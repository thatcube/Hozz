public struct HealthChangeBatch: Equatable, Sendable {
    public let changes: [HealthChange]
    public let proposedAnchor: AnchorToken

    public init(changes: [HealthChange], proposedAnchor: AnchorToken) {
        self.changes = changes
        self.proposedAnchor = proposedAnchor
    }

    public func containsOnly(type: HealthTypeKey) -> Bool {
        changes.allSatisfy { $0.type == type }
    }
}
