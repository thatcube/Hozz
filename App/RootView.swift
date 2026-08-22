import HozzCatalog
import HozzHealth
import SwiftUI

struct RootView: View {
    @State private var model = ExportViewModel()
    private let healthDataAvailable: Bool

    init(healthDataAvailable: Bool = HealthKitAvailability.isAvailable) {
        self.healthDataAvailable = healthDataAvailable
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ExportActionCard(
                        state: model.state,
                        healthDataAvailable: healthDataAvailable,
                        isWorking: model.isWorking,
                        exportFormat: model.exportFormat,
                        selectExportFormat: model.selectExportFormat,
                        exportAction: model.exportNow
                    )

                    if let result = model.result {
                        CompletedExportCard(result: result)
                    }

                    if let partialFileURL = model.partialFileURL {
                        PartialExportCard(fileURL: partialFileURL)
                    }

                    if !model.isWorking {
                        ExportScopeCard()
                    }
                    CompactProjectLinks()
                }
                .padding(20)
            }
            .background(HozzPalette.canvas.ignoresSafeArea())
            .navigationTitle("Hozz")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ExportActionCard: View {
    let state: ExportViewModel.State
    let healthDataAvailable: Bool
    let isWorking: Bool
    let exportFormat: HealthExportFormat
    let selectExportFormat: (HealthExportFormat) -> Void
    let exportAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "heart.text.square.fill")
                .font(.largeTitle)
                .foregroundStyle(.white)

            Text(isWorking ? "Exporting Health Data" : "Export Apple Health")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)

            if case .exporting(let presentation) = state {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ExportProgressDetails(
                        presentation: presentation,
                        now: context.date
                    )
                }
            }

            if !isWorking {
                Text(statusText)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.82))

                Menu {
                    Button {
                        selectExportFormat(.gzip)
                    } label: {
                        Label(
                            "Compressed NDJSON (.gz)",
                            systemImage: exportFormat == .gzip ? "checkmark" : "archivebox"
                        )
                    }

                    Button {
                        selectExportFormat(.raw)
                    } label: {
                        Label(
                            "Raw NDJSON",
                            systemImage: exportFormat == .raw ? "checkmark" : "doc.plaintext"
                        )
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: exportFormat == .gzip ? "archivebox" : "doc.plaintext")

                        VStack(alignment: .leading, spacing: 2) {
                            Text(formatTitle)
                                .font(.subheadline.weight(.semibold))
                            Text(formatDetail)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.68))
                        }

                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                }

                Button(action: exportAction) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text(buttonTitle)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(HozzPalette.ink)
                .disabled(!healthDataAvailable)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(
            LinearGradient(
                colors: [HozzPalette.ink, HozzPalette.deepWater],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
    }

    private var statusText: LocalizedStringResource {
        switch state {
        case .idle:
            healthDataAvailable
                ? "Choose Health access, then Hozz creates an NDJSON file on this device."
                : "Health data is unavailable on this device."
        case .requestingAccess:
            "Waiting for your Health access choices…"
        case .exporting:
            ""
        case .ready(let result):
            "Created an export with \(result.recordCount) records."
        case .failed(let message, _):
            "Export failed: \(message)"
        }
    }

    private var buttonTitle: LocalizedStringResource {
        switch state {
        case .idle, .failed:
            "Export now"
        case .requestingAccess:
            "Waiting for Health access"
        case .exporting:
            "Exporting"
        case .ready:
            "Export again"
        }
    }

    private var formatTitle: LocalizedStringResource {
        switch exportFormat {
        case .gzip:
            "Compressed (recommended)"
        case .raw:
            "Raw NDJSON"
        }
    }

    private var formatDetail: LocalizedStringResource {
        switch exportFormat {
        case .gzip:
            "Usually 80–95% smaller; opens with Finder"
        case .raw:
            "Largest file; opens directly without decompression"
        }
    }

}

private struct ExportProgressDetails: View {
    let presentation: ExportViewModel.ProgressPresentation
    let now: Date

