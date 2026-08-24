import Charts
import SwiftUI
import HozzUI
import HozzReceive

/// The first thing someone sees, and the reason to open the app.
///
/// Not a list of types. Someone opening this wants to know what their health
/// has actually been like, so the screen leads with the archive's own shape and
/// then answers, domain by domain, with real numbers in units people use.
struct OverviewView: View {
    let services: MacServices
    @Binding var selectedType: String?
    @Binding var section: DataSection

    @State private var range: ChartRange = .month

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Dash.gutter) {
                header
                archiveCard

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 320), spacing: Dash.gutter),
                        GridItem(.flexible(minimum: 320), spacing: Dash.gutter)
                    ],
                    spacing: Dash.gutter
                ) {
                    ForEach(HealthDomain.allCases) { domain in
                        domainCard(domain)
                    }
                }
            }
            .dashboardPage()
        }
        .task(id: range) { await services.loadOverview(range: range) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your health")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(HozzPalette.ink)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(HozzPalette.inkSoft)
            }
            Spacer()
            RangePicker(range: $range)
        }
    }

    private var subtitle: String {
        let records = services.totalRecords
        var text = records.formatted(.number.grouping(.automatic))
        text += records == 1 ? " record" : " records"
        text += " across \(services.summaries.count) "
        text += services.summaries.count == 1 ? "type" : "types"
        if let span = services.archiveSpan {
            text += ", \(Self.year(span.earliest))–\(Self.year(span.latest))"
        }
        return text + ". All of it on this computer."
    }

    // MARK: - Archive

    /// The archive's own shape, made the hero rather than hidden.
    ///
    /// This person has 58,910 records from 2022 and 734 from 2026. Any chart
    /// that shows recent months beside older ones has to explain that somehow,
    /// and the most honest explanation is simply to draw it: the sweep's
    /// progress through nine years of history is itself the most interesting
    /// picture on the screen, and it makes every thin month afterwards legible.
    private var archiveCard: some View {
        Card(
            title: "What has arrived",
            subtitle: "Records received each month. A phone works back through history one type at a time, so the shape here is the sweep's, not your life's."
        ) {
            if services.archiveDensity.isEmpty {
                Text("Nothing yet.")
                    .font(.callout)
                    .foregroundStyle(HozzPalette.inkMuted)
                    .frame(height: 150)
            } else {
                Chart(services.archiveDensity) { column in
                    AreaMark(
                        x: .value("Month", column.start),
                        y: .value("Records", column.recordCount)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                HozzPalette.blue.opacity(0.45),
                                HozzPalette.blue.opacity(0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("Month", column.start),
                        y: .value("Records", column.recordCount)
                    )
                    .foregroundStyle(HozzPalette.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.monotone)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(HozzPalette.lineSoft)
                        AxisValueLabel {
                            if let count = value.as(Int.self) {
                                Text(Self.compact(count))
                                    .foregroundStyle(HozzPalette.inkMuted)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .year)) { value in
                        AxisGridLine().foregroundStyle(HozzPalette.lineSoft)
                        AxisValueLabel(format: .dateTime.year())
                            .foregroundStyle(HozzPalette.inkMuted)
                    }
                }
                .frame(height: 150)

                HStack(spacing: 0) {
                    StatTile(
                        label: "Records",
                        value: services.totalRecords.formatted(.number),
                        caption: "on this computer"
                    )
                    StatTile(
                        label: "Types",
                        value: "\(services.summaries.count)",
                        caption: "seen so far"
                    )
                    StatTile(
                        label: "Busiest month",
                        value: busiestMonth,
                        caption: busiestMonthCount
                    )
                    StatTile(
                        label: "Devices",
                        value: "\(services.devices.count)",
                        caption: services.devices.first?.name ?? "none yet"
                    )
                }
            }
        }
    }

    private var busiestMonth: String {
        guard let peak = services.archiveDensity.max(by: { $0.recordCount < $1.recordCount }),
              peak.recordCount > 0 else {
            return "—"
        }
        return peak.start.formatted(.dateTime.month(.abbreviated).year())
    }

    private var busiestMonthCount: String {
        guard let peak = services.archiveDensity.max(by: { $0.recordCount < $1.recordCount }),
              peak.recordCount > 0 else {
            return ""
        }
        return "\(peak.recordCount.formatted(.number)) records"
    }

    // MARK: - Domains

    private func domainCard(_ domain: HealthDomain) -> some View {
        let snapshots = services.overview[domain] ?? []
        return Card(
            title: domain.rawValue,
            subtitle: snapshots.isEmpty
                ? "Nothing here has arrived yet."
                : rangeCaption,
            accessory: AnyView(
                Image(systemName: domain.symbol)
                    .font(.title3)
                    .foregroundStyle(HozzPalette.blue.opacity(0.75))
            )
        ) {
            if snapshots.isEmpty {
                Text("As your phone works back through your history, these appear here.")
                    .font(.caption)
                    .foregroundStyle(HozzPalette.inkMuted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                        if index > 0 {
                            Divider().overlay(HozzPalette.lineSoft)
                        }
                        MetricRow(snapshot: snapshot) {
                            selectedType = snapshot.series.measure.type
                            section = .types
                        }
                    }
                }
            }
        }
    }

    private var rangeCaption: String {
        switch range {
        case .week: "Past seven days"
        case .month: "Past thirty days"
        case .year: "Past year"
        case .all: "Everything held"
        }
    }

    private static func year(_ date: Date) -> String {
        date.formatted(.dateTime.year())
    }

    static func compact(_ count: Int) -> String {
        if count >= 1_000_000 {
            return (Double(count) / 1_000_000)
                .formatted(.number.precision(.fractionLength(0))) + "M"
        }
        if count >= 1000 {
            return (Double(count) / 1000)
                .formatted(.number.precision(.fractionLength(0))) + "k"
        }
        return "\(count)"
    }
}

