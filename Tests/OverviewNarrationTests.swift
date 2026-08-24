import XCTest
@testable import HozzReceive

/// What the overview's words claim about the data underneath them.
///
/// Every one of these pins a sentence a person reads and acts on. The bug that
/// prompted the file: a cycling row built from two days of records inside a
/// thirty-day window read "as of Dec 2022 · total" — true, and quietly missing
/// the only part that would have stopped someone reading 19.11 km as a month.
final class OverviewNarrationTests: XCTestCase {
    private static func snapshot(
        type: String = "HKQuantityTypeIdentifierDistanceCycling",
        kind: MeasureKind = .total,
        unit: String = "m",
        daysWithData: Int,
        dayCount: Int,
        headline: Double? = 19_114.55,
        latestOverall: Date? = Date(timeIntervalSince1970: 1_670_793_937),
        isFromEarlierWindow: Bool
    ) -> IngestStore.MetricSnapshot {
        let measure = HealthMeasure(type: type, kind: kind, storedUnit: unit)
        let columns = [
            SeriesColumn(
                index: 0,
                start: Date(timeIntervalSince1970: 1_668_124_800),
                end: Date(timeIntervalSince1970: 1_670_803_200),
                total: headline ?? 0,
                weightedSum: headline ?? 0,
                weight: headline == nil ? 0 : 1,
                minimum: headline,
                maximum: headline,
                sampleCount: headline == nil ? 0 : 19,
                countedCount: headline == nil ? 0 : 19,
                readingCount: headline == nil ? 0 : 19,
                daysWithData: daysWithData,
                dayCount: dayCount,
                durationSeconds: 0
            )
        ]
        let series = TypeSeries(
            measure: measure,
            columns: columns,
            granularity: .day,
            units: unit.isEmpty ? [] : [unit],
            coverage: SeriesCoverage(
                daysWithData: daysWithData,
                dayCount: dayCount,
                firstSample: nil,
                lastSample: nil
            )
        )
        return IngestStore.MetricSnapshot(
            series: series,
            latestOverall: latestOverall,
            totalRecords: 19,
            isFromEarlierWindow: isFromEarlierWindow
        )
    }

    /// Fixed so a locale cannot decide half the sentence under test.
    private static func month(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }

    // MARK: - A number has to say how many days it came from

    /// The real row from Brandon's archive: 19.11 km that came from two days.
    ///
    /// The figure is genuine and so is its age; what was missing is that it is
    /// two days of a thirty-day window, which is the difference between a quiet
    /// month and two rides.
    func testAStaleRowStillSaysHowManyDaysItsNumberCameFrom() {
        let row = Self.snapshot(daysWithData: 2, dayCount: 30, isFromEarlierWindow: true)
        XCTAssertEqual(
            row.rowCaption(monthName: Self.month),
            "received to Dec 2022 · total · 2/30 days"
        )
    }

    /// The same row before the fix, spelled out so the regression is nameable.
    func testAStaleRowsCaptionIsNotJustItsAgeAndAggregation() {
        let row = Self.snapshot(daysWithData: 2, dayCount: 30, isFromEarlierWindow: true)
        XCTAssertNotEqual(
            row.rowCaption(monthName: Self.month),
            "received to Dec 2022 · total"
        )
    }

    func testAStaleRowThatIsGenuinelyCompleteDoesNotClaimPartialCoverage() {
        let row = Self.snapshot(daysWithData: 30, dayCount: 30, isFromEarlierWindow: true)
        XCTAssertEqual(
            row.rowCaption(monthName: Self.month),
            "received to Dec 2022 · total"
        )
    }

    /// A row from the range asked for still says how much of it is there —
    /// and, since nothing has said this type is finished, that the figure may
    /// not be all of it. Before the phone sent its coverage there was no
    /// honest way to write the second half of that sentence.
    func testACurrentRowSaysCoverageWithoutSayingWhenItArrived() {
        let row = Self.snapshot(daysWithData: 11, dayCount: 30, isFromEarlierWindow: false)
        XCTAssertEqual(
            row.rowCaption(monthName: Self.month),
            "may be incomplete · total · 11/30 days"
        )
        XCTAssertFalse(row.rowCaption(monthName: Self.month).contains("received to"))
    }

    /// A row with nothing in the window still names a month, and that month is
    /// still a claim. Nothing has said this type is finished, so it is
    /// described as the newest thing that arrived rather than the last there
    /// was — `CoverageNarrationTests` pins both halves of that.
    func testARowWithNoValuesSaysSoRatherThanReportingZero() {
        let row = Self.snapshot(
            daysWithData: 0,
            dayCount: 30,
            headline: nil,
            isFromEarlierWindow: true
        )
        XCTAssertEqual(
            row.rowCaption(monthName: Self.month),
            "Nothing yet · received to Dec 2022"
        )
    }

    func testARowWithNoValuesAndNoHistoryDoesNotInventADate() {
        let row = Self.snapshot(
            daysWithData: 0,
            dayCount: 30,
            headline: nil,
            latestOverall: nil,
            isFromEarlierWindow: true
        )
        XCTAssertEqual(row.rowCaption(monthName: Self.month), "No values yet")
    }

    // MARK: - A row must not report the transfer as the person

