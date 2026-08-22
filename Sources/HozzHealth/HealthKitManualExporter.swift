import Foundation
import HealthKit
import HozzCatalog

public struct HealthExportProgress: Equatable, Sendable {
    public let completedTypes: Int
    public let totalTypes: Int
    public let recordCount: Int
    public let currentType: String

    public init(
        completedTypes: Int,
        totalTypes: Int,
        recordCount: Int,
        currentType: String
    ) {
        self.completedTypes = completedTypes
        self.totalTypes = totalTypes
        self.recordCount = recordCount
        self.currentType = currentType
    }
}

public struct HealthExportResult: Equatable, Sendable {
    public let fileURL: URL
    public let recordCount: Int
    public let attemptedTypeCount: Int
    public let nonEmptyTypeCount: Int
    public let catalogTypeCount: Int
    public let zeroResultTypeCount: Int
    public let failedTypeCount: Int
    public let sampleEncodingErrorCount: Int

    public init(
        fileURL: URL,
        recordCount: Int,
        attemptedTypeCount: Int,
        nonEmptyTypeCount: Int,
        catalogTypeCount: Int,
        zeroResultTypeCount: Int,
        failedTypeCount: Int,
        sampleEncodingErrorCount: Int
    ) {
        self.fileURL = fileURL
        self.recordCount = recordCount
        self.attemptedTypeCount = attemptedTypeCount
        self.nonEmptyTypeCount = nonEmptyTypeCount
        self.catalogTypeCount = catalogTypeCount
        self.zeroResultTypeCount = zeroResultTypeCount
        self.failedTypeCount = failedTypeCount
        self.sampleEncodingErrorCount = sampleEncodingErrorCount
    }
}

public enum HealthKitManualExporterError: Error, LocalizedError, Sendable {
    case healthDataUnavailable
    case missingAnchor
    case cannotCreateExport
    case partialExport(fileURL: URL, reason: String)

    public var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            "Health data is unavailable on this device."
        case .missingAnchor:
            "HealthKit returned data without a continuation anchor."
        case .cannotCreateExport:
            "Hozz could not create the export file."
        case .partialExport(_, let reason):
            "Hozz preserved a partial export after an unexpected failure: \(reason)"
        }
    }
}

