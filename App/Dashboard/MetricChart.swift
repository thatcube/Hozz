import Charts
import HozzUI
import SwiftUI

/// The chart pieces the dashboard is assembled from.
///
/// The whole design problem here is that Brandon's data — and almost anyone's
/// — is lopsided. Years of dense history sit behind a recent stretch that is
/// nearly empty, and a chart drawn over that without comment says "you did
/// nothing this month" when the truth is "this month has barely arrived yet".
///
/// So a gap is drawn as a gap. Bars simply do not appear for buckets nothing
/// came back for, a dimmed band marks the stretch before the data begins, and
/// the caption underneath says how many buckets of the range actually hold
/// anything. None of that is decoration; it is the difference between a chart
/// that reports and one that implies.
///
/// Everything plotted is worked out before the chart builder runs. Swift
/// Charts on iOS 17 cannot take a branch inside its builder, and precomputing
/// is faster anyway: a year of data becomes an array of twelve before Charts
/// sees any of it.

// MARK: - Formatting

enum MetricFormat {
    static func value(
        _ value: Double,
        fractionDigits: Int,
        abbreviateThousands: Bool = false
    ) -> String {
        if abbreviateThousands, abs(value) >= 10_000 {
            // A six-figure step count in a small card wraps and loses its
            // label. Below ten thousand the exact number fits and is more
            // useful, so the abbreviation only starts above it.
            let thousands = value / 1_000
            return "\(thousands.formatted(.number.precision(.fractionLength(0))))k"
        }
        return value.formatted(
            .number.precision(.fractionLength(0...max(0, fractionDigits)))
        )
    }

    /// Hours as a person says them: "7h 20m", not "7.33".
    static func hours(_ hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        let whole = totalMinutes / 60
        let minutes = totalMinutes % 60
        if whole == 0 {
            return "\(minutes)m"
        }
        return minutes == 0 ? "\(whole)h" : "\(whole)h \(minutes)m"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        hours(seconds / 3_600)
    }

    static func headline(_ value: Double, for metric: DashboardMetric) -> String {
        if case .sleep = metric.kind {
            return hours(value)
        }
        return self.value(
            value,
            fractionDigits: metric.fractionDigits,
            abbreviateThousands: metric.fractionDigits == 0
        )
    }
}

// MARK: - What actually gets drawn

/// A bucket flattened to something with no optionals in it, so the chart
/// builder never needs a branch.
struct PlottablePoint: Identifiable, Equatable {
    let id: Date
    let value: Double
    /// The last bucket of a range that has not finished yet — today. Drawn
    /// lighter, because comparing a part-day with whole ones invites the wrong
    /// conclusion.
    let isUnfinished: Bool
}

extension MetricSeries {
    func plottable(now: Date) -> [PlottablePoint] {
        let unfinishedID = coverage(now: now).finalBucketIsPartial
            ? buckets.last?.id
            : nil
        return buckets.compactMap { bucket in
            // A value that is not a number is not a measurement, so it is not
            // drawn. It also cannot be allowed as far as the axis: a domain
            // built from one is not a valid range and traps rather than
            // rendering oddly.
            guard let value = bucket.value, value.isFinite else {
                return nil
            }
            return PlottablePoint(
                id: bucket.id,
                value: value,
                isUnfinished: bucket.id == unfinishedID
            )
        }
    }

    /// The stretch at the start of the range that nothing had arrived for yet,
    /// as a zero-or-one element array so it can be drawn without a branch.
    func leadInGap(now: Date) -> [DateInterval] {
        let coverage = coverage(now: now)
        guard
            let first = coverage.firstBucketWithData,
            first > 0,
            let start = buckets.first?.interval.start
        else {
            return []
        }
        return [DateInterval(start: start, end: buckets[first].interval.start)]
    }

