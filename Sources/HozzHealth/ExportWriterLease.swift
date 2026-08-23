import Foundation

/// Guarantees that only one thing writes a run's spool at a time.
///
/// The foreground UI, the `BGProcessingTask` handler, and automatic sync each
/// build their own store and engine, but they run in the same process, so a
/// process-wide lease is enough. Without it two of them could resume the same
/// run, pick the same next part sequence, and unlink each other's open file —
/// a hazard SQLite's stale anchor checks cannot catch, because it happens on
/// the filesystem.
///
/// Two things here are answers to a real report rather than preference.
/// Someone opened Hozz, pressed Export, and was told an export was already
/// running when nothing they could see was running.
///
/// The lease now says **who** holds it, because "an export is already running"
/// was not even true: what held it was an automatic sync, started by opening
/// the app. Naming the wrong activity is worse than saying nothing, because it
/// sends someone looking for an export that does not exist.
///
/// And a caller can **wait** for it rather than being refused. Refusing was
/// technically correct and practically useless: the person cannot see the run,
/// cannot tell how long it has left, and a Try again button gives them no way
/// to know whether trying again could ever work. Waiting is what they meant by
/// pressing the button.
public actor ExportWriterLease {
    public static let shared = ExportWriterLease()

    /// What holds the lease, in words that can be shown to someone.
    public enum Owner: String, Sendable {
        case manualExport
        case automaticSync

        /// Written for the person waiting, not for a log.
        public var activityDescription: String {
            switch self {
            case .manualExport:
                "An export is already running."
            case .automaticSync:
                "Hozz is sending health data to your destinations."
            }
        }
    }

    private var holder: Owner?
    private var waiters: [Waiter] = []

    private struct Waiter {
        let id: UUID
        let owner: Owner
        let resume: @Sendable (Bool) -> Void
    }

    public init() {}

    /// Who holds the lease, if anyone.
    public var currentHolder: Owner? {
        holder
    }

    /// Takes the lease, or returns `false` immediately if it is held.
    public func acquire(for owner: Owner = .manualExport) -> Bool {
        guard holder == nil else {
            return false
        }
        holder = owner
        return true
    }

    /// Takes the lease, waiting for it if something else holds it.
    ///
    /// Returns `false` only if the wait ran out or the caller was cancelled,
    /// so a refusal still means something rather than being the ordinary
    /// answer to pressing a button a second too early.
    public func acquire(
        for owner: Owner,
        waitingUpTo timeout: Duration
    ) async -> Bool {
        if acquire(for: owner) {
            return true
        }

        let id = UUID()
        let timeout = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.giveUpWaiting(id: id)
        }
        defer { timeout.cancel() }

        let handedOver = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(
                    Waiter(id: id, owner: owner) { continuation.resume(returning: $0) }
                )
            }
        } onCancel: {
            Task { [weak self] in await self?.giveUpWaiting(id: id) }
        }

        guard handedOver else {
            return false
        }
        // The lease was handed over directly rather than left free, so it is
        // already ours. If we were cancelled in the meantime it has to go
        // back, or it would be held by a caller that has given up.
        if Task.isCancelled {
            release()
            return false
        }
        return true
    }

    /// Stops waiting, because the wait ran out or the caller was cancelled.
    ///
    /// Resumed rather than dropped: an abandoned continuation leaves its task
    /// suspended forever. A waiter already handed the lease by `release` is no
    /// longer in the queue, so this correctly does nothing.
    private func giveUpWaiting(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).resume(false)
    }

    public func release() {
        guard !waiters.isEmpty else {
            holder = nil
            return
        }
        // Handed straight to the next waiter instead of being freed and
        // re-acquired. In between the two the lease would be free, and a
        // caller that never waited could take it, so the person who waited
        // longest would be refused in favour of the one who just arrived.
        let next = waiters.removeFirst()
        holder = next.owner
        next.resume(true)
    }
}
