import Foundation
import HealthKit
import HozzCore
@testable import HozzHealth
import XCTest

/// Which failure is which.
///
/// The projection from `HealthKitFailure.Kind` onto `CoverageState` used to
/// send two very different situations to the same word. "Someone dismissed the
/// permission sheet" and "an error nobody has ever classified" both became
/// `unknown`, so a genuine unhandled fault was indistinguishable from a
/// deliberate human choice — and a workout-route stream on Brandon's phone sat
/// in that state for weeks while every surface called it progress.
///
/// The expectations here are written out per case rather than derived from the
/// mapping, because a test that reads the mapping to check the mapping proves
/// only that it agrees with itself.
final class FailureClassificationTests: XCTestCase {
    /// Hozz's own errors are not in `HKError.errorDomain`, so every one of
    /// them was being filed as an unrecognised *HealthKit* error — reported as
    /// a puzzle about Health when it is a fault in this app.
    func testHozzsOwnErrorsAreRecognisedAsHozzsOwn() {
        let ours: [any Error] = [
            HealthKitSourceError.missingAnchor("HKWorkoutRouteTypeIdentifier"),
            HealthKitSourceError.unsupportedType("HKWorkoutRouteTypeIdentifier"),
            HealthKitSourceError.invalidLimit,
            HealthSampleEncodingError.invalidJSONObject,
            HealthSampleEncodingError.missingCanonicalUnit("x")
        ]
        for error in ours {
            let failure = HealthKitFailure.classify(
                error,
                typeIdentifier: "HKWorkoutRouteTypeIdentifier"
            )
            XCTAssertEqual(
                failure.kind,
                .internalInconsistency,
                "\(error)"
            )
            XCTAssertEqual(failure.coverageState, .readFailed, "\(error)")
        }
    }

    /// The specific candidate for the route stall: Health handing back samples
    /// with no continuation cursor. It has to name itself as ours.
    func testAMissingContinuationCursorIsReportedAsOurFault() {
        let failure = HealthKitFailure.classify(
            HealthKitSourceError.missingAnchor("HKWorkoutRouteTypeIdentifier"),
            typeIdentifier: "HKWorkoutRouteTypeIdentifier"
        )
        XCTAssertEqual(failure.coverageState, .readFailed)
        XCTAssertNotEqual(
            failure.coverageState,
            .unknown,
            "filed as unknown, this reads as a puzzle about Health"
        )
        let described = failure.errorDescription ?? ""
        XCTAssertTrue(
            described.contains("Hozz's own reading"),
            described
        )
    }

    /// An error from somebody else's framework stays unclassified, because it
    /// genuinely is.
    func testAnErrorFromAnotherDomainStaysUnclassified() {
        let failure = HealthKitFailure.classify(
            NSError(domain: "com.example.something", code: 42),
            typeIdentifier: "HKQuantityTypeIdentifierStepCount"
        )
        XCTAssertEqual(failure.kind, .unclassified)
        XCTAssertEqual(failure.coverageState, .unknown)
    }

    /// A person tapping Cancel is a choice with a remedy, and no longer shares
    /// a word with a fault.
    func testADismissedSheetHasItsOwnState() {
        let failure = HealthKitFailure.classify(
            NSError(
                domain: HKError.errorDomain,
                code: HKError.Code.errorUserCanceled.rawValue
            ),
            typeIdentifier: "HKQuantityTypeIdentifierStepCount"
        )
        XCTAssertEqual(failure.kind, .userCancelled)
        XCTAssertEqual(failure.coverageState, .authorizationDismissed)
        XCTAssertNotEqual(failure.coverageState, .unknown)
    }

    /// The whole projection, stated independently of the code that performs
    /// it. Every kind, every expected state, written by hand.
    func testEveryKindLandsOnTheStateItShould() {
        let expected: [(HealthKitFailure.Kind, CoverageState)] = [
            (.deviceLocked, .deviceLockedDeferred),
            (.authorizationIndeterminate, .authorizationIndeterminate),
            (.healthDataUnavailable, .unsupported),
            (.userCancelled, .authorizationDismissed),
            (.nonAdvancingAnchor, .tombstoneGapSuspected),
            (.exceededQueryBudget, .tombstoneGapSuspected),
            (.internalInconsistency, .readFailed),
            (.unclassified, .unknown)
        ]
        XCTAssertEqual(
            expected.count,
            HealthKitFailure.Kind.allCases.count,
            "a failure kind was added without deciding what it means"
        )
        for (kind, state) in expected {
            XCTAssertEqual(kind.coverageState, state, "\(kind)")
        }

        // No two kinds that mean different things may share a state. The one
        // permitted pair is the two ways a sweep can be cut short mid-stream,
        // which really are the same fact about the data.
        let states = expected.map(\.1)
        XCTAssertEqual(
            Set(states).count,
            states.count - 1,
            "a kind is sharing a state with one it does not match"
        )
    }

    /// Only a locked device is worth retrying without anyone doing anything.
    func testOnlyALockedDeviceIsTransient() {
        // Derived from the enum, so a kind added later is judged here rather
        // than quietly skipped by a list nobody updated.
        for kind in HealthKitFailure.Kind.allCases {
            XCTAssertEqual(
                kind.isTransient,
                kind == .deviceLocked,
                "\(kind)"
            )
        }
    }

    /// A `HealthKitFailure` handed back to `classify` must survive unchanged,
    /// or a failure would be re-classified on its way up the stack and lose
    /// whatever the layer below it had established.
    func testAnAlreadyClassifiedFailurePassesThrough() {
        let original = HealthKitFailure(
            kind: .internalInconsistency,
            typeIdentifier: "HKWorkoutRouteTypeIdentifier",
            underlyingDescription: "a missing continuation cursor"
        )
        XCTAssertEqual(HealthKitFailure.classify(original), original)
    }
}
