import Foundation
import HozzHealth
import Observation

@MainActor
@Observable
final class ExportViewModel {
    enum State {
        case idle
        case requestingAccess
        case exporting(HealthExportProgress)
        case ready(HealthExportResult)
        case failed(String, partialFileURL: URL?)
    }

    private let exporter: HealthKitManualExporter
    private(set) var state: State = .idle

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

    func exportNow() {
        guard !isWorking else {
            return
        }

        Task { [self] in
            do {
                state = .requestingAccess
                try await exporter.requestAuthorization()

                state = .exporting(
                    HealthExportProgress(
                        completedTypes: 0,
                        totalTypes: 1,
                        recordCount: 0,
                        currentType: ""
                    )
                )
                let result = try await exporter.export { progress in
                    await MainActor.run {
                        self.state = .exporting(progress)
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
}
