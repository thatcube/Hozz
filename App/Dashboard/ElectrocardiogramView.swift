import Charts
import HozzUI
import Observation
import SwiftUI

@MainActor
@Observable
final class ElectrocardiogramListViewModel {
    private(set) var readings: [ECGSummary] = []
    private(set) var isLoading = false
    private(set) var failure: String?

    private let reader: HealthMetricReader

    init(reader: HealthMetricReader = HealthMetricReader()) {
        self.reader = reader
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            readings = try await reader.electrocardiograms()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct ElectrocardiogramListView: View {
    @State private var model = ElectrocardiogramListViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let failure = model.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                        .hozzCard()
                } else if model.isLoading && model.readings.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 80)
                } else if model.readings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No recordings")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(HozzPalette.inkSoft)
                        Text(
                            """
                            Electrocardiograms are taken on an Apple Watch. \
                            Health does not say whether a type was declined or \
                            is simply empty.
                            """
                        )
                        .hozzCaption()
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .hozzCard()
                } else {
                    ForEach(model.readings) { reading in
                        NavigationLink {
                            ElectrocardiogramDetailView(summary: reading)
                        } label: {
                            ECGRow(reading: reading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(HozzSurface())
        .navigationTitle("Electrocardiograms")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }
}

struct ECGRow: View {
    let reading: ECGSummary

    var body: some View {
        HStack(spacing: 12) {
            HozzIconView(.activity, size: 16)
                .foregroundStyle(HozzPalette.blue)
                .frame(width: 30, height: 30)
                .background(HozzPalette.blueWash, in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(reading.classification)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(HozzPalette.ink)
                Text(
                    reading.recordedAt.formatted(
                        .dateTime.weekday(.abbreviated).day().month(.abbreviated)
                            .hour().minute()
                    )
                )
                .hozzCaption()
            }
            Spacer(minLength: 0)
            if let rate = reading.averageHeartRate {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(MetricFormat.value(rate, fractionDigits: 0))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(HozzPalette.ink)
                    Text("BPM").hozzLabel()
                }
            }
            HozzIconView(.chevronRight, size: 14)
                .foregroundStyle(HozzPalette.inkMuted)
        }
        .hozzCard(padding: 13, radius: 16)
    }
}

// MARK: - One recording

@MainActor
@Observable
final class ElectrocardiogramDetailViewModel {
    private(set) var waveform: ECGWaveform?
    private(set) var isLoading = false
    private(set) var failure: String?

    private let reader: HealthMetricReader

    init(reader: HealthMetricReader = HealthMetricReader()) {
        self.reader = reader
    }

    func load(_ summary: ECGSummary) async {
        isLoading = true
        defer { isLoading = false }
        do {
            waveform = try await reader.waveform(for: summary)
            failure = nil
        } catch {
            waveform = nil
            failure = error.localizedDescription
        }
    }
}

/// A recording's trace.
///
/// The one rule this view exists to keep: a trace that did not arrive whole is
/// never drawn as though it did. `ECGWaveform.isComplete` compares what came
/// back against what Health said the recording holds, and when they disagree
/// the shortfall is stated above the chart rather than left to be read as a
/// flat stretch of someone's heartbeat.
struct ElectrocardiogramDetailView: View {
    let summary: ECGSummary

    @State private var model = ElectrocardiogramDetailViewModel()
    /// How many columns the trace is reduced to. Roughly a phone's width in
    /// points, since more columns than pixels buys nothing and costs frames.
    private let columns = 360

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                factsCard
                waveformCard
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(HozzSurface())
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(summary) }
    }

    private var factsCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(
                summary.recordedAt.formatted(
                    .dateTime.weekday(.wide).day().month(.wide).hour().minute()
                )
            )
            .hozzLabel()
            .textCase(.uppercase)

            Text(summary.classification)
                .hozzDisplay(size: 26)
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            HStack(spacing: 16) {
                if let rate = summary.averageHeartRate {
                    fact("\(MetricFormat.value(rate, fractionDigits: 0)) bpm", "Average")
                }
                if let duration = summary.duration, duration > 0 {
                    fact("\(Int(duration.rounded()))s", "Length")
                }
                if let frequency = summary.samplingFrequencyHertz {
                    fact("\(MetricFormat.value(frequency, fractionDigits: 0)) Hz", "Sampled")
                }
            }
            .padding(.top, 7)

            Text(summary.symptoms)
                .hozzCaption()
                .padding(.top, 6)
        }
        .hozzCard()
    }

    private func fact(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(HozzPalette.ink)
            Text(label).hozzLabel()
        }
    }

    @ViewBuilder
    private var waveformCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Trace")
                .hozzLabel()
                .textCase(.uppercase)

            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let waveform = model.waveform {
                if !waveform.isComplete {
                    incompleteNote(waveform)
                }
                ECGWaveformChart(
                    envelope: ECGDecimation.envelope(waveform.points, buckets: columns),
                    isComplete: waveform.isComplete
                )
                Text("Lead I equivalent, in microvolts.")
                    .hozzCaption()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
            }
        }
        .hozzCard()
    }

    /// Said in full rather than hinted at. A partial trace looks like a
    /// complete one with a quiet stretch in it, and that is precisely the
    /// reading someone must not take from it.
    private func incompleteNote(_ waveform: ECGWaveform) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("This trace is incomplete", systemImage: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.orange)
            Text(
                """
                \(waveform.points.count.formatted()) of \
                \(waveform.expectedCount.formatted()) readings arrived. What is \
                drawn below is part of the recording, not the whole of it, and \
                must not be read as a complete heartbeat.
                """
            )
            .hozzCaption()
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The trace itself.
///
/// Drawn as an envelope — the lowest and highest reading in each column —
/// rather than as a sampled line. A QRS complex is a spike a few readings
/// wide, and taking every nth reading flattens the one feature of the trace
/// anyone looks at.
struct ECGWaveformChart: View {
    let envelope: [ECGEnvelope]
    let isComplete: Bool

    var body: some View {
        Chart {
            ForEach(envelope) { column in
                RectangleMark(
                    x: .value("Seconds", column.secondsSinceStart),
                    yStart: .value("Low", column.low),
                    yEnd: .value("High", column.high),
                    width: 1.4
                )
                .foregroundStyle(
                    isComplete ? HozzPalette.blue : HozzPalette.blue.opacity(0.45)
                )
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(HozzPalette.lineSoft)
                AxisValueLabel()
                    .font(.system(size: 9))
                    .foregroundStyle(HozzPalette.inkMuted)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(HozzPalette.lineSoft.opacity(0.6))
                AxisValueLabel()
                    .font(.system(size: 9))
                    .foregroundStyle(HozzPalette.inkMuted)
            }
        }
        .frame(height: 200)
    }
}
