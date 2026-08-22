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
                        exportAction: model.exportNow
                    )

                    if let result = model.result {
                        CompletedExportCard(result: result)
                    }

                    if let partialFileURL = model.partialFileURL {
                        PartialExportCard(fileURL: partialFileURL)
                    }

                    ExportScopeCard()
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
    let exportAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "heart.text.square.fill")
                .font(.largeTitle)
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 8) {
                Text("Export Apple Health")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)

                Text(statusText)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.82))
            }

            if case .exporting(let progress) = state {
                ProgressView(
                    value: Double(progress.completedTypes),
                    total: Double(max(progress.totalTypes, 1))
                )
                .tint(.white)

                Text("\(progress.recordCount) records · \(progress.completedTypes) of \(progress.totalTypes) types")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.78))
            }

            Button(action: exportAction) {
                HStack {
                    if isWorking {
                        ProgressView()
                            .tint(HozzPalette.ink)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Text(buttonTitle)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(HozzPalette.ink)
            .disabled(!healthDataAvailable || isWorking)
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
        case .exporting(let progress):
            progress.currentType.isEmpty
                ? "Preparing your export…"
                : "Reading \(progress.currentType)…"
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
