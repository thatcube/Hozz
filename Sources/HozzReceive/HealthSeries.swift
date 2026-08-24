import Foundation
import HozzCore
import HozzStore

/// One column of a chart, with everything needed to draw it honestly.
///
/// Both a total and the parts of an average are carried, because which one is
/// the right number depends on the type and neither can be recovered from the
/// other afterwards.
public struct SeriesColumn: Sendable, Hashable, Identifiable {
    public let index: Int
    public let start: Date
    public let end: Date
    /// Σ value. Meaningless unless the measure is summable.
    public let total: Double
    /// Σ (value × readings), the numerator of a reading-weighted average.
    public let weightedSum: Double
    /// Σ readings, the denominator.
    public let weight: Double
    public let minimum: Double?
    public let maximum: Double?
    /// Rows stored in this column, whatever their value.
    ///
    /// Deliberately every row and not only the ones that count towards the
    /// measure. A day the watch recorded twenty-four *idle* stand hours holds
    /// plenty of data and the honest answer is "0 stand hours"; counting only
    /// the stood ones would make that day identical to one the watch was never
    /// worn, and it is exactly the day worth seeing.
    public let sampleCount: Int
    /// Rows that count towards the measure — stand hours actually stood, sleep
    /// samples actually asleep. Equal to `sampleCount` for every type whose
    /// value is a measurement rather than an enumeration.
    public let countedCount: Int
    /// Measurements those rows stand for. Equal to `sampleCount` unless the
    /// phone sent aggregated series samples.
    public let readingCount: Int
    /// Local calendar days inside this column that hold at least one sample.
    ///
    /// Any sample, not only a counted one, for the same reason `sampleCount`
    /// is: coverage answers "did anything arrive that day", and a day of
    /// readings that all happen to be zeroes is a day that arrived.
    public let daysWithData: Int
    /// Local calendar days this column spans.
    public let dayCount: Int
    /// Seconds covered by the samples that count towards a duration measure.
    public let durationSeconds: Double

    public var id: Int { index }

    public init(
        index: Int,
        start: Date,
        end: Date,
        total: Double,
        weightedSum: Double,
        weight: Double,
        minimum: Double?,
        maximum: Double?,
        sampleCount: Int,
        countedCount: Int,
        readingCount: Int,
        daysWithData: Int,
        dayCount: Int,
        durationSeconds: Double
    ) {
        self.index = index
        self.start = start
        self.end = end
        self.total = total
        self.weightedSum = weightedSum
        self.weight = weight
        self.minimum = minimum
        self.maximum = maximum
        self.sampleCount = sampleCount
        self.countedCount = countedCount
        self.readingCount = readingCount
        self.daysWithData = daysWithData
        self.dayCount = dayCount
        self.durationSeconds = durationSeconds
    }

    /// The reading-weighted mean.
    ///
    /// Weighted, not plain, because one stored row can stand for three hundred
    /// measurements. Health sends a series as a single sample carrying the
    /// average of its readings and the number of them, so treating that row as
    /// one observation lets a quiet minute outvote an hour of noise.
    public var average: Double? {
        weight > 0 ? weightedSum / weight : nil
    }

    /// Whether every local day in this column has something in it.
    ///
    /// Deliberately about days rather than about completeness. This computer
    /// cannot know how much data exists on the phone, so it never claims a
    /// column is complete — only that data arrived on every day it covers.
    public var hasEveryDay: Bool {
        dayCount > 0 && daysWithData >= dayCount
    }

    public var isEmpty: Bool { sampleCount == 0 }
}

/// How much of a range actually has data in it.
///
/// Not a fraction of what exists — this computer has no way to know that, and a
/// denominator invented here would be a guess wearing a measurement's clothes.
/// It is a fraction of the days the chart is drawing.
public struct SeriesCoverage: Sendable, Hashable {
    public let daysWithData: Int
    public let dayCount: Int
    public let firstSample: Date?
    public let lastSample: Date?

    public init(
        daysWithData: Int,
        dayCount: Int,
        firstSample: Date?,
        lastSample: Date?
    ) {
        self.daysWithData = daysWithData
        self.dayCount = dayCount
        self.firstSample = firstSample
        self.lastSample = lastSample
    }

    public var fraction: Double {
        dayCount > 0 ? Double(daysWithData) / Double(dayCount) : 0
    }

    public var isEveryDay: Bool {
        dayCount > 0 && daysWithData >= dayCount
    }

