import Foundation
import HozzCore
import HozzReceive
import XCTest

/// Covers every number the Mac dashboards put on screen.
///
/// A chart that renders beautifully and shows a wrong number is worse than no
/// chart, because someone will believe it. So each expectation here is worked
/// out by hand or by a second, independent method — never by calling the same
/// aggregation the test is supposed to be checking, which can only ever prove
/// the code agrees with itself.
final class HealthDashboardTests: XCTestCase {
    private var root: URL!

    /// A zone that observes daylight saving and sits behind UTC, so a mistake
    /// about local time shows up as a sample on the wrong day rather than
    /// hiding behind a zero offset.
    private let zone = TimeZone(identifier: "America/New_York")!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // Pinned so a machine set to a different first weekday does not move
        // every week boundary and fail tests that are actually about time.
        calendar.firstWeekday = 1
        return calendar
    }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-dash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    /// An instant written as UTC, so the test says exactly what it means and
    /// the local day is something the code has to work out.
    private func utc(_ text: String) throws -> Date {
        try XCTUnwrap(Timestamps.date(from: text))
    }

    /// An instant written as a local wall clock in `zone`.
    private func local(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0
    ) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = zone
        return try XCTUnwrap(calendar.date(from: components))
    }

    private func quantity(
        _ id: String,
        _ type: String,
        _ start: Date,
        _ value: Double,
        _ unit: String,
        end: Date? = nil,
        readings: Int? = nil
    ) -> [String: Any] {
        var measurement: [String: Any] = ["unit": unit, "value": value]
        if let readings {
            measurement["count"] = readings
            measurement["aggregatesSeries"] = true
        }
        return [
            "kind": "quantity", "id": id, "type": type,
            "startDate": Timestamps.text(from: start),
            "endDate": Timestamps.text(from: end ?? start),
            "quantity": measurement,
            "source": ["name": "Apple Watch"]
        ]
    }

    private func category(
        _ id: String,
        _ type: String,
        _ start: Date,
        _ value: Int,
        end: Date? = nil
    ) -> [String: Any] {
        [
            "kind": "category", "id": id, "type": type,
            "startDate": Timestamps.text(from: start),
            "endDate": Timestamps.text(from: end ?? start),
            "value": value,
            "source": ["name": "Apple Watch"]
        ]
    }

    private func store(_ objects: [[String: Any]]) async throws -> IngestStore {
        let store = try IngestStore(directory: root.appending(path: "store"))
        guard !objects.isEmpty else {
            return store
        }
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

    private func dayPlan(
        from start: Date,
        days: Int
    ) throws -> TimeBucketPlan {
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

    // MARK: - Local days, not UTC days

    /// An evening sample belongs to that evening, not to the next morning.
    ///
    /// 20:00 in New York on 15 June is 00:00 UTC on 16 June. Grouping on the
    /// stored timestamp's date puts an after-dinner walk on the following day,
    /// which is the mistake the Markdown exporter had to be taught not to make.
    func testEveningSampleStaysOnItsOwnLocalDay() async throws {
        let evening = try local(2026, 6, 15, 20, 0)
        XCTAssertEqual(
            Timestamps.text(from: evening),
            "2026-06-16T00:00:00.000Z",
            "the fixture is only meaningful if it really does cross UTC midnight"
        )

        let store = try await store([
            quantity("a", "HKQuantityTypeIdentifierStepCount", evening, 900, "count")
        ])

        let plan = try dayPlan(from: try local(2026, 6, 15), days: 2)
        let series = try await store.series(
            type: "HKQuantityTypeIdentifierStepCount",
            plan: plan
        )

        XCTAssertEqual(series.columns.count, 2)
        XCTAssertEqual(series.columns[0].total, 900)
        XCTAssertEqual(series.columns[0].sampleCount, 1)
        XCTAssertEqual(series.columns[1].sampleCount, 0, "16 June must be empty")
    }

    /// Midnight opens a day rather than closing the one before.
    func testSampleAtExactlyLocalMidnightOpensTheNewDay() async throws {
        let midnight = try local(2026, 6, 15, 0, 0)
        let lastMinute = try local(2026, 6, 14, 23, 59)

        let store = try await store([
            quantity("a", "HKQuantityTypeIdentifierStepCount", lastMinute, 10, "count"),
            quantity("b", "HKQuantityTypeIdentifierStepCount", midnight, 20, "count")
        ])

        let plan = try dayPlan(from: try local(2026, 6, 14), days: 2)
        let series = try await store.series(
            type: "HKQuantityTypeIdentifierStepCount",
            plan: plan
        )

        XCTAssertEqual(series.columns[0].total, 10)
        XCTAssertEqual(series.columns[1].total, 20)
    }

    /// The day the clocks go forward is 23 hours long and is still one day.
    ///
    /// On 8 March 2026 New York skips 02:00. A sample at 23:30 that evening is
    /// 03:30 UTC on 9 March, so any arithmetic that assumes 86,400-second days
    /// files it under the wrong date.
    func testSpringForwardDayKeepsItsOwnSamples() async throws {
        let early = try local(2026, 3, 8, 0, 30)
        let late = try local(2026, 3, 8, 23, 30)
        XCTAssertEqual(Timestamps.text(from: late), "2026-03-09T03:30:00.000Z")

        let store = try await store([
            quantity("a", "HKQuantityTypeIdentifierStepCount", early, 100, "count"),
            quantity("b", "HKQuantityTypeIdentifierStepCount", late, 250, "count")
        ])

        let plan = try dayPlan(from: try local(2026, 3, 8), days: 2)
        let series = try await store.series(
            type: "HKQuantityTypeIdentifierStepCount",
            plan: plan
        )

        XCTAssertEqual(series.columns[0].total, 350, "both belong to 8 March")
        XCTAssertEqual(series.columns[0].daysWithData, 1)
        XCTAssertEqual(series.columns[1].sampleCount, 0)

        // 23 hours of elapsed time, still one calendar day.
        let elapsed = series.columns[0].end.timeIntervalSince(series.columns[0].start)
        XCTAssertEqual(elapsed, 23 * 3600, accuracy: 1)
        XCTAssertEqual(series.columns[0].dayCount, 1)
    }

    /// The day the clocks go back is 25 hours long and the repeated hour is
    /// counted once, not twice.
    func testFallBackDayIsOneDayOfTwentyFiveHours() async throws {
        // 05:30 and 06:30 UTC on 1 November 2026 are both 01:30 in New York —
        // once on daylight time and once on standard time.
        let firstOneThirty = try utc("2026-11-01T05:30:00.000Z")
        let secondOneThirty = try utc("2026-11-01T06:30:00.000Z")

        let store = try await store([
            quantity("a", "HKQuantityTypeIdentifierStepCount", firstOneThirty, 11, "count"),
            quantity("b", "HKQuantityTypeIdentifierStepCount", secondOneThirty, 22, "count")
        ])

        let plan = try dayPlan(from: try local(2026, 11, 1), days: 2)
        let series = try await store.series(
            type: "HKQuantityTypeIdentifierStepCount",
            plan: plan
        )

        let elapsed = series.columns[0].end.timeIntervalSince(series.columns[0].start)
        XCTAssertEqual(elapsed, 25 * 3600, accuracy: 1)
        XCTAssertEqual(series.columns[0].total, 33)
        XCTAssertEqual(
            series.columns[0].daysWithData,
            1,
            "an hour lived twice is still one day with data"
        )
    }

    /// The SQL day expression and `Calendar` agree, including over a transition.
    ///
    /// The chart's columns come from `Calendar` and its coverage counts come
    /// from SQL. If the two disagreed about where a day starts, the bars and the
    /// "days with data" underneath them would describe different days.
    ///
    /// The expectation is built from `Calendar.startOfDay` — genuinely the
    /// other implementation — and its *contents* are compared, not just its
    /// size. An earlier version of this test built the expected set by calling
    /// `LocalDayExpression.day(for:)`, the Swift twin of the formula under
    /// test, and then only asserted the set had five members: it could not have
    /// failed for any uniform whole-day shift, which is exactly the hollow test
    /// this file exists to avoid.
    func testDatabaseAndCalendarAgreeOnWhereADayBegins() async throws {
        var samples: [[String: Any]] = []
        var startsOfDay: Set<Date> = []

        // Every hour across the spring-forward weekend.
        var cursor = try local(2026, 3, 6)
        var index = 0
        while cursor < (try local(2026, 3, 11)) {
            samples.append(
                quantity(
                    "s\(index)",
                    "HKQuantityTypeIdentifierStepCount",
                    cursor,
                    1,
                    "count"
                )
            )
            startsOfDay.insert(calendar.startOfDay(for: cursor))
            cursor = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: cursor))
            index += 1
        }

        let store = try await store(samples)
        let plan = try dayPlan(from: try local(2026, 3, 6), days: 5)
        let series = try await store.series(
            type: "HKQuantityTypeIdentifierStepCount",
            plan: plan
        )

        // The days Calendar says were touched, as dates rather than as indices.
        XCTAssertEqual(
            startsOfDay.sorted(),
            [
                try local(2026, 3, 6),
                try local(2026, 3, 7),
                try local(2026, 3, 8),
                try local(2026, 3, 9),
                try local(2026, 3, 10)
            ]
        )
        // The columns the plan drew are those same days, in that same order.
        XCTAssertEqual(series.columns.map(\.start), startsOfDay.sorted())
        // And the database found data on every one of them.
        XCTAssertEqual(series.columns.map(\.daysWithData), [1, 1, 1, 1, 1])
        XCTAssertEqual(series.coverage.daysWithData, 5)

        // Columns are 6, 7, 8, 9 and 10 March. The clocks go forward on the
        // 8th, so that column — and only that one — is an hour short.
        XCTAssertEqual(index, 119, "24 + 24 + 23 + 24 + 24")
        XCTAssertEqual(series.sampleCount, 119)
        XCTAssertEqual(series.columns.map(\.sampleCount), [24, 24, 23, 24, 24])
    }

    /// Columns keep landing on local midnight in a zone that transitions at
    /// midnight.
    ///
    /// Santiago puts its clocks forward at local 00:00, so that day has no
    /// midnight at all. Advancing a cursor by adding a day preserves the wall
    /// clock, so once `startOfDay` returned 01:00 for the transition day every
    /// column after it began at 01:00 too — while the SQL kept counting true
    /// midnights. The bars each straddled two local days, and a thirty-day
    /// window reported forty-four days with data and announced that every one
    /// of the thirty was covered.
    func testColumnsDoNotDriftInAZoneThatChangesAtMidnight() throws {
        let santiago = TimeZone(identifier: "America/Santiago")!
        var santiagoCalendar = Calendar(identifier: .gregorian)
        santiagoCalendar.timeZone = santiago

        var components = DateComponents()
        components.year = 2025
        components.month = 9
        components.day = 20
        components.hour = 14
        components.timeZone = TimeZone.gmt
        let now = try XCTUnwrap(santiagoCalendar.date(from: components))

        let plan = TimeBucketPlan.trailing(
            30,
            granularity: .day,
            endingAt: now,
            calendar: santiagoCalendar
        )

        XCTAssertEqual(plan.columns.count, 30)
        for column in plan.columns {
            XCTAssertEqual(
                column.start,
                santiagoCalendar.startOfDay(for: column.start),
                "every column must begin where the calendar says a day begins"
            )
            XCTAssertEqual(column.dayCount(in: santiagoCalendar), 1)
        }
        // The transition day is 23 hours; every other day is 24.
        let lengths = plan.columns.map { $0.end.timeIntervalSince($0.start) }
        XCTAssertEqual(lengths.filter { $0 == 23 * 3600 }.count, 1)
        XCTAssertEqual(lengths.filter { $0 == 24 * 3600 }.count, 29)
        // Columns must meet exactly: no gaps, no overlaps.
        for (earlier, later) in zip(plan.columns, plan.columns.dropFirst()) {
            XCTAssertEqual(earlier.end, later.start)
        }
    }

    /// Coverage can never exceed the days it is counted against.
    func testCoverageNeverClaimsMoreDaysThanAColumnHas() async throws {
        var samples: [[String: Any]] = []
        for hour in 0..<(24 * 40) {
            let moment = try XCTUnwrap(
                calendar.date(
                    byAdding: .hour,
                    value: hour,
                    to: try local(2026, 2, 20)
                )
            )
            samples.append(
                quantity(
                    "h\(hour)",
                    "HKQuantityTypeIdentifierStepCount",
                    moment,
                    1,
                    "count"
                )
            )
        }
        let store = try await store(samples)

        for granularity in [ChartGranularity.day, .week, .month] {
            let plan = TimeBucketPlan.covering(
                from: try local(2026, 2, 20),
                to: try local(2026, 4, 5),
                granularity: granularity,
                calendar: calendar
            )
            let series = try await store.series(
                type: "HKQuantityTypeIdentifierStepCount",
                plan: plan
            )
            for column in series.columns {
                XCTAssertLessThanOrEqual(
                    column.daysWithData,
                    column.dayCount,
                    "\(granularity) column \(column.index) over-counted days"
                )
            }
            XCTAssertLessThanOrEqual(series.coverage.fraction, 1.0)
        }
    }

    /// A month column starts on the first and a week column on the first weekday.
    func testMonthAndWeekColumnsLandOnRealBoundaries() throws {
        let plan = TimeBucketPlan.covering(
            from: try local(2026, 1, 17, 13, 45),
            to: try local(2026, 4, 2),
            granularity: .month,
            calendar: calendar
        )

        XCTAssertEqual(plan.columns.count, 4)
        XCTAssertEqual(plan.columns[0].start, try local(2026, 1, 1))
        XCTAssertEqual(plan.columns[1].start, try local(2026, 2, 1))
        XCTAssertEqual(plan.columns[2].start, try local(2026, 3, 1))
        XCTAssertEqual(plan.columns[3].start, try local(2026, 4, 1))

        // February 2026 has 28 days; March has 31 even though it is an hour short.
        XCTAssertEqual(plan.columns[1].dayCount(in: calendar), 28)
        XCTAssertEqual(plan.columns[2].dayCount(in: calendar), 31)

        let weeks = TimeBucketPlan.covering(
            from: try local(2026, 1, 15),
            to: try local(2026, 2, 5),
            granularity: .week,
            calendar: calendar
        )
        for column in weeks.columns {
            XCTAssertEqual(
                calendar.component(.weekday, from: column.start),
                calendar.firstWeekday
            )
            XCTAssertEqual(column.dayCount(in: calendar), 7)
        }
    }

    // MARK: - Total versus average

    /// A cumulative type is totalled and a measured type never is.
    func testStepsAreTotalledAndHeartRateIsNot() async throws {
        let day = try local(2026, 5, 4, 9, 0)
        let store = try await store([
            quantity("s1", "HKQuantityTypeIdentifierStepCount", day, 1200, "count"),
            quantity("s2", "HKQuantityTypeIdentifierStepCount", day, 800, "count"),
            quantity("h1", "HKQuantityTypeIdentifierHeartRate", day, 1.0, "count/s"),
            quantity("h2", "HKQuantityTypeIdentifierHeartRate", day, 1.5, "count/s")
        ])

        let plan = try dayPlan(from: try local(2026, 5, 4), days: 1)

        let steps = try await store.series(
            type: "HKQuantityTypeIdentifierStepCount",
            plan: plan
        )
        XCTAssertEqual(steps.measure.kind, .total)
        XCTAssertEqual(steps.headline, 2000, "1200 + 800, worked out by hand")
        XCTAssertEqual(steps.value(steps.columns[0]), 2000)

        let heart = try await store.series(
            type: "HKQuantityTypeIdentifierHeartRate",
            plan: plan
        )
        XCTAssertEqual(heart.measure.kind, .average)
        XCTAssertFalse(
            heart.measure.isSummable,
            "a measured type must never be summed anywhere"
        )
        // (1.0 + 1.5) / 2 = 1.25 count/s, which is 75 bpm.
        XCTAssertEqual(try XCTUnwrap(heart.headline), 1.25, accuracy: 1e-9)
        XCTAssertNotEqual(heart.headline, 2.5, "that would be the sum")
    }

    /// Heart rate is stored per second and read per minute.
    ///
    /// Health's canonical unit for a pulse is `count/s`, so drawing the stored
    /// number puts a resting heart rate of 1.08 on the screen.
    func testHeartRateIsShownInBeatsPerMinute() async throws {
        let day = try local(2026, 5, 4, 9, 0)
        let store = try await store([
            quantity("h1", "HKQuantityTypeIdentifierHeartRate", day, 1.0, "count/s")
        ])

        let series = try await store.series(
            type: "HKQuantityTypeIdentifierHeartRate",
            plan: try dayPlan(from: try local(2026, 5, 4), days: 1)
        )

        let unit = series.displayUnit
        XCTAssertEqual(unit.label, "bpm")
        XCTAssertEqual(unit.convert(1.0), 60, accuracy: 1e-9)
        XCTAssertEqual(unit.format(1.0), "60")
    }

    /// A percentage is stored as a fraction and read as a percentage.
    func testBloodOxygenIsShownAsAPercentage() async throws {
        let day = try local(2026, 5, 4, 9, 0)
        let store = try await store([
            quantity("o1", "HKQuantityTypeIdentifierOxygenSaturation", day, 0.957, "%")
        ])

        let series = try await store.series(
            type: "HKQuantityTypeIdentifierOxygenSaturation",
            plan: try dayPlan(from: try local(2026, 5, 4), days: 1)
        )

        XCTAssertEqual(series.displayUnit.label, "%")
        XCTAssertEqual(series.displayUnit.convert(0.957), 95.7, accuracy: 1e-9)
    }

    // MARK: - Aggregated series samples

    /// One stored row can stand for hundreds of readings, and the average has
    /// to be weighted by how many.
    ///
    /// Health delivers a series as a single sample carrying the mean of its
    /// readings and their count. Treating that row as one observation lets a
    /// single quiet measurement outweigh an hour of loud ones.
    func testAverageIsWeightedByHowManyReadingsASampleStandsFor() async throws {
        let day = try local(2026, 5, 4, 9, 0)
        let later = try local(2026, 5, 4, 11, 0)
        let store = try await store([
            quantity(
                "a", "HKQuantityTypeIdentifierEnvironmentalAudioExposure",
                day, 100, "dBASPL", readings: 1
            ),
            quantity(
                "b", "HKQuantityTypeIdentifierEnvironmentalAudioExposure",
                later, 50, "dBASPL", readings: 99
            )
        ])

        let series = try await store.series(
            type: "HKQuantityTypeIdentifierEnvironmentalAudioExposure",
            plan: try dayPlan(from: try local(2026, 5, 4), days: 1)
        )

        // By hand: (100 × 1 + 50 × 99) / (1 + 99) = 5050 / 100 = 50.5.
        XCTAssertEqual(try XCTUnwrap(series.headline), 50.5, accuracy: 1e-9)
        XCTAssertNotEqual(
            try XCTUnwrap(series.headline),
            75,
            "75 is the unweighted mean, which over-weights the single reading"
        )
        XCTAssertEqual(series.sampleCount, 2)
        XCTAssertEqual(series.readingCount, 100)
        XCTAssertTrue(series.hasAggregatedSamples)
    }

    /// A cumulative series sample is already a total and must not be multiplied
    /// by its reading count.
    func testCumulativeSeriesSampleIsNotMultipliedByItsCount() async throws {
        let day = try local(2026, 5, 4, 9, 0)
        let store = try await store([
            quantity(
                "a", "HKQuantityTypeIdentifierDistanceCycling",
                day, 1000, "m", readings: 132
            )
        ])

        let series = try await store.series(
            type: "HKQuantityTypeIdentifierDistanceCycling",
            plan: try dayPlan(from: try local(2026, 5, 4), days: 1)
        )

        XCTAssertEqual(series.measure.kind, .total)
        XCTAssertEqual(
            series.headline,
            1000,
            "the sample already carries the whole distance"
        )
        XCTAssertNotEqual(series.headline, 132_000)
    }

    // MARK: - Category types

    /// Stand hours count the hours stood, not the raw stored value.
    ///
    /// `HKCategoryValueAppleStandHour` is 0 for stood and 1 for idle, so adding
    /// the values up totals the idle hours and labels them a total — drawing
    /// the exact inverse of the ring the person is used to.
    func testStandHoursCountHoursStoodRatherThanTheStoredValue() async throws {
        var samples: [[String: Any]] = []
        // Nine in the morning through five: three stood, six idle.
        for hour in 9..<18 {
            let stood = [9, 12, 15].contains(hour)
            samples.append(
                category(
                    "h\(hour)",
                    "HKCategoryTypeIdentifierAppleStandHour",
                    try local(2026, 5, 4, hour, 0),
                    stood ? 0 : 1,
                    end: try local(2026, 5, 4, hour + 1, 0)
                )
            )
        }

        let store = try await store(samples)
        let series = try await store.series(
            type: "HKCategoryTypeIdentifierAppleStandHour",
            plan: try dayPlan(from: try local(2026, 5, 4), days: 1)
        )

        XCTAssertEqual(series.measure.kind, .occurrences)
        XCTAssertEqual(series.headline, 3, "three hours stood, counted by hand")
        XCTAssertNotEqual(series.headline, 6, "six is the idle count")
        XCTAssertNotEqual(series.headline, 9, "nine is every sample")
    }

    /// Sleep is time asleep, and time in bed awake is not sleep.
    func testSleepCountsAsleepStagesOnly() async throws {
        // HKCategoryValueSleepAnalysis: 0 inBed, 2 awake, 3 core, 4 deep, 5 REM.
        let store = try await store([
            category(
                "bed", "HKCategoryTypeIdentifierSleepAnalysis",
                try local(2026, 5, 4, 22, 0), 0,
                end: try local(2026, 5, 5, 6, 0)
            ),
            category(
                "core", "HKCategoryTypeIdentifierSleepAnalysis",
                try local(2026, 5, 4, 22, 30), 3,
                end: try local(2026, 5, 5, 0, 30)
            ),
            category(
                "awake", "HKCategoryTypeIdentifierSleepAnalysis",
                try local(2026, 5, 4, 23, 0), 2,
                end: try local(2026, 5, 4, 23, 20)
            )
        ])

        let plan = try dayPlan(from: try local(2026, 5, 4), days: 1)
        let series = try await store.series(
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            plan: plan
        )

        XCTAssertEqual(series.measure.kind, .duration)
        // Only the two-hour core block counts: 7,200 seconds.
        XCTAssertEqual(try XCTUnwrap(series.headline), 7200, accuracy: 0.5)
        XCTAssertEqual(series.displayUnit.label, "hr")
        XCTAssertEqual(series.displayUnit.format(7200), "2.0")
    }

    /// A day of nothing but idle hours is nought stand hours, not no data.
    ///
    /// The worst possible day to hide. Counting only the stood hours made a
    /// fully recorded, entirely sedentary day identical to one the watch was
    /// never worn — a gap in the chart and a day missing from coverage.
    func testADayOfOnlyIdleHoursReportsZeroRatherThanNothing() async throws {
        var samples: [[String: Any]] = []
        for hour in 0..<24 {
            samples.append(
                category(
                    "h\(hour)",
                    "HKCategoryTypeIdentifierAppleStandHour",
                    try local(2026, 5, 4, hour, 0),
                    1,  // idle, every hour
                    end: try local(2026, 5, 4, hour, 59)
                )
            )
        }

        let store = try await store(samples)
        let series = try await store.series(
            type: "HKCategoryTypeIdentifierAppleStandHour",
            plan: try dayPlan(from: try local(2026, 5, 4), days: 1)
        )

        let column = series.columns[0]
        XCTAssertEqual(column.sampleCount, 24, "the watch recorded all day")
        XCTAssertEqual(column.countedCount, 0, "and none of it was standing")
        XCTAssertFalse(column.isEmpty, "a fully recorded day is not empty")
        XCTAssertEqual(column.daysWithData, 1)
        XCTAssertEqual(
            series.value(column),
            0,
            "zero stand hours is an answer; a gap is not"
        )
        XCTAssertEqual(series.headline, 0)
        XCTAssertTrue(series.coverage.isEveryDay)
    }

    /// A night recorded only as in-bed and awake is nought minutes asleep.
    func testANightWithNoSleepStagesReportsZeroMinutes() async throws {
        let store = try await store([
            category(
                "bed", "HKCategoryTypeIdentifierSleepAnalysis",
                try local(2026, 5, 4, 22, 0), 0,
                end: try local(2026, 5, 4, 23, 30)
            ),
            category(
                "awake", "HKCategoryTypeIdentifierSleepAnalysis",
                try local(2026, 5, 4, 23, 0), 2,
                end: try local(2026, 5, 4, 23, 40)
            )
        ])

        let series = try await store.series(
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            plan: try dayPlan(from: try local(2026, 5, 4), days: 1)
        )

        let column = series.columns[0]
        XCTAssertEqual(column.sampleCount, 2)
        XCTAssertEqual(column.countedCount, 0)
        XCTAssertFalse(column.isEmpty)
        XCTAssertEqual(series.value(column), 0, "no sleep is nought, not missing")
        XCTAssertEqual(column.daysWithData, 1)
    }

    /// A day with genuinely nothing is still empty.
    func testADayWithNoSamplesIsStillEmpty() async throws {
        let store = try await store([
            category(
                "h", "HKCategoryTypeIdentifierAppleStandHour",
                try local(2026, 5, 4, 9, 0), 0,
                end: try local(2026, 5, 4, 10, 0)
            )
        ])
        let series = try await store.series(
            type: "HKCategoryTypeIdentifierAppleStandHour",
            plan: try dayPlan(from: try local(2026, 5, 4), days: 2)
        )

        XCTAssertFalse(series.columns[0].isEmpty)
        XCTAssertTrue(series.columns[1].isEmpty, "the second day has no records")
        XCTAssertNil(series.value(series.columns[1]))
        XCTAssertEqual(series.coverage.daysWithData, 1)
        XCTAssertEqual(series.coverage.dayCount, 2)
    }

    /// Types HealthKit calls discrete are never summed, however countable
    /// their names sound.
    ///
    /// Decibels are the sharp end of this: they are logarithmic, so a total is
    /// not merely inaccurate but undefined, and a day of headphone use would
    /// have rendered as something like "12,480 dBASPL".
    func testDiscreteTypesThatSoundCountableAreStillAveraged() {
        for type in [
            "HKQuantityTypeIdentifierEnvironmentalSoundReduction",
            "HKQuantityTypeIdentifierEnvironmentalAudioExposure",
            "HKQuantityTypeIdentifierUVExposure",
            "HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances"
        ] {
            let measure = HealthMeasure.measure(for: type, storedUnit: "dBASPL")
            XCTAssertEqual(measure.kind, .average, "\(type) is a measurement")
            XCTAssertFalse(measure.isSummable, "\(type) must never be summed")
        }
    }

    // MARK: - Distribution

    /// A cumulative series sample is one occurrence of its total.
    ///
    /// Its value is the sum over its readings, not their mean, so counting it
    /// once per reading would inflate its bar by the length of the series.
    func testDistributionDoesNotWeightCumulativeSeriesSamples() async throws {
        let store = try await store([
            quantity(
                "a", "HKQuantityTypeIdentifierDistanceCycling",
                try local(2026, 5, 4, 9, 0), 1000, "m", readings: 132
            ),
            quantity(
                "b", "HKQuantityTypeIdentifierDistanceCycling",
                try local(2026, 5, 4, 10, 0), 2000, "m"
            )
        ])

        let buckets = try await store.distribution(
            type: "HKQuantityTypeIdentifierDistanceCycling",
            from: try local(2026, 5, 4),
            to: try local(2026, 5, 5)
        )

        XCTAssertEqual(
            buckets.reduce(0) { $0 + $1.count },
            2,
            "two rides, not 133 — the aggregate is one occurrence of its total"
        )
    }

    /// A measured series sample really does stand for many readings.
    func testDistributionWeightsMeasuredSeriesSamples() async throws {
        let store = try await store([
            quantity(
                "a", "HKQuantityTypeIdentifierEnvironmentalAudioExposure",
                try local(2026, 5, 4, 9, 0), 50, "dBASPL", readings: 60
            ),
            quantity(
                "b", "HKQuantityTypeIdentifierEnvironmentalAudioExposure",
                try local(2026, 5, 4, 10, 0), 80, "dBASPL"
            )
        ])

        let buckets = try await store.distribution(
            type: "HKQuantityTypeIdentifierEnvironmentalAudioExposure",
            from: try local(2026, 5, 4),
            to: try local(2026, 5, 5)
        )

        XCTAssertEqual(
            buckets.reduce(0) { $0 + $1.count },
            61,
            "sixty readings averaged into one row, plus one spot measurement"
        )
        // The quiet hour is the low band and the loud minute the high one.
        XCTAssertEqual(buckets.first?.count, 60)
        XCTAssertEqual(buckets.last?.count, 1)
    }

    /// A category type has no histogram: its values are an encoding.
    func testDistributionRefusesCategoryTypes() async throws {
        let store = try await store([
            category(
                "a", "HKCategoryTypeIdentifierSleepAnalysis",
                try local(2026, 5, 4, 22, 0), 3,
                end: try local(2026, 5, 5, 6, 0)
            )
        ])
        let buckets = try await store.distribution(
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            from: try local(2026, 5, 4),
            to: try local(2026, 5, 6)
        )
        XCTAssertTrue(buckets.isEmpty)
    }

    /// Every reading identical gives one band, not a division by zero.
    func testDistributionOfIdenticalReadingsIsOneBand() async throws {
        let store = try await store([
            quantity(
                "a", "HKQuantityTypeIdentifierBodyMass",
                try local(2026, 5, 4, 9, 0), 80, "kg"
            ),
            quantity(
                "b", "HKQuantityTypeIdentifierBodyMass",
                try local(2026, 5, 5, 9, 0), 80, "kg"
            )
        ])
        let buckets = try await store.distribution(
            type: "HKQuantityTypeIdentifierBodyMass",
            from: try local(2026, 5, 4),
            to: try local(2026, 5, 6)
        )
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].count, 2)
        XCTAssertEqual(buckets[0].midpoint, 80)
    }

    /// Mixed units have no single histogram either.
    func testDistributionRefusesMixedUnits() async throws {
        let store = try await store([
            quantity(
                "a", "HKQuantityTypeIdentifierBodyMass",
                try local(2026, 5, 4, 9, 0), 80, "kg"
            ),
            quantity(
                "b", "HKQuantityTypeIdentifierBodyMass",
                try local(2026, 5, 4, 10, 0), 176, "lb"
            )
        ])
        let buckets = try await store.distribution(
            type: "HKQuantityTypeIdentifierBodyMass",
            from: try local(2026, 5, 4),
            to: try local(2026, 5, 5)
        )
        XCTAssertTrue(buckets.isEmpty, "80 kg and 176 lb share no axis")
    }

    /// A zone that has never changed its offset produces a constant, and the
    /// constant is right.
    func testZoneWithNoTransitionsStillGroupsCorrectly() async throws {
        let store = try await store([
            quantity(
                "a", "HKQuantityTypeIdentifierStepCount",
                try XCTUnwrap(Timestamps.date(from: "2026-06-16T02:00:00.000Z")),
                40, "count"
            ),
            quantity(
                "b", "HKQuantityTypeIdentifierStepCount",
                try XCTUnwrap(Timestamps.date(from: "2026-06-16T08:00:00.000Z")),
                60, "count"
            )
        ])

        var phoenix = Calendar(identifier: .gregorian)
        phoenix.timeZone = TimeZone(identifier: "America/Phoenix")!
        let plan = TimeBucketPlan.covering(
            from: try XCTUnwrap(Timestamps.date(from: "2026-06-14T07:00:00.000Z")),
            to: try XCTUnwrap(Timestamps.date(from: "2026-06-18T07:00:00.000Z")),
            granularity: .day,
            calendar: phoenix
        )
        let series = try await store.series(
            type: "HKQuantityTypeIdentifierStepCount",
            plan: plan
        )

        // 02:00Z is 19:00 on the 15th in Phoenix; 08:00Z is 01:00 on the 16th.
        XCTAssertEqual(series.columns.map(\.total), [0, 40, 60, 0])
        XCTAssertEqual(series.coverage.daysWithData, 2)
    }

    /// Two samples of one type in different units are not added.
    func testMixedUnitsAreRefusedRatherThanAdded() async throws {
        let day = try local(2026, 5, 4, 9, 0)
        let store = try await store([
            quantity("a", "HKQuantityTypeIdentifierBodyMass", day, 80, "kg"),
            quantity("b", "HKQuantityTypeIdentifierBodyMass", day, 176, "lb")
        ])

        let series = try await store.series(
            type: "HKQuantityTypeIdentifierBodyMass",
            plan: try dayPlan(from: try local(2026, 5, 4), days: 1)
        )

        XCTAssertTrue(series.hasMixedUnits)
        XCTAssertEqual(series.units, ["kg", "lb"])
        XCTAssertNil(series.headline, "128 kg-pounds is not a weight")
        XCTAssertNil(series.value(series.columns[0]))
    }

    // MARK: - Degenerate series

    func testEmptySeriesReportsNothingRatherThanZero() async throws {
        let store = try await store([])
        let series = try await store.series(
            type: "HKQuantityTypeIdentifierStepCount",
            plan: try dayPlan(from: try local(2026, 5, 4), days: 7)
        )

        XCTAssertEqual(series.columns.count, 7)
        XCTAssertNil(series.headline)
        XCTAssertTrue(series.values.isEmpty)
        XCTAssertEqual(series.coverage.daysWithData, 0)
        XCTAssertEqual(series.coverage.dayCount, 7)
        XCTAssertFalse(series.coverage.isEveryDay)
        XCTAssertEqual(series.coverage.sentence, "No days in this range have data yet.")
    }

    func testSinglePointSeriesHasNoRangeButStillHasAValue() async throws {
        let store = try await store([
            quantity(
                "a", "HKQuantityTypeIdentifierBodyMass",
                try local(2026, 5, 4, 9, 0), 82.5, "kg"
            )
        ])
        let series = try await store.series(
            type: "HKQuantityTypeIdentifierBodyMass",
            plan: try dayPlan(from: try local(2026, 5, 4), days: 7)
        )

        XCTAssertEqual(try XCTUnwrap(series.headline), 82.5, accuracy: 1e-9)
        XCTAssertEqual(series.values.count, 1)
        let extremes = try XCTUnwrap(series.extremes)
        XCTAssertEqual(extremes.minimum, 82.5)
        XCTAssertEqual(extremes.maximum, 82.5)
        XCTAssertEqual(series.coverage.daysWithData, 1)
        XCTAssertEqual(series.coverage.dayCount, 7)
    }

    func testTwoPointSeriesAveragesBothAndKeepsBothExtremes() async throws {
        let store = try await store([
            quantity(
                "a", "HKQuantityTypeIdentifierBodyMass",
                try local(2026, 5, 4, 9, 0), 80, "kg"
            ),
            quantity(
                "b", "HKQuantityTypeIdentifierBodyMass",
                try local(2026, 5, 6, 9, 0), 84, "kg"
            )
        ])
        let series = try await store.series(
            type: "HKQuantityTypeIdentifierBodyMass",
            plan: try dayPlan(from: try local(2026, 5, 4), days: 7)
        )

        XCTAssertEqual(try XCTUnwrap(series.headline), 82, accuracy: 1e-9)
        let extremes = try XCTUnwrap(series.extremes)
        XCTAssertEqual(extremes.minimum, 80)
        XCTAssertEqual(extremes.maximum, 84)
        XCTAssertEqual(series.coverage.daysWithData, 2)
    }

    // MARK: - Coverage

    /// Coverage counts days that have data and never claims more than that.
    func testCoverageCountsDaysWithDataAndClaimsNothingElse() async throws {
        // Three of seven days, deliberately not contiguous.
        let store = try await store([
            quantity(
                "a", "HKQuantityTypeIdentifierStepCount",
                try local(2026, 5, 4, 9, 0), 100, "count"
            ),
            quantity(
                "b", "HKQuantityTypeIdentifierStepCount",
                try local(2026, 5, 4, 18, 0), 100, "count"
            ),
            quantity(
                "c", "HKQuantityTypeIdentifierStepCount",
                try local(2026, 5, 6, 9, 0), 100, "count"
            ),
            quantity(
                "d", "HKQuantityTypeIdentifierStepCount",
                try local(2026, 5, 9, 9, 0), 100, "count"
            )
        ])

        let series = try await store.series(
            type: "HKQuantityTypeIdentifierStepCount",
            plan: try dayPlan(from: try local(2026, 5, 4), days: 7)
        )

        XCTAssertEqual(
            series.coverage.daysWithData,
            3,
            "four samples across three distinct days"
        )
        XCTAssertEqual(series.coverage.dayCount, 7)
        XCTAssertEqual(series.coverage.fraction, 3.0 / 7.0, accuracy: 1e-9)
        XCTAssertFalse(series.coverage.isEveryDay)
        XCTAssertEqual(series.coverage.sentence, "3 of 7 days have data so far.")
        XCTAssertFalse(
            series.coverage.sentence.lowercased().contains("complete"),
            "this computer cannot know what completeness would mean"
        )
    }

    /// A month column knows how many of its own days have data.
    func testMultiDayColumnCarriesItsOwnDayCoverage() async throws {
        var samples: [[String: Any]] = []
        for day in 1...10 {
            samples.append(
                quantity(
                    "d\(day)", "HKQuantityTypeIdentifierStepCount",
                    try local(2026, 5, day, 9, 0), 500, "count"
                )
            )
        }

        let store = try await store(samples)
        let plan = TimeBucketPlan.covering(
            from: try local(2026, 5, 1),
            to: try local(2026, 6, 1),
            granularity: .month,
            calendar: calendar
        )
        let series = try await store.series(
            type: "HKQuantityTypeIdentifierStepCount",
            plan: plan
        )

        XCTAssertEqual(series.columns.count, 1)
        XCTAssertEqual(series.columns[0].daysWithData, 10)
        XCTAssertEqual(series.columns[0].dayCount, 31, "May has 31 days")
        XCTAssertFalse(series.columns[0].hasEveryDay)
        XCTAssertEqual(series.columns[0].total, 5000)
    }

    /// A column that has every one of its days says so, and only then.
    func testAFullColumnReportsEveryDay() async throws {
        var samples: [[String: Any]] = []
        for day in 4...10 {
            samples.append(
                quantity(
                    "d\(day)", "HKQuantityTypeIdentifierStepCount",
                    try local(2026, 5, day, 9, 0), 500, "count"
                )
            )
        }
        let store = try await store(samples)
        let series = try await store.series(
            type: "HKQuantityTypeIdentifierStepCount",
            plan: try dayPlan(from: try local(2026, 5, 4), days: 7)
        )

        XCTAssertTrue(series.coverage.isEveryDay)
        XCTAssertEqual(series.coverage.sentence, "Every one of these 7 days has data.")
    }

    // MARK: - Measure classification

    func testMeasureClassificationIsExplicitAboutWhatItSums() {
        let cumulative = [
            "HKQuantityTypeIdentifierStepCount",
            "HKQuantityTypeIdentifierActiveEnergyBurned",
            "HKQuantityTypeIdentifierDistanceCycling",
            "HKQuantityTypeIdentifierDietaryProtein",
            "HKQuantityTypeIdentifierAppleExerciseTime",
            "HKQuantityTypeIdentifierFlightsClimbed"
        ]
        for type in cumulative {
            XCTAssertEqual(
                HealthMeasure.measure(for: type, storedUnit: "count").kind,
                .total,
                "\(type) accumulates"
            )
        }

        let measured = [
            "HKQuantityTypeIdentifierHeartRate",
            "HKQuantityTypeIdentifierRestingHeartRate",
            "HKQuantityTypeIdentifierBodyMass",
            "HKQuantityTypeIdentifierOxygenSaturation",
            "HKQuantityTypeIdentifierVO2Max",
            "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
            "HKQuantityTypeIdentifierWalkingSpeed",
            "HKQuantityTypeIdentifierBloodGlucose"
        ]
        for type in measured {
            let measure = HealthMeasure.measure(for: type, storedUnit: "count")
            XCTAssertEqual(measure.kind, .average, "\(type) is measured")
            XCTAssertFalse(measure.isSummable, "\(type) must never be summed")
        }
    }

    /// A type this build has never heard of is counted, not summed.
    func testUnknownTypeIsNeverSummed() {
        let measure = HealthMeasure.measure(
            for: "HKQuantityTypeIdentifierSomethingAppleAddedLater",
            storedUnit: "count"
        )
        XCTAssertEqual(measure.kind, .average)
        XCTAssertFalse(measure.isSummable)

        let category = HealthMeasure.measure(
            for: "HKCategoryTypeIdentifierSomethingNew",
            storedUnit: nil
        )
        XCTAssertEqual(category.kind, .occurrences)
    }

    // MARK: - Display units

    func testDistanceSwitchesUnitWithMagnitudeAndNeverMisstatesIt() {
        let measure = HealthMeasure.measure(
            for: "HKQuantityTypeIdentifierDistanceCycling",
            storedUnit: "m"
        )

        let short = measure.displayUnit(forMagnitude: 400)
        XCTAssertEqual(short.label, "m")
        XCTAssertEqual(short.format(400), "400")

        let long = measure.displayUnit(forMagnitude: 68_211)
        XCTAssertEqual(long.label, "km")
        XCTAssertEqual(long.convert(68_211), 68.211, accuracy: 1e-9)
    }

    func testMicronutrientsAreReadInMilligrams() {
        let measure = HealthMeasure.measure(
            for: "HKQuantityTypeIdentifierDietaryVitaminC",
            storedUnit: "g"
        )
        let unit = measure.displayUnit(forMagnitude: 0.019)
        XCTAssertEqual(unit.label, "mg")
        XCTAssertEqual(unit.convert(0.019), 19, accuracy: 1e-9)
    }

    // MARK: - Range plans

    func testTrailingWeekIsSevenDaysEndingWithToday() throws {
        let now = try local(2026, 5, 20, 14, 30)
        let plan = TimeBucketPlan.forRange(
            .week,
            now: now,
            earliest: nil,
            calendar: calendar
        )

        XCTAssertEqual(plan.columns.count, 7)
        XCTAssertEqual(plan.columns.first?.start, try local(2026, 5, 14))
        XCTAssertEqual(plan.columns.last?.start, try local(2026, 5, 20))
        XCTAssertEqual(plan.columns.last?.end, try local(2026, 5, 21))
    }

    func testAllRangeStartsAtTheOldestRecordsMonth() throws {
        let plan = TimeBucketPlan.forRange(
            .all,
            now: try local(2026, 5, 20),
            earliest: try local(2017, 6, 18, 16, 50),
            calendar: calendar
        )

        XCTAssertEqual(plan.columns.first?.start, try local(2017, 6, 1))
        XCTAssertEqual(plan.columns.last?.start, try local(2026, 5, 1))
        // June 2017 through May 2026 inclusive is nine whole years of months.
        XCTAssertEqual(plan.columns.count, 9 * 12)
    }

    // MARK: - Route completeness

    /// A route missing its final pages is not a complete route.
    ///
    /// Gaps found by comparing consecutive offsets cannot see a shortfall at
    /// the end: everything that arrived is an unbroken run. The watch says how
    /// many locations it recorded when it closes the series, and that is what
    /// catches it.
    func testRouteMissingItsLastPageIsNotComplete() async throws {
        let store = try await store([
            routeSample("route-1", workout: "w-1"),
            locationPage("route-1", sequence: 0, offset: 0, count: 2),
            routeEnd("route-1", locations: 4)
        ])

        let loaded = try await store.route(forWorkout: "w-1")
        let route = try XCTUnwrap(loaded)
        XCTAssertEqual(route.points.count, 2)
        XCTAssertFalse(
            route.isComplete,
            "two of four locations is not the whole route"
        )
        XCTAssertEqual(route.missingPages, 1)
    }

    /// A page that decodes to fewer locations than it claims is a gap.
    ///
    /// Advancing by the claimed count makes the next page line up perfectly and
    /// hides the hole. The electrocardiogram reader already advances by what it
    /// actually decoded; this now does the same.
    func testPageHoldingFewerLocationsThanItClaimsIsAGap() async throws {
        let store = try await store([
            routeSample("route-2", workout: "w-2"),
            locationPage("route-2", sequence: 0, offset: 0, count: 4, actual: 2),
            locationPage("route-2", sequence: 1, offset: 4, count: 2),
            routeEnd("route-2", locations: 6)
        ])

        let loaded = try await store.route(forWorkout: "w-2")
        let route = try XCTUnwrap(loaded)
        XCTAssertEqual(route.points.count, 4, "two lost, four drawn")
        XCTAssertFalse(route.isComplete)
        XCTAssertGreaterThanOrEqual(route.missingPages, 1)
    }

    /// Two routes for one workout are joined by a straight line, which is a gap.
    func testTwoRoutesForOneWorkoutAreNotOneUnbrokenPath() async throws {
        let store = try await store([
            routeSample("route-3a", workout: "w-3"),
            locationPage("route-3a", sequence: 0, offset: 0, count: 2),
            routeEnd("route-3a", locations: 2),
            routeSample("route-3b", workout: "w-3", start: "2026-05-04T11:00:00.000Z"),
            locationPage("route-3b", sequence: 0, offset: 0, count: 2),
            routeEnd("route-3b", locations: 2)
        ])

        let loaded = try await store.route(forWorkout: "w-3")
        let route = try XCTUnwrap(loaded)
        XCTAssertEqual(route.points.count, 4)
        XCTAssertFalse(
            route.isComplete,
            "a pause and resume leaves a straight line between the two"
        )
    }

    /// A whole route in contiguous pages really is complete.
    func testAWholeRouteIsReportedComplete() async throws {
        let store = try await store([
            routeSample("route-4", workout: "w-4"),
            locationPage("route-4", sequence: 0, offset: 0, count: 2),
            locationPage("route-4", sequence: 1, offset: 2, count: 2),
            routeEnd("route-4", locations: 4)
        ])

        let loaded = try await store.route(forWorkout: "w-4")
        let route = try XCTUnwrap(loaded)
        XCTAssertEqual(route.points.count, 4)
        XCTAssertTrue(route.isComplete)
        XCTAssertEqual(route.missingPages, 0)
    }

    // MARK: - Route fixtures

    private func routeSample(
        _ id: String,
        workout: String,
        start: String = "2026-05-04T10:00:00.000Z"
    ) -> [String: Any] {
        [
            "kind": "workoutRoute",
            "id": id,
            "type": "HKWorkoutRouteTypeIdentifier",
            "startDate": start,
            "endDate": start,
            "workout": ["id": workout, "activityType": 52]
        ]
    }

    private func locationPage(
        _ routeID: String,
        sequence: Int,
        offset: Int,
        count: Int,
        actual: Int? = nil
    ) -> [String: Any] {
        let held = actual ?? count
        let locations = (0..<held).map { index -> [String: Any] in
            [
                "latitude": 42.65 + Double(offset + index) * 0.0001,
                "longitude": -73.76 + Double(offset + index) * 0.0001,
                "altitude": 60.0,
                "timestamp": "2026-05-04T10:00:0\(index % 10).000Z"
            ]
        }
        return [
            "kind": "workoutRouteLocations",
            "id": "\(routeID)-page-\(sequence)",
            "type": "HKWorkoutRouteTypeIdentifier",
            "sample": routeID,
            "sequence": sequence,
            "offset": offset,
            // Deliberately the claimed count, which `actual` may undercut.
            "count": count,
            "startDate": "2026-05-04T10:00:00.000Z",
            "endDate": "2026-05-04T10:05:00.000Z",
            "locations": locations
        ]
    }

    private func routeEnd(_ routeID: String, locations: Int) -> [String: Any] {
        [
            "kind": "workoutRouteEnd",
            "id": "\(routeID)-end",
            "type": "HKWorkoutRouteTypeIdentifier",
            "sample": routeID,
            "locations": locations,
            "startDate": "2026-05-04T10:00:00.000Z",
            "endDate": "2026-05-04T10:05:00.000Z"
        ]
    }
}
