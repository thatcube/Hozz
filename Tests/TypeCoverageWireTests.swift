import Foundation
import HozzCore
@testable import HozzReceive
import XCTest

/// The bytes that carry per-type coverage from the phone to the Mac.
///
/// Every expectation here is written out by hand rather than produced by the
/// code being checked. A test that encodes with `TypeCoverageShape.line` and
/// decodes with `TypeCoverageShape.report` proves only that the two agree with
/// each other, which they would continue to do while both drifted away from
/// the format on disk — and a receiver holding a year of records written to
/// the old shape has no way back.
final class TypeCoverageWireTests: XCTestCase {
    /// 2026-03-04T05:06:07.500Z, computed from its parts rather than parsed by
    /// the code under test.
    ///
    /// Half a second rather than a prettier fraction because a half is exact
    /// in binary: a fixture that cannot survive its own round trip would fail
    /// here and say nothing about the code.
    private static let observed = Date(
        timeIntervalSince1970: 1_772_600_767.5
    )
    private static let observedText = "2026-03-04T05:06:07.500Z"

    /// The instant above, arrived at independently of `Timestamps`.
    func testTheFixtureInstantIsTheDateItClaimsToBe() {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 4
        components.hour = 5
        components.minute = 6
        components.second = 7
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let whole = calendar.date(from: components)!
        XCTAssertEqual(
            whole.timeIntervalSince1970 + 0.5,
            Self.observed.timeIntervalSince1970,
            accuracy: 0.0005
        )
    }

    // MARK: - What goes on the wire

    func testAReportBecomesExactlyTheseKeysAndValues() throws {
        let report = TypeCoverageReport(
            type: "HKQuantityTypeIdentifierStepCount",
            state: .anchorClosed,
            deliveredCount: 147_330,
            observedAt: Self.observed
        )
        let line = TypeCoverageShape.line(for: report)

        XCTAssertEqual(line["kind"] as? String, "typeCoverage")
        XCTAssertEqual(line["type"] as? String, "HKQuantityTypeIdentifierStepCount")
        XCTAssertEqual(line["state"] as? String, "anchorClosed")
        XCTAssertEqual(line["complete"] as? Bool, true)
        XCTAssertEqual(line["deliveredCount"] as? Int, 147_330)
        XCTAssertEqual(line["observedAt"] as? String, Self.observedText)
        XCTAssertEqual(
            Set(line.keys),
            ["kind", "type", "state", "complete", "deliveredCount", "observedAt"],
            "a key nobody decided to add is a key the receiver was never taught"
        )
    }

    /// The report deliberately carries no frontier date. That number would be
    /// easy to compute and would look authoritative, and the sweep's ordering
    /// cannot support it — which is the whole reason this record exists.
    func testNoLineEverCarriesASweptThroughDate() {
        for state in CoverageState.allCoverageStates {
            let line = TypeCoverageShape.line(
                for: TypeCoverageReport(
                    type: "HKQuantityTypeIdentifierHeartRate",
                    state: state,
                    deliveredCount: 12,
                    primedFrom: Self.observed.addingTimeInterval(-86_400),
                    primedThrough: Self.observed,
                    observedAt: Self.observed
                )
            )
            for key in line.keys {
                XCTAssertFalse(
                    key.lowercased().contains("swept")
                        || key.lowercased().contains("frontier")
                        || key.lowercased().contains("latest"),
                    "\(key) claims a date the sweep cannot support"
                )
            }
        }
    }

    func testAPrimedWindowTravelsAsTwoTimestamps() {
        let from = Date(timeIntervalSince1970: 1_764_547_200)
        let through = Date(timeIntervalSince1970: 1_772_236_800)
        let line = TypeCoverageShape.line(
            for: TypeCoverageReport(
                type: "HKQuantityTypeIdentifierStepCount",
                state: .draining,
                deliveredCount: 10,
                primedFrom: from,
                primedThrough: through,
                observedAt: Self.observed
            )
        )
        XCTAssertEqual(line["primedFrom"] as? String, "2025-12-01T00:00:00.000Z")
        XCTAssertEqual(line["primedThrough"] as? String, "2026-02-28T00:00:00.000Z")
        XCTAssertEqual(line["complete"] as? Bool, false)
    }

    /// A window with no window in it must not appear at all: something asking
    /// "is there a primed window" would be told yes about an empty stretch.
    func testAReportWithoutAWindowOmitsBothEnds() {
        let line = TypeCoverageShape.line(
            for: TypeCoverageReport(
                type: "HKQuantityTypeIdentifierStepCount",
                state: .draining,
                observedAt: Self.observed
            )
        )
        XCTAssertNil(line["primedFrom"])
        XCTAssertNil(line["primedThrough"])
    }

    // MARK: - What comes off the wire

