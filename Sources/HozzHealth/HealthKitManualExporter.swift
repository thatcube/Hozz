import Foundation
import HealthKit
import HozzCatalog
import HozzCore
import HozzStore

public enum HealthKitManualExporterError: Error, LocalizedError, Sendable {
    case healthDataUnavailable
    case cannotCreateExport
    case authorizationNotCompleted

    public var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            "Health data is unavailable on this device."
        case .cannotCreateExport:
            "Hozz could not create the export file."
        case .authorizationNotCompleted:
            "Health access was not completed."
        }
    }
}

/// The HealthKit-facing entry point for a manual export.
///
/// Everything about ordering, durability, and resumption lives in
/// ``HealthExportEngine``; this type only owns authorization and the wiring
/// between HealthKit and the store.
public actor HealthKitManualExporter {
    private let healthStore: HKHealthStore
    private let store: HozzStore
    private let allTypes: [ExportableHealthType]
    private let batchSize: Int
    /// One engine per format, because a format decides which types the run
    /// reads. Built on demand and kept, so resuming a run does not rebuild it.
    private var engines: [HealthExportFormat: HealthExportEngine] = [:]

    public init(
        healthStore: HKHealthStore = HKHealthStore(),
        store: HozzStore,
        types: [ExportableHealthType] = HealthKitTypeRegistry.exportableTypes(),
        batchSize: Int = 1_000
    ) {
        self.healthStore = healthStore
        self.store = store
        self.allTypes = types
        self.batchSize = batchSize
    }

    /// The types a run in this format will read.
    ///
    /// Kept separate and pure so the narrowing can be checked without a
    /// HealthKit store, which is the part that decides whether someone waits
    /// for their whole history or for two types.
    public static func types(
        for format: HealthExportFormat,
        from all: [ExportableHealthType]
    ) -> [ExportableHealthType] {
        guard let required = format.requiredTypes else {
            return all
        }
        return all.filter { required.contains($0.catalogEntry.key) }
    }

    private func engine(for format: HealthExportFormat) -> HealthExportEngine {
        if let existing = engines[format] {
            return existing
        }
        let selected = Self.types(for: format, from: allTypes)
        let engine = HealthExportEngine(
            store: store,
            source: HealthKitHealthDataSource(
                healthStore: healthStore,
                types: selected
            ),
            types: selected.map(\.catalogEntry.key),
            characteristics: HealthKitCharacteristicsReader(
                healthStore: healthStore
            ),
            batchSize: batchSize
        )
        engines[format] = engine
        return engine
    }

    /// Any engine will do for the store-backed operations below: they read and
    /// write run records, and none of them touches the type list.
    private func storeBackedEngine() -> HealthExportEngine {
        engine(for: .ndjson)
    }

    /// Opens the store in the app's private support directory.
    public static func makeDefault() throws -> HealthKitManualExporter {
        HealthKitManualExporter(store: try HozzStore.makeDefault())
    }

    public func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitManualExporterError.healthDataUnavailable
        }

        let readTypes = HealthKitTypeRegistry.authorizationReadTypes()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            healthStore.requestAuthorization(
                toShare: nil,
                read: readTypes
            ) { success, error in
                if let error {
                    continuation.resume(
                        throwing: HealthKitFailure.classify(error)
                    )
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: HealthKitManualExporterError.authorizationNotCompleted
                    )
                }
            }
        }
    }

    public func export(
        format: HealthExportFormat = .ndjson,
        progress: @escaping @Sendable (HealthExportProgress) async -> Void
    ) async throws -> HealthExportOutcome {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitManualExporterError.healthDataUnavailable
        }
        return try await engine(for: format)
            .export(format: format, progress: progress)
    }

    public func resumableRun() async throws -> ExportRunRecord? {
        try await storeBackedEngine().resumableRun()
    }

    public func discardRun(id: UUID) async throws {
        try await storeBackedEngine().discardRun(id: id)
    }

    /// Deletes spool artifacts no run still references.
    ///
    /// Called at launch so a Health dump left behind by a crash does not sit on
    /// disk until the next export happens to start.
    @discardableResult
    public func sweepUnreferencedArtifacts() async throws -> Int {
        try await ExportSpoolSweeper.sweep(store: store)
    }
}
