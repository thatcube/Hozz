import Foundation

/// How wide one column of a chart is.
public enum ChartGranularity: String, CaseIterable, Sendable, Hashable {
    case hour
    case day
    case week
    case month
    case year

    var component: Calendar.Component {
        switch self {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    /// The label a person reads for one column.
    public var columnNoun: String {
        switch self {
        case .hour: "hour"
        case .day: "day"
        case .week: "week"
        case .month: "month"
        case .year: "year"
        }
    }
}

/// How far back a chart looks.
public enum ChartRange: String, CaseIterable, Sendable, Hashable, Identifiable {
    case week
    case month
    case year
    case all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .all: "All"
        }
    }

    /// The column width that keeps a range readable.
    ///
    /// Not a preference: a year of hourly columns is 8,760 bars in a few hundred
    /// points of width, which is a grey smear rather than a chart, and a week of
    /// monthly columns is one bar.
    public var granularity: ChartGranularity {
        switch self {
        case .week: .day
        case .month: .day
        case .year: .week
        case .all: .month
        }
    }
}

/// The local-time columns a chart is drawn from.
///
/// Boundaries are computed with a `Calendar` rather than by dividing a timestamp,
/// because a local day is not always 86,400 seconds long. Twice a year one is 23
/// hours and one is 25, and arithmetic that assumes otherwise moves an evening's
/// samples into the following morning — the same mistake `ExportMarkdownWriter`
/// had to be taught not to make. The calendar is injectable so a test can pin a
/// zone and a clock instead of inheriting the machine's.
public struct TimeBucketPlan: Sendable, Equatable {
    /// Half-open `[start, end)` in absolute time; the label is the local wall
    /// clock those instants correspond to.
    public struct Column: Sendable, Equatable, Hashable {
        public let index: Int
        public let start: Date
        public let end: Date

        public init(index: Int, start: Date, end: Date) {
            self.index = index
            self.start = start
            self.end = end
        }

        /// Whole local days this column spans, used to say how much of a column
        /// actually has data in it. Computed from the calendar rather than from
        /// the elapsed seconds so a short or long day still counts as one day.
        public func dayCount(in calendar: Calendar) -> Int {
            let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
            return max(days, 1)
        }
    }

    public let columns: [Column]
    public let granularity: ChartGranularity
    public let calendar: Calendar

    /// The whole span the columns cover, or `nil` when there are none.
    public var span: (start: Date, end: Date)? {
        guard let first = columns.first, let last = columns.last else {
            return nil
        }
        return (first.start, last.end)
    }

    public init(columns: [Column], granularity: ChartGranularity, calendar: Calendar) {
        self.columns = columns
        self.granularity = granularity
        self.calendar = calendar
    }

    /// Columns covering `[start, end)`, aligned to local boundaries.
    ///
    /// The first column starts at the boundary at or before `start`, so a range
    /// beginning mid-afternoon still produces whole days rather than a first
    /// column that is a different width from every other one.
    public static func covering(
        from start: Date,
        to end: Date,
        granularity: ChartGranularity,
        calendar: Calendar
    ) -> TimeBucketPlan {
        guard end > start else {
            return TimeBucketPlan(columns: [], granularity: granularity, calendar: calendar)
        }

        var columns: [Column] = []
        var cursor = align(start, to: granularity, calendar: calendar)
        var index = 0

        // A guard against a calendar that refuses to advance. Without it a
        // malformed component request spins forever holding the main thread,
        // which on a chart redraw is indistinguishable from a hang.
        let ceiling = 100_000
        while cursor < end, index < ceiling {
            guard let next = calendar.date(
                byAdding: granularity.component,
                value: 1,
                to: cursor
            ), next > cursor else {
                break
            }
            columns.append(Column(index: index, start: cursor, end: next))
            cursor = next
            index += 1
        }

        return TimeBucketPlan(
            columns: columns,
            granularity: granularity,
            calendar: calendar
        )
    }

    /// The most recent `count` columns ending after `now`.
    ///
    /// The final column is the one `now` falls inside, included in full even
    /// though only part of it has happened. Trimming it to the current instant
    /// would make today's bar shorter than yesterday's for a reason that has
    /// nothing to do with the person's health, and coverage reporting already
    /// says a partial column is partial.
    public static func trailing(
        _ count: Int,
        granularity: ChartGranularity,
        endingAt now: Date,
        calendar: Calendar
    ) -> TimeBucketPlan {
        guard count > 0 else {
            return TimeBucketPlan(columns: [], granularity: granularity, calendar: calendar)
        }
        let lastStart = align(now, to: granularity, calendar: calendar)
        guard let end = calendar.date(
            byAdding: granularity.component,
            value: 1,
            to: lastStart
        ) else {
            return TimeBucketPlan(columns: [], granularity: granularity, calendar: calendar)
        }
        guard let start = calendar.date(
            byAdding: granularity.component,
            value: -(count - 1),
            to: lastStart
        ) else {
            return TimeBucketPlan(columns: [], granularity: granularity, calendar: calendar)
        }
        return covering(
            from: start,
            to: end,
            granularity: granularity,
            calendar: calendar
        )
    }

    /// The start of the local hour, day, week, month or year containing `date`.
    public static func align(
        _ date: Date,
        to granularity: ChartGranularity,
        calendar: Calendar
    ) -> Date {
        switch granularity {
        case .hour:
            return calendar.dateInterval(of: .hour, for: date)?.start
                ?? calendar.startOfDay(for: date)
        case .day:
            // `startOfDay` rather than a components round-trip: on a day where
            // the clocks go forward at midnight there is no 00:00 at all, and
            // building a date from components then yields 01:00 or nil.
            return calendar.startOfDay(for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start
                ?? calendar.startOfDay(for: date)
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start
                ?? calendar.startOfDay(for: date)
        case .year:
            return calendar.dateInterval(of: .year, for: date)?.start
                ?? calendar.startOfDay(for: date)
        }
    }

    /// A plan for one of the offered ranges, ending at `now`.
    ///
    /// `all` needs the archive's own extent, which only the store knows, so it
    /// is passed in rather than guessed at.
    public static func forRange(
        _ range: ChartRange,
        now: Date,
        earliest: Date?,
        calendar: Calendar
    ) -> TimeBucketPlan {
        switch range {
        case .week:
            return trailing(7, granularity: .day, endingAt: now, calendar: calendar)
        case .month:
            return trailing(30, granularity: .day, endingAt: now, calendar: calendar)
        case .year:
            return trailing(53, granularity: .week, endingAt: now, calendar: calendar)
        case .all:
            guard let earliest, earliest < now else {
                return trailing(12, granularity: .month, endingAt: now, calendar: calendar)
            }
            let start = align(earliest, to: .month, calendar: calendar)
            guard let end = calendar.date(
                byAdding: .month,
                value: 1,
                to: align(now, to: .month, calendar: calendar)
            ) else {
                return trailing(12, granularity: .month, endingAt: now, calendar: calendar)
            }
            return covering(
                from: start,
                to: end,
                granularity: .month,
                calendar: calendar
            )
        }
    }
}
