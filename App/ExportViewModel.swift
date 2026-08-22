import Foundation
import HozzHealth
import Observation

@MainActor
@Observable
final class ExportViewModel {
    struct ProgressPresentation {
        let export: HealthExportProgress
        let exportStartedAt: Date
        let currentTypeStartedAt: Date
        let estimatedRemainingSeconds: ClosedRange<TimeInterval>?
        let estimateCapturedAt: Date?
    }

    enum State {
        case idle
        case requestingAccess
        case exporting(ProgressPresentation)
        case ready(HealthExportResult)
        case failed(String, partialFileURL: URL?)
    }

    private let exporter: HealthKitManualExporter
    private(set) var state: State = .idle
    private(set) var exportFormat: HealthExportFormat = .gzip
    @ObservationIgnored private var exportStartedAt: Date?
    @ObservationIgnored private var currentTypeStartedAt: Date?
    @ObservationIgnored private var currentTypeIdentifier: String?

    init(exporter: HealthKitManualExporter = HealthKitManualExporter()) {
        self.exporter = exporter
    }

    var isWorking: Bool {
        switch state {
        case .requestingAccess, .exporting:
            true
        case .idle, .ready, .failed:
            false
        }
    }

    var result: HealthExportResult? {
        guard case .ready(let result) = state else {
            return nil
        }
        return result
    }

    var partialFileURL: URL? {
        guard case .failed(_, let fileURL) = state else {
            return nil
        }
        return fileURL
    }

    func selectExportFormat(_ format: HealthExportFormat) {
        guard !isWorking else {
            return
        }
        exportFormat = format
    }

    func exportNow() {
        guard !isWorking else {
            return
        }

        Task { [self] in
            do {
                state = .requestingAccess
                try await exporter.requestAuthorization()

                let startedAt = Date.now
                exportStartedAt = startedAt
                currentTypeStartedAt = startedAt
                currentTypeIdentifier = nil
                state = .exporting(
                    ProgressPresentation(
                        export: HealthExportProgress(
                            completedTypes: 0,
                            totalTypes: 1,
                            recordCount: 0,
                            currentTypeIdentifier: "",
                            currentTypeName: "",
                            currentTypeFamily: nil,
                            currentTypeRecordCount: 0
                        ),
                        exportStartedAt: startedAt,
                        currentTypeStartedAt: startedAt,
                        estimatedRemainingSeconds: nil,
                        estimateCapturedAt: nil
                    )
                )
                let result = try await exporter.export(format: exportFormat) { progress in
                    await MainActor.run {
                        self.state = .exporting(self.presentation(for: progress))
                    }
                }
                state = .ready(result)
            } catch is CancellationError {
                state = .idle
            } catch let error as HealthKitManualExporterError {
                if case .partialExport(let fileURL, _) = error {
                    state = .failed(error.localizedDescription, partialFileURL: fileURL)
                } else {
                    state = .failed(error.localizedDescription, partialFileURL: nil)
                }
            } catch {
                state = .failed(error.localizedDescription, partialFileURL: nil)
            }
        }
    }

    private func presentation(
        for progress: HealthExportProgress,
        now: Date = .now
    ) -> ProgressPresentation {
        let startedAt = exportStartedAt ?? now
        if currentTypeIdentifier != progress.currentTypeIdentifier {
            currentTypeIdentifier = progress.currentTypeIdentifier
            currentTypeStartedAt = now
        }

        let elapsed = max(now.timeIntervalSince(startedAt), 0)
        let remainingTypes = max(progress.totalTypes - progress.completedTypes, 0)
        let estimate: ClosedRange<TimeInterval>?
        if progress.currentTypeFamily == .quantity,
           progress.completedTypes >= 100,
           remainingTypes > 0 {
            let pointEstimate =
                elapsed / Double(progress.completedTypes) * Double(remainingTypes)
            estimate = (pointEstimate * 0.5)...(pointEstimate * 3)
        } else {
            estimate = nil
        }

        return ProgressPresentation(
            export: progress,
            exportStartedAt: startedAt,
            currentTypeStartedAt: currentTypeStartedAt ?? now,
            estimatedRemainingSeconds: estimate,
            estimateCapturedAt: estimate == nil ? nil : now
        )
    }
}
