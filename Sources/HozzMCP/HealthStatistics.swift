import Foundation

/// The statistics behind the analysis tools, kept separate from the server so
/// they can be tested against known numbers rather than through a database.
///
/// Every function here is built around one idea: the output goes straight to a
/// language model, which will narrate a confident story around any number it is
/// given. A slope with no uncertainty attached becomes "your heart rate is
/// climbing". A correlation over three weeks of autocorrelated daily data
/// becomes "your sleep drives your step count". Neither is supportable, and a
/// health app asserting them is not merely unhelpful — it is the kind of
/// confident wrongness someone might act on.
///
/// So the rule is that these return *whether a claim is supportable* alongside
/// the number, and the phrasing at the call site is required to respect it.
enum HealthStatistics {
    /// Below this many days, a line fitted through daily values describes the
    /// noise rather than any trend. Nine days of resting heart rate is not a
    /// direction of travel.
    static let minimumTrendDays = 14

    /// Correlation needs more than a trend does, because the quantity being
    /// estimated is a relationship between two noisy series rather than one
    /// series' own drift.
    static let minimumCorrelationDays = 28

    /// A baseline shorter than this cannot say what is usual, so nothing can
    /// be called unusual against it.
    static let minimumBaselineDays = 14

    // MARK: - Trend

    struct Trend {
        /// Change in the measured unit per day.
        let slopePerDay: Double
        let confidenceLow: Double
        let confidenceHigh: Double
        let dayCount: Int
        /// The value the fitted line starts at, so a slope can be described
        /// relative to where it began rather than in a vacuum.
        let startValue: Double
        let endValue: Double
        /// How much of the variation the line accounts for. A steep slope
        /// through scattered points is still mostly scatter.
        let rSquared: Double

        /// Whether the data supports saying the direction at all.
        ///
        /// The confidence interval crossing zero means a flat line is as
        /// consistent with these points as the fitted one, and the honest
        /// report is "no detectable trend" rather than a slope with a sign.
        var isDetectable: Bool {
            confidenceLow > 0 || confidenceHigh < 0
        }

        var direction: String {
            guard isDetectable else {
                return "no detectable change"
            }
            return slopePerDay > 0 ? "rising" : "falling"
        }

        /// Change over a week, which is how a person thinks about drift.
        var perWeek: Double {
            slopePerDay * 7
        }
    }

    /// Fits a line through daily values and reports how much it can be
    /// trusted.
    ///
    /// - Parameter points: `(dayNumber, value)`, one per day that has data.
    ///   Days without data are simply absent rather than zero; a missing day
    ///   is not a day someone scored nothing.
    static func trend(_ points: [(day: Double, value: Double)]) -> Trend? {
        let n = points.count
        guard n >= minimumTrendDays else {
            return nil
        }

        let meanX = points.reduce(0) { $0 + $1.day } / Double(n)
        let meanY = points.reduce(0) { $0 + $1.value } / Double(n)

        var sxx = 0.0
        var sxy = 0.0
        var syy = 0.0
        for point in points {
            let dx = point.day - meanX
            let dy = point.value - meanY
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
        }
        guard sxx > 0 else {
            return nil
        }

        let slope = sxy / sxx
        let intercept = meanY - slope * meanX

        // Residual spread is what turns a slope into a claim or leaves it as
        // an artefact of scatter.
        var residualSumOfSquares = 0.0
        for point in points {
            let predicted = intercept + slope * point.day
            let residual = point.value - predicted
            residualSumOfSquares += residual * residual
        }

        let degreesOfFreedom = n - 2
        let residualVariance = residualSumOfSquares / Double(degreesOfFreedom)
        let standardError = (residualVariance / sxx).squareRoot()
        let margin = tCritical(degreesOfFreedom: degreesOfFreedom) * standardError

        let firstDay = points.map(\.day).min() ?? 0
        let lastDay = points.map(\.day).max() ?? 0

        return Trend(
            slopePerDay: slope,
            confidenceLow: slope - margin,
            confidenceHigh: slope + margin,
            dayCount: n,
            startValue: intercept + slope * firstDay,
            endValue: intercept + slope * lastDay,
            rSquared: syy > 0 ? max(0, 1 - residualSumOfSquares / syy) : 0
        )
    }

    // MARK: - Correlation

    struct Correlation {
        let coefficient: Double
        let pairedDays: Int
        /// Days adjusted for the fact that consecutive ones are not
        /// independent. See ``effectiveSampleSize(_:_:)``.
        let effectiveDays: Double
        let confidenceLow: Double
        let confidenceHigh: Double
        /// Whether both series are drifting over the window. Two things that
        /// both rise across a year correlate strongly without being related to
        /// each other at all, and that is the single most common way this
        /// kind of number misleads.
        let bothTrending: Bool

