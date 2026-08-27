import Foundation
import HealthKit
import HozzCore
import HozzDeliver
import HozzHealth
import HozzStore

/// Wires the modules together once, so the app, the background task, and the
/// App Intents all share the same store, cursors, and delivery state.
///
/// Two processes writing the same spool would corrupt it, so everything that
/// can drain Health goes through one lease.
final class HozzServices: @unchecked Sendable {
    let store: HozzStore
    let delivery: DeliveryEngine
    let exporter: HealthKitManualExporter
    let sync: SyncCoordinator
    let observer: HealthObserver

    /// The types the drain actually visits. A destination that names no types
    /// means "everything", and this is what everything is.
    let syncTypes: [HealthTypeKey]

    /// Collapses observer bursts into single passes. Held here so the app, the
    /// background task, and the intents all feed the same one.
    ///
    /// Deliberately not `lazy`: this type is `@unchecked Sendable`, so a lazy
    /// property could be initialised twice from different threads and quietly
    /// produce two coalescers that do not coalesce with each other.
    let coalescer: SyncCoalescer

    private let healthStore = HKHealthStore()

    init() throws {
        let store = try HozzStore.makeDefault()
        let types = HealthKitTypeRegistry.exportableTypes()
        let source = HealthKitHealthDataSource(
            healthStore: healthStore,
            types: types
        )
        let delivery = DeliveryEngine(store: store)

        self.store = store
        self.delivery = delivery
        self.syncTypes = types.map(\.catalogEntry.key)
        self.exporter = HealthKitManualExporter(
            healthStore: healthStore,
            store: store,
            types: types
        )
        self.observer = HealthObserver(healthStore: healthStore, types: types)
        let sync = SyncCoordinator(
            engine: HealthSyncEngine(
                store: store,
                source: source,
                delivery: delivery,
                types: types.map(\.catalogEntry.key),
                // The same object, offered twice, because it is the same
                // HealthKit connection read two ways: by anchor for the sweep
                // that will eventually have everything, and by date for the
                // prime that makes the recent past appear now.
                datedSource: source
            ),
            delivery: delivery
        )
        self.sync = sync
        self.coalescer = SyncCoalescer { _ in
            // Dirty types deliberately do not narrow the pass. A narrowed pass
            // still marks the destination as recently attempted, so an hourly
            // destination woken for one type would not look due again for an
            // hour, delaying every type that did not happen to fire. Checking
            // all types is cheap when there is nothing new to read.
            _ = try? await sync.sync()
        }
    }

    /// Begins watching Health so iOS wakes Hozz when new data arrives.
    func startObserving() async {
        let selection = (try? await selectedTypes()) ?? []
        let coalescer = coalescer
        await observer.start(selection: selection) { types in
            // The observer callback owes iOS an answer within seconds, so the
            // sync is requested and not waited on. HealthKit fires every
            // observer at once after a Watch sync, so this goes through the
            // coalescer rather than starting a pass per type.
            await coalescer.request(types: types)
        }
    }

    /// The union of every destination's chosen types. Empty means everything.
    private func selectedTypes() async throws -> Set<HealthTypeKey> {
        let destinations = try await delivery.destinations()
        guard destinations.contains(where: { !$0.includedTypes.isEmpty }) else {
            return []
        }
        return destinations.reduce(into: Set<HealthTypeKey>()) { result, destination in
            result.formUnion(destination.includedTypes)
        }
    }
}

/// A thin wrapper that adds "run regardless of cadence" and a connection test.
struct SyncCoordinator: Sendable {
    private let engine: HealthSyncEngine
    private let delivery: DeliveryEngine

    init(engine: HealthSyncEngine, delivery: DeliveryEngine) {
        self.engine = engine
        self.delivery = delivery
    }

    @discardableResult
    func sync(force: Bool = false) async throws -> SyncOutcome {
        try await engine.sync(ignoringCadence: force)
    }

    /// Walks the recent months again for every destination.
    ///
    /// The pass that follows does the work; this only moves the cursors back,
    /// so the app stops claiming the stretch before it starts re-reading it.
    func primeAgain() async throws {
        try await engine.restartPrime()
    }
}

struct DestinationTestResult: Sendable {
    let message: String
    let endpointURL: URL?
}

extension DeliveryEngine {
    /// Sends a small, clearly-marked probe and reports what came back.
    ///
    /// Setup failures in this space are almost always a wrong URL or a wrong
    /// auth header, discovered days later when data never arrived. This turns
    /// that into an immediate, readable answer.
    func test(_ destination: Destination) async throws -> DestinationTestResult {
        let batch = DeliveryBatch(
            id: UUID(),
            sequence: 0,
            createdAt: .now,
            recordCount: 0,
            payload: DeliveryProbe.payload(for: destination),
            format: destination.format
        )

        do {
            let savedEndpointBefore = try await self.destination(
                id: destination.id
            )?.endpointURL
            let receipt = try await deliverWithoutRecording(batch, to: destination)
            let message = switch destination.kind {
            case .folder:
                "Wrote \(receipt.artifactName ?? "a test file") successfully."
            case .restAPI:
                "The destination accepted the test. \(receipt.detail ?? "")"
            case .mqtt:
                "The broker accepted the test. \(receipt.detail ?? "")"
            }
            let savedEndpointAfter = try await self.destination(
                id: destination.id
            )?.endpointURL
            return DestinationTestResult(
                message: message,
                // An edited draft was tested but not persisted; returning the
                // old cached address would overwrite the user's working edit.
                // Only return the endpoint when this test actually changed the
                // saved destination it began from.
                endpointURL:
                    savedEndpointBefore == destination.endpointURL
                        && savedEndpointAfter != savedEndpointBefore
                    ? savedEndpointAfter
                    : nil
            )
        } catch let error as DeliveryError {
            return DestinationTestResult(
                message: error.errorDescription ?? "The test failed.",
                endpointURL: nil
            )
        }
    }
}
