import CryptoKit
import Foundation
import HozzCore
import HozzStore

/// Turns what the phone knows about reading each type into what it tells a
/// receiver.
///
/// The phone has recorded per-type coverage since the first version and never
/// sent it anywhere, so every surface downstream inferred it from the records
/// that happened to have arrived. That inference cannot work: an anchored sweep
/// returns samples in the order Health stored them, so an unfinished type has
/// delivered an arbitrary subset by date and its newest arrival says nothing
/// about the person. This is the piece that replaces the inference with the
/// fact.
public enum CoverageReporter {
    /// A stretch a dated query has genuinely filled.
    ///
    /// Both ends are required. A window with one end is not a window, and a
    /// zero-length one is worse than none: anything asking "is there a primed
    /// window" would be told yes about a stretch containing nothing.
    public struct PrimedWindow: Equatable, Sendable {
        public let from: Date
        public let through: Date

        public init?(from: Date, through: Date) {
            guard from < through else {
                return nil
            }
            self.from = from
            self.through = through
        }
    }

    /// One report per type the phone has state for.
    ///
    /// - Parameters:
    ///   - stored: what the store holds for this cursor space.
    ///   - pass: coverage this pass is about to commit, which overrides the
    ///     stored value for the types it names. Reporting the stored value
    ///     instead would put every completion one delivery late, and a type
    ///     that finishes and then never changes again would never be reported
    ///     complete at all.
    ///   - primedWindows: stretches filled by a dated query rather than the
    ///     sweep. Supplied by the caller rather than read here, because the
    ///     dated reader is a separate concern and this type must not grow an
    ///     opinion about how a window came to be.
    ///   - observedAt: when this set of facts was observed. One moment for the
    ///     whole set, which is what the field means and what keeps the bytes
    ///     still — see ``observation(matching:storedDigest:storedMoment:now:)``.
    public static func reports(
        from stored: [StreamRecord],
        pass: [HealthTypeKey: PassCoverage] = [:],
        primedWindows: [HealthTypeKey: PrimedWindow] = [:],
        observedAt: Date
    ) -> [TypeCoverageReport] {
        var byType: [HealthTypeKey: TypeCoverageReport] = [:]

        for record in stored {
            let window = primedWindows[record.type]
            byType[record.type] = TypeCoverageReport(
                type: record.type.rawValue,
                state: record.coverage,
                deliveredCount: record.recordCount,
                primedFrom: window?.from,
                primedThrough: window?.through,
                observedAt: observedAt
            )
        }

        for (type, coverage) in pass {
            let window = primedWindows[type]
            let priorCount = byType[type]?.deliveredCount ?? 0
            byType[type] = TypeCoverageReport(
                type: type.rawValue,
                state: coverage.state,
                deliveredCount: coverage.deliveredCount ?? priorCount,
                primedFrom: window?.from,
                primedThrough: window?.through,
                observedAt: observedAt
            )
        }

        // Sorted so two passes over the same facts produce the same bytes, and
        // so the digest below is a statement about the coverage rather than
        // about dictionary ordering.
        return byType.values.sorted { $0.type < $1.type }
    }

    /// When a set of coverage was observed: the moment it last *changed*, not
    /// the moment it was last confirmed.
    ///
    /// This exists because the clock cannot be used here, and the reason is
    /// not obvious.
    ///
    /// A batch is identified by a hash of its bytes, and that identity is the
    /// whole of a receiver's duplicate detection. When an acknowledgement is
    /// lost the phone keeps its cursors, re-reads the same records, and sends
    /// the same batch — and the receiver is supposed to recognise it. Stamping
    /// each pass with `Date.now` puts a different byte in every payload, so an
    /// identical retry arrives under a new identity and is stored as though it
    /// were new. That path is at its busiest during a first sweep, which is
    /// also the longest and most interruption-prone delivery there is.
    ///
    /// A receiver too old to understand these lines quarantines each one under
    /// a fingerprint of its bytes, so a moving timestamp would also add a
    /// fresh row per type per delivery, for ever, on a Mac that is merely a
    /// version behind and has lost nothing.
    ///
    /// Re-confirming a fact does not change when it became true, so the stable
    /// reading is also the honest one.
    ///
    /// - Returns: the moment to stamp, and whether it needs recording. A
    ///   moment is recorded before delivery rather than after, because it is
    ///   an observation rather than a claim about what a destination received
    ///   — and recording it after would leave a refused batch's retry looking
    ///   for a moment that was never written down.
    public static func observation(
        matching digest: String,
        storedDigest: String?,
        storedMoment: Date?,
        now: Date
    ) -> (moment: Date, isNew: Bool) {
        guard
            let storedDigest,
            let storedMoment,
            storedDigest == digest,
            // A moment from the future is a clock that moved backwards. Keeping
            // it would freeze the timestamp until the clock caught up, and a
            // receiver comparing moments would refuse everything in between.
            storedMoment <= now
        else {
            return (now, true)
        }
        return (storedMoment, false)
    }

