import Foundation

public protocol HealthDataSource: Sendable {
    func changes(
        for type: HealthTypeKey,
        after anchor: AnchorToken?,
        limit: Int
    ) async throws -> HealthChangeBatch
}

public protocol DurableHealthChangeSink: Sendable {
    func committedAnchor(for type: HealthTypeKey) async throws -> AnchorToken?

    func commit(
        _ batch: HealthChangeBatch,
        for type: HealthTypeKey,
        baseAnchor: AnchorToken?
    ) async throws

    func markAnchorClosed(
        type: HealthTypeKey,
        anchor: AnchorToken,
        observedChangeCount: Int,
        hadPriorAnchor: Bool,
        at date: Date
    ) async throws
}
