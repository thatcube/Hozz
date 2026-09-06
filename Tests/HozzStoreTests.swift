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

        // The point is that reopening does not re-run or skip a migration, not
        // that the schema sits at any particular number forever.
        XCTAssertGreaterThanOrEqual(version, 1)
        XCTAssertEqual(reopened, version)
    }

    func testCanonicalRecordVersionSurvivesClockRollbackAndReopen() async throws {
        let first = try await makeStore()
        let initial = try await first.nextCanonicalRecordVersion(
            id: "apple.healthkit:characteristics",
            observedAt: Date(timeIntervalSince1970: 100)
        )
        let rollback = try await first.nextCanonicalRecordVersion(
            id: "apple.healthkit:characteristics",
            observedAt: Date(timeIntervalSince1970: 50)
        )
        await first.close()

        let reopened = try await makeStore()
        let afterReopen = try await reopened.nextCanonicalRecordVersion(
            id: "apple.healthkit:characteristics",
            observedAt: Date(timeIntervalSince1970: 25)
        )

        XCTAssertEqual(initial, 100_000)
        XCTAssertEqual(rollback, initial + 1)
        XCTAssertEqual(afterReopen, rollback + 1)
    }

    func testVersionFourMigrationStartsAbovePriorExportTime() async throws {
        let first = try await makeStore()
        let databaseURL = await first.databaseURL
        await first.close()
        let legacy = try SQLiteDatabase(url: databaseURL)
        try legacy.transaction {
            try legacy.execute("DROP TABLE canonical_record_version;")
            try legacy.run(
                """
                INSERT INTO export_run
                    (id, state, format, started_at, updated_at, finished_at,
                     record_count, attempted_type_count, catalog_version,
                     sample_encoding_error_count)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                [
                    .text(UUID().uuidString),
                    .text("running"),
                    .text("ndjson"),
                    .real(202),
                    .real(100),
                    .null,
                    .integer(0),
                    .integer(0),
                    .text("test"),
                    .integer(0)
                ]
            )
            try legacy.execute("PRAGMA user_version = 3;")
        }
        legacy.close()

        let migrated = try await makeStore()
        let version = try await migrated.nextCanonicalRecordVersion(
            id: "apple.healthkit:characteristics",
            observedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(version, 202_001)
    }

    func testConcurrentFreshMigrationsAreIdempotent() async throws {
        let storeDirectory = directory.url.appending(path: "store")

        let stores = try await withThrowingTaskGroup(
            of: HozzStore.self,
            returning: [HozzStore].self
        ) { group in
            for _ in 0..<2 {
                group.addTask {
                    try HozzStore(directory: storeDirectory)
                }
            }
            var opened: [HozzStore] = []
            for try await store in group {
                opened.append(store)
            }
            return opened
        }

        for store in stores {
            let version = try await store.schemaVersion()
            XCTAssertEqual(version, 8)
            await store.close()
        }
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

    func testOmissionSealRollsBackWithAFailedCursorTransaction() async throws {
        let store = try await makeStore()
        let destinationID = UUID()
        let scope = AnchorScope.destination(destinationID)
        _ = try await store.saveDestination(
            id: destinationID,
            payload: Data("{}".utf8),
            createdAt: .now
        )
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
                        baseAnchor: anchor("a1"),
                        anchor: anchor("a2"),
                        coverage: .draining,
                        addedRecordCount: 1,
                        addedObservedCount: 1
                    ),
                    PendingAnchorCommit(
                        type: heartRate,
                        baseAnchor: anchor("wrong"),
                        anchor: anchor("bad"),
                        coverage: .draining,
                        addedRecordCount: 1,
                        addedObservedCount: 1
                    )
                ],
                prime: [],
                omissionSeal: DeliveryOmissionSeal(
                    destinationID: destinationID,
                    format: "metrics",
                    omittedRecordCount: 1
                ),
                scope: scope
            )
            XCTFail("The stale cursor must roll back the omission seal too.")
        } catch HozzStoreError.staleBaseAnchor {
            // Expected.
        }

        let stored = try await store.streamRecord(scope: scope, type: steps)
        let omissionFormats = try await store.deliveryOmissionFormats(
            for: destinationID
        )
        XCTAssertEqual(stored?.committedAnchor, anchor("a1"))
        XCTAssertTrue(omissionFormats.isEmpty)
    }

    func testStaleDestinationRevisionRejectsCursorAndOmissionTogether()
        async throws
    {
        let store = try await makeStore()
        let destinationID = UUID()
        let scope = AnchorScope.destination(destinationID)
        let first = try await store.saveDestination(
            id: destinationID,
            payload: Data(#"{"format":"metrics"}"#.utf8),
            createdAt: .now
        )
        let second = try await store.saveDestination(
            id: destinationID,
            payload: Data(#"{"format":"ndjson"}"#.utf8),
            createdAt: .now
        )
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(second.revision, 2)

        do {
            try await store.commit(
                [
                    PendingAnchorCommit(
                        type: steps,
                        baseAnchor: nil,
                        anchor: anchor("stale"),
                        coverage: .draining,
                        addedRecordCount: 1,
                        addedObservedCount: 1
                    )
                ],
                prime: [],
                omissionSeal: DeliveryOmissionSeal(
                    destinationID: destinationID,
                    format: "metrics",
                    omittedRecordCount: 1
                ),
                expectedDestinationRevision: first.revision,
                scope: scope
            )
            XCTFail("A stale destination snapshot must not advance its cursor.")
        } catch HozzStoreError.staleDestinationConfiguration(
            let id,
            let expected,
            let actual
        ) {
            XCTAssertEqual(id, destinationID)
            XCTAssertEqual(expected, first.revision)
            XCTAssertEqual(actual, second.revision)
        }

        let anchor = try await store.committedAnchor(scope: scope, type: steps)
        let formats = try await store.deliveryOmissionFormats(
            for: destinationID
        )
        XCTAssertNil(anchor)
        XCTAssertTrue(formats.isEmpty)
    }

    func testStaleDestinationRevisionRejectsStateAndReceiptWrites() async throws {
        let store = try await makeStore()
        let id = UUID()
        let original = try await store.saveDestination(
            id: id,
            payload: Data(#"{"format":"metrics"}"#.utf8),
            createdAt: .now
        )
        let current = try await store.saveDestination(
            id: id,
            payload: Data(#"{"format":"ndjson"}"#.utf8),
            createdAt: .now
        )
        let state = DeliveryStateRecord(
            destinationID: id,
            state: "idle",
            deliveredRecords: 7
        )
        let receipt = DeliveryReceiptRecord(
            destinationID: id,
            attemptedAt: Date(timeIntervalSince1970: 1),
            recordCount: 7,
            byteCount: 70,
            state: "delivered",
            detail: nil,
            artifactName: nil
        )
        try await store.saveDeliveryState(
            state,
            expectedDestinationRevision: current.revision
        )
        try await store.appendReceipt(
            receipt,
            expectedDestinationRevision: current.revision
        )
        try await store.validateDestinationRevision(
            id: id,
            expectedRevision: current.revision
        )

        for deleted in [false, true] {
            if deleted {
                try await store.deleteDestination(id: id)
            }
            let expectedActual: Int64? = deleted ? nil : current.revision
            do {
                try await store.saveDeliveryState(
                    DeliveryStateRecord(destinationID: id, state: "retrying"),
                    expectedDestinationRevision: original.revision
                )
                XCTFail("A stale state write must fail, including after deletion.")
            } catch HozzStoreError.staleDestinationConfiguration(
                let failedID, let expected, let actual
            ) {
                XCTAssertEqual(failedID, id)
                XCTAssertEqual(expected, original.revision)
                XCTAssertEqual(actual, expectedActual)
            }
            do {
                try await store.appendReceipt(
                    receipt,
                    keeping: 0,
                    expectedDestinationRevision: original.revision
                )
                XCTFail("A stale receipt must neither insert nor prune history.")
            } catch HozzStoreError.staleDestinationConfiguration(
                let failedID, let expected, let actual
            ) {
                XCTAssertEqual(failedID, id)
                XCTAssertEqual(expected, original.revision)
                XCTAssertEqual(actual, expectedActual)
            }
            let savedState = try await store.deliveryState(for: id)
            let receipts = try await store.receipts(for: id)
            XCTAssertEqual(savedState, deleted ? nil : state)
            XCTAssertEqual(receipts, deleted ? [] : [receipt])
        }
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
