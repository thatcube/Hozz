import Foundation
import HozzCore
import HozzStore

/// A SQL expression that maps a stored UTC timestamp to a local calendar day.
///
/// Local days are what a person means by "day", and they are not a fixed number
/// of seconds apart: twice a year one is 23 hours and one is 25. Dividing the
/// timestamp by 86,400 therefore puts an evening's samples on the following
/// morning around every transition, which is the bug `ExportMarkdownWriter` was
/// taught to avoid and the reason this is not simply `date(start_date)`.
///
/// The offsets come from the same `TimeZone` the chart's columns are built from,
/// so the grouping in the database and the labels on the axis can never disagree
/// about where a day begins. A test asserts the two agree across a transition.
public struct LocalDayExpression {
    /// The instant an offset stops applying, and the offset before it.
    private struct Segment {
        let until: Date
        let offsetSeconds: Int
    }

    private let segments: [Segment]
    private let finalOffset: Int

    /// Keeps the dividend positive so integer division truncates the same way
    /// floor would. SQLite truncates towards zero, so a negative value either
    /// side of the epoch would land a day out; no health record predates 1970,
    /// but a bias costs nothing and removes the question.
    private static let bias = 62_135_596_800
    public init(timeZone: TimeZone, from start: Date, to end: Date) {
        var segments: [Segment] = []
        var cursor = start
        var offset = timeZone.secondsFromGMT(for: start)

        // Transitions are rare — two a year in a zone that observes them — so
        // walking them is cheap, and a zone with none produces no segments and
        // a single constant offset.
        var guardCount = 0
        while let next = timeZone.nextDaylightSavingTimeTransition(after: cursor),
              next < end,
              guardCount < 512 {
            segments.append(Segment(until: next, offsetSeconds: offset))
            offset = timeZone.secondsFromGMT(for: next)
            cursor = next
            guardCount += 1
        }

        self.segments = segments
        self.finalOffset = offset
    }

    /// The expression, applied to a column holding an ISO-8601 UTC timestamp.
    func sql(column: String) -> String {
        let offsetSQL: String
        if segments.isEmpty {
            offsetSQL = "\(finalOffset)"
        } else {
            let branches = segments.map { segment in
                "WHEN \(column) < '\(Timestamps.text(from: segment.until))'"
                    + " THEN \(segment.offsetSeconds)"
            }
            offsetSQL = "CASE \(branches.joined(separator: " ")) ELSE \(finalOffset) END"
        }
        return """
            ((CAST(strftime('%s', \(column)) AS INTEGER) \
            + (\(offsetSQL)) + \(Self.bias)) / 86400)
            """
    }

    /// The same mapping computed in Swift, so a test can check the two agree
    /// without reimplementing either.
    ///
    /// Static because it depends on nothing but the instant and the zone: the
    /// segments exist to move this arithmetic into SQL, not to change it.
    public static func day(for date: Date, timeZone: TimeZone) -> Int {
        let seconds = Int(date.timeIntervalSince1970.rounded(.down))
        return (seconds + timeZone.secondsFromGMT(for: date) + bias) / 86400
    }

    public func day(for date: Date, timeZone: TimeZone) -> Int {
        Self.day(for: date, timeZone: timeZone)
    }

