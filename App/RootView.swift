import HozzHealth
import SwiftUI

struct RootView: View {
    @State private var model: ExportViewModel
    private let healthDataAvailable: Bool

    init(healthDataAvailable: Bool = HealthKitAvailability.isAvailable) {
        self.healthDataAvailable = healthDataAvailable
        _model = State(initialValue: ExportViewModel())
    }

    var body: some View {
        NavigationStack {
            switch model.state {
            case .idle, .requestingAccess:
                ExportSetupView(
                    healthDataAvailable: healthDataAvailable,
                    isRequestingAccess: model.isWorking,
                    exportFormat: model.exportFormat,
                    selectExportFormat: model.selectExportFormat,
                    exportAction: model.exportNow
                )
            case .exporting(let presentation):
                ExportSessionView(
                    presentation: presentation,
                    exportFormat: model.exportFormat
                )
            case .ready(let result):
                ExportReadyView(
                    result: result,
                    newExportAction: model.prepareNewExport
                )
            case .failed(let message, let partialFileURL):
                ExportFailureView(
                    message: message,
                    partialFileURL: partialFileURL,
                    tryAgainAction: model.prepareNewExport
                )
            }
        }
        .tint(HozzPalette.action)
    }
}

private struct ExportSetupView: View {
    let healthDataAvailable: Bool
    let isRequestingAccess: Bool
    let exportFormat: HealthExportFormat
    let selectExportFormat: (HealthExportFormat) -> Void
    let exportAction: () -> Void

