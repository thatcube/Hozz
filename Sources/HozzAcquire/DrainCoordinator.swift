import Foundation
import HozzCore

public enum DrainError: Error, Equatable, Sendable {
    case invalidBatchLimit
    case invalidQueryBudget
    case unexpectedType(expected: HealthTypeKey, actual: HealthTypeKey)
    case nonAdvancingAnchor
}

public enum DrainCompletion: Equatable, Sendable {
    case anchorClosed
    case paused
    case cancelled
}

public struct DrainReport: Equatable, Sendable {
    public let completion: DrainCompletion
    public let queryCount: Int
    public let changeCount: Int
    public let finalAnchor: AnchorToken?

    public init(
        completion: DrainCompletion,
        queryCount: Int,
        changeCount: Int,
        finalAnchor: AnchorToken?
    ) {
        self.completion = completion
        self.queryCount = queryCount
        self.changeCount = changeCount
        self.finalAnchor = finalAnchor
    }
}

public struct DrainCoordinator: Sendable {
    private let source: any HealthDataSource
    private let sink: any DurableHealthChangeSink

    public init(
        source: any HealthDataSource,
        sink: any DurableHealthChangeSink
    ) {
        self.source = source
        self.sink = sink
    }

    /// - Parameter onBatch: Invoked after each page is durably staged, with the
    ///   running change count for this type. A single type can hold millions of
    ///   records, so without this the caller cannot show progress until the
    ///   whole type finishes.
    public func drain(
        type: HealthTypeKey,
        batchLimit: Int,
        maximumQueries: Int? = nil,
        onBatch: (@Sendable (Int) async -> Void)? = nil
    ) async throws -> DrainReport {
        guard batchLimit > 0 else {
            throw DrainError.invalidBatchLimit
        }
        if let maximumQueries, maximumQueries <= 0 {
            throw DrainError.invalidQueryBudget
        }

        var anchor = try await sink.committedAnchor(for: type)
        let hadPriorAnchor = anchor != nil
        var queryCount = 0
        var changeCount = 0

        while true {
            if Task.isCancelled {
                return DrainReport(
                    completion: .cancelled,
                    queryCount: queryCount,
                    changeCount: changeCount,
                    finalAnchor: anchor
                )
            }

            let batch = try await source.changes(
                for: type,
                after: anchor,
                limit: batchLimit
            )

            if Task.isCancelled {
                return DrainReport(
                    completion: .cancelled,
                    queryCount: queryCount,
                    changeCount: changeCount,
                    finalAnchor: anchor
                )
            }
            if let unexpected = batch.changes.first(where: { $0.type != type }) {
                throw DrainError.unexpectedType(expected: type, actual: unexpected.type)
            }
            if !batch.changes.isEmpty, batch.proposedAnchor == anchor {
                throw DrainError.nonAdvancingAnchor
            }

            try await sink.commit(batch, for: type, baseAnchor: anchor)
            anchor = batch.proposedAnchor
            queryCount += 1
            changeCount += batch.changes.count

            if !batch.changes.isEmpty {
                await onBatch?(changeCount)
            }

            if batch.changes.isEmpty {
                try await sink.markAnchorClosed(
                    type: type,
                    anchor: batch.proposedAnchor,
                    observedChangeCount: changeCount,
                    hadPriorAnchor: hadPriorAnchor,
                    at: .now
                )
                return DrainReport(
                    completion: .anchorClosed,
                    queryCount: queryCount,
                    changeCount: changeCount,
                    finalAnchor: batch.proposedAnchor
                )
            }

            if let maximumQueries, queryCount >= maximumQueries {
                return DrainReport(
                    completion: .paused,
                    queryCount: queryCount,
                    changeCount: changeCount,
                    finalAnchor: batch.proposedAnchor
                )
            }
        }
    }
}
