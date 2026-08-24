import Foundation

/// How far back a destination is willing to be sent.
///
/// **This is a delivery window, not an acquisition cursor, and the difference
/// is the whole reason the file reads the way it does.**
///
/// Hozz reads Health through opaque, type-scoped anchors rather than date
/// windows, because Health accepts samples written retroactively: a workout
/// imported from a watch this morning can carry yesterday's date, and a query
/// for "everything since the last run" would never see it. Anchors have no such
/// hole — a record that appears is a record Hozz has not read before, whenever
/// it claims to have happened.
///
/// That is why ``sinceLastDelivery`` is the default and is *not* a date range at
/// all. It is the absence of a filter: everything the anchors have not yet
/// delivered, however old, however lately it was written. The competitor's
/// setting of the same name is a date cursor from the last run to now, and it
/// silently skips retroactive writes. Hozz's is strictly stronger.
///
/// ## Why every other case is a floor and never a range
///
/// The bounded cases exist for the other half of the request: someone pointing
/// Hozz at a new home-automation dashboard wants recent readings, not a decade
/// of step counts. Each one is a **floor** — an oldest date, with no upper bound
/// at all — and that shape is a correctness requirement rather than a
/// simplification.
///
/// A window with an upper bound loses records, permanently and invisibly, for
/// two separate reasons:
///
/// - **A reading newer than the window is gone.** A sample HealthKit gains while
///   a sync is already running comes back from the anchored query dated after
///   the moment the pass started. An upper bound at "now" excludes it, and the
///   anchor then commits past it. There is no reason for "the last seven days"
///   to reject a reading for being too *new*, and every reason not to.
/// - **A range that ends before today delivers almost nothing, for ever.** A
///   "Yesterday" window rejects everything dated today — but readings dated
///   today are drained today, and by the time they would fall inside
///   "yesterday" the cursor is long past them. The steady state is a destination
///   that receives nothing while reporting success. That case is not offered
///   here at all.
///
/// A floor has neither problem. It can still exclude a reading — one older than
/// the floor — and the anchor still moves past it, so that exclusion is
/// permanent on its own. Two things make it safe to offer anyway: it is counted
/// and reported rather than silent, and **lowering the floor replays the
/// destination's whole history**, so nothing is unreachable for ever. See
/// ``covers(_:)`` and `DeliveryEngine.save(_:)`.
///
/// One honest residue remains, and the interface says so: a floor moves with the
/// clock, so which readings it excludes depends on when iOS happened to let Hozz
/// run. A reading from late last night can fall outside "nothing older than
/// today" if the sync lands after midnight.
public enum DeliveryWindow: String, Codable, CaseIterable, Sendable {
    /// No date filter at all. The anchors decide, which is the only setting
    /// that cannot exclude a record.
    case sinceLastDelivery
    /// Nothing dated before midnight this morning.
    case sinceStartOfToday
    /// Nothing dated before midnight yesterday.
    case sinceStartOfYesterday
    /// Nothing dated before midnight seven days ago.
    case sinceSevenDaysAgo
    /// Nothing dated before midnight thirty days ago.
    case sinceThirtyDaysAgo

    public var displayName: String {
        switch self {
        case .sinceLastDelivery:
            "Everything not yet sent"
        case .sinceStartOfToday:
            "Nothing older than today"
        case .sinceStartOfYesterday:
            "Nothing older than yesterday"
        case .sinceSevenDaysAgo:
            "Nothing older than 7 days"
        case .sinceThirtyDaysAgo:
            "Nothing older than 30 days"
        }
    }

    /// What choosing this actually does, in the words a person would use.
    public var explanation: String {
        switch self {
        case .sinceLastDelivery:
            "Everything Hozz has read from Health and not yet delivered here, "
            + "however old it is. A reading the Health app filed under last "
            + "Tuesday this morning still gets sent. Nothing is left out."
        case .sinceStartOfToday:
            "Readings dated before midnight this morning are not sent here, "
            + "and will not be sent later."
        case .sinceStartOfYesterday:
            "Readings dated before midnight yesterday are not sent here, and "
            + "will not be sent later."
        case .sinceSevenDaysAgo:
            "Readings dated more than seven days ago are not sent here, and "
            + "will not be sent later."
        case .sinceThirtyDaysAgo:
            "Readings dated more than thirty days ago are not sent here, and "
            + "will not be sent later."
        }
    }

    /// Whether this window can leave a record out.
    public var isBounded: Bool {
        self != .sinceLastDelivery
    }

    /// How many whole days back the floor sits, or nil when there is no floor.
    ///
    /// The single source of every date and every ordering below, so the picker,
    /// the filter, and the decision to replay history cannot drift apart.
    var daysBack: Int? {
        switch self {
        case .sinceLastDelivery:
            nil
        case .sinceStartOfToday:
            0
        case .sinceStartOfYesterday:
            1
        case .sinceSevenDaysAgo:
            7
        case .sinceThirtyDaysAgo:
            30
        }
    }

