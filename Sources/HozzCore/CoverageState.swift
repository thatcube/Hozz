import Foundation

/// How completely one type has been read, and why it stopped if it did.
///
/// Every case is a different fact, and they are kept apart deliberately. A
/// state that covers two situations is a state that cannot be acted on: the
/// whole coverage signal exists because "the sweep has not reached this" and
/// "there is nothing here" were once indistinguishable downstream, and the same
/// collapse one level down is what let a workout-route stream fail on Brandon's
/// phone for weeks while every surface called it progress.
///
/// `CaseIterable` so the tests that check every state has its own words can
/// derive the list from the enum rather than keeping a copy beside it. Three
/// copies had already appeared, and a list maintained by hand cannot fail when
/// a case is added — which is precisely what those tests exist to do.
public enum CoverageState: String, Codable, Hashable, Sendable, CaseIterable {
    /// A read failed with an error from HealthKit that Hozz does not
    /// recognise, and also the word a receiver falls back to when a newer
    /// phone sends a state it has never heard of.
    ///
    /// Both readings are "something happened here that this build cannot
    /// interpret", which is why they can honestly share a word. Neither is
    /// ignorance — a report saying `unknown` is still a report, and licenses
    /// nothing.
    case unknown
    /// The anchored sweep is running and has more to hand over.
    case draining
    /// The sweep ran out of records. The only state that means everything is
    /// here.
    case anchorClosed
    /// The stream closed without ever returning an object. HealthKit answers
    /// identically whether a type has no records or was never granted, so this
    /// deliberately claims neither.
    case authorizationIndeterminate
    case limitedAuthorizationWindow
    case deviceLockedDeferred
    case tombstoneGapSuspected
    /// Health data is unavailable or restricted on this device.
    case unsupported
    case unverifiedOnDevice
    /// Someone dismissed the authorization sheet.
    ///
    /// Split out from ``unknown`` because a human choice with an obvious
    /// remedy has no business sharing a word with a fault nobody has
    /// classified. Sat together, a genuine unhandled failure was
    /// indistinguishable from a person tapping Cancel.
    case authorizationDismissed
    /// A read failed inside Hozz rather than inside HealthKit: a missing
    /// continuation cursor, a type the reader cannot handle, an encoding step
    /// that threw.
    ///
    /// Worth its own word because the remedy is completely different. An error
    /// from HealthKit may be transient or may be the person's own settings; one
    /// of these is a bug in Hozz, and reporting it as though the phone were
    /// merely puzzled by Health hides it indefinitely.
    case readFailed
}

public struct StreamCoverage: Codable, Hashable, Sendable {
    public let type: HealthTypeKey
    public let state: CoverageState
    public let committedAnchor: AnchorToken?
    public let anchorClosedAt: Date?
    public let authorizationEpoch: UInt64

    public init(
        type: HealthTypeKey,
        state: CoverageState,
        committedAnchor: AnchorToken?,
        anchorClosedAt: Date?,
        authorizationEpoch: UInt64
    ) {
        self.type = type
        self.state = state
        self.committedAnchor = committedAnchor
        self.anchorClosedAt = anchorClosedAt
        self.authorizationEpoch = authorizationEpoch
    }
}
