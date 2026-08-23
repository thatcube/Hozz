import BackgroundTasks
import Foundation
import HozzHealth
import os

/// Runs Hozz's work while the app is not in the foreground.
///
/// Two different jobs share this file:
///
/// - A refresh task keeps automatic destinations up to date. It is scheduled
///   again after every run, because iOS only ever grants one at a time.
/// - A processing task resumes a checkpointed manual export.
///
/// Both are genuinely best effort. iOS decides whether and when they run, they
/// are given seconds rather than minutes, and Health cannot be read at all
/// while the device is locked. The expiration handlers checkpoint rather than
/// abandon, so an interrupted attempt loses nothing.
enum BackgroundExportScheduler {
    static let processingIdentifier = "com.thatcube.Hozz.processing"
    static let refreshIdentifier = "com.thatcube.Hozz.refresh"

    private static let log = Logger(
        subsystem: "com.thatcube.Hozz",
        category: "background"
    )

    /// Carries the non-`Sendable` `BGTask` into the task that completes it.
    ///
    /// The box is read once, by the single task that owns this launch handler
    /// invocation, so there is no concurrent access to guard.
    private final class TaskBox: @unchecked Sendable {
        let task: BGTask

        init(_ task: BGTask) {
            self.task = task
        }
    }

    /// Must be called before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: processingIdentifier,
            using: nil
        ) { task in
            run(task) { await resumePausedExport() }
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshIdentifier,
            using: nil
        ) { task in
            run(task) { await syncDestinations() }
        }
    }

    /// Asks iOS for another sync opportunity.
    ///
    /// Called after every run, because a task request is consumed when it
    /// fires. Without this, automatic export would happen exactly once.
    static func scheduleRefresh(after delay: TimeInterval = 15 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: delay)
        submit(request)
    }

    /// Asks iOS to finish a paused export when the phone is charging.
    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = true
        submit(request)
    }

    static func cancelProcessing() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingIdentifier)
    }

    private static func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Submission fails in the simulator and when a request is already
            // pending. Neither is worth surfacing to the user.
            log.debug("A background request was not accepted.")
        }
    }

    private static func run(
        _ task: BGTask,
        work: @escaping @Sendable () async -> Bool
    ) {
        let box = TaskBox(task)
        let running = Task {
            let success = await work()
            box.task.setTaskCompleted(success: success)
        }
        task.expirationHandler = {
            // Cancelling makes the engine checkpoint, so the next attempt
            // resumes instead of starting over.
            running.cancel()
        }
    }

    // MARK: - Work

    private static func syncDestinations() async -> Bool {
        // Always ask for the next slot first. If this run is killed part way
        // through, the schedule survives.
        scheduleRefresh()

        do {
            let services = try HozzServices()
            let outcome = try await services.sync.sync()
            if outcome.waitingForUnlock {
                log.debug("Sync deferred: the device is locked.")
                return true
            }
            return true
        } catch {
            log.error("Background sync stopped: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func resumePausedExport() async -> Bool {
        do {
            let exporter = try HealthKitManualExporter.makeDefault()
            guard let run = try await exporter.resumableRun() else {
                return true
            }
            // Resuming in a different format would discard everything already
            // sealed, so the run's own format decides.
            guard let format = HealthExportFormat(rawValue: run.format) else {
                return true
            }

            switch try await exporter.export(format: format, progress: { _ in }) {
            case .completed:
                return true
            case .paused:
                scheduleProcessing()
                return false
            }
        } catch is HealthExportEngineError {
            // Something in the foreground already owns the writer. It will
            // finish the run, and this task has no user watching it.
            return true
        } catch {
            log.error("Background export stopped: \(error.localizedDescription, privacy: .public)")
            scheduleProcessing()
            return false
        }
    }
}
