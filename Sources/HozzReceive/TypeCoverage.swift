import Foundation
import HozzCore
import HozzStore

/// What this receiver has been *told* about how completely one type was read.
///
/// Three states, not two, and the distinction is the whole point. A receiver
/// that has never been told anything is not a receiver holding a complete
/// type: absence of a report is not evidence of completeness, and reading it
/// as one is how "Step Count · as of Jan 2023" came to be shown to someone who
/// wears a watch daily.
///
/// Only ``complete`` licenses a surface to present a held date as the person's
/// latest. In the other two the newest record held is the newest record
/// *received*, which is a fact about a transfer and not about a body.
public enum TypeCoverageStanding: Hashable, Sendable {
    /// No report has arrived. The phone may be older than this fact, may not
    /// have delivered since, or may never have read this type at all — and
    /// this receiver cannot tell which, so it claims none of them.
    case untold
    /// The phone says the anchored sweep has not run out of records.
    case incomplete(TypeCoverageReport)
    /// The phone says the sweep ran out of records. Everything is here, and
    /// dates mean what they appear to mean.
    case complete(TypeCoverageReport)

    public init(report: TypeCoverageReport?) {
        guard let report else {
            self = .untold
            return
        }
        self = report.isComplete ? .complete(report) : .incomplete(report)
    }

    public var report: TypeCoverageReport? {
        switch self {
        case .untold: nil
        case .incomplete(let report), .complete(let report): report
        }
    }

    /// Whether a date held for this type may be presented as the person's own
    /// most recent.
    ///
    /// The single question every surface should be asking, named so that no
    /// surface has to reason about anchors, sweeps, or ordering to answer it.
    public var licensesLatestDate: Bool {
        if case .complete = self { return true }
        return false
    }

    /// Whether the held data has two regions with a hole between them.
    ///
    /// A dated query fills a recent window while the sweep is still years
    /// back, so the archive is dense at both ends and empty in the middle.
    /// This looks exactly like a complete archive to anything counting
    /// records, and reading it as one is the same mistake in a new hat.
    public var hasGap: Bool {
        guard case .incomplete(let report) = self else { return false }
        return report.hasPrimedWindow
    }

    /// Whether the hole is one the phone is still working to close.
    ///
    /// A gap with a sweep running behind it will be filled. A gap with a sweep
    /// that has *stopped* will not, and the two want opposite sentences: one
    /// is patience, the other is a fault. They were the same sentence until a
    /// review caught it, which is precisely the collapse this whole signal was
    /// built to remove — surviving inside the code that removes it.
    public var hasClosingGap: Bool {
        hasGap && motion == .arriving
    }

    /// The stretch a dated query filled, when there is one.
    public var primedWindow: (from: Date, through: Date)? {
        guard
            let report,
            let from = report.primedFrom,
            let through = report.primedThrough
        else { return nil }
        return (from, through)
    }

    /// Whether Health declined to say whether this type is empty or denied.
    ///
    /// The sweep closed without ever returning an object, which HealthKit
    /// reports identically for "you have no records of this" and "you did not
    /// grant this". Kept separate from ``complete`` deliberately: collapsing
    /// the two would let a type nobody has permission to read be presented as
    /// a type the person genuinely has nothing for.
    public var isAuthorizationIndeterminate: Bool {
        report?.state == .authorizationIndeterminate
    }

    /// What is happening to this type right now, as opposed to how much of it
    /// is here.
    ///
    /// A dashboard row has to choose one word, and "still arriving" was being
    /// used for all of them — including streams that had stopped on an error
    /// and were never coming back. Reassurance a person cannot act on is worse
    /// than no annotation at all.
    public enum Motion: Hashable, Sendable {
        /// The sweep is running and has more to hand over.
        case arriving
        /// Stopped for a reason that clears itself, without anyone doing
        /// anything.
        case paused
        /// Stopped. Nothing more is coming unless something changes.
        case stopped
        /// Nothing is known about it either way.
        case unknown
    }

    public var motion: Motion {
        switch self {
        case .complete:
            return .stopped
        case .untold:
            return .unknown
        case .incomplete(let report):
            switch report.state {
            case .draining, .anchorClosed:
                return .arriving
            case .deviceLockedDeferred:
                return .paused
            case .authorizationIndeterminate,
                 .authorizationDismissed,
                 .limitedAuthorizationWindow,
                 .tombstoneGapSuspected,
                 .unsupported,
                 .unverifiedOnDevice,
                 .readFailed:
                return .stopped
            case .unknown:
                return .unknown
            }
        }
    }

