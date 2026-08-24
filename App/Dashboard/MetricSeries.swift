import Foundation

/// The pieces a chart is built from, kept free of HealthKit so the arithmetic
/// can be checked against numbers worked out by hand rather than through a
/// query only a device can answer.
///
/// Two rules run through all of it.
///
/// The first is that a bucket boundary is half-open. A reading at exactly
/// midnight belongs to the day beginning, not to the one that just ended, and
/// it belongs to exactly one of them. `DateInterval.contains(_:)` is inclusive
/// at both ends and would file such a reading twice, so it is not used here.
///
/// The second is that nothing is invented to fill a gap. A bucket nothing
/// arrived for carries `nil`, never zero. Zero is a real measurement — no
/// steps at all — and a day the phone was in a drawer is not that.

// MARK: - How values may be combined

/// How a type's values may honestly be reduced to one number.
///
/// This is not a matter of taste. A cumulative quantity accumulates over its
/// sample's span, so its samples add; a measured one is a reading of something
/// that was always there, so its samples average and adding them produces an
/// authoritative-looking figure that means nothing at all. Three hundred heart
/// rates summed is not a heart rate.
enum MetricAggregation: String, Equatable, Sendable {
    /// Values add: steps, active energy, distance.
    case total
    /// Values average: heart rate, body mass, blood oxygen.
    case average
}

// MARK: - A reading

/// One sample, reduced to what a chart needs from it.
struct MetricReading: Equatable, Sendable {
    /// When the sample began. Buckets are assigned on this rather than on the
    /// end, so an evening workout is filed under the evening it started even
    /// when it runs past midnight.
    let start: Date
    let value: Double
    /// Carried per reading rather than per series so a series that mixes units
    /// can be detected instead of silently added together.
    let unit: String
    /// How many individual readings this one sample stands for.
    ///
    /// HealthKit stores some measurements as a series: one sample whose value
    /// is an aggregate over `count` readings. Weighting such a sample the same
    /// as a single measurement when averaging is wrong by however lopsided the
    /// counts are, so the count travels with the value.
    let count: Int

    init(start: Date, value: Double, unit: String, count: Int = 1) {
        self.start = start
        self.value = value
        self.unit = unit
        self.count = max(1, count)
    }
}

// MARK: - A bucket

/// One column of a chart.
struct MetricBucket: Equatable, Sendable, Identifiable {
    let interval: DateInterval
    /// The bucket's value, or `nil` when nothing arrived for it.
    ///
    /// Deliberately optional. A missing day drawn as zero is the difference
    /// between "you walked nowhere" and "Hozz has not been told", and only one
    /// of those is something a person should read off a chart.
    let value: Double?
    /// The smallest and largest values seen in this bucket.
    let minimum: Double?
    let maximum: Double?
    /// How many individual readings the value stands for, counting a series
    /// sample as the many it represents.
    let readingCount: Int
    /// How many samples arrived, counting a series sample as one.
    let sampleCount: Int

    var id: Date { interval.start }

    var hasData: Bool { value != nil }
}

// MARK: - Ranges

/// The spans a person can switch between on a detail view.
enum MetricRange: String, CaseIterable, Identifiable, Sendable {
    case week
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        }
    }

    /// How many buckets the range is drawn in, and how wide each one is.
    ///
    /// A year is drawn in months rather than in 365 days for two reasons: a
    /// year of daily bars is illegible at phone width, and asking HealthKit
    /// for twelve figures instead of three hundred and sixty-five is the
    /// difference between a chart that appears and one that stutters.
    var bucketCount: Int {
        switch self {
        case .week: 7
        case .month: 30
        case .year: 12
        }
    }

    var bucketUnit: Calendar.Component {
        switch self {
        case .week, .month: .day
        case .year: .month
        }
    }

    /// What one bucket holds, for a caption that has to name it.
    var bucketNoun: String {
        switch self {
        case .week, .month: "day"
        case .year: "month"
        }
    }

    /// The calendar unit one bucket spans.
    ///
    /// A bar drawn against a date axis has to be told this. Without it Swift
    /// Charts treats the axis as plainly continuous, has no bin width to give
    /// the bar, and draws nothing — silently, with the axes still labelled, so
    /// the chart looks merely empty rather than broken.
    var plottableUnit: Calendar.Component { bucketUnit }

    /// How to refer to the bucket in progress. "This day is still going" is
    /// not something anyone says.
    var currentBucketName: String {
        switch self {
        case .week, .month: "Today"
        case .year: "This month"
        }
    }
}

