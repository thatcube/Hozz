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
    /// Identifies the worker that owns the current registration.
    ///
    /// `worker` alone is not enough: after a cancel-then-request, an older
    /// drain finishing would clear the *newer* worker's slot, letting a third
    /// drain start alongside it.
    private var workerGeneration = 0
    /// True while `operation` is actually executing, so nothing starts a
    /// second pass concurrently.
    private var isRunning = false

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
        startWorkerIfNeeded()
    }

    /// Runs any outstanding request now, and waits for it to finish.
    ///
    /// Used by the background refresh task, which has a real deadline and
    /// cannot afford the quiet window.
    public func flush() async {
        // A pass already running will observe anything still pending when it
        // loops, so starting a second one here would only duplicate work and
        // contend for the writer lease.
        guard !isRunning, hasPendingRequest else {
            return
        }
        // Stand the scheduled worker down, or it wakes to an empty batch and
        // runs a redundant pass after this one.
        worker?.cancel()
        worker = nil
        workerGeneration += 1
        await runPass()
        // Anything that arrived during the pass still deserves one.
        startWorkerIfNeeded()
    }

    /// Stops any scheduled pass. A pass already running is left to finish.
    public func cancel() {
        worker?.cancel()
        worker = nil
        workerGeneration += 1
        hasPendingRequest = false
        pendingTypes.removeAll()
    }

    /// True while a pass is scheduled or running.
    public var isActive: Bool {
        worker != nil || isRunning
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, hasPendingRequest else {
            return
        }
        workerGeneration += 1
        let generation = workerGeneration
        worker = Task { [weak self] in
            await self?.drainRequests(generation: generation)
        }
    }

    private func drainRequests(generation: Int) async {
        defer {
            // Only clear the registration this worker owns. A newer worker's
            // slot must survive.
            if workerGeneration == generation {
                worker = nil
            }
        }

        while hasPendingRequest {
            await sleep(quietWindow)
            // A cancel, or a flush that took over, retires this worker.
            if Task.isCancelled || workerGeneration != generation {
                return
            }
            await runPass()
        }
    }

    /// Claims the pending batch and runs exactly one pass.
    ///
    /// The batch is claimed *before* the operation runs, so work arriving
    /// during a pass is treated as new rather than folded into a pass that has
    /// already read its cursors.
    private func runPass() async {
        guard !isRunning else {
            return
        }
        hasPendingRequest = false
        let types = pendingTypes
        pendingTypes.removeAll()

        isRunning = true
        // Detached from the caller's task, so cancelling a *scheduled* pass
        // cannot tear down a pass that is already writing to the store.
        let work = Task.detached(priority: .utility) { [operation] in
            await operation(types)
        }
        await work.value
        isRunning = false
    }
}
