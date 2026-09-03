import HozzUI
import Observation
import SwiftUI

@MainActor
@Observable
final class MetricDetailViewModel {
    private(set) var series: MetricSeries?
    private(set) var isLoading = false
    private(set) var failure: String?

    private let reader: HealthMetricReader
    private let metric: DashboardMetric
    /// Which load is the current one.
    ///
    /// A cancelled task is not a stopped one: the HealthKit query has already
    /// been handed off, its callback still fires, and its continuation still
    /// resumes. So switching from Week to Year could see the cheap Week query
    /// land *after* the expensive Year one and leave a week of data on screen
    /// under the year's labels, permanently. Only the newest request may
    /// write.
    private var generation = 0

    init(metric: DashboardMetric, reader: HealthMetricReader = HealthMetricReader()) {
        self.metric = metric
        self.reader = reader
    }

    func load(range: MetricRange) async {
        generation += 1
        let request = generation
        isLoading = true
        // Cleared rather than left in place. The picker changes the moment it
        // is tapped, so keeping the old series would draw one range's numbers
        // under another's labels — a week's step total titled "Total, 12
        // months", which is wrong by around fiftyfold and looks deliberate.
        series = nil
        failure = nil

        do {
            let loaded = try await reader.series(for: metric, range: range)
            guard request == generation else {
                return
            }
            series = loaded
            isLoading = false
        } catch {
            guard request == generation else {
                return
            }
            series = nil
            failure = error.localizedDescription
            isLoading = false
        }
    }
}

/// One type over time, with the statistics that make sense for it and a plain
/// statement of how much of the range actually has data behind it.
struct MetricDetailView: View {
    let metric: DashboardMetric

    @State private var range: MetricRange = .week
    @State private var model: MetricDetailViewModel

    init(metric: DashboardMetric) {
        self.metric = metric
        _model = State(initialValue: MetricDetailViewModel(metric: metric))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                picker
                chartCard
                statisticsCard
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(HozzSurface())
        .navigationTitle(metric.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: range) { await model.load(range: range) }
    }

    private var picker: some View {
        Picker("Range", selection: $range) {
            ForEach(MetricRange.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 14))
                    .foregroundStyle(HozzPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let series = model.series {
                headline(for: series)
                if series.hasUnitConflict {
                    unitConflictNote
                } else if series.hasAnyData {
                    MetricChart(series: series, metric: metric, range: range)
                    MetricCoverageNote(
                        coverage: series.coverage(now: .now),
                        range: range,
                        isAggregated: series.containsAggregatedReadings
                    )
                } else {
                    MetricEmptyNote()
                        .padding(.vertical, 26)
                }
                // Printed whatever the state, because a filing rule explains an
                // empty chart as readily as a full one.
                if let note = metric.note {
                    MetricNoteLine(text: note)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 70)
            }
        }
        .hozzCard()
    }

    /// Two readings of the same type in different units must not be added, and
    /// without a conversion table the honest answer is no number at all.
    private var unitConflictNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mixed units")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(HozzPalette.inkSoft)
            Text(
                "Hozz will not combine readings without a known conversion."
            )
            .hozzCaption()
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private func headline(for series: MetricSeries) -> some View {
        let summary = series.summary
        VStack(alignment: .leading, spacing: 2) {
            Text(headlineLabel(for: summary))
                .hozzLabel()
                .textCase(.uppercase)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let value = summary.headline {
                    Text(MetricFormat.headline(value, for: metric))
                        .hozzDisplay(size: 36)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if !isSleep {
                        Text(metric.unitLabel).hozzUnit()
                    }
                } else {
                    Text("—")
                        .hozzDisplay(size: 36)
                        .foregroundColor(HozzPalette.inkMuted)
                }
            }
        }
    }

    /// The label has to name which reduction this is, because "total" and
    /// "average" over the same chart are different numbers and only one of
    /// them is on screen.
    private func headlineLabel(for summary: MetricSummary) -> String {
        let span = switch range {
        case .week: "7 days"
        case .month: "30 days"
        case .year: "12 months"
        }
        return summary.aggregation == .total
            ? "Total, \(span)"
            : "Average, \(span)"
    }

    @ViewBuilder
    private var statisticsCard: some View {
        if let series = model.series, series.hasAnyData, !series.hasUnitConflict {
            let summary = series.summary
            VStack(alignment: .leading, spacing: 13) {
                Text("Statistics")
                    .hozzLabel()
                    .textCase(.uppercase)

                VStack(spacing: 0) {
                    ForEach(Array(rows(for: summary).enumerated()), id: \.offset) { index, row in
                        if index > 0 {
                            Divider().overlay(HozzPalette.lineSoft)
                        }
                        HStack {
                            Text(row.label)
                                .font(.system(size: 14))
                                .foregroundStyle(HozzPalette.inkSoft)
                            Spacer(minLength: 12)
                            Text(row.value)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(HozzPalette.ink)
                        }
                        .padding(.vertical, 9)
                    }
                }
            }
            .hozzCard()
        }
    }

    private struct StatisticRow {
        let label: String
        let value: String
    }

    /// Only the statistics that mean something for this kind of type.
    ///
    /// A cumulative type gets a total and a per-day average; a measured one
    /// gets an average and its extremes. Offering a "total resting heart rate"
    /// would be offering a number with no meaning, and someone would read it.
    private func rows(for summary: MetricSummary) -> [StatisticRow] {
        var rows: [StatisticRow] = []
        let noun = range.bucketNoun

        if summary.aggregation == .total, let perBucket = summary.averagePerActiveBucket {
            rows.append(
                StatisticRow(
                    label: "Average per \(noun) with data",
                    value: formatted(perBucket)
                )
            )
        }
        if let low = summary.lowest {
            rows.append(StatisticRow(label: "Lowest reading", value: formatted(low)))
        }
        if let high = summary.highest {
            rows.append(StatisticRow(label: "Highest reading", value: formatted(high)))
        }
        rows.append(
            StatisticRow(
                label: "\(noun.capitalized)s with data",
                value: "\(summary.bucketsWithData) of \(summary.bucketsInRange)"
            )
        )
        return rows
    }

    private func formatted(_ value: Double) -> String {
        let text = MetricFormat.headline(value, for: metric)
        return isSleep ? text : "\(text) \(metric.unitLabel)"
    }

    private var isSleep: Bool {
        if case .sleep = metric.kind { return true }
        return false
    }
}
