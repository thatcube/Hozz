import Foundation
import HealthKit
import HozzCatalog

public enum HealthExportTypeState: Equatable, Sendable {
    case exporting
    case completed
    case failed
}

public struct HealthExportProgress: Equatable, Sendable {
    public let completedTypes: Int
    public let totalTypes: Int
    public let recordCount: Int
    public let currentTypeIdentifier: String
    public let currentTypeName: String
    public let currentTypeFamily: HealthTypeFamily?
    public let currentTypeRecordCount: Int
    public let currentTypeState: HealthExportTypeState

    public init(
        completedTypes: Int,
        totalTypes: Int,
        recordCount: Int,
        currentTypeIdentifier: String,
        currentTypeName: String,
        currentTypeFamily: HealthTypeFamily?,
        currentTypeRecordCount: Int,
        currentTypeState: HealthExportTypeState
    ) {
        self.completedTypes = completedTypes
        self.totalTypes = totalTypes
        self.recordCount = recordCount
        self.currentTypeIdentifier = currentTypeIdentifier
        self.currentTypeName = currentTypeName
        self.currentTypeFamily = currentTypeFamily
        self.currentTypeRecordCount = currentTypeRecordCount
        self.currentTypeState = currentTypeState
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
    public let fileByteCount: UInt64
    public let format: HealthExportFormat

    public init(
        fileURL: URL,
        recordCount: Int,
        attemptedTypeCount: Int,
        nonEmptyTypeCount: Int,
        catalogTypeCount: Int,
        zeroResultTypeCount: Int,
        failedTypeCount: Int,
        sampleEncodingErrorCount: Int,
        fileByteCount: UInt64,
        format: HealthExportFormat
    ) {
        self.fileURL = fileURL
        self.recordCount = recordCount
        self.attemptedTypeCount = attemptedTypeCount
        self.nonEmptyTypeCount = nonEmptyTypeCount
        self.catalogTypeCount = catalogTypeCount
        self.zeroResultTypeCount = zeroResultTypeCount
        self.failedTypeCount = failedTypeCount
        self.sampleEncodingErrorCount = sampleEncodingErrorCount
        self.fileByteCount = fileByteCount
        self.format = format
    }
}

public enum HealthKitManualExporterError: Error, LocalizedError, Sendable {
    case healthDataUnavailable
    case missingAnchor
    case cannotCreateExport
    case authorizationNotCompleted
    case nonAdvancingAnchor(typeIdentifier: String)
    case exceededQueryBudget(typeIdentifier: String)
    case partialExport(fileURL: URL, reason: String)

    public var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            "Health data is unavailable on this device."
        case .missingAnchor:
            "HealthKit returned data without a continuation anchor."
        case .cannotCreateExport:
            "Hozz could not create the export file."
        case .authorizationNotCompleted:
            "Health access was not completed."
        case .nonAdvancingAnchor(let typeIdentifier):
            "HealthKit stopped advancing while reading \(typeIdentifier)."
        case .exceededQueryBudget(let typeIdentifier):
            "Reading \(typeIdentifier) exceeded its safety limit."
        case .partialExport(_, let reason):
            "Hozz preserved a partial export after an unexpected failure: \(reason)"
        }
    }
}

