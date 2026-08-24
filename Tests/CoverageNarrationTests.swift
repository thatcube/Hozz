import Foundation
import HozzCore
@testable import HozzReceive
import XCTest

/// What a person is allowed to be told, once the phone has said how completely
/// a type was read.
///
/// The rule these all turn on: a date held for a type whose sweep is unfinished
/// is the date of the newest record *received*, and presenting it as the
/// person's own latest is a claim the data cannot support. On Brandon's
/// archive that claim was false and cruel — "Step Count · as of Jan 2023",
/// shown to someone who wears a watch daily and is largely bedbound.
final class CoverageNarrationTests: XCTestCase {
    /// 2022-12-11T20:05:37Z, the instant from the real row.
    private static let latest = Date(timeIntervalSince1970: 1_670_793_937)

    private static func report(
        _ state: CoverageState,
        primedFrom: Date? = nil,
        primedThrough: Date? = nil
    ) -> TypeCoverageReport {
        TypeCoverageReport(
            type: "HKQuantityTypeIdentifierStepCount",
            state: state,
            deliveredCount: 19,
            primedFrom: primedFrom,
            primedThrough: primedThrough,
            observedAt: Date(timeIntervalSince1970: 1_772_600_767)
        )
    }

    private static func snapshot(
        standing: TypeCoverageStanding,
        daysWithData: Int = 30,
        dayCount: Int = 30,
        headline: Double? = 19_114.55,
        latestOverall: Date? = CoverageNarrationTests.latest,
        isFromEarlierWindow: Bool,
        windowStart: Date = Date(timeIntervalSince1970: 1_668_124_800),
        windowEnd: Date = Date(timeIntervalSince1970: 1_670_803_200),
        readingsPerSample: Int = 1
    ) -> IngestStore.MetricSnapshot {
        let measure = HealthMeasure(
            type: "HKQuantityTypeIdentifierStepCount",
            kind: .total,
            storedUnit: ""
        )
        let columns = [
            SeriesColumn(
                index: 0,
                start: windowStart,
                end: windowEnd,
                total: headline ?? 0,
                weightedSum: headline ?? 0,
                weight: headline == nil ? 0 : 1,
                minimum: headline,
                maximum: headline,
                sampleCount: headline == nil ? 0 : 19,
                countedCount: headline == nil ? 0 : 19,
                readingCount: headline == nil ? 0 : 19 * readingsPerSample,
                daysWithData: daysWithData,
                dayCount: dayCount,
                durationSeconds: 0
            )
        ]
        return IngestStore.MetricSnapshot(
            series: TypeSeries(
                measure: measure,
                columns: columns,
                granularity: .day,
                units: [],
                coverage: SeriesCoverage(
                    daysWithData: daysWithData,
                    dayCount: dayCount,
                    firstSample: nil,
                    lastSample: nil
                )
            ),
            latestOverall: latestOverall,
            totalRecords: 19,
            isFromEarlierWindow: isFromEarlierWindow,
            standing: standing
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

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    /// The fixture instant, arrived at without the formatter under test.
    func testTheFixtureDateIsTheDayItIsCalled() {
        XCTAssertEqual(Self.month(Self.latest), "Dec 2022")
        XCTAssertEqual(Self.day(Self.latest), "11 Dec 2022")
    }

    // MARK: - Only a finished sweep licenses a date

    /// The exact row from the bug, now with the phone saying the sweep for
    /// this type has *not* finished.
    func testAnUnfinishedTypeNeverPresentsItsNewestArrivalAsTheNewestThereIs() {
        let row = Self.snapshot(
            standing: .incomplete(Self.report(.draining)),
            daysWithData: 2,
            isFromEarlierWindow: true
        )
        let caption = row.rowCaption(monthName: Self.month)
        XCTAssertEqual(caption, "received to Dec 2022 · total · 2/30 days")
        XCTAssertFalse(caption.contains("as of"), caption)
    }

    /// The same row, with the phone saying the sweep ran out of records. Now
    /// the flattering wording is earned: December really was the last of it.
    func testAFinishedTypeMaySayAsOfBecauseItHasBeenToldSo() {
        let row = Self.snapshot(
            standing: .complete(Self.report(.anchorClosed)),
            daysWithData: 2,
            isFromEarlierWindow: true
        )
        XCTAssertEqual(
            row.rowCaption(monthName: Self.month),
            "as of Dec 2022 · total · 2/30 days"
        )
    }

    /// Absence of a report is not evidence of completeness. Nothing said means
    /// nothing claimed.
    func testATypeNothingHasBeenSaidAboutIsWordedLikeAnUnfinishedOne() {
        let row = Self.snapshot(standing: .untold, daysWithData: 2, isFromEarlierWindow: true)
        let caption = row.rowCaption(monthName: Self.month)
        XCTAssertTrue(caption.hasPrefix("received to "), caption)
        XCTAssertFalse(caption.contains("as of"), caption)
    }

    /// Written as a sweep over every state rather than case by case, so a
    /// state added later cannot quietly acquire a licence it was never given.
    func testNoStateButAClosedAnchorEverSaysAsOf() {
        for state in CoverageState.allCoverageStates {
            let report = Self.report(state)
            let row = Self.snapshot(
                standing: TypeCoverageStanding(report: report),
                daysWithData: 2,
                isFromEarlierWindow: true
            )
            let caption = row.rowCaption(monthName: Self.month)
            if state == .anchorClosed {
                XCTAssertTrue(caption.hasPrefix("as of "), "\(state.rawValue): \(caption)")
            } else {
                XCTAssertFalse(caption.contains("as of"), "\(state.rawValue): \(caption)")
            }
        }
    }

    /// A row with no values at all still names a month, and that month is
    /// still a claim.
    func testAnEmptyRowDoesNotCallItsNewestArrivalTheLast() {
        let unfinished = Self.snapshot(
            standing: .incomplete(Self.report(.draining)),
            daysWithData: 0,
            headline: nil,
            isFromEarlierWindow: true
        )
        XCTAssertEqual(
            unfinished.rowCaption(monthName: Self.month),
            "Nothing yet · received to Dec 2022"
        )
        let finished = Self.snapshot(
            standing: .complete(Self.report(.anchorClosed)),
            daysWithData: 0,
            headline: nil,
            isFromEarlierWindow: true
        )
        XCTAssertEqual(
            finished.rowCaption(monthName: Self.month),
            "Nothing yet · last Dec 2022"
        )
    }

    // MARK: - A figure that is not all here says so where it cannot be cut off

    /// A row drawn from the range asked for looks entirely current. During a
    /// first sweep almost none of them are, and silence in this slot reads as
    /// a complete figure.
    func testACurrentLookingRowStillSaysWhenItsRecordsAreNotAllHere() {
        XCTAssertEqual(
            Self.snapshot(
                standing: .incomplete(Self.report(.draining)),
                isFromEarlierWindow: false
            ).rowCaption(monthName: Self.month),
            "still arriving · total"
        )
        XCTAssertEqual(
            Self.snapshot(standing: .untold, isFromEarlierWindow: false)
                .rowCaption(monthName: Self.month),
            "may be incomplete · total"
        )
        XCTAssertEqual(
            Self.snapshot(
                standing: .complete(Self.report(.anchorClosed)),
                isFromEarlierWindow: false
            ).rowCaption(monthName: Self.month),
            "total",
            "a finished type has nothing to apologise for"
        )
    }

    /// The qualifier goes first because the caption is one line and truncates
    /// from the right. A warning that disappears on a narrow window is not a
    /// warning.
    func testTheQualifierCannotBeTruncatedAway() {
        for standing in [
            TypeCoverageStanding.untold,
            .incomplete(Self.report(.draining))
        ] {
            let caption = Self.snapshot(standing: standing, isFromEarlierWindow: false)
                .rowCaption(monthName: Self.month)
            XCTAssertTrue(
                caption.hasPrefix("still arriving") || caption.hasPrefix("may be incomplete"),
                caption
            )
        }
    }

    // MARK: - The gap a primed window leaves

    /// A dated query fills the recent weeks while the sweep is still years
    /// back, so the archive is dense at both ends and empty in the middle.
    /// Anything counting records sees a healthy type.
    func testAPrimedWindowWithAnUnfinishedSweepIsTwoRegionsWithAHole() {
        let standing = TypeCoverageStanding(
            report: Self.report(
                .draining,
                primedFrom: Date(timeIntervalSince1970: 1_764_547_200),
                primedThrough: Date(timeIntervalSince1970: 1_772_236_800)
            )
        )
        XCTAssertTrue(standing.hasGap)
        XCTAssertFalse(standing.licensesLatestDate)
        XCTAssertNotNil(standing.primedWindow)

        let sentence = OverviewNarration.completeness(
            standing,
            latest: Self.latest,
            day: Self.day
        )
        XCTAssertTrue(sentence.contains("gap"), sentence)
        // Midnight UTC on 1 December is the evening of 30 November where the
        // dashboard is being read, and the sentence is written in the reader's
        // own days.
        XCTAssertTrue(sentence.contains("30 Nov 2025"), sentence)
        XCTAssertTrue(
            sentence.contains("not a gap in your history"),
            "the hole is in the transfer, and the sentence has to say so: \(sentence)"
        )
    }

    /// A window drawn entirely inside a primed stretch is genuinely complete,
    /// even while the sweep behind it is years away. Saying otherwise would be
    /// alarm the data does not support.
    func testAWindowInsideAPrimedStretchIsNotHedged() {
        let from = Date(timeIntervalSince1970: 1_764_547_200)
        let through = Date(timeIntervalSince1970: 1_772_236_800)
        let inside = Self.snapshot(
            standing: TypeCoverageStanding(
                report: Self.report(.draining, primedFrom: from, primedThrough: through)
            ),
            isFromEarlierWindow: false,
            windowStart: from.addingTimeInterval(86_400),
            windowEnd: through.addingTimeInterval(-86_400)
        )
        XCTAssertTrue(inside.shownWindowIsFullyHeld)
        XCTAssertEqual(inside.rowCaption(monthName: Self.month), "total")

        let straddling = Self.snapshot(
            standing: TypeCoverageStanding(
                report: Self.report(.draining, primedFrom: from, primedThrough: through)
            ),
            isFromEarlierWindow: false,
            windowStart: from.addingTimeInterval(-86_400),
            windowEnd: through
        )
        XCTAssertFalse(
            straddling.shownWindowIsFullyHeld,
            "one day older than the primed stretch is one day nobody promised"
        )
        XCTAssertEqual(
            straddling.rowCaption(monthName: Self.month),
            "still arriving · total"
        )
    }

    func testAFinishedSweepMakesEveryWindowFullyHeld() {
        let row = Self.snapshot(
            standing: .complete(Self.report(.anchorClosed)),
            isFromEarlierWindow: false,
            windowStart: Date(timeIntervalSince1970: 0),
            windowEnd: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertTrue(row.shownWindowIsFullyHeld)
    }

    /// A dated read fetches the *samples* in its window. For a high-frequency
    /// type each of those is an aggregate standing for hundreds of underlying
    /// readings, and the chart is drawn from the readings — which a prime does
    /// not fetch. So a primed window promises the containers and not the
    /// contents, and a heart-rate row that dropped its qualifier on the
    /// strength of one would read as complete while most of its readings were
    /// still weeks behind in the sweep.
    func testAPrimedWindowDoesNotVouchForReadingsInsideAggregatedSamples() {
        let from = Date(timeIntervalSince1970: 1_764_547_200)
        let through = Date(timeIntervalSince1970: 1_772_236_800)
        let standing = TypeCoverageStanding(
            report: Self.report(.draining, primedFrom: from, primedThrough: through)
        )
        let aggregated = Self.snapshot(
            standing: standing,
            isFromEarlierWindow: false,
            windowStart: from.addingTimeInterval(86_400),
            windowEnd: through.addingTimeInterval(-86_400),
            readingsPerSample: 500
        )
        XCTAssertTrue(aggregated.series.hasAggregatedSamples)
        XCTAssertFalse(aggregated.shownWindowIsFullyHeld)
        XCTAssertEqual(
            aggregated.rowCaption(monthName: Self.month),
            "still arriving · total"
        )
    }

    /// A finished sweep does carry the readings, so aggregation changes
    /// nothing there. Saying otherwise would be alarm the data does not
    /// support, which is its own kind of dishonesty.
    func testAFinishedSweepVouchesForAggregatedReadingsToo() {
        let row = Self.snapshot(
            standing: .complete(Self.report(.anchorClosed)),
            isFromEarlierWindow: false,
            readingsPerSample: 500
        )
        XCTAssertTrue(row.series.hasAggregatedSamples)
        XCTAssertTrue(row.shownWindowIsFullyHeld)
        XCTAssertEqual(row.rowCaption(monthName: Self.month), "total")
    }

    // MARK: - The long sentence, for the places with room

    func testAFinishedTypeIsDescribedAsFinishedAndAsNothingElse() {
        let sentence = OverviewNarration.completeness(
            .complete(Self.report(.anchorClosed)),
            latest: Self.latest,
            day: Self.day
        )
        XCTAssertTrue(sentence.contains("finished reading this type"), sentence)
        XCTAssertTrue(sentence.contains("11 Dec 2022"), sentence)
        XCTAssertFalse(
            sentence.contains("still"),
            "a finished type must not be told more is coming: \(sentence)"
        )
        XCTAssertFalse(sentence.contains("often arrive last"), sentence)
    }

    /// The wording this replaced explained the sweep whether or not the sweep
    /// was still running, which is hedging rather than accuracy.
    func testAnUnfinishedTypeExplainsWhyItsNewestIsNotTheNewest() {
        let sentence = OverviewNarration.completeness(
            .incomplete(Self.report(.draining)),
            latest: Self.latest,
            day: Self.day
        )
        XCTAssertTrue(sentence.contains("still reading this type"), sentence)
        XCTAssertTrue(sentence.contains("not necessarily your newest"), sentence)
        XCTAssertTrue(sentence.contains("11 Dec 2022"), sentence)
    }

    /// HealthKit answers identically for a type with no records and one that
    /// was never granted. Neither of those is "you have none of this".
    func testAnIndeterminateTypeSaysHealthWouldNotSayWhich() {
        let sentence = OverviewNarration.completeness(
            .incomplete(Self.report(.authorizationIndeterminate)),
            latest: nil,
            day: Self.day
        )
        XCTAssertTrue(sentence.contains("no records"), sentence)
        XCTAssertTrue(sentence.contains("never granted"), sentence)
        XCTAssertFalse(sentence.contains("finished reading this type,"), sentence)
    }

    func testATypeNothingWasSaidAboutClaimsNeitherWay() {
        let sentence = OverviewNarration.completeness(
            .untold,
            latest: Self.latest,
            day: Self.day
        )
        XCTAssertTrue(sentence.contains("has not said"), sentence)
        XCTAssertTrue(sentence.contains("may or may not"), sentence)
    }

    /// Every standing has to produce a sentence, and none of them may be the
    /// old blanket hedge.
    func testEveryStandingHasSomethingTrueToSay() {
        let standings: [TypeCoverageStanding] = [.untold]
            + CoverageState.allCoverageStates.map {
                TypeCoverageStanding(report: Self.report($0))
            }
        for standing in standings {
            for latest in [Self.latest, nil] {
                let sentence = OverviewNarration.completeness(
                    standing,
                    latest: latest,
                    day: Self.day
                )
                XCTAssertFalse(sentence.isEmpty)
                XCTAssertFalse(
                    sentence.contains("often arrive last"),
                    "the hedge this replaced: \(sentence)"
                )
                if !standing.licensesLatestDate, latest != nil {
                    XCTAssertFalse(
                        sentence.contains("really is your most recent"),
                        "\(sentence)"
                    )
                }
            }
        }
    }

    // MARK: - The one-clause version, for rows

    func testOnlyAFinishedTypeIsAllowedToSayNothing() {
        XCTAssertNil(TypeCoverageStanding.complete(Self.report(.anchorClosed)).qualifier)
        XCTAssertNotNil(TypeCoverageStanding.untold.qualifier)
        XCTAssertNotNil(
            TypeCoverageStanding.incomplete(Self.report(.draining)).qualifier
        )
        XCTAssertEqual(
            TypeCoverageStanding.incomplete(Self.report(.draining)).qualifier,
            "still arriving"
        )
    }
}