    /// Hand-written bytes, as a phone would actually send them.
    func testALineWrittenByHandIsReadCorrectly() throws {
        let json = """
            {"complete":true,"deliveredCount":41,"kind":"typeCoverage",\
            "observedAt":"2026-03-04T05:06:07.500Z","state":"anchorClosed",\
            "type":"HKCategoryTypeIdentifierSleepAnalysis"}
            """
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8))
                as? [String: Any]
        )
        let report = try XCTUnwrap(TypeCoverageShape.report(in: object))

        XCTAssertEqual(report.type, "HKCategoryTypeIdentifierSleepAnalysis")
        XCTAssertEqual(report.state, .anchorClosed)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.deliveredCount, 41)
        XCTAssertEqual(
            report.observedAt.timeIntervalSince1970,
            Self.observed.timeIntervalSince1970,
            accuracy: 0.0005
        )
    }

    /// A word this build has never heard of has to arrive as "a report I
    /// cannot interpret", not as no report at all. The two license completely
    /// different sentences downstream.
    func testAStateFromANewerPhoneStillCountsAsAReport() throws {
        let object: [String: Any] = [
            "kind": "typeCoverage",
            "type": "HKQuantityTypeIdentifierStepCount",
            "state": "somethingInvented",
            "observedAt": Self.observedText
        ]
        let report = try XCTUnwrap(TypeCoverageShape.report(in: object))
        XCTAssertEqual(report.state, .unknown)
        XCTAssertFalse(
            report.isComplete,
            "a word nobody understands cannot license a date"
        )
        XCTAssertEqual(
            TypeCoverageStanding(report: report),
            .incomplete(report),
            "a report that cannot be read is still a report"
        )
    }

    /// `complete` is written for a reader's benefit, but it is the *state*
    /// that decides. A phone that wrote them inconsistently must not be able
    /// to talk this receiver into presenting a date it has no licence for.
    func testTheStateDecidesCompletenessAndNotTheFlag() throws {
        let object: [String: Any] = [
            "kind": "typeCoverage",
            "type": "HKQuantityTypeIdentifierStepCount",
            "state": "draining",
            "complete": true,
            "observedAt": Self.observedText
        ]
        let report = try XCTUnwrap(TypeCoverageShape.report(in: object))
        XCTAssertFalse(report.isComplete)
    }

    func testALineOfAnotherKindIsNotAReport() {
        XCTAssertNil(
            TypeCoverageShape.report(
                in: [
                    "kind": "quantity",
                    "type": "HKQuantityTypeIdentifierStepCount",
                    "observedAt": Self.observedText
                ]
            )
        )
    }

    func testAReportWithNoMomentIsRefused() {
        XCTAssertNil(
            TypeCoverageShape.report(
                in: [
                    "kind": "typeCoverage",
                    "type": "HKQuantityTypeIdentifierStepCount",
                    "state": "anchorClosed"
                ]
            ),
            "without a moment there is no way to tell an echo from news"
        )
    }

    // MARK: - Only one state may license a date

    /// Written out one by one rather than derived, so adding a state to the
    /// enumeration forces a decision here about whether it means "everything
    /// is here" — which is the one question this whole change turns on.
    func testExactlyOneStateMeansEverythingIsHere() {
        let licensed: Set<CoverageState> = [.anchorClosed]
        XCTAssertEqual(
            Set(CoverageState.allCoverageStates.map(\.rawValue)),
            [
                "unknown", "draining", "anchorClosed",
                "authorizationIndeterminate", "limitedAuthorizationWindow",
                "deviceLockedDeferred", "tombstoneGapSuspected", "unsupported",
                "unverifiedOnDevice", "authorizationDismissed", "readFailed"
            ],
            "a state was added without deciding whether it licenses a date"
        )
        for state in CoverageState.allCoverageStates {
            let report = TypeCoverageReport(
                type: "HKQuantityTypeIdentifierStepCount",
                state: state,
                observedAt: Self.observed
            )
            XCTAssertEqual(
                report.isComplete,
                licensed.contains(state),
                "\(state.rawValue)"
            )
        }
    }

    /// HealthKit answers identically for a type you have no records of and one
    /// Hozz was never granted. Letting that collapse into "complete" would
    /// present an empty type as a finished one.
    func testAnIndeterminateAuthorizationIsNeverComplete() {
        let report = TypeCoverageReport(
            type: "HKQuantityTypeIdentifierStepCount",
            state: .authorizationIndeterminate,
            deliveredCount: 0,
            observedAt: Self.observed
        )
        XCTAssertFalse(report.isComplete)
        let standing = TypeCoverageStanding(report: report)
        XCTAssertFalse(standing.licensesLatestDate)
        XCTAssertTrue(standing.isAuthorizationIndeterminate)
    }
}

extension CoverageState {
    /// Every case, from the enum. Was a hand-kept copy until a review pointed
    /// out that a list maintained by hand cannot fail when a case is added.
    static var allCoverageStates: [CoverageState] { allCases }
}