    /// The start of a local day, from the index ``day(for:timeZone:)`` gives.
    ///
    /// Resolved via midday rather than midnight. On the morning the clocks go
    /// forward some zones have no 00:00 at all, and asking a calendar for a
    /// time that never happened gets either the wrong hour or nothing; midday
    /// is eleven hours from any transition, so one correction lands it.
    public static func date(forDay day: Int, timeZone: TimeZone) -> Date {
        let naiveMidday = Double(day) * 86400 - Double(bias) + 43200
        let approximate = Date(timeIntervalSince1970: naiveMidday)
        let midday = Date(
            timeIntervalSince1970: naiveMidday
                - Double(timeZone.secondsFromGMT(for: approximate))
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.startOfDay(for: midday)
    }
}

extension IngestStore {
    /// One type over a set of local-time columns.
    ///
    /// Aggregation happens in SQLite rather than by loading rows and reducing
    /// them in Swift. A year of stand hours is 8,760 rows and 2022 alone is
    /// 58,910; carrying those across an actor boundary to add them up makes a
    /// chart that stutters on exactly the person whose archive is worth looking
    /// at.
    public func series(
        type: String,
        plan: TimeBucketPlan
    ) throws -> TypeSeries {
        let measure = try measure(for: type)
        guard let span = plan.span, !plan.columns.isEmpty else {
            return TypeSeries(
                measure: measure,
                columns: [],
                granularity: plan.granularity,
                units: [],
                coverage: SeriesCoverage(
                    daysWithData: 0,
                    dayCount: 0,
                    firstSample: nil,
                    lastSample: nil
                )
            )
        }

        let timeZone = plan.calendar.timeZone
        let localDay = LocalDayExpression(
            timeZone: timeZone,
            from: span.start,
            to: span.end
        )
        let dayExpression = localDay.sql(column: "s.start_date")

        // Only the values that count towards this measure contribute. A sleep
        // sample marked awake is not sleep, and a stand hour marked idle is the
        // opposite of a stand hour — the first version of this chart added them
        // up and drew the inverse of the ring.
        let counted: String
        if measure.countedValues.isEmpty {
            counted = "1"
        } else {
            let list = measure.countedValues.sorted().map(String.init).joined(separator: ", ")
            counted = "(CASE WHEN CAST(s.value AS INTEGER) IN (\(list)) THEN 1 ELSE 0 END)"
        }

        // A stored row can stand for many measurements. The encoder carries how
        // many on the sample, and the average has to be weighted by it or a
        // single reading outvotes an hour of them.
        let readings = "COALESCE(json_extract(CAST(s.raw AS TEXT), '$.quantity.count'), 1)"

        // A stretch of time belongs to the bucket it *ended* in — a night
        // beginning at 23:30 is the next morning's, which is what the phone's
        // chart and the Markdown export both say. Everything else is filed on
        // the moment it was taken. Counts and durations must use the same
        // column or a night lands in one bucket while its records land in the
        // one before.
        let bucketColumn = measure.kind == .duration
            ? "COALESCE(s.end_date, s.start_date)"
            : "s.start_date"

        let values = plan.columns.map { column in
            "(\(column.index),"
                + "'\(Timestamps.text(from: column.start))',"
                + "'\(Timestamps.text(from: column.end))')"
        }.joined(separator: ",")

        let sql = """
            WITH b(idx, lo, hi) AS (VALUES \(values))
            SELECT b.idx,
                   COUNT(*),
                   SUM(\(counted)),
                   SUM(CASE WHEN s.value IS NULL THEN 0
                            ELSE s.value * \(counted) END),
                   SUM(CASE WHEN s.value IS NULL THEN 0
                            ELSE s.value * \(readings) * \(counted) END),
                   SUM(CASE WHEN s.value IS NULL THEN 0
                            ELSE \(readings) * \(counted) END),
                   MIN(CASE WHEN \(counted) = 1 THEN s.value END),
                   MAX(CASE WHEN \(counted) = 1 THEN s.value END),
                   SUM(\(readings)),
                   COUNT(DISTINCT \(dayExpression)),
                   SUM(CASE WHEN \(counted) = 1 THEN
                            MAX(0.0, (julianday(s.end_date)
                                      - julianday(s.start_date)) * 86400.0)
                       ELSE 0 END)
              FROM b JOIN sample s
                ON s.type = ?
               AND \(bucketColumn) >= b.lo
               AND \(bucketColumn) < b.hi
             GROUP BY b.idx
            """

        // Mapped inside the transform rather than returning the row itself: the
        // row wraps the statement, and the statement is finalised as soon as
        // the query returns. Holding one past that reads freed memory.
        let fetched = try database.query(sql, [.text(type)]) { row in
            (
                index: Int(row.integer(0)),
                samples: Int(row.integer(1)),
                counted: Int(row.optionalReal(2) ?? 0),
                total: row.optionalReal(3) ?? 0,
                weightedSum: row.optionalReal(4) ?? 0,
                weight: row.optionalReal(5) ?? 0,
                minimum: row.optionalReal(6),
                maximum: row.optionalReal(7),
                readings: Int(row.optionalReal(8) ?? 0),
                days: Int(row.integer(9)),
                duration: row.optionalReal(10) ?? 0
            )
        }
        let rows = Dictionary(
            uniqueKeysWithValues: fetched.map { ($0.index, $0) }
        )

        // A duration category is the one shape SQL cannot answer.
        //
        // Two devices readily describe the same night — a watch and a phone
        // both wrote sleep here — and `SUM(end - start)` counts their shared
        // hours twice, reporting a night that never happened. Worse, it errs
        // generously, so it reads as a good night rather than as a fault. The
        // union has to be taken over the stretches themselves, which SQL has
        // no way to express, so the rows are read and merged here instead.
        //
        // Filed on the end, not the start: a night beginning at 23:30 belongs
        // to the morning the sleeper woke up, which is what both the phone's
        // chart and the Markdown export already say.
        let mergedDurations = measure.kind == .duration
            ? try durationSeconds(type: type, plan: plan, measure: measure)
            : [:]

        let columns = plan.columns.map { column in
            let row = rows[column.index]
            return SeriesColumn(
                index: column.index,
                start: column.start,
                end: column.end,
                total: row?.total ?? 0,
                weightedSum: row?.weightedSum ?? 0,
                weight: row?.weight ?? 0,
                minimum: row?.minimum,
                maximum: row?.maximum,
                sampleCount: row?.samples ?? 0,
                countedCount: row?.counted ?? 0,
                readingCount: row?.readings ?? 0,
                daysWithData: row?.days ?? 0,
                dayCount: column.dayCount(in: plan.calendar),
                durationSeconds: measure.kind == .duration
                    ? (((mergedDurations[column.index] ?? 0) * 1000).rounded()) / 1000
                    : (((row?.duration ?? 0) * 1000).rounded()) / 1000
            )
        }

        let units = try database.query(
            """
            SELECT DISTINCT unit FROM sample
             WHERE type = ? AND start_date >= ? AND start_date < ?
               AND unit IS NOT NULL AND unit <> ''
             ORDER BY unit
            """,
            [
                .text(type),
                .text(Timestamps.text(from: span.start)),
                .text(Timestamps.text(from: span.end))
            ],
            row: { $0.text(0) }
        )

        let bounds = try database.query(
            """
            SELECT MIN(start_date), MAX(start_date) FROM sample
             WHERE type = ? AND start_date >= ? AND start_date < ?
            """,
            [
                .text(type),
                .text(Timestamps.text(from: span.start)),
                .text(Timestamps.text(from: span.end))
            ],
            row: { ($0.optionalText(0), $0.optionalText(1)) }
        ).first ?? (nil, nil)

        return TypeSeries(
            measure: measure,
            columns: columns,
            granularity: plan.granularity,
            units: units,
            coverage: SeriesCoverage(
                daysWithData: columns.reduce(0) { $0 + $1.daysWithData },
                dayCount: columns.reduce(0) { $0 + $1.dayCount },
                firstSample: bounds.0.flatMap(Timestamps.date(from:)),
                lastSample: bounds.1.flatMap(Timestamps.date(from:))
            )
        )
    }

