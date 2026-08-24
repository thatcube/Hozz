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
/// silently skips retroactive writes. Hozz's is strictly stronger, and the
/// wording in the interface says so.
///
/// The bounded cases exist for the other half of the request: someone pointing
/// Hozz at a home-automation dashboard wants recent data, not a decade of step
/// counts. They are a **filter over records already drained**, applied once the
/// batch is built. That has a consequence which is stated plainly rather than
/// hidden: a record older than the window is not delivered, and the anchor moves
/// past it, so it will not come round again on its own.
///
/// One record can therefore be excluded, but no record can be skipped *forever*,
/// because widening a destination's window resets that destination's anchors and
/// replays everything from the start. See
/// ``DeliveryWindow/covers(_:)`` and `DeliveryEngine.save(_:)`.
public enum DeliveryWindow: String, Codable, CaseIterable, Sendable {
    /// No date filter at all. The anchors decide, which is the only setting
    /// that cannot exclude a record.
    case sinceLastDelivery
    /// Midnight this morning until now.
    case today
    /// The whole of the previous day, and nothing since.
    case yesterday
    /// The whole of the previous day, plus today so far.
    case previousDayAndToday
    /// The seven days before today, plus today so far.
    case previous7Days

    public var displayName: String {
        switch self {
        case .sinceLastDelivery:
            "Everything not yet sent"
        case .today:
            "Today"
        case .yesterday:
            "Yesterday"
        case .previousDayAndToday:
            "Yesterday and today"
        case .previous7Days:
            "The last 7 days"
        }
    }

    /// What choosing this actually does, in the words a person would use.
    public var explanation: String {
        switch self {
        case .sinceLastDelivery:
            "Everything Hozz has read from Health and not yet delivered here, "
            + "however old it is. A reading the Health app filed under last "
            + "Tuesday this morning still gets sent. Nothing is left out."
        case .today:
            "Only readings dated since midnight. Anything older is not sent, "
            + "and will not be sent later."
        case .yesterday:
            "Only readings dated to the whole of yesterday. Today's are not "
            + "sent, and neither is anything older."
        case .previousDayAndToday:
            "Readings dated to yesterday or today. Anything older is not sent, "
            + "and will not be sent later."
        case .previous7Days:
            "Readings dated within the last seven days and today. Anything "
            + "older is not sent, and will not be sent later."
        }
    }

    /// Whether this window can leave a record out.
    public var isBounded: Bool {
        self != .sinceLastDelivery
    }

    /// The span of time this window admits, or nil when it admits everything.
    ///
    /// Days are the user's own calendar days, because that is what a person
    /// means by "today". A device in Auckland and one in Los Angeles agreeing on
    /// a UTC boundary would put half of somebody's evening in the wrong day.
    public func range(
        now: Date,
        calendar: Calendar = .current
    ) -> DateInterval? {
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .sinceLastDelivery:
            return nil
        case .today:
            return DateInterval(start: startOfToday, end: max(now, startOfToday))
        case .yesterday:
            let startOfYesterday = calendar.date(
                byAdding: .day,
                value: -1,
                to: startOfToday
            ) ?? startOfToday.addingTimeInterval(-86_400)
            return DateInterval(start: startOfYesterday, end: startOfToday)
        case .previousDayAndToday:
            let start = calendar.date(byAdding: .day, value: -1, to: startOfToday)
                ?? startOfToday.addingTimeInterval(-86_400)
            return DateInterval(start: start, end: max(now, start))
        case .previous7Days:
            let start = calendar.date(byAdding: .day, value: -7, to: startOfToday)
                ?? startOfToday.addingTimeInterval(-7 * 86_400)
            return DateInterval(start: start, end: max(now, start))
        }
    }

    /// Whether a record with this date belongs in this window.
    ///
    /// A record with no date is always admitted. That is not laxness: the one
    /// record shape that carries no date is a deletion tombstone, and a
    /// tombstone held back leaves a receiver showing a reading the user
    /// deliberately removed from Health. Excluding a record needs positive
    /// evidence that it falls outside, and an absent date is not evidence.
    public func admits(
        _ date: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let range = range(now: now, calendar: calendar), let date else {
            return true
        }
        // Half open at the end so a record at exactly midnight belongs to the
        // day starting there and to only one of two adjacent windows.
        return date >= range.start && date <= range.end
    }

    /// Whether every record this window admits is also admitted by the receiver.
    ///
    /// Used for one purpose: deciding whether changing a destination's window
    /// has to replay its history. If the window in force until now covered
    /// everything the new one wants, then nothing the new one wants was ever
    /// dropped, and the anchors can carry on. If it did not — going from
    /// "Today" to "The last 7 days", or from "Today" to "Yesterday" — then
    /// records the new setting wants have already been passed over, and the
    /// only way they are ever sent is to start the destination again.
    ///
    /// Deliberately a partial order rather than a size comparison. "Today" and
    /// "Yesterday" do not overlap at all, so neither covers the other, and
    /// moving between them in either direction has to replay.
    public func covers(_ other: DeliveryWindow) -> Bool {
        switch self {
        case .sinceLastDelivery:
            return true
        case .previous7Days:
            return other != .sinceLastDelivery
        case .previousDayAndToday:
            return other == .previousDayAndToday
                || other == .today
                || other == .yesterday
        case .today:
            return other == .today
        case .yesterday:
            return other == .yesterday
        }
    }
}

/// What applying a window to one batch did.
public struct WindowedBatch: Sendable {
    /// The batch to send, already rebuilt if anything was excluded. Nil when
    /// the window excluded every record, which is a complete delivery of
    /// nothing rather than a failure.
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