    /// The vertical span a chart should cover.
    ///
    /// A cumulative type starts at zero, because a bar's height is the amount
    /// and a shortened axis would overstate every difference. A measured type
    /// gets its own span: a resting heart rate between 48 and 62 drawn from
    /// zero is a flat line that says nothing.
    func domain(padding: Double = 0.18) -> ClosedRange<Double> {
        let values = buckets.compactMap(\.value).filter(\.isFinite)
        guard let low = values.min(), let high = values.max(), low <= high else {
            return 0...1
        }
        switch aggregation {
        case .total:
            return 0...(high > 0 ? high * (1 + padding * 0.8) : 1)
        case .average:
            guard high > low else {
                // One value, or several identical ones. Give it room so the
                // line sits in the middle rather than along an edge.
                let pad = max(abs(high) * 0.1, 1)
                return (low - pad)...(high + pad)
            }
            // Never zero, so the bounds cannot collide however small the
            // spread between the readings is.
            let pad = max((high - low) * padding, .ulpOfOne)
            return (low - pad)...(high + pad)
        }
    }
}

// MARK: - Notes under a chart

/// One line of small print under a chart, with an icon to set it apart from
/// the numbers above it.
struct MetricNoteLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            HozzIconView(.infoCircle, size: 11)
                .foregroundStyle(HozzPalette.inkMuted)
                .padding(.top, 1)
            Text(text)
                .hozzCaption()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Coverage caption

/// The sentence under a chart that says how much of the range is really there.
///
/// It never says "complete". Health does not publish a total without being
/// read in full, and it does not distinguish a type someone declined from one
/// with nothing in it — a declined type comes back empty, exactly like an
/// empty one. So the wording only ever reports what arrived.
struct MetricCoverageNote: View {
    let coverage: MetricCoverage
    let range: MetricRange
    var isAggregated: Bool = false

    var body: some View {
        if let sentence {
            MetricNoteLine(text: sentence)
        }
    }

