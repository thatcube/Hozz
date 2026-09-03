import Charts
import SwiftUI
import HozzUI
import HozzReceive

/// How someone felt, and what they took.
///
/// Two things that only make sense apart. A momentary emotion and a whole day's
/// mood are different measurements of different things, so they are never
/// averaged together — the schema says as much and this screen keeps its word.
/// Medication doses are counted by status for the same reason: skipped, snoozed
/// and never-answered are three separate facts, and only one of the four means
/// the medicine was taken.
struct MoodView: View {
    let services: MacServices

    private var daily: [IngestStore.StoredMoodEntry] {
        services.moods.filter { $0.kindOfEntry == "dailyMood" }
    }

    private var momentary: [IngestStore.StoredMoodEntry] {
        services.moods.filter { $0.kindOfEntry != "dailyMood" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HozzMetrics.desktopGutter) {
                header
                if services.moods.isEmpty {
                    Card {
                        Text("No State of Mind entries.")
                            .font(.callout)
                            .foregroundStyle(HozzPalette.inkMuted)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                } else {
                    statsCard
                    chartCard
                    if !associations.isEmpty {
                        associationsCard
                    }
                }
                medicationCard
            }
            .dashboardPage()
        }
        .task { await services.loadMoodAndMedication() }
    }

    private var header: some View {
        HozzPageHeader("Mood & medication")
    }

    private var statsCard: some View {
        Card {
            HStack(spacing: 0) {
                StatTile(
                    label: "Entries",
                    value: "\(services.moods.count)",
                    caption: "\(daily.count) daily · \(momentary.count) momentary"
                )
                if let average = Self.mean(daily) {
                    StatTile(
                        label: "Daily mood",
                        value: Self.valence(average),
                        caption: Self.describe(average)
                    )
                }
                if let average = Self.mean(momentary) {
                    StatTile(
                        label: "Momentary",
                        value: Self.valence(average),
                        caption: Self.describe(average)
                    )
                }
                if let latest = services.moods.map(\.startDate).max() {
                    StatTile(
                        label: "Most recent",
                        value: latest.formatted(.dateTime.month(.abbreviated).day()),
                        caption: latest.formatted(.dateTime.year())
                    )
                }
            }
        }
    }

    private var chartCard: some View {
        Card(
            title: "Over time",
            subtitle: "Daily moods and momentary emotions stay separate."
        ) {
            Chart {
                RuleMark(y: .value("Neutral", 0))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(HozzPalette.lineSoft)

                ForEach(Array(daily.enumerated()), id: \.offset) { _, entry in
                    PointMark(
                        x: .value("When", entry.startDate),
                        y: .value("Valence", entry.valence)
                    )
                    .foregroundStyle(HozzPalette.blue)
                    .symbolSize(60)
                }
                ForEach(Array(momentary.enumerated()), id: \.offset) { _, entry in
                    PointMark(
                        x: .value("When", entry.startDate),
                        y: .value("Valence", entry.valence)
                    )
                    .foregroundStyle(HozzPalette.series(1))
                    .symbol(.diamond)
                    .symbolSize(50)
                }
            }
            .chartYScale(domain: -1...1)
            .chartYAxis {
                AxisMarks(position: .leading, values: [-1, -0.5, 0, 0.5, 1]) { value in
                    AxisGridLine().foregroundStyle(HozzPalette.lineSoft)
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(Self.axisLabel(number))
                                .font(.caption2)
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
            .frame(height: 210)

            HStack(spacing: 14) {
                legend(HozzPalette.blue, "Daily mood")
                legend(HozzPalette.series(1), "Momentary emotion")
                Spacer()
            }
        }
    }

    private func legend(_ colour: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(HozzPalette.inkMuted)
        }
    }

    /// What the person themselves put the feeling down to.
    private var associations: [(String, Int)] {
        var counts: [String: Int] = [:]
        for entry in services.moods {
            for association in entry.associations
                .split(separator: ",")
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                where !association.isEmpty {
                counts[association, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    private var associationsCard: some View {
        Card(
            title: "Associations"
        ) {
            Chart(Array(associations.prefix(10)), id: \.0) { item in
                BarMark(
                    x: .value("Times", item.1),
                    y: .value("Association", Self.readable(item.0))
                )
                .foregroundStyle(HozzPalette.blue.opacity(0.75))
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(HozzPalette.lineSoft)
                    AxisValueLabel().foregroundStyle(HozzPalette.inkMuted)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel().foregroundStyle(HozzPalette.inkSoft)
                }
            }
            .frame(height: CGFloat(min(associations.count, 10)) * 26 + 30)
        }
    }

    private var medicationCard: some View {
        Card(
            title: "Medication",
            verbatimSubtitle: services.medications.isEmpty
                ? nil
                : "Dose statuses stay separate."
        ) {
            if services.medications.isEmpty {
                // An empty type exported nothing, which is a complete and
                // successful result. It is not a warning and is not drawn as one.
                Text("No medication doses.")
                    .font(.callout)
                    .foregroundStyle(HozzPalette.inkMuted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(services.medications.enumerated()), id: \.offset) { index, entry in
                        if index > 0 {
                            Divider().overlay(HozzPalette.lineSoft)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.medication)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(HozzPalette.ink)
                            HStack(spacing: 12) {
                                ForEach(
                                    entry.statusCounts.sorted(by: { $0.key < $1.key }),
                                    id: \.key
                                ) { status, count in
                                    Text("\(Self.readable(status)) \(count)")
                                        .font(.caption)
                                        .foregroundStyle(HozzPalette.inkSoft)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - Reading valence

    /// Averaged only within one kind of entry, never across both.
    private static func mean(_ entries: [IngestStore.StoredMoodEntry]) -> Double? {
        guard !entries.isEmpty else { return nil }
        return entries.reduce(0) { $0 + $1.valence } / Double(entries.count)
    }

    private static func valence(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    /// Apple's own wording for where a valence sits.
    private static func describe(_ value: Double) -> String {
        switch value {
        case ..<(-0.6): "very unpleasant"
        case ..<(-0.2): "unpleasant"
        case ..<0.2: "neutral"
        case ..<0.6: "pleasant"
        default: "very pleasant"
        }
    }

    private static func axisLabel(_ value: Double) -> String {
        switch value {
        case -1: "very unpleasant"
        case -0.5: "unpleasant"
        case 0: "neutral"
        case 0.5: "pleasant"
        case 1: "very pleasant"
        default: ""
        }
    }

    static func readable(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(
            of: #"([a-z0-9])([A-Z])"#,
            with: "$1 $2",
            options: .regularExpression
        )
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}