    /// What to tell someone, in words they can act on.
    ///
    /// A sparse recent month and a dense old one are both normal while a phone
    /// works back through years of history, so the wording describes what
    /// arrived rather than warning about what has not.
    public var sentence: String {
        guard dayCount > 0 else {
            return "Nothing in this range yet."
        }
        if daysWithData == 0 {
            return "No days in this range have data yet."
        }
        if isEveryDay {
            return "Every one of these \(dayCount) days has data."
        }
        return "\(daysWithData) of \(dayCount) days have data so far."
    }
}

/// One type, over time, ready to draw.
public struct TypeSeries: Sendable, Hashable {
    public let measure: HealthMeasure
    public let columns: [SeriesColumn]
    public let granularity: ChartGranularity
    /// Distinct units the stored samples are in.
    ///
    /// More than one means the values must not be added or averaged together:
    /// a gram and a kilogram are both numbers and their sum is neither.
    public let units: [String]
    public let coverage: SeriesCoverage

    public init(
        measure: HealthMeasure,
        columns: [SeriesColumn],
        granularity: ChartGranularity,
        units: [String],
        coverage: SeriesCoverage
    ) {
        self.measure = measure
        self.columns = columns
        self.granularity = granularity
        self.units = units
        self.coverage = coverage
    }

    /// Whether the samples are in units that cannot be combined.
    public var hasMixedUnits: Bool { units.count > 1 }

    /// The number to draw for a column, or `nil` when there is none.
    ///
    /// Returns `nil` for every column when the range mixes units, because there
    /// is no honest single value to draw and a chart drawn anyway would be the
    /// most confident lie in the app.
    public func value(_ column: SeriesColumn) -> Double? {
        guard !hasMixedUnits else { return nil }
        guard !column.isEmpty else { return nil }
        switch measure.kind {
        case .total:
            // `weight` is zero only when nothing in the column carried a
            // number, which is different from carrying zero.
            return column.weight > 0 ? column.total : nil
        case .average:
            return column.average
        case .duration:
            // Zero is a real answer here. A night recorded entirely as awake
            // is nought minutes asleep, and drawing a gap instead would hide
            // the most interesting night of the month.
            return column.durationSeconds
        case .occurrences:
            return Double(column.countedCount)
        }
    }

    public var values: [Double] {
        columns.compactMap { value($0) }
    }

    /// The unit to draw in, chosen from how large the drawn values actually are.
    public var displayUnit: DisplayUnit {
        let drawn = values.map(abs)
        // The median rather than the maximum: one outlying day should not push a
        // whole year of metres into kilometres and flatten every other column
        // into a rounding error.
        let magnitude: Double
        if drawn.isEmpty {
            magnitude = 0
        } else {
            let sorted = drawn.sorted()
            magnitude = sorted[sorted.count / 2]
        }
        return measure.displayUnit(forMagnitude: magnitude)
    }

    /// The one number that summarises the whole range for this type.
    ///
    /// A total for something cumulative, a weighted average for something
    /// measured. Never a total of something measured.
    public var headline: Double? {
        guard !hasMixedUnits else { return nil }
        switch measure.kind {
        case .total:
            guard columns.contains(where: { $0.weight > 0 }) else { return nil }
            return columns.reduce(0) { $0 + $1.total }
        case .average:
            let weight = columns.reduce(0) { $0 + $1.weight }
            guard weight > 0 else { return nil }
            return columns.reduce(0) { $0 + $1.weightedSum } / weight
        case .duration:
            let populated = columns.filter { !$0.isEmpty }
            return populated.isEmpty
                ? nil
                : populated.reduce(0) { $0 + $1.durationSeconds }
        case .occurrences:
            let populated = columns.filter { !$0.isEmpty }
            return populated.isEmpty
                ? nil
                : Double(populated.reduce(0) { $0 + $1.countedCount })
        }
    }

    /// The lowest and highest single readings seen in the range.
    public var extremes: (minimum: Double, maximum: Double)? {
        let lows = columns.compactMap(\.minimum)
        let highs = columns.compactMap(\.maximum)
        guard let low = lows.min(), let high = highs.max() else {
            return nil
        }
        return (low, high)
    }

    /// Rows stored across the range.
    public var sampleCount: Int {
        columns.reduce(0) { $0 + $1.sampleCount }
    }

    /// Measurements those rows stand for.
    public var readingCount: Int {
        columns.reduce(0) { $0 + $1.readingCount }
    }

    /// Whether any stored row stands for more than one measurement.
    public var hasAggregatedSamples: Bool {
        readingCount > sampleCount
    }
}