public actor HealthKitManualExporter {
    private struct TypeExportStats {
        let writtenRecords: Int
        let observedRecords: Int
        let encodingErrors: Int
    }

    private struct BatchExportStats {
        let writtenRecords: Int
        let observedRecords: Int
        let encodingErrors: Int
    }

    private let healthStore: HKHealthStore
    private let encoder: HealthSampleEncoder
    private let batchSize: Int

    public init(
        healthStore: HKHealthStore = HKHealthStore(),
        encoder: HealthSampleEncoder = HealthSampleEncoder(),
        batchSize: Int = 1_000
    ) {
        self.healthStore = healthStore
        self.encoder = encoder
        self.batchSize = batchSize
    }

    public func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitManualExporterError.healthDataUnavailable
        }

        let readTypes = Set(
            HealthKitTypeRegistry.exportableTypes().map(\.sampleType)
        )
        try await healthStore.requestAuthorization(toShare: [], read: readTypes)
    }

    public func export(
        progress: @escaping @Sendable (HealthExportProgress) async -> Void
    ) async throws -> HealthExportResult {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitManualExporterError.healthDataUnavailable
        }

        let types = HealthKitTypeRegistry.exportableTypes()
        let fileURL = try makeExportFile()
        let handle = try FileHandle(forWritingTo: fileURL)
        var totalRecords = 0
        var zeroResultTypes = 0
        var nonEmptyTypes = 0
        var failedTypes = 0
        var sampleEncodingErrors = 0

        do {
            try write(
                [
                    "kind": "manifest",
                    "schemaVersion": 1,
                    "catalogVersion": HealthTypeCatalog.version,
                    "createdAt": timestamp(.now),
                    "coverage": "authorization-scoped",
                    "attemptedTypes": types.count,
                    "catalogTypes": HealthTypeCatalog.entries.count
                ],
                to: handle
            )

            for (index, type) in types.enumerated() {
                try Task.checkCancellation()
                let stats: TypeExportStats
                var typeWrittenRecords = 0
                var typeObservedRecords = 0
                var typeEncodingErrors = 0

                do {
                    stats = try await export(type: type, to: handle) { batch in
                        totalRecords += batch.writtenRecords
                        typeWrittenRecords += batch.writtenRecords
                        typeObservedRecords += batch.observedRecords
                        typeEncodingErrors += batch.encodingErrors
                        sampleEncodingErrors += batch.encodingErrors
                        await progress(
                            HealthExportProgress(
                                completedTypes: index,
                                totalTypes: types.count,
                                recordCount: totalRecords,
                                currentType: type.catalogEntry.key.rawValue
                            )
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failedTypes += 1
                    if typeObservedRecords > 0 {
                        nonEmptyTypes += 1
                    }
                    try write(
                        [
                            "kind": "typeError",
                            "type": type.catalogEntry.key.rawValue,
                            "message": error.localizedDescription,
                            "records": typeWrittenRecords,
                            "observedRecords": typeObservedRecords,
                            "encodingErrors": typeEncodingErrors
                        ],
                        to: handle
                    )
                    await progress(
                        HealthExportProgress(
                            completedTypes: index + 1,
                            totalTypes: types.count,
                            recordCount: totalRecords,
                            currentType: type.catalogEntry.key.rawValue
                        )
                    )
                    continue
                }

                if stats.observedRecords == 0 {
                    zeroResultTypes += 1
                } else {
                    nonEmptyTypes += 1
                }

                try write(
                    [
                        "kind": "typeSummary",
                        "type": type.catalogEntry.key.rawValue,
                        "records": stats.writtenRecords,
                        "observedRecords": stats.observedRecords,
                        "encodingErrors": stats.encodingErrors,
                        "state": stats.observedRecords == 0 ? "authorizationIndeterminate" : "anchorClosed"
                    ],
                    to: handle
                )
                await progress(
                    HealthExportProgress(
                        completedTypes: index + 1,
                        totalTypes: types.count,
                        recordCount: totalRecords,
                        currentType: type.catalogEntry.key.rawValue
                    )
                )
            }

            try write(
                [
                    "kind": "completion",
                    "completedAt": timestamp(.now),
                    "records": totalRecords,
                    "attemptedTypes": types.count,
                    "nonEmptyTypes": nonEmptyTypes,
                    "catalogTypes": HealthTypeCatalog.entries.count,
                    "zeroResultTypes": zeroResultTypes,
                    "failedTypes": failedTypes,
                    "sampleEncodingErrors": sampleEncodingErrors
                ],
                to: handle
            )
            try handle.synchronize()
            try handle.close()

            return HealthExportResult(
                fileURL: fileURL,
                recordCount: totalRecords,
                attemptedTypeCount: types.count,
                nonEmptyTypeCount: nonEmptyTypes,
                catalogTypeCount: HealthTypeCatalog.entries.count,
                zeroResultTypeCount: zeroResultTypes,
                failedTypeCount: failedTypes,
                sampleEncodingErrorCount: sampleEncodingErrors
            )
        } catch is CancellationError {
            try? handle.close()
            try? FileManager.default.removeItem(at: fileURL)
            throw CancellationError()
        } catch {
            try? handle.close()
            throw HealthKitManualExporterError.partialExport(
                fileURL: fileURL,
                reason: error.localizedDescription
            )
        }
    }

    private func export(
        type: ExportableHealthType,
        to handle: FileHandle,
        didWriteBatch: (BatchExportStats) async -> Void
    ) async throws -> TypeExportStats {
        var anchor: HKQueryAnchor?
        var writtenRecords = 0
        var observedRecords = 0
        var encodingErrors = 0

        while true {
            try Task.checkCancellation()
            let page = try await query(type: type.sampleType, anchor: anchor)
            var batchWrittenRecords = 0
            var batchEncodingErrors = 0

            for sample in page.samples {
                do {
                    try write(
                        encoder.encode(sample: sample, catalogEntry: type.catalogEntry),
                        to: handle
                    )
                    writtenRecords += 1
                    batchWrittenRecords += 1
                } catch let error as HealthSampleEncodingError {
                    encodingErrors += 1
                    batchEncodingErrors += 1
                    try write(
                        [
                            "kind": "sampleEncodingError",
                            "id": sample.uuid.uuidString.lowercased(),
                            "type": type.catalogEntry.key.rawValue,
                            "message": String(describing: error)
                        ],
                        to: handle
                    )
                }
            }
            for deletion in page.deletions {
                try write(
                    encoder.encodeDeletion(
                        id: deletion.uuid,
                        typeIdentifier: type.sampleType.identifier
                    ),
                    to: handle
                )
                writtenRecords += 1
                batchWrittenRecords += 1
            }

            let batchCount = page.samples.count + page.deletions.count
            observedRecords += batchCount
            try handle.synchronize()

            guard let newAnchor = page.newAnchor else {
                throw HealthKitManualExporterError.missingAnchor
            }
            anchor = newAnchor
            await didWriteBatch(
                BatchExportStats(
                    writtenRecords: batchWrittenRecords,
                    observedRecords: batchCount,
                    encodingErrors: batchEncodingErrors
                )
            )

            if batchCount == 0 {
                return TypeExportStats(
                    writtenRecords: writtenRecords,
                    observedRecords: observedRecords,
                    encodingErrors: encodingErrors
                )
            }
        }
    }

    private func query(
        type: HKSampleType,
        anchor: HKQueryAnchor?
    ) async throws -> (
        samples: [HKSample],
        deletions: [HKDeletedObject],
        newAnchor: HKQueryAnchor?
    ) {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: nil,
                anchor: anchor,
                limit: batchSize
            ) { _, samples, deletions, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(
                    returning: (
                        samples ?? [],
                        deletions ?? [],
                        newAnchor
                    )
                )
            }
            healthStore.execute(query)
        }
    }

    private func makeExportFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Hozz", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let staleFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for file in staleFiles where file.lastPathComponent.hasPrefix("hozz-health-export-") {
            try FileManager.default.removeItem(at: file)
        }

        let fileURL = directory.appending(
            path: "hozz-health-export-\(UUID().uuidString.lowercased()).ndjson"
        )
        guard FileManager.default.createFile(
            atPath: fileURL.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        ) else {
            throw HealthKitManualExporterError.cannotCreateExport
        }

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = fileURL
        try mutableURL.setResourceValues(values)
        return fileURL
    }

    private func write(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try write(data, to: handle)
    }

    private func write(_ data: Data, to handle: FileHandle) throws {
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    private func timestamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        ).format(date)
    }
}