        /// Whether a relationship can be claimed.
        ///
        /// The interval is computed on the autocorrelation-adjusted sample
        /// size, so a run of similar days cannot masquerade as independent
        /// evidence.
        var isDetectable: Bool {
            (confidenceLow > 0 || confidenceHigh < 0) && effectiveDays >= 10
        }

        var strength: String {
            let magnitude = abs(coefficient)
            return switch magnitude {
            case ..<0.2: "negligible"
            case ..<0.4: "weak"
            case ..<0.6: "moderate"
            case ..<0.8: "strong"
            default: "very strong"
            }
        }
    }

    /// Correlates two daily series over the days they share.
    ///
    /// - Parameters:
    ///   - first: `(dayNumber, value)` for one type.
    ///   - second: the same for another.
    static func correlation(
        _ first: [(day: Double, value: Double)],
        _ second: [(day: Double, value: Double)]
    ) -> Correlation? {
        // Only days where both were measured can say anything about the pair.
        let secondByDay = Dictionary(
            second.map { ($0.day, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        let paired = first
            .compactMap { point -> (Double, Double, Double)? in
                guard let other = secondByDay[point.day] else {
                    return nil
                }
                return (point.day, point.value, other)
            }
            .sorted { $0.0 < $1.0 }

        let n = paired.count
        guard n >= minimumCorrelationDays else {
            return nil
        }

        let xs = paired.map(\.1)
        let ys = paired.map(\.2)
        guard let r = pearson(xs, ys) else {
            return nil
        }

        // Daily health data is strongly autocorrelated: today's step count
        // resembles yesterday's. Treating each day as independent evidence
        // inflates confidence badly, so the interval is computed on an
        // effective sample size instead.
        let effective = effectiveSampleSize(xs, ys)

        // Fisher's transformation, which makes the sampling distribution of a
        // correlation roughly normal so an interval can be put around it.
        let z = atanh(min(max(r, -0.999_999), 0.999_999))
        let standardError = effective > 3
            ? (1 / (effective - 3)).squareRoot()
            : Double.infinity
        let margin = 1.96 * standardError

        let days = paired.map(\.0)
        let firstTrend = trend(zip(days, xs).map { (day: $0, value: $1) })
        let secondTrend = trend(zip(days, ys).map { (day: $0, value: $1) })

        return Correlation(
            coefficient: r,
            pairedDays: n,
            effectiveDays: effective,
            confidenceLow: margin.isFinite ? tanh(z - margin) : -1,
            confidenceHigh: margin.isFinite ? tanh(z + margin) : 1,
            bothTrending: (firstTrend?.isDetectable ?? false)
                && (secondTrend?.isDetectable ?? false)
        )
    }

    static func pearson(_ xs: [Double], _ ys: [Double]) -> Double? {
        guard xs.count == ys.count, xs.count > 1 else {
            return nil
        }
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n

        var sxy = 0.0
        var sxx = 0.0
        var syy = 0.0
        for (x, y) in zip(xs, ys) {
            let dx = x - meanX
            let dy = y - meanY
            sxy += dx * dy
            sxx += dx * dx
            syy += dy * dy
        }
        guard sxx > 0, syy > 0 else {
            // One series never varies, so nothing can co-vary with it.
            return nil
        }
        return sxy / (sxx * syy).squareRoot()
    }

    /// How many genuinely independent observations two series are worth.
    ///
    /// Consecutive days are not independent, and pretending they are is what
    /// turns three weeks of data into an apparently overwhelming result. This
    /// is the standard adjustment using each series' lag-one autocorrelation:
    /// two strongly self-similar series contribute far fewer independent pairs
    /// than their length suggests.
    static func effectiveSampleSize(_ xs: [Double], _ ys: [Double]) -> Double {
        let n = Double(xs.count)
        let a = lagOneAutocorrelation(xs)
        let b = lagOneAutocorrelation(ys)
        let factor = (1 - a * b) / (1 + a * b)
        // A factor of zero means each series is perfectly self-similar, which
        // is the *most* redundant case, not the least. Falling back to the raw
        // count here would have handed maximum confidence to exactly the data
        // that deserves least — so only a value that is not a number at all
        // falls back.
        guard factor.isFinite else {
            return n
        }
        return min(n, max(3, n * max(0, factor)))
    }

    static func lagOneAutocorrelation(_ values: [Double]) -> Double {
        guard values.count > 2 else {
            return 0
        }
        let lagged = Array(values.dropLast())
        let leading = Array(values.dropFirst())
        // Clamped: a negative estimate would inflate the effective sample size
        // above the real one, which is the wrong direction to be wrong in.
        return max(0, pearson(lagged, leading) ?? 0)
    }

    // MARK: - Anomalies

    struct DailyValue {
        let day: Double
        let value: Double
        /// How many records that day held. A day the watch was not worn looks
        /// exactly like a real outlier to anything that ignores this.
        let recordCount: Int
    }

    struct Outlier {
        let day: Double
        let value: Double
        /// Distance from the usual value, in robust deviations.
        let deviations: Double
        let recordCount: Int
        var isHigh: Bool { deviations > 0 }
    }

    struct AnomalyReport {
        let outliers: [Outlier]
        let median: Double
        let deviation: Double
        let consideredDays: Int
        /// Days excluded because too little was recorded to judge them. These
        /// are reported rather than dropped, because "the watch was off" is a
        /// different answer from "nothing unusual happened".
        let lowCoverageDays: [Double]
    }

    /// Finds days that genuinely stand out, and refuses to confuse them with
    /// days that were barely measured.
    ///
    /// Uses the median and median absolute deviation rather than mean and
    /// standard deviation, because a single wear-gap artefact inflates a
    /// standard deviation enough to hide the real outliers it sits beside.
    ///
    /// - Parameter threshold: How many robust deviations count as unusual.
    ///   Three is roughly the conventional 3-sigma once scaled.
    static func anomalies(
        _ values: [DailyValue],
        threshold: Double = 3.0
    ) -> AnomalyReport? {
        guard values.count >= minimumBaselineDays else {
            return nil
        }

        // A day with far fewer records than usual was not measured properly.
        // Judging its value against days that were is how "you stopped wearing
        // the watch" becomes "your resting heart rate collapsed".
        let counts = values.map { Double($0.recordCount) }.sorted()
        let medianCount = median(counts)
        let coverageFloor = max(1.0, medianCount * 0.34)

        let judged = values.filter { Double($0.recordCount) >= coverageFloor }
        let skipped = values
            .filter { Double($0.recordCount) < coverageFloor }
            .map(\.day)

        guard judged.count >= minimumBaselineDays else {
            return AnomalyReport(
                outliers: [],
                median: median(values.map(\.value).sorted()),
                deviation: 0,
                consideredDays: judged.count,
                lowCoverageDays: skipped
            )
        }

        let sorted = judged.map(\.value).sorted()
        let centre = median(sorted)
        // 1.4826 scales the median absolute deviation so it is comparable to a
        // standard deviation for normally distributed data.
        let absoluteDeviations = judged
            .map { abs($0.value - centre) }
            .sorted()
        let scaled = median(absoluteDeviations) * 1.4826

        guard scaled > 0 else {
            // Every judged day is identical, so nothing deviates from anything.
            return AnomalyReport(
                outliers: [],
                median: centre,
                deviation: 0,
                consideredDays: judged.count,
                lowCoverageDays: skipped
            )
        }

        let outliers = judged
            .map { day in
                Outlier(
                    day: day.day,
                    value: day.value,
                    deviations: (day.value - centre) / scaled,
                    recordCount: day.recordCount
                )
            }
            .filter { abs($0.deviations) >= threshold }
            .sorted { abs($0.deviations) > abs($1.deviations) }

        return AnomalyReport(
            outliers: outliers,
            median: centre,
            deviation: scaled,
            consideredDays: judged.count,
            lowCoverageDays: skipped
        )
    }

    static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else {
            return 0
        }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// Two-tailed 95% critical value.
    ///
    /// A table for the small degrees of freedom that actually occur here, with
    /// a standard approximation beyond it. Being slightly conservative is the
    /// right direction: it widens the interval, which makes a claim harder to
    /// support rather than easier.
    static func tCritical(degreesOfFreedom: Int) -> Double {
        let table: [Int: Double] = [
            1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571,
            6: 2.447, 7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228,
            11: 2.201, 12: 2.179, 13: 2.160, 14: 2.145, 15: 2.131,
            16: 2.120, 17: 2.110, 18: 2.101, 19: 2.093, 20: 2.086,
            25: 2.060, 30: 2.042, 40: 2.021, 60: 2.000, 120: 1.980
        ]
        if let exact = table[degreesOfFreedom] {
            return exact
        }
        guard degreesOfFreedom > 0 else {
            return 12.706
        }
        if degreesOfFreedom > 120 {
            return 1.96
        }
        // Between tabulated points, take the nearest lower entry, which errs
        // wide.
        let keys = table.keys.sorted()
        let lower = keys.last { $0 <= degreesOfFreedom } ?? 1
        return table[lower] ?? 1.96
    }
}
