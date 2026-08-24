import Foundation
import HozzCore
@testable import HozzDeliver
import HozzStore
import XCTest

/// What the phone decides to tell a receiver, and when it decides to tell it.
final class CoverageReporterTests: XCTestCase {
    private static let observed = Date(timeIntervalSince1970: 1_772_600_767)

    private func record(
        _ type: String,
        coverage: CoverageState,
        recordCount: Int = 0,
        observedCount: Int = 0
    ) -> StreamRecord {
        StreamRecord(
            type: HealthTypeKey(type),
            coverage: coverage,
            committedAnchor: AnchorToken(data: Data("a".utf8)),
            recordCount: recordCount,
            observedCount: observedCount,
            anchorClosedAt: coverage == .anchorClosed ? Self.observed : nil,
            failureReason: nil,
            updatedAt: Self.observed
        )
    }

    // MARK: - What is reported

    func testEveryStoredTypeIsReportedInOneStableOrder() {
        let reports = CoverageReporter.reports(
            from: [
                record("HKQuantityTypeIdentifierStepCount", coverage: .draining),
                record("HKCategoryTypeIdentifierSleepAnalysis", coverage: .anchorClosed),
                record("HKQuantityTypeIdentifierHeartRate", coverage: .draining)
            ],
            observedAt: Self.observed
        )
        XCTAssertEqual(
            reports.map(\.type),
            [
                "HKCategoryTypeIdentifierSleepAnalysis",
                "HKQuantityTypeIdentifierHeartRate",
                "HKQuantityTypeIdentifierStepCount"
            ]
        )
    }

