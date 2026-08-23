import Foundation
import HozzAcquire
import HozzCatalog
import HozzCore
import HozzStore

public enum HealthExportTypeState: Equatable, Sendable {
    case exporting
    case completed
    case failed
    /// The type finished but Health returned nothing, which Hozz cannot
    /// distinguish from the type being denied.
    case indeterminate
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
    public let runID: UUID
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
    public let wasResumed: Bool

    public init(
        runID: UUID,
        fileURL: URL,
        recordCount: Int,
        attemptedTypeCount: Int,
        nonEmptyTypeCount: Int,
        catalogTypeCount: Int,
        zeroResultTypeCount: Int,
        failedTypeCount: Int,
        sampleEncodingErrorCount: Int,
        fileByteCount: UInt64,
        format: HealthExportFormat,
        wasResumed: Bool
    ) {
        self.runID = runID
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
        self.wasResumed = wasResumed
    }
}

/// Why a run stopped at a checkpoint instead of finishing.
public enum HealthExportPauseReason: Equatable, Sendable {
    /// The app was cancelled, backgrounded, or its background time expired.
    case checkpointed
    /// Health is locked. Unlocking the device is enough to continue.
    case deviceLocked
}

public struct HealthExportPause: Equatable, Sendable {
    public let runID: UUID
    public let reason: HealthExportPauseReason
    public let completedTypeCount: Int
    public let totalTypeCount: Int
    public let recordCount: Int

    public init(
        runID: UUID,
        reason: HealthExportPauseReason,
        completedTypeCount: Int,
        totalTypeCount: Int,
        recordCount: Int
    ) {
        self.runID = runID
        self.reason = reason
        self.completedTypeCount = completedTypeCount
        self.totalTypeCount = totalTypeCount
        self.recordCount = recordCount
    }
}

public enum HealthExportOutcome: Equatable, Sendable {
    case completed(HealthExportResult)
    case paused(HealthExportPause)
}

public enum HealthExportEngineError: Error, LocalizedError, Equatable, Sendable {
    case exportAlreadyRunning

    public var errorDescription: String? {
        switch self {
        case .exportAlreadyRunning:
            "An export is already running."
        }
    }
}

