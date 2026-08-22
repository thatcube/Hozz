import BackgroundTasks
import Foundation
import HozzHealth
import os

/// Resumes a checkpointed export while the app is not in the foreground.
///
/// This is the only user of the `processing` background mode and the
/// `BGTaskSchedulerPermittedIdentifiers` entry, and it is genuinely best
/// effort: iOS decides whether and when the task runs, and the expiration
/// handler checkpoints so an unfinished attempt loses no work.
enum BackgroundExportScheduler {
    static let identifier = "com.thatcube.Hozz.processing"

    private static let log = Logger(
        subsystem: "com.thatcube.Hozz",
        category: "background"
    )

    /// Carries the non-`Sendable` `BGTask` into the task that completes it.
    ///
    /// The box is only ever read once, from the single task that owns this
    /// launch handler invocation, so there is no concurrent access to guard.
    private final class TaskBox: @unchecked Sendable {
        let task: BGTask

        init(_ task: BGTask) {
            self.task = task
        }
    }

    /// Must be called before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            handle(task)
        }
    }

    /// Asks iOS to run a catch-up pass. Only meaningful when a run is paused.
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = true

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Submission fails in the simulator and whenever a request is
            // already pending. Neither is worth surfacing to the user.
            log.debug("Background export request was not accepted.")
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }

    private static func handle(_ task: BGTask) {
        let box = TaskBox(task)
        let work = Task {
            let success = await resumePausedExport()
            box.task.setTaskCompleted(success: success)
        }

        task.expirationHandler = {
            // Cancelling makes the engine seal its open part and record a
            // checkpoint, so the next attempt resumes instead of restarting.
            work.cancel()
        }
    }

    private static func resumePausedExport() async -> Bool {
        do {
            let exporter = try HealthKitManualExporter.makeDefault()
            guard let run = try await exporter.resumableRun() else {
                return true
            }
            // Resuming in a different format would be treated as a mismatched
            // run and throw away everything already sealed, so the run's own
            // format decides.
            guard let format = HealthExportFormat(rawValue: run.format) else {
                return true
            }

            switch try await exporter.export(format: format, progress: { _ in }) {
            case .completed:
                return true
            case .paused:
                schedule()
                return false
            }
        } catch HealthExportEngineError.exportAlreadyRunning {
            // The foreground is already draining this run. Nothing to do, and
            // rescheduling would just fight it.
            return true
        } catch {
            log.error(
                "Background export stopped: \(error.localizedDescription, privacy: .public)"
            )
            schedule()
            return false
        }
    }
}
