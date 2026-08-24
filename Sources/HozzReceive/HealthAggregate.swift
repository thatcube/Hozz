import Foundation
import HozzCore
import HozzStore

extension IngestStore {
    /// Aggregation over local-time buckets, shared by the MCP tools and the
    /// Mac dashboards.
    ///
    /// For a quantity type the statistics are a plain `SUM`, `AVG`, `MIN`,
    /// `MAX` and row count over `value`, exactly as they have always been.
    ///
    /// A category type is different, because its stored value is an
    /// enumeration case rather than a measurement.
    /// `HKCategoryValueAppleStandHour` is 0 for *stood* and 1 for *idle*, so
    /// the sum of a day's values is the number of hours somebody sat down —
    /// and an assistant reading "sum: 10" for a stand-hour type will say "you
    /// stood for ten hours", which is precisely inverted. There is no
    /// meaningful sum of enumeration cases at all, so these report the thing
    /// the type actually means: hours stood, or minutes asleep.
    ///
    /// Boundaries come from ``TimeBucketPlan``, which builds them with a
    /// `Calendar`. That is what makes a 23-hour and a 25-hour day come out as
    /// one day each, and it is the same code the dashboard charts are drawn
    /// from, so a total here and a column there can never disagree about which
    /// Tuesday a sample was on.
    func localAggregate(
        type: String,
        bucket: BucketSize,
        from start: Date?,
        to end: Date?,
        timeZone: TimeZone
    ) throws -> [AggregateBucket] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // Without explicit bounds the range is the type's own extent, so the
        // caller still gets everything held rather than an arbitrary window.
        let extent = try database.query(
            """
            SELECT MIN(start_date), MAX(start_date) FROM sample
             WHERE type = ? AND value IS NOT NULL
            """,
            [.text(type)],
            row: { ($0.optionalText(0), $0.optionalText(1)) }
        ).first ?? (nil, nil)

        guard
            let earliest = extent.0.flatMap(Timestamps.date(from:)),
            let latest = extent.1.flatMap(Timestamps.date(from:))
        else {
            return []
        }

        let lower = max(start ?? earliest, earliest)
        // `latest` is an instant inside the final bucket, so the range has to
        // reach past it: a half-open interval ending exactly on the last
        // sample would drop that sample.
        let requestedUpper = end ?? latest
        let upper = min(requestedUpper, latest)
        guard upper >= lower else {
            return []
        }
        guard let exclusiveEnd = calendar.date(
            byAdding: bucket.granularity.component,
            value: 1,
            to: TimeBucketPlan.align(
                upper,
                to: bucket.granularity,
                calendar: calendar
            )
        ) else {
            return []
        }

        let plan = TimeBucketPlan.covering(
            from: lower,
            to: exclusiveEnd,
            granularity: bucket.granularity,
            calendar: calendar
        )
        guard !plan.columns.isEmpty else {
            return []
        }

        let measure = try measure(for: type)
        let values = plan.columns.map { column in
            "(\(column.index),"
                + "'\(Timestamps.text(from: column.start))',"
                + "'\(Timestamps.text(from: column.end))')"
        }.joined(separator: ",")

        // Only the cases that count towards the measure. A sleep sample marked
        // awake is not sleep, and a stand hour marked idle is the opposite of
        // one. Empty for every quantity type, where every row counts.
        let counted: String
        if measure.countedValues.isEmpty {
            counted = "1"
        } else {
            let list = measure.countedValues.sorted().map(String.init).joined(separator: ", ")
            counted = "(CASE WHEN CAST(s.value AS INTEGER) IN (\(list)) THEN 1 ELSE 0 END)"
        }

        // The caller's own bounds are still applied inside the join, so a range
        // starting mid-day reports only that day's later samples even though
        // the bucket it falls in begins at midnight.
        let rows = try database.query(
            """
            WITH b(idx, lo, hi) AS (VALUES \(values))
            SELECT b.idx, SUM(s.value), AVG(s.value),
                   MIN(s.value), MAX(s.value), COUNT(*),
                   SUM(\(counted))
              FROM b JOIN sample s
                ON s.type = ?
               AND s.start_date >= b.lo
               AND s.start_date < b.hi
               AND s.start_date >= ?
               AND s.start_date <= ?
             WHERE s.value IS NOT NULL
             GROUP BY b.idx
             ORDER BY b.idx
            """,
            [
                .text(type),
                .text(Timestamps.text(from: lower)),
                .text(Timestamps.text(from: requestedUpper))
            ]
        ) { row in
            (
                index: Int(row.integer(0)),
                sum: row.real(1),
                average: row.real(2),
                minimum: row.real(3),
                maximum: row.real(4),
                count: Int(row.integer(5)),
                counted: Int(row.optionalReal(6) ?? 0)
            )
        }

        // Time covered, not durations added. Only a duration measure needs it,
        // and those types are inherently low-volume — a handful of records a
        // night — so the rows are read rather than summed in SQL.
        let unioned = measure.kind == .duration
            ? try unionedSeconds(type: type, measure: measure, plan: plan)
            : [:]

        let starts = Dictionary(
            uniqueKeysWithValues: plan.columns.map { ($0.index, $0.start) }
        )

        // Only buckets that hold something, matching what a `GROUP BY` gave
        // before: a run of empty days is not news, and inventing zero-valued
        // buckets would turn "the watch was not worn" into "no steps taken".
        return rows.compactMap { row in
            guard let start = starts[row.index], row.count > 0 else {
                return nil
            }
            let meaningful: Double = switch measure.kind {
            case .total: row.sum
            case .average: row.average
            // Rounded to the millisecond. Floating-point arithmetic over
            // instants carries a few microseconds of noise, which is invisible
            // in seconds and turns "120" minutes into "120.00" the moment
            // anyone formats it — a number that looks measured to a precision
            // nobody has.
            case .duration: ((unioned[row.index] ?? 0) * 1000).rounded() / 1000
            case .occurrences: Double(row.counted)
            }
            return AggregateBucket(
                start: start,
                sum: row.sum,
                average: row.average,
                minimum: row.minimum,
                maximum: row.maximum,
                count: row.count,
                kind: measure.kind,
                value: meaningful
            )
        }
    }
}
