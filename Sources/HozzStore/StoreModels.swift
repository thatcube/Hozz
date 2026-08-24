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
    /// One destination's own cursor space.
    ///
    /// Destinations must not share a cursor. They are scheduled independently —
    /// one may be hourly, another daily, another manual — so a shared cursor
    /// advanced by whichever happened to run would permanently skip that data
    /// for all the others. Giving each its own cursor costs re-reading the same
    /// pages once per destination and buys the guarantee that every destination
    /// receives everything it asked for.
    case destination(UUID)

    public var rawValue: String {
        switch self {
        case .global:
            "global"
        case .run(let id):
            "run:\(id.uuidString.lowercased())"
        case .destination(let id):
            "destination:\(id.uuidString.lowercased())"
        }
    }

    public init?(rawValue: String) {
        if rawValue == "global" {
            self = .global
            return
        }
        if rawValue.hasPrefix("run:"),
           let id = UUID(uuidString: String(rawValue.dropFirst(4))) {
            self = .run(id)
            return
        }
        if rawValue.hasPrefix("destination:"),
           let id = UUID(uuidString: String(rawValue.dropFirst(12))) {
            self = .destination(id)
            return
        }
        return nil
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

/// How a dated prime of one type is getting on.
public enum PrimeState: String, Codable, Hashable, Sendable {
    /// The window is being walked and part of it may already be delivered.
    case priming
    /// The frontier reached the start of the window. Everything in it is here.
    case covered
    /// The walk cannot continue without either dropping records or reading more
    /// than a background launch can hold, so it stopped and said so.
    ///
    /// Nothing is lost by this: the anchored sweep still reaches every record
    /// eventually. What is lost is the *speed*, and a stalled prime says that
    /// plainly rather than quietly claiming the window.
    case stalled
}

/// What a dated prime has actually covered for one type, in one cursor space.
///
/// The field that matters is ``frontier``, and it matters because of what it is
/// not. `windowStart` is an intention — the oldest instant this prime is aiming
/// at — and no surface may ever report it, because aiming at a date is not the
/// same as holding it. The frontier is the achieved position: it moves only
/// inside the same transaction that records a delivery the destination
/// accepted, so `[frontier, windowEnd)` is a claim the app can stand behind.
public struct PrimeRecord: Equatable, Sendable {
    public let type: HealthTypeKey
    /// The oldest instant this prime is aiming at. An intention, not a claim.
    public let windowStart: Date
    /// The newest instant of the window, fixed when the prime began.
    ///
    /// Fixed rather than "now" so the window does not slide out from under a
    /// walk that takes days: a moving end would leave a permanent sliver of
    /// unread recent data that the frontier could never catch.
    public let windowEnd: Date
    /// Everything from here to ``windowEnd`` has been delivered and accepted.
    public let frontier: Date
    /// The chunk length that suited this type's density last time.
    public let chunkSeconds: TimeInterval
    /// Records this prime has handed over, as the phone counts them.
    public let deliveredCount: Int
    public let state: PrimeState
    public let failureReason: String?
    public let updatedAt: Date

    public init(
        type: HealthTypeKey,
        windowStart: Date,
        windowEnd: Date,
        frontier: Date,
        chunkSeconds: TimeInterval,
        deliveredCount: Int,
        state: PrimeState,
        failureReason: String? = nil,
        updatedAt: Date
    ) {
        self.type = type
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.frontier = frontier
        self.chunkSeconds = chunkSeconds
        self.deliveredCount = deliveredCount
        self.state = state
        self.failureReason = failureReason
        self.updatedAt = updatedAt
    }

    /// The window that has genuinely been read, or nil when none has.
    ///
    /// A prime that has delivered nothing has no window, and deliberately does
    /// not report a zero-length one: anything asking whether a primed window
    /// exists would read `from == through` as "yes, an empty one" and present a
    /// density claim about no time at all.
    public var coveredWindow: (from: Date, through: Date)? {
        guard frontier < windowEnd else {
            return nil
        }
        return (frontier, windowEnd)
    }

    public var isCovered: Bool {
        state == .covered
    }
}

/// One type's prime frontier advance, staged until its delivery is accepted.
///
/// Deliberately parallel to ``PendingAnchorCommit`` and deliberately separate
/// from it. They are committed in the same transaction when a batch carried
/// both, but they are different rows in different tables, and no code path
/// turns one into the other — a prime cannot advance an anchor by accident
/// because there is no expressible way to say it.
public struct PendingPrimeCommit: Equatable, Sendable {
    public let type: HealthTypeKey
    /// The frontier this advance was computed from. A mismatch means something
    /// else moved the cursor underneath, and the write is refused rather than
    /// applied, exactly as a stale anchor base is.
    public let baseFrontier: Date
    public let frontier: Date
    public let chunkSeconds: TimeInterval
    public let addedRecordCount: Int
    public let state: PrimeState
    public let failureReason: String?

    public init(
        type: HealthTypeKey,
        baseFrontier: Date,
        frontier: Date,
        chunkSeconds: TimeInterval,
        addedRecordCount: Int,
        state: PrimeState,
        failureReason: String? = nil
    ) {
        self.type = type
        self.baseFrontier = baseFrontier
        self.frontier = frontier
        self.chunkSeconds = chunkSeconds
        self.addedRecordCount = addedRecordCount
        self.state = state
        self.failureReason = failureReason
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
    public let uncompressedByteCount: UInt64
    public let crc32: UInt32
    public let recordCount: Int
    public let createdAt: Date
    public let sealedAt: Date?

    public init(
        runID: UUID,
        sequence: Int,
        fileName: String,
        state: ExportPartState,
        byteCount: UInt64,
        uncompressedByteCount: UInt64 = 0,
        crc32: UInt32 = 0,
        recordCount: Int,
        createdAt: Date,
        sealedAt: Date?
    ) {
        self.runID = runID
        self.sequence = sequence
        self.fileName = fileName
        self.state = state
        self.byteCount = byteCount
        self.uncompressedByteCount = uncompressedByteCount
        self.crc32 = crc32
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
