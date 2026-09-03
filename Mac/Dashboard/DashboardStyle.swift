import Charts
import SwiftUI
import HozzUI
import HozzReceive

typealias Card<Content: View> = HozzPanel<Content>
typealias StatTile = HozzStatTile

/// The honesty strip that sits under a chart.
///
/// Coverage is part of the chart rather than a screen of its own because the
/// alternative is drawing a sparse month exactly as if it were a full one and
/// putting the caveat somewhere the reader has to go looking for it. A phone
/// working back through nine years of history leaves this month thin and 2022
/// dense, and neither is a fault — but a reader who cannot see which is which
/// will read the thin month as a collapse in their health.
struct CoverageRibbon: View {
    let columns: [SeriesColumn]
    let coverage: SeriesCoverage
    let granularity: ChartGranularity

    private var isUniform: Bool {
        columns.allSatisfy(\.hasEveryDay)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let count = max(columns.count, 1)
                let spacing: CGFloat = columns.count > 60 ? 0 : 1
                let width = max(
                    (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count),
                    0.5
                )
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(columns) { column in
                        Capsule(style: .continuous)
                            .fill(fill(for: column))
                            .frame(width: width, height: 6)
                    }
                }
                .frame(height: 6, alignment: .center)
            }
            .frame(height: 6)

            HStack(spacing: 8) {
                Text(coverage.sentence)
                    .font(.caption2)
                    .foregroundStyle(HozzPalette.inkMuted)
                if !isUniform && coverage.daysWithData > 0 {
                    Text("Paler \(granularity.columnNoun)s have fewer days.")
                        .font(.caption2)
                        .foregroundStyle(HozzPalette.inkMuted.opacity(0.85))
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Opacity carries how much of a column arrived.
    ///
    /// A pale bar and a full one are the same height, so a partly covered
    /// period is never redrawn shorter than it was — the reader sees what was
    /// measured and, separately, how much of the period it was measured over.
    private func fill(for column: SeriesColumn) -> Color {
        guard column.dayCount > 0 else {
            return HozzPalette.lineSoft
        }
        let share = min(Double(column.daysWithData) / Double(column.dayCount), 1)
        if share == 0 {
            return HozzPalette.lineSoft
        }
        return HozzPalette.blue.opacity(0.25 + 0.75 * share)
    }
}

/// The same idea for a single chart mark: full where every day arrived, pale
/// where only some did.
func coverageOpacity(_ column: SeriesColumn) -> Double {
    guard column.dayCount > 0 else { return 1 }
    let share = min(Double(column.daysWithData) / Double(column.dayCount), 1)
    return 0.4 + 0.6 * share
}

/// A segmented range picker in the app's own tone.
struct RangePicker: View {
    @Binding var range: ChartRange

    var body: some View {
        Picker("Range", selection: $range) {
            ForEach(ChartRange.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240)
    }
}

/// Text for a value that may not exist, so a missing number never renders as 0.
func formattedOrDash(_ value: Double?, unit: DisplayUnit) -> String {
    guard let value else { return "—" }
    return unit.format(value)
}

/// The axis treatment every chart in the app shares.
///
/// One place so the grid lines and labels cannot drift apart between screens,
/// and so a chart added later inherits the tone without being told about it.
struct DashboardAxes: ViewModifier {
    func body(content: Content) -> some View {
        content
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
    }
}

extension View {
    /// The standard page padding, applied once.
    func dashboardPage() -> some View {
        padding(HozzMetrics.desktopPageInset)
    }
}
