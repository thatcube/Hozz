import Charts
import SwiftUI
import HozzUI
import HozzReceive

/// Electrocardiograms, with the trace actually drawn.
///
/// The single hard rule here: **an incomplete waveform is never drawn as though
/// it were whole.** The voltages arrive as separate pages and some readings are
/// partial, so a trace assembled from what happens to be present would look
/// exactly like a thirty-second recording that simply ended early — which, on a
/// chart that looks like a hospital printout, is the most convincing lie this
/// app could tell. When pages are missing, the shortfall is stated first, the
/// trace is labelled as a fragment, and the axis stops where the data does.
struct ElectrocardiogramView: View {
    let services: MacServices
    @State private var selected: IngestStore.StoredElectrocardiogram?

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: HozzMetrics.desktopListWidth)
            Divider().overlay(HozzPalette.lineSoft)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await services.loadElectrocardiograms()
            if selected == nil {
                selected = services.electrocardiograms.first
            }
        }
        // Keyed on the reading, not fired from the button.
        //
        // Setting `selected` and then starting an unstructured `Task` leaves a
        // window — at least a frame, and in practice a SQLite read plus a
        // decode of fifteen thousand points — where the header, the
        // classification and the completeness banner describe the reading just
        // clicked while the trace on screen is still the previous one's. A
        // partial waveform could be titled "Waveform", drawn in confident blue,
        // under someone else's date. That is the one thing this file exists to
        // prevent. `.task(id:)` also cancels the outgoing load, so two quick
        // clicks cannot land out of order.
        .task(id: selected?.id) {
            guard let id = selected?.id else { return }
            await services.loadWaveform(id: id)
        }
        .background(HozzSurface())
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(services.electrocardiograms) { reading in
                    Button {
                        selected = reading
                    } label: {
                        row(reading)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(HozzPalette.lineSoft)
                }
            }
        }
        .background(HozzPalette.air.opacity(0.4))
    }

    private func row(_ reading: IngestStore.StoredElectrocardiogram) -> some View {
        let chosen = selected?.id == reading.id
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(reading.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(HozzPalette.ink)
                Spacer()
                if !reading.isComplete {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(HozzPalette.inkMuted)
                }
            }
            HStack(spacing: 6) {
                Text(Self.classification(reading.classification))
                    .font(.caption2)
                    .foregroundStyle(HozzPalette.inkSoft)
                if let rate = reading.averageHeartRate {
                    Text("· \(rate.formatted(.number.precision(.fractionLength(0)))) bpm")
                        .font(.caption2)
                        .foregroundStyle(HozzPalette.inkMuted)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(chosen ? HozzPalette.blueWash : Color.clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var detail: some View {
        if let selected {
            ScrollView {
                VStack(alignment: .leading, spacing: HozzMetrics.desktopGutter) {
                    header(selected)
                    statsCard(selected)
                    traceCard(selected)
                }
                .dashboardPage()
            }
        } else {
            ContentUnavailableView(
                "No readings yet",
                systemImage: "waveform.path.ecg",
                description: Text("Received ECGs appear here.")
            )
        }
    }

    private func header(_ reading: IngestStore.StoredElectrocardiogram) -> some View {
        HozzPageHeader(
            "Electrocardiogram",
            verbatimSubtitle: reading.startDate.formatted(date: .complete, time: .shortened)
                + (reading.sourceName.map { " · \($0)" } ?? "")
        )
    }

    private func statsCard(_ reading: IngestStore.StoredElectrocardiogram) -> some View {
        Card {
            HStack(spacing: 0) {
                StatTile(
                    label: "Result",
                    value: Self.classification(reading.classification)
                )
                StatTile(
                    label: "Average rate",
                    value: reading.averageHeartRate
                        .map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—",
                    unit: "bpm"
                )
                StatTile(
                    label: "Symptoms",
                    value: Self.symptoms(reading.symptomsStatus)
                )
                StatTile(
                    label: "Sampling",
                    value: reading.samplingHertz
                        .map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—",
                    unit: "Hz"
                )
                StatTile(
                    label: "Measurements",
                    value: reading.heldVoltages.formatted(.number),
                    caption: Self.completeness(reading),
                    tone: reading.isComplete ? HozzPalette.ink : HozzPalette.inkSoft
                )
            }
        }
    }

    private static func completeness(
        _ reading: IngestStore.StoredElectrocardiogram
    ) -> String {
        guard let expected = reading.expectedVoltages, expected > 0 else {
            return "expected count unavailable"
        }
        return reading.isComplete
            ? "all \(expected.formatted(.number)) held"
            : "of \(expected.formatted(.number)) recorded"
    }

    private func traceCard(
        _ reading: IngestStore.StoredElectrocardiogram
    ) -> some View {
        Card(
            verbatimTitle: waveformTitle,
            verbatimSubtitle: waveformSubtitle(reading)
        ) {
            if let waveform = services.waveform {
                if waveform.points.isEmpty {
                    Text("No voltages yet.")
                        .font(.callout)
                        .foregroundStyle(HozzPalette.inkMuted)
                        .frame(height: 200)
                } else {
                    if !waveform.isComplete {
                        incompleteBanner(waveform)
                    }
                    ECGTrace(
                        points: waveform.points,
                        isComplete: waveform.isComplete
                    )
                    .frame(height: 230)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
    }

    private var waveformTitle: String {
        guard let waveform = services.waveform else {
            return "Waveform"
        }
        // The title itself says which of the two things this is, because it is
        // the first thing read and the last thing remembered.
        return waveform.isComplete ? "Waveform" : "Partial waveform"
    }

    private func waveformSubtitle(
        _ reading: IngestStore.StoredElectrocardiogram
    ) -> String {
        guard let waveform = services.waveform else {
            return "Loading measurements."
        }
        guard let expected = waveform.expected, expected > 0 else {
            return "Expected count unavailable; completeness is unknown."
        }
        if waveform.isComplete {
            let seconds = Double(waveform.points.count)
                / (reading.samplingHertz ?? 512)
            return "Complete · \(expected.formatted(.number)) measurements · "
                + "about \(seconds.formatted(.number.precision(.fractionLength(0)))) seconds"
        }
        return "\(waveform.points.count.formatted(.number)) of "
            + "\(expected.formatted(.number)) measurements · fragment, not a short recording"
    }

    private func incompleteBanner(_ waveform: IngestStore.Waveform) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(HozzPalette.warning)
            Text(
                "Incomplete—missing measurements can change the trace's shape."
            )
            .font(.caption)
            .foregroundStyle(HozzPalette.inkSoft)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HozzPalette.warningWash)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    static func classification(_ raw: String?) -> String {
        switch raw {
        case "sinusRhythm": "Sinus rhythm"
        case "atrialFibrillation": "Atrial fibrillation"
        case "inconclusiveLowHeartRate": "Inconclusive — low rate"
        case "inconclusiveHighHeartRate": "Inconclusive — high rate"
        case "inconclusivePoorReading": "Inconclusive — poor reading"
        case "inconclusiveOther": "Inconclusive"
        case "unrecognized", nil: "Not classified"
        case .some(let other): other
        }
    }

    static func symptoms(_ raw: String?) -> String {
        switch raw {
        case "present": "Reported"
        case "none": "None reported"
        case "notSet", nil: "Not answered"
        case .some(let other): other
        }
    }
}

/// The trace itself.
///
/// Drawn with `Chart` over a decimated copy of the points: a thirty-second
/// reading is about 15,000 measurements, and asking Swift Charts for 15,000
/// marks costs seconds of main-thread time to draw detail finer than a pixel.
/// Decimation keeps the extremes of each pixel column, so the R wave — the tall
/// spike that is the whole point of looking — stays exactly as tall as it was.
struct ECGTrace: View {
    let points: [IngestStore.VoltagePoint]
    let isComplete: Bool

    /// Roughly two samples per horizontal pixel on a wide window.
    private static let targetColumns = 900

    private struct Reduced: Identifiable {
        let id: Int
        let seconds: Double
        let low: Double
        let high: Double
    }

    private var reduced: [Reduced] {
        guard points.count > Self.targetColumns * 2 else {
            return points.enumerated().map {
                Reduced(
                    id: $0.offset,
                    seconds: $0.element.secondsSinceStart,
                    low: $0.element.volts,
                    high: $0.element.volts
                )
            }
        }
        let stride = max(points.count / Self.targetColumns, 1)
        var result: [Reduced] = []
        result.reserveCapacity(points.count / stride + 1)
        var index = 0
        var column = 0
        while index < points.count {
            let end = min(index + stride, points.count)
            let slice = points[index..<end]
            let volts = slice.map(\.volts)
            result.append(
                Reduced(
                    id: column,
                    seconds: slice[slice.startIndex].secondsSinceStart,
                    low: volts.min() ?? 0,
                    high: volts.max() ?? 0
                )
            )
            index = end
            column += 1
        }
        return result
    }

    var body: some View {
        let data = reduced
        Chart(data) { point in
            // A vertical extent per column rather than a line through means:
            // the peaks of a heartbeat are the signal, and averaging them away
            // would flatten exactly what somebody is looking for.
            RectangleMark(
                x: .value("Seconds", point.seconds),
                yStart: .value("Low", point.low),
                yEnd: .value("High", point.high),
                width: .fixed(1.2)
            )
            .foregroundStyle(isComplete ? HozzPalette.blue : HozzPalette.inkMuted)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: 5)) { value in
                AxisGridLine().foregroundStyle(HozzPalette.lineSoft)
                AxisValueLabel {
                    if let seconds = value.as(Double.self) {
                        Text("\(Int(seconds))s")
                            .foregroundStyle(HozzPalette.inkMuted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(HozzPalette.lineSoft)
                AxisValueLabel().foregroundStyle(HozzPalette.inkMuted)
            }
        }
        .chartYAxisLabel("µV", alignment: .leading)
        // The axis stops where the measurements stop. Padding a fragment out
        // to thirty seconds would draw a recording that flatlined.
        .chartXScale(domain: 0...(data.last?.seconds ?? 1))
        .chartPlotStyle { plot in
            plot.background(HozzPalette.air.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
