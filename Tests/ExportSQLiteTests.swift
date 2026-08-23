import Foundation
import HozzAcquire
import HozzCore
import HozzHealthFake
import HozzStore
import XCTest
@testable import HozzHealth

/// The SQLite export exists so someone can ask questions across types and
/// years. These tests check the two things that makes true: every record the
/// spool held is in the file, and the queries a person would actually write
/// return the right answers and use an index.
final class ExportSQLiteTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let steps = HealthTypeKey("HKQuantityTypeIdentifierStepCount")
    private let heartRate = HealthTypeKey("HKQuantityTypeIdentifierHeartRate")

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    // MARK: - Fixtures

    private func write(lines: [[String: Any]]) throws -> URL {
        let url = directory.url.appending(path: "spool-\(UUID().uuidString).ndjson")
        var data = Data()
        for line in lines {
            data.append(
                try JSONSerialization.data(
                    withJSONObject: line,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
            )
            data.append(0x0A)
        }
        try data.write(to: url)
        return url
    }

    private func quantity(
        id: String = UUID().uuidString.lowercased(),
        type: String,
        start: String,
        value: Double,
        unit: String = "count",
        source: String = "Brandon's iPhone"
    ) -> [String: Any] {
        [
            "kind": "quantity",
            "schemaVersion": 1,
            "id": id,
            "type": type,
            "startDate": start,
            "endDate": start,
            "quantity": ["unit": unit, "value": value, "description": "\(value) \(unit)"],
            "source": [
                "name": source,
                "bundleIdentifier": "com.apple.health",
                "version": "1.0"
            ],
            "device": ["name": "iPhone", "manufacturer": "Apple Inc.", "model": "iPhone"],
            "metadata": ["HKWasUserEntered": ["type": "bool", "value": true]]
        ]
    }

    private func build(
        _ lines: [[String: Any]],
        timeZone: TimeZone = TimeZone(identifier: "America/New_York")!
    ) throws -> (url: URL, statistics: ExportSQLiteStatistics) {
        let source = try write(lines: lines)
        let destination = directory.url.appending(path: "export.sqlite")
        let statistics = try ExportSQLiteWriter.write(
            readingFrom: source,
            to: destination,
            metadata: ExportSQLiteWriter.Metadata(
                runID: UUID(),
                startedAt: Date(timeIntervalSince1970: 1_767_225_600),
                timeZone: timeZone
            )
        )
        return (destination, statistics)
    }

    private func open(_ url: URL) throws -> SQLiteDatabase {
        try SQLiteDatabase(url: url)
    }

    // MARK: - Shape

    func testEveryRecordKindLandsInATableThatFitsIt() throws {
        let workoutID = UUID().uuidString.lowercased()
        let (url, statistics) = try build([
            [
                "kind": "manifest",
                "schemaVersion": 1,
                "run": "run-1",
                "catalogVersion": 3,
                "createdAt": "2026-01-01T00:00:00.000Z",
                "coverage": "authorization-scoped",
                "attemptedTypes": 2,
                "catalogTypes": 100
            ],
            quantity(type: steps.rawValue, start: "2026-01-02T15:00:00.000Z", value: 400),
            quantity(type: steps.rawValue, start: "2026-01-02T18:00:00.000Z", value: 600),
            quantity(
                type: heartRate.rawValue,
                start: "2026-01-02T15:30:00.000Z",
                value: 58,
                unit: "count/min"
            ),
            [
                "kind": "category",
                "schemaVersion": 1,
                "id": UUID().uuidString.lowercased(),
                "type": "HKCategoryTypeIdentifierSleepAnalysis",
                "startDate": "2026-01-02T04:00:00.000Z",
                "endDate": "2026-01-02T11:00:00.000Z",
                "value": 1,
                "source": ["name": "Apple Watch", "bundleIdentifier": "com.apple.health"],
                "metadata": [:]
            ],
            [
                "kind": "workout",
                "schemaVersion": 1,
                "id": workoutID,
                "type": "HKWorkoutTypeIdentifier",
                "startDate": "2026-01-02T13:00:00.000Z",
                "endDate": "2026-01-02T13:45:00.000Z",
                "activityType": 37,
                "duration": 2_700.0,
                "events": [
                    [
                        "type": 1,
                        "startDate": "2026-01-02T13:20:00.000Z",
                        "endDate": "2026-01-02T13:20:00.000Z",
                        "metadata": [:]
                    ]
                ],
                "source": ["name": "Apple Watch", "bundleIdentifier": "com.apple.workout"],
                "metadata": [:]
            ],
            [
                "kind": "deletion",
                "schemaVersion": 1,
                "id": "deleted-1",
                "type": steps.rawValue
            ],
            [
                "kind": "sampleEncodingError",
                "schemaVersion": 1,
                "id": "broken-1",
                "type": heartRate.rawValue,
                "message": "No canonical unit."
            ],
            [
                "kind": "typeSummary",
                "schemaVersion": 1,
                "type": steps.rawValue,
                "records": 2,
                "queries": 1,
                "encodingErrors": 0,
                "state": "anchorClosed"
            ],
            [
                "kind": "completion",
                "schemaVersion": 1,
                "run": "run-1",
                "completedAt": "2026-01-03T00:00:00.000Z",
                "records": 7,
                "nonEmptyTypes": 3,
                "zeroResultTypes": 0,
                "failedTypes": 0,
                "sampleEncodingErrors": 1
            ]
        ])

        XCTAssertEqual(statistics.sampleRows, 4)
        XCTAssertEqual(statistics.workoutRows, 1)
        XCTAssertEqual(statistics.workoutEventRows, 1)
        XCTAssertEqual(statistics.deletionRows, 1)
        XCTAssertEqual(statistics.issueRows, 1)
        XCTAssertEqual(statistics.logRows, 3)
        XCTAssertEqual(statistics.unreadableLines, 0)
        XCTAssertEqual(statistics.collapsedDuplicates, 0)

        let database = try open(url)
        defer { database.close() }

        XCTAssertEqual(
            try database.query("PRAGMA user_version", row: { Int32($0.integer(0)) }).first,
            ExportSQLiteWriter.schemaVersion
        )
        XCTAssertEqual(
            try database.query("PRAGMA application_id", row: { Int32($0.integer(0)) }).first,
            ExportSQLiteWriter.applicationID,
            "A file that identifies itself can be recognised without opening it."
        )

        XCTAssertEqual(try scalar(database, "SELECT count(*) FROM sample"), 4)
        XCTAssertEqual(try scalar(database, "SELECT count(*) FROM workout"), 1)
        XCTAssertEqual(try scalar(database, "SELECT count(*) FROM workout_event"), 1)
        XCTAssertEqual(try scalar(database, "SELECT count(*) FROM deletion"), 1)
        XCTAssertEqual(try scalar(database, "SELECT count(*) FROM export_issue"), 1)
        XCTAssertEqual(try scalar(database, "SELECT count(*) FROM export_log"), 3)

        let events = try database.query(
            "SELECT workout_id, ordinal, type FROM workout_event",
            row: { ($0.text(0), $0.integer(1), $0.integer(2)) }
        )
        XCTAssertEqual(events.first?.0, workoutID)
        XCTAssertEqual(events.first?.2, 1)
    }

    /// The point of one wide table: two types in one query, with no knowledge
    /// of how many tables the export happened to produce.
    func testOneQueryCanCompareTwoTypesOverTheSamePeriod() throws {
        let (url, _) = try build([
            quantity(type: steps.rawValue, start: "2026-01-02T15:00:00.000Z", value: 400),
            quantity(type: steps.rawValue, start: "2026-01-02T18:00:00.000Z", value: 600),
            quantity(
                type: heartRate.rawValue,
                start: "2026-01-02T15:30:00.000Z",
                value: 58,
                unit: "count/min"
            )
        ])
        let database = try open(url)
        defer { database.close() }

        let rows = try database.query(
            """
            SELECT type, sum(value) FROM sample
             WHERE start_date >= ? AND start_date < ?
             GROUP BY type ORDER BY type
            """,
            [.text("2026-01-02T00:00:00.000Z"), .text("2026-01-03T00:00:00.000Z")],
            row: { ($0.text(0), $0.real(1)) }
        )

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.0, heartRate.rawValue)
        XCTAssertEqual(rows.first?.1, 58)
        XCTAssertEqual(rows.last?.1, 1_000)
    }

    /// A UTC day would file an evening workout in California under the next
    /// morning. The file says which zone it used, so the answer stays checkable.
    func testDaysAreBucketedInTheExportsTimeZoneAndTheZoneIsRecorded() throws {
        let (url, _) = try build(
            [
                // 20:00 in New York on the 2nd, which is the 3rd in UTC.
                quantity(type: steps.rawValue, start: "2026-01-03T01:00:00.000Z", value: 500)
            ],
            timeZone: TimeZone(identifier: "America/New_York")!
        )
        let database = try open(url)
        defer { database.close() }

        XCTAssertEqual(
            try text(database, "SELECT local_day FROM sample"),
            "2026-01-02"
        )
        XCTAssertEqual(
            try text(database, "SELECT value FROM meta WHERE key = 'time_zone'"),
            "America/New_York"
        )

        let daily = try database.query(
            "SELECT local_day, total FROM daily",
            row: { ($0.text(0), $0.real(1)) }
        )
        XCTAssertEqual(daily.first?.0, "2026-01-02")
        XCTAssertEqual(daily.first?.1, 500)
    }

    /// Workouts live in their own table, but a timeline question should not
    /// have to know that.
    func testTheRecordViewPutsWorkoutsBackOnTheSameTimeline() throws {
        let (url, _) = try build([
            quantity(type: steps.rawValue, start: "2026-01-02T15:00:00.000Z", value: 400),
            [
                "kind": "workout",
                "schemaVersion": 1,
                "id": UUID().uuidString.lowercased(),
                "type": "HKWorkoutTypeIdentifier",
                "startDate": "2026-01-02T13:00:00.000Z",
                "endDate": "2026-01-02T13:45:00.000Z",
                "activityType": 37,
                "duration": 2_700.0,
                "source": ["name": "Apple Watch", "bundleIdentifier": "com.apple.workout"],
                "metadata": [:]
            ]
        ])
        let database = try open(url)
        defer { database.close() }

        let rows = try database.query(
            "SELECT kind, type, value, unit FROM record ORDER BY start_date",
            row: { ($0.text(0), $0.text(1), $0.real(2), $0.text(3)) }
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.0, "workout")
        XCTAssertEqual(rows.first?.2, 2_700)
        XCTAssertEqual(rows.first?.3, "sec")
        XCTAssertEqual(rows.last?.0, "quantity")
    }

    // MARK: - Nothing lost

    /// The typed columns are a projection. The record itself has to survive
    /// them, or this format would be as lossy as CSV without saying so.
    func testEveryRowKeepsTheRecordItCameFrom() throws {
        let original = quantity(
            type: steps.rawValue,
            start: "2026-01-02T15:00:00.000Z",
            value: 400
        )
        let (url, _) = try build([original])
        let database = try open(url)
        defer { database.close() }

        let raw = try text(database, "SELECT raw FROM sample")
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        )

        XCTAssertEqual(decoded["type"] as? String, steps.rawValue)
        XCTAssertNotNil(
            decoded["metadata"] as? [String: Any],
            "Metadata has no column of its own, so it must still be in the record."
        )
        XCTAssertEqual(
            (decoded["device"] as? [String: Any])?["manufacturer"] as? String,
            "Apple Inc.",
            "A device field the schema does not project must survive anyway."
        )

        // The same claim, made the way a user would check it.
        XCTAssertEqual(
            try text(
                database,
                "SELECT json_extract(raw, '$.quantity.description') FROM sample"
            ),
            "400.0 count"
        )
    }

    /// The acquisition side emits one record holding every characteristic it
    /// read, keyed by type. This is that exact shape: if it changes, this test
    /// is where the two halves stop agreeing.
    func testACombinedCharacteristicsRecordFansOutIntoRows() throws {
        let (url, statistics) = try build([
            [
                "kind": "characteristics",
                "schemaVersion": 1,
                "catalogVersion": "2026.08.1",
                "readAt": "2026-01-02T15:00:00.000Z",
                "characteristics": [
                    "HKCharacteristicTypeIdentifierBloodType": [
                        "state": "read",
                        "value": "APositive",
                        "rawValue": 2
                    ],
                    "HKCharacteristicTypeIdentifierDateOfBirth": [
                        "state": "read",
                        "value": "1985-03-04"
                    ],
                    "HKCharacteristicTypeIdentifierBiologicalSex": [
                        "state": "notSet",
                        "coverage": "authorizationIndeterminate"
                    ]
                ]
            ]
        ])

        XCTAssertEqual(statistics.characteristicRows, 3)

        let database = try open(url)
        defer { database.close() }

        let rows = try database.query(
            "SELECT type, state, value, read_at FROM characteristic ORDER BY type",
            row: { ($0.text(0), $0.optionalText(1), $0.optionalText(2), $0.optionalText(3)) }
        )
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].0, "HKCharacteristicTypeIdentifierBiologicalSex")
        XCTAssertEqual(rows[0].1, "notSet")
        XCTAssertNil(
            rows[0].2,
            "A characteristic that was never set has no value to invent."
        )
        XCTAssertEqual(rows[1].0, "HKCharacteristicTypeIdentifierBloodType")
        XCTAssertEqual(rows[1].2, "APositive")
        XCTAssertEqual(rows[1].3, "2026-01-02T15:00:00.000Z")
        XCTAssertEqual(rows[2].2, "1985-03-04")

        // The fan-out is a projection, so the record itself still survives.
        let logged = try text(
            database,
            "SELECT raw FROM export_log WHERE kind = 'characteristics'"
        )
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(logged.utf8))
                as? [String: Any]
        )
        XCTAssertEqual(
            (decoded["characteristics"] as? [String: Any])?.count,
            3
        )
        XCTAssertEqual(decoded["catalogVersion"] as? String, "2026.08.1")
    }

    /// A single characteristic carrying its own type still works, so the table
    /// does not depend on which shape the encoder settles on.
    func testASingleCharacteristicRecordAlsoLands() throws {
        let (url, statistics) = try build([
            [
                "kind": "characteristic",
                "schemaVersion": 1,
                "id": "c-1",
                "type": "HKCharacteristicTypeIdentifierBloodType",
                "state": "read",
                "value": "ONegative"
            ]
        ])

        XCTAssertEqual(statistics.characteristicRows, 1)
        let database = try open(url)
        defer { database.close() }
        XCTAssertEqual(
            try text(database, "SELECT value FROM characteristic"),
            "ONegative"
        )
    }

    func testAnUnreadableLineIsKeptRatherThanSkipped() throws {
        let url = directory.url.appending(path: "broken.ndjson")
        var data = Data()
        data.append(
            try JSONSerialization.data(
                withJSONObject: quantity(
                    type: steps.rawValue,
                    start: "2026-01-02T15:00:00.000Z",
                    value: 400
                )
            )
        )
        data.append(0x0A)
        data.append(Data("{this is not json".utf8))
        data.append(0x0A)
        try data.write(to: url)

        let destination = directory.url.appending(path: "export.sqlite")
        let statistics = try ExportSQLiteWriter.write(
            readingFrom: url,
            to: destination,
            metadata: ExportSQLiteWriter.Metadata(runID: UUID(), startedAt: .now)
        )
        XCTAssertEqual(statistics.unreadableLines, 1)

        let database = try open(destination)
        defer { database.close() }
        XCTAssertEqual(try scalar(database, "SELECT count(*) FROM export_issue"), 1)
        XCTAssertEqual(
            try text(database, "SELECT value FROM meta WHERE key = 'unreadable_lines'"),
            "1"
        )
    }

    /// A type that returned nothing is a complete export of nothing, and the
    /// file has to be able to say so.
    func testTheFileReportsPerTypeCoverageIncludingEmptyTypes() throws {
        let (url, _) = try build([
            [
                "kind": "typeSummary",
                "schemaVersion": 1,
                "type": heartRate.rawValue,
                "records": 0,
                "queries": 1,
                "encodingErrors": 0,
                "state": "authorizationIndeterminate"
            ],
            [
                "kind": "typeError",
                "schemaVersion": 1,
                "type": steps.rawValue,
                "coverage": "failed",
                "message": "Health refused the read."
            ]
        ])
        let database = try open(url)
        defer { database.close() }

        let rows = try database.query(
            "SELECT type, state, message FROM export_type ORDER BY type",
            row: { ($0.text(0), $0.text(1), $0.optionalText(2)) }
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.0, heartRate.rawValue)
        XCTAssertEqual(rows.first?.1, "authorizationIndeterminate")
        XCTAssertEqual(rows.last?.1, "failed")
        XCTAssertEqual(rows.last?.2, "Health refused the read.")
    }

    func testTheFileDescribesItsOwnScope() throws {
        let (url, _) = try build([
            [
                "kind": "manifest",
                "schemaVersion": 1,
                "run": "run-1",
                "catalogVersion": 3,
                "createdAt": "2026-01-01T00:00:00.000Z",
                "coverage": "authorization-scoped",
                "attemptedTypes": 2,
                "catalogTypes": 100
            ],
            quantity(type: steps.rawValue, start: "2026-01-02T15:00:00.000Z", value: 400),
            quantity(type: steps.rawValue, start: "2026-03-09T15:00:00.000Z", value: 900)
        ])
        let database = try open(url)
        defer { database.close() }

        let meta = Dictionary(
            uniqueKeysWithValues: try database.query(
                "SELECT key, value FROM meta",
                row: { ($0.text(0), $0.text(1)) }
            )
        )
        XCTAssertEqual(meta["generator"], "Hozz")
        XCTAssertEqual(meta["coverage"], "authorization-scoped")
        XCTAssertEqual(meta["attempted_types"], "2")
        XCTAssertEqual(meta["catalog_types"], "100")
        XCTAssertEqual(meta["earliest_record"], "2026-01-02T15:00:00.000Z")
        XCTAssertEqual(meta["latest_record"], "2026-03-09T15:00:00.000Z")
        XCTAssertEqual(meta["sample_rows"], "2")

        let devices = try database.query(
            "SELECT name, record_count FROM device",
            row: { ($0.text(0), $0.integer(1)) }
        )
        XCTAssertEqual(devices.first?.0, "iPhone")
        XCTAssertEqual(devices.first?.1, 2)
    }

    // MARK: - Fast enough to be useful

    func testTheCommonQueriesUseAnIndex() throws {
        // A one-row table is correctly scanned rather than indexed, so this
        // asks the question at a size where the answer means something.
        var lines: [[String: Any]] = []
        for type in 0..<10 {
            for index in 0..<200 {
                lines.append(
                    quantity(
                        id: "sample-\(type)-\(index)",
                        type: "HKQuantityTypeIdentifierType\(type)",
                        start: String(
                            format: "2026-01-%02dT%02d:00:00.000Z",
                            (index % 28) + 1,
                            index % 24
                        ),
                        value: Double(index)
                    )
                )
            }
        }
        let (url, _) = try build(lines)
        let database = try open(url)
        defer { database.close() }

        let indexes = Set(
            try database.query(
                "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'",
                row: { $0.text(0) }
            )
        )
        XCTAssertTrue(indexes.contains("sample_type_start"))
        XCTAssertTrue(indexes.contains("sample_day_type"))
        XCTAssertTrue(indexes.contains("workout_start"))

        func plan(_ sql: String) throws -> String {
            try database.query("EXPLAIN QUERY PLAN \(sql)", row: { $0.text(3) })
                .joined(separator: " | ")
        }

        let typePlan = try plan(
            """
            SELECT * FROM sample
             WHERE type = 'HKQuantityTypeIdentifierType3'
               AND start_date BETWEEN '2026-01-05' AND '2026-01-09'
            """
        )
        XCTAssertTrue(
            typePlan.contains("sample_type_start"),
            "One type over a period must not scan the table: \(typePlan)"
        )

        let dayPlan = try plan(
            "SELECT sum(value) FROM sample WHERE local_day = '2026-01-05'"
        )
        XCTAssertTrue(
            dayPlan.contains("sample_day_type"),
            "A day's totals must not scan the table: \(dayPlan)"
        )
    }

    /// A full history does not fit in memory, so the load must never hold more
    /// than a bounded slice of it — regardless of how large the export is.
    func testALargeExportIsLoadedInBoundedBatchesRatherThanBuffered() throws {
        let recordCount = 12_000
        let url = directory.url.appending(path: "large.ndjson")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        var chunk = Data()
        for index in 0..<recordCount {
            chunk.append(
                try JSONSerialization.data(
                    withJSONObject: quantity(
                        id: "sample-\(index)",
                        type: steps.rawValue,
                        start: "2026-01-02T15:00:00.000Z",
                        value: Double(index)
                    ),
                    options: [.sortedKeys]
                )
            )
            chunk.append(0x0A)
            if chunk.count > 512 * 1_024 {
                try handle.write(contentsOf: chunk)
                chunk = Data()
            }
        }
        try handle.write(contentsOf: chunk)
        try handle.close()

        let spoolSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        ).intValue

        let destination = directory.url.appending(path: "large.sqlite")
        let statistics = try ExportSQLiteWriter.write(
            readingFrom: url,
            to: destination,
            metadata: ExportSQLiteWriter.Metadata(runID: UUID(), startedAt: .now),
            batchSize: 500
        )

        XCTAssertEqual(statistics.sampleRows, recordCount)
        XCTAssertEqual(statistics.collapsedDuplicates, 0)
        XCTAssertGreaterThan(spoolSize, 2 * 1_024 * 1_024)
        XCTAssertLessThan(
            statistics.peakUncommittedBytes,
            spoolSize / 8,
            """
            The load held \(statistics.peakUncommittedBytes) bytes of a \
            \(spoolSize) byte export at once, which is not streaming.
            """
        )

        let database = try open(destination)
        defer { database.close() }
        XCTAssertEqual(
            try scalar(database, "SELECT count(*) FROM sample"),
            recordCount
        )
    }

    // MARK: - Through the engine

    func testAnExportRunProducesADatabaseFile() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let source = ScriptedHealthDataSource(
            streams: [
                steps: (0..<5).map { index in
                    change(
                        quantity(
                            id: "step-\(index)",
                            type: steps.rawValue,
                            start: "2026-01-02T15:00:00.000Z",
                            value: Double(index)
                        ),
                        type: steps
                    )
                }
            ]
        )
        let engine = HealthExportEngine(
            store: store,
            source: source,
            types: [steps],
            batchSize: 2,
            lease: ExportWriterLease()
        )

        guard
            case .completed(let result) = try await engine.export(
                format: .sqlite,
                progress: { _ in }
            )
        else {
            return XCTFail("The run should have completed.")
        }

        XCTAssertEqual(result.fileURL.pathExtension, "sqlite")
        XCTAssertGreaterThan(result.fileByteCount, 0)

        let database = try open(result.fileURL)
        defer { database.close() }
        XCTAssertEqual(try scalar(database, "SELECT count(*) FROM sample"), 5)
        XCTAssertEqual(
            try text(database, "SELECT value FROM meta WHERE key = 'export_run'"),
            result.runID.uuidString.lowercased()
        )
    }

    /// An interrupted run resumes from its last sealed part, and the database
    /// is built from every part together. Each record must appear once.
    func testAResumedRunProducesADatabaseWithEveryRecordExactlyOnce() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let heart = heartRate
        let source = ScriptedHealthDataSource(
            streams: [
                steps: (0..<4).map { index in
                    change(
                        quantity(
                            id: "step-\(index)",
                            type: steps.rawValue,
                            start: "2026-01-02T15:00:00.000Z",
                            value: Double(index)
                        ),
                        type: steps
                    )
                },
                heart: (0..<4).map { index in
                    change(
                        quantity(
                            id: "heart-\(index)",
                            type: heart.rawValue,
                            start: "2026-01-02T16:00:00.000Z",
                            value: Double(60 + index),
                            unit: "count/min"
                        ),
                        type: heart
                    )
                }
            ]
        )
        let engine = HealthExportEngine(
            store: store,
            source: source,
            types: [steps, heart],
            batchSize: 2,
            lease: ExportWriterLease()
        )

        let task = Task {
            try await engine.export(format: .sqlite) { progress in
                if progress.currentTypeState == .completed {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        guard case .paused = try await task.value else {
            return XCTFail("Cancelling mid-run must pause, not fail.")
        }

        guard
            case .completed(let result) = try await engine.export(
                format: .sqlite,
                progress: { _ in }
            )
        else {
            return XCTFail("The paused run should resume to completion.")
        }
        XCTAssertTrue(result.wasResumed)

        let database = try open(result.fileURL)
        defer { database.close() }
        let identifiers = try database.query(
            "SELECT id FROM sample ORDER BY id",
            row: { $0.text(0) }
        )
        XCTAssertEqual(
            Set(identifiers),
            Set((0..<4).map { "step-\($0)" } + (0..<4).map { "heart-\($0)" })
        )
        XCTAssertEqual(identifiers.count, Set(identifiers).count)
    }

    /// Continuing a run in a different format throws away every part it had
    /// already sealed. That is correct — deflated NDJSON parts cannot be
    /// appended to under a different assembly — but it is also why the format
    /// of a resumable run is not the user's to change: the UI restores it from
    /// the run rather than from whatever the picker happens to be showing, or
    /// "Continue export" would silently start over.
    func testResumingInADifferentFormatStartsOverRatherThanContinuing() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let source = ScriptedHealthDataSource(
            streams: [
                steps: (0..<4).map { index in
                    change(
                        quantity(
                            id: "step-\(index)",
                            type: steps.rawValue,
                            start: "2026-01-02T15:00:00.000Z",
                            value: Double(index)
                        ),
                        type: steps
                    )
                },
                heartRate: (0..<4).map { index in
                    change(
                        quantity(
                            id: "heart-\(index)",
                            type: heartRate.rawValue,
                            start: "2026-01-02T16:00:00.000Z",
                            value: Double(60 + index),
                            unit: "count/min"
                        ),
                        type: heartRate
                    )
                }
            ]
        )
        let engine = HealthExportEngine(
            store: store,
            source: source,
            types: [steps, heartRate],
            batchSize: 2,
            lease: ExportWriterLease()
        )

        let task = Task {
            try await engine.export(format: .sqlite) { progress in
                if progress.currentTypeState == .completed {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        guard case .paused(let pause) = try await task.value else {
            return XCTFail("Cancelling mid-run must pause, not fail.")
        }
        let resumable = try await engine.resumableRun()
        XCTAssertEqual(resumable?.id, pause.runID)
        XCTAssertEqual(
            resumable?.format,
            HealthExportFormat.sqlite.rawValue,
            "The run remembers the format it was started in."
        )

        guard
            case .completed(let result) = try await engine.export(
                format: .ndjson,
                progress: { _ in }
            )
        else {
            return XCTFail("The run should have completed.")
        }

        XCTAssertFalse(
            result.wasResumed,
            "A different format cannot continue the sealed parts, so this is a new run."
        )
        XCTAssertNotEqual(
            result.runID,
            pause.runID,
            "The old run is discarded rather than silently mixed."
        )

        // Nothing is lost from Health itself: anchors are scoped to the run, so
        // a discarded run replays from the beginning and the new artifact still
        // holds every record.
        let identifiers = try ExportArtifactReader.records(in: result.fileURL)
            .compactMap { $0["id"] as? String }
            .filter { $0.hasPrefix("step-") || $0.hasPrefix("heart-") }
        XCTAssertEqual(
            Set(identifiers),
            Set((0..<4).map { "step-\($0)" } + (0..<4).map { "heart-\($0)" })
        )
    }

    // MARK: - Helpers

    private func change(
        _ object: [String: Any],
        type: HealthTypeKey
    ) -> HealthChange {
        .upsert(
            CapturedHealthObject(
                id: UUID(),
                type: type,
                canonicalPayload: try! JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
            )
        )
    }

    private func scalar(_ database: SQLiteDatabase, _ sql: String) throws -> Int {
        Int(try database.query(sql, row: { $0.integer(0) }).first ?? -1)
    }

    private func text(_ database: SQLiteDatabase, _ sql: String) throws -> String {
        try database.query(sql, row: { $0.text(0) }).first ?? ""
    }
}
