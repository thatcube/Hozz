import Foundation
import HozzCore

/// Identifies which cursor space a stream's anchors belong to.
///
/// A manual export is a complete historical snapshot, so it drains from its own
/// run-scoped cursor space and always starts from nothing. The `global` scope is
/// reserved for the continuous, incremental pipeline, whose anchors must survive
/// across runs.
public enum AnchorScope: Hashable, Sendable {
    case global
    case run(UUID)

    public var rawValue: String {
        switch self {
        case .global:
            "global"
        case .run(let id):
            "run:\(id.uuidString.lowercased())"
        }
    }

    public init?(rawValue: String) {
        if rawValue == "global" {
            self = .global
            return
        }
        guard
            rawValue.hasPrefix("run:"),
            let id = UUID(uuidString: String(rawValue.dropFirst(4)))
        else {
            return nil
        }
        self = .run(id)
    }
}

/// The durable state of one Health type inside one cursor space.
public struct StreamRecord: Equatable, Sendable {
    public let type: HealthTypeKey
    public let coverage: CoverageState
    public let committedAnchor: AnchorToken?
    public let recordCount: Int
    public let observedCount: Int
    public let anchorClosedAt: Date?
    public let failureReason: String?
    public let updatedAt: Date

    public init(
        type: HealthTypeKey,
        coverage: CoverageState,
        committedAnchor: AnchorToken?,
        recordCount: Int,
        observedCount: Int,
        anchorClosedAt: Date?,
        failureReason: String?,
        updatedAt: Date
    ) {
        self.type = type
        self.coverage = coverage
        self.committedAnchor = committedAnchor
        self.recordCount = recordCount
        self.observedCount = observedCount
        self.anchorClosedAt = anchorClosedAt
        self.failureReason = failureReason
        self.updatedAt = updatedAt
    }
}

public enum ExportRunState: String, Codable, Hashable, Sendable {
    /// The run owns the current export and is actively draining.
    case running
    /// The run stopped at a checkpoint and can be resumed without loss.
    case paused
    /// Every attempted type reached a terminal state and the parts were joined.
    case completed
    /// The run stopped for a reason a resume cannot clear.
    case failed
    /// The user discarded the run; its artifacts may be swept.
    case abandoned

    public var isResumable: Bool {
        self == .running || self == .paused
    }

    public var isTerminal: Bool {
        !isResumable
    }
}

/// A gzip member written by one uninterrupted stretch of a run.
///
/// A part is `open` while it is being written and `sealed` once it has been
/// flushed, closed, and its byte count recorded. Anchors may only be committed
/// for data that lives in a sealed part.
public enum ExportPartState: String, Codable, Hashable, Sendable {
    case open
    case sealed
}

public struct ExportRunRecord: Equatable, Sendable {
    public let id: UUID
    public let state: ExportRunState
    public let format: String
    public let startedAt: Date
    public let updatedAt: Date
    public let finishedAt: Date?
    public let recordCount: Int
    public let attemptedTypeCount: Int
    public let catalogVersion: String
    public let sampleEncodingErrorCount: Int
    public let failureReason: String?
    public let finalFileName: String?

    public init(
        id: UUID,
        state: ExportRunState,
        format: String,
        startedAt: Date,
        updatedAt: Date,
        finishedAt: Date?,
        recordCount: Int,
        attemptedTypeCount: Int,
        catalogVersion: String,
        sampleEncodingErrorCount: Int,
        failureReason: String?,
        finalFileName: String?
    ) {
        self.id = id
        self.state = state
        self.format = format
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.recordCount = recordCount
        self.attemptedTypeCount = attemptedTypeCount
        self.catalogVersion = catalogVersion
        self.sampleEncodingErrorCount = sampleEncodingErrorCount
        self.failureReason = failureReason
        self.finalFileName = finalFileName
    }
}

public struct ExportPartRecord: Equatable, Sendable {
    public let runID: UUID
    public let sequence: Int
    public let fileName: String
    public let state: ExportPartState
    public let byteCount: UInt64
    public let recordCount: Int
    public let createdAt: Date
    public let sealedAt: Date?

    public init(
        runID: UUID,
        sequence: Int,
        fileName: String,
        state: ExportPartState,
        byteCount: UInt64,
        recordCount: Int,
        createdAt: Date,
        sealedAt: Date?
    ) {
        self.runID = runID
        self.sequence = sequence
        self.fileName = fileName
        self.state = state
        self.byteCount = byteCount
        self.recordCount = recordCount
        self.createdAt = createdAt
        self.sealedAt = sealedAt
    }
}

/// One type's anchor advance, staged in memory until its part is sealed.
public struct PendingAnchorCommit: Equatable, Sendable {
    public let type: HealthTypeKey
    public let baseAnchor: AnchorToken?
    public let anchor: AnchorToken
    public let coverage: CoverageState
    public let addedRecordCount: Int
    public let addedObservedCount: Int
    public let anchorClosedAt: Date?
    public let failureReason: String?

    public init(
        type: HealthTypeKey,
        baseAnchor: AnchorToken?,
        anchor: AnchorToken,
        coverage: CoverageState,
        addedRecordCount: Int,
        addedObservedCount: Int,
        anchorClosedAt: Date? = nil,
        failureReason: String? = nil
    ) {
        self.type = type
        self.baseAnchor = baseAnchor
        self.anchor = anchor
        self.coverage = coverage
        self.addedRecordCount = addedRecordCount
        self.addedObservedCount = addedObservedCount
        self.anchorClosedAt = anchorClosedAt
        self.failureReason = failureReason
    }
}
