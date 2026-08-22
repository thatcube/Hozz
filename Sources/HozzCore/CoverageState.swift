import Foundation

public enum CoverageState: String, Codable, Hashable, Sendable {
    case unknown
    case draining
    case anchorClosed
    case authorizationIndeterminate
    case limitedAuthorizationWindow
    case deviceLockedDeferred
    case tombstoneGapSuspected
    case unsupported
    case unverifiedOnDevice
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