// MARK: - Building buckets

enum MetricBucketing {
    /// The buckets a range covers, oldest first, with the last one holding
    /// `now`.
    ///
    /// Every boundary is normalised to the true start of its local unit, and
    /// each bucket ends exactly where the next begins, so the chain is
    /// contiguous by construction rather than by coincidence.
    ///
    /// Both of those matter more than they look. Stepping by 86,400 seconds
    /// walks the boundary an hour off on the day a clock changes and keeps it
    /// there. But calendar arithmetic alone is not enough either: `byAdding`
    /// preserves the wall time it started from, and in a zone whose clock
    /// changes *at midnight* — Santiago in September, Havana in November,
    /// Cairo in April — local midnight either does not exist that day or
    /// exists twice, so the walk drifts to 01:00 and stays there. Computing
    /// each end independently as "start plus one unit" then leaves a real hole
    /// or a real overlap in the chain, and a reading in the hole belongs to no
    /// bucket at all: it is dropped and reported as an absence.
    ///
    /// Normalising after every step and taking each end from the next start
    /// removes both failures.
    static func buckets(
        for range: MetricRange,
        endingAt now: Date,
        calendar: Calendar
    ) -> [DateInterval] {
        let unit = range.bucketUnit
        guard let currentStart = start(of: unit, containing: now, in: calendar) else {
            return []
        }

        var starts: [Date] = [currentStart]
        var cursor = currentStart
        for _ in 1..<max(1, range.bucketCount) {
            guard
                let stepped = calendar.date(byAdding: unit, value: -1, to: cursor),
                let normalised = start(of: unit, containing: stepped, in: calendar),
                // Must move backwards. A zone whose clock change swallows the
                // boundary could otherwise normalise back onto the day just
                // recorded and repeat it forever.
                normalised < cursor
            else {
                break
            }
            starts.append(normalised)
            cursor = normalised
        }
        starts.reverse()

        // The final boundary is the only one that has to be stepped forwards;
        // every other end is simply the next start, which is what makes the
        // chain airtight.
        guard
            let afterLast = calendar.date(byAdding: unit, value: 1, to: currentStart),
            let finalEnd = start(of: unit, containing: afterLast, in: calendar),
            finalEnd > currentStart
        else {
            return []
        }

        return starts.indices.compactMap { index in
            let end = index + 1 < starts.count ? starts[index + 1] : finalEnd
            guard end > starts[index] else {
                return nil
            }
            return DateInterval(start: starts[index], end: end)
        }
    }

    private static func start(
        of unit: Calendar.Component,
        containing date: Date,
        in calendar: Calendar
    ) -> Date? {
        switch unit {
        case .day:
            return calendar.startOfDay(for: date)
        default:
            return calendar.dateInterval(of: unit, for: date)?.start
        }
    }

    /// Which bucket a date falls in, treating each bucket as half-open.
    ///
    /// Half-open is the whole point: `[start, end)` puts a reading at exactly
    /// midnight in the day that is beginning and in nothing else.
    /// `DateInterval.contains(_:)` includes both ends, which would place that
    /// reading in two adjacent buckets and count it twice.
    static func index(of date: Date, in buckets: [DateInterval]) -> Int? {
        guard let first = buckets.first, let last = buckets.last else {
            return nil
        }
        guard date >= first.start, date < last.end else {
            return nil
        }

        var low = 0
        var high = buckets.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let bucket = buckets[middle]
            if date < bucket.start {
                high = middle - 1
            } else if date >= bucket.end {
                low = middle + 1
            } else {
                return middle
            }
        }
        return nil
    }
}

// MARK: - Aggregating into buckets

/// A series ready to draw, with everything a caption needs to be truthful
/// about it.
struct MetricSeries: Equatable, Sendable {
    let buckets: [MetricBucket]
    /// The unit every value is in, or `nil` when there is nothing to show.
    let unit: String?
    let aggregation: MetricAggregation
    /// True when readings arrived in more than one unit.
    ///
    /// When this is set every value is withheld rather than converted, because
    /// this layer has no unit table and a guessed conversion is a wrong number
    /// wearing a right one's clothes.
    let hasUnitConflict: Bool
    /// True when at least one sample stood for more than one reading, so a
    /// caption can say the detail behind it is not here.
    let containsAggregatedReadings: Bool
    /// The range taken as a whole, when something that can see every
    /// individual reading has already reduced it.
    ///
    /// This exists because the mean of a set of daily means is not the mean of
    /// the readings behind them — a day holding four readings and a day
    /// holding four hundred are not equal evidence — and the buckets HealthKit
    /// returns do not say how many readings each stands for. Rather than
    /// average the averages and hope, the whole range is asked for separately
    /// and the answer carried here.
    let overall: MetricOverall?