    /// How to describe this type's standing in one clause, or nothing when
    /// there is nothing worth saying.
    ///
    /// Silence is the right answer for a complete type without a gap: the
    /// numbers beside it already say everything, and a row that annotates
    /// every state equally trains a reader to skip the annotation.
    ///
    /// Every other state gets its own clause. They used to share `draining`'s
    /// — "still arriving" — which meant a stream that had *stopped* on an
    /// error was described as making progress. That is the failure this whole
    /// signal exists to prevent, in the surface built to prevent it: on
    /// Brandon's phone the workout-route stream delivered 541 records, hit an
    /// error nobody had classified, and every week since has been reported as
    /// still on its way.
    public var qualifier: String? {
        switch self {
        case .complete:
            nil
        case .untold:
            "your phone has not said whether this type is finished"
        case .incomplete(let report):
            hasClosingGap
                ? "recent days are complete; older history is still arriving, "
                    + "so the middle is not here yet"
                : Self.qualifier(for: report.state)
        }
    }

    /// One clause per state, written out rather than defaulted.
    ///
    /// A `default:` here would be the same trap the states themselves were in:
    /// a case added later would silently inherit somebody else's sentence, and
    /// nothing would fail. Adding a state has to break this switch.
    private static func qualifier(for state: CoverageState) -> String {
        switch state {
        case .draining:
            "still arriving"
        case .anchorClosed:
            // Unreachable: a closed anchor is `.complete`. Answered rather
            // than crashed, because a state and a standing disagreeing is not
            // worth taking the dashboard down over.
            "still arriving"
        case .authorizationIndeterminate:
            "your phone read this type and Health returned nothing, which "
                + "it reports the same way whether there is nothing to "
                + "read or permission was declined"
        case .authorizationDismissed:
            "your phone is waiting for permission to read this type"
        case .deviceLockedDeferred:
            "your phone was locked and will pick this up when it is unlocked"
        case .limitedAuthorizationWindow:
            "your phone was granted only part of this type's history"
        case .tombstoneGapSuspected:
            "your phone could not read this type to the end, so it may have "
                + "gaps"
        case .unsupported:
            "your phone cannot read this type"
        case .unverifiedOnDevice:
            "your phone has not confirmed this type on this device"
        case .readFailed:
            "your phone's own read of this type failed, so it has stopped "
                + "rather than paused"
        case .unknown:
            "your phone sent a status this copy of Hozz cannot act on"
        }
    }
}

extension IngestStore {
    /// What the phone has said about every type it has reported on.
    public func coverage() throws -> [String: TypeCoverageReport] {
        let reports = try database.query(
            """
            SELECT type, state, delivered_count, primed_from, primed_through,
                   observed_at
              FROM type_coverage
             ORDER BY type
            """,
            row: Self.coverageReport
        )
        return Dictionary(uniqueKeysWithValues: reports.map { ($0.type, $0) })
    }

    /// What the phone has said about one type, if anything.
    public func coverage(for type: String) throws -> TypeCoverageReport? {
        try database.query(
            """
            SELECT type, state, delivered_count, primed_from, primed_through,
                   observed_at
              FROM type_coverage
             WHERE type = ?
            """,
            [.text(type)],
            row: Self.coverageReport
        ).first
    }

    /// The standing of one type, which is what a surface actually needs.
    public func coverageStanding(for type: String) throws -> TypeCoverageStanding {
        TypeCoverageStanding(report: try coverage(for: type))
    }

    private static func coverageReport(_ row: SQLiteRow) -> TypeCoverageReport {
        TypeCoverageReport(
            type: row.text(0),
            // An unrecognised word becomes `unknown` rather than throwing. A
            // Mac meeting a state a newer phone knows must still report that
            // a report exists: "I do not know what this says" and "nothing has
            // been said" license very different sentences, and only one of
            // them is this row.
            state: CoverageState(rawValue: row.text(1)) ?? .unknown,
            deliveredCount: row.optionalReal(2).map { Int($0) },
            primedFrom: row.optionalText(3).flatMap(Timestamps.date(from:)),
            primedThrough: row.optionalText(4).flatMap(Timestamps.date(from:)),
            observedAt: row.optionalText(5).flatMap(Timestamps.date(from:))
                ?? Date(timeIntervalSince1970: 0)
        )
    }
}