    /// The oldest date this window will deliver, or nil when it has no floor.
    ///
    /// Days are the user's own calendar days, because that is what a person
    /// means by "today". A device in Auckland and one in Los Angeles agreeing on
    /// a UTC boundary would put half of somebody's evening in the wrong day.
    public func floor(now: Date, calendar: Calendar = .current) -> Date? {
        guard let daysBack else {
            return nil
        }
        let startOfToday = calendar.startOfDay(for: now)
        guard daysBack > 0 else {
            return startOfToday
        }
        return calendar.date(byAdding: .day, value: -daysBack, to: startOfToday)
            ?? startOfToday.addingTimeInterval(-Double(daysBack) * 86_400)
    }

    /// Whether a record with this date belongs in this window.
    ///
    /// A record with no date is always admitted. That is not laxness: the one
    /// record shape that carries no date is a deletion tombstone, and a
    /// tombstone held back leaves a receiver showing a reading the user
    /// deliberately removed from Health. Excluding a record needs positive
    /// evidence that it falls outside, and an absent date is not evidence.
    ///
    /// There is no upper bound, so a reading recorded while the sync was already
    /// running is never rejected for being too new.
    public func admits(
        _ date: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let floor = floor(now: now, calendar: calendar), let date else {
            return true
        }
        return date >= floor
    }

    /// Whether every record this window admits is also admitted by the receiver.
    ///
    /// Used for one purpose: deciding whether changing a destination's window
    /// has to replay its history. If the window in force until now admitted
    /// everything the new one wants, nothing the new one wants was ever dropped,
    /// and the cursors can carry on. If it did not — going from "Nothing older
    /// than today" to "Nothing older than 7 days" — then readings the new
    /// setting wants have already been passed over, and the only way they are
    /// ever sent is to start the destination again.
    ///
    /// Floors are totally ordered, and the ordering holds whenever it is
    /// evaluated, because every floor is a fixed number of days back from the
    /// user's own midnight. That is what makes this a sound basis for the
    /// decision even though the old window was in force over past days while the
    /// new one is being judged today.
    public func covers(_ other: DeliveryWindow) -> Bool {
        guard let mine = daysBack else {
            // No floor admits everything.
            return true
        }
        guard let theirs = other.daysBack else {
            return false
        }
        return mine >= theirs
    }
}

/// What applying a window to one batch did.
public struct WindowedBatch: Sendable {
    /// The batch to send, already rebuilt if anything was excluded. Nil when the
    /// window excluded every record, which is a complete delivery of nothing
    /// rather than a failure.
    public let batch: DeliveryBatch?
    public let excludedRecords: Int

    public init(batch: DeliveryBatch?, excludedRecords: Int) {
        self.batch = batch
        self.excludedRecords = excludedRecords
    }
}

extension DeliveryWindow {
    /// Applies this window to an encoded batch.
    ///
    /// A batch nothing was excluded from comes back byte-identical, with the
    /// identifier it arrived with. A batch that lost records is rebuilt, and
    /// therefore gets a **new** identifier derived from its new bytes — which is
    /// the rule the whole idempotency scheme rests on. Reusing the old key for
    /// different contents is exactly how a correctly written receiver ends up
    /// discarding records it has never seen.
    ///
    /// Throws when the payload could not be taken apart, rather than delivering
    /// it whole. Sending records the user asked to exclude is not a smaller
    /// failure than sending nothing; it is the one that looks like it worked.
    public func apply(
        to batch: DeliveryBatch,
        destination: Destination,
        now: Date,
        calendar: Calendar = .current
    ) throws -> WindowedBatch {
        guard isBounded, !batch.payload.isEmpty else {
            return WindowedBatch(batch: batch, excludedRecords: 0)
        }
        guard
            let division = PayloadDivision.decompose(
                batch.payload,
                format: batch.format,
                influxPrecision: destination.influxOptions.precision,
                dateStyle: destination.pointDateStyle
            )
        else {
            throw DeliveryError.windowNotApplicable
        }

        let kept = division.records.filter {
            admits($0.date, now: now, calendar: calendar)
        }
        let excluded = division.count - kept.count
        guard excluded > 0 else {
            return WindowedBatch(batch: batch, excludedRecords: 0)
        }
        guard !kept.isEmpty else {
            return WindowedBatch(batch: nil, excludedRecords: excluded)
        }

        let payload = division.recompose(kept)
        return WindowedBatch(
            batch: DeliveryBatch(
                id: DeliveryBatch.identifier(for: payload),
                sequence: batch.sequence,
                createdAt: batch.createdAt,
                recordCount: kept.count,
                payload: payload,
                format: batch.format
            ),
            excludedRecords: excluded
        )
    }
}

extension Destination {
    /// Which spelling of a date this destination's Metrics JSON uses.
    var pointDateStyle: PayloadDivision.PointDateStyle {
        format == .metrics && payloadSchema == .healthAutoExport
            ? .healthAutoExport(.current)
            : .iso8601
    }
}