    /// The receiver records that batches arrived and is never told a type is
    /// finished, so it cannot tell a person who stopped walking in Jan 2023
    /// from a sweep that has carried step count only as far as Jan 2023. It
    /// said "as of Jan 2023", which picks the first reading and states it.
    ///
    /// On the maintainer's own archive the first reading was false and the
    /// second true: he wears a watch daily, and his stand hours prove
    /// continuous wear two years past the month this row named. The wording has
    /// to be true whichever case it is, which is the whole of the first rule.
    func testAStaleRowDescribesWhatArrivedRatherThanWhatTheBodyDid() {
        let row = Self.snapshot(
            type: "HKQuantityTypeIdentifierStepCount",
            daysWithData: 2,
            dayCount: 30,
            isFromEarlierWindow: true
        )
        let caption = row.rowCaption(monthName: Self.month)
        XCTAssertTrue(
            caption.hasPrefix("received to "),
            "a stale row describes arrival, got: \(caption)"
        )
        // "as of <month>" reads as a fact about the person. Nothing on this row
        // is entitled to state one.
        XCTAssertFalse(caption.contains("as of"), caption)
    }

    func testNoHeadingClaimsTheDataItselfRanOut() {
        for range in ChartRange.allCases {
            let heading = OverviewNarration.heading(range: range, staleRows: 4, totalRows: 4)
            XCTAssertFalse(heading.contains("as of"), heading)
            XCTAssertTrue(heading.contains("reached this computer"), heading)
        }
    }

    // MARK: - The slot under the number holds a unit or nothing

    /// Step Count and Apple Stand Hour, the two rows that showed the bug: both
    /// are counts with no unit, and both printed their aggregation where the
    /// row above prints "kcal".
    func testATypeWithNoUnitPrintsNothingRatherThanItsAggregation() {
        for kind in [MeasureKind.total, .occurrences] {
            let row = Self.snapshot(
                type: "HKQuantityTypeIdentifierStepCount",
                kind: kind,
                unit: "",
                daysWithData: 30,
                dayCount: 30,
                isFromEarlierWindow: false
            )
            XCTAssertNil(row.unitLabel, "kind \(kind.rawValue)")
        }
    }

    func testATypeWithAUnitStillShowsIt() {
        let row = Self.snapshot(
            type: "HKQuantityTypeIdentifierActiveEnergyBurned",
            unit: "kcal",
            daysWithData: 30,
            dayCount: 30,
            isFromEarlierWindow: false
        )
        XCTAssertEqual(row.unitLabel, "kcal")
    }

    /// The word that used to appear in the unit slot must not appear in it
    /// again, whatever a future aggregation is called.
    func testNoAggregationNameEverReachesTheUnitSlot() {
        let nouns = Set(MeasureKind.allCases.map { $0.noun.lowercased() })
        XCTAssertTrue(nouns.contains("total"), "the word from the bug is in the set")
        XCTAssertTrue(nouns.contains("count"), "the word from the bug is in the set")
        for kind in MeasureKind.allCases {
            let row = Self.snapshot(
                kind: kind,
                unit: "",
                daysWithData: 30,
                dayCount: 30,
                isFromEarlierWindow: false
            )
            if let label = row.unitLabel {
                XCTAssertFalse(
                    nouns.contains(label.lowercased()),
                    "\(kind.rawValue) put its aggregation in the unit slot"
                )
            }
        }
    }

    // MARK: - The heading does not argue with itself

    func testAHeadingDoesNotNameAWindowNoRowReaches() {
        let heading = OverviewNarration.heading(range: .month, staleRows: 7, totalRows: 7)
        XCTAssertEqual(
            heading,
            "Nothing in the past thirty days has reached this computer yet — "
                + "each row shows the most recent stretch that has."
        )
        XCTAssertFalse(heading.hasPrefix(ChartRange.month.windowTitle))
    }

    func testAHeadingWithSomeStaleRowsCountsThem() {
        XCTAssertEqual(
            OverviewNarration.heading(range: .month, staleRows: 3, totalRows: 7),
            "Past thirty days — 3 of 7 have not reached it yet and show the "
                + "most recent stretch that has."
        )
    }

    func testAHeadingWithNothingStaleIsJustTheWindow() {
        XCTAssertEqual(
            OverviewNarration.heading(range: .week, staleRows: 0, totalRows: 7),
            "Past seven days"
        )
    }

    /// Every range has to read as English in both sentences it can appear in.
    /// Written out by hand rather than derived, so the expectation is an
    /// independent statement of the answer.
    func testEveryRangeReadsAsEnglishInBothSentences() {
        let expected: [ChartRange: (String, String)] = [
            .week: ("Past seven days", "the past seven days"),
            .month: ("Past thirty days", "the past thirty days"),
            .year: ("Past year", "the past year"),
            .all: ("Everything held", "the range held")
        ]
        XCTAssertEqual(
            Set(expected.keys), Set(ChartRange.allCases),
            "a range was added without deciding how it reads"
        )
        for range in ChartRange.allCases {
            guard let pair = expected[range] else { continue }
            XCTAssertEqual(range.windowTitle, pair.0)
            XCTAssertEqual(range.windowNoun, pair.1)
            XCTAssertEqual(
                OverviewNarration.heading(range: range, staleRows: 2, totalRows: 2),
                "Nothing in \(pair.1) has reached this computer yet — each row "
                    + "shows the most recent stretch that has."
            )
        }
    }
}