    var body: some View {
        Form {
            Section {
                SetupIntroduction()

                if !healthDataAvailable {
                    Label(
                        "Apple Health is unavailable or restricted on this device.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("File") {
                Picker(
                    "Format",
                    selection: Binding(
                        get: { exportFormat },
                        set: { format in
                            selectExportFormat(format)
                        }
                    )
                ) {
                    Text("Compressed (.ndjson.gz)")
                        .tag(HealthExportFormat.gzip)
                    Text("Raw (.ndjson)")
                        .tag(HealthExportFormat.raw)
                }

                Label(
                    exportFormat == .gzip
                        ? "Compressed is usually 80–95% smaller and opens with Finder."
                        : "Raw files open directly but can be several gigabytes.",
                    systemImage: exportFormat == .gzip ? "archivebox" : "doc.plaintext"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Current coverage") {
                CoverageRow("Quantity and category samples", available: true)
                CoverageRow("Correlations and basic workouts", available: true)
                CoverageRow("Historical deletions", available: true)
                CoverageRow(
                    "Routes, ECG, audiograms, series, and clinical records",
                    available: false
                )
            }

            Section {
                Link("Source code", destination: HozzLinks.source)
                Link("Support development", destination: HozzLinks.sponsors)
                Link("More free apps", destination: HozzLinks.developer)
            }
        }
        .navigationTitle("Hozz")
        .safeAreaInset(edge: .bottom) {
            Button(action: exportAction) {
                HStack {
                    if isRequestingAccess {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Text(isRequestingAccess ? "Waiting for Health access" : "Export now")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!healthDataAvailable || isRequestingAccess)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

private struct SetupIntroduction: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "heart.text.square.fill")
                .font(.largeTitle)
                .foregroundStyle(HozzPalette.action)

            Text("Export Apple Health")
                .font(.largeTitle.bold())

            Text("Choose your Health access, then save a file directly from this device.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .listRowBackground(Color.clear)
    }
}

private struct CoverageRow: View {
    let title: LocalizedStringResource
    let available: Bool

    init(_ title: LocalizedStringResource, available: Bool) {
        self.title = title
        self.available = available
    }

    var body: some View {
        Label(
            title,
            systemImage: available ? "checkmark.circle.fill" : "clock.badge.exclamationmark"
        )
        .foregroundStyle(available ? .primary : .secondary)
        .symbolRenderingMode(.hierarchical)
    }
}

private struct ExportSessionView: View {
    let presentation: ExportViewModel.ProgressPresentation
    let exportFormat: HealthExportFormat

    var body: some View {
        VStack(spacing: 0) {
            ExportSessionHeader(
                presentation: presentation,
                exportFormat: exportFormat
            )
            ExportStepList(
                steps: presentation.steps,
                currentTypeStartedAt: presentation.currentTypeStartedAt
            )
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Exporting")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ExportSessionSummary(
                    presentation: presentation,
                    now: context.date
                )
            }
        }
    }
}

private struct ExportSessionHeader: View {
    let presentation: ExportViewModel.ProgressPresentation
    let exportFormat: HealthExportFormat

    var body: some View {
        let progress = presentation.export

        VStack(spacing: 10) {
            ProgressView(
                value: Double(progress.completedTypes),
                total: Double(max(progress.totalTypes, 1))
            )

            ViewThatFits(in: .horizontal) {
                HStack {
                    progressLabel
                    Spacer()
                    formatLabel
                }

                VStack(alignment: .leading, spacing: 6) {
                    progressLabel
                    formatLabel
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var progressLabel: some View {
        Text(
            "\(presentation.export.completedTypes) of "
            + "\(presentation.export.totalTypes) data types"
        )
        .font(.subheadline.weight(.semibold))
    }

    private var formatLabel: some View {
        Label(
            exportFormat == .gzip ? "Compressed" : "Raw",
            systemImage: exportFormat == .gzip
                ? "archivebox.fill"
                : "doc.plaintext.fill"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

private struct ExportStepList: View {
    let steps: [ExportViewModel.ExportStep]
    let currentTypeStartedAt: Date

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(steps) { step in
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        ExportStepRow(
                            step: step,
                            currentTypeElapsed: max(
                                context.date.timeIntervalSince(currentTypeStartedAt),
                                0
                            )
                        )
                    }
                    .id(step.id)
                    .listRowBackground(
                        step.state == .exporting
                            ? HozzPalette.action.opacity(0.09)
                            : Color(uiColor: .secondarySystemGroupedBackground)
                    )
                }
            }
            .listStyle(.insetGrouped)
            .onAppear {
                scrollToCurrent(using: proxy, animated: false)
            }
            .onChange(of: steps.last?.id) {
                scrollToCurrent(using: proxy, animated: true)
            }
        }
    }

    private func scrollToCurrent(
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let id = steps.last?.id else {
            return
        }

        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

private struct ExportStepRow: View {
    let step: ExportViewModel.ExportStep
    let currentTypeElapsed: TimeInterval

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(step.name)
                    .font(.body.weight(step.state == .exporting ? .semibold : .regular))

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.state {
        case .exporting:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var detail: String {
        switch step.state {
        case .exporting:
            "\(step.recordCount.formatted()) records · \(durationLabel(currentTypeElapsed))"
        case .completed:
            step.recordCount == 0
                ? "No records returned"
                : "\(step.recordCount.formatted()) records"
        case .failed:
            "Could not finish this data type"
        }
    }
}

private struct ExportSessionSummary: View {
    let presentation: ExportViewModel.ProgressPresentation
    let now: Date

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                recordMetric

                Divider()
                    .frame(height: 30)

                elapsedMetric

                if let estimate = remainingEstimate {
                    Divider()
                        .frame(height: 30)

                    SummaryMetric(
                        value: etaLabel(estimate),
                        label: "Estimated left"
                    )
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                recordMetric
                elapsedMetric

                if let estimate = remainingEstimate {
                    SummaryMetric(
                        value: etaLabel(estimate),
                        label: "Estimated left"
                    )
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var recordMetric: some View {
        SummaryMetric(
            value: presentation.export.recordCount.formatted(),
            label: "Records"
        )
    }

    private var elapsedMetric: some View {
        SummaryMetric(
            value: durationLabel(exportElapsed),
            label: "Elapsed"
        )
    }

    private var exportElapsed: TimeInterval {
        max(now.timeIntervalSince(presentation.exportStartedAt), 0)
    }

    private var remainingEstimate: ClosedRange<TimeInterval>? {
        guard
            let estimate = presentation.estimatedRemainingSeconds,
            let capturedAt = presentation.estimateCapturedAt
        else {
            return nil
        }

        let elapsed = max(now.timeIntervalSince(capturedAt), 0)
        let lower = max(estimate.lowerBound - elapsed, 0)
        let upper = max(estimate.upperBound - elapsed, 0)
        return upper > 0 ? lower...upper : nil
    }

    private func etaLabel(_ estimate: ClosedRange<TimeInterval>) -> String {
        let lower = durationLabel(estimate.lowerBound, rounding: .up)
        let upper = durationLabel(estimate.upperBound, rounding: .up)
        return lower == upper ? upper : "\(lower)–\(upper)"
    }
}

private struct SummaryMetric: View {
    let value: String
    let label: LocalizedStringResource

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ExportReadyView: View {
    let result: HealthExportResult
    let newExportAction: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(
                systemName: hasErrors
                    ? "exclamationmark.circle.fill"
                    : "checkmark.circle.fill"
            )
                .font(.system(size: 64))
                .foregroundStyle(hasErrors ? .orange : .green)

            VStack(spacing: 8) {
                Text(hasErrors ? "Export ready with warnings" : "Export ready")
                    .font(.largeTitle.bold())
                Text(
                    "\(result.recordCount.formatted()) records · "
                    + Int64(clamping: result.fileByteCount)
                        .formatted(.byteCount(style: .file))
                )
                .foregroundStyle(.secondary)
            }

            DisclosureGroup("Export details") {
                VStack(spacing: 10) {
                    LabeledContent(
                        "Types with records",
                        value: result.nonEmptyTypeCount.formatted()
                    )
                    LabeledContent(
                        "No records returned",
                        value: result.zeroResultTypeCount.formatted()
                    )

                    if result.failedTypeCount > 0 {
                        LabeledContent(
                            "Types that failed",
                            value: result.failedTypeCount.formatted()
                        )
                    }

                    if result.sampleEncodingErrorCount > 0 {
                        LabeledContent(
                            "Samples that failed",
                            value: result.sampleEncodingErrorCount.formatted()
                        )
                    }
                }
                .font(.subheadline)
                .padding(.top, 8)
            }
            .padding()
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )

            ShareLink(item: result.fileURL) {
                Label("Save or share export", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("New export", action: newExportAction)

            Spacer()
        }
        .padding(24)
        .navigationTitle("Hozz")
    }

    private var hasErrors: Bool {
        result.failedTypeCount > 0 || result.sampleEncodingErrorCount > 0
    }
}

private struct ExportFailureView: View {
    let message: String
    let partialFileURL: URL?
    let tryAgainAction: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Export stopped", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            if let partialFileURL {
                ShareLink("Save partial export", item: partialFileURL)
                    .buttonStyle(.borderedProminent)
            }
            Button("Try again", action: tryAgainAction)
        }
        .navigationTitle("Hozz")
    }
}

private func durationLabel(
    _ seconds: TimeInterval,
    rounding: FloatingPointRoundingRule = .down
) -> String {
    guard seconds >= 60 else {
        return "<1 min"
    }

    let minutes = Int((seconds / 60).rounded(rounding))
    guard minutes >= 60 else {
        return "\(minutes) min"
    }

    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
}

private enum HozzLinks {
    static let source = URL(string: "https://github.com/thatcube/hozz")!
    static let sponsors = URL(string: "https://github.com/sponsors/thatcube")!
    static let developer = URL(string: "https://github.com/thatcube")!
}

enum HozzPalette {
    static let action = Color(red: 0.00, green: 0.45, blue: 0.48)
}
