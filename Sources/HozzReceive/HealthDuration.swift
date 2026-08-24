import Foundation
import HozzCore
import HozzStore

extension IngestStore {
    /// Seconds per bucket for a category whose value is a stretch of time.
    ///
    /// One implementation, read by the Mac dashboards and by the MCP tool,
    /// because the alternative is what this codebase keeps finding: two copies
    /// of one rule that agree until they do not, and nothing to say which is
    /// right. The phone's chart and the Markdown export share `SleepIntervals`
    /// for the same reason; that type cannot be called from here because it
    /// works on HealthKit samples and builds for iOS, so what is shared is the
    /// rule in ``TimeUnion`` and, deliberately, the behaviour below.
    ///
    /// Reads the stretches rather than summing them in SQL, because the answer
    /// is the union of overlapping records and SQL cannot express that. Each
    /// merged stretch is then filed under the bucket its *end* falls in — the
    /// day the sleeper woke up. A night begun at 23:30 is the next morning's:
    /// filing on the start puts a 7pm nap under tomorrow, a day nobody was
    /// asleep, and files a night begun at 17:30 under yesterday.
    ///
    /// Merging happens across the whole range before anything is filed. Two
    /// records of one night can end either side of a bucket boundary, so
    /// merging within a bucket afterwards would never compare them and would
    /// count their shared hours twice.
    func durationSeconds(
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
    static let longestPlausibleStretch: TimeInterval = 2 * 24 * 3_600
}
