import Foundation
import HozzCore
@testable import HozzReceive
import XCTest

/// Every coverage state has to have its own words.
///
/// This suite exists because of a stream on Brandon's own phone. Workout
/// routes delivered 541 records, hit an error nobody had classified, and
/// stopped. Every surface reported it as "still arriving" for weeks, because
/// `TypeCoverageStanding` mapped every non-closed state onto one sentence —
/// the same collapse the whole coverage signal was built to remove, inside the
/// code built to remove it.
///
/// So the checks here are deliberately exhaustive rather than a sample. A
/// state added later must fail this file rather than quietly inherit a
/// sentence that does not describe it.
final class CoverageStateWordsTests: XCTestCase {
    private static let observed = Date(timeIntervalSince1970: 1_772_600_767)
    private static let latest = Date(timeIntervalSince1970: 1_670_793_937)

    private static func standing(_ state: CoverageState) -> TypeCoverageStanding {
        TypeCoverageStanding(
            report: TypeCoverageReport(
                type: "HKWorkoutRouteTypeIdentifier",
                state: state,
                deliveredCount: 541,
                observedAt: observed
            )
        )
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    /// Every state, from the enum itself.
    ///
    /// Derived rather than written out, because a hand-kept copy cannot fail
    /// when a case is added — which is the one thing this file exists to do.
    /// There were three such copies before a review pointed out that the test
    /// claiming to catch a new state was comparing one literal list against
    /// another twelve lines below it.
    private static let everyState = CoverageState.allCases

    func testTheListOfStatesIsTheWholeList() {
        // The expectation is written out; the subject is derived. That way
        // adding a case fails here — deliberately, so somebody has to decide
        // what it means — while the rest of the file picks it up automatically.
        XCTAssertEqual(
            Set(Self.everyState.map(\.rawValue)),
            [
                "unknown", "draining", "anchorClosed",
                "authorizationIndeterminate", "limitedAuthorizationWindow",
                "deviceLockedDeferred", "tombstoneGapSuspected", "unsupported",
                "unverifiedOnDevice", "authorizationDismissed", "readFailed"
            ],
            "a coverage state was added or renamed; give it words below"
        )
    }

    // MARK: - A stopped stream is not a working one

    /// The row from Brandon's phone, in the state it is actually in.
    func testAStreamThatFailedIsNotDescribedAsStillArriving() {
        let standing = Self.standing(.readFailed)
        XCTAssertEqual(standing.motion, .stopped)
        XCTAssertEqual(standing.qualifier?.contains("still arriving"), false)

        let sentence = OverviewNarration.completeness(
            standing,
            latest: Self.latest,
            day: Self.day
        )
        XCTAssertFalse(
            sentence.contains("still reading"),
            "a stream that stopped must not be reported as working: \(sentence)"
        )
        XCTAssertTrue(sentence.contains("stopped rather than paused"), sentence)
    }

    /// And it must say whose fault it is, because the previous wording invited
    /// a housebound person to wonder what he had done.
    func testAFaultInHozzIsNamedAsAFaultInHozz() {
        let sentence = OverviewNarration.completeness(
            Self.standing(.readFailed),
            latest: nil,
            day: Self.day
        )
        XCTAssertTrue(
            sentence.contains("fault in Hozz"),
            sentence
        )
        XCTAssertTrue(
            sentence.contains("rather than anything about you"),
            sentence
        )
    }

    /// Only a genuinely running sweep may claim to be running.
    func testExactlyOneStateIsDescribedAsArriving() {
        let arriving = Self.everyState.filter {
            Self.standing($0).motion == .arriving
        }
        // Built through the public initialiser, which is the only way a
        // standing is ever made: `anchorClosed` becomes `.complete` there, so
        // `draining` is the sole state that can present as still going.
        XCTAssertEqual(arriving, [.draining])
        XCTAssertEqual(
            TypeCoverageStanding.complete(
                TypeCoverageReport(
                    type: "t",
                    state: .anchorClosed,
                    observedAt: Self.observed
                )
            ).motion,
            .stopped,
            "a finished sweep is not still going"
        )
    }

    /// A lock clears itself; a denial does not. Reporting them the same way
    /// either invents an action for something that needs none, or hides one
    /// that does.
    func testOnlyASelfClearingStopIsCalledPaused() {
        let paused = Self.everyState.filter {
            Self.standing($0).motion == .paused
        }
        XCTAssertEqual(paused, [.deviceLockedDeferred])
    }

    // MARK: - Nothing borrows anybody else's sentence

    func testEveryStateGetsWordsOfItsOwn() throws {
        var seen: [String: CoverageState] = [:]
        for state in Self.everyState {
            let standing = Self.standing(state)
            guard case .incomplete = standing else {
                // `anchorClosed` becomes `.complete`, which deliberately says
                // nothing at all.
                XCTAssertEqual(state, .anchorClosed)
                XCTAssertNil(standing.qualifier)
                continue
            }
            // `XCTUnwrap` rather than a force, so a state with no words fails
            // this test instead of taking the whole runner down with it.
            let qualifier = try XCTUnwrap(
                standing.qualifier,
                "\(state.rawValue) has no words at all"
            )
            if let other = seen[qualifier] {
                XCTFail(
                    "\(state.rawValue) borrows \(other.rawValue)'s words: "
                        + qualifier
                )
            }
            seen[qualifier] = state
        }
        XCTAssertEqual(
            seen.count,
            Self.everyState.count - 1,
            "every state but the closed one has a clause of its own"
        )
    }

    func testEveryStateGetsASentenceOfItsOwn() {
        var seen: [String: CoverageState] = [:]
        for state in Self.everyState where state != .anchorClosed {
            let sentence = OverviewNarration.completeness(
                Self.standing(state),
                latest: Self.latest,
                day: Self.day
            )
            XCTAssertFalse(sentence.isEmpty, state.rawValue)
            if let other = seen[sentence] {
                XCTFail(
                    "\(state.rawValue) borrows \(other.rawValue)'s sentence"
                )
            }
            seen[sentence] = state
        }
    }

    /// No state but a closed anchor may present a held date as the person's
    /// own, whatever else its sentence says.
    func testNoStateButAClosedAnchorLicensesADate() {
        for state in Self.everyState {
            let standing = Self.standing(state)
            XCTAssertEqual(
                standing.licensesLatestDate,
                state == .anchorClosed,
                state.rawValue
            )
            let sentence = OverviewNarration.completeness(
                standing,
                latest: Self.latest,
                day: Self.day
            )
            if state != .anchorClosed {
                XCTAssertFalse(
                    sentence.contains("really is your most recent"),
                    "\(state.rawValue): \(sentence)"
                )
            }
        }
    }

    /// A held date may still be *mentioned* — it is a true statement about
    /// what arrived — but never as the last of anything.
    func testAStoppedStreamStillSaysHowFarWhatArrivedReaches() {
        let sentence = OverviewNarration.completeness(
            Self.standing(.readFailed),
            latest: Self.latest,
            day: Self.day
        )
        XCTAssertTrue(sentence.contains("11 Dec 2022"), sentence)
        XCTAssertTrue(
            sentence.contains("not necessarily all there is"),
            sentence
        )
    }

    // MARK: - The two states that used to be one

    /// Someone dismissing a permission sheet and an error nobody has ever
    /// classified are different facts with different remedies. Sharing a word
    /// made a genuine unhandled failure indistinguishable from a deliberate
    /// human choice, which is why the route stream took four steps to find.
    func testADismissedSheetAndAnUnclassifiedErrorAreDifferentStates() {
        XCTAssertNotEqual(CoverageState.authorizationDismissed, .unknown)

        let dismissed = OverviewNarration.completeness(
            Self.standing(.authorizationDismissed),
            latest: nil,
            day: Self.day
        )
        XCTAssertTrue(dismissed.contains("waiting for permission"), dismissed)
        XCTAssertTrue(
            dismissed.contains("Open Hozz on the phone"),
            "a state with a remedy has to name it: \(dismissed)"
        )

        let unrecognised = OverviewNarration.completeness(
            Self.standing(.unknown),
            latest: nil,
            day: Self.day
        )
        XCTAssertFalse(unrecognised.contains("permission"), unrecognised)
    }

    /// `unknown` covers two readings — the phone said so, or the phone said a
    /// word this Mac has never heard. The sentence has to be true of both,
    /// because the receiver genuinely cannot tell them apart.
    func testTheUnknownSentenceIsTrueOfBothWaysItCanArise() {
        let sentence = OverviewNarration.completeness(
            Self.standing(.unknown),
            latest: nil,
            day: Self.day
        )
        XCTAssertTrue(sentence.contains("newer version"), sentence)
        XCTAssertTrue(sentence.contains("could not classify"), sentence)
        XCTAssertFalse(
            sentence.contains("fault in Hozz"),
            "an unrecognised word is not evidence of a fault: \(sentence)"
        )
    }

    /// A word from a newer phone decodes to `unknown` and must still be a
    /// report, not an absence.
    func testAWordThisBuildHasNeverHeardIsStillAReport() throws {
        let object: [String: Any] = [
            "kind": "typeCoverage",
            "type": "HKWorkoutRouteTypeIdentifier",
            "state": "somethingOnlyANewerPhoneKnows",
            "observedAt": "2026-03-04T05:06:07.500Z"
        ]
        let report = try XCTUnwrap(TypeCoverageShape.report(in: object))
        XCTAssertEqual(report.state, .unknown)
        let standing = TypeCoverageStanding(report: report)
        XCTAssertEqual(standing.motion, .unknown)
        XCTAssertNotEqual(standing, .untold)
        XCTAssertFalse(standing.licensesLatestDate)
    }

    // MARK: - A hole that is still closing, and one that is not

    private static func gapped(_ state: CoverageState) -> TypeCoverageStanding {
        TypeCoverageStanding(
            report: TypeCoverageReport(
                type: "HKQuantityTypeIdentifierHeartRate",
                state: state,
                deliveredCount: 541,
                // 1 Dec 2025 to 28 Feb 2026, computed from their epochs.
                primedFrom: Date(timeIntervalSince1970: 1_764_547_200),
                primedThrough: Date(timeIntervalSince1970: 1_772_236_800),
                observedAt: observed
            )
        )
    }

    /// A gap behind a running sweep will be filled. A gap behind a sweep that
    /// has *stopped* will not, and the two want opposite sentences.
    ///
    /// They shared one until a review caught it: the primed-window clause sat
    /// ahead of the per-state words, so a type that had failed while holding a
    /// primed window was told its older history was still arriving. That is
    /// this signal's own bug, inside the code written to remove it.
    func testAGapBehindAStoppedSweepIsNotCalledStillArriving() {
        for state in Self.everyState where state != .anchorClosed {
            let standing = Self.gapped(state)
            guard standing.motion != .arriving else { continue }

            XCTAssertTrue(standing.hasGap, state.rawValue)
            XCTAssertFalse(standing.hasClosingGap, state.rawValue)

            let qualifier = standing.qualifier ?? ""
            XCTAssertFalse(
                qualifier.contains("still arriving"),
                "\(state.rawValue): \(qualifier)"
            )

            let sentence = OverviewNarration.completeness(
                standing,
                latest: Self.latest,
                day: Self.day
            )
            XCTAssertFalse(
                sentence.contains("still working back"),
                "\(state.rawValue): \(sentence)"
            )
            XCTAssertTrue(
                sentence.contains("that hole will stay where it is"),
                "a stranded hole has to be named as stranded: \(sentence)"
            )
        }
    }

    /// And a gap behind a running sweep keeps the patient wording.
    func testAGapBehindARunningSweepIsStillDescribedAsClosing() {
        let standing = Self.gapped(.draining)
        XCTAssertTrue(standing.hasClosingGap)
        XCTAssertEqual(
            standing.qualifier,
            "recent days are complete; older history is still arriving, "
                + "so the middle is not here yet"
        )
        let sentence = OverviewNarration.completeness(
            standing,
            latest: Self.latest,
            day: Self.day
        )
        XCTAssertTrue(sentence.contains("still working back"), sentence)
        XCTAssertTrue(
            sentence.contains("not a gap in your history"),
            sentence
        )
    }

    // MARK: - The row, which has one line

    /// The leading clause carries the honesty, because the caption truncates
    /// from the right. A stopped stream that read "still arriving" until the
    /// line ran out would be the same reassurance by a different route.
    func testAStoppedRowLeadsWithTheFactThatItStopped() {
        for state in Self.everyState where state != .anchorClosed {
            let standing = Self.standing(state)
            guard standing.motion == .stopped else { continue }
            let caption = Self.row(standing).rowCaption(monthName: Self.month)
            XCTAssertTrue(
                caption.hasPrefix("stopped early"),
                "\(state.rawValue): \(caption)"
            )
        }
    }

    func testAPausedRowSaysPausedRatherThanArriving() {
        let caption = Self.row(Self.standing(.deviceLockedDeferred))
            .rowCaption(monthName: Self.month)
        XCTAssertTrue(caption.hasPrefix("paused"), caption)
    }

    private static func month(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }

    private static func row(
        _ standing: TypeCoverageStanding
    ) -> IngestStore.MetricSnapshot {
        let measure = HealthMeasure(
            type: "HKWorkoutRouteTypeIdentifier",
            kind: .total,
            storedUnit: ""
        )
        let columns = [
            SeriesColumn(
                index: 0,
                start: Date(timeIntervalSince1970: 1_668_124_800),
                end: Date(timeIntervalSince1970: 1_670_803_200),
                total: 12,
                weightedSum: 12,
                weight: 1,
                minimum: 12,
                maximum: 12,
                sampleCount: 3,
                countedCount: 3,
                readingCount: 3,
                daysWithData: 30,
                dayCount: 30,
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
                    daysWithData: 30,
                    dayCount: 30,
                    firstSample: nil,
                    lastSample: nil
                )
            ),
            latestOverall: latest,
            totalRecords: 541,
            isFromEarlierWindow: false,
            standing: standing
        )
    }
}
