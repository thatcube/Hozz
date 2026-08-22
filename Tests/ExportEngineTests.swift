import Foundation
import HealthKit
import HozzAcquire
import HozzCore
import HozzHealth
import HozzHealthFake
import HozzStore
import XCTest

/// Proves the durability contract of a manual export: an interrupted run may
/// repeat work, but the artifact it produces must never omit a record and must
/// never contain one twice.
final class ExportEngineTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let steps = HealthTypeKey("HKQuantityTypeIdentifierStepCount")
    private let heartRate = HealthTypeKey("HKQuantityTypeIdentifierHeartRate")

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func makeStore() throws -> HozzStore {
        try HozzStore(directory: directory.url.appending(path: "store"))
    }

    private func upsert(_ identifier: String, type: HealthTypeKey) -> HealthChange {
        .upsert(
            CapturedHealthObject(
                id: UUID(),
                type: type,
                canonicalPayload: Data(
                    #"{"kind":"quantity","sample":"\#(identifier)"}"#.utf8
                )
            )
        )
    }

    private func sampleIdentifiers(in fileURL: URL) throws -> [String] {
        try ExportArtifactReader.records(in: fileURL)
            .compactMap { $0["sample"] as? String }
    }

    private func makeEngine(
        store: HozzStore,
        source: any HealthDataSource,
        types: [HealthTypeKey],
        batchSize: Int = 2
    ) -> HealthExportEngine {
        HealthExportEngine(
            store: store,
            source: source,
            types: types,
            batchSize: batchSize,
            lease: ExportWriterLease()
        )
    }

    // MARK: - Happy path

    func testACompleteRunWritesEverySampleExactlyOnce() async throws {
        let store = try makeStore()
        let stepChanges = (0..<7).map { upsert("step-\($0)", type: steps) }
        let heartChanges = (0..<3).map { upsert("heart-\($0)", type: heartRate) }
        let source = ScriptedHealthDataSource(
            streams: [steps: stepChanges, heartRate: heartChanges]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            types: [steps, heartRate]
        )

        let outcome = try await engine.export(format: .gzip) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }

        let identifiers = try sampleIdentifiers(in: result.fileURL)
        XCTAssertEqual(
            Set(identifiers),
            Set((0..<7).map { "step-\($0)" } + (0..<3).map { "heart-\($0)" })
        )
        XCTAssertEqual(identifiers.count, Set(identifiers).count)
        XCTAssertEqual(result.recordCount, 10)
        XCTAssertEqual(result.nonEmptyTypeCount, 2)
        XCTAssertFalse(result.wasResumed)
    }

    func testAnEmptyTypeIsReportedAsIndeterminateRatherThanComplete() async throws {
        let store = try makeStore()
        let source = ScriptedHealthDataSource(
            streams: [steps: [upsert("step-0", type: steps)], heartRate: []]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            types: [steps, heartRate]
        )

        let outcome = try await engine.export(format: .gzip) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }

        let summaries = try ExportArtifactReader.records(in: result.fileURL)
            .filter { $0["kind"] as? String == "typeSummary" }
        let heartSummary = summaries.first { $0["type"] as? String == heartRate.rawValue }

        XCTAssertEqual(result.zeroResultTypeCount, 1)
        XCTAssertEqual(
            heartSummary?["state"] as? String,
            CoverageState.authorizationIndeterminate.rawValue,
            "A type that returned nothing cannot be claimed as fully read."
        )
    }

    func testTheManifestRecordsCatalogScopedCoverage() async throws {
        let store = try makeStore()
        let source = ScriptedHealthDataSource(streams: [steps: []])
        let engine = makeEngine(store: store, source: source, types: [steps])

        let outcome = try await engine.export(format: .gzip) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }

        let manifest = try ExportArtifactReader.records(in: result.fileURL)
            .first { $0["kind"] as? String == "manifest" }
        XCTAssertEqual(manifest?["coverage"] as? String, "authorization-scoped")
        XCTAssertEqual(manifest?["attemptedTypes"] as? Int, 1)
    }

    // MARK: - The acceptance gate

    func testAKilledRunReplaysItsUnsealedPartWithoutGapsOrDuplicates() async throws {
        let store = try makeStore()
        let stepChanges = (0..<6).map { upsert("step-\($0)", type: steps) }
        let heartChanges = (0..<4).map { upsert("heart-\($0)", type: heartRate) }
        let source = ScriptedHealthDataSource(
            streams: [steps: stepChanges, heartRate: heartChanges]
        )

        // Drain one type into an open part and then simply stop, exactly as a
        // kill or a reboot would. Nothing is sealed, so nothing is durable.
        let run = try await store.createRun(
            format: HealthExportFormat.gzip.rawValue,
            attemptedTypeCount: 2,
            catalogVersion: "test"
        )
        let spool = await store.spoolDirectory
        let sink = SpooledExportSink(
            store: store,
            runID: run.id,
            format: .gzip,
            spoolDirectory: spool,
            nextSequence: 0,
            totalRecordCount: 0
        )
        let coordinator = DrainCoordinator(source: source, sink: sink)
        let report = try await coordinator.drain(type: steps, batchLimit: 2)
        XCTAssertEqual(report.completion, .anchorClosed)

        let uncommitted = try await store.committedAnchor(
            scope: .run(run.id),
            type: steps
        )
        XCTAssertNil(
            uncommitted,
            "An unsealed part must never advance a durable cursor."
        )
        let orphanURL = spool.appending(
            path: SpooledExportSink.partFileName(
                runID: run.id,
                sequence: 0,
                format: .gzip
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path))

        // A fresh engine over the same store is what relaunching looks like.
        let engine = makeEngine(
            store: store,
            source: source,
            types: [steps, heartRate]
        )
        let outcome = try await engine.export(format: .gzip) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The resumed run should have completed.")
        }

        let identifiers = try sampleIdentifiers(in: result.fileURL)
        XCTAssertEqual(
            Set(identifiers),
            Set((0..<6).map { "step-\($0)" } + (0..<4).map { "heart-\($0)" }),
            "No record may be missing after a kill."
        )
        XCTAssertEqual(
            identifiers.count,
            Set(identifiers).count,
            "No record may appear twice after a kill."
        )
        XCTAssertTrue(result.wasResumed)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphanURL.path),
            "The unsealed part must be swept, not shipped."
        )
    }

    func testASealedPartSurvivesAndIsNotRereadOnResume() async throws {
        let store = try makeStore()
        let stepChanges = (0..<4).map { upsert("step-\($0)", type: steps) }
        let heartChanges = (0..<4).map { upsert("heart-\($0)", type: heartRate) }
        let source = ScriptedHealthDataSource(
            streams: [steps: stepChanges, heartRate: heartChanges]
        )

        let run = try await store.createRun(
            format: HealthExportFormat.gzip.rawValue,
            attemptedTypeCount: 2,
            catalogVersion: "test"
        )
        let spool = await store.spoolDirectory
        let sink = SpooledExportSink(
            store: store,
            runID: run.id,
            format: .gzip,
            spoolDirectory: spool,
            nextSequence: 0,
            totalRecordCount: 0
        )
        let coordinator = DrainCoordinator(source: source, sink: sink)
        _ = try await coordinator.drain(type: steps, batchLimit: 2)
        try await sink.seal()

        let committed = try await store.committedAnchor(
            scope: .run(run.id),
            type: steps
        )
        XCTAssertNotNil(committed, "Sealing must make the cursor durable.")
        let queriesBeforeResume = await source.queryCount(for: steps)

        let engine = makeEngine(
            store: store,
            source: source,
            types: [steps, heartRate]
        )
        let outcome = try await engine.export(format: .gzip) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The resumed run should have completed.")
        }

        let queriesAfterResume = await source.queryCount(for: steps)
        let identifiers = try sampleIdentifiers(in: result.fileURL)

        XCTAssertEqual(
            queriesAfterResume,
            queriesBeforeResume,
            "A settled type must not be read again on resume."
        )
        XCTAssertEqual(
            Set(identifiers),
            Set((0..<4).map { "step-\($0)" } + (0..<4).map { "heart-\($0)" })
        )
        XCTAssertEqual(identifiers.count, Set(identifiers).count)
    }

    func testCancellationCheckpointsInsteadOfDiscarding() async throws {
        let store = try makeStore()
        let stepChanges = (0..<4).map { upsert("step-\($0)", type: steps) }
        let source = ScriptedHealthDataSource(
            streams: [steps: stepChanges, heartRate: []]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            types: [steps, heartRate]
        )

        let task = Task {
            try await engine.export(format: .gzip) { progress in
                if progress.currentTypeState == .completed {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        let outcome = try await task.value

        guard case .paused(let pause) = outcome else {
            return XCTFail("Cancelling mid-run must pause, not fail.")
        }
        XCTAssertEqual(pause.reason, .checkpointed)

        let resumable = try await engine.resumableRun()
        XCTAssertEqual(resumable?.id, pause.runID)
        XCTAssertEqual(resumable?.state, .paused)

        let resumed = try await engine.export(format: .gzip) { _ in }
        guard case .completed(let result) = resumed else {
            return XCTFail("The paused run should resume to completion.")
        }

        let identifiers = try sampleIdentifiers(in: result.fileURL)
        XCTAssertEqual(Set(identifiers), Set((0..<4).map { "step-\($0)" }))
        XCTAssertEqual(identifiers.count, Set(identifiers).count)
        XCTAssertTrue(result.wasResumed)
    }

    func testASourceFailureFailsOneTypeWithoutLosingTheOthers() async throws {
        let store = try makeStore()
        let stepChanges = (0..<4).map { upsert("step-\($0)", type: steps) }
        let heartChanges = (0..<2).map { upsert("heart-\($0)", type: heartRate) }
        let source = ScriptedHealthDataSource(
            streams: [steps: stepChanges, heartRate: heartChanges],
            faults: [steps: [1: .fail]]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            types: [steps, heartRate]
        )

        let outcome = try await engine.export(format: .gzip) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("One failing type must not abort the whole run.")
        }

        let records = try ExportArtifactReader.records(in: result.fileURL)
        let typeError = records.first { $0["kind"] as? String == "typeError" }
        let identifiers = records.compactMap { $0["sample"] as? String }

        XCTAssertEqual(result.failedTypeCount, 1)
        XCTAssertEqual(typeError?["type"] as? String, steps.rawValue)
        XCTAssertEqual(Set(identifiers), Set((0..<2).map { "heart-\($0)" }))
    }

    func testDeletionsAreWrittenAsTombstones() async throws {
        let store = try makeStore()
        let id = UUID()
        let source = ScriptedHealthDataSource(
            streams: [
                steps: [
                    .upsert(
                        CapturedHealthObject(
                            id: id,
                            type: steps,
                            canonicalPayload: Data(#"{"sample":"live"}"#.utf8)
                        )
                    ),
                    .delete(CapturedHealthDeletion(id: id, type: steps))
                ]
            ]
        )
        let engine = makeEngine(store: store, source: source, types: [steps], batchSize: 1)

        let outcome = try await engine.export(format: .gzip) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }

        let deletion = try ExportArtifactReader.records(in: result.fileURL)
            .first { $0["kind"] as? String == "deletion" }
        XCTAssertEqual(deletion?["id"] as? String, id.uuidString.lowercased())
        XCTAssertEqual(deletion?["type"] as? String, steps.rawValue)
    }

    func testDiscardingARunRemovesItsArtifactsAndCursors() async throws {
        let store = try makeStore()
        let source = ScriptedHealthDataSource(
            streams: [steps: (0..<3).map { upsert("step-\($0)", type: steps) }]
        )
        let engine = makeEngine(store: store, source: source, types: [steps])

        let outcome = try await engine.export(format: .gzip) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.fileURL.path))

        try await engine.discardRun(id: result.runID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: result.fileURL.path))
        let records = try await store.streamRecords(scope: .run(result.runID))
        XCTAssertTrue(records.isEmpty)
    }

    func testSweepingKeepsOnlyTheNewestFinishedExport() async throws {
        let store = try makeStore()
        let source = ScriptedHealthDataSource(
            streams: [steps: (0..<2).map { upsert("step-\($0)", type: steps) }]
        )
        let engine = makeEngine(store: store, source: source, types: [steps])

        guard
            case .completed(let first) = try await engine.export(format: .gzip, progress: { _ in })
        else {
            return XCTFail("The first run should have completed.")
        }
        // A second run drains nothing new, but it still produces its own
        // artifact in its own cursor space.
        guard
            case .completed(let second) = try await engine.export(format: .gzip, progress: { _ in })
        else {
            return XCTFail("The second run should have completed.")
        }
        XCTAssertNotEqual(first.runID, second.runID)

        let removed = try await ExportSpoolSweeper.sweep(store: store)

        XCTAssertGreaterThan(removed, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: first.fileURL.path),
            "An older finished export must not linger on the device."
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: second.fileURL.path),
            "The export a share sheet may still be offering must survive."
        )
    }

    func testSpooledPartsAreExcludedFromBackup() async throws {
        let store = try makeStore()
        let source = ScriptedHealthDataSource(
            streams: [steps: (0..<2).map { upsert("step-\($0)", type: steps) }]
        )
        let engine = makeEngine(store: store, source: source, types: [steps])

        guard
            case .completed(let result) = try await engine.export(format: .gzip, progress: { _ in })
        else {
            return XCTFail("The run should have completed.")
        }

        XCTAssertTrue(try StoreLocation.isExcludedFromBackup(result.fileURL))
    }

    // MARK: - Failures found by review

    /// A type that failed its authorization query records the same coverage as
    /// a stream that legitimately closed while empty. Only a recorded closure
    /// timestamp may settle a type, or a resume would skip a type that was
    /// never actually read to the end.
    func testAnAuthorizationFailureIsRetriedOnResumeRatherThanSettled() async throws {
        let store = try makeStore()
        let scripted = ScriptedHealthDataSource(
            streams: [steps: (0..<3).map { upsert("step-\($0)", type: steps) }]
        )
        let source = AuthorizationFailingSource(
            wrapped: scripted,
            failing: steps,
            failuresBeforeSucceeding: 1
        )
        let engine = makeEngine(store: store, source: source, types: [steps])

        guard
            case .completed(let first) = try await engine.export(format: .gzip, progress: { _ in })
        else {
            return XCTFail("A failing type must not abort the run.")
        }
        XCTAssertEqual(first.failedTypeCount, 1)

        let record = try await store.streamRecord(scope: .run(first.runID), type: steps)
        XCTAssertEqual(
            record?.coverage,
            .authorizationIndeterminate,
            "An authorization error and an empty stream share this coverage state."
        )
        XCTAssertNil(
            record?.anchorClosedAt,
            "A type that failed never reached an empty page, so it has no closure."
        )

        // The same run, resumed, must read the failed type again rather than
        // treating the indeterminate coverage as a finished stream.
        try await store.updateRun(id: first.runID, state: .paused)
        guard
            case .completed(let resumed) = try await engine.export(format: .gzip, progress: { _ in })
        else {
            return XCTFail("The resumed run should have completed.")
        }

        let identifiers = try sampleIdentifiers(in: resumed.fileURL)
        XCTAssertEqual(Set(identifiers), Set((0..<3).map { "step-\($0)" }))
        XCTAssertEqual(identifiers.count, Set(identifiers).count)
    }

    func testAnUnclassifiedFailureFailsOneTypeAndKeepsTheRest() async throws {
        let store = try makeStore()
        let stepChanges = (0..<3).map { upsert("step-\($0)", type: steps) }
        let source = ScriptedHealthDataSource(
            streams: [steps: stepChanges],
            faults: [steps: [1: .fail]]
        )
        let engine = makeEngine(store: store, source: source, types: [steps])

        guard
            case .completed(let first) = try await engine.export(format: .gzip, progress: { _ in })
        else {
            return XCTFail("A failing type must not abort the run.")
        }

        let record = try await store.streamRecord(scope: .run(first.runID), type: steps)
        XCTAssertEqual(first.failedTypeCount, 1)
        XCTAssertEqual(record?.coverage, .unknown)
        XCTAssertNil(record?.anchorClosedAt)
    }

    /// Two engines over one store must not both drive the same run: they would
    /// pick the same next part sequence and unlink each other's open file.
    func testASecondConcurrentExportIsRefused() async throws {
        let store = try makeStore()
        let source = ScriptedHealthDataSource(
            streams: [steps: (0..<2).map { upsert("step-\($0)", type: steps) }]
        )
        let lease = ExportWriterLease()
        let engine = HealthExportEngine(
            store: store,
            source: source,
            types: [steps],
            batchSize: 2,
            lease: lease
        )

        let acquired = await lease.acquire()
        XCTAssertTrue(acquired, "The lease should start free.")
        do {
            _ = try await engine.export(format: .gzip) { _ in }
            XCTFail("A second writer must be refused.")
        } catch HealthExportEngineError.exportAlreadyRunning {
            // Expected.
        }

        await lease.release()
        guard
            case .completed = try await engine.export(format: .gzip, progress: { _ in })
        else {
            return XCTFail("The export should run once the lease is free.")
        }
    }

    /// Finishing must be idempotent: a crash between publishing the joined file
    /// and marking the run completed must not join it into itself.
    func testFinishingTwiceDoesNotDuplicateTheJoinedArtifact() async throws {
        let store = try makeStore()
        let source = ScriptedHealthDataSource(
            streams: [steps: (0..<3).map { upsert("step-\($0)", type: steps) }]
        )
        let engine = makeEngine(store: store, source: source, types: [steps])

        guard
            case .completed(let first) = try await engine.export(format: .gzip, progress: { _ in })
        else {
            return XCTFail("The run should have completed.")
        }
        let firstIdentifiers = try sampleIdentifiers(in: first.fileURL)

        // Rewind only the run state, exactly as a crash after
        // `replacePartsWithFinalFile` but before the completion update would.
        try await store.updateRun(id: first.runID, state: .paused)
        guard
            case .completed(let second) = try await engine.export(format: .gzip, progress: { _ in })
        else {
            return XCTFail("The re-finished run should have completed.")
        }

        let secondIdentifiers = try sampleIdentifiers(in: second.fileURL)
        XCTAssertEqual(first.runID, second.runID)
        XCTAssertEqual(
            secondIdentifiers.count,
            Set(secondIdentifiers).count,
            "Re-finishing must not concatenate the artifact onto itself."
        )
        XCTAssertEqual(Set(secondIdentifiers), Set(firstIdentifiers))
    }

    /// The joiner leaves its inputs alone; only the engine removes them, and
    /// only after the store has recorded the joined artifact.
    func testNoScratchOrPartFilesSurviveACompletedRun() async throws {
        let store = try makeStore()
        let source = ScriptedHealthDataSource(
            streams: [steps: (0..<4).map { upsert("step-\($0)", type: steps) }]
        )
        // A tiny part budget forces several parts, so the join is a real join.
        let spool = await store.spoolDirectory
        let engine = HealthExportEngine(
            store: store,
            source: source,
            types: [steps],
            batchSize: 1,
            lease: ExportWriterLease(),
            sinkFactory: { runID, format, _, sequence, records in
                SpooledExportSink(
                    store: store,
                    runID: runID,
                    format: format,
                    spoolDirectory: spool,
                    nextSequence: sequence,
                    totalRecordCount: records,
                    partByteBudget: 1,
                    partRecordBudget: 1
                )
            }
        )

        guard
            case .completed(let result) = try await engine.export(format: .gzip, progress: { _ in })
        else {
            return XCTFail("The run should have completed.")
        }

        let identifiers = try sampleIdentifiers(in: result.fileURL)
        XCTAssertEqual(Set(identifiers), Set((0..<4).map { "step-\($0)" }))
        XCTAssertEqual(identifiers.count, Set(identifiers).count)

        let leftovers = try FileManager.default.contentsOfDirectory(
            at: spool,
            includingPropertiesForKeys: nil
        )
        .map(\.lastPathComponent)
        .filter { $0 != result.fileURL.lastPathComponent }
        XCTAssertTrue(
            leftovers.isEmpty,
            "A completed run must leave only its joined artifact: \(leftovers)"
        )
    }
}

/// Injects the HealthKit authorization error that shares a coverage state with
/// a legitimately empty stream, which no scripted fault can produce.
private actor AuthorizationFailingSource: HealthDataSource {
    private let wrapped: ScriptedHealthDataSource
    private let failing: HealthTypeKey
    private var remainingFailures: Int

    init(
        wrapped: ScriptedHealthDataSource,
        failing: HealthTypeKey,
        failuresBeforeSucceeding: Int
    ) {
        self.wrapped = wrapped
        self.failing = failing
        self.remainingFailures = failuresBeforeSucceeding
    }

    func changes(
        for type: HealthTypeKey,
        after anchor: AnchorToken?,
        limit: Int
    ) async throws -> HealthChangeBatch {
        if type == failing, remainingFailures > 0 {
            remainingFailures -= 1
            throw NSError(
                domain: HKError.errorDomain,
                code: HKError.Code.errorAuthorizationDenied.rawValue
            )
        }
        return try await wrapped.changes(for: type, after: anchor, limit: limit)
    }
}
