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
        self.exporter = HealthKitManualExporter(
            healthStore: healthStore,
            store: store,
            types: types
        )
        self.observer = HealthObserver(healthStore: healthStore, types: types)
        self.sync = SyncCoordinator(
            engine: HealthSyncEngine(
                store: store,
                source: source,
                delivery: delivery,
                types: types.map(\.catalogEntry.key)
            ),
            delivery: delivery
        )
    }

    /// Begins watching Health so iOS wakes Hozz when new data arrives.
    func startObserving() async {
        let selection = (try? await selectedTypes()) ?? []
        let sync = sync
        await observer.start(selection: selection) { _ in
            // The observer callback owes iOS an answer within seconds, so the
            // sync is kicked off and not waited on.
            Task.detached(priority: .utility) {
                _ = try? await sync.sync()
            }
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
}

extension DeliveryEngine {
    /// Sends a small, clearly-marked probe and reports what came back.
    ///
    /// Setup failures in this space are almost always a wrong URL or a wrong
    /// auth header, discovered days later when data never arrived. This turns
    /// that into an immediate, readable answer.
    func test(_ destination: Destination) async throws -> String {
        let probe = Data(
            #"{"kind":"hozzConnectionTest","schemaVersion":1}"#.utf8
        )
        let batch = DeliveryBatch(
            id: UUID(),
            sequence: 0,
            createdAt: .now,
            recordCount: 0,
            payload: destination.format == .ndjson ? probe + Data([0x0A]) : probe,
            format: destination.format
        )

        do {
            let receipt = try await deliverWithoutRecording(batch, to: destination)
            switch destination.kind {
            case .folder:
                return "Wrote \(receipt.artifactName ?? "a test file") successfully."
            case .restAPI:
                return "The destination accepted the test. \(receipt.detail ?? "")"
            case .mqtt:
                return "The broker accepted the test. \(receipt.detail ?? "")"
            }
        } catch let error as DeliveryError {
            return error.errorDescription ?? "The test failed."
        }
    }
}
