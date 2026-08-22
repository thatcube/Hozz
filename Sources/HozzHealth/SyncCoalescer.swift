import Foundation
import HozzCore
import os

/// Collapses a burst of Health observer callbacks into a single sync pass.
///
/// This exists because of how HealthKit actually behaves. Hozz subscribes to
/// dozens of types, and they do not report new data one at a time: when a Watch
/// finishes syncing, or the phone is unlocked after a night of recording,
/// HealthKit fires many observers at once. Handing each callback its own sync
/// would start dozens of full passes that all contend for the same writer
/// lease, each re-reading every type, for one logical change in the data.
///
/// The coalescer turns that burst into one pass:
///
/// 1. The first request starts a short quiet window rather than syncing
///    immediately, so the rest of the burst arrives before any work begins.
/// 2. Requests during that window are absorbed — they do not extend it and do
///    not queue another pass.
/// 3. Requests that arrive *while a pass is running* are not lost. Exactly one
///    further pass runs afterwards, however many arrived.
///
/// Point 3 is the reason this is not a plain debounce. Data recorded during a
/// sync would otherwise sit undelivered until something else happened to
/// trigger a pass, which for a quiet type could be a very long time.
public actor SyncCoalescer {
    private static let log = Logger(
        subsystem: "com.thatcube.Hozz",
        category: "coalescer"
    )

    public typealias Operation = @Sendable (Set<HealthTypeKey>) async -> Void
    public typealias Sleep = @Sendable (Duration) async -> Void

    /// How long to wait for a burst to settle before syncing.
    ///
    /// Long enough to absorb a Watch sync, short enough to stay well inside the
    /// few seconds of runtime iOS grants a background delivery wake-up.
    public static let defaultQuietWindow: Duration = .seconds(3)

    private let quietWindow: Duration
    private let operation: Operation
    private let sleep: Sleep

    private var pendingTypes: Set<HealthTypeKey> = []
    private var hasPendingRequest = false
    private var worker: Task<Void, Never>?

    public init(
        quietWindow: Duration = SyncCoalescer.defaultQuietWindow,
        sleep: @escaping Sleep = { try? await Task.sleep(for: $0) },
        operation: @escaping Operation
    ) {
        self.quietWindow = quietWindow
        self.operation = operation
        self.sleep = sleep
    }

    /// Records that new data arrived and ensures a pass will run.
    ///
    /// Returns immediately. Observer callbacks owe iOS an answer within
    /// seconds, so they must never wait for a sync to finish.
    public func request(types: Set<HealthTypeKey> = []) {
        pendingTypes.formUnion(types)
        hasPendingRequest = true
        guard worker == nil else {
            // A pass is already scheduled or running. It will pick this up.
            return
        }
        worker = Task { [weak self] in
            await self?.drainRequests()
        }
    }

    /// Runs any outstanding request now, and waits for it to finish.
    ///
    /// Used by the background refresh task, which has a real deadline and
    /// cannot afford the quiet window.
    public func flush() async {
        guard hasPendingRequest else {
            return
        }
        hasPendingRequest = false
        let types = pendingTypes
        pendingTypes.removeAll()
        await operation(types)
    }

    /// Stops any scheduled pass. A pass already running is left to finish.
    public func cancel() {
        worker?.cancel()
        worker = nil
        hasPendingRequest = false
        pendingTypes.removeAll()
    }

    /// True while a pass is scheduled or running.
    public var isActive: Bool {
        worker != nil
    }

    private func drainRequests() async {
        // Clearing `worker` here rather than at every exit keeps the invariant
        // "worker != nil means a pass is coming" true for `request`.
        defer { worker = nil }

        while hasPendingRequest {
            await sleep(quietWindow)
            if Task.isCancelled {
                return
            }
            // Claim the current batch before running, so requests arriving
            // during the operation are seen as new work rather than folded
            // into the pass that is already reading from the cursor.
            hasPendingRequest = false
            let types = pendingTypes
            pendingTypes.removeAll()

            await operation(types)
            // Looping re-checks `hasPendingRequest`, which is set again if
            // anything arrived while the operation was running.
        }
    }
}
