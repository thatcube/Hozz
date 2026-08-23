import Foundation
import HozzMCP
@testable import HozzReceive
import XCTest

/// State of Mind and medication doses reached the Mac as generic samples with
/// their real content only in `raw`, which is the state that made ECG answer
/// questions wrongly. Two outputs were flatly false: charting mood said there
/// were no records in a range holding forty of them, and every dose looked
/// identical whether it was taken or skipped.
final class MoodAndMedicationTests: XCTestCase {
    private var root: URL!
    private let day: TimeInterval = 86_400
    private let moodType = "HKStateOfMindTypeIdentifier"
    private let doseType = "HKMedicationDoseEventTypeIdentifier"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "mood-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func moodRecord(_ index: Int, valence: Double, at date: Date) -> [String: Any] {
        [
            "kind": "stateOfMind", "id": "som-\(index)", "type": moodType,
            "startDate": ISO8601DateFormatter().string(from: date),
            "endDate": ISO8601DateFormatter().string(from: date),
            "kindOfEntry": ["name": "dailyMood", "rawValue": 2],
            "valence": valence,
            "valenceClassification": [
                "name": valence < 0 ? "unpleasant" : "pleasant", "rawValue": 5
            ],
            "labels": [["name": "content", "rawValue": 1]],
            "associations": [["name": "work", "rawValue": 3]],
            "source": ["name": "iPhone"]
        ]
    }

    private func doseRecord(_ index: Int, status: String, at date: Date) -> [String: Any] {
        [
            "kind": "medicationDose", "id": "dose-\(index)", "type": doseType,
            "startDate": ISO8601DateFormatter().string(from: date),
            "endDate": ISO8601DateFormatter().string(from: date),
            "scheduleType": ["name": "scheduled", "rawValue": 1],
            "logStatus": ["name": status, "rawValue": index],
            "unit": "mg", "doseQuantity": 10.0,
            "medication": [
                "displayText": "Atorvastatin",
                "generalForm": ["name": "tablet", "rawValue": 2]
            ],
            "source": ["name": "iPhone"]
        ]
    }

    private func store(_ objects: [[String: Any]]) async throws -> IngestStore {
        let store = try IngestStore(directory: root.appending(path: "store"))
        var data = Data()
        for object in objects {
            data.append(
                try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys]
                )
            )
            data.append(0x0A)
        }
        _ = try await store.ingest(
            try BatchParser.parse(data),
            idempotencyKey: UUID().uuidString
        )
        return store
    }

    private func call(
        _ store: IngestStore,
        _ name: String,
        _ arguments: [String: Any] = [:]
    ) async throws -> String {
        let server = MCPServer(store: store)
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ]
        let payload = try JSONSerialization.data(withJSONObject: message)
        let response = await server.handle(payload)
        let reply = try XCTUnwrap(response)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        )
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }

    private func fortyDaysOfDecliningMood() -> [[String: Any]] {
        let base = Date.now.addingTimeInterval(-day)
        return (0..<40).map { index in
            moodRecord(
                index,
                valence: 0.6 - Double(index) * 0.03,
                at: base.addingTimeInterval(-Double(39 - index) * day)
            )
        }
    }

    // MARK: - Mood

    /// The question anyone actually asks of mood data, which previously got a
    /// false answer: the tool reported no records in a range holding forty.
    func testMoodCanBeChartedAndTrended() async throws {
        let store = try await store(fortyDaysOfDecliningMood())

        let trend = try await call(
            store,
            "analyse_health_trend",
            ["type": moodType, "days": 90]
        )
        XCTAssertTrue(trend.contains("Falling"), trend)
        XCTAssertTrue(trend.contains("40 days with data"), trend)
        XCTAssertFalse(
            trend.contains("none in the last"),
            "Forty entries sat in the window while this claimed there were none: \(trend)"
        )

        // It has to be comparable against other types too, which means it must
        // be an ordinary sample row with a real value.
        let aggregate = try await call(
            store,
            "aggregate_health_data",
            ["type": moodType, "bucket": "day"]
        )
        XCTAssertFalse(aggregate.contains("no records"), aggregate)
    }

    func testMoodKeepsWhatASingleColumnCannotHold() async throws {
        let store = try await store(fortyDaysOfDecliningMood())
        let text = try await call(store, "list_mood_entries", ["limit": 3])

        XCTAssertTrue(text.contains("dailyMood"), text)
        XCTAssertTrue(
            text.contains("unpleasant"),
            "How Health classified the feeling is part of the entry: \(text)"
        )
        XCTAssertTrue(text.contains("content"), "The labels survive: \(text)")
        XCTAssertTrue(text.contains("work"), "The associations survive: \(text)")
        XCTAssertTrue(
            text.contains("-1 (very unpleasant)"),
            "A bare valence needs its scale, or the number means nothing: \(text)"
        )
    }

    // MARK: - Medication

    /// The distinction that matters: only one of four statuses means the
    /// medicine was taken, and collapsing them answers the question wrongly.
    func testTheFourDoseStatusesStayDistinct() async throws {
        let base = Date.now.addingTimeInterval(-day)
        let store = try await store([
            doseRecord(0, status: "taken", at: base),
            doseRecord(1, status: "taken", at: base.addingTimeInterval(-day)),
            doseRecord(2, status: "skipped", at: base.addingTimeInterval(-2 * day)),
            doseRecord(3, status: "snoozed", at: base.addingTimeInterval(-3 * day)),
            doseRecord(4, status: "notAnswered", at: base.addingTimeInterval(-4 * day))
        ])

        let text = try await call(store, "summarise_medication_adherence")
        XCTAssertTrue(text.contains("Atorvastatin"), text)
        XCTAssertTrue(text.contains("taken: 2"), text)
        XCTAssertTrue(text.contains("skipped: 1"), text)
        XCTAssertTrue(text.contains("snoozed: 1"), text)
        XCTAssertTrue(text.contains("notAnswered: 1"), text)
        XCTAssertTrue(
            text.contains("only 'taken' means it was taken"),
            "The output must forbid collapsing the statuses: \(text)"
        )

        let adherence = try await store.medicationAdherence()
        XCTAssertEqual(adherence.first?.taken, 2)
        XCTAssertEqual(adherence.first?.total, 5)
    }

    /// A dose has no number to chart, so a row with an empty value in the
    /// generic sample list hides the only thing that matters about it.
    func testDosesDoNotAppearAsValuelessSamples() async throws {
        let store = try await store([
            doseRecord(0, status: "taken", at: Date.now.addingTimeInterval(-day))
        ])

        let samples = try await call(
            store,
            "list_health_samples",
            ["type": doseType]
        )
        XCTAssertTrue(samples.contains("No samples matched"), samples)
    }

    /// An unrecognised status is never guessed at, because every guess here is
    /// a claim about whether someone took their medicine.
    func testAnUnknownStatusIsRecordedAsUnrecordedRatherThanTaken() async throws {
        var record = doseRecord(0, status: "taken", at: Date.now.addingTimeInterval(-day))
        record["logStatus"] = ["rawValue": 9]
        let store = try await store([record])

        let adherence = try await store.medicationAdherence()
        XCTAssertEqual(adherence.first?.taken, 0)
        XCTAssertEqual(adherence.first?.statusCounts["unrecorded"], 1)
    }

    // MARK: - Honest absence, and fields not yet understood

    func testAnEmptyMoodWindowSaysItMayNotHaveSyncedYet() async throws {
        let store = try IngestStore(directory: root.appending(path: "store"))
        let text = try await call(store, "list_mood_entries")
        XCTAssertTrue(
            text.contains("not have arrived yet"),
            "Absent because unsynced is not absent because none exists: \(text)"
        )
    }

    /// Workout association has not landed on the phone yet. This is the
    /// guarantee it will rely on when it does: a field the receiver has never
    /// heard of survives on the sample it arrived with, so the link is
    /// preserved even before anything can query it as a column.
    func testAFieldTheReceiverDoesNotUnderstandSurvivesOnTheSample() async throws {
        let base = Date.now.addingTimeInterval(-day)
        let sample: [String: Any] = [
            "kind": "quantity", "id": "hr-1",
            "type": "HKQuantityTypeIdentifierHeartRate",
            "startDate": ISO8601DateFormatter().string(from: base),
            "endDate": ISO8601DateFormatter().string(from: base),
            "quantity": ["unit": "count/min", "value": 148.0],
            // The shape workout association is expected to take.
            "workout": ["id": "workout-1", "activityType": 37],
            "source": ["name": "Apple Watch"]
        ]
        let store = try await store([sample])

        let stored = try await store.samples(
            type: "HKQuantityTypeIdentifierHeartRate",
            limit: 5
        )
        let raw = try XCTUnwrap(stored.first?.raw)
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        )
        XCTAssertEqual(
            (decoded["workout"] as? [String: Any])?["id"] as? String,
            "workout-1",
            "A heart rate that knows it belongs to a run must keep knowing it."
        )
        XCTAssertEqual(stored.first?.value, 148)
    }
}