/// Drives one export run to completion, or to a checkpoint it can resume from.
///
/// The engine deliberately knows nothing about HealthKit. It composes a
/// ``HealthDataSource`` with a ``SpooledExportSink`` through the same
/// ``DrainCoordinator`` the fault tests exercise, which is what makes those
/// tests statements about production behaviour rather than about a parallel
/// implementation.
public actor HealthExportEngine {
    /// Bounds one type's pagination so a stream that never reports exhaustion
    /// cannot spin forever. At the default page size this still allows tens of
    /// millions of records for a single type.
    public static let maximumQueriesPerType = 50_000

    /// Coverage states that mean a type reached an empty page in this run.
    ///
    /// A type is only settled when it also carries a closure timestamp. An
    /// authorization *error* records `authorizationIndeterminate` too, and
    /// treating that as settled would skip a type on resume that never actually
    /// reached the end of its stream — silently overstating coverage.
    private static let settledCoverage: Set<CoverageState> = [
        .anchorClosed,
        .authorizationIndeterminate
    ]

    private let store: HozzStore
    private let source: any HealthDataSource
    private let characteristics: (any HealthCharacteristicsSource)?
    private let types: [HealthTypeKey]
    private let batchSize: Int
    private let lease: ExportWriterLease
    private let sinkFactory: @Sendable (UUID, HealthExportFormat, URL, Int, Int) -> SpooledExportSink

    public init(
        store: HozzStore,
        source: any HealthDataSource,
        types: [HealthTypeKey],
        characteristics: (any HealthCharacteristicsSource)? = nil,
        batchSize: Int = 1_000,
        lease: ExportWriterLease = .shared,
        sinkFactory: (
            @Sendable (UUID, HealthExportFormat, URL, Int, Int) -> SpooledExportSink
        )? = nil
    ) {
        self.store = store
        self.source = source
        self.characteristics = characteristics
        self.types = types
        self.batchSize = batchSize
        self.lease = lease
        self.sinkFactory = sinkFactory ?? { runID, format, spool, sequence, records in
            SpooledExportSink(
                store: store,
                runID: runID,
                format: format,
                spoolDirectory: spool,
                nextSequence: sequence,
                totalRecordCount: records
            )
        }
    }

    /// The run that a new call to ``export(format:progress:)`` would resume.
    public func resumableRun() async throws -> ExportRunRecord? {
        try await store.resumableRun()
    }

    /// Discards a run and every artifact it owns.
    public func discardRun(id: UUID) async throws {
        for part in try await store.parts(runID: id) {
            try? FileManager.default.removeItem(
                at: await store.spoolDirectory.appending(path: part.fileName)
            )
        }
        try await store.deleteRun(id: id)
    }

    public func export(
        format: HealthExportFormat,
        progress: @escaping @Sendable (HealthExportProgress) async -> Void
    ) async throws -> HealthExportOutcome {
        guard await lease.acquire() else {
            throw HealthExportEngineError.exportAlreadyRunning
        }
        defer {
            Task { await lease.release() }
        }
        return try await runExport(format: format, progress: progress)
    }

    private func runExport(
        format: HealthExportFormat,
        progress: @escaping @Sendable (HealthExportProgress) async -> Void
    ) async throws -> HealthExportOutcome {
        let spool = await store.spoolDirectory
        let (run, wasResumed) = try await resolveRun(format: format)

        // An unsealed part's bytes were never durable, so it is deleted and the
        // types it touched replay from their last sealed cursor.
        for orphan in try await store.discardOpenParts(runID: run.id) {
            try? FileManager.default.removeItem(
                at: spool.appending(path: orphan.fileName)
            )
        }

        let sealedParts = try await store.parts(runID: run.id)
        let nextSequence = (sealedParts.map(\.sequence).max() ?? -1) + 1
        let sink = sinkFactory(
            run.id,
            format,
            spool,
            nextSequence,
            run.recordCount
        )
        let coordinator = DrainCoordinator(source: source, sink: sink)

        var settled = try await settledStates(runID: run.id)
        if wasResumed {
            try await sink.writeRecord([
                "kind": "resume",
                "schemaVersion": 1,
                "run": run.id.uuidString.lowercased(),
                "resumedAt": Self.timestamp(.now),
                "completedTypes": settled.count,
                "records": run.recordCount
            ])
        } else {
            try await sink.writeRecord([
                "kind": "manifest",
                "schemaVersion": 1,
                "run": run.id.uuidString.lowercased(),
                "catalogVersion": HealthTypeCatalog.version,
                "createdAt": Self.timestamp(run.startedAt),
                "coverage": "authorization-scoped",
                "attemptedTypes": types.count,
                "catalogTypes": HealthTypeCatalog.entries.count
            ])
        }

        // Written on every attempt rather than only on the first. The part
        // holding an earlier copy may have been discarded unsealed, and these
        // few lines are the context that makes every measurement after them
        // interpretable — a duplicate is cheap, a missing one is not. Each
        // carries its own `readAt`, so the last is the current one.
        if let characteristics {
            try await sink.writeRecord(
                HealthCharacteristicsRecord.make(
                    from: await characteristics.characteristics()
                )
            )
        }

        do {
            return try await drainAll(
                run: run,
                wasResumed: wasResumed,
                format: format,
                sink: sink,
                coordinator: coordinator,
                settled: &settled,
                progress: progress
            )
        } catch {
            // Preserve everything already sealed, then surface the failure.
            try? await sink.seal()
            try? await store.updateRun(
                id: run.id,
                state: .paused,
                failureReason: error.localizedDescription
            )
            throw error
        }
    }

    // MARK: - Draining

    private func drainAll(
        run: ExportRunRecord,
        wasResumed: Bool,
        format: HealthExportFormat,
        sink: SpooledExportSink,
        coordinator: DrainCoordinator,
        settled: inout [HealthTypeKey: StreamRecord],
        progress: @escaping @Sendable (HealthExportProgress) async -> Void
    ) async throws -> HealthExportOutcome {
        var completedTypes = 0
        var failedTypes = 0
        var zeroResultTypes = 0
        var nonEmptyTypes = 0

        for type in types {
            let entry = HealthTypeCatalog.entriesByIdentifier[type.rawValue]

            if let record = settled[type] {
                completedTypes += 1
                if record.observedCount == 0 {
                    zeroResultTypes += 1
                } else {
                    nonEmptyTypes += 1
                }
                await progress(
                    Self.progress(
                        completedTypes: completedTypes,
                        totalTypes: types.count,
                        recordCount: await sink.recordCount,
                        type: type,
                        entry: entry,
                        typeRecordCount: record.recordCount,
                        state: record.observedCount == 0 ? .indeterminate : .completed
                    )
                )
                continue
            }

            await progress(
                Self.progress(
                    completedTypes: completedTypes,
                    totalTypes: types.count,
                    recordCount: await sink.recordCount,
                    type: type,
                    entry: entry,
                    typeRecordCount: 0,
                    state: .exporting
                )
            )

            let report: DrainReport
            do {
                // A single type can hold millions of records, so progress is
                // reported per page rather than only when the type finishes.
                let completedSoFar = completedTypes
                let totalTypes = types.count
                report = try await coordinator.drain(
                    type: type,
                    batchLimit: batchSize,
                    maximumQueries: Self.maximumQueriesPerType
                ) { typeRecordCount in
                    await progress(
                        Self.progress(
                            completedTypes: completedSoFar,
                            totalTypes: totalTypes,
                            recordCount: await sink.recordCount,
                            type: type,
                            entry: entry,
                            typeRecordCount: typeRecordCount,
                            state: .exporting
                        )
                    )
                }
            } catch {
                let failure = HealthKitFailure.classify(
                    error,
                    typeIdentifier: type.rawValue
                )
                // Everything already written stays; only the failing page is
                // replayed on the next attempt.
                try await sink.seal()
                try await sink.recordFailure(
                    type: type,
                    coverage: failure.coverageState,
                    reason: failure.underlyingDescription
                )

                if failure.isTransient {
                    try await store.updateRun(
                        id: run.id,
                        state: .paused,
                        failureReason: failure.errorDescription
                    )
                    return .paused(
                        HealthExportPause(
                            runID: run.id,
                            reason: .deviceLocked,
                            completedTypeCount: completedTypes,
                            totalTypeCount: types.count,
                            recordCount: await sink.recordCount
                        )
                    )
                }

                failedTypes += 1
                completedTypes += 1
                try await sink.writeRecord([
                    "kind": "typeError",
                    "schemaVersion": 1,
                    "type": type.rawValue,
                    "coverage": failure.coverageState.rawValue,
                    "message": failure.underlyingDescription
                ])
                await progress(
                    Self.progress(
                        completedTypes: completedTypes,
                        totalTypes: types.count,
                        recordCount: await sink.recordCount,
                        type: type,
                        entry: entry,
                        typeRecordCount: 0,
                        state: .failed
                    )
                )
                try await recordEncodingErrors(for: type, runID: run.id)
                continue
            }

            switch report.completion {
            case .cancelled:
                try await sink.seal()
                try await store.updateRun(id: run.id, state: .paused)
                return .paused(
                    HealthExportPause(
                        runID: run.id,
                        reason: .checkpointed,
                        completedTypeCount: completedTypes,
                        totalTypeCount: types.count,
                        recordCount: await sink.recordCount
                    )
                )

            case .paused:
                // The pagination budget ran out, which means the stream never
                // reported exhaustion. That is a coverage gap, not success.
                try await sink.seal()
                try await sink.recordFailure(
                    type: type,
                    coverage: .tombstoneGapSuspected,
                    reason: "Reading \(type.rawValue) exceeded its safety limit."
                )
                failedTypes += 1
                completedTypes += 1
                try await sink.writeRecord([
                    "kind": "typeError",
                    "schemaVersion": 1,
                    "type": type.rawValue,
                    "coverage": CoverageState.tombstoneGapSuspected.rawValue,
                    "message": "Exceeded the per-type query budget."
                ])
                await progress(
                    Self.progress(
                        completedTypes: completedTypes,
                        totalTypes: types.count,
                        recordCount: await sink.recordCount,
                        type: type,
                        entry: entry,
                        typeRecordCount: 0,
                        state: .failed
                    )
                )

            case .anchorClosed:
                completedTypes += 1
                let isEmpty = report.changeCount == 0
                if isEmpty {
                    zeroResultTypes += 1
                } else {
                    nonEmptyTypes += 1
                }
                try await sink.writeRecord([
                    "kind": "typeSummary",
                    "schemaVersion": 1,
                    "type": type.rawValue,
                    "records": report.changeCount,
                    "queries": report.queryCount,
                    "encodingErrors": await encodingErrorCount(for: type),
                    "state": isEmpty
                        ? CoverageState.authorizationIndeterminate.rawValue
                        : CoverageState.anchorClosed.rawValue
                ])
                await progress(
                    Self.progress(
                        completedTypes: completedTypes,
                        totalTypes: types.count,
                        recordCount: await sink.recordCount,
                        type: type,
                        entry: entry,
                        typeRecordCount: report.changeCount,
                        state: isEmpty ? .indeterminate : .completed
                    )
                )
            }

            try await recordEncodingErrors(for: type, runID: run.id)

            if Task.isCancelled {
                try await sink.seal()
                try await store.updateRun(id: run.id, state: .paused)
                return .paused(
                    HealthExportPause(
                        runID: run.id,
                        reason: .checkpointed,
                        completedTypeCount: completedTypes,
                        totalTypeCount: types.count,
                        recordCount: await sink.recordCount
                    )
                )
            }
        }

        return try await finish(
            run: run,
            wasResumed: wasResumed,
            format: format,
            sink: sink,
            nonEmptyTypes: nonEmptyTypes,
            zeroResultTypes: zeroResultTypes,
            failedTypes: failedTypes
        )
    }

    // MARK: - Completion

    private func finish(
        run: ExportRunRecord,
        wasResumed: Bool,
        format: HealthExportFormat,
        sink: SpooledExportSink,
        nonEmptyTypes: Int,
        zeroResultTypes: Int,
        failedTypes: Int
    ) async throws -> HealthExportOutcome {
        // Read the durable total rather than this process's counter, so a run
        // that was resumed still accounts for errors sealed before relaunch.
        let encodingErrors = try await store.run(id: run.id)?
            .sampleEncodingErrorCount ?? 0
        try await sink.writeRecord([
            "kind": "completion",
            "schemaVersion": 1,
            "run": run.id.uuidString.lowercased(),
            "completedAt": Self.timestamp(.now),
            "records": await sink.recordCount,
            "attemptedTypes": types.count,
            "nonEmptyTypes": nonEmptyTypes,
            "catalogTypes": HealthTypeCatalog.entries.count,
            "zeroResultTypes": zeroResultTypes,
            "failedTypes": failedTypes,
            "sampleEncodingErrors": encodingErrors
        ])
        try await sink.seal()
        await sink.close()

        let spool = await store.spoolDirectory
        let finalName =
            "hozz-health-export-\(run.id.uuidString.lowercased()).\(format.fileExtension)"
        let finalURL = spool.appending(path: finalName)
        let recordCount = await sink.recordCount

        // The store, not the filesystem, decides whether a joined artifact
        // already accounts for a set of parts. When it does, that artifact
        // becomes the first member of any later join rather than being rebuilt
        // from parts it already absorbed.
        // A completed run is never resumed, and the artifact is recorded in
        // the same transaction that completes the run, so reaching here always
        // means the artifact still has to be built from the run's parts. Any
        // archive left on disk by an interrupted attempt is simply replaced.
        let parts = try await store.parts(runID: run.id)
            .sorted { $0.sequence < $1.sequence }
            .filter { $0.fileName != finalName }
        for part in parts {
            let url = spool.appending(path: part.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ExportPartJoinerError.missingPart(part.fileName)
            }
        }

        let byteCount = try assemble(
            run: run,
            format: format,
            parts: parts,
            spool: spool,
            finalURL: finalURL
        )
        try StoreLocation.harden(finalURL)
        try await store.completeRun(
            runID: run.id,
            fileName: finalName,
            byteCount: byteCount,
            recordCount: recordCount
        )
        // Only now are the parts unreferenced, so removing them cannot strand
        // an assembly that still needs them.
        for part in parts {
            try? FileManager.default.removeItem(
                at: spool.appending(path: part.fileName)
            )
        }

        return .completed(
            HealthExportResult(
                runID: run.id,
                fileURL: finalURL,
                recordCount: recordCount,
                attemptedTypeCount: types.count,
                nonEmptyTypeCount: nonEmptyTypes,
                catalogTypeCount: HealthTypeCatalog.entries.count,
                zeroResultTypeCount: zeroResultTypes,
                failedTypeCount: failedTypes,
                sampleEncodingErrorCount: encodingErrors,
                fileByteCount: byteCount,
                format: format,
                wasResumed: wasResumed
            )
        )
    }

    // MARK: - Helpers

    private func resolveRun(
        format: HealthExportFormat
    ) async throws -> (ExportRunRecord, Bool) {
        if let existing = try await store.resumableRun() {
            if existing.format == format.rawValue {
                try await store.updateRun(id: existing.id, state: .running)
                return (existing, true)
            }
            // A different format cannot append to the existing parts, so the
            // stale run is abandoned rather than silently mixed.
            try await discardRun(id: existing.id)
        }

        let run = try await store.createRun(
            format: format.rawValue,
            attemptedTypeCount: types.count,
            catalogVersion: HealthTypeCatalog.version
        )
        return (run, false)
    }

    private func settledStates(
        runID: UUID
    ) async throws -> [HealthTypeKey: StreamRecord] {
        let records = try await store.streamRecords(scope: .run(runID))
        return Dictionary(
            records
                .filter {
                    $0.anchorClosedAt != nil
                        && Self.settledCoverage.contains($0.coverage)
                }
                .map { ($0.type, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func encodingErrorCount(for type: HealthTypeKey) async -> Int {
        guard let healthKitSource = source as? HealthKitHealthDataSource else {
            return 0
        }
        return await healthKitSource.encodingErrorCount(for: type)
    }

    /// Persists the encoding errors seen while draining one type.
    ///
    /// Each type is drained at most once per engine, so the source's running
    /// count for that type is exactly this run's contribution.
    private func recordEncodingErrors(
        for type: HealthTypeKey,
        runID: UUID
    ) async throws {
        let count = await encodingErrorCount(for: type)
        guard count > 0 else {
            return
        }
        try await store.addEncodingErrors(runID: runID, count: count)
    }

    private static func progress(
        completedTypes: Int,
        totalTypes: Int,
        recordCount: Int,
        type: HealthTypeKey,
        entry: HealthCatalogEntry?,
        typeRecordCount: Int,
        state: HealthExportTypeState
    ) -> HealthExportProgress {
        HealthExportProgress(
            completedTypes: completedTypes,
            totalTypes: totalTypes,
            recordCount: recordCount,
            currentTypeIdentifier: type.rawValue,
            currentTypeName: entry?.displayName ?? type.rawValue,
            currentTypeFamily: entry?.family,
            currentTypeRecordCount: typeRecordCount,
            currentTypeState: state
        )
    }

    private static func timestamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        ).format(date)
    }

    private static func byteCount(of url: URL) throws -> UInt64 {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? NSNumber
        return size?.uint64Value ?? 0
    }

    /// Produces the single artifact a run hands to the user.
    ///
    /// A ZIP export cannot fold a previously produced archive back in as a
    /// member, because the archive is a container rather than a bare stream. It
    /// does not need to: every part is still on disk until the store records
    /// the archive, so the archive is simply rebuilt from the parts.
    private func assemble(
        run: ExportRunRecord,
        format: HealthExportFormat,
        parts: [ExportPartRecord],
        spool: URL,
        finalURL: URL
    ) throws -> UInt64 {
        let partURLs = parts.map { spool.appending(path: $0.fileName) }
        let baseName = "hozz-health-export-\(run.id.uuidString.lowercased())"

        switch format {
        case .raw:
            return try ExportPartJoiner.join(sourceURLs: partURLs, into: finalURL)

        case .ndjson:
            // The parts are already deflate-compressed, so this is a copy.
            return try inArchive(finalURL: finalURL, modifiedAt: run.startedAt) {
                archive in
                try archive.addEntry(
                    name: "\(baseName).ndjson",
                    copying: parts.map { part in
                        ZipMember(
                            url: spool.appending(path: part.fileName),
                            compressedByteCount: part.byteCount,
                            uncompressedByteCount: part.uncompressedByteCount,
                            crc32: part.crc32
                        )
                    }
                )
            }

        case .csv, .json, .markdown, .sqlite, .gpx:
            // These read every record back, so the spool is inflated once to a
            // scratch file and streamed from there.
            let plainURL = spool.appending(
                path: "transcode-\(UUID().uuidString.lowercased()).ndjson"
            )
            defer { try? FileManager.default.removeItem(at: plainURL) }
            try ExportPartInflater.inflate(partURLs: partURLs, into: plainURL)

            switch format {
            case .sqlite:
                // A database is not a container of files, so it is built
                // directly rather than placed inside an archive.
                try ExportSQLiteWriter.write(
                    readingFrom: plainURL,
                    to: finalURL,
                    metadata: ExportSQLiteWriter.Metadata(
                        runID: run.id,
                        startedAt: run.startedAt
                    )
                )
                return try Self.byteCount(of: finalURL)

            case .csv:
                return try inArchive(
                    finalURL: finalURL,
                    modifiedAt: run.startedAt
                ) { archive in
                    try ExportTranscoder.writeCSV(
                        readingFrom: plainURL,
                        into: archive
                    )
                }

            case .gpx:
                return try inArchive(
                    finalURL: finalURL,
                    modifiedAt: run.startedAt
                ) { archive in
                    try ExportGPXWriter.write(
                        readingFrom: plainURL,
                        into: archive,
                        metadata: ExportGPXWriter.Metadata(
                            runID: run.id,
                            startedAt: run.startedAt
                        )
                    )
                }

            case .markdown:
                return try inArchive(
                    finalURL: finalURL,
                    modifiedAt: run.startedAt
                ) { archive in
                    try ExportMarkdownWriter.write(
                        readingFrom: plainURL,
                        into: archive,
                        metadata: ExportMarkdownWriter.Metadata(
                            runID: run.id,
                            startedAt: run.startedAt
                        )
                    )
                }

            default:
                return try inArchive(
                    finalURL: finalURL,
                    modifiedAt: run.startedAt
                ) { archive in
                    try ExportTranscoder.writeJSON(
                        readingFrom: plainURL,
                        into: archive,
                        entryName: "\(baseName).json"
                    )
                }
            }
        }
    }

    /// Runs `body` against a new archive, abandoning it if anything throws so a
    /// half-written file is never left where a finished one belongs.
    private func inArchive(
        finalURL: URL,
        modifiedAt: Date,
        _ body: (ZipStreamWriter) throws -> Void
    ) throws -> UInt64 {
        let archive = try ZipStreamWriter(
            destinationURL: finalURL,
            modifiedAt: modifiedAt
        )
        do {
            try body(archive)
            return try archive.finish()
        } catch {
            archive.abandon()
            throw error
        }
    }
}