    /// How a type should be read, using the unit its samples are actually in.
    public func measure(for type: String) throws -> HealthMeasure {
        let unit = try database.query(
            """
            SELECT unit FROM sample
             WHERE type = ? AND unit IS NOT NULL AND unit <> ''
             LIMIT 1
            """,
            [.text(type)],
            row: { $0.optionalText(0) }
        ).first ?? nil
        return HealthMeasure.measure(for: type, storedUnit: unit)
    }

    /// Every type's measure in one pass, for a dashboard that needs them all.
    public func measures() throws -> [String: HealthMeasure] {
        let rows = try database.query(
            """
            SELECT type, MIN(unit) FROM sample
             WHERE unit IS NOT NULL AND unit <> ''
             GROUP BY type
            """,
            row: { ($0.text(0), $0.optionalText(1)) }
        )
        var byType = Dictionary(
            uniqueKeysWithValues: rows.map {
                ($0.0, HealthMeasure.measure(for: $0.0, storedUnit: $0.1))
            }
        )
        // Category types carry no unit and so never appear above, but they are
        // exactly the types whose measure matters most to get right.
        for type in try database.query(
            "SELECT DISTINCT type FROM sample",
            row: { $0.text(0) }
        ) where byType[type] == nil {
            byType[type] = HealthMeasure.measure(for: type, storedUnit: nil)
        }
        return byType
    }

    /// Seconds per bucket for a category whose value is a stretch of time.
    ///
    /// Reads the stretches rather than summing them in SQL, because the answer
    /// is the union of overlapping records and SQL cannot express that. Each
    /// merged stretch is then filed under the bucket its *end* falls in — the
    /// day the sleeper woke up.
    ///
    /// Merging happens across the whole range before anything is filed. Two
    /// records of one night can end either side of a bucket boundary, so
    /// merging within a bucket afterwards would never compare them and would
    /// count their shared hours twice, which is the bug this replaces.
    private func durationSeconds(
        type: String,
        plan: TimeBucketPlan,
        measure: HealthMeasure
    ) throws -> [Int: Double] {
        guard let first = plan.columns.first, let last = plan.columns.last else {
            return [:]
        }
        // A stretch that starts before the window can still end inside it, and
        // it is the end that decides where it is filed.
        let lower = first.start.addingTimeInterval(-Self.longestPlausibleStretch)

        var sql = """
            SELECT s.start_date, s.end_date, s.value
              FROM sample s
             WHERE s.type = ? AND s.start_date >= ? AND s.start_date < ?
               AND s.end_date IS NOT NULL
            """
        var parameters: [SQLiteValue] = [
            .text(type),
            .text(Timestamps.text(from: lower)),
            .text(Timestamps.text(from: last.end))
        ]
        if !measure.countedValues.isEmpty {
            let list = measure.countedValues.sorted()
                .map(String.init).joined(separator: ", ")
            sql += " AND CAST(s.value AS INTEGER) IN (\(list))"
        }
        _ = parameters

        let stretches: [DateInterval] = try database.query(sql, parameters) { row in
            guard
                let start = Timestamps.date(from: row.text(0)),
                let end = Timestamps.date(from: row.text(1)),
                end > start
            else {
                return nil
            }
            return DateInterval(start: start, end: end)
        }.compactMap { $0 }

        var seconds: [Int: Double] = [:]
        for stretch in TimeUnion.merge(stretches) {
            guard let column = plan.columns.first(where: {
                stretch.end > $0.start && stretch.end <= $0.end
            }) else {
                continue
            }
            seconds[column.index, default: 0] += stretch.duration
        }
        return seconds
    }

    /// How far before the window to look for a stretch that ends inside it.
    ///
    /// Sleep is the only duration category with a meaningful length, and two
    /// days is far longer than any single stretch Health records. Reading from
    /// the beginning of time instead would make every chart scan the archive.
    private static let longestPlausibleStretch: TimeInterval = 2 * 24 * 3_600
}