    /// The pass in progress wins, because its coverage is what is about to be
    /// committed. Reporting the stored value would put every completion one
    /// delivery late, and a type that finishes and is never touched again
    /// would never be reported finished at all.
    func testThisPassOverridesWhatTheStoreStillSays() throws {
        let reports = CoverageReporter.reports(
            from: [
                record(
                    "HKQuantityTypeIdentifierStepCount",
                    coverage: .draining,
                    recordCount: 900
                )
            ],
            pass: [
                HealthTypeKey("HKQuantityTypeIdentifierStepCount"):
                    CoverageReporter.PassCoverage(
                        state: .anchorClosed,
                        deliveredCount: 1_000
                    )
            ],
            observedAt: Self.observed
        )
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.state, .anchorClosed)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.deliveredCount, 1_000)
    }

    func testATypeSeenOnlyInThisPassIsStillReported() throws {
        let reports = CoverageReporter.reports(
            from: [],
            pass: [
                HealthTypeKey("HKQuantityTypeIdentifierHeartRate"):
                    CoverageReporter.PassCoverage(state: .draining, deliveredCount: 5)
            ],
            observedAt: Self.observed
        )
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(try XCTUnwrap(reports.first).deliveredCount, 5)
    }

    // MARK: - The primed window

    func testAPrimedWindowIsAttachedToItsOwnTypeAndNoOther() throws {
        let from = Date(timeIntervalSince1970: 1_764_547_200)
        let through = Date(timeIntervalSince1970: 1_772_323_200)
        let reports = CoverageReporter.reports(
            from: [
                record("HKQuantityTypeIdentifierStepCount", coverage: .draining),
                record("HKQuantityTypeIdentifierHeartRate", coverage: .draining)
            ],
            primedWindows: [
                HealthTypeKey("HKQuantityTypeIdentifierStepCount"):
                    try XCTUnwrap(
                        CoverageReporter.PrimedWindow(from: from, through: through)
                    )
            ],
            observedAt: Self.observed
        )
        let steps = try XCTUnwrap(
            reports.first { $0.type == "HKQuantityTypeIdentifierStepCount" }
        )
        let heart = try XCTUnwrap(
            reports.first { $0.type == "HKQuantityTypeIdentifierHeartRate" }
        )
        XCTAssertTrue(steps.hasPrimedWindow)
        XCTAssertEqual(steps.primedFrom, from)
        XCTAssertEqual(steps.primedThrough, through)
        XCTAssertFalse(heart.hasPrimedWindow)
        XCTAssertNil(heart.primedFrom)
    }

    /// A prime that has delivered nothing has no window. Reported as a
    /// zero-length one, anything asking "is there a primed window" would be
    /// told yes about a stretch containing nothing at all.
    func testAWindowThatContainsNothingIsNotAWindow() {
        let instant = Date(timeIntervalSince1970: 1_772_323_200)
        XCTAssertNil(CoverageReporter.PrimedWindow(from: instant, through: instant))
        XCTAssertNil(
            CoverageReporter.PrimedWindow(
                from: instant,
                through: instant.addingTimeInterval(-1)
            ),
            "a window that ends before it starts is not a window either"
        )
        XCTAssertNotNil(
            CoverageReporter.PrimedWindow(
                from: instant,
                through: instant.addingTimeInterval(1)
            )
        )
    }

    // MARK: - When a report is worth sending

    /// The digest exists to answer one question: has anything a receiver would
    /// care about changed? A digest that moved every pass would deliver a
    /// batch every hour to a computer that may be switched off, fail, back
    /// off, and eventually park a destination with nothing wrong with it.
    func testTheDigestIgnoresTheClock() {
        // Written by hand rather than through `reports`, because that function
        // now keeps `observedAt` still for coverage that has not changed — so
        // a fixture built through it could not differ in the one way this test
        // exists to ignore.
        func report(at observed: Date) -> TypeCoverageReport {
            TypeCoverageReport(
                type: "HKQuantityTypeIdentifierStepCount",
                state: .draining,
                deliveredCount: 12,
                observedAt: observed
            )
        }
        let first = [report(at: Self.observed)]
        let later = [report(at: Self.observed.addingTimeInterval(9 * 3_600))]

        XCTAssertNotEqual(
            first.first?.observedAt,
            later.first?.observedAt,
            "the fixture has to differ in the way being ignored"
        )
        XCTAssertEqual(
            CoverageReporter.digest(of: first),
            CoverageReporter.digest(of: later)
        )
    }

    func testEveryFactAReceiverActsOnMovesTheDigest() throws {
        let base = record(
            "HKQuantityTypeIdentifierStepCount",
            coverage: .draining,
            recordCount: 10
        )
        let reference = CoverageReporter.digest(
            of: CoverageReporter.reports(from: [base], observedAt: Self.observed)
        )
        let window = try XCTUnwrap(
            CoverageReporter.PrimedWindow(
                from: Date(timeIntervalSince1970: 1_764_547_200),
                through: Date(timeIntervalSince1970: 1_772_323_200)
            )
        )

        let variants: [String: [TypeCoverageReport]] = [
            "the sweep finished": CoverageReporter.reports(
                from: [
                    record(
                        "HKQuantityTypeIdentifierStepCount",
                        coverage: .anchorClosed,
                        recordCount: 10
                    )
                ],
                observedAt: Self.observed
            ),
            "more was delivered": CoverageReporter.reports(
                from: [
                    record(
                        "HKQuantityTypeIdentifierStepCount",
                        coverage: .draining,
                        recordCount: 11
                    )
                ],
                observedAt: Self.observed
            ),
            "a window was primed": CoverageReporter.reports(
                from: [base],
                primedWindows: [
                    HealthTypeKey("HKQuantityTypeIdentifierStepCount"): window
                ],
                observedAt: Self.observed
            ),
            "another type appeared": CoverageReporter.reports(
                from: [
                    base,
                    record("HKQuantityTypeIdentifierHeartRate", coverage: .draining)
                ],
                observedAt: Self.observed
            )
        ]

        for (change, reports) in variants {
            XCTAssertNotEqual(
                CoverageReporter.digest(of: reports),
                reference,
                "\(change) left the digest unmoved, so it would never be sent"
            )
        }
    }

    /// Two runs over the same facts have to agree, or "has anything changed"
    /// answers yes forever.
    func testTheDigestDoesNotDependOnTheOrderTypesArriveIn() {
        let records = [
            record("HKQuantityTypeIdentifierStepCount", coverage: .draining),
            record("HKQuantityTypeIdentifierHeartRate", coverage: .anchorClosed),
            record("HKCategoryTypeIdentifierSleepAnalysis", coverage: .draining)
        ]
        XCTAssertEqual(
            CoverageReporter.digest(
                of: CoverageReporter.reports(from: records, observedAt: Self.observed)
            ),
            CoverageReporter.digest(
                of: CoverageReporter.reports(
                    from: records.reversed(),
                    observedAt: Self.observed
                )
            )
        )
    }

    // MARK: - The bytes have to stop moving when the facts do

    /// A batch is identified by a hash of its bytes, and that identity is the
    /// whole of a receiver's duplicate detection. When an acknowledgement is
    /// lost the phone keeps its cursors, re-reads the same records and sends
    /// the same batch — so a timestamp taken from the clock would make an
    /// identical retry arrive under a new identity.
    func testUnchangedCoverageKeepsTheMomentItWasFirstObserved() {
        let earlier = Self.observed
        let now = Self.observed.addingTimeInterval(3_600)
        let observation = CoverageReporter.observation(
            matching: "abc",
            storedDigest: "abc",
            storedMoment: earlier,
            now: now
        )
        XCTAssertEqual(observation.moment, earlier)
        XCTAssertFalse(
            observation.isNew,
            "nothing changed, so there is nothing new to write down"
        )
    }

    /// Stable is not frozen. A fact that changes has to be dated to the moment
    /// it changed, or the receiver's "is this news or an echo" guard has
    /// nothing to compare.
    func testChangedCoverageIsDatedToNowAndWrittenDown() {
        let now = Self.observed.addingTimeInterval(3_600)
        let observation = CoverageReporter.observation(
            matching: "def",
            storedDigest: "abc",
            storedMoment: Self.observed,
            now: now
        )
        XCTAssertEqual(observation.moment, now)
        XCTAssertTrue(observation.isNew)
    }

    /// A moment in the future is a clock that went backwards. Keeping it would
    /// freeze the timestamp until the clock caught up, and a receiver
    /// comparing moments would refuse everything sent in between.
    ///
    /// Restored after a review noticed this guard's only test had been deleted
    /// along with the hunk it sat in — live behaviour with a documented reason
    /// and nothing exercising it.
    func testAMomentFromTheFutureIsNotKept() {
        let now = Self.observed
        let observation = CoverageReporter.observation(
            matching: "abc",
            storedDigest: "abc",
            storedMoment: now.addingTimeInterval(86_400),
            now: now
        )
        XCTAssertEqual(observation.moment, now)
        XCTAssertTrue(observation.isNew)
    }

    /// The bytes, not just the digest: the same facts observed at the same
    /// moment render identically however the records arrive.
    func testTheSameFactsAtTheSameMomentProduceTheSameBytes() {
        let records = [
            record(
                "HKQuantityTypeIdentifierStepCount",
                coverage: .anchorClosed,
                recordCount: 4
            ),
            record("HKQuantityTypeIdentifierHeartRate", coverage: .draining)
        ]
        XCTAssertEqual(
            CoverageReporter.lines(
                for: CoverageReporter.reports(from: records, observedAt: Self.observed)
            ),
            CoverageReporter.lines(
                for: CoverageReporter.reports(
                    from: records.reversed(),
                    observedAt: Self.observed
                )
            )
        )
    }

    /// The case that matters most, because a first sweep is the longest and
    /// most interruption-prone delivery there is: a type nothing has been
    /// recorded for yet.
    func testAFirstObservationIsDatedToNow() {
        let observation = CoverageReporter.observation(
            matching: "abc",
            storedDigest: nil,
            storedMoment: nil,
            now: Self.observed
        )
        XCTAssertEqual(observation.moment, Self.observed)
        XCTAssertTrue(observation.isNew)
    }

    // The sweep that pins this, and the test that asserts the wire format is
    // not safe to round trip a moment through, both live in
    // `CoverageDeliveryTests`. They arrived from the session that shipped the
    // first fix, they drive the real `DeliveryEngine` rather than the pure
    // function, and they assert the property rather than either
    // implementation — so they hold against the exact storage below without
    // modification. A second pair here asserting the same two things would
    // read as an accident rather than a decision.

    /// A destination written by the build already on the maintainer's phone
    /// holds an ISO-8601 timestamp in this option, not a number.
    ///
    /// That build is shipped, so this is a live path rather than a
    /// hypothetical. It has to degrade to "no moment recorded" — which costs
    /// one batch stamped afresh and then settles — rather than to a wrong
    /// instant or a crash.
    func testAMomentLeftByTheEarlierBuildIsIgnoredRatherThanMisread() {
        var destination = Destination(
            name: "Mac",
            kind: .folder,
            cadence: .whenDataArrives,
            folderBookmark: Data("a".utf8)
        )
        destination.options[Destination.coverageObservedDigestKey] = "abc"
        destination.options[Destination.coverageObservedAtKey] =
            "2026-08-24T21:54:15.118Z"

        XCTAssertNil(
            destination.observedCoverageMoment,
            "an ISO-8601 string is not a number and must not be guessed at"
        )

        let observation = CoverageReporter.observation(
            matching: "abc",
            storedDigest: destination.observedCoverageDigest,
            storedMoment: destination.observedCoverageMoment,
            now: Self.observed
        )
        XCTAssertEqual(observation.moment, Self.observed)
        XCTAssertTrue(
            observation.isNew,
            "so the next pass writes it in the form that survives"
        )
    }

    /// The value really is lossless, which is the whole reason for storing a
    /// number rather than a timestamp.
    func testAMomentWrittenAsANumberComesBackExactly() {
        for step in 0..<5_000 {
            let moment = Date(
                timeIntervalSince1970: 1_772_600_767 + Double(step) / 5_000
            )
            let text = Destination.observedCoverageText(moment)
            let recovered = Double(text).map(Date.init(timeIntervalSince1970:))
            XCTAssertEqual(
                recovered?.timeIntervalSince1970,
                moment.timeIntervalSince1970,
                "step \(step) did not survive"
            )
        }
    }

    // MARK: - Which formats carry it at all

    /// A CSV has fixed columns and a metrics envelope reduces a record to one
    /// number, so a report sent in either arrives as a row of blanks or as a
    /// metric named after a type. Told nothing is better than told something
    /// false.
    func testOnlyTheLosslessFormatsCarryAReport() {
        let carrying = DeliveryFormat.allCases.filter(\.carriesCoverage)
        XCTAssertEqual(Set(carrying), [.ndjson, .json])
        XCTAssertEqual(
            Set(DeliveryFormat.allCases),
            [.ndjson, .json, .csv, .metrics, .influx],
            "a format was added without deciding whether it carries coverage"
        )
    }

    func testALineIsWrittenForEveryReport() throws {
        let reports = CoverageReporter.reports(
            from: [
                record("HKQuantityTypeIdentifierStepCount", coverage: .anchorClosed),
                record("HKQuantityTypeIdentifierHeartRate", coverage: .draining)
            ],
            observedAt: Self.observed
        )
        let lines = CoverageReporter.lines(for: reports)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: line) as? [String: Any]
            )
            XCTAssertEqual(object["kind"] as? String, "typeCoverage")
            XCTAssertFalse(
                String(decoding: line, as: UTF8.self).contains("\n"),
                "a line with a newline in it is two lines"
            )
        }
    }
}