    /// What one type's coverage will be once the batch carrying it is accepted.
    public struct PassCoverage: Equatable, Sendable {
        public let state: CoverageState
        public let deliveredCount: Int?

        public init(state: CoverageState, deliveredCount: Int? = nil) {
            self.state = state
            self.deliveredCount = deliveredCount
        }
    }

    /// A stable summary of everything a receiver would learn from these reports.
    ///
    /// Deliberately excludes `observedAt`. Including it would make the digest
    /// differ on every pass, which would turn "send when something changed"
    /// into "send every hour forever" — a batch delivered to a Mac that is
    /// switched off, failing, backing off, and eventually parking a destination
    /// that had nothing wrong with it.
    public static func digest(of reports: [TypeCoverageReport]) -> String {
        var hash = SHA256()
        for report in reports.sorted(by: { $0.type < $1.type }) {
            hash.update(data: Data(report.type.utf8))
            hash.update(data: Data(report.state.rawValue.utf8))
            hash.update(data: Data("\(report.deliveredCount ?? -1)".utf8))
            hash.update(data: Data(Self.stamp(report.primedFrom).utf8))
            hash.update(data: Data(Self.stamp(report.primedThrough).utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The reports as the lines a lossless payload carries.
    public static func lines(for reports: [TypeCoverageReport]) -> [Data] {
        reports.compactMap { report in
            try? JSONSerialization.data(
                withJSONObject: TypeCoverageShape.line(for: report),
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        }
    }

    private static func stamp(_ date: Date?) -> String {
        date.map { String($0.timeIntervalSince1970) } ?? "-"
    }
}

extension DeliveryFormat {
    /// Whether a coverage report survives this format.
    ///
    /// Only the lossless shapes carry one. A CSV has fixed columns and a
    /// metrics envelope reduces a record to one number, so a report sent in
    /// either would arrive as a row of empty fields or as a metric named after
    /// a type — which is how a reading page once landed inside the real metric
    /// and made every point count wrong. Left out is the honest option: a
    /// receiver reading those formats is told nothing rather than something
    /// false.
    public var carriesCoverage: Bool {
        switch self {
        case .ndjson, .json:
            true
        case .csv, .metrics, .influx:
            false
        }
    }
}

extension Destination {
    /// The coverage last accepted by this destination, as a digest.
    ///
    /// Kept in `options` beside the delivery floor and the replay marker rather
    /// than in a table of its own, because it is the same kind of fact: a small
    /// piece of per-destination bookkeeping that has to survive a relaunch and
    /// means nothing without the destination it belongs to.
    ///
    /// Recorded only after a delivery is accepted. A digest written before
    /// would mark coverage as told when the batch carrying it was refused, and
    /// the receiver would then wait for a change that had already happened.
    public static let coverageDigestKey = "coverageDigest"

    /// The coverage this destination has currently observed, and when.
    ///
    /// Separate from the digest above because the two are written at different
    /// moments and mean different things. This one records an *observation*,
    /// so it is written before a delivery is attempted and survives a refusal;
    /// that one records what a destination *accepted*, so it is written only
    /// after one succeeds. Collapsing them would either mark coverage as told
    /// when the batch carrying it was refused, or leave a retry unable to
    /// reproduce the bytes it sent a minute earlier.
    public static let coverageObservedDigestKey = "coverageObservedDigest"
    public static let coverageObservedAtKey = "coverageObservedAt"

    public var reportedCoverageDigest: String? {
        options[Destination.coverageDigestKey]
    }

    public var observedCoverageDigest: String? {
        options[Destination.coverageObservedDigestKey]
    }

    public var observedCoverageMoment: Date? {
        options[Destination.coverageObservedAtKey]
            .flatMap(Timestamps.date(from:))
    }
}
