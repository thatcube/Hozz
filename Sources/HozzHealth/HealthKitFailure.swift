import Foundation
import HealthKit
import HozzCore

/// A classified HealthKit failure.
///
/// HealthKit reports very different situations through the same error domain.
/// Flattening them all into "failed" makes a locked device — by far the most
/// common background failure — indistinguishable from a permanent one, so Hozz
/// keeps the distinction and reports it.
public struct HealthKitFailure: Error, Equatable, Sendable {
    /// `CaseIterable` for the same reason as ``CoverageState``: the test that
    /// checks every kind lands on the state it should has to be able to fail
    /// when a kind is added, and a hand-written list cannot.
    public enum Kind: Equatable, Sendable, CaseIterable {
        /// The Health database is locked. Retrying after unlock usually works.
        case deviceLocked
        /// Read access was not granted, or there is genuinely nothing to read.
        /// HealthKit deliberately does not let an app tell these apart.
        case authorizationIndeterminate
        /// Health data is not available or is restricted on this device.
        case healthDataUnavailable
        /// The user dismissed the authorization sheet.
        case userCancelled
        /// HealthKit stopped advancing a cursor, so continuing would loop.
        case nonAdvancingAnchor
        /// A type exceeded its pagination budget without reaching an empty page.
        case exceededQueryBudget
        /// A read failed inside Hozz rather than inside HealthKit: a missing
        /// continuation cursor, a type the reader cannot handle, an encoding
        /// step that threw.
        ///
        /// Separated from ``unclassified`` because the two need opposite
        /// responses. An unrecognised HealthKit error may be transient, or may
        /// be something about the person's own device; one of these is a bug
        /// in Hozz, and it stays invisible for exactly as long as it is
        /// reported as a puzzle about Health.
        case internalInconsistency
        /// A HealthKit error Hozz has not classified.
        case unclassified

        public var coverageState: CoverageState {
            switch self {
            case .deviceLocked:
                .deviceLockedDeferred
            case .authorizationIndeterminate:
                .authorizationIndeterminate
            case .healthDataUnavailable:
                .unsupported
            case .userCancelled:
                .authorizationDismissed
            case .nonAdvancingAnchor, .exceededQueryBudget:
                .tombstoneGapSuspected
            case .internalInconsistency:
                .readFailed
            case .unclassified:
                .unknown
            }
        }

        /// Whether resuming later, without user action, could succeed.
        public var isTransient: Bool {
            switch self {
            case .deviceLocked:
                true
            case .authorizationIndeterminate,
                 .healthDataUnavailable,
                 .userCancelled,
                 .nonAdvancingAnchor,
                 .exceededQueryBudget,
                 .internalInconsistency,
                 .unclassified:
                false
            }
        }
    }

    public let kind: Kind
    public let typeIdentifier: String?
    public let underlyingDescription: String

    public init(
        kind: Kind,
        typeIdentifier: String?,
        underlyingDescription: String
    ) {
        self.kind = kind
        self.typeIdentifier = typeIdentifier
        self.underlyingDescription = underlyingDescription
    }

    public var coverageState: CoverageState {
        kind.coverageState
    }

    public var isTransient: Bool {
        kind.isTransient
    }

    /// Classifies an arbitrary error raised while reading Health data.
    public static func classify(
        _ error: any Error,
        typeIdentifier: String? = nil
    ) -> HealthKitFailure {
        if let failure = error as? HealthKitFailure {
            return failure
        }

        let description = (error as any CustomStringConvertible).description
        let nsError = error as NSError

        // Hozz's own errors are recognised before the domain check, because
        // none of them is in `HKError.errorDomain` and every one of them would
        // otherwise be filed as an unclassified HealthKit error. That is how a
        // missing continuation cursor — a fault in this app — came to be
        // reported as a puzzle about Health, and stayed one.
        if error is HealthKitSourceError || error is HealthSampleEncodingError {
            return HealthKitFailure(
                kind: .internalInconsistency,
                typeIdentifier: typeIdentifier,
                underlyingDescription: description
            )
        }

        guard nsError.domain == HKError.errorDomain else {
            return HealthKitFailure(
                kind: .unclassified,
                typeIdentifier: typeIdentifier,
                underlyingDescription: description
            )
        }

        let kind: Kind = switch HKError.Code(rawValue: nsError.code) {
        case .errorDatabaseInaccessible:
            .deviceLocked
        case .errorAuthorizationDenied,
             .errorAuthorizationNotDetermined,
             .errorRequiredAuthorizationDenied:
            .authorizationIndeterminate
        case .errorHealthDataUnavailable, .errorHealthDataRestricted:
            .healthDataUnavailable
        case .errorUserCanceled:
            .userCancelled
        default:
            .unclassified
        }

        return HealthKitFailure(
            kind: kind,
            typeIdentifier: typeIdentifier,
            underlyingDescription: description
        )
    }
}

extension HealthKitFailure: LocalizedError {
    public var errorDescription: String? {
        let subject = typeIdentifier.map { " for \($0)" } ?? ""
        switch kind {
        case .deviceLocked:
            return "Health data\(subject) is locked. Unlock this iPhone and Hozz will continue."
        case .authorizationIndeterminate:
            return "Health returned no data\(subject). Apple does not let Hozz tell a denied type from an empty one."
        case .healthDataUnavailable:
            return "Health data is unavailable or restricted on this device."
        case .userCancelled:
            return "Health access was not completed."
        case .nonAdvancingAnchor:
            return "Health stopped advancing while reading\(subject)."
        case .exceededQueryBudget:
            return "Reading\(subject) exceeded its safety limit."
        case .internalInconsistency:
            // Named as Hozz's own fault rather than Health's, because it is.
            // Reported as a puzzle about Health it would sit unfixed for as
            // long as it took someone to read the string.
            return "Hozz's own reading\(subject) failed: \(underlyingDescription)"
        case .unclassified:
            return "Hozz could not read Health data\(subject): \(underlyingDescription)"
        }
    }
}
