import Foundation
import HozzCore
import HozzReceive
import XCTest

/// Covers the bug that `aggregate_health_data` shipped with.
///
/// It grouped on `strftime('%Y-%m-%dT00:00:00Z', start_date)` — a *UTC* day.
/// On the maintainer's own archive that filed 27,858 of 147,330 records under
/// the wrong day, because he is in US Eastern and every evening sample after
/// about eight o'clock is already tomorrow in UTC. An assistant asked how many
/// steps he did on Tuesday was answering with a slice of Monday, which is the
/// same class of confidently-wrong answer this codebase exists to prevent.
///
/// The expectations here are worked out by hand from the fixture. Where a total
/// is checked it is also reconciled against the raw row count, so a bucketing
/// change cannot silently drop or duplicate a sample.
final class LocalDayAggregationTests: XCTestCase {
    private var root: URL!
    private let eastern = TimeZone(identifier: "America/New_York")!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = eastern
        return calendar
    }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-localday-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store(_ lines: [String]) async throws -> IngestStore {
        let store = try IngestStore(directory: root.appending(path: "store"))
        _ = try await store.ingest(
            try BatchParser.parse(Data(lines.joined(separator: "\n").utf8)),
            idempotencyKey: UUID().uuidString
        )
        return store
    }

    private func steps(_ id: String, _ utc: String, _ value: Double) -> String {
        """
        {"id":"\(id)","type":"HKQuantityTypeIdentifierStepCount",\
        "startDate":"\(utc)","endDate":"\(utc)",\
        "quantity":{"unit":"count","value":\(value)},"kind":"quantity"}
        """
    }

    private func localDate(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0
    ) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = eastern
        return try XCTUnwrap(calendar.date(from: components))
    }

    // MARK: - The bug itself

    /// An evening reading belongs to that evening.
    ///
    /// 20:00 Eastern on 15 June is 00:00 UTC on the 16th. Under the old
    /// grouping these two samples landed in different buckets on different
    /// days; they are one evening.
    func testEveningSamplesStayOnTheEveningTheyHappened() async throws {
        let store = try await store([
            steps("a", "2026-06-15T23:00:00.000Z", 100),  // 19:00 local
            steps("b", "2026-06-16T00:30:00.000Z", 200),  // 20:30 local, same day
            steps("c", "2026-06-16T03:00:00.000Z", 400)   // 23:00 local, same day
        ])

        let buckets = try await store.aggregate(
            type: "HKQuantityTypeIdentifierStepCount",
            bucket: .day,
            timeZone: eastern
        )

        XCTAssertEqual(buckets.count, 1, "one evening is one day")
        XCTAssertEqual(buckets[0].start, try localDate(2026, 6, 15))
        XCTAssertEqual(buckets[0].sum, 700, "100 + 200 + 400, added by hand")
        XCTAssertEqual(buckets[0].count, 3)

        // The same data in UTC really does split, so the fixture proves the
        // point rather than merely agreeing with the new code.
        let utcBuckets = try await store.aggregate(
            type: "HKQuantityTypeIdentifierStepCount",
            bucket: .day,
            timeZone: .gmt
        )
        XCTAssertEqual(utcBuckets.count, 2)
        XCTAssertEqual(utcBuckets.map(\.sum), [100, 600])
    }

    /// Half past midnight belongs to the day that just started.
    func testJustAfterLocalMidnightIsTheNewDay() async throws {
        let store = try await store([
            steps("a", "2026-06-15T04:30:00.000Z", 11),  // 00:30 local on the 15th
            steps("b", "2026-06-15T03:30:00.000Z", 22)   // 23:30 local on the 14th
        ])

        let buckets = try await store.aggregate(
            type: "HKQuantityTypeIdentifierStepCount",
            bucket: .day,
            timeZone: eastern
        )

        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].start, try localDate(2026, 6, 14))
        XCTAssertEqual(buckets[0].sum, 22)
        XCTAssertEqual(buckets[1].start, try localDate(2026, 6, 15))
        XCTAssertEqual(buckets[1].sum, 11)
    }

    /// The 23-hour day is one bucket.
    func testSpringForwardIsOneDay() async throws {
        let store = try await store([
            steps("a", "2026-03-08T05:30:00.000Z", 5),   // 00:30 EST
            steps("b", "2026-03-08T12:00:00.000Z", 7),   // 08:00 EDT
            steps("c", "2026-03-09T03:30:00.000Z", 9)    // 23:30 EDT, still the 8th
        ])

        let buckets = try await store.aggregate(
            type: "HKQuantityTypeIdentifierStepCount",
            bucket: .day,
            timeZone: eastern
        )

        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].start, try localDate(2026, 3, 8))
        XCTAssertEqual(buckets[0].sum, 21, "5 + 7 + 9")
        XCTAssertEqual(buckets[0].count, 3)
    }

    /// The 25-hour day is also one bucket, and the hour lived twice is not
    /// counted twice.
    func testFallBackIsOneDay() async throws {
        let store = try await store([
            steps("a", "2026-11-01T05:30:00.000Z", 3),   // 01:30 EDT
            steps("b", "2026-11-01T06:30:00.000Z", 4),   // 01:30 EST, an hour later
            steps("c", "2026-11-02T03:00:00.000Z", 5)    // 22:00 EST on the 1st
        ])

        let buckets = try await store.aggregate(
            type: "HKQuantityTypeIdentifierStepCount",
            bucket: .day,
            timeZone: eastern
        )

        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].start, try localDate(2026, 11, 1))
        XCTAssertEqual(buckets[0].sum, 12, "3 + 4 + 5")
        XCTAssertEqual(buckets[0].count, 3)
    }

    /// A week starts on a local weekday boundary, not on `%W`'s.
    func testWeekAndMonthBucketsStartLocally() async throws {
        let store = try await store([
            steps("a", "2026-06-01T03:30:00.000Z", 10),  // 23:30 local, 31 May
            steps("b", "2026-06-01T16:00:00.000Z", 20)   // 12:00 local, 1 June
        ])

        let months = try await store.aggregate(
            type: "HKQuantityTypeIdentifierStepCount",
            bucket: .month,
            timeZone: eastern
        )

        XCTAssertEqual(months.count, 2, "one sample is still in May, locally")
        XCTAssertEqual(months[0].start, try localDate(2026, 5, 1))
        XCTAssertEqual(months[0].sum, 10)
        XCTAssertEqual(months[1].start, try localDate(2026, 6, 1))
        XCTAssertEqual(months[1].sum, 20)

        let weeks = try await store.aggregate(
            type: "HKQuantityTypeIdentifierStepCount",
            bucket: .week,
            timeZone: eastern
        )
        for week in weeks {
            XCTAssertEqual(
                calendar.component(.weekday, from: week.start),
                calendar.firstWeekday,
                "a week must begin on the calendar's own first weekday"
            )
        }
    }

    // MARK: - Nothing lost, nothing duplicated

    /// Every sample lands in exactly one bucket, whatever the zone.
    ///
    /// Checked against a total counted independently of the bucketing — the
    /// fixture's own known size — so a boundary change cannot drop a sample at
    /// the edge or count it twice in two buckets.
    func testEverySampleLandsInExactlyOneBucket() async throws {
        var lines: [String] = []
        var expectedTotal: Double = 0
        // Hourly for a fortnight across the spring-forward weekend.
        var cursor = try XCTUnwrap(
            Timestamps.date(from: "2026-03-01T00:00:00.000Z")
        )
        for index in 0..<(24 * 14) {
            let value = Double(index % 7) + 1
            lines.append(steps("s\(index)", Timestamps.text(from: cursor), value))
            expectedTotal += value
            cursor = cursor.addingTimeInterval(3600)
        }
        let store = try await store(lines)

        for zone in [eastern, TimeZone.gmt, TimeZone(identifier: "Asia/Tokyo")!] {
            for bucket in [BucketSize.day, .week, .month] {
                let buckets = try await store.aggregate(
                    type: "HKQuantityTypeIdentifierStepCount",
                    bucket: bucket,
                    timeZone: zone
                )
                XCTAssertEqual(
                    buckets.reduce(0) { $0 + $1.count },
                    24 * 14,
                    "\(zone.identifier)/\(bucket.rawValue) lost or duplicated rows"
                )
                XCTAssertEqual(
                    buckets.reduce(0) { $0 + $1.sum },
                    expectedTotal,
                    accuracy: 1e-6,
                    "\(zone.identifier)/\(bucket.rawValue) total drifted"
                )
                // Buckets must not overlap, or a sample could be in two.
                for (earlier, later) in zip(buckets, buckets.dropFirst()) {
                    XCTAssertLessThan(earlier.start, later.start)
                }
            }
        }
    }

    /// A zone ahead of UTC splits differently from one behind it, and both are
    /// right for whoever is reading.
    func testZoneAheadOfUTCGroupsDifferentlyFromBehind() async throws {
        let store = try await store([
            // 09:00 UTC: still the 1st in Tokyo (18:00) and in New York (05:00).
            steps("a", "2026-06-01T09:00:00.000Z", 100),
            // 16:00 UTC: 2 June 01:00 in Tokyo, 1 June 12:00 in New York.
            steps("b", "2026-06-01T16:00:00.000Z", 200)
        ])

        let tokyo = try await store.aggregate(
            type: "HKQuantityTypeIdentifierStepCount",
            bucket: .day,
            timeZone: TimeZone(identifier: "Asia/Tokyo")!
        )
        XCTAssertEqual(tokyo.map(\.sum), [100, 200])

        let newYork = try await store.aggregate(
            type: "HKQuantityTypeIdentifierStepCount",
            bucket: .day,
            timeZone: eastern
        )
        XCTAssertEqual(newYork.map(\.sum), [300], "both are one day in New York")
    }

    // MARK: - The day index the statistics run on

    /// Consecutive local days are consecutive integers, including over a
    /// transition.
    ///
    /// This matters beyond labelling: `analyse_health_trend` fits a line
    /// against this number, so a step of 0.958 across the spring-forward day
    /// would tilt the slope for a reason that is not about anybody's health.
    func testLocalDayIndexStepsByExactlyOnePerDay() throws {
        var day = try localDate(2026, 3, 5, 12)
        var previous = LocalDayExpression.day(for: day, timeZone: eastern)

        for _ in 0..<10 {
            day = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
            let index = LocalDayExpression.day(for: day, timeZone: eastern)
            XCTAssertEqual(
                index - previous,
                1,
                "\(day) should be exactly one day after the last"
            )
            previous = index
        }
    }

    /// The index round-trips back to the start of the day it came from.
    func testLocalDayIndexRoundTripsToTheStartOfThatDay() throws {
        for (month, dayOfMonth) in [(3, 8), (11, 1), (6, 15), (1, 1)] {
            let midday = try localDate(2026, month, dayOfMonth, 12)
            let index = LocalDayExpression.day(for: midday, timeZone: eastern)
            let recovered = LocalDayExpression.date(
                forDay: index,
                timeZone: eastern
            )
            XCTAssertEqual(
                recovered,
                try localDate(2026, month, dayOfMonth),
                "round trip failed for \(month)/\(dayOfMonth)"
            )
        }
    }

    /// A zone that has never observed daylight saving still works.
    func testZoneWithoutDaylightSavingIsHandled() async throws {
        let phoenix = TimeZone(identifier: "America/Phoenix")!
        let store = try await store([
            steps("a", "2026-06-16T02:00:00.000Z", 40),  // 19:00 on the 15th
            steps("b", "2026-06-16T08:00:00.000Z", 60)   // 01:00 on the 16th
        ])

        let buckets = try await store.aggregate(
            type: "HKQuantityTypeIdentifierStepCount",
            bucket: .day,
            timeZone: phoenix
        )

        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets.map(\.sum), [40, 60])
    }

    /// An empty type is empty rather than a row of zeroes.
    func testNothingStoredGivesNoBuckets() async throws {
        let store = try await store([steps("a", "2026-06-15T12:00:00.000Z", 1)])
        let buckets = try await store.aggregate(
            type: "HKQuantityTypeIdentifierHeartRate",
            bucket: .day,
            timeZone: eastern
        )
        XCTAssertTrue(buckets.isEmpty)
    }

    /// A range narrower than a bucket still reports only what is inside it.
    func testExplicitBoundsAreHonouredInsideTheirBucket() async throws {
        let store = try await store([
            steps("a", "2026-06-15T13:00:00.000Z", 10),  // 09:00 local
            steps("b", "2026-06-15T22:00:00.000Z", 90)   // 18:00 local, same day
        ])

        let buckets = try await store.aggregate(
            type: "HKQuantityTypeIdentifierStepCount",
            bucket: .day,
            from: try localDate(2026, 6, 15, 12),
            timeZone: eastern
        )

        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(
            buckets[0].sum,
            90,
            "the morning sample is outside the requested range"
        )
        XCTAssertEqual(
            buckets[0].start,
            try localDate(2026, 6, 15),
            "the bucket still begins at midnight, as a day does"
        )
    }
}
