import Foundation
import HozzHealth
import HozzStore
import Observation
import SwiftUI

@MainActor
@Observable
final class ExportViewModel {
    struct ExportStep: Identifiable {
        let id: String
        let name: String
        let recordCount: Int
        let state: HealthExportTypeState
    }

    struct ProgressPresentation {
        let export: HealthExportProgress
        let steps: [ExportStep]
        let exportStartedAt: Date
        let currentTypeStartedAt: Date
        let estimatedRemainingSeconds: ClosedRange<TimeInterval>?
        let estimateCapturedAt: Date?
    }

    struct ResumableSummary: Equatable {
        let runID: UUID
        let recordCount: Int
        let startedAt: Date
    }

    enum State {
        case idle(resumable: ResumableSummary?)
        case requestingAccess
        case exporting(ProgressPresentation)
        case paused(HealthExportPause)
        case ready(HealthExportResult)
        case failed(String)
    }

    private(set) var state: State = .idle(resumable: nil)
    private(set) var exportFormat: HealthExportFormat = .ndjson

    @ObservationIgnored private var exporter: HealthKitManualExporter?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private let activityGuard = ExportActivityGuard()
    @ObservationIgnored private let makeExporter: @Sendable () throws -> HealthKitManualExporter
    @ObservationIgnored private var exportStartedAt: Date?
    @ObservationIgnored private var currentTypeStartedAt: Date?
    @ObservationIgnored private var currentTypeIdentifier: String?
    @ObservationIgnored private var exportSteps: [ExportStep] = []
    /// Distinguishes a pause the user asked for from one iOS forced on us. Only
    /// the latter resumes automatically when the app returns to the foreground.
    @ObservationIgnored private var pauseWasRequestedByUser = false

    init(
        makeExporter: @escaping @Sendable () throws -> HealthKitManualExporter = {
            try HealthKitManualExporter.makeDefault()
        }
    ) {
        self.makeExporter = makeExporter
    }

    var isWorking: Bool {
        switch state {
        case .requestingAccess, .exporting:
            true
        case .idle, .paused, .ready, .failed:
            false
        }
    }

    var isExporting: Bool {
        if case .exporting = state {
            return true
        }
        return false
    }

    var result: HealthExportResult? {
        guard case .ready(let result) = state else {
            return nil
        }
        return result
    }

    var resumable: ResumableSummary? {
        switch state {
        case .idle(let resumable):
            return resumable
        case .paused(let pause):
            return ResumableSummary(
                runID: pause.runID,
                recordCount: pause.recordCount,
                startedAt: exportStartedAt ?? .now
            )
        default:
            return nil
        }
    }

    // MARK: - Lifecycle

    /// Sweeps stale artifacts and surfaces any run that can still be resumed.
    func prepare() async {
        do {
            let exporter = try resolveExporter()
            try await exporter.sweepUnreferencedArtifacts()

            guard case .idle = state else {
                return
            }
            if let run = try await exporter.resumableRun() {
                state = .idle(
                    resumable: ResumableSummary(
                        runID: run.id,
                        recordCount: run.recordCount,
                        startedAt: run.startedAt
                    )
                )
                BackgroundExportScheduler.scheduleProcessing()
            } else {
                state = .idle(resumable: nil)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // The background assertion buys minutes, not hours. Checkpointing
            // now means an export that outlives its assertion resumes from the
            // last sealed part instead of starting over.
            if isExporting {
                checkpoint(requestedByUser: false)
            }
        case .active:
            // A pause the user asked for stays paused; one iOS forced on us by
            // suspending the app picks itself back up.
            if case .paused = state, !pauseWasRequestedByUser {
                exportNow()
            }
        default:
            break
        }
    }

    func selectExportFormat(_ format: HealthExportFormat) {
        guard !isWorking else {
            return
        }
        exportFormat = format
    }

    func prepareNewExport() {
        guard !isWorking else {
            return
        }
        state = .idle(resumable: nil)
        Task { await prepare() }
    }

    // MARK: - Running

    func exportNow() {
        guard !isWorking else {
            return
        }

        let format = exportFormat
        let startedAt = Date.now
        exportStartedAt = startedAt
        currentTypeStartedAt = startedAt
        currentTypeIdentifier = nil
        exportSteps = []
        pauseWasRequestedByUser = false

        activityGuard.begin { [weak self] in
            self?.checkpoint(requestedByUser: false)
        }

        exportTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.activityGuard.end()
                self.exportTask = nil
            }

            do {
                let exporter = try resolveExporter()
                state = .requestingAccess
                try await exporter.requestAuthorization()

                state = .exporting(
                    ProgressPresentation(
                        export: HealthExportProgress(
                            completedTypes: 0,
                            totalTypes: 1,
                            recordCount: 0,
                            currentTypeIdentifier: "",
                            currentTypeName: "",
                            currentTypeFamily: nil,
                            currentTypeRecordCount: 0,
                            currentTypeState: .exporting
                        ),
                        steps: [],
                        exportStartedAt: startedAt,
                        currentTypeStartedAt: startedAt,
                        estimatedRemainingSeconds: nil,
                        estimateCapturedAt: nil
                    )
                )

                let outcome = try await exporter.export(format: format) { progress in
                    await MainActor.run {
                        self.state = .exporting(self.presentation(for: progress))
                    }
                }

                switch outcome {
                case .completed(let result):
                    BackgroundExportScheduler.cancelProcessing()
                    state = .ready(result)
                case .paused(let pause):
                    BackgroundExportScheduler.scheduleProcessing()
                    state = .paused(pause)
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops the export at its next safe point and keeps everything already
    /// sealed. Nothing is discarded, so resuming costs at most one part.
    func pause() {
        checkpoint(requestedByUser: true)
    }

    private func checkpoint(requestedByUser: Bool) {
        pauseWasRequestedByUser = requestedByUser
        exportTask?.cancel()
    }

    /// Throws away a paused run and every artifact it owns.
    func discardResumableRun() {
        guard let resumable else {
            return
        }
        state = .idle(resumable: nil)

        Task { [weak self] in
            guard let self else {
                return
            }
            BackgroundExportScheduler.cancelProcessing()
            if let exporter = try? resolveExporter() {
                try? await exporter.discardRun(id: resumable.runID)
            }
            await prepare()
        }
    }

    // MARK: - Presentation

    private func resolveExporter() throws -> HealthKitManualExporter {
        if let exporter {
            return exporter
        }
        let exporter = try makeExporter()
        self.exporter = exporter
        return exporter
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
        let step = ExportStep(
            id: progress.currentTypeIdentifier,
            name: progress.currentTypeName,
            recordCount: progress.currentTypeRecordCount,
            state: progress.currentTypeState
        )
        if let index = exportSteps.firstIndex(where: { $0.id == step.id }) {
            exportSteps[index] = step
        } else if !step.id.isEmpty {
            exportSteps.append(step)
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
            steps: exportSteps,
            exportStartedAt: startedAt,
            currentTypeStartedAt: currentTypeStartedAt ?? now,
            estimatedRemainingSeconds: estimate,
            estimateCapturedAt: estimate == nil ? nil : now
        )
    }
}
