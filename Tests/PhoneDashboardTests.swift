import Foundation
import HealthKit
import HozzCatalog
import HozzHealth
import XCTest
@testable import Hozz

/// The arithmetic behind the iPhone's charts.
///
/// Named for the phone because the Mac dashboards have their own suite under
/// `HealthDashboardTests`, and two test classes of the same name in one bundle
/// are one class as far as the runtime is concerned.
///
/// Every expected value here is worked out by hand or by an obviously
/// different method than the one under test. A test that recomputes the
/// production formula and compares the two only proves the copy agrees with
/// itself, and would have passed just as happily on every wrong version of
/// this code.
///
/// The stakes are why. A chart that renders beautifully and reports the wrong
/// resting heart rate is worse than no chart, because someone believes it.
final class PhoneDashboardTests: XCTestCase {
    /// A fixed zone with a daylight-saving change, so "local time" means
    /// something specific rather than whatever the test machine is set to.
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0,
        zone: TimeZone
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = zone
        return calendar(zone).date(from: components)!
    }

    // MARK: - Bucket boundaries

    /// The boundary case that decides whether a reading is counted once or
    /// twice. `DateInterval.contains(_:)` includes both ends and would answer
    /// "both" here.
    func testAReadingAtExactlyMidnightBelongsToTheDayBeginning() throws {
        let calendar = calendar(newYork)
        let buckets = MetricBucketing.buckets(
            for: .week,
            endingAt: date(2025, 6, 15, 12, zone: newYork),
            calendar: calendar
        )

        let midnight = date(2025, 6, 12, 0, 0, zone: newYork)
        let found = try XCTUnwrap(MetricBucketing.index(of: midnight, in: buckets))
        XCTAssertEqual(
            buckets[found].start,
            midnight,
            "Midnight opens a day. It must land in the day starting, not the one ending."
        )

        // And in exactly one bucket: the day before must not also claim it.
        let matches = buckets.filter { $0.start <= midnight && midnight < $0.end }
        XCTAssertEqual(matches.count, 1, "A reading may belong to one bucket only.")
    }

    /// One second before midnight is still the old day. The pair of these two
    /// tests is what pins the boundary.
    func testTheLastInstantOfADayStaysInThatDay() throws {
        let calendar = calendar(newYork)
        let buckets = MetricBucketing.buckets(
            for: .week,
            endingAt: date(2025, 6, 15, 12, zone: newYork),
            calendar: calendar
        )

        let justBefore = date(2025, 6, 12, 0, 0, zone: newYork).addingTimeInterval(-1)
        let index = try XCTUnwrap(MetricBucketing.index(of: justBefore, in: buckets))
        XCTAssertEqual(
            calendar.component(.day, from: buckets[index].start),
            11,
            "23:59:59 on the 11th belongs to the 11th."
        )
    }

    /// The bug the Markdown export had: an evening in New York is already
    /// tomorrow in UTC, and bucketing on UTC files it under the wrong day.
    func testAnEveningReadingIsNotFiledUnderTheFollowingMorning() throws {
        let calendar = calendar(newYork)
        let evening = date(2025, 6, 15, 20, 30, zone: newYork)

        // Independently: 20:30 in New York in June is UTC-4, so this instant is
        // 00:30 on the 16th in UTC. A UTC-bucketed chart would say the 16th.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.day, from: evening), 16, "Precondition: it is the 16th in UTC.")

        let buckets = MetricBucketing.buckets(
            for: .week,
            endingAt: date(2025, 6, 17, 12, zone: newYork),
            calendar: calendar
        )
        let index = try XCTUnwrap(MetricBucketing.index(of: evening, in: buckets))
        XCTAssertEqual(
            calendar.component(.day, from: buckets[index].start),
            15,
            "An evening workout belongs to the evening it happened, not to the next morning."
        )
    }

    /// Stepping by 86,400 seconds would put every boundary after this Sunday
    /// an hour out and leave it there.
    func testTheDayAClockGoesForwardIsTwentyThreeHoursLong() throws {
        let calendar = calendar(newYork)
        let buckets = MetricBucketing.buckets(
            for: .week,
            endingAt: date(2025, 3, 12, 12, zone: newYork),
            calendar: calendar
        )

        // 9 March 2025 is when US clocks go forward, so that local day is 23
        // hours long. Worked out from the rule, not from the code under test.
        let day = try XCTUnwrap(
            buckets.first { calendar.component(.day, from: $0.start) == 9 }
        )
        XCTAssertEqual(day.duration, 23 * 3_600, "That local day is 23 hours.")

        for bucket in buckets {
            XCTAssertEqual(
                calendar.component(.hour, from: bucket.start),
                0,
                "Every bucket must start at local midnight, including after the change."
            )
        }
    }

    func testTheDayAClockGoesBackIsTwentyFiveHoursLong() throws {
        let calendar = calendar(newYork)
        let buckets = MetricBucketing.buckets(
            for: .week,
            endingAt: date(2025, 11, 5, 12, zone: newYork),
            calendar: calendar
        )

        let day = try XCTUnwrap(
            buckets.first { calendar.component(.day, from: $0.start) == 2 }
        )
        XCTAssertEqual(day.duration, 25 * 3_600, "2 November 2025 is 25 hours long in New York.")
    }

    /// Buckets have to be contiguous, or readings fall between them and vanish.
    func testBucketsMeetExactlyWithNoGapAndNoOverlap() {
        let calendar = calendar(newYork)
        let buckets = MetricBucketing.buckets(
            for: .month,
            endingAt: date(2025, 3, 20, 9, zone: newYork),
            calendar: calendar
        )
        XCTAssertEqual(buckets.count, 30)
        for (earlier, later) in zip(buckets, buckets.dropFirst()) {
            XCTAssertEqual(earlier.end, later.start, "A gap here loses every reading inside it.")
        }
    }

    /// New York changes its clocks at two in the morning, which is the gentle
    /// case: local midnight still happens exactly once.
    ///
    /// These zones move theirs *at* midnight, so on the transition day local
    /// midnight either never happens or happens twice. Stepping a day back
    /// from a midnight and then adding a day to get the end drifts to 01:00
    /// and leaves a real hole — or a real overlap — in the chain. A reading in
    /// the hole belongs to no bucket and is dropped, then reported as an
    /// absence, which is the one thing a bucket carrying nil is promised not
    /// to mean.
    func testBucketsStayContiguousInZonesWhoseClocksChangeAtMidnight() throws {
        let awkward: [(String, Int, Int, Int)] = [
            ("America/Santiago", 2025, 9, 10),
            ("America/Havana", 2025, 11, 5),
            ("Africa/Cairo", 2025, 4, 29),
            ("America/Asuncion", 2025, 10, 8),
            ("Asia/Beirut", 2025, 3, 31)
        ]

        for (name, year, month, day) in awkward {
            let zone = try XCTUnwrap(TimeZone(identifier: name))
            let calendar = calendar(zone)
            for range in MetricRange.allCases {
                let buckets = MetricBucketing.buckets(
                    for: range,
                    endingAt: date(year, month, day, 12, zone: zone),
                    calendar: calendar
                )
                XCTAssertEqual(
                    buckets.count,
                    range.bucketCount,
                    "\(name) \(range.title) lost a bucket."
                )
                for (earlier, later) in zip(buckets, buckets.dropFirst()) {
                    XCTAssertEqual(
                        earlier.end,
                        later.start,
                        "\(name) \(range.title): a hole or overlap here silently drops readings."
                    )
                }
                // Every boundary must be a real local start-of-unit, not
                // whatever wall time survived the arithmetic.
                if range.bucketUnit == .day {
                    for bucket in buckets {
                        XCTAssertEqual(
                            bucket.start,
                            calendar.startOfDay(for: bucket.start),
                            "\(name): \(bucket.start) is not the start of a local day."
                        )
                    }
                }
            }
        }
    }

    /// Contiguity alone is not enough: every instant in the range has to land
    /// in exactly one bucket, checked instant by instant across a transition.
    func testEveryInstantAcrossAMidnightTransitionLandsInExactlyOneBucket() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Santiago"))
        let calendar = calendar(zone)
        let buckets = MetricBucketing.buckets(
            for: .week,
            endingAt: date(2025, 9, 10, 12, zone: zone),
            calendar: calendar
        )
        let first = try XCTUnwrap(buckets.first)
        let last = try XCTUnwrap(buckets.last)

        // Every quarter hour of the week, counted independently of the binary
        // search by scanning all the buckets.
        var instant = first.start
        while instant < last.end {
            let matches = buckets.filter { $0.start <= instant && instant < $0.end }
            XCTAssertEqual(
                matches.count,
                1,
                "\(instant) belongs to \(matches.count) buckets; it must belong to one."
            )
            XCTAssertNotNil(
                MetricBucketing.index(of: instant, in: buckets),
                "\(instant) is inside the range but the search found no bucket."
            )
            instant = instant.addingTimeInterval(900)
        }
    }

    /// The consequence, in the shape someone would actually see it: seven
    /// ordinary nights across a midnight transition must be seven bars, not
    /// one bar of sixteen hours beside an empty one.
    func testSevenNightsAcrossAMidnightTransitionAreSevenSeparateDays() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Santiago"))
        let calendar = calendar(zone)
        let now = date(2025, 9, 10, 12, zone: zone)
        let intervals = MetricBucketing.buckets(for: .week, endingAt: now, calendar: calendar)

        // One eight-hour night ending each morning of the week.
        let nights: [DateInterval] = intervals.compactMap { bucket in
            let wake = calendar.date(byAdding: .hour, value: 7, to: bucket.start)
            guard let wake, let sleep = calendar.date(byAdding: .hour, value: -8, to: wake) else {
                return nil
            }
            return DateInterval(start: sleep, end: wake)
        }
        XCTAssertEqual(nights.count, 7, "Precondition: seven nights.")

        let series = MetricAggregator.aggregate(
            SleepAttribution.readings(from: nights, calendar: calendar),
            into: intervals,
            using: .total
        )

        XCTAssertEqual(
            series.buckets.filter(\.hasData).count,
            7,
            "Every night must reach its own day."
        )
        for bucket in series.buckets {
            XCTAssertEqual(
                bucket.value ?? 0,
                8,
                accuracy: 0.001,
                "No day may hold two nights, and none may lose one."
            )
        }
    }

    func testAYearIsDrawnInTwelveMonthlyBucketsEndingWithThisMonth() {
        let calendar = calendar(newYork)
        let buckets = MetricBucketing.buckets(
            for: .year,
            endingAt: date(2025, 8, 24, 5, zone: newYork),
            calendar: calendar
        )

        XCTAssertEqual(buckets.count, 12)
        XCTAssertEqual(
            buckets.first?.start,
            date(2024, 9, 1, zone: newYork),
            "Twelve months back from August 2025 is September 2024."
        )
        XCTAssertEqual(buckets.last?.start, date(2025, 8, 1, zone: newYork))
        // February 2025 had 28 days; a fixed 30-day step would not.
        let february = buckets.first { calendar.component(.month, from: $0.start) == 2 }
        XCTAssertEqual(february?.duration, 28 * 24 * 3_600)
    }

    func testAReadingOutsideTheRangeIsDroppedRatherThanClamped() {
        let calendar = calendar(newYork)
        let intervals = MetricBucketing.buckets(
            for: .week,
            endingAt: date(2025, 6, 15, 12, zone: newYork),
            calendar: calendar
        )

        let old = MetricReading(
            start: date(2024, 1, 1, 12, zone: newYork),
            value: 5_000,
            unit: "count"
        )
        let series = MetricAggregator.aggregate(
            [old],
            into: intervals,
            using: .total
        )
        XCTAssertFalse(
            series.hasAnyData,
            "A reading from last year is not evidence about this week."
        )
    }

    // MARK: - Total versus average, decided by HealthKit

    func testACumulativeTypeTotalsAndAMeasuredTypeAverages() {
        let steps = HKObjectType.quantityType(forIdentifier: .stepCount)!
        let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate)!

        XCTAssertEqual(MetricAggregation(steps.aggregationStyle), .total)
        XCTAssertEqual(MetricAggregation(heartRate.aggregationStyle), .average)
    }

    /// The invariant, checked against every quantity type Hozz can read rather
    /// than against a handful someone remembered.
    ///
    /// Summing three hundred heart rates produces a large, authoritative,
    /// meaningless number, and the only structural defence is that no discrete
    /// type is ever handed `.cumulativeSum`.
    func testNoMeasuredTypeIsEverSummed() {
        let quantityTypes = HealthKitTypeRegistry.exportableTypes()
            .compactMap { $0.sampleType as? HKQuantityType }
        XCTAssertGreaterThan(quantityTypes.count, 50, "Precondition: the catalog is populated.")

        for type in quantityTypes {
            let aggregation = MetricAggregation(type.aggregationStyle)
            let isCumulative = type.aggregationStyle == .cumulative

            XCTAssertEqual(
                aggregation == .total,
                isCumulative,
                "\(type.identifier) totals only if HealthKit calls it cumulative."
            )
            if !isCumulative {
                XCTAssertFalse(
                    aggregation.statisticsOptions.contains(.cumulativeSum),
                    "\(type.identifier) is measured and must never be summed."
                )
            } else {
                XCTAssertFalse(
                    aggregation.statisticsOptions.contains(.discreteAverage),
                    "\(type.identifier) accumulates; averaging its samples is meaningless."
                )
            }
        }
    }

    /// A style this build has never seen must fall to averaging, which is the
    /// conservative direction.
    func testAnUnrecognisedAggregationStyleAveragesRatherThanSums() {
        // `.discreteTemporallyWeighted` stands in for "not plainly cumulative".
        XCTAssertEqual(MetricAggregation(.discreteTemporallyWeighted), .average)
        XCTAssertEqual(MetricAggregation(.discreteEquivalentContinuousLevel), .average)
        XCTAssertEqual(MetricAggregation(.discreteArithmetic), .average)
    }

    // MARK: - Aggregate samples

    /// A sample carrying three hundred readings is not one opinion among two.
    func testASampleStandingForManyReadingsOutweighsASingleOne() throws {
        let start = date(2025, 6, 12, 9, zone: newYork)
        let readings = [
            MetricReading(start: start, value: 60, unit: "count/min", count: 300),
            MetricReading(start: start, value: 120, unit: "count/min", count: 1)
        ]

        // By hand: (60 x 300 + 120 x 1) / 301 = 18,120 / 301 = 60.19933...
        let expected = 18_120.0 / 301.0
        let mean = try XCTUnwrap(MetricAggregator.weightedMean(readings))
        XCTAssertEqual(mean, expected, accuracy: 0.000_001)
        XCTAssertEqual(mean, 60.199_335, accuracy: 0.000_01)

        // And emphatically not the plain mean of the two sample values.
        XCTAssertNotEqual(mean, 90, accuracy: 0.5, "This is the wrong answer, arrived at naively.")
    }

    func testASingleReadingIsItsOwnAverage() {
        let start = date(2025, 6, 12, 9, zone: newYork)
        let mean = MetricAggregator.weightedMean(
            [MetricReading(start: start, value: 72, unit: "count/min")]
        )
        XCTAssertEqual(mean, 72)
    }

    // MARK: - Bucketing readings

    func testACumulativeDayIsTheSumOfItsSamples() {
        let calendar = calendar(newYork)
        let intervals = MetricBucketing.buckets(
            for: .week,
            endingAt: date(2025, 6, 15, 12, zone: newYork),
            calendar: calendar
        )
        let day = date(2025, 6, 13, zone: newYork)
        let readings = [
            MetricReading(start: day.addingTimeInterval(3_600), value: 1_200, unit: "count"),
            MetricReading(start: day.addingTimeInterval(7_200), value: 800, unit: "count"),
            MetricReading(start: day.addingTimeInterval(50_000), value: 3_000, unit: "count")
        ]

        let series = MetricAggregator.aggregate(readings, into: intervals, using: .total)
        let bucket = series.buckets.first { $0.interval.start == day }

        // 1,200 + 800 + 3,000 = 5,000.
        XCTAssertEqual(bucket?.value, 5_000)
        XCTAssertEqual(bucket?.sampleCount, 3)
        XCTAssertEqual(series.summary.headline, 5_000, "One day of data is the week's total too.")
    }

    /// A day nothing arrived for is not a day someone scored nothing.
    func testAMissingDayIsEmptyRatherThanZero() {
        let calendar = calendar(newYork)
        let intervals = MetricBucketing.buckets(
            for: .week,
            endingAt: date(2025, 6, 15, 12, zone: newYork),
            calendar: calendar
        )
        let readings = [
            MetricReading(
                start: date(2025, 6, 13, 10, zone: newYork),
                value: 5_000,
                unit: "count"
            )
        ]

        let series = MetricAggregator.aggregate(readings, into: intervals, using: .total)
        let empty = series.buckets.filter { !$0.hasData }
        XCTAssertEqual(empty.count, 6, "Six of the seven days had nothing.")
        for bucket in empty {
            XCTAssertNil(bucket.value, "Nil, not zero. Zero is a measurement.")
        }
    }

    // MARK: - Units

    /// Two units of the same type must not be added. Without a conversion
    /// table the only honest answer is to withhold the number.
    func testReadingsInTwoUnitsAreNotAddedTogether() {
        let calendar = calendar(newYork)
        let intervals = MetricBucketing.buckets(
            for: .week,
            endingAt: date(2025, 6, 15, 12, zone: newYork),
            calendar: calendar
        )
        let day = date(2025, 6, 13, 10, zone: newYork)
        let series = MetricAggregator.aggregate(
            [
                MetricReading(start: day, value: 5, unit: "km"),
                MetricReading(start: day, value: 3, unit: "mi")
            ],
            into: intervals,
            using: .total
        )

        XCTAssertTrue(series.hasUnitConflict)
        XCTAssertFalse(series.hasAnyData, "8 of something is not an answer.")
        XCTAssertNil(series.summary.headline)
        XCTAssertNil(series.unit)
    }

    func testOneUnitThroughoutIsNotAConflict() {
        let calendar = calendar(newYork)
        let intervals = MetricBucketing.buckets(
            for: .week,
            endingAt: date(2025, 6, 15, 12, zone: newYork),
            calendar: calendar
        )
        let day = date(2025, 6, 13, 10, zone: newYork)
        let series = MetricAggregator.aggregate(
            [
                MetricReading(start: day, value: 5, unit: "km"),
                MetricReading(start: day, value: 3, unit: "km")
            ],
            into: intervals,
            using: .total
        )
        XCTAssertFalse(series.hasUnitConflict)
        XCTAssertEqual(series.summary.headline, 8)
        XCTAssertEqual(series.unit, "km")
    }

    // MARK: - Summaries

    /// The average someone achieved on the days they recorded, not diluted by
    /// the days Hozz was never told about.
    func testADailyAverageDividesByDaysWithDataNotDaysInRange() {
        let calendar = calendar(newYork)
        let intervals = MetricBucketing.buckets(
            for: .week,
            endingAt: date(2025, 6, 15, 12, zone: newYork),
            calendar: calendar
        )
        let readings = [
            MetricReading(start: date(2025, 6, 13, 10, zone: newYork), value: 8_000, unit: "count"),
            MetricReading(start: date(2025, 6, 14, 10, zone: newYork), value: 12_000, unit: "count")
        ]

        let summary = MetricAggregator
            .aggregate(readings, into: intervals, using: .total)
            .summary

        // By hand: 20,000 over the two days that had data is 10,000.
        // Over all seven it would be 2,857 — a figure the person never had.
        XCTAssertEqual(summary.headline, 20_000)
        XCTAssertEqual(summary.averagePerActiveBucket, 10_000)
        XCTAssertEqual(summary.bucketsWithData, 2)
        XCTAssertEqual(summary.bucketsInRange, 7)
    }

    /// A measured type has no meaningful daily total, so none is offered.
    func testAMeasuredTypeHasNoDailyAverageOfTotals() {
        let calendar = calendar(newYork)
        let intervals = MetricBucketing.buckets(
            for: .week,
            endingAt: date(2025, 6, 15, 12, zone: newYork),
            calendar: calendar
        )
        let summary = MetricAggregator
            .aggregate(
                [
                    MetricReading(
                        start: date(2025, 6, 13, 10, zone: newYork),
                        value: 60,
                        unit: "count/min"
                    )
                ],
                into: intervals,
                using: .average
            )
            .summary

        XCTAssertEqual(summary.aggregation, .average)
        XCTAssertNil(summary.averagePerActiveBucket)
    }

    /// When something that saw every reading has already reduced the range,
    /// that figure wins over anything reconstructed from daily averages.
    func testAMeasuredHeadlinePrefersTheWholeRangeFigureOverTheMeanOfDailyMeans() throws {
        let calendar = calendar(newYork)
        let intervals = MetricBucketing.buckets(
            for: .week,
            endingAt: date(2025, 6, 15, 12, zone: newYork),
            calendar: calendar
        )

        // Two days: one averaging 60 over many readings, one averaging 100
        // over a single reading. The mean of the two daily means is 80. The
        // real average of the readings is nearer 60.
        let buckets = intervals.enumerated().map { index, interval in
            MetricBucket(
                interval: interval,
                value: index == 5 ? 60 : (index == 6 ? 100 : nil),
                minimum: nil,
                maximum: nil,
                readingCount: index == 5 ? 500 : (index == 6 ? 1 : 0),
                sampleCount: index >= 5 ? 1 : 0
            )
        }

        let withoutOverall = MetricSeries(
            buckets: buckets,
            unit: "count/min",
            aggregation: .average,
            hasUnitConflict: false,
            containsAggregatedReadings: false
        )
        // By hand: (60 x 500 + 100 x 1) / 501 = 30,100 / 501 = 60.0798...
        let reconstructed = try XCTUnwrap(withoutOverall.summary.headline)
        XCTAssertEqual(reconstructed, 30_100.0 / 501.0, accuracy: 0.000_001)
        XCTAssertNotEqual(
            reconstructed,
            80,
            accuracy: 1,
            "80 is the mean of the daily means, which is not the mean."
        )

        let withOverall = MetricSeries(
            buckets: buckets,
            unit: "count/min",
            aggregation: .average,
            hasUnitConflict: false,
            containsAggregatedReadings: false,
            overall: MetricOverall(value: 60.5, minimum: 48, maximum: 173)
        )
        XCTAssertEqual(withOverall.summary.headline, 60.5)
        XCTAssertEqual(withOverall.summary.lowest, 48)
        XCTAssertEqual(withOverall.summary.highest, 173)
    }

    func testARangeWithNothingInItReportsNoHeadlineRatherThanZero() {
        let calendar = calendar(newYork)
        let intervals = MetricBucketing.buckets(
            for: .month,
            endingAt: date(2025, 6, 15, 12, zone: newYork),
            calendar: calendar
        )
        let series = MetricAggregator.aggregate([], into: intervals, using: .total)
        let summary = series.summary

        XCTAssertNil(summary.headline, "Nothing arrived. Zero would be a claim.")
        XCTAssertNil(summary.averagePerActiveBucket)
        XCTAssertEqual(summary.bucketsWithData, 0)
        XCTAssertEqual(summary.bucketsInRange, 30)
        XCTAssertFalse(summary.hasData)
    }

    func testASinglePointIsAValueRatherThanASpread() {
        let calendar = calendar(newYork)
        let intervals = MetricBucketing.buckets(
            for: .week,
            endingAt: date(2025, 6, 15, 12, zone: newYork),
            calendar: calendar
        )
        let summary = MetricAggregator
            .aggregate(
                [
                    MetricReading(
                        start: date(2025, 6, 14, 10, zone: newYork),
                        value: 72,
                        unit: "count/min"
                    )
                ],
                into: intervals,
                using: .average
            )
            .summary

        XCTAssertEqual(summary.headline, 72)
        XCTAssertEqual(summary.lowest, 72)
        XCTAssertEqual(summary.highest, 72)
        XCTAssertEqual(summary.bucketsWithData, 1, "One day is one day, not a trend.")
    }

    // MARK: - Coverage

    /// Coverage counts what arrived. It never says a range is complete,
    /// because Health does not publish a total without being read in full and
    /// does not reveal a declined type at all.
    func testCoverageCountsBucketsThatArrivedNotBucketsAskedFor() {
        let calendar = calendar(newYork)
        let now = date(2025, 6, 15, 12, zone: newYork)
        let intervals = MetricBucketing.buckets(for: .month, endingAt: now, calendar: calendar)

        // Eleven days of data at the recent end of a thirty-day range, which
        // is the shape a backfill still working through history produces.
        let readings = (0..<11).map { offset in
            MetricReading(
                start: calendar.date(byAdding: .day, value: -offset, to: now)!,
                value: 1_000,
                unit: "count"
            )
        }

        let coverage = MetricAggregator
            .aggregate(readings, into: intervals, using: .total)
            .coverage(now: now)

        XCTAssertEqual(coverage.bucketsInRange, 30)
        XCTAssertEqual(coverage.bucketsWithData, 11)
        XCTAssertTrue(coverage.isPartial)
        XCTAssertFalse(coverage.isEmpty)
        // Thirty buckets, the last eleven filled, so nineteen lead in empty.
        XCTAssertEqual(coverage.leadingEmptyBuckets, 19)
        XCTAssertEqual(coverage.firstBucketWithData, 19)
        XCTAssertEqual(coverage.lastBucketWithData, 29)
    }

    func testAFullRangeIsNotDescribedAsPartial() {
        let calendar = calendar(newYork)
        let now = date(2025, 6, 15, 12, zone: newYork)
        let intervals = MetricBucketing.buckets(for: .week, endingAt: now, calendar: calendar)
        let readings = intervals.map {
            MetricReading(start: $0.start.addingTimeInterval(3_600), value: 10, unit: "count")
        }

        let coverage = MetricAggregator
            .aggregate(readings, into: intervals, using: .total)
            .coverage(now: now)

        XCTAssertEqual(coverage.bucketsWithData, 7)
        XCTAssertFalse(coverage.isPartial)
        XCTAssertEqual(coverage.leadingEmptyBuckets, 0)
    }

    func testAnEmptyRangeIsEmptyRatherThanPartial() {
        let calendar = calendar(newYork)
        let now = date(2025, 6, 15, 12, zone: newYork)
        let intervals = MetricBucketing.buckets(for: .week, endingAt: now, calendar: calendar)
        let coverage = MetricAggregator
            .aggregate([], into: intervals, using: .total)
            .coverage(now: now)

        XCTAssertTrue(coverage.isEmpty)
        XCTAssertFalse(coverage.isPartial, "Nothing at all is not partial coverage.")
        XCTAssertNil(coverage.firstBucketWithData)
    }

    /// Today is not over, so today's bar is not comparable with the rest.
    func testTodayIsMarkedUnfinished() {
        let calendar = calendar(newYork)
        let now = date(2025, 6, 15, 12, zone: newYork)
        let intervals = MetricBucketing.buckets(for: .week, endingAt: now, calendar: calendar)
        let coverage = MetricAggregator
            .aggregate([], into: intervals, using: .total)
            .coverage(now: now)

        XCTAssertTrue(coverage.finalBucketIsPartial, "Midday on the last day is a part-day.")
    }

    func testARangeThatEndedIsNotMarkedUnfinished() {
        let calendar = calendar(newYork)
        let intervals = MetricBucketing.buckets(
            for: .week,
            endingAt: date(2025, 6, 15, 12, zone: newYork),
            calendar: calendar
        )
        // A week later, nothing in that range is still in progress.
        let coverage = MetricAggregator
            .aggregate([], into: intervals, using: .total)
            .coverage(now: date(2025, 6, 22, 12, zone: newYork))

        XCTAssertFalse(coverage.finalBucketIsPartial)
    }

    // MARK: - Sleep

    /// A watch, a phone and an app all describing the same night must not add
    /// up to more sleep than the night contained.
    func testOverlappingSleepIsCountedOnce() {
        let first = DateInterval(
            start: date(2025, 6, 12, 23, zone: newYork),
            end: date(2025, 6, 13, 1, zone: newYork)
        )
        let second = DateInterval(
            start: date(2025, 6, 13, 0, zone: newYork),
            end: date(2025, 6, 13, 3, zone: newYork)
        )

        // By hand: 23:00 to 01:00 is two hours, 00:00 to 03:00 is three. They
        // share an hour, so the union runs 23:00 to 03:00 — four hours, not
        // five.
        let merged = SleepAttribution.merge([first, second])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].duration, 4 * 3_600)

        let readings = SleepAttribution.readings(
            from: [first, second],
            calendar: calendar(newYork)
        )
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(readings[0].value, 4, accuracy: 0.000_1, "Four hours slept, not five.")
    }

    func testAStretchWhollyInsideAnotherDoesNotShortenIt() {
        let long = DateInterval(
            start: date(2025, 6, 13, 0, zone: newYork),
            end: date(2025, 6, 13, 8, zone: newYork)
        )
        let short = DateInterval(
            start: date(2025, 6, 13, 2, zone: newYork),
            end: date(2025, 6, 13, 3, zone: newYork)
        )

        let merged = SleepAttribution.merge([long, short])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].duration, 8 * 3_600, "The long stretch must survive intact.")
    }

    func testSeparateNapsStaySeparate() {
        let morning = DateInterval(
            start: date(2025, 6, 13, 2, zone: newYork),
            end: date(2025, 6, 13, 6, zone: newYork)
        )
        let afternoon = DateInterval(
            start: date(2025, 6, 13, 14, zone: newYork),
            end: date(2025, 6, 13, 15, zone: newYork)
        )

        let merged = SleepAttribution.merge([morning, afternoon])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.reduce(0) { $0 + $1.duration }, 5 * 3_600)
    }

    /// A night beginning before midnight belongs to the morning it ends on,
    /// which is where a person looks for it.
    func testANightBeginningInTheEveningIsFiledUnderTheFollowingDay() {
        let calendar = calendar(newYork)
        let night = DateInterval(
            start: date(2025, 6, 12, 23, 30, zone: newYork),
            end: date(2025, 6, 13, 7, 0, zone: newYork)
        )

        let readings = SleepAttribution.readings(from: [night], calendar: calendar)
        XCTAssertEqual(readings.count, 1, "One night is one figure, not two half-nights.")
        XCTAssertEqual(
            readings[0].start,
            date(2025, 6, 13, zone: newYork),
            "Filed under the 13th, the morning it ended."
        )
        // 23:30 to 07:00 is seven and a half hours.
        XCTAssertEqual(readings[0].value, 7.5, accuracy: 0.000_1)
    }

    func testAnAfternoonNapStaysOnItsOwnDay() {
        let calendar = calendar(newYork)
        let nap = DateInterval(
            start: date(2025, 6, 13, 14, zone: newYork),
            end: date(2025, 6, 13, 15, zone: newYork)
        )
        let readings = SleepAttribution.readings(from: [nap], calendar: calendar)
        XCTAssertEqual(readings[0].start, date(2025, 6, 13, zone: newYork))
        XCTAssertEqual(readings[0].value, 1, accuracy: 0.000_1)
    }

    /// Time in bed is not time asleep, and reporting it as such is the most
    /// common way a sleep figure flatters someone.
    /// The awkward case, pinned deliberately rather than left undiscovered.
    ///
    /// Deciding on the start alone means an evening nap is filed under the
    /// following day, though nobody woke then. That is a consequence of the
    /// rule and not a defect in it — deciding on the end instead would split a
    /// night that began with dozing on the sofa across two days — but it is
    /// why the caption states the mechanism rather than saying sleep counts
    /// towards the day you woke up, which this case would make false.
    func testAnEveningNapIsFiledUnderTheFollowingDay() {
        let calendar = calendar(newYork)
        let nap = DateInterval(
            start: date(2025, 6, 12, 19, zone: newYork),
            end: date(2025, 6, 12, 20, zone: newYork)
        )

        let readings = SleepAttribution.readings(from: [nap], calendar: calendar)
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(
            readings[0].start,
            date(2025, 6, 13, zone: newYork),
            "Nineteen hundred is after the boundary, so it counts towards the 13th."
        )
        XCTAssertEqual(readings[0].value, 1, accuracy: 0.000_1)
    }

    /// The mirror of the case above: someone asleep before the boundary has
    /// the night filed under the day it began, not the day they woke.
    func testANightBegunBeforeTheBoundaryIsFiledUnderTheDayItStarted() {
        let calendar = calendar(newYork)
        let night = DateInterval(
            start: date(2025, 6, 12, 17, 30, zone: newYork),
            end: date(2025, 6, 13, 6, 0, zone: newYork)
        )

        let readings = SleepAttribution.readings(from: [night], calendar: calendar)
        XCTAssertEqual(
            readings[0].start,
            date(2025, 6, 12, zone: newYork),
            "Half past five is before the boundary, so it counts towards the 12th."
        )
        // 17:30 to 06:00 is twelve and a half hours.
        XCTAssertEqual(readings[0].value, 12.5, accuracy: 0.000_1)
    }

    /// The caption says "at 6pm or later", so the instant itself has to fall on
    /// the later side. One second earlier must not.
    func testTheBoundaryInstantItselfCountsTowardsTheNextDay() {
        let calendar = calendar(newYork)

        let atSix = SleepAttribution.day(
            forSleepStartingAt: date(2025, 6, 12, 18, 0, zone: newYork),
            calendar: calendar
        )
        let justBefore = SleepAttribution.day(
            forSleepStartingAt: date(2025, 6, 12, 17, 59, zone: newYork),
            calendar: calendar
        )

        XCTAssertEqual(atSix, date(2025, 6, 13, zone: newYork), "Six exactly is 'or later'.")
        XCTAssertEqual(justBefore, date(2025, 6, 12, zone: newYork), "A minute before is not.")
    }

    func testTimeInBedAndTimeAwakeAreNotCountedAsSleep() {
        XCTAssertFalse(
            HealthMetricReader.isAsleep(HKCategoryValueSleepAnalysis.inBed.rawValue)
        )
        XCTAssertFalse(
            HealthMetricReader.isAsleep(HKCategoryValueSleepAnalysis.awake.rawValue)
        )
        XCTAssertTrue(
            HealthMetricReader.isAsleep(HKCategoryValueSleepAnalysis.asleepCore.rawValue)
        )
        XCTAssertTrue(
            HealthMetricReader.isAsleep(HKCategoryValueSleepAnalysis.asleepDeep.rawValue)
        )
        XCTAssertTrue(
            HealthMetricReader.isAsleep(HKCategoryValueSleepAnalysis.asleepREM.rawValue)
        )
        XCTAssertTrue(
            HealthMetricReader.isAsleep(HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue)
        )
        XCTAssertFalse(
            HealthMetricReader.isAsleep(9_999),
            "A stage this build has never heard of must not be assumed to be sleep."
        )
    }

    func testSleepStretchesAcrossSeveralNightsBecomeOneFigureEach() {
        let calendar = calendar(newYork)
        let nights = [
            DateInterval(
                start: date(2025, 6, 10, 23, zone: newYork),
                end: date(2025, 6, 11, 6, zone: newYork)
            ),
            DateInterval(
                start: date(2025, 6, 11, 22, 30, zone: newYork),
                end: date(2025, 6, 12, 6, 30, zone: newYork)
            )
        ]

        let readings = SleepAttribution.readings(from: nights, calendar: calendar)
        XCTAssertEqual(readings.count, 2)
        // Seven hours filed under the 11th, eight under the 12th.
        XCTAssertEqual(readings[0].start, date(2025, 6, 11, zone: newYork))
        XCTAssertEqual(readings[0].value, 7, accuracy: 0.000_1)
        XCTAssertEqual(readings[1].start, date(2025, 6, 12, zone: newYork))
        XCTAssertEqual(readings[1].value, 8, accuracy: 0.000_1)
    }

    /// Merging must happen across the whole set before anything is filed under
    /// a day, or two records of the same night that straddle the six o'clock
    /// boundary are never compared and their shared hours are counted twice.
    func testOverlapAcrossTheAttributionBoundaryIsStillMergedOnce() {
        let calendar = calendar(newYork)
        let early = DateInterval(
            start: date(2025, 6, 12, 17, 30, zone: newYork),
            end: date(2025, 6, 12, 19, 30, zone: newYork)
        )
        let late = DateInterval(
            start: date(2025, 6, 12, 18, 30, zone: newYork),
            end: date(2025, 6, 12, 20, 30, zone: newYork)
        )

        // Union is 17:30 to 20:30, three hours. Added separately it is four.
        let readings = SleepAttribution.readings(from: [early, late], calendar: calendar)
        let total = readings.reduce(0.0) { $0 + $1.value }
        XCTAssertEqual(total, 3, accuracy: 0.000_1, "Three hours of sleep, counted once.")
    }

    // MARK: - Units the display attaches

    /// HealthKit's percent unit is a fraction, not a percentage: the header
    /// says `% (0.0 - 1.0)`. A blood oxygen of 98% arrives as 0.98, and shown
    /// beside a "%" label with one decimal it reads "1.0 %" — alarming and
    /// wrong. The scale and the label have to agree, and they are declared
    /// in different places, so this checks they do.
    func testEveryPercentMetricIsScaledToMatchItsPercentLabel() throws {
        var checked = 0
        for metric in DashboardMetrics.all {
            let reading = try XCTUnwrap(
                DashboardMetrics.reading(for: metric),
                "\(metric.title) has no unit chosen for it."
            )
            if reading.unit == HKUnit.percent() {
                checked += 1
                XCTAssertEqual(
                    reading.scale,
                    100,
                    "\(metric.title) is read as a fraction and must be scaled to a percentage."
                )
                XCTAssertEqual(
                    metric.unitLabel,
                    "%",
                    "\(metric.title) is scaled to a percentage, so it must say so."
                )
                // Worked by hand: HealthKit's 0.98 is 98 per cent.
                XCTAssertEqual(0.98 * reading.scale, 98, accuracy: 0.000_001)
            } else {
                XCTAssertEqual(
                    reading.scale,
                    1,
                    "\(metric.title) is read in its own unit and must not be rescaled."
                )
            }
        }
        XCTAssertGreaterThan(checked, 0, "Precondition: at least one percent metric exists.")
    }

    /// A metric whose values are filed under a day other than the one the
    /// reading started on has made a choice on the reader's behalf, and a
    /// choice nobody can see makes a correct number look like a mistake. This
    /// finds such metrics by exercising the attribution rather than by knowing
    /// which they are, then insists each one says so on screen.
    ///
    /// It checks only that something is said. Whether what is said is *true*
    /// is pinned separately, by
    /// `testTheCaptionNamesTheHourTheRuleActuallyUses` and
    /// `testTheBoundaryInstantItselfCountsTowardsTheNextDay`.
    func testAMetricThatFilesAReadingUnderADifferentDaySaysSoOnScreen() throws {
        let calendar = calendar(newYork)
        let sleep = try XCTUnwrap(
            DashboardMetrics.all.first { $0.kind == .sleep },
            "Precondition: sleep is on offer."
        )

        // Worked by hand against the rule, not read back from it: a night that
        // begins at 23:30 on the 12th is filed under the 13th, and one that
        // begins at 06:00 on the 12th is filed under the 12th. If both landed
        // on the day they started, no explanation would be owed.
        let lateNight = date(2025, 6, 12, 23, 30, zone: newYork)
        let morning = date(2025, 6, 12, 6, 0, zone: newYork)

        let lateNightDay = try XCTUnwrap(
            SleepAttribution.day(forSleepStartingAt: lateNight, calendar: calendar)
        )
        let morningDay = try XCTUnwrap(
            SleepAttribution.day(forSleepStartingAt: morning, calendar: calendar)
        )

        XCTAssertEqual(
            lateNightDay,
            date(2025, 6, 13, 0, 0, zone: newYork),
            "A night beginning before midnight belongs to the morning it ends on."
        )
        XCTAssertEqual(
            morningDay,
            date(2025, 6, 12, 0, 0, zone: newYork),
            "A morning nap belongs to the day it happened on."
        )

        // Established, not assumed: this metric really does re-file a reading.
        XCTAssertNotEqual(
            lateNightDay,
            calendar.startOfDay(for: lateNight),
            "Precondition: sleep attribution is non-obvious, so it owes an explanation."
        )
        XCTAssertNotNil(
            sleep.note,
            "Sleep is filed under a day it did not start on and must say so."
        )
    }

    /// The counterpart: a metric that files a reading under the day it
    /// happened does not need small print, and adding some would be noise.
    /// Nothing here is filed unusually except sleep.
    func testNoOtherMetricCarriesAnUnexplainedNote() {
        for metric in DashboardMetrics.all where metric.kind != .sleep {
            XCTAssertNil(
                metric.note,
                "\(metric.title) is filed under the day it was measured; a note only adds noise."
            )
        }
    }

    /// The caption is written by hand and the boundary is a constant, so
    /// nothing but a test keeps the two saying the same thing. Moving the
    /// constant without rewriting the sentence would leave the app stating a
    /// rule it does not follow, which is worse than stating none: a reader
    /// who is told the rule will believe it and stop questioning the number.
    ///
    /// The hour is spoken here rather than read out of the caption — 18 on a
    /// twenty-four hour clock is six in the evening — so this is a second
    /// opinion on the sentence and not a copy of it.
    func testTheCaptionNamesTheHourTheRuleActuallyUses() throws {
        let sleep = try XCTUnwrap(DashboardMetrics.all.first { $0.kind == .sleep })
        let note = try XCTUnwrap(sleep.note, "Sleep must explain how it files a night.")

        let hour = SleepAttribution.dayBoundaryHour
        let spoken: String = switch hour {
        case 0: "12am"
        case 1..<12: "\(hour)am"
        case 12: "12pm"
        default: "\(hour - 12)pm"
        }

        XCTAssertTrue(
            note.contains(spoken),
            """
            The rule turns on \(spoken), so the caption has to name \(spoken). \
            It says: \(note)
            """
        )
        XCTAssertTrue(
            note.localizedCaseInsensitiveContains("next day"),
            "Sleep past the boundary moves forward a day, and the caption must say so."
        )
    }

    func testEveryMetricOfferedHasAUnitAndAnIdentity() throws {
        var seen: Set<String> = []
        for metric in DashboardMetrics.all {
            XCTAssertTrue(seen.insert(metric.id).inserted, "\(metric.id) is listed twice.")
            XCTAssertNotNil(
                DashboardMetrics.reading(for: metric),
                "\(metric.title) would be read in the wrong unit."
            )
            XCTAssertFalse(metric.unitLabel.isEmpty)
        }
    }

    // MARK: - The shape HealthKit actually returns

    /// HealthKit does not say how many readings a bucket stands for, so the
    /// reader sets `readingCount` to zero and the whole range is asked for
    /// separately. This is that shape, which no other test drives.
    func testASeriesShapedTheWayHealthKitReturnsItSummarisesCorrectly() throws {
        let calendar = calendar(newYork)
        let now = date(2025, 6, 15, 12, zone: newYork)
        let intervals = MetricBucketing.buckets(for: .week, endingAt: now, calendar: calendar)
        let values: [Double?] = [nil, 8_000, 10_000, nil, 12_000, 9_000, 3_000]

        let buckets = zip(intervals, values).map { interval, value in
            MetricBucket(
                interval: interval,
                value: value,
                minimum: value,
                maximum: value,
                readingCount: 0,
                sampleCount: value == nil ? 0 : 1
            )
        }

        // A cumulative type needs no whole-range figure: a sum of sums is the
        // same number however it is grouped.
        let steps = MetricSeries(
            buckets: buckets,
            unit: "count",
            aggregation: .total,
            hasUnitConflict: false,
            containsAggregatedReadings: false
        )
        // By hand: 8,000 + 10,000 + 12,000 + 9,000 + 3,000 = 42,000 over five
        // days with data, so 8,400 each.
        XCTAssertEqual(steps.summary.headline, 42_000)
        XCTAssertEqual(steps.summary.averagePerActiveBucket, 8_400)
        XCTAssertEqual(steps.summary.bucketsWithData, 5)
        XCTAssertTrue(steps.summary.hasData)

        // A measured type carries HealthKit's own whole-range answer.
        let heart = MetricSeries(
            buckets: buckets,
            unit: "count/min",
            aggregation: .average,
            hasUnitConflict: false,
            containsAggregatedReadings: false,
            overall: MetricOverall(value: 58.4, minimum: 41, maximum: 168)
        )
        XCTAssertEqual(heart.summary.headline, 58.4)
        XCTAssertEqual(heart.summary.lowest, 41)
        XCTAssertEqual(heart.summary.highest, 168)
        XCTAssertTrue(heart.summary.hasData)
    }

    /// With neither counts nor a whole-range figure there is no honest average
    /// to report, and the mean of the daily means must not be passed off as
    /// one. Reporting nothing is the correct direction to be wrong in.
    func testAMeasuredSeriesWithNeitherCountsNorAWholeRangeFigureReportsNoAverage() throws {
        let calendar = calendar(newYork)
        let intervals = MetricBucketing.buckets(
            for: .week,
            endingAt: date(2025, 6, 15, 12, zone: newYork),
            calendar: calendar
        )
        let buckets = intervals.enumerated().map { index, interval in
            MetricBucket(
                interval: interval,
                value: index < 2 ? Double(60 + index * 40) : nil,
                minimum: nil,
                maximum: nil,
                readingCount: 0,
                sampleCount: index < 2 ? 1 : 0
            )
        }
        let series = MetricSeries(
            buckets: buckets,
            unit: "count/min",
            aggregation: .average,
            hasUnitConflict: false,
            containsAggregatedReadings: false
        )

        XCTAssertTrue(series.hasAnyData, "There are values to draw.")
        XCTAssertNil(
            series.summary.headline,
            "80 would be the mean of the daily means, which is not the average."
        )
    }

    // MARK: - Sleep, in the shapes a watch actually writes

    /// A watch writes a night as a chain of touching stage samples — core,
    /// deep, REM, core — each beginning exactly where the last ended. They
    /// have to become one stretch, not four.
    func testTouchingSleepStagesBecomeOneStretch() {
        let base = date(2025, 6, 12, 23, zone: newYork)
        let stages = (0..<4).map { index in
            DateInterval(
                start: base.addingTimeInterval(Double(index) * 3_600),
                end: base.addingTimeInterval(Double(index + 1) * 3_600)
            )
        }

        let merged = SleepAttribution.merge(stages)
        XCTAssertEqual(merged.count, 1, "Four touching stages are one night.")
        // Four hours, whether counted as one stretch or four.
        XCTAssertEqual(merged[0].duration, 4 * 3_600)

        let readings = SleepAttribution.readings(from: stages, calendar: calendar(newYork))
        XCTAssertEqual(readings.count, 1, "One night, filed under one day.")
        XCTAssertEqual(readings[0].value, 4, accuracy: 0.000_1)
        XCTAssertEqual(readings[0].start, date(2025, 6, 13, zone: newYork))
    }

    /// A stretch of zero length is not sleep and must not create a day.
    func testZeroLengthSleepIsIgnored() {
        let instant = date(2025, 6, 13, 2, zone: newYork)
        let readings = SleepAttribution.readings(
            from: [DateInterval(start: instant, end: instant)],
            calendar: calendar(newYork)
        )
        XCTAssertTrue(readings.isEmpty)
        XCTAssertTrue(SleepAttribution.merge([DateInterval(start: instant, end: instant)]).isEmpty)
    }

    // MARK: - What a chart is asked to draw

    /// A `ClosedRange` whose bounds are the wrong way round, or not numbers at
    /// all, traps rather than drawing oddly. Health values reaching a chart
    /// have to be checked before they become an axis.
    func testAChartDomainIsAlwaysAValidRange() throws {
        let calendar = calendar(newYork)
        let intervals = MetricBucketing.buckets(
            for: .week,
            endingAt: date(2025, 6, 15, 12, zone: newYork),
            calendar: calendar
        )

        let awkward: [[Double?]] = [
            [nil, nil, nil, nil, nil, nil, nil],
            [0, 0, 0, 0, 0, 0, 0],
            [5, 5, 5, 5, 5, 5, 5],
            [-10, -20, -30, nil, nil, nil, nil],
            [.nan, 5, 6, nil, nil, nil, nil],
            [.infinity, 5, nil, nil, nil, nil, nil],
            [1e12, 1, nil, nil, nil, nil, nil],
            [42, nil, nil, nil, nil, nil, nil]
        ]

        for values in awkward {
            for aggregation in [MetricAggregation.total, .average] {
                let series = MetricSeries(
                    buckets: zip(intervals, values).map { interval, value in
                        MetricBucket(
                            interval: interval,
                            value: value,
                            minimum: value,
                            maximum: value,
                            readingCount: 0,
                            sampleCount: value == nil ? 0 : 1
                        )
                    },
                    unit: "count",
                    aggregation: aggregation,
                    hasUnitConflict: false,
                    containsAggregatedReadings: false
                )

                let domain = series.domain()
                XCTAssertLessThanOrEqual(
                    domain.lowerBound,
                    domain.upperBound,
                    "\(values) as \(aggregation) produced an inverted range."
                )
                XCTAssertTrue(
                    domain.lowerBound.isFinite && domain.upperBound.isFinite,
                    "\(values) as \(aggregation) produced a domain that is not a number."
                )

                // And nothing that is not a number reaches a mark.
                for point in series.plottable(now: .now) {
                    XCTAssertTrue(point.value.isFinite)
                }
            }
        }
    }

    // MARK: - Workouts

    /// A triathlon's `allStatistics` holds swimming, cycling and running
    /// distances at once, because it describes the whole workout rather than
    /// one leg of it. Reporting any one of them as "distance" for the event is
    /// wrong, and summing them is worse — metres swum and metres ridden are
    /// not the same quantity.
    func testAWorkoutThatRecordedSeveralDistancesReportsNoSingleOne() {
        let triathlon: [HKQuantityTypeIdentifier: Double] = [
            .distanceSwimming: 1_500,
            .distanceCycling: 40_000,
            .distanceWalkingRunning: 10_000
        ]
        XCTAssertNil(
            HealthMetricReader.soleDistance(triathlon),
            "10 km would be the run's, and 51.5 km is not a distance anyone travelled."
        )
    }

    func testAnOrdinaryRunReportsItsOwnDistance() {
        XCTAssertEqual(
            HealthMetricReader.soleDistance([.distanceWalkingRunning: 7_240]),
            7_240
        )
        XCTAssertEqual(
            HealthMetricReader.soleDistance([.distanceSwimming: 1_500]),
            1_500
        )
    }

    /// A type present but measuring nothing is not a second kind of distance.
    func testAZeroDistanceDoesNotCountAsASecondKind() {
        XCTAssertEqual(
            HealthMetricReader.soleDistance([
                .distanceWalkingRunning: 5_000,
                .distanceCycling: 0
            ]),
            5_000
        )
    }

    func testAWorkoutThatMeasuredNoDistanceReportsNone() {
        XCTAssertNil(HealthMetricReader.soleDistance([:]))
        XCTAssertNil(HealthMetricReader.soleDistance([.distanceCycling: 0]))
    }

    // MARK: - Electrocardiograms

    /// A spike a few readings wide is the one feature of a trace anyone looks
    /// at. Sampling every nth reading walks straight past it; keeping both
    /// extremes of each column cannot.
    func testDecimationKeepsASpikeThatPlainSamplingWouldMiss() throws {
        let hertz = 512
        var points = (0..<hertz).map { index in
            ECGPoint(
                secondsSinceStart: Double(index) / Double(hertz),
                microvolts: 10
            )
        }
        // One reading, in the middle, far above the rest.
        points[256] = ECGPoint(secondsSinceStart: 256 / 512.0, microvolts: 900)

        // Independently: taking every 8th reading steps 0, 8, 16 … 256 is a
        // multiple of 8, so shift the spike one sample to make plain sampling
        // genuinely miss it.
        points[257] = points[256]
        points[256] = ECGPoint(secondsSinceStart: 256 / 512.0, microvolts: 10)
        let sampled = stride(from: 0, to: points.count, by: 8).map { points[$0].microvolts }
        XCTAssertEqual(sampled.max(), 10, "Precondition: plain sampling misses the spike.")

        let envelope = ECGDecimation.envelope(points, buckets: 64)
        XCTAssertEqual(envelope.count, 64)
        XCTAssertEqual(
            envelope.map(\.high).max(),
            900,
            "The spike has to survive being shrunk, or the trace is a lie."
        )
        XCTAssertEqual(envelope.map(\.low).min(), 10)
    }

    func testDecimationHandlesTraceShapesThatWouldOtherwiseCrash() {
        XCTAssertTrue(ECGDecimation.envelope([], buckets: 100).isEmpty)
        XCTAssertTrue(
            ECGDecimation.envelope(
                [ECGPoint(secondsSinceStart: 0, microvolts: 5)],
                buckets: 0
            ).isEmpty
        )
        // Fewer readings than columns: each becomes its own column rather than
        // being merged into nothing.
        let few = (0..<3).map {
            ECGPoint(secondsSinceStart: Double($0), microvolts: Double($0))
        }
        XCTAssertEqual(ECGDecimation.envelope(few, buckets: 50).count, 3)
        XCTAssertEqual(ECGDecimation.envelope(few, buckets: 3).count, 3)
    }

    /// The rule the ECG view exists to keep.
    func testATraceIsOnlyWholeWhenEveryReadingItClaimsArrived() {
        let points = (0..<100).map {
            ECGPoint(secondsSinceStart: Double($0), microvolts: 1)
        }
        XCTAssertTrue(
            ECGWaveform(
                sampleID: UUID(),
                points: points,
                expectedCount: 100,
                samplingFrequencyHertz: 512
            ).isComplete
        )
        XCTAssertFalse(
            ECGWaveform(
                sampleID: UUID(),
                points: points,
                expectedCount: 15_360,
                samplingFrequencyHertz: 512
            ).isComplete,
            "A hundred of fifteen thousand readings is not a heartbeat."
        )
        XCTAssertFalse(
            ECGWaveform(
                sampleID: UUID(),
                points: [],
                expectedCount: 0,
                samplingFrequencyHertz: nil
            ).isComplete,
            "A recording claiming no readings cannot be vouched for as whole."
        )
    }

    // MARK: - Ranges

    func testEachRangeAsksForTheNumberOfBucketsItPromises() throws {
        let calendar = calendar(newYork)
        let now = date(2025, 6, 15, 12, zone: newYork)
        for range in MetricRange.allCases {
            let buckets = MetricBucketing.buckets(for: range, endingAt: now, calendar: calendar)
            XCTAssertEqual(
                buckets.count,
                range.bucketCount,
                "\(range.title) promised \(range.bucketCount) buckets."
            )
            let last = try XCTUnwrap(buckets.last)
            XCTAssertTrue(
                last.start <= now && now < last.end,
                "The last bucket of \(range.title) must hold the moment asked about."
            )
        }
    }
}
