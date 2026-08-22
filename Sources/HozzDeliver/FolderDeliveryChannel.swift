import Foundation

/// Writes batches into a folder the user picked.
///
/// This is the default destination because it needs no server, no open ports,
/// and no VPN: whichever sync client the user already runs — iCloud Drive,
/// Dropbox, OneDrive, Google Drive — does the networking. It also keeps working
/// while their computer is switched off, which a push to a local receiver
/// cannot, and it avoids the plaintext-HTTP problem a LAN endpoint creates.
public struct FolderDeliveryChannel: DeliveryChannel {
    public init() {}

    public func deliver(
        _ batch: DeliveryBatch,
        to destination: Destination
    ) async throws -> DeliveryReceipt {
        guard let bookmark = destination.folderBookmark else {
            throw DeliveryError.notConfigured
        }

        var isStale = false
        let folder: URL
        do {
            folder = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw DeliveryError.folderUnavailable
        }

        // A security-scoped resource has to be claimed before use and released
        // on every path, or the process leaks its access to that folder.
        guard folder.startAccessingSecurityScopedResource() else {
            throw DeliveryError.accessDenied
        }
        defer { folder.stopAccessingSecurityScopedResource() }

        let fileName = batch.fileName()
        let target = folder.appending(path: fileName)

        var coordinationError: NSError?
        var writeError: (any Error)?
        // File coordination is what tells iCloud Drive, Dropbox, and the rest
        // that a file appeared and should be uploaded.
        NSFileCoordinator().coordinate(
            writingItemAt: target,
            options: .forReplacing,
            error: &coordinationError
        ) { url in
            do {
                try batch.payload.write(to: url, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let coordinationError {
            throw DeliveryError.transport(coordinationError.localizedDescription)
        }
        if let writeError {
            throw DeliveryError.transport(writeError.localizedDescription)
        }

        return DeliveryReceipt(
            destinationID: destination.id,
            attemptedAt: .now,
            recordCount: batch.recordCount,
            byteCount: UInt64(batch.payload.count),
            state: .delivered,
            artifactName: fileName
        )
    }
}
