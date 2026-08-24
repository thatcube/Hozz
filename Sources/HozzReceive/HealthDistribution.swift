import Foundation
import HozzCore
import HozzStore

/// One bar of a histogram: a value band and how many readings fell in it.
public struct DistributionBucket: Sendable, Hashable, Identifiable {
    public let index: Int
    public let lowerBound: Double
    public let upperBound: Double
    public let count: Int

    public var id: Int { index }

    public var midpoint: Double { (lowerBound + upperBound) / 2 }

    public init(index: Int, lowerBound: Double, upperBound: Double, count: Int) {
        self.index = index
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.count = count
    }
}

extension IngestStore {
    /// Where a type's individual readings actually sit.
    ///
    /// Drawn from the readings rather than from the daily figures, because a
    /// column chart of daily averages hides the shape entirely: a person whose
    /// heart rate is 55 asleep and 150 running has a daily average of about 70
    /// and spends almost no time there.
    ///
    /// A sample that stands for many readings contributes that many when its
    /// value is their mean, for the same reason its average is weighted —
    /// otherwise an hour compressed into one row counts once against a single
    /// spot measurement.
    public func distribution(
        type: String,
        from start: Date,
        to end: Date,
        buckets: Int = 24
    ) throws -> [DistributionBucket] {
        guard buckets > 0, end > start else {
            return []
        }
        let measure = try measure(for: type)
        // A category type's value is an enumeration. A histogram of the numbers
        // 0 to 5 is a picture of an encoding, not of a person.
        guard measure.kind == .total || measure.kind == .average else {
            return []
        }

        // A row standing for many readings contributes that many — but only
        // when its value is their *mean*. A cumulative series sample already
        // holds the sum over its readings, so a single 1,000 m cycling row
        // covering 132 of them is one occurrence of 1,000 m, not 132. Weighting
        // it would inflate the bar by roughly the length of the series, which
        // is the same mistake `series()` is careful not to make.
        let weight = measure.kind == .average
            ? "COALESCE(json_extract(CAST(raw AS TEXT), '$.quantity.count'), 1)"
            : "1"

        let parameters: [SQLiteValue] = [
            .text(type),
            .text(Timestamps.text(from: start)),
            .text(Timestamps.text(from: end))
        ]

        let bounds = try database.query(
            """
            SELECT MIN(value), MAX(value), COUNT(DISTINCT unit)
              FROM sample
             WHERE type = ? AND start_date >= ? AND start_date < ?
               AND value IS NOT NULL
            """,
            parameters,
            row: { ($0.optionalReal(0), $0.optionalReal(1), Int($0.integer(2))) }
        ).first ?? (nil, nil, 0)

        guard let low = bounds.0, let high = bounds.1, bounds.2 <= 1 else {
            return []
        }

        // Every reading identical: one band, rather than a division by zero or
        // twenty-four empty bars either side of a spike.
        guard high > low else {
            let count = try database.query(
                """
                SELECT SUM(\(weight))
                  FROM sample
                 WHERE type = ? AND start_date >= ? AND start_date < ?
                   AND value IS NOT NULL
                """,
                parameters,
                row: { Int($0.optionalReal(0) ?? 0) }
            ).first ?? 0
            return count == 0
                ? []
                : [DistributionBucket(
                    index: 0,
                    lowerBound: low,
                    upperBound: high,
                    count: count
                )]
        }

        let width = (high - low) / Double(buckets)
        let rows = try database.query(
            """
            SELECT MIN(CAST((value - ?) / ? AS INTEGER), ?),
                   SUM(\(weight))
              FROM sample
             WHERE type = ? AND start_date >= ? AND start_date < ?
               AND value IS NOT NULL
             GROUP BY 1
             ORDER BY 1
            """,
            [
                .real(low),
                .real(width),
                .integer(Int64(buckets - 1)),
                .text(type),
                .text(Timestamps.text(from: start)),
                .text(Timestamps.text(from: end))
            ],
            row: { (Int($0.integer(0)), Int($0.optionalReal(1) ?? 0)) }
        )
        let byIndex = Dictionary(uniqueKeysWithValues: rows)

        return (0..<buckets).map { index in
            DistributionBucket(
                index: index,
                lowerBound: low + width * Double(index),
                upperBound: low + width * Double(index + 1),
                count: byIndex[index] ?? 0
            )
        }
    }
}
