import Foundation
import HozzStore

/// Removes Health-derived artifacts that no run still needs.
///
/// Two rules keep a plaintext or compressed Health dump from lingering:
///
/// - Any spool file no run references is deleted. That covers crashes, which
///   leave an unsealed part behind.
/// - Only the newest finished run keeps its joined artifact. Older finished
///   runs are deleted outright, so history does not accumulate on the device.
///
/// A file is never deleted while its run is still resumable or is the newest
/// finished run, which is what a `ShareLink` may still be offering.
public enum ExportSpoolSweeper {
    @discardableResult
    public static func sweep(store: HozzStore) async throws -> Int {
        var removed = 0
        let spool = await store.spoolDirectory
        let runs = try await store.allRuns()

        let finished = runs
            .filter { $0.state.isTerminal }
            .sorted { $0.startedAt > $1.startedAt }
        for stale in finished.dropFirst() {
            for part in try await store.parts(runID: stale.id) {
                if remove(spool.appending(path: part.fileName)) {
                    removed += 1
                }
            }
            try await store.deleteRun(id: stale.id)
        }

        let referenced = try await store.referencedFileNames()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: spool,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in contents where !referenced.contains(file.lastPathComponent) {
            if remove(file) {
                removed += 1
            }
        }

        removed += removeLegacyTemporaryExports()
        return removed
    }

    /// Deletes exports written by the pre-store implementation, which staged
    /// them in the temporary directory and only cleaned up on the next export.
    private static func removeLegacyTemporaryExports() -> Int {
        let legacy = FileManager.default.temporaryDirectory
            .appending(path: "Hozz", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: legacy.path) else {
            return 0
        }
        return remove(legacy) ? 1 : 0
    }

    @discardableResult
    private static func remove(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}
