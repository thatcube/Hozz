import Foundation
import SQLite3
import HozzAcquire
import HozzCore
import HozzHealthFake
import HozzStore
import XCTest
@testable import HozzHealth

/// What happens to an unfinished export when this build meets a stored word it
/// does not know.
///
/// Every unknown value here is written straight into the database rather than
/// produced by encoding today's types, for the same reason
/// `UnknownSettingTests` does it: a round trip can only ever contain values
/// this build already understands, which is exactly the case that was never in
/// doubt. The bug this file exists for — "Continue export" offered, tapped, and
/// failing — is invisible to a round-trip test.
final class UnfinishedExportTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let steps = HealthTypeKey("HKQuantityTypeIdentifierStepCount")

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func makeStore() throws -> HozzStore {
        try HozzStore(directory: directory.url.appending(path: "store"))
    }

    private func upsert(_ identifier: String) -> HealthChange {
        .upsert(
            CapturedHealthObject(
                id: UUID(),
                type: steps,
                canonicalPayload: Data(
                    #"{"kind":"quantity","sample":"\#(identifier)"}"#.utf8
                )
            )
        )
    }

    private func makeEngine(
        store: HozzStore,
        source: any HealthDataSource
    ) -> HealthExportEngine {
        HealthExportEngine(
            store: store,
            source: source,
            types: [steps],
            batchSize: 2,
            lease: ExportWriterLease()
        )
    }

    /// Leaves a genuine unfinished run behind, exactly as a kill would.
    @discardableResult
    private func leaveUnfinishedRun(
        store: HozzStore,
        format: HealthExportFormat = .ndjson
    ) async throws -> ExportRunRecord {
        let run = try await store.createRun(
            format: format.rawValue,
            attemptedTypeCount: 1,
            catalogVersion: "test"
        )
        let sink = SpooledExportSink(
            store: store,
            runID: run.id,
            format: format,
            spoolDirectory: await store.spoolDirectory,
            nextSequence: 0,
            totalRecordCount: 0
        )
        try await sink.writeRecord(["kind": "manifest", "schemaVersion": 1])
        try await sink.commit(
            HealthChangeBatch(
                changes: [upsert("s-0")],
                proposedAnchor: AnchorToken(data: Data([1]))
            ),
            for: steps,
            baseAnchor: nil
        )
        try await sink.seal()
        try await store.updateRun(id: run.id, state: .paused)
        let resumable = try await store.resumableRun()
        return try XCTUnwrap(resumable)
    }

    /// Writes a part state no build of Hozz has ever produced.
    private func writeUnknownPartState(
        store: HozzStore,
        runID: UUID,
        state: String = "verified"
    ) async throws {
        let databaseURL = await store.databaseURL
        await store.close()

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let sql = """
            UPDATE export_part SET state = '\(state)'
            WHERE run_id = '\(runID.uuidString.lowercased())';
            """
        XCTAssertEqual(
            sqlite3_exec(handle, sql, nil, nil, nil),
            SQLITE_OK,
            "The fixture must actually change the stored state."
        )
    }

    private func eraseArchiveContractVersion(
        store: HozzStore,
        runID: UUID,
        run: Bool = true,
        parts: Bool = true
    ) async throws {
        let databaseURL = await store.databaseURL
        await store.close()

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let runKey = runID.uuidString.lowercased()
        if run {
            XCTAssertEqual(
                sqlite3_exec(
                    handle,
                    "UPDATE export_run SET contract_version = NULL WHERE id = '\(runKey)';",
                    nil,
                    nil,
                    nil
                ),
                SQLITE_OK
            )
        }
        if parts {
            XCTAssertEqual(
                sqlite3_exec(
                    handle,
                    "UPDATE export_part SET contract_version = NULL WHERE run_id = '\(runKey)';",
                    nil,
                    nil,
                    nil
                ),
                SQLITE_OK
            )
        }
    }

    // MARK: - The bug

    /// The run was offered, the person tapped Continue, and it threw.
    func testARunWithAnUnknownPartStateIsNotOfferedAsContinuable() async throws {
        var store = try makeStore()
        let run = try await leaveUnfinishedRun(store: store)
        try await writeUnknownPartState(store: store, runID: run.id)

        store = try makeStore()
        let engine = makeEngine(
            store: store,
            source: ScriptedHealthDataSource(streams: [steps: [upsert("s-1")]])
        )

        let found = try await engine.resumableRun()
        let resumable = try XCTUnwrap(found)
        let obstruction = try await engine.resumeObstruction(for: resumable)

        XCTAssertNotNil(
            obstruction,
            "A part whose state cannot be read leaves the run undecidable."
        )
        XCTAssertTrue(
            try XCTUnwrap(obstruction).contains("cannot be continued safely")
        )
    }

    func testAPreContractRunIsRejectedWithoutDiscardingOwedWork() async throws {
        var store = try makeStore()
        let run = try await leaveUnfinishedRun(store: store)
        let partNames = try await store.partFileNames(runID: run.id)
        let storedStream = try await store.streamRecord(
            scope: .run(run.id),
            type: steps
        )
        let anchor = try XCTUnwrap(storedStream?.committedAnchor)
        try await eraseArchiveContractVersion(store: store, runID: run.id)

        store = try makeStore()
        let engine = makeEngine(
            store: store,
            source: ScriptedHealthDataSource(streams: [steps: [upsert("s-1")]])
        )
        let found = try await engine.resumableRun()
        let resumable = try XCTUnwrap(found)
        XCTAssertNil(resumable.contractVersion)
        let obstruction = try await engine.resumeObstruction(for: resumable)
        XCTAssertNotNil(obstruction)

        do {
            _ = try await engine.export(format: .ndjson) { _ in }
            XCTFail("A pre-contract run must not be resumed as strict v1.")
        } catch let error as HealthExportEngineError {
            XCTAssertEqual(
                error,
                .incompatibleContractVersion(
                    stored: nil,
                    supported: HozzHealthArchiveContract.schemaVersion
                )
            )
        }

        let preservedPartNames = try await store.partFileNames(runID: run.id)
        XCTAssertEqual(
            preservedPartNames,
            partNames,
            "Rejecting a legacy run must not discard sealed archive bytes."
        )
        let preservedStream = try await store.streamRecord(
            scope: .run(run.id),
            type: steps
        )
        XCTAssertEqual(
            preservedStream?.committedAnchor,
            anchor,
            "Rejecting a legacy run must not discard its acquisition cursor."
        )
        let preservedRun = try await store.resumableRun()
        XCTAssertEqual(preservedRun?.id, run.id)
    }

    func testAPreContractPartIsRejectedBeforeResumeMutatesTheRun() async throws {
        var store = try makeStore()
        let run = try await leaveUnfinishedRun(store: store)
        let partNames = try await store.partFileNames(runID: run.id)
        try await eraseArchiveContractVersion(
            store: store,
            runID: run.id,
            run: false
        )

        store = try makeStore()
        let engine = makeEngine(
            store: store,
            source: ScriptedHealthDataSource(streams: [steps: [upsert("s-1")]])
        )
        let found = try await engine.resumableRun()
        let resumable = try XCTUnwrap(found)
        XCTAssertEqual(
            resumable.contractVersion,
            HozzHealthArchiveContract.schemaVersion
        )
        let obstruction = try await engine.resumeObstruction(for: resumable)
        XCTAssertNotNil(obstruction)

        do {
            _ = try await engine.export(format: .ndjson) { _ in }
            XCTFail("A legacy part must be rejected before resume.")
        } catch let error as HealthExportEngineError {
            XCTAssertEqual(
                error,
                .incompatibleContractVersion(
                    stored: nil,
                    supported: HozzHealthArchiveContract.schemaVersion
                )
            )
        }

        let preservedPartNames = try await store.partFileNames(runID: run.id)
        XCTAssertEqual(preservedPartNames, partNames)
        let preservedRun = try await store.resumableRun()
        XCTAssertEqual(preservedRun?.state, .paused)
    }

    /// The stale run is found first on every attempt, so without this a build
    /// that met one could never export again — including a brand new export.
    func testAStuckRunDoesNotBlockEveryFutureExport() async throws {
        var store = try makeStore()
        let run = try await leaveUnfinishedRun(store: store)
        try await writeUnknownPartState(store: store, runID: run.id)

        store = try makeStore()
        let engine = makeEngine(
            store: store,
            source: ScriptedHealthDataSource(
                streams: [steps: (0..<4).map { upsert("fresh-\($0)") }]
            )
        )

        let outcome = try await engine.export(format: .ndjson) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("A fresh export must still be possible.")
        }

        XCTAssertFalse(
            result.wasResumed,
            "The unreadable run is abandoned rather than continued."
        )
        XCTAssertNotEqual(result.runID, run.id)
        let identifiers = try ExportArtifactReader.records(in: result.fileURL)
            .compactMap { $0["sample"] as? String }
        XCTAssertEqual(Set(identifiers).count, 4)
    }

    /// The same failure in a different disguise, and it was already there: an
    /// unknown format made the unfinished run vanish with nothing said.
    func testARunInAnUnknownFormatIsReportedRatherThanHidden() async throws {
        let store = try makeStore()
        let run = try await store.createRun(
            format: "parquet",
            attemptedTypeCount: 1,
            catalogVersion: "test"
        )
        try await store.updateRun(id: run.id, state: .paused)

        let engine = makeEngine(
            store: store,
            source: ScriptedHealthDataSource(streams: [steps: []])
        )
        let found = try await engine.resumableRun()
        let resumable = try XCTUnwrap(found)
        let obstruction = try await engine.resumeObstruction(for: resumable)

        XCTAssertEqual(
            resumable.id,
            run.id,
            "The run is still found, so it can be explained and discarded."
        )
        XCTAssertTrue(
            try XCTUnwrap(obstruction).contains("does not know")
        )
    }

    /// The escape hatch must not depend on the thing that is broken.
    ///
    /// Discarding used to read every part record, which meant a run nobody
    /// could continue was also a run nobody could get rid of — the Discard
    /// button failed with the same error as Continue, and the person was
    /// stuck with no way forward at all.
    func testAStuckRunCanStillBeDiscarded() async throws {
        var store = try makeStore()
        let run = try await leaveUnfinishedRun(store: store)
        try await writeUnknownPartState(store: store, runID: run.id)

        store = try makeStore()
        let engine = makeEngine(
            store: store,
            source: ScriptedHealthDataSource(streams: [steps: []])
        )

        try await engine.discardRun(id: run.id)

        let remaining = try await engine.resumableRun()
        XCTAssertNil(remaining, "Discarding must actually remove it.")
        let files = try FileManager.default.contentsOfDirectory(
            atPath: await store.spoolDirectory.path
        )
        XCTAssertTrue(
            files.filter { $0.contains(run.id.uuidString.lowercased()) }.isEmpty,
            "Its spool files go with it."
        )
    }

    // MARK: - What must not change

    func testAGenuinelyResumableRunIsStillOffered() async throws {
        var store = try makeStore()
        let run = try await leaveUnfinishedRun(store: store)

        store = try makeStore()
        let engine = makeEngine(
            store: store,
            source: ScriptedHealthDataSource(
                streams: [steps: [upsert("s-0"), upsert("s-1")]]
            )
        )

        let found = try await engine.resumableRun()
        let resumable = try XCTUnwrap(found)
        XCTAssertEqual(resumable.id, run.id)
        let obstruction = try await engine.resumeObstruction(for: resumable)
        XCTAssertNil(
            obstruction,
            "A run this build wrote and can read must stay resumable."
        )
    }

    /// The outcome that would be worse than the bug: an interrupted multi-hour
    /// export quietly starting over.
    func testAResumableRunStillContinuesRatherThanStartingOver() async throws {
        var store = try makeStore()
        let run = try await leaveUnfinishedRun(store: store)

        store = try makeStore()
        let engine = makeEngine(
            store: store,
            source: ScriptedHealthDataSource(
                streams: [steps: [upsert("s-0"), upsert("s-1")]]
            )
        )

        let outcome = try await engine.export(format: .ndjson) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }

        XCTAssertTrue(
            result.wasResumed,
            "Sealed work must be continued, never silently thrown away."
        )
        XCTAssertEqual(result.runID, run.id)
    }

    func testAStoreWithNoUnknownStatesReportsNone() async throws {
        let store = try makeStore()
        let run = try await leaveUnfinishedRun(store: store)

        let unknown = try await store.unrecognisedPartStates(runID: run.id)

        XCTAssertTrue(unknown.isEmpty)
    }

    func testAnUnknownStateIsReportedByItsStoredSpelling() async throws {
        var store = try makeStore()
        let run = try await leaveUnfinishedRun(store: store)
        try await writeUnknownPartState(
            store: store,
            runID: run.id,
            state: "quarantined"
        )

        store = try makeStore()
        let unknown = try await store.unrecognisedPartStates(runID: run.id)

        XCTAssertEqual(
            unknown,
            ["quarantined"],
            "Reading the raw string is the only way to ask without hitting the failure."
        )
    }
}
