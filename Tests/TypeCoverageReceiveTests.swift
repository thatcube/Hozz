import Foundation
import HozzCore
@testable import HozzReceive
import HozzStore
import XCTest

/// The receiver's half: reading coverage off the wire, keeping it, and being
/// able to say afterwards which of three things it knows.
final class TypeCoverageReceiveTests: XCTestCase {
    private var root: URL!
    private let steps = "HKQuantityTypeIdentifierStepCount"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "coverage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(_ name: String = "store") throws -> IngestStore {
        try IngestStore(directory: root.appending(path: name))
    }

    /// Bytes as a phone sends them, written out rather than produced by the
    /// encoder, so this checks the format on the wire and not the encoder's
    /// agreement with itself.
    private func coverageLine(
        type: String,
        state: String,
        complete: Bool,
        delivered: Int? = nil,
        observedAt: String,
        primedFrom: String? = nil,
        primedThrough: String? = nil
    ) -> String {
        var parts = [
            "\"kind\":\"typeCoverage\"",
            "\"type\":\"\(type)\"",
            "\"state\":\"\(state)\"",
            "\"complete\":\(complete)",
            "\"observedAt\":\"\(observedAt)\""
        ]
        if let delivered {
            parts.append("\"deliveredCount\":\(delivered)")
        }
        if let primedFrom {
            parts.append("\"primedFrom\":\"\(primedFrom)\"")
        }
        if let primedThrough {
            parts.append("\"primedThrough\":\"\(primedThrough)\"")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private func sampleLine(id: String, type: String, start: String) -> String {
        """
        {"kind":"quantity","id":"\(id)","type":"\(type)",\
        "startDate":"\(start)","endDate":"\(start)",\
        "quantity":{"value":1200,"unit":"count"}}
        """
    }

    // MARK: - Parsing

    func testACoverageLineIsReadAndIsNotMistakenForAMeasurement() throws {
        let batch = try BatchParser.parse(
            Data(
                coverageLine(
                    type: steps,
                    state: "anchorClosed",
                    complete: true,
                    delivered: 147_330,
                    observedAt: "2026-03-04T05:06:07.008Z"
                ).utf8
            )
        )

        XCTAssertEqual(batch.coverageReports.count, 1)
        XCTAssertEqual(batch.records.count, 0, "coverage is not a reading")
        XCTAssertEqual(batch.unhandled.count, 0)
        XCTAssertEqual(batch.unreadableCount, 0)

        let report = try XCTUnwrap(batch.coverageReports.first)
        XCTAssertEqual(report.type, steps)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.deliveredCount, 147_330)
    }

    /// A batch of nothing but coverage has told the receiver something it
    /// could not otherwise know. Answered as empty, the phone would resend the
    /// same fact for ever and the record would be quarantined every time.
    func testABatchOfOnlyCoverageIsNotAnEmptyBatch() throws {
        let batch = try BatchParser.parse(
            Data(
                coverageLine(
                    type: steps,
                    state: "draining",
                    complete: false,
                    observedAt: "2026-03-04T05:06:07.008Z"
                ).utf8
            )
        )
        XCTAssertFalse(batch.isEmpty)
    }

    func testAMalformedCoverageLineIsKeptRatherThanDropped() throws {
        let batch = try BatchParser.parse(
            Data(#"{"kind":"typeCoverage","state":"draining"}"#.utf8)
        )
        XCTAssertEqual(batch.coverageReports.count, 0)
        XCTAssertEqual(
            batch.unhandled.count,
            1,
            "a record nobody can interpret is still a record somebody sent"
        )
    }

    // MARK: - Storing

    func testAReportSurvivesTheTripAndComesBackWhole() async throws {
        let store = try makeStore()
        let payload = [
            sampleLine(id: "a", type: steps, start: "2023-01-14T09:00:00.000Z"),
            coverageLine(
                type: steps,
                state: "anchorClosed",
                complete: true,
                delivered: 147_330,
                observedAt: "2026-03-04T05:06:07.008Z"
            )
        ].joined(separator: "\n")

        let batch = try BatchParser.parse(Data(payload.utf8))
        let result = try await store.ingest(batch, idempotencyKey: "one")
        XCTAssertEqual(result.stored, 1)

        let held = try await store.coverage()
        let report = try XCTUnwrap(held[steps])
        XCTAssertEqual(report.state, .anchorClosed)
        XCTAssertEqual(report.deliveredCount, 147_330)
        let standing = try await store.coverageStanding(for: steps)
        XCTAssertTrue(standing.licensesLatestDate)
        await store.close()
    }

    /// Deliveries are retried and a folder of exports can be dropped on the
    /// receiver in any order, so an older statement can genuinely arrive after
    /// a newer one. The older one must not win.
    func testAnOlderReportArrivingLaterDoesNotUndoANewerOne() async throws {
        let store = try makeStore()

        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    coverageLine(
                        type: steps,
                        state: "anchorClosed",
                        complete: true,
                        delivered: 900,
                        observedAt: "2026-03-04T05:06:07.008Z"
                    ).utf8
                )
            ),
            idempotencyKey: "newer"
        )
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    coverageLine(
                        type: steps,
                        state: "draining",
                        complete: false,
                        delivered: 100,
                        observedAt: "2026-03-01T00:00:00.000Z"
                    ).utf8
                )
            ),
            idempotencyKey: "older"
        )

        let held = try await store.coverage()
        let report = try XCTUnwrap(held[steps])
        XCTAssertEqual(report.state, .anchorClosed)
        XCTAssertEqual(report.deliveredCount, 900)
        await store.close()
    }

    /// Coverage genuinely moves in both directions: widening a destination's
    /// date range replays its history, and a finished sweep opens again. What
    /// is forbidden is the *older* statement winning, not a backwards one.
    func testAFinishedTypeCanBeReopenedByANewerReport() async throws {
        let store = try makeStore()

        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    coverageLine(
                        type: steps,
                        state: "anchorClosed",
                        complete: true,
                        observedAt: "2026-03-01T00:00:00.000Z"
                    ).utf8
                )
            ),
            idempotencyKey: "finished"
        )
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    coverageLine(
                        type: steps,
                        state: "draining",
                        complete: false,
                        observedAt: "2026-03-09T00:00:00.000Z"
                    ).utf8
                )
            ),
            idempotencyKey: "replaying"
        )

        let standing = try await store.coverageStanding(for: steps)
        XCTAssertFalse(standing.licensesLatestDate)
        await store.close()
    }

    func testAPrimedWindowIsKeptAndReadBackToTheSecond() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    coverageLine(
                        type: steps,
                        state: "draining",
                        complete: false,
                        observedAt: "2026-03-04T05:06:07.008Z",
                        primedFrom: "2025-12-01T00:00:00.000Z",
                        primedThrough: "2026-02-28T00:00:00.000Z"
                    ).utf8
                )
            ),
            idempotencyKey: "primed"
        )

        let standing = try await store.coverageStanding(for: steps)
        let window = try XCTUnwrap(standing.primedWindow)
        // 2025-12-01T00:00:00Z and 2026-02-28T00:00:00Z as seconds, arrived at
        // without going back through the parser being checked.
        XCTAssertEqual(window.from.timeIntervalSince1970, 1_764_547_200, accuracy: 0.001)
        XCTAssertEqual(window.through.timeIntervalSince1970, 1_772_236_800, accuracy: 0.001)
        XCTAssertTrue(
            standing.hasGap,
            "a primed window with an unfinished sweep is two regions with a hole"
        )
        XCTAssertFalse(standing.licensesLatestDate)
        await store.close()
    }

    // MARK: - The three things a receiver can know

    func testNothingSaidIsNotTheSameAsSaidComplete() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    sampleLine(
                        id: "a",
                        type: steps,
                        start: "2023-01-14T09:00:00.000Z"
                    ).utf8
                )
            ),
            idempotencyKey: "just-a-sample"
        )

        let standing = try await store.coverageStanding(for: steps)
        XCTAssertEqual(standing, .untold)
        XCTAssertFalse(
            standing.licensesLatestDate,
            "a receiver told nothing knows nothing"
        )
        let nothing = try await store.coverage(for: steps)
        XCTAssertNil(nothing)
        await store.close()
    }

    func testTheThreeStandingsAreGenuinelyDistinct() {
        let complete = TypeCoverageReport(
            type: "t",
            state: .anchorClosed,
            observedAt: Date(timeIntervalSince1970: 0)
        )
        let incomplete = TypeCoverageReport(
            type: "t",
            state: .draining,
            observedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(TypeCoverageStanding(report: nil), .untold)
        XCTAssertEqual(TypeCoverageStanding(report: complete), .complete(complete))
        XCTAssertEqual(TypeCoverageStanding(report: incomplete), .incomplete(incomplete))
        XCTAssertEqual(
            [TypeCoverageStanding.untold, .complete(complete), .incomplete(incomplete)]
                .map(\.licensesLatestDate),
            [false, true, false]
        )
    }

    // MARK: - The upgrade

    /// The real path for anyone already running Hozz: a receiver at version 8,
    /// holding records, meeting a build that knows about coverage.
    ///
    /// The fixture is a full version-8 database with `type_coverage` removed,
    /// which is the whole of what the 8 → 9 step does. That shortcut would be
    /// hollow for a step that also moved rows — and the step above it does, so
    /// it is fixtured properly in `SchemaMigrationTests` — but here it
    /// exercises every statement the migration contains.
    func testAVersionEightReceiverGainsTheTableWithoutLosingRecords() async throws {
        let directory = root.appending(path: "v8")
        let databaseURL = directory.appending(path: "hozz-received.sqlite")

        let fresh = try makeStore("v8")
        _ = try await fresh.ingest(
            try BatchParser.parse(
                Data(
                    (0..<20).map {
                        sampleLine(
                            id: "s\($0)",
                            type: steps,
                            start: "2023-01-14T09:00:00.000Z"
                        )
                    }.joined(separator: "\n").utf8
                )
            ),
            idempotencyKey: "seed"
        )
        await fresh.close()

        do {
            let database = try SQLiteDatabase(url: databaseURL)
            defer { database.close() }
            try database.execute("DROP TABLE type_coverage")
            try database.execute("PRAGMA user_version = 8")
        }

        let upgraded = try IngestStore(directory: directory)
        let carried = try await upgraded.totalRecordCount()
        XCTAssertEqual(carried, 20)
        let beforeAnyReport = try await upgraded.coverage(for: steps)
        XCTAssertNil(beforeAnyReport)

        _ = try await upgraded.ingest(
            try BatchParser.parse(
                Data(
                    coverageLine(
                        type: steps,
                        state: "anchorClosed",
                        complete: true,
                        observedAt: "2026-03-04T05:06:07.008Z"
                    ).utf8
                )
            ),
            idempotencyKey: "after-upgrade"
        )
        let upgradedStanding = try await upgraded.coverageStanding(for: steps)
        XCTAssertTrue(upgradedStanding.licensesLatestDate)
        await upgraded.close()

        let version = try SQLiteDatabase(url: databaseURL)
            .query("PRAGMA user_version", row: { $0.integer(0) }).first
        XCTAssertEqual(version, 11)
    }

    /// A rolled-back attempt must leave the database at the version it was and
    /// still openable, so the next launch simply tries again.
    func testAnInterruptedUpgradeIsRetriedRatherThanWedging() async throws {
        let directory = root.appending(path: "interrupted")
        let databaseURL = directory.appending(path: "hozz-received.sqlite")

        let fresh = try makeStore("interrupted")
        await fresh.close()

        do {
            let database = try SQLiteDatabase(url: databaseURL)
            defer { database.close() }
            try database.execute("DROP TABLE type_coverage")
            try database.execute("PRAGMA user_version = 8")

            // The step starts and the process dies before the version moves.
            try database.execute("BEGIN IMMEDIATE;")
            try database.execute(
                "CREATE TABLE IF NOT EXISTS type_coverage (type TEXT PRIMARY KEY)"
            )
            try database.execute("ROLLBACK;")

            XCTAssertEqual(
                try database.query("PRAGMA user_version", row: { $0.integer(0) }).first,
                8,
                "a rolled-back step must not have advanced the version"
            )
        }

        let reopened = try IngestStore(directory: directory)
        _ = try await reopened.ingest(
            try BatchParser.parse(
                Data(
                    coverageLine(
                        type: steps,
                        state: "anchorClosed",
                        complete: true,
                        observedAt: "2026-03-04T05:06:07.008Z"
                    ).utf8
                )
            ),
            idempotencyKey: "after-retry"
        )
        let retriedStanding = try await reopened.coverageStanding(for: steps)
        XCTAssertTrue(
            retriedStanding.licensesLatestDate,
            "reopening after an interruption has to finish the job"
        )
        await reopened.close()
    }
}