    var body: some View {
        let progress = presentation.export

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(progress.currentTypeName.isEmpty ? "Preparing export" : progress.currentTypeName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                if progress.currentTypeFamily != nil {
                    Text("\(progress.currentTypeRecordCount.formatted()) records · \(durationLabel(currentTypeElapsed)) on this type")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.76))
                }
            }

            ProgressView(
                value: Double(progress.completedTypes),
                total: Double(max(progress.totalTypes, 1))
            )
            .tint(.white)

            HStack(spacing: 8) {
                Text("\(progress.recordCount.formatted()) total")
                Text("·")
                Text("\(progress.completedTypes)/\(progress.totalTypes) types")
                Text("·")
                Text("\(durationLabel(exportElapsed))")

                if let estimate = remainingEstimate {
                    Spacer()
                    Label(etaLabel(estimate), systemImage: "hourglass")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.78))
        }
    }

    private var exportElapsed: TimeInterval {
        max(now.timeIntervalSince(presentation.exportStartedAt), 0)
    }

    private var currentTypeElapsed: TimeInterval {
        max(now.timeIntervalSince(presentation.currentTypeStartedAt), 0)
    }

    private var remainingEstimate: ClosedRange<TimeInterval>? {
        guard
            let estimate = presentation.estimatedRemainingSeconds,
            let capturedAt = presentation.estimateCapturedAt
        else {
            return nil
        }

        let elapsedSinceEstimate = max(now.timeIntervalSince(capturedAt), 0)
        let lower = max(estimate.lowerBound - elapsedSinceEstimate, 0)
        let upper = max(estimate.upperBound - elapsedSinceEstimate, 0)
        return upper > 0 ? lower...upper : nil
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

    private func etaLabel(_ estimate: ClosedRange<TimeInterval>) -> String {
        let lower = durationLabel(estimate.lowerBound, rounding: .up)
        let upper = durationLabel(estimate.upperBound, rounding: .up)
        return lower == upper ? "About \(upper) left" : "\(lower)–\(upper) left"
    }
}

private struct CompletedExportCard: View {
    let result: HealthExportResult

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Export ready", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(HozzPalette.success)

            Text("\(result.recordCount) records across \(result.nonEmptyTypeCount) types that returned data.")
                .font(.body)

            Text("\(formatTitle) · \(Int64(clamping: result.fileByteCount).formatted(.byteCount(style: .file)))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            if result.zeroResultTypeCount > 0 {
                Text("\(result.zeroResultTypeCount) types returned no records. iOS does not reveal whether those types were empty or denied.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if result.failedTypeCount > 0 || result.sampleEncodingErrorCount > 0 {
                Text("\(result.failedTypeCount) types and \(result.sampleEncodingErrorCount) individual samples reported errors in the export file.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            ShareLink(item: result.fileURL) {
                Label("Save or share export", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(HozzPalette.action)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HozzPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var formatTitle: String {
        switch result.format {
        case .gzip:
            "Compressed NDJSON"
        case .raw:
            "Raw NDJSON"
        }
    }
}

private struct PartialExportCard: View {
    let fileURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Partial export preserved", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("The file includes everything written before the unexpected failure.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ShareLink(item: fileURL) {
                Label("Save partial export", systemImage: "square.and.arrow.up")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HozzPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct ExportScopeCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Current export coverage")
                .font(.headline)

            Label("Quantity, category, and correlation samples", systemImage: "checkmark")
            Label("Basic workout records and workout events", systemImage: "checkmark")
            Label("Historical drain and deletion tombstones", systemImage: "checkmark")
            Label("Workout statistics, routes, series, ECG, audiograms, and clinical records are not in this build yet", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(HozzPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct CompactProjectLinks: View {
    var body: some View {
        HStack {
            Link("Source", destination: URL(string: "https://github.com/thatcube/hozz")!)
            Spacer()
            Link("Donate", destination: URL(string: "https://github.com/sponsors/thatcube")!)
            Spacer()
            Link("More apps", destination: URL(string: "https://github.com/thatcube")!)
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 8)
    }
}

enum HozzPalette {
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let ink = Color(red: 0.04, green: 0.15, blue: 0.20)
    static let deepWater = Color(red: 0.02, green: 0.38, blue: 0.42)
    static let action = Color(red: 0.00, green: 0.45, blue: 0.48)
    static let success = Color(red: 0.12, green: 0.58, blue: 0.38)
}

#Preview {
    RootView(healthDataAvailable: true)
}

#Preview("Exporting") {
    ExportActionCard(
        state: .exporting(
            ExportViewModel.ProgressPresentation(
                export: HealthExportProgress(
                    completedTypes: 73,
                    totalTypes: 194,
                    recordCount: 1_042_819,
                    currentTypeIdentifier: "HKQuantityTypeIdentifierActiveEnergyBurned",
                    currentTypeName: "Active Energy Burned",
                    currentTypeFamily: .quantity,
                    currentTypeRecordCount: 614_292
                ),
                exportStartedAt: .now.addingTimeInterval(-184),
                currentTypeStartedAt: .now.addingTimeInterval(-71),
                estimatedRemainingSeconds: 132...396,
                estimateCapturedAt: .now
            )
        ),
        healthDataAvailable: true,
        isWorking: true,
        exportFormat: .gzip,
        selectExportFormat: { _ in },
        exportAction: {}
    )
    .padding()
    .background(HozzPalette.canvas)
}
