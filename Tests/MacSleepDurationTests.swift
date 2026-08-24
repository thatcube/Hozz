import XCTest
@testable import HozzReceive
import HozzCore

/// The Mac's own sleep figures, which were the last surface still adding
/// overlapping records together.
///
/// Brandon's archive has 699 sleep records from a watch and 301 from a phone,
/// with 591 overlapping pairs between them, so this was not a theoretical
/// fault — every sleep figure the Mac drew was inflated.
final class MacSleepDurationTests: XCTestCase {
    private var directory: URL!
    private var store: IngestStore!

    override func setUpWithError() throws {
        directory = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        store = try IngestStore(directory: directory)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A day-granularity plan of `days` days beginning at `start`.
    private func dayPlan(from start: Date, days: Int) throws -> TimeBucketPlan {
        let end = try XCTUnwrap(
            calendar.date(byAdding: .day, value: days, to: start)
        )
        return TimeBucketPlan.covering(
            from: start,
            to: end,
            granularity: .day,
            calendar: calendar
        )
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    private func sleep(
        _ id: String,
        _ from: String,
        _ to: String,
        value: Int = 1
    ) -> [String: Any] {
        [
            "kind": "category",
            "id": id,
            "type": "HKCategoryTypeIdentifierSleepAnalysis",
            "startDate": from,
            "endDate": to,
            "value": value
        ]
    }

    private func ingest(_ objects: [[String: Any]]) async throws {
        let lines = objects.map {
            String(
                data: try! JSONSerialization.data(withJSONObject: $0),
                encoding: .utf8
            )!
        }.joined(separator: "\n")
        _ = try await store.ingest(
            try BatchParser.parse(Data(lines.utf8)),
            idempotencyKey: UUID().uuidString
        )
    }

    /// A night both devices recorded is reported once.
    ///
    /// 23:00 to 07:00 is eight hours by hand. Adding the two records gives
    /// fifteen, which is what the SQL sum produced and what a person would have
    /// read as an unusually good night.
    func testANightRecordedByTwoDevicesIsNotDoubled() async throws {
        try await ingest([
            sleep("watch", "2026-03-01T23:00:00Z", "2026-03-02T07:00:00Z"),
            sleep("phone", "2026-03-01T23:30:00Z", "2026-03-02T06:30:00Z")
        ])

        let series = try await store.series(
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            plan: try dayPlan(from: date("2026-03-01T00:00:00Z"), days: 3)
        )

        let total = series.columns.reduce(0) { $0 + $1.durationSeconds }
        XCTAssertEqual(total, 8 * 3_600, accuracy: 1)
    }

    /// A night is filed under the morning it ended, not the evening it began.
    ///
    /// This is the rule the phone's chart and the Markdown export already use.
    /// The Mac used to file on the start date, so the same night appeared on
    /// the previous day and the two surfaces disagreed about which Tuesday a
    /// night belonged to.
    func testANightIsFiledUnderTheMorningItEnded() async throws {
        try await ingest([
            sleep("night", "2026-03-01T23:00:00Z", "2026-03-02T07:00:00Z")
        ])

        let series = try await store.series(
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            plan: try dayPlan(from: date("2026-03-01T00:00:00Z"), days: 3)
        )

        let withSleep = series.columns.filter { $0.durationSeconds > 0 }
        XCTAssertEqual(withSleep.count, 1)
        XCTAssertEqual(
            withSleep.first?.start,
            date("2026-03-02T00:00:00Z"),
            "The sleeper woke on the 2nd, so the night is the 2nd's."
        )
    }

    /// Awake stretches inside a night are not sleep.
    ///
    /// Value 2 is awake. Counting it would inflate the night by the time spent
    /// staring at the ceiling, which is the opposite of what the figure means.
    func testAnAwakeStretchIsNotCountedAsSleep() async throws {
        try await ingest([
            sleep("asleep", "2026-03-01T23:00:00Z", "2026-03-02T07:00:00Z"),
            sleep("awake", "2026-03-02T03:00:00Z", "2026-03-02T04:00:00Z", value: 2)
        ])

        let series = try await store.series(
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            plan: try dayPlan(from: date("2026-03-01T00:00:00Z"), days: 3)
        )

        let total = series.columns.reduce(0) { $0 + $1.durationSeconds }
        XCTAssertEqual(
            total,
            8 * 3_600,
            accuracy: 1,
            "The awake hour sits inside the night; it neither adds nor removes."
        )
    }

    /// A stretch beginning before the window still lands in it.
    ///
    /// The query reads from before the first bucket precisely so a night that
    /// began the previous evening is not lost when it is filed on its end.
    func testANightBegunBeforeTheWindowIsStillCounted() async throws {
        try await ingest([
            sleep("night", "2026-02-28T23:00:00Z", "2026-03-01T07:00:00Z")
        ])

        let series = try await store.series(
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            plan: try dayPlan(from: date("2026-03-01T00:00:00Z"), days: 2)
        )

        let total = series.columns.reduce(0) { $0 + $1.durationSeconds }
        XCTAssertEqual(total, 8 * 3_600, accuracy: 1)
    }
}
