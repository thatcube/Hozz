import Foundation
import HozzCore
import HozzStore

extension IngestStore {
    /// Time actually covered by a type's records, per column.
    ///
    /// Not the sum of their durations. Sleep arrives as separate records, and
    /// two devices describing one night each write one — a watch and a phone,
    /// or a watch and a third-party app — so adding them reports that night
    /// twice. The result looks like an unusually good night's sleep rather
    /// than like an error, which is the worst way for a number to be wrong.
    ///
    /// ``TimeUnion`` is the rule, shared with the Markdown export rather than
    /// reimplemented here. Two implementations of one rule is exactly how the
    /// day-boundary bug happened: they agreed until they did not, and nothing
    /// said which was right.
    ///
    /// A record belongs to the column its *start* falls in, which is the
    /// attribution the export uses, so a night beginning at eleven is that
    /// night's sleep rather than being split across two days.
    func unionedSeconds(
        type: String,
        measure: HealthMeasure,
        plan: TimeBucketPlan
    ) throws -> [Int: Double] {
        guard let span = plan.span else {
            return [:]
        }

        var predicate = ""
        if !measure.countedValues.isEmpty {
            let list = measure.countedValues
                .sorted()
                .map(String.init)
                .joined(separator: ", ")
            predicate = " AND CAST(value AS INTEGER) IN (\(list))"
        }

        let rows = try database.query(
            """
            SELECT start_date, end_date FROM sample
             WHERE type = ? AND start_date >= ? AND start_date < ?\(predicate)
             ORDER BY start_date
            """,
            [
                .text(type),
                .text(Timestamps.text(from: span.start)),
                .text(Timestamps.text(from: span.end))
            ],
            row: { ($0.text(0), $0.optionalText(1)) }
        )

        var byColumn: [Int: [DateInterval]] = [:]
        for row in rows {
            guard let start = Timestamps.date(from: row.0),
                  let index = plan.index(for: start) else {
                continue
            }
            // A record with no end, or one ending before it began, covers no
            // time. Counted, but contributing nothing — which is different
            // from being dropped, and the sample count still shows it.
            guard let endText = row.1,
                  let end = Timestamps.date(from: endText),
                  end > start else {
                continue
            }
            byColumn[index, default: []].append(
                DateInterval(start: start, end: end)
            )
        }

        return byColumn.mapValues { TimeUnion.seconds(of: $0) }
    }
}