    init(
        buckets: [MetricBucket],
        unit: String?,
        aggregation: MetricAggregation,
        hasUnitConflict: Bool,
        containsAggregatedReadings: Bool,
        overall: MetricOverall? = nil
    ) {
        self.buckets = buckets
        self.unit = unit
        self.aggregation = aggregation
        self.hasUnitConflict = hasUnitConflict
        self.containsAggregatedReadings = containsAggregatedReadings
        self.overall = overall
    }

    var hasAnyData: Bool { buckets.contains(where: \.hasData) }
}

/// A whole range reduced by something that could see every reading in it.
struct MetricOverall: Equatable, Sendable {
    let value: Double
    let minimum: Double?
    let maximum: Double?
}

enum MetricAggregator {
    /// Puts readings into buckets and reduces each one.
    ///
    /// Readings outside the buckets are dropped rather than clamped into the
    /// nearest, since a reading from before the range is not evidence about
    /// the range.
    static func aggregate(
        _ readings: [MetricReading],
        into intervals: [DateInterval],
        using aggregation: MetricAggregation
    ) -> MetricSeries {
        let units = Set(readings.map(\.unit))
        let hasConflict = units.count > 1
        let unit = hasConflict ? nil : units.first
        let hasAggregates = readings.contains { $0.count > 1 }

        guard !hasConflict else {
            // Every value is withheld, but the shape of the range is kept so
            // the view can still say what it was asked for.
            return MetricSeries(
                buckets: intervals.map(Self.emptyBucket),
                unit: nil,
                aggregation: aggregation,
                hasUnitConflict: true,
                containsAggregatedReadings: hasAggregates
            )
        }

        var grouped: [Int: [MetricReading]] = [:]
        for reading in readings {
            guard let index = MetricBucketing.index(of: reading.start, in: intervals) else {
                continue
            }
            grouped[index, default: []].append(reading)
        }

        let buckets = intervals.enumerated().map { index, interval -> MetricBucket in
            guard let inBucket = grouped[index], !inBucket.isEmpty else {
                return emptyBucket(interval)
            }
            return MetricBucket(
                interval: interval,
                value: reduce(inBucket, using: aggregation),
                minimum: inBucket.map(\.value).min(),
                maximum: inBucket.map(\.value).max(),
                readingCount: inBucket.reduce(0) { $0 + $1.count },
                sampleCount: inBucket.count
            )
        }

        return MetricSeries(
            buckets: buckets,
            unit: unit,
            aggregation: aggregation,
            hasUnitConflict: false,
            containsAggregatedReadings: hasAggregates
        )
    }

    private static func emptyBucket(_ interval: DateInterval) -> MetricBucket {
        MetricBucket(
            interval: interval,
            value: nil,
            minimum: nil,
            maximum: nil,
            readingCount: 0,
            sampleCount: 0
        )
    }

    private static func reduce(
        _ readings: [MetricReading],
        using aggregation: MetricAggregation
    ) -> Double? {
        switch aggregation {
        case .total:
            // A cumulative sample's value is already the total over its own
            // span, so the count plays no part here.
            return readings.reduce(0) { $0 + $1.value }
        case .average:
            return weightedMean(readings)
        }
    }

    /// The mean of the underlying readings, not the mean of the samples.
    ///
    /// A sample standing for three hundred readings and a single measurement
    /// are not two equal pieces of evidence about an average, and treating
    /// them as such moves the answer by however lopsided the counts are.
    static func weightedMean(_ readings: [MetricReading]) -> Double? {
        let weight = readings.reduce(0) { $0 + $1.count }
        guard weight > 0 else {
            return nil
        }
        let total = readings.reduce(0.0) { $0 + $1.value * Double($1.count) }
        return total / Double(weight)
    }
}

// MARK: - Summarising a series

