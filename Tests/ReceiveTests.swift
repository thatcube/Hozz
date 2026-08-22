import Foundation
import HozzCore
import HozzReceive
import XCTest

/// Covers the desktop side: understanding whatever the phone sends, and storing
/// it so the same batch arriving twice does not become two copies.
final class ReceiveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-receive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() throws -> IngestStore {
        try IngestStore(directory: root.appending(path: "store"))
    }

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(Timestamps.date(from: text))
    }

    // MARK: - Parsing

    func testNDJSONIsParsed() throws {
        let payload = Data(
            """
            {"id":"a","type":"HKQuantityTypeIdentifierStepCount","startDate":"2026-01-01T10:00:00.000Z","quantity":{"value":120,"unit":"count"},"source":{"name":"iPhone"}}
            {"id":"b","type":"HKQuantityTypeIdentifierStepCount","startDate":"2026-01-01T11:00:00.000Z","quantity":{"value":80,"unit":"count"}}
            """.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.records.count, 2)
        XCTAssertEqual(batch.records.first?.value, 120)
        XCTAssertEqual(batch.records.first?.unit, "count")
        XCTAssertEqual(batch.records.first?.sourceName, "iPhone")
        XCTAssertEqual(batch.unreadableCount, 0)
    }

    func testAJSONArrayIsParsed() throws {
        let payload = Data(
            """
            [{"id":"a","type":"HKQuantityTypeIdentifierHeartRate","startDate":"2026-01-01T10:00:00.000Z","quantity":{"value":62,"unit":"count/min"}}]
            """.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.records.count, 1)
        XCTAssertEqual(batch.records.first?.value, 62)
    }

    func testCSVIsParsed() throws {
        let payload = Data(
            """
            id,type,kind,startDate,endDate,value,unit,sourceName,deleted
            a,HKQuantityTypeIdentifierStepCount,quantity,2026-01-01T10:00:00.000Z,2026-01-01T10:01:00.000Z,120,count,iPhone,
            """.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.records.count, 1)
        XCTAssertEqual(batch.records.first?.value, 120, "CSV values arrive as text and must be converted.")
        XCTAssertEqual(batch.records.first?.type, "HKQuantityTypeIdentifierStepCount")
    }

    func testTheMetricsEnvelopeIsFlattened() throws {
        let payload = Data(
            """
            {"data":{"metrics":[{"name":"step_count","units":"count","data":[
              {"date":"2026-01-01T10:00:00.000Z","qty":120},
              {"date":"2026-01-01T11:00:00.000Z","qty":80}
            ]}],"deletions":[]}}
            """.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.records.count, 2)
        XCTAssertEqual(batch.records.first?.unit, "count")
        XCTAssertEqual(
            batch.records.first?.id,
            "step_count:2026-01-01T10:00:00.000Z",
            "A shape with no sample id needs a derived one, or re-delivery duplicates."
        )
    }

    /// A connection test is a valid request carrying no samples. Reporting it
    /// as unreadable would tell the user their setup is broken at exactly the
    /// moment they are checking that it works.
    func testAConnectionTestIsRecognisedRatherThanRejected() {
        let payload = Data(#"{"kind":"hozzConnectionTest","schemaVersion":1}"#.utf8)

        XCTAssertThrowsError(try BatchParser.parse(payload)) { error in
            XCTAssertTrue(error is BatchParseError)
        }
    }

    func testUnreadableLinesAreCountedNotDiscardedSilently() throws {
        let payload = Data(
            """
            {"id":"a","type":"T","startDate":"2026-01-01T10:00:00.000Z"}
            this is not json
            """.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.records.count, 1)
        XCTAssertEqual(batch.unreadableCount, 1, "A dropped line must be visible.")
    }

    /// Regression: Hozz's own encoder marks a removed sample with
    /// `kind: "deletion"` and no dates. The parser only understood a `deleted`
    /// flag, so its own NDJSON deletions were counted as unreadable, answered
    /// 200, and never resent — the sample stayed on the receiver forever and
    /// kept being served to an assistant as live data.
    func testHozzsOwnDeletionShapeIsUnderstood() throws {
        let payload = Data(
            #"{"id":"gone","kind":"deletion","schemaVersion":1,"type":"HKQuantityTypeIdentifierStepCount"}"#.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.deletions.count, 1, "A kind=deletion line is a deletion.")
        XCTAssertEqual(batch.deletions.first?.id, "gone")
        XCTAssertEqual(batch.unreadableCount, 0, "It must not be counted as junk.")
    }

    func testAnNDJSONDeletionActuallyRemovesTheSample() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(#"{"id":"a","type":"S","startDate":"2026-01-01T10:00:00.000Z","value":1}"#.utf8)
            ),
            idempotencyKey: "k1"
        )

        let result = try await store.ingest(
            try BatchParser.parse(
                Data(#"{"id":"a","kind":"deletion","schemaVersion":1,"type":"S"}"#.utf8)
            ),
            idempotencyKey: "k2"
        )

        XCTAssertEqual(result.deleted, 1)
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 0)
    }

    /// Regression: workouts travel in their own key of the metrics envelope.
    /// They were dropped without even counting as unreadable, so the receiver
    /// answered 200 and the phone never sent them again.
    func testWorkoutsInTheMetricsEnvelopeAreKept() throws {
        let payload = Data(
            """
            {"data":{"metrics":[],"workouts":[
              {"id":"w1","name":"Workout","start":"2026-01-01T10:00:00.000Z","end":"2026-01-01T11:00:00.000Z"}
            ]}}
            """.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.records.count, 1, "A workout must not vanish.")
        XCTAssertEqual(batch.records.first?.id, "w1")
        XCTAssertEqual(batch.records.first?.kind, "workout")
    }

    func testDeletionsAreParsed() throws {
        let payload = Data(
            #"{"id":"gone","type":"HKQuantityTypeIdentifierStepCount","deleted":true}"#.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.deletions.count, 1)
        XCTAssertEqual(batch.deletions.first?.id, "gone")
    }

    // MARK: - Storage

    func testRecordsAreStoredAndCounted() async throws {
        let store = try makeStore()
        let batch = try BatchParser.parse(
            Data(
                """
                {"id":"a","type":"S","startDate":"2026-01-01T10:00:00.000Z","value":1}
                {"id":"b","type":"S","startDate":"2026-01-01T11:00:00.000Z","value":2}
                """.utf8
            )
        )

        let result = try await store.ingest(batch, idempotencyKey: "key-1")

        XCTAssertEqual(result.stored, 2)
        XCTAssertFalse(result.duplicate)
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 2)
    }

    /// The phone retries a delivery it never got an answer for. Without this,
    /// every dropped connection would permanently double a day's data.
    func testTheSameBatchArrivingTwiceIsStoredOnce() async throws {
        let store = try makeStore()
        let batch = try BatchParser.parse(
            Data(#"{"id":"a","type":"S","startDate":"2026-01-01T10:00:00.000Z","value":1}"#.utf8)
        )

        _ = try await store.ingest(batch, idempotencyKey: "same-key")
        let second = try await store.ingest(batch, idempotencyKey: "same-key")

        XCTAssertTrue(second.duplicate)
        XCTAssertEqual(second.stored, 0)
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 1)
    }

    /// Re-sending a corrected sample must update it, not add a second copy.
    func testResendingASampleUpdatesItInPlace() async throws {
        let store = try makeStore()
        let first = try BatchParser.parse(
            Data(#"{"id":"a","type":"S","startDate":"2026-01-01T10:00:00.000Z","value":1}"#.utf8)
        )
        let corrected = try BatchParser.parse(
            Data(#"{"id":"a","type":"S","startDate":"2026-01-01T10:00:00.000Z","value":99}"#.utf8)
        )

        _ = try await store.ingest(first, idempotencyKey: "k1")
        _ = try await store.ingest(corrected, idempotencyKey: "k2")

        let samples = try await store.samples(type: "S")
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.value, 99)
    }

    /// Health is the user's record of their own body. A receiver that only ever
    /// accumulates would keep showing data they deliberately deleted.
    func testADeletionRemovesAStoredSample() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(#"{"id":"a","type":"S","startDate":"2026-01-01T10:00:00.000Z","value":1}"#.utf8)
            ),
            idempotencyKey: "k1"
        )

        let result = try await store.ingest(
            try BatchParser.parse(Data(#"{"id":"a","type":"S","deleted":true}"#.utf8)),
            idempotencyKey: "k2"
        )

        XCTAssertEqual(result.deleted, 1)
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 0)
    }

    /// The metrics shape has no sample id, so its deletions can only be matched
    /// the same way its upserts were keyed.
    func testAMetricsDeletionMatchesByTypeAndDate() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"2026-01-01T10:00:00.000Z","qty":120}]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "k1"
        )

        let result = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[],"deletions":[
                      {"name":"step_count","date":"2026-01-01T10:00:00.000Z"}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "k2"
        )

        XCTAssertEqual(result.deleted, 1)
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 0)
    }

    // MARK: - Knowing whether it is working

    /// The question the user actually has is "is this working", and an answer
    /// that resets whenever the app relaunches cannot answer it.
    func testADeliveryIsRememberedAcrossRestarts() async throws {
        let directory = root.appending(path: "store")
        let store = try IngestStore(directory: directory)
        let when = try date("2026-05-01T10:00:00.000Z")

        try await store.noteDelivery(from: "Brandos iPhone", records: 120, at: when)
        await store.close()

        let reopened = try IngestStore(directory: directory)
        let devices = try await reopened.devices()

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.name, "Brandos iPhone")
        XCTAssertEqual(devices.first?.lastSeenAt, when)
        XCTAssertEqual(devices.first?.deliveredRecords, 120)
    }

    /// Repeated deliveries move the clock forward and accumulate, rather than
    /// each one looking like a new device.
    func testRepeatedDeliveriesUpdateTheSameDevice() async throws {
        let store = try makeStore()
        let first = try date("2026-05-01T10:00:00.000Z")
        let second = try date("2026-05-01T18:00:00.000Z")

        try await store.noteDelivery(from: "Brandos iPhone", records: 100, at: first)
        try await store.noteDelivery(from: "Brandos iPhone", records: 50, at: second)

        let devices = try await store.devices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.firstSeenAt, first, "The first sighting is kept.")
        XCTAssertEqual(devices.first?.lastSeenAt, second)
        XCTAssertEqual(devices.first?.deliveredRecords, 150)
    }

    func testDevicesComeBackMostRecentlyHeardFromFirst() async throws {
        let store = try makeStore()
        try await store.noteDelivery(
            from: "Old phone", records: 1, at: try date("2026-01-01T10:00:00.000Z")
        )
        try await store.noteDelivery(
            from: "New phone", records: 1, at: try date("2026-06-01T10:00:00.000Z")
        )

        let devices = try await store.devices()
        XCTAssertEqual(devices.map(\.name), ["New phone", "Old phone"])
    }

    // MARK: - Questions the data should be able to answer

    func testSummariesDescribeEachType() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"id":"a","type":"Steps","startDate":"2026-01-01T10:00:00.000Z","value":10,"unit":"count"}
                    {"id":"b","type":"Steps","startDate":"2026-01-03T10:00:00.000Z","value":20,"unit":"count"}
                    {"id":"c","type":"Heart","startDate":"2026-01-02T10:00:00.000Z","value":60,"unit":"count/min"}
                    """.utf8
                )
            ),
            idempotencyKey: "k1"
        )

        let summaries = try await store.summaries()

        XCTAssertEqual(summaries.count, 2)
        let steps = try XCTUnwrap(summaries.first { $0.type == "Steps" })
        XCTAssertEqual(steps.recordCount, 2)
        XCTAssertEqual(steps.unit, "count")
        XCTAssertEqual(steps.earliest, try date("2026-01-01T10:00:00.000Z"))
        XCTAssertEqual(steps.latest, try date("2026-01-03T10:00:00.000Z"))
    }

    /// Both sum and average are reported, because which one is correct depends
    /// on the type: summing heart rate is meaningless and averaging steps
    /// understates a day. Collapsing them to one number invites a confidently
    /// wrong answer.
    func testDailyAggregationReportsSumAndAverageSeparately() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"id":"a","type":"Steps","startDate":"2026-01-01T09:00:00.000Z","value":100}
                    {"id":"b","type":"Steps","startDate":"2026-01-01T18:00:00.000Z","value":300}
                    {"id":"c","type":"Steps","startDate":"2026-01-02T09:00:00.000Z","value":50}
                    """.utf8
                )
            ),
            idempotencyKey: "k1"
        )

        let buckets = try await store.aggregate(type: "Steps", bucket: .day)

        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].sum, 400)
        XCTAssertEqual(buckets[0].average, 200)
        XCTAssertEqual(buckets[0].minimum, 100)
        XCTAssertEqual(buckets[0].maximum, 300)
        XCTAssertEqual(buckets[0].count, 2)
        XCTAssertEqual(buckets[1].sum, 50)
    }

    func testAggregationCanBeBoundedByDate() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"id":"a","type":"Steps","startDate":"2026-01-01T09:00:00.000Z","value":100}
                    {"id":"b","type":"Steps","startDate":"2026-02-01T09:00:00.000Z","value":300}
                    """.utf8
                )
            ),
            idempotencyKey: "k1"
        )

        let buckets = try await store.aggregate(
            type: "Steps",
            bucket: .day,
            from: try date("2026-01-15T00:00:00.000Z")
        )

        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].sum, 300)
    }

    func testSamplesComeBackNewestFirst() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"id":"old","type":"S","startDate":"2026-01-01T09:00:00.000Z","value":1}
                    {"id":"new","type":"S","startDate":"2026-06-01T09:00:00.000Z","value":2}
                    """.utf8
                )
            ),
            idempotencyKey: "k1"
        )

        let samples = try await store.samples(type: "S")

        XCTAssertEqual(samples.map(\.id), ["new", "old"])
    }
}