/// One type on one line: what it was, how it moved, and how much arrived.
private struct MetricRow: View {
    let snapshot: IngestStore.MetricSnapshot
    let open: () -> Void

    private var series: TypeSeries { snapshot.series }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(series.measure.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(HozzPalette.ink)
                        .lineLimit(1)
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(HozzPalette.inkMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                sparkline
                    .frame(width: 84, height: 26)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(headline)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(HozzPalette.ink)
                    Text(series.displayUnit.label.isEmpty
                         ? series.measure.kind.noun
                         : series.displayUnit.label)
                        .font(.caption2)
                        .foregroundStyle(HozzPalette.inkMuted)
                }
                .frame(width: 78, alignment: .trailing)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var headline: String {
        guard let value = series.headline else { return "—" }
        return series.displayUnit.format(value)
    }

    /// Says what the number is and, when the range is empty, why.
    private var caption: String {
        if series.hasMixedUnits {
            return "Mixed units — not combined"
        }
        if series.headline == nil {
            guard let latest = snapshot.latestOverall else {
                return "No values yet"
            }
            return "Nothing in range · last \(latest.formatted(.dateTime.month(.abbreviated).year()))"
        }
        var text = series.measure.kind.noun.lowercased()
        if !series.coverage.isEveryDay {
            text += " · \(series.coverage.daysWithData)/\(series.coverage.dayCount) days"
        }
        return text
    }

    @ViewBuilder
    private var sparkline: some View {
        let drawn = series.columns.filter { series.value($0) != nil }
        if drawn.count < 2 {
            Rectangle()
                .fill(HozzPalette.lineSoft)
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .center)
        } else {
            Chart(drawn) { column in
                LineMark(
                    x: .value("When", column.start),
                    y: .value("Value", series.value(column) ?? 0)
                )
                .foregroundStyle(HozzPalette.blue)
                .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartPlotStyle { $0.background(Color.clear) }
        }
    }
}
