import UIKit

/// Keeps a long export alive while the user is not looking at it.
///
/// Two separate things are needed and both are released on every exit path:
///
/// - The idle timer is disabled so the screen does not sleep mid-export, which
///   is the most likely way a real multi-minute export gets interrupted.
/// - A background task assertion buys extra running time when the screen does
///   turn off or the user switches apps. iOS grants only a few minutes, so the
///   expiration handler checkpoints rather than abandoning the work.
@MainActor
final class ExportActivityGuard {
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var isHoldingIdleTimer = false

    var isActive: Bool {
        backgroundTask != .invalid || isHoldingIdleTimer
    }

    /// - Parameter onExpiration: Invoked when iOS is about to reclaim the
    ///   assertion. It must checkpoint quickly; it must not start new work.
    func begin(onExpiration: @escaping @MainActor () -> Void) {
        guard !isActive else {
            return
        }

        UIApplication.shared.isIdleTimerDisabled = true
        isHoldingIdleTimer = true

        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "com.thatcube.Hozz.export"
        ) { [weak self] in
            onExpiration()
            self?.end()
        }
    }

    func end() {
        if isHoldingIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = false
            isHoldingIdleTimer = false
        }
        guard backgroundTask != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    deinit {
        // `end()` is main-actor isolated and a deinit cannot await, so the
        // assertion is released on the main actor without capturing `self`.
        // This is a backstop: every normal exit path already calls `end()`.
        if backgroundTask != .invalid {
            let identifier = backgroundTask
            Task { @MainActor in
                UIApplication.shared.endBackgroundTask(identifier)
            }
        }
        if isHoldingIdleTimer {
            Task { @MainActor in
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
}
