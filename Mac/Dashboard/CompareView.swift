import Charts
import SwiftUI
import HozzUI
import HozzReceive

/// Several types on one timeline.
///
/// This is what a big screen buys, and it is why the archive stores every type
/// in one wide table rather than one table per type: "does my sleep track with
/// my step count" should be answerable by looking.
///
/// Different types have different units and wildly different magnitudes, so each
/// line is drawn against its own range. That is a real distortion and it is
/// stated in as many words on the axis and in the legend, where every series
/// carries the actual numbers its shape was drawn from. The alternative — one
/// shared axis — puts a resting heart rate and a step count on the same scale
/// and flattens the heart rate into a straight line at the bottom, which looks
/// authoritative and says nothing.
struct CompareView: View {
    let services: MacServices
    @Binding var range: ChartRange

    /// Four is the limit on purpose: a fifth line is one more than anybody can
    /// follow, and the point of this screen is being able to see a relationship.
    private static let maximumSeries = 4

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Dash.gutter) {
                header
                picker
                if services.comparison.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(emptyReason)
                                .font(.callout)
                                .foregroundStyle(HozzPalette.inkSoft)
                            if !services.comparisonTypes.isEmpty, range != .all {
                                Button("Show everything held") { range = .all }
                                    .buttonStyle(.borderedProminent)
                                    .tint(HozzPalette.blue)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
                    }
                } else {
                    chartCard
                    legendCard
                }
            }
            .dashboardPage()
        }
        .task(
            id: TaskKey(
                types: services.comparisonTypes,
                range: range,
                // Included so the defaults get chosen once the type list has
                // actually arrived. Without it, opening this screen before the
                // first refresh finishes leaves nothing selected and nothing to
                // change, because the key never moves again.
                knownTypes: services.summaries.count
            )
        ) {
            await services.loadComparison(range: range)
        }
    }

    private struct TaskKey: Equatable {
        let types: [String]
        let range: ChartRange
        let knownTypes: Int
    }

    /// Says which of the two reasons the chart is blank, because "pick
    /// something" and "nothing in this window" call for different actions.
    private var emptyReason: String {
        if services.comparisonTypes.isEmpty {
            return "Choose two or more types above to see them together."
        }
        return "Nothing chosen here reaches this range yet. A phone works back "
            + "through history one type at a time, so the newest weeks are "
            + "often the last to arrive."
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Compare")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(HozzPalette.ink)
                Text("Up to four types on one timeline.")
                    .font(.callout)
                    .foregroundStyle(HozzPalette.inkSoft)
            }
            Spacer()
            RangePicker(range: $range)
        }
    }

    private var picker: some View {
        Card(
            title: "Types",
            subtitle: "\(services.comparisonTypes.count) of \(Self.maximumSeries) chosen"
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(services.comparableTypes, id: \.type) { summary in
                        chip(summary.type)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 34)
        }
    }

    private func chip(_ type: String) -> some View {
        let chosen = services.comparisonTypes.contains(type)
        let index = services.comparisonTypes.firstIndex(of: type)
        let tint = index.map { HozzPalette.series($0) } ?? HozzPalette.blue
        return Button {
            services.toggleComparison(type, limit: Self.maximumSeries)
        } label: {
            HStack(spacing: 5) {
                if chosen {
                    Circle().fill(tint).frame(width: 7, height: 7)
                }
                Text(HealthMeasure.measure(for: type, storedUnit: nil).displayName)
                    .font(.caption.weight(chosen ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(chosen ? HozzPalette.blueWash : HozzPalette.air)
            .foregroundStyle(chosen ? HozzPalette.ink : HozzPalette.inkSoft)
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(
                    chosen ? tint.opacity(0.45) : HozzPalette.lineSoft,
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
    }

    private var chartCard: some View {
        Card(
            title: "Together",
            subtitle: "Each line is scaled to its own range, so shapes can be compared but heights cannot. Real values are in the legend below."
        ) {
            Chart {
                ForEach(Array(services.comparison.enumerated()), id: \.element.id) { index, entry in
                    ForEach(entry.points) { point in
                        LineMark(
                            x: .value("When", point.start),
                            y: .value("Scaled", point.normalised),
                            series: .value("Type", entry.id)
                        )
                        .foregroundStyle(HozzPalette.series(index))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.monotone)
                    }
                }
            }
            .chartYScale(domain: -0.04...1.04)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 0.5, 1]) { value in
                    AxisGridLine().foregroundStyle(HozzPalette.lineSoft)
                    AxisValueLabel {
                        // Deliberately "low / high" rather than 0 to 1. The
                        // numbers on this axis belong to no series, and
                        // printing them invites reading a 0.5 as a value.
                        if let number = value.as(Double.self) {
                            Text(number == 0 ? "low" : (number == 1 ? "high" : ""))
                                .foregroundStyle(HozzPalette.inkMuted)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(HozzPalette.lineSoft.opacity(0.6))
                    AxisValueLabel().foregroundStyle(HozzPalette.inkMuted)
                }
            }
            .frame(height: 280)
        }
    }

    private var legendCard: some View {
        Card(title: "What each line is") {
            VStack(spacing: 0) {
                ForEach(Array(services.comparison.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Divider().overlay(HozzPalette.lineSoft)
                    }
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(HozzPalette.series(index))
                            .frame(width: 16, height: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.series.measure.displayName)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(HozzPalette.ink)
                            Text(entry.series.coverage.sentence)
                                .font(.caption2)
                                .foregroundStyle(HozzPalette.inkMuted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(range(for: entry))
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(HozzPalette.inkSoft)
                            Text(
                                entry.series.measure.kind.noun
                                    + " " + headline(entry)
                            )
                            .font(.caption2)
                            .foregroundStyle(HozzPalette.inkMuted)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    /// The low and high the line's shape was drawn between.
    private func range(for entry: ComparisonSeries) -> String {
        let unit = entry.series.displayUnit
        guard entry.lowest < entry.highest else {
            return unit.formatted(entry.lowest)
        }
        return "\(unit.format(entry.lowest)) – \(unit.formatted(entry.highest))"
    }

    private func headline(_ entry: ComparisonSeries) -> String {
        guard let value = entry.series.headline else { return "—" }
        return entry.series.displayUnit.formatted(value)
    }
}

/// One line on the comparison chart, with the numbers its shape came from.
struct ComparisonSeries: Identifiable, Equatable {
    struct Point: Identifiable, Equatable {
        let start: Date
        let value: Double
        /// Where the value sits between this series' own lowest and highest.
        let normalised: Double

        var id: Date { start }
    }

    let series: TypeSeries
    let points: [Point]
    let lowest: Double
    let highest: Double

    var id: String { series.measure.type }

    /// Scales a series to its own range, keeping the real values alongside.
    ///
    /// A flat series would divide by zero, so it is drawn along the middle
    /// rather than at the top or bottom, where a reader would take the position
    /// to mean something.
    init?(series: TypeSeries) {
        let drawn = series.columns.compactMap { column -> (Date, Double)? in
            guard let value = series.value(column) else { return nil }
            return (column.start, value)
        }
        guard drawn.count >= 2 else { return nil }

        let values = drawn.map(\.1)
        guard let lowest = values.min(), let highest = values.max() else {
            return nil
        }
        let span = highest - lowest
        self.series = series
        self.lowest = lowest
        self.highest = highest
        self.points = drawn.map { start, value in
            Point(
                start: start,
                value: value,
                normalised: span > 0 ? (value - lowest) / span : 0.5
            )
        }
    }
}
