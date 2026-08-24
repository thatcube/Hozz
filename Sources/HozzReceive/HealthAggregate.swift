import Foundation
import HozzCore
import HozzStore

extension IngestStore {
    /// Aggregation over local-time buckets, shared by the MCP tools and the
    /// Mac dashboards.
    ///
    /// The statistics themselves are deliberately unchanged from the version
    /// this replaces — a plain `SUM`, `AVG`, `MIN`, `MAX` and row count over
    /// `value`. Only where a bucket begins is different. Changing the numbers
    /// and the boundaries in one step would make it impossible to tell which
    /// change moved a figure somebody had already read.
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

        let values = plan.columns.map { column in
            "(\(column.index),"
                + "'\(Timestamps.text(from: column.start))',"
                + "'\(Timestamps.text(from: column.end))')"
        }.joined(separator: ",")

        // The caller's own bounds are still applied inside the join, so a range
        // starting mid-day reports only that day's later samples even though
        // the bucket it falls in begins at midnight.
        let rows = try database.query(
            """
            WITH b(idx, lo, hi) AS (VALUES \(values))
            SELECT b.idx, SUM(s.value), AVG(s.value),
                   MIN(s.value), MAX(s.value), COUNT(*)
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
                count: Int(row.integer(5))
            )
        }

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
            return AggregateBucket(
                start: start,
                sum: row.sum,
                average: row.average,
                minimum: row.minimum,
                maximum: row.maximum,
                count: row.count
            )
        }
    }
}