    private var sentence: String? {
        guard !coverage.isEmpty else {
            return nil
        }
        var parts: [String] = []
        if coverage.isPartial {
            // Pluralised on the range, not on the count: it is "1 of 7 days",
            // because the noun belongs to the seven.
            let noun = coverage.bucketsInRange == 1
                ? range.bucketNoun
                : "\(range.bucketNoun)s"
            let verb = coverage.bucketsWithData == 1 ? "has" : "have"
            parts.append(
                """
                \(coverage.bucketsWithData) of \(coverage.bucketsInRange) \
                \(noun) \(verb) data.
                """
            )
        }
        if coverage.finalBucketIsPartial {
            parts.append("\(range.currentBucketName) is still going.")
        }
        if isAggregated {
            parts.append("Some readings arrived already averaged.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

// MARK: - The chart

/// One series drawn.
///
/// Cumulative types get bars, because a day's steps are a quantity that
/// accumulated and a bar reads as an amount. Measured types get a line,
/// because a resting heart rate is a level rather than an amount, and bars
/// from a zero baseline exaggerate small differences into a story.
struct MetricChart: View {
    let series: MetricSeries
    let metric: DashboardMetric
    let range: MetricRange
    var height: CGFloat = 190

    private var now: Date { .now }

    var body: some View {
        Group {
            if series.aggregation == .total {
                barChart
            } else {
                lineChart
            }
        }
        .chartYScale(domain: series.domain())
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: range == .week ? 7 : 4)) { _ in
                AxisValueLabel(format: axisFormat)
                    .font(.system(size: 10))
                    .foregroundStyle(HozzPalette.inkMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(HozzPalette.lineSoft)
                AxisValueLabel()
                    .font(.system(size: 10))
                    .foregroundStyle(HozzPalette.inkMuted)
            }
        }
        .frame(height: height)
    }

    private var barChart: some View {
        Chart {
            ForEach(series.leadInGap(now: now), id: \.start) { gap in
                RectangleMark(
                    xStart: .value("From", gap.start),
                    xEnd: .value("To", gap.end)
                )
                .foregroundStyle(HozzPalette.inkMuted.opacity(0.055))
            }
            ForEach(series.plottable(now: now)) { point in
                BarMark(
                    x: .value(range.bucketNoun.capitalized, point.id, unit: range.plottableUnit),
                    y: .value(metric.title, point.value)
                )
                .foregroundStyle(
                    point.isUnfinished
                        ? HozzPalette.blue.opacity(0.32)
                        : HozzPalette.blue.opacity(0.88)
                )
                // Rounded through `cornerRadius` rather than by clipping to a
                // shape. Clipping a BarMark to an UnevenRoundedRectangle
                // compiles and then draws nothing at all — the whole chart
                // comes back empty, with the axes still dutifully labelled.
                .cornerRadius(3)
            }
        }
    }

    private var lineChart: some View {
        Chart {
            ForEach(series.leadInGap(now: now), id: \.start) { gap in
                RectangleMark(
                    xStart: .value("From", gap.start),
                    xEnd: .value("To", gap.end)
                )
                .foregroundStyle(HozzPalette.inkMuted.opacity(0.055))
            }
            ForEach(series.plottable(now: now)) { point in
                AreaMark(
                    x: .value(range.bucketNoun.capitalized, point.id),
                    y: .value(metric.title, point.value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            HozzPalette.blue.opacity(0.2),
                            HozzPalette.blue.opacity(0.01)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)
            }
            ForEach(series.plottable(now: now)) { point in
                LineMark(
                    x: .value(range.bucketNoun.capitalized, point.id),
                    y: .value(metric.title, point.value)
                )
                .foregroundStyle(HozzPalette.blue)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            }
            ForEach(markedPoints) { point in
                PointMark(
                    x: .value(range.bucketNoun.capitalized, point.id),
                    y: .value(metric.title, point.value)
                )
                .foregroundStyle(HozzPalette.blue)
                .symbolSize(26)
            }
        }
    }

    /// Individual points are only worth showing when there are few enough to
    /// tell apart. Past that they merge into the line and add noise.
    private var markedPoints: [PlottablePoint] {
        let points = series.plottable(now: now)
        return points.count <= 12 ? points : []
    }

    private var axisFormat: Date.FormatStyle {
        switch range {
        case .week: .dateTime.weekday(.narrow)
        case .month: .dateTime.day()
        case .year: .dateTime.month(.narrow)
        }
    }
}

// MARK: - Sparkline

/// The small chart on an overview card. No axes, no labels — it gives the
/// headline number a shape rather than being read off.
struct MetricSparkline: View {
    let series: MetricSeries
    var height: CGFloat = 32

    var body: some View {
        Group {
            if series.aggregation == .total {
                bars
            } else {
                line
            }
        }
        .chartYScale(domain: series.domain(padding: 0.25))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: height)
    }

    private var bars: some View {
        Chart {
            ForEach(series.plottable(now: .now)) { point in
                BarMark(
                    x: .value("Day", point.id, unit: .day),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(
                    point.isUnfinished
                        ? HozzPalette.blue.opacity(0.3)
                        : HozzPalette.blue.opacity(0.7)
                )
                .cornerRadius(2)
            }
        }
    }

    private var line: some View {
        Chart {
            ForEach(series.plottable(now: .now)) { point in
                LineMark(
                    x: .value("Day", point.id),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(HozzPalette.blue.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            }
        }
    }
}

// MARK: - Empty state

/// What a metric with nothing in it says.
///
/// Plainly, and without alarm. A type with no data is not a fault: it is a
/// complete and successful answer of nothing. The one thing worth adding is
/// that Health will not say whether a type was declined, so this must not be
/// read as proof there is nothing to find.
struct MetricEmptyNote: View {
    var isCompact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("No data in this range")
                .font(.system(size: isCompact ? 13 : 15, weight: .medium))
                .foregroundStyle(HozzPalette.inkSoft)
            if !isCompact {
                Text(
                    """
                    Health does not say whether a type was declined or is \
                    simply empty, so Hozz cannot tell you which this is.
                    """
                )
                .hozzCaption()
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