/// The figures shown beside a chart.
struct MetricSummary: Equatable, Sendable {
    /// The one number for the range: a sum for a cumulative type, a mean for a
    /// measured one. `nil` when nothing arrived.
    let headline: Double?
    let aggregation: MetricAggregation
    /// The lowest and highest values seen anywhere in the range.
    let lowest: Double?
    let highest: Double?
    let bucketsWithData: Int
    let bucketsInRange: Int
    /// A cumulative type's average over the buckets that had anything.
    ///
    /// Divided by buckets *with data* rather than by buckets in range. Days
    /// nothing arrived for are not days someone scored nothing, and dividing
    /// by them reports a lower average than the person achieved.
    let averagePerActiveBucket: Double?

    var hasData: Bool { headline != nil }
}

extension MetricSeries {
    var summary: MetricSummary {
        let present = buckets.compactMap(\.value)
        let withData = buckets.filter(\.hasData)

        guard !present.isEmpty, !hasUnitConflict else {
            return MetricSummary(
                headline: nil,
                aggregation: aggregation,
                lowest: nil,
                highest: nil,
                bucketsWithData: 0,
                bucketsInRange: buckets.count,
                averagePerActiveBucket: nil
            )
        }

        let headline: Double?
        switch aggregation {
        case .total:
            // A sum of sums is the same number however it is grouped, so the
            // buckets answer this exactly and no separate reduction is needed.
            headline = present.reduce(0, +)
        case .average:
            if let overall {
                // Reduced by something that saw every reading. Preferred over
                // anything computable from the buckets.
                headline = overall.value
            } else {
                // Weighted by how many readings each bucket's figure stands
                // for. The plain mean of daily means answers a different
                // question — it treats a day with four readings as equal
                // evidence to a day with four hundred — and it is the wrong
                // answer to this one. When no bucket says how many readings it
                // holds there is nothing honest left to compute, so nothing is
                // reported rather than a mean of means dressed up as a mean.
                let weight = withData.reduce(0) { $0 + $1.readingCount }
                headline = weight > 0
                    ? withData.reduce(0.0) { $0 + ($1.value ?? 0) * Double($1.readingCount) }
                        / Double(weight)
                    : nil
            }
        }

        let averagePerActive: Double? = switch aggregation {
        case .total: present.reduce(0, +) / Double(present.count)
        case .average: nil
        }

        return MetricSummary(
            headline: headline,
            aggregation: aggregation,
            lowest: overall?.minimum ?? buckets.compactMap(\.minimum).min() ?? present.min(),
            highest: overall?.maximum ?? buckets.compactMap(\.maximum).max() ?? present.max(),
            bucketsWithData: withData.count,
            bucketsInRange: buckets.count,
            averagePerActiveBucket: averagePerActive
        )
    }
}

// MARK: - Coverage

/// How much of a range actually has data behind it.
///
/// This exists because Hozz's charts are drawn over whatever Health has
/// answered with, and that is routinely a fraction of the range asked for. A
/// month with eleven days in it, drawn as though it were a month, is the kind
/// of quiet overstatement this app is written to avoid — so the count travels
/// with the chart and the view is expected to show it.
///
/// It reports what arrived. It never claims a range is *complete*, because
/// that is not knowable: Health does not publish a total without being read in
/// full, and it does not reveal whether a type was declined rather than empty.
struct MetricCoverage: Equatable, Sendable {
    let bucketsInRange: Int
    let bucketsWithData: Int
    /// The first and last buckets that hold anything, so a view can dim the
    /// stretch before data begins instead of drawing a flat line across it.
    let firstBucketWithData: Int?
    let lastBucketWithData: Int?
    /// The final bucket has not finished yet — today is not over.
    let finalBucketIsPartial: Bool

    var isEmpty: Bool { bucketsWithData == 0 }

    /// True when data covers only part of the range, which is the case a
    /// chart must not paper over.
    var isPartial: Bool {
        bucketsWithData > 0 && bucketsWithData < bucketsInRange
    }

    /// Buckets before anything had arrived. A leading gap usually means the
    /// history simply does not go back that far, which is worth distinguishing
    /// from scattered gaps throughout.
    var leadingEmptyBuckets: Int {
        firstBucketWithData ?? bucketsInRange
    }
}

extension MetricSeries {
    func coverage(now: Date) -> MetricCoverage {
        let indices = buckets.indices.filter { buckets[$0].hasData }
        let finalPartial: Bool = {
            guard let last = buckets.last else {
                return false
            }
            return now >= last.interval.start && now < last.interval.end
        }()

        return MetricCoverage(
            bucketsInRange: buckets.count,
            bucketsWithData: indices.count,
            firstBucketWithData: indices.first,
            lastBucketWithData: indices.last,
            finalBucketIsPartial: finalPartial
        )
    }
}
