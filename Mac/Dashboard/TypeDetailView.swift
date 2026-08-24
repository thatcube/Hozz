import Charts
import SwiftUI
import HozzUI
import HozzReceive

/// One type, properly.
///
/// A range to choose, the right summary statistic for what the type actually
/// is, the distribution of the individual readings, and — inseparable from the
/// chart rather than filed elsewhere — how much of the period the data covers.
struct TypeDetailView: View {
    let services: MacServices
    let type: String
    @Binding var range: ChartRange

    private var series: TypeSeries? { services.detail }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Dash.gutter) {
                if let series {
                    header(series)
                    if series.hasMixedUnits {
                        mixedUnitsCard(series)
                    } else {
                        statsCard(series)
                        chartCard(series)
                        if let distribution = services.distribution, !distribution.isEmpty {
                            distributionCard(series, distribution)
                        }
                    }
                    recentCard
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
            .dashboardPage()
        }
        .task(id: TaskKey(type: type, range: range)) {
            await services.loadDetail(type: type, range: range)
        }
    }

    private struct TaskKey: Equatable {
        let type: String
        let range: ChartRange
    }

    // MARK: - Header

    private func header(_ series: TypeSeries) -> some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(series.measure.displayName)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(HozzPalette.ink)
                Text(spanCaption(series))
                    .font(.callout)
                    .foregroundStyle(HozzPalette.inkSoft)
                // Said on every visit rather than only when a range comes up
                // empty. The state that produced the original bug — a type
                // years behind, charting happily — never opens an empty range
                // at all, so an explanation that appears only there is an
                // explanation that never appears when it is needed.
                Text(
                    OverviewNarration.completeness(
                        services.standing(for: type),
                        latest: services.summaries
                            .first { $0.type == type }?.latest,
                        day: Self.day
                    )
                )
                .font(.caption)
                .foregroundStyle(HozzPalette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            RangePicker(range: $range)
        }
    }

    /// How much is held and over what stretch — described as what arrived
    /// unless the phone has said the type is finished.
    ///
    /// "2019 – 2023" reads as the span of the person's records. For a type
    /// still being swept it is the span of the *arrivals*, and the two are not
    /// the same thing: an anchored sweep returns samples in the order Health
    /// stored them, so both ends of that range can move outward later.
    private func spanCaption(_ series: TypeSeries) -> String {
        guard let summary = services.summaries.first(where: { $0.type == type }) else {
            return ""
        }
        var text = summary.recordCount.formatted(.number)
        text += summary.recordCount == 1 ? " record" : " records"
        if let earliest = summary.earliest, let latest = summary.latest {
            let held = services.standing(for: type).licensesLatestDate
                ? ""
                : "received so far, "
            text += " · \(held)\(Self.day(earliest)) – \(Self.day(latest))"
        }
        if series.hasAggregatedSamples {
            // Worth saying: one row standing for hundreds of readings is why
            // the average here is weighted and not a plain mean.
            text += " · \(series.readingCount.formatted(.number)) readings in range"
        }
        return text
    }

    // MARK: - Cards

    /// Two units cannot be added, so nothing is drawn and the reason is given.
    private func mixedUnitsCard(_ series: TypeSeries) -> some View {
        Card(title: "Two different units in this range") {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Samples here arrived in \(series.units.joined(separator: " and ")). "
                        + "Combining them would produce a number that is neither, so nothing is charted."
                )
                .font(.callout)
                .foregroundStyle(HozzPalette.inkSoft)
                Text("The records are safe and unchanged — only the summary is withheld.")
                    .font(.caption)
                    .foregroundStyle(HozzPalette.inkMuted)
            }
        }
    }

    private func statsCard(_ series: TypeSeries) -> some View {
        let unit = series.displayUnit
        return Card {
            HStack(spacing: 0) {
                StatTile(
                    label: series.measure.kind.noun,
                    value: formattedOrDash(series.headline, unit: unit),
                    unit: unit.label,
                    caption: headlineCaption(series)
                )
                if let extremes = series.extremes, series.measure.kind != .duration {
                    StatTile(
                        label: "Lowest reading",
                        value: unit.format(extremes.minimum),
                        unit: unit.label
                    )
                    StatTile(
                        label: "Highest reading",
                        value: unit.format(extremes.maximum),
                        unit: unit.label
                    )
                }
                StatTile(
                    label: "Days with data",
                    value: "\(series.coverage.daysWithData)",
                    caption: "of \(series.coverage.dayCount) in range"
                )
                StatTile(
                    label: series.hasAggregatedSamples ? "Readings" : "Samples",
                    value: Self.compact(
                        series.hasAggregatedSamples
                            ? series.readingCount
                            : series.sampleCount
                    ),
                    caption: series.hasAggregatedSamples
                        ? "in \(series.sampleCount.formatted(.number)) stored rows"
                        : "stored rows"
                )
            }
        }
    }

    /// Says out loud which statistic this is, because the wrong one is the
    /// easiest way for a chart to lie.
    private func headlineCaption(_ series: TypeSeries) -> String {
        switch series.measure.kind {
        case .total: "added across the range"
        case .average: series.hasAggregatedSamples
            ? "weighted by readings per sample"
            : "mean of every reading"
        case .duration: "time recorded"
        case .occurrences: "times recorded"
        }
    }

    private func chartCard(_ series: TypeSeries) -> some View {
        let unit = series.displayUnit
        return Card(
            title: "Over time",
            subtitle: "One \(series.granularity.columnNoun) per column, in your local time.",
            accessory: AnyView(
                Text(unit.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(HozzPalette.inkMuted)
            )
        ) {
            if series.values.isEmpty {
                emptyRange(series)
            } else {
                chartBody(series)
                    .frame(height: 240)

                CoverageRibbon(
                    columns: series.columns,
                    coverage: series.coverage,
                    granularity: series.granularity
                )
            }
        }
    }

    /// One point actually drawn: the column it came from, so coverage can tint
    /// it, and the value already converted to the display unit.
    private struct Drawn: Identifiable {
        let column: SeriesColumn
        let value: Double
        var id: Int { column.index }
    }

    private func drawn(_ series: TypeSeries) -> [Drawn] {
        let unit = series.displayUnit
        return series.columns.compactMap { column in
            guard let value = series.value(column) else { return nil }
            return Drawn(column: column, value: unit.convert(value))
        }
    }

    /// The branch happens here, at the `View` level, and not inside the chart.
    ///
    /// Swift Charts only conforms `_ConditionalContent` to `ChartContent` from
    /// macOS 27, so an `if` inside a `Chart` builder will not compile against
    /// this app's macOS 14 deployment target. Two whole charts is also simply
    /// clearer than one with two personalities.
    @ViewBuilder
    private func chartBody(_ series: TypeSeries) -> some View {
        if series.measure.kind == .average {
            measuredChart(series)
        } else {
            accumulatedChart(series)
        }
    }

    /// A measured type is a line.
    ///
    /// A bar drawn from zero implies the value was zero between readings, which
    /// for a resting heart rate would mean something rather serious.
    private func measuredChart(_ series: TypeSeries) -> some View {
        let unit = series.displayUnit
        let points = drawn(series)
        // An array of nought or one, so the mean can be drawn without an `if`
        // inside the chart builder.
        let mean = series.headline.map { [unit.convert($0)] } ?? []
        let small = series.columns.count > 60

        return Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("When", point.column.start),
                    y: .value(unit.label, point.value)
                )
                .foregroundStyle(HozzPalette.blue)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)
            }
            ForEach(points) { point in
                PointMark(
                    x: .value("When", point.column.start),
                    y: .value(unit.label, point.value)
                )
                .symbolSize(small ? 6 : 22)
                .foregroundStyle(
                    HozzPalette.blue.opacity(coverageOpacity(point.column))
                )
            }
            ForEach(mean, id: \.self) { value in
                RuleMark(y: .value("Average", value))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(HozzPalette.inkMuted.opacity(0.55))
                    .annotation(position: .top, alignment: .leading) {
                        Text("average \(unit.format(series.headline ?? 0))")
                            .font(.caption2)
                            .foregroundStyle(HozzPalette.inkMuted)
                    }
            }
        }
        .modifier(DashboardAxes())
    }

    /// Something that accumulates is a bar: the column is the whole of it.
    private func accumulatedChart(_ series: TypeSeries) -> some View {
        let unit = series.displayUnit
        let points = drawn(series)
        let dense = series.columns.count > 60

        return Chart(points) { point in
            BarMark(
                x: .value("When", point.column.start),
                y: .value(unit.label, point.value)
            )
            .foregroundStyle(HozzPalette.blue.opacity(coverageOpacity(point.column)))
            .cornerRadius(dense ? 0.5 : 3)
        }
        .modifier(DashboardAxes())
    }

    /// An empty range is a fact about the sweep, not about the person.
    private func emptyRange(_ series: TypeSeries) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing in this range yet.")
                .font(.callout.weight(.medium))
                .foregroundStyle(HozzPalette.ink)
            if let summary = services.summaries.first(where: { $0.type == type }),
               let latest = summary.latest {
                // This used to explain the sweep whether or not the sweep was
                // still running: "your phone sends one type at a time, so the
                // newest days often arrive last" was shown for a finished type
                // too, where it is simply not true and quietly suggests more is
                // coming when nothing is. The phone now says which it is.
                Text(
                    "This type does have \(summary.recordCount.formatted(.number)) records, "
                        + "the most recent from \(Self.day(latest)). "
                        + OverviewNarration.completeness(
                            services.standing(for: type),
                            latest: nil,
                            day: Self.day
                        )
                )
                .font(.caption)
                .foregroundStyle(HozzPalette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                // A way out rather than a dead end: the records are here, and
                // the only thing between the reader and them is the window.
                if range != .all {
                    Button("Show everything held") { range = .all }
                        .buttonStyle(.borderedProminent)
                        .tint(HozzPalette.blue)
                        .padding(.top, 2)
                }
            }
        }
        .frame(height: 240, alignment: .topLeading)
    }

    /// Where the individual readings actually sit.
    ///
    /// A column chart of daily averages hides that half the readings were at
    /// one end; the histogram is drawn from the readings themselves.
    private func distributionCard(
        _ series: TypeSeries,
        _ buckets: [DistributionBucket]
    ) -> some View {
        let unit = series.displayUnit
        return Card(
            title: "Distribution",
            subtitle: "Every individual reading in range, not the daily figures."
        ) {
            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Value", unit.convert(bucket.midpoint)),
                    y: .value("Readings", bucket.count),
                    width: .ratio(0.9)
                )
                .foregroundStyle(HozzPalette.blue.opacity(0.7))
                .cornerRadius(2)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(HozzPalette.lineSoft)
                    AxisValueLabel().foregroundStyle(HozzPalette.inkMuted)
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(HozzPalette.lineSoft.opacity(0.6))
                    AxisValueLabel().foregroundStyle(HozzPalette.inkMuted)
                }
            }
            .chartXAxisLabel(unit.label, alignment: .trailing)
            .frame(height: 150)
        }
    }

    private var recentCard: some View {
        Card(
            title: "Most recent readings",
            subtitle: "Straight from the archive, newest first."
        ) {
            if services.recent.isEmpty {
                Text("None held.")
                    .font(.callout)
                    .foregroundStyle(HozzPalette.inkMuted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(services.recent.prefix(8).enumerated()), id: \.offset) { index, record in
                        if index > 0 {
                            Divider().overlay(HozzPalette.lineSoft)
                        }
                        HStack {
                            Text(record.startDate.formatted(
                                date: .abbreviated,
                                time: .shortened
                            ))
                            .font(.callout)
                            .foregroundStyle(HozzPalette.inkSoft)
                            Spacer()
                            Text(record.sourceName ?? "—")
                                .font(.caption)
                                .foregroundStyle(HozzPalette.inkMuted)
                                .lineLimit(1)
                            Spacer()
                            Text(readingText(record))
                                .font(.callout.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(HozzPalette.ink)
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
    }

    /// A single reading in its own stored unit.
    ///
    /// Deliberately converted with a unit built for this one value rather than
    /// for the series: a row is one number, and borrowing the chart's scale
    /// would print a day's kilometres beside a single metre reading.
    private func readingText(_ record: HealthRecord) -> String {
        guard let value = record.value else {
            return "—"
        }
        let measure = HealthMeasure.measure(for: record.type, storedUnit: record.unit)
        return measure.displayUnit(forMagnitude: value).formatted(value)
    }

    private static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private static func compact(_ count: Int) -> String {
        OverviewView.compact(count)
    }
}
