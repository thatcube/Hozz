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

    /// How to describe this type's standing in one clause, or nothing when
    /// there is nothing worth saying.
    ///
    /// Silence is the right answer for a complete type without a gap: the
    /// numbers beside it already say everything, and a row that annotates
    /// every state equally trains a reader to skip the annotation.
    public var qualifier: String? {
        switch self {
        case .complete:
            nil
        case .untold:
            "your phone has not said whether this type is finished"
        case .incomplete(let report):
            if hasGap {
                "recent days are complete; older history is still arriving, "
                    + "so the middle is not here yet"
            } else if report.state == .authorizationIndeterminate {
                "your phone read this type and Health returned nothing, which "
                    + "it reports the same way whether there is nothing to "
                    + "read or permission was declined"
            } else {
                "still arriving"
            }
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
