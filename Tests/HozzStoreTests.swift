import Foundation
import HozzCore
import HozzStore
import XCTest

final class HozzStoreTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let steps = HealthTypeKey("HKQuantityTypeIdentifierStepCount")
    private let heartRate = HealthTypeKey("HKQuantityTypeIdentifierHeartRate")

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func makeStore() async throws -> HozzStore {
        try HozzStore(directory: directory.url.appending(path: "store"))
    }

    private func anchor(_ value: String) -> AnchorToken {
        AnchorToken(data: Data(value.utf8))
    }

    // MARK: - Schema and durability

    func testMigrationIsIdempotentAcrossOpens() async throws {
        let first = try await makeStore()
        let version = try await first.schemaVersion()
        await first.close()

        let second = try await makeStore()
        let reopened = try await second.schemaVersion()

        XCTAssertEqual(version, 1)
        XCTAssertEqual(reopened, version)
    }

    func testDatabaseAndSideFilesAreExcludedFromBackup() async throws {
        let store = try await makeStore()
        // Force a write so SQLite creates its write-ahead log beside the file.
        _ = try await store.createRun(
            format: "zip",
            attemptedTypeCount: 1,
            catalogVersion: "test"
        )
        try await store.hardenFiles()

        let databaseURL = await store.databaseURL
        let existing = StoreLocation.databaseFileURLs(for: databaseURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        XCTAssertTrue(existing.contains(databaseURL))
        XCTAssertTrue(
            existing.contains { $0.lastPathComponent.hasSuffix("-wal") },
            "The write-ahead log must exist so its exclusion can be proven."
        )
        for url in existing {
            XCTAssertTrue(
                try StoreLocation.isExcludedFromBackup(url),
                "\(url.lastPathComponent) must be excluded from device backups."
            )
        }
    }

    func testSpoolDirectoryIsExcludedFromBackup() async throws {
        let store = try await makeStore()
        let spool = await store.spoolDirectory

        XCTAssertTrue(try StoreLocation.isExcludedFromBackup(spool))
    }

    func testHardenedFilesRequestCompleteUnlessOpenProtection() async throws {
        let store = try await makeStore()
        let spool = await store.spoolDirectory
        let file = spool.appending(path: "protected.ndjson.gz")
        XCTAssertTrue(
            FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        )
        try StoreLocation.harden(file)

        // The simulator does not always report a protection class back, so an
        // absent value is tolerated; a wrong value is not.
        if let protection = try StoreLocation.protectionType(of: file) {
            XCTAssertEqual(protection, StoreLocation.protection)
        }
        XCTAssertTrue(try StoreLocation.isExcludedFromBackup(file))
    }

    // MARK: - Anchor commits

    func testCommitAdvancesAnchorAndAccumulatesCounts() async throws {
        let store = try await makeStore()
        let scope = AnchorScope.run(UUID())

        try await store.commit(
            [
                PendingAnchorCommit(
                    type: steps,
                    baseAnchor: nil,
                    anchor: anchor("a1"),
                    coverage: .draining,
                    addedRecordCount: 3,
                    addedObservedCount: 3
                )
            ],
            scope: scope
        )
        try await store.commit(
            [
                PendingAnchorCommit(
                    type: steps,
                    baseAnchor: anchor("a1"),
                    anchor: anchor("a2"),
                    coverage: .anchorClosed,
                    addedRecordCount: 2,
                    addedObservedCount: 2,
                    anchorClosedAt: Date(timeIntervalSince1970: 10)
                )
            ],
            scope: scope
        )

        let record = try await store.streamRecord(scope: scope, type: steps)
        XCTAssertEqual(record?.committedAnchor, anchor("a2"))
        XCTAssertEqual(record?.recordCount, 5)
        XCTAssertEqual(record?.observedCount, 5)
        XCTAssertEqual(record?.coverage, .anchorClosed)
        XCTAssertEqual(record?.anchorClosedAt, Date(timeIntervalSince1970: 10))
    }

    func testCommitWithAStaleBaseAnchorIsRejected() async throws {
        let store = try await makeStore()
        let scope = AnchorScope.run(UUID())

        try await store.commit(
            [
                PendingAnchorCommit(
                    type: steps,
                    baseAnchor: nil,
                    anchor: anchor("a1"),
                    coverage: .draining,
                    addedRecordCount: 1,
                    addedObservedCount: 1
                )
            ],
            scope: scope
        )

        do {
            try await store.commit(
                [
                    PendingAnchorCommit(
                        type: steps,
                        baseAnchor: nil,
                        anchor: anchor("a9"),
                        coverage: .draining,
                        addedRecordCount: 1,
                        addedObservedCount: 1
                    )
                ],
                scope: scope
            )
            XCTFail("A stale base anchor must be rejected.")
        } catch HozzStoreError.staleBaseAnchor(let type) {
            XCTAssertEqual(type, steps.rawValue)
        }

        let record = try await store.streamRecord(scope: scope, type: steps)
        XCTAssertEqual(record?.committedAnchor, anchor("a1"))
        XCTAssertEqual(record?.recordCount, 1)
    }

    func testAMixedBatchCommitsAllOrNothing() async throws {
        let store = try await makeStore()
        let scope = AnchorScope.run(UUID())

        do {
            try await store.commit(
                [
                    PendingAnchorCommit(
                        type: steps,
                        baseAnchor: nil,
                        anchor: anchor("ok"),
                        coverage: .draining,
                        addedRecordCount: 1,
                        addedObservedCount: 1
                    ),
                    PendingAnchorCommit(
                        type: heartRate,
                        // Wrong base: this type has no committed anchor yet.
                        baseAnchor: anchor("nonexistent"),
                        anchor: anchor("bad"),
                        coverage: .draining,
                        addedRecordCount: 1,
                        addedObservedCount: 1
                    )
                ],
                scope: scope
            )
            XCTFail("The batch must fail because one commit is stale.")
        } catch HozzStoreError.staleBaseAnchor {
            // Expected.
        }

        let stepsRecord = try await store.streamRecord(scope: scope, type: steps)
        let heartRecord = try await store.streamRecord(scope: scope, type: heartRate)
        XCTAssertNil(
            stepsRecord,
            "A rolled back transaction must not leave the healthy commit behind."
        )
        XCTAssertNil(heartRecord)
    }

    func testScopesDoNotShareAnchors() async throws {
        let store = try await makeStore()
        let runA = AnchorScope.run(UUID())
        let runB = AnchorScope.run(UUID())

        try await store.commit(
            [
                PendingAnchorCommit(
                    type: steps,
                    baseAnchor: nil,
                    anchor: anchor("a"),
                    coverage: .draining,
                    addedRecordCount: 1,
                    addedObservedCount: 1
                )
            ],
            scope: runA
        )

        let inB = try await store.committedAnchor(scope: runB, type: steps)
        let inGlobal = try await store.committedAnchor(scope: .global, type: steps)
        XCTAssertNil(inB)
        XCTAssertNil(inGlobal)
    }

    // MARK: - Runs and parts

    func testSealingAPartCommitsItsAnchorsAtomically() async throws {
        let store = try await makeStore()
        let run = try await store.createRun(
            format: "zip",
            attemptedTypeCount: 1,
            catalogVersion: "test"
        )
        _ = try await store.createPart(runID: run.id, sequence: 0, fileName: "p0")

        try await store.sealPart(
            runID: run.id,
            sequence: 0,
            byteCount: 1_234,
            uncompressedByteCount: 5_000,
            crc32: 0xDEAD_BEEF,
            recordCount: 7,
            commits: [
                PendingAnchorCommit(
                    type: steps,
                    baseAnchor: nil,
                    anchor: anchor("sealed"),
                    coverage: .draining,
                    addedRecordCount: 7,
                    addedObservedCount: 7
                )
            ],
            runRecordCount: 7
        )

        let part = try await store.part(runID: run.id, sequence: 0)
        let stored = try await store.streamRecord(scope: .run(run.id), type: steps)
        let updated = try await store.run(id: run.id)

        XCTAssertEqual(part?.state, .sealed)
        XCTAssertEqual(part?.byteCount, 1_234)
        XCTAssertEqual(stored?.committedAnchor, anchor("sealed"))
        XCTAssertEqual(updated?.recordCount, 7)
    }

    func testFailingToSealLeavesThePartOpenAndTheAnchorUnmoved() async throws {
        let store = try await makeStore()
        let run = try await store.createRun(
            format: "zip",
            attemptedTypeCount: 1,
            catalogVersion: "test"
        )
        _ = try await store.createPart(runID: run.id, sequence: 0, fileName: "p0")

        do {
            try await store.sealPart(
                runID: run.id,
                sequence: 0,
                byteCount: 10,
                uncompressedByteCount: 40,
                crc32: 0,
                recordCount: 1,
                commits: [
                    PendingAnchorCommit(
                        type: steps,
                        baseAnchor: anchor("wrong"),
                        anchor: anchor("next"),
                        coverage: .draining,
                        addedRecordCount: 1,
                        addedObservedCount: 1
                    )
                ],
                runRecordCount: 1
            )
            XCTFail("A stale anchor inside a seal must abort the whole seal.")
        } catch HozzStoreError.staleBaseAnchor {
            // Expected.
        }

        let part = try await store.part(runID: run.id, sequence: 0)
        let stored = try await store.streamRecord(scope: .run(run.id), type: steps)
        XCTAssertEqual(
            part?.state,
            .open,
            "A failed seal must not mark the part durable."
        )
        XCTAssertNil(stored)
    }

    func testDiscardingOpenPartsLeavesSealedPartsAlone() async throws {
        let store = try await makeStore()
        let run = try await store.createRun(
            format: "zip",
            attemptedTypeCount: 1,
            catalogVersion: "test"
        )
        _ = try await store.createPart(runID: run.id, sequence: 0, fileName: "p0")
        try await store.sealPart(
            runID: run.id,
            sequence: 0,
            byteCount: 1,
            uncompressedByteCount: 4,
            crc32: 0,
            recordCount: 1,
            commits: [],
            runRecordCount: 1
        )
        _ = try await store.createPart(runID: run.id, sequence: 1, fileName: "p1")

        let discarded = try await store.discardOpenParts(runID: run.id)
        let remaining = try await store.parts(runID: run.id)

        XCTAssertEqual(discarded.map(\.fileName), ["p1"])
        XCTAssertEqual(remaining.map(\.fileName), ["p0"])
    }

    func testResumableRunIgnoresFinishedRuns() async throws {
        let store = try await makeStore()
        let finished = try await store.createRun(
            format: "zip",
            attemptedTypeCount: 1,
            catalogVersion: "test"
        )
        try await store.updateRun(id: finished.id, state: .completed)

        let none = try await store.resumableRun()
        XCTAssertNil(none)

        let paused = try await store.createRun(
            format: "zip",
            attemptedTypeCount: 1,
            catalogVersion: "test"
        )
        try await store.updateRun(id: paused.id, state: .paused)

        let found = try await store.resumableRun()
        XCTAssertEqual(found?.id, paused.id)
    }

    func testDeletingARunAlsoDropsItsCursorSpace() async throws {
        let store = try await makeStore()
        let run = try await store.createRun(
            format: "zip",
            attemptedTypeCount: 1,
            catalogVersion: "test"
        )
        try await store.commit(
            [
                PendingAnchorCommit(
                    type: steps,
                    baseAnchor: nil,
                    anchor: anchor("a"),
                    coverage: .draining,
                    addedRecordCount: 1,
                    addedObservedCount: 1
                )
            ],
            scope: .run(run.id)
        )

        try await store.deleteRun(id: run.id)

        let records = try await store.streamRecords(scope: .run(run.id))
        let runs = try await store.allRuns()
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(runs.isEmpty)
    }

    func testReferencedFileNamesCoversPartsAndFinalArtifacts() async throws {
        let store = try await makeStore()
        let run = try await store.createRun(
            format: "zip",
            attemptedTypeCount: 1,
            catalogVersion: "test"
        )
        _ = try await store.createPart(runID: run.id, sequence: 0, fileName: "part-0")
        try await store.completeRun(
            runID: run.id,
            fileName: "final.zip",
            byteCount: 5,
            recordCount: 1
        )

        let referenced = try await store.referencedFileNames()
        let completed = try await store.run(id: run.id)
        XCTAssertEqual(referenced, ["final.zip"])
        XCTAssertEqual(
            completed?.state,
            .completed,
            "Publishing the artifact and finishing the run must be one step."
        )
    }
}
