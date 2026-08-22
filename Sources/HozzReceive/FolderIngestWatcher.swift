import Foundation
import HozzCore
import os

/// Ingests batches the phone writes to a folder.
///
/// This is the path that works everywhere. Receiving over the local network is
/// faster, but it asks the network to cooperate — and networks frequently do
/// not. A router may isolate clients from each other, a corporate profile or a
/// firewall may drop inbound connections to an unrecognised app, a phone may be
/// on cellular or a guest VLAN, and none of that is something the user can
/// reasonably be asked to fix.
///
/// A folder asks nothing of the network. The phone writes a file, the file
/// arrives however the user already syncs files — iCloud Drive, Dropbox, a
/// shared volume — and this notices and reads it. It works from anywhere, on
/// any connection, with no ports, no addresses and no permissions.
public actor FolderIngestWatcher {
    private static let log = Logger(
        subsystem: "com.thatcube.Hozz",
        category: "folder"
    )

    /// Extensions the phone writes.
    private static let readable: Set<String> = ["ndjson", "json", "csv"]

    private let store: IngestStore
    private var folder: URL?
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    /// Files already read, so a folder that is rescanned does not re-ingest.
    private var seen: Set<String> = []
    private var observers: [@Sendable (ReceiverEvent) -> Void] = []

    public init(store: IngestStore) {
        self.store = store
    }

    public func onEvent(_ observer: @escaping @Sendable (ReceiverEvent) -> Void) {
        observers.append(observer)
    }

    public var watchedFolder: URL? {
        folder
    }

    /// Starts watching a folder, reading anything already in it.
    public func start(folder: URL) async {
        await stop()
        self.folder = folder

        // Read what is already there first. A folder chosen after the phone has
        // been syncing for a while is the normal case, not the exception.
        await ingestNewFiles()

        descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Self.log.error("Could not watch the chosen folder.")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { await self?.ingestNewFiles() }
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    public func stop() async {
        source?.cancel()
        source = nil
        descriptor = -1
        folder = nil
        seen.removeAll()
    }

    /// Reads every file that has appeared since the last pass.
    func ingestNewFiles() async {
        guard let folder else {
            return
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []

        for name in names.sorted() {
            guard !seen.contains(name),
                  Self.readable.contains((name as NSString).pathExtension.lowercased())
            else {
                continue
            }
            let url = folder.appending(path: name)

            // A file still being written, or still downloading from iCloud, is
            // skipped rather than half-read. It will be picked up on the next
            // pass once it has settled.
            guard Self.isSettled(url) else {
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                continue
            }

            do {
                let batch = try BatchParser.parse(data)
                // The file name is the idempotency key: the phone names each
                // batch uniquely, so a folder read twice cannot double the
                // data.
                let result = try await store.ingest(batch, idempotencyKey: name)
                seen.insert(name)
                emit(
                    ReceiverEvent(
                        outcome: result.duplicate
                            ? .duplicate
                            : .stored(records: result.stored, deleted: result.deleted)
                    )
                )
            } catch is BatchParseError {
                seen.insert(name)
            } catch {
                Self.log.error("A file in the watched folder could not be read.")
                seen.insert(name)
                emit(ReceiverEvent(outcome: .rejected("A file could not be read")))
            }
        }
    }

    /// Whether a file has finished being written or downloaded.
    private static func isSettled(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .isUbiquitousItemKey,
            .contentModificationDateKey
        ])
        // An iCloud placeholder has no contents yet; reading it returns nothing
        // and would mark the batch as seen without storing anything.
        if values?.isUbiquitousItem == true,
           values?.ubiquitousItemDownloadingStatus != .current {
            return false
        }
        // A file written moments ago may still be growing.
        if let modified = values?.contentModificationDate,
           Date().timeIntervalSince(modified) < 1 {
            return false
        }
        return true
    }

    private func emit(_ event: ReceiverEvent) {
        for observer in observers {
            observer(event)
        }
    }
}
