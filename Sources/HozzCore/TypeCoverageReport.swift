import Foundation

/// What a receiver is told about how completely a type has been read.
///
/// The phone has always known this. ``StreamCoverage`` records, per type,
/// whether the anchored sweep has closed, and the store has carried it since
/// the first version. It was simply never sent anywhere, so every surface
/// downstream had to guess — and guessed wrong in the one direction that
/// matters.
///
/// The guess it made: a receiver holding step count up to January 2023 wrote
/// "as of Jan 2023", which reads as a statement about the person. It cannot be
/// one. `HKAnchoredObjectQuery` returns samples in the order Health stored
/// them, not the order they happened, so what has arrived for an unfinished
/// type is an arbitrary subset by date. The newest record received is the
/// newest record *received*, and says nothing whatever about the newest record
/// that exists.
///
/// So this deliberately carries no "swept through <date>" field. That number
/// would be easy to compute, would look authoritative, and would be a claim the
/// sweep's ordering cannot support. What is knowable is carried instead:
///
///   - `isComplete` — the anchor closed. Everything is here. Dates mean what
///     they appear to mean, and only then.
///   - `primedFrom`/`primedThrough` — a window read by a *dated* query, which
///     is a genuine density claim: everything in it is present.
///
/// Between an incomplete sweep and a primed window there is a hole, and a
/// surface that does not know about this record cannot know the hole is there.
public struct TypeCoverageReport: Codable, Hashable, Sendable {
    /// The HealthKit type identifier this describes.
    public let type: String
    /// What the phone last observed about reading it.
    public let state: CoverageState
    /// Whether the anchored sweep has run out of records at least once.
    ///
    /// The only field that licenses a surface to present a date as current.
    public var isComplete: Bool { state == .anchorClosed }
    /// Records delivered for this type so far, as the phone counts them.
    ///
    /// Informational. Deliberately not compared against the receiver's own
    /// count to decide completeness: they can differ legitimately, and a
    /// disagreement between two counts is not evidence about a third thing.
    public let deliveredCount: Int?
    /// The start of a window read by a dated query rather than the sweep.
    public let primedFrom: Date?
    /// The end of that window.
    public let primedThrough: Date?
    /// When the phone observed all of the above.
    public let observedAt: Date

    public init(
        type: String,
        state: CoverageState,
        deliveredCount: Int? = nil,
        primedFrom: Date? = nil,
        primedThrough: Date? = nil,
        observedAt: Date
    ) {
        self.type = type
        self.state = state
        self.deliveredCount = deliveredCount
        self.primedFrom = primedFrom
        self.primedThrough = primedThrough
        self.observedAt = observedAt
    }

    /// Whether a dated prime has filled a window that the sweep has not reached.
    ///
    /// True means the held data has two regions with a gap between them, and no
    /// surface may present it as one continuous history.
    public var hasPrimedWindow: Bool {
        primedFrom != nil && primedThrough != nil
    }
}

/// The wire shape, written once and read once.
///
/// Kept beside the type rather than in the parser because a producer and a
/// parser that each know the key names separately is precisely the arrangement
/// that has produced every disagreement in this app so far.
public enum TypeCoverageShape {
    public static let kind = "typeCoverage"

    public static func line(for report: TypeCoverageReport) -> [String: Any] {
        var object: [String: Any] = [
            "kind": kind,
            "type": report.type,
            "state": report.state.rawValue,
            "complete": report.isComplete,
            "observedAt": Timestamps.text(from: report.observedAt)
        ]
        if let count = report.deliveredCount {
            object["deliveredCount"] = count
        }
        if let from = report.primedFrom {
            object["primedFrom"] = Timestamps.text(from: from)
        }
        if let through = report.primedThrough {
            object["primedThrough"] = Timestamps.text(from: through)
        }
        return object
    }

    public static func report(in object: [String: Any]) -> TypeCoverageReport? {
        guard
            (object["kind"] as? String) == kind,
            let type = object["type"] as? String,
            let observedAt = (object["observedAt"] as? String)
                .flatMap(Timestamps.date(from:))
        else { return nil }

        // An unknown state is read as `unknown` rather than dropped. A receiver
        // meeting a word a newer phone knows must not silently lose the fact
        // that a report arrived at all — "I do not know what this says" and "no
        // report exists" license very different sentences downstream.
        let state = (object["state"] as? String)
            .flatMap(CoverageState.init(rawValue:)) ?? .unknown

        return TypeCoverageReport(
            type: type,
            state: state,
            deliveredCount: (object["deliveredCount"] as? NSNumber)?.intValue,
            primedFrom: (object["primedFrom"] as? String).flatMap(Timestamps.date(from:)),
            primedThrough: (object["primedThrough"] as? String).flatMap(Timestamps.date(from:)),
            observedAt: observedAt
        )
    }
}
