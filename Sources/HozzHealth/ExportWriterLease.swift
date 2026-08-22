import Foundation

/// Guarantees that only one export writes a run's spool at a time.
///
/// The foreground UI and the `BGProcessingTask` handler each build their own
/// store and engine, but they run in the same process, so a process-wide lease
/// is enough. Without it both could resume the same run, pick the same next
/// part sequence, and unlink each other's open file — a hazard SQLite's stale
/// anchor checks cannot catch, because it happens on the filesystem.
public actor ExportWriterLease {
    public static let shared = ExportWriterLease()

    private var isHeld = false

    public init() {}

    /// Takes the lease, or returns `false` if another export already holds it.
    public func acquire() -> Bool {
        guard !isHeld else {
            return false
        }
        isHeld = true
        return true
    }

    public func release() {
        isHeld = false
    }
}