public actor HealthKitManualExporter {
    /// Bounds a single type's pagination so a HealthKit stream that never
    /// reports exhaustion cannot spin indefinitely. At the default batch size
    /// this still allows tens of millions of records for one type.
    private static let maximumQueriesPerType = 50_000

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

        let readTypes = HealthKitTypeRegistry.authorizationReadTypes()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            healthStore.requestAuthorization(
                toShare: nil,
                read: readTypes
            ) { success, error in
                if let error {
                    continuation.resume(throwing: error)
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
        format: HealthExportFormat = .gzip,
        progress: @escaping @Sendable (HealthExportProgress) async -> Void
    ) async throws -> HealthExportResult {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitManualExporterError.healthDataUnavailable
        }

        let types = HealthKitTypeRegistry.exportableTypes()
        let fileURL = try makeExportFile(format: format)
        let output: any ExportOutput = switch format {
        case .gzip:
            try GzipExportOutput(fileURL: fileURL)
        case .raw:
            try RawExportOutput(fileURL: fileURL)
        }
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
                to: output
            )

            for (index, type) in types.enumerated() {
                try Task.checkCancellation()
                let stats: TypeExportStats
                var typeWrittenRecords = 0
                var typeObservedRecords = 0
                var typeEncodingErrors = 0
                await progress(
                    HealthExportProgress(
                        completedTypes: index,
                        totalTypes: types.count,
                        recordCount: totalRecords,
                        currentTypeIdentifier: type.catalogEntry.key.rawValue,
                        currentTypeName: type.catalogEntry.displayName,
                        currentTypeFamily: type.catalogEntry.family,
                        currentTypeRecordCount: 0,
                        currentTypeState: .exporting
                    )
                )

                do {
                    stats = try await export(type: type, to: output) { batch in
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
                                currentTypeIdentifier: type.catalogEntry.key.rawValue,
                                currentTypeName: type.catalogEntry.displayName,
                                currentTypeFamily: type.catalogEntry.family,
                                currentTypeRecordCount: typeWrittenRecords,
                                currentTypeState: .exporting
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
                        to: output
                    )
                    await progress(
                        HealthExportProgress(
                            completedTypes: index + 1,
                            totalTypes: types.count,
                            recordCount: totalRecords,
                            currentTypeIdentifier: type.catalogEntry.key.rawValue,
                            currentTypeName: type.catalogEntry.displayName,
                            currentTypeFamily: type.catalogEntry.family,
                            currentTypeRecordCount: typeWrittenRecords,
                            currentTypeState: .failed
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
                    to: output
                )
                await progress(
                    HealthExportProgress(
                        completedTypes: index + 1,
                        totalTypes: types.count,
                        recordCount: totalRecords,
                        currentTypeIdentifier: type.catalogEntry.key.rawValue,
                        currentTypeName: type.catalogEntry.displayName,
                        currentTypeFamily: type.catalogEntry.family,
                        currentTypeRecordCount: stats.writtenRecords,
                        currentTypeState: .completed
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
                to: output
            )
            let fileByteCount = try output.finish()

            return HealthExportResult(
                fileURL: fileURL,
                recordCount: totalRecords,
                attemptedTypeCount: types.count,
                nonEmptyTypeCount: nonEmptyTypes,
                catalogTypeCount: HealthTypeCatalog.entries.count,
                zeroResultTypeCount: zeroResultTypes,
                failedTypeCount: failedTypes,
                sampleEncodingErrorCount: sampleEncodingErrors,
                fileByteCount: fileByteCount,
                format: format
            )
        } catch is CancellationError {
            output.abandon()
            try? FileManager.default.removeItem(at: fileURL)
            throw CancellationError()
        } catch {
            let originalError = error
            do {
                _ = try output.finish()
            } catch {
                output.abandon()
                try? FileManager.default.removeItem(at: fileURL)
                throw originalError
            }
            throw HealthKitManualExporterError.partialExport(
                fileURL: fileURL,
                reason: originalError.localizedDescription
            )
        }
    }

    private func export(
        type: ExportableHealthType,
        to output: any ExportOutput,
        didWriteBatch: (BatchExportStats) async -> Void
    ) async throws -> TypeExportStats {
        var anchor: HKQueryAnchor?
        var writtenRecords = 0
        var observedRecords = 0
        var encodingErrors = 0
        var queryCount = 0

        while true {
            try Task.checkCancellation()
            let page = try await query(type: type.sampleType, anchor: anchor)
            var batchWrittenRecords = 0
            var batchEncodingErrors = 0
            queryCount += 1

            guard queryCount <= Self.maximumQueriesPerType else {
                throw HealthKitManualExporterError.exceededQueryBudget(
                    typeIdentifier: type.catalogEntry.key.rawValue
                )
            }

            for sample in page.samples {
                do {
                    try write(
                        encoder.encode(sample: sample, catalogEntry: type.catalogEntry),
                        to: output
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
                        to: output
                    )
                }
            }
            for deletion in page.deletions {
                try write(
                    encoder.encodeDeletion(
                        id: deletion.uuid,
                        typeIdentifier: type.sampleType.identifier
                    ),
                    to: output
                )
                writtenRecords += 1
                batchWrittenRecords += 1
            }

            let batchCount = page.samples.count + page.deletions.count
            observedRecords += batchCount
            try output.synchronize()

            guard let newAnchor = page.newAnchor else {
                throw HealthKitManualExporterError.missingAnchor
            }
            if batchCount > 0, newAnchor == anchor {
                throw HealthKitManualExporterError.nonAdvancingAnchor(
                    typeIdentifier: type.catalogEntry.key.rawValue
                )
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

    private func makeExportFile(format: HealthExportFormat) throws -> URL {
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
            path: "hozz-health-export-\(UUID().uuidString.lowercased()).\(format.fileExtension)"
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

    private func write(_ object: [String: Any], to output: any ExportOutput) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try write(data, to: output)
    }

    private func write(_ data: Data, to output: any ExportOutput) throws {
        try output.write(data)
        try output.write(Data([0x0A]))
    }

    private func timestamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        ).format(date)
    }
}
