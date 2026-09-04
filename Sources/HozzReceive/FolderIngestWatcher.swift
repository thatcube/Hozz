import CryptoKit
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
    private static let defaultAuditFileLimit = 8
    private static let defaultAuditReadByteLimit: UInt64 = 16 * 1_024 * 1_024

    private let store: IngestStore
    private var folder: URL?
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var retryTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var retryDelayMilliseconds: Int64 = 1_100
    private var failedSnapshots: [String: ObservedFile] = [:]
    private var attemptedSnapshots: [String: FileIdentity] = [:]
    /// The content generation last read at each name.
    private var seen: [String: ObservedFile] = [:]
    private var generationlessAuditCursor: String?
    private var generationlessAuditStates:
        [String: GenerationlessAuditState] = [:]
    private var isReconciling = false
    private var priorityReconciliationRequested = false
    private var auditReconciliationRequested = false
    private var observers: [@Sendable (ReceiverEvent) -> Void] = []
    private let didVerifySnapshot: (@Sendable (URL) -> Void)?
    private let reconciliationInterval: Duration
    private let generationIdentifierProvider: @Sendable (URL) -> Data?
    private let observesDirectoryChanges: Bool
    private let generationlessAuditFileLimit: Int
    private let generationlessAuditReadByteLimit: UInt64
    private let didCompleteGenerationlessAudit:
        (@Sendable (Int, UInt64) async -> Void)?

    public init(store: IngestStore) {
        self.store = store
        self.didVerifySnapshot = nil
        self.reconciliationInterval = .seconds(5)
        self.generationIdentifierProvider = Self.contentGenerationIdentifier
        self.observesDirectoryChanges = true
        self.generationlessAuditFileLimit = Self.defaultAuditFileLimit
        self.generationlessAuditReadByteLimit =
            Self.defaultAuditReadByteLimit
        self.didCompleteGenerationlessAudit = nil
    }

    init(
        store: IngestStore,
        reconciliationInterval: Duration = .seconds(5),
        didVerifySnapshot: (@Sendable (URL) -> Void)? = nil,
        generationIdentifierProvider: (@Sendable (URL) -> Data?)? = nil,
        observesDirectoryChanges: Bool = true,
        generationlessAuditFileLimit: Int = defaultAuditFileLimit,
        generationlessAuditReadByteLimit: UInt64 = defaultAuditReadByteLimit,
        didCompleteGenerationlessAudit:
            (@Sendable (Int, UInt64) async -> Void)? = nil
    ) {
        self.store = store
        self.didVerifySnapshot = didVerifySnapshot
        self.reconciliationInterval = reconciliationInterval
        self.generationIdentifierProvider =
            generationIdentifierProvider ?? Self.contentGenerationIdentifier
        self.observesDirectoryChanges = observesDirectoryChanges
        self.generationlessAuditFileLimit = max(
            1,
            generationlessAuditFileLimit
        )
        self.generationlessAuditReadByteLimit = max(
            1,
            generationlessAuditReadByteLimit
        )
        self.didCompleteGenerationlessAudit =
            didCompleteGenerationlessAudit
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

        // Arm before the first scan. A file arriving while that scan is running
        // then leaves a pending event instead of falling into a scan-to-watch
        // gap and waiting indefinitely for some unrelated later write.
        if observesDirectoryChanges {
            armDirectory(folder)
        }
        startPeriodicReconciliation()

        // Read what is already there first. A folder chosen after the phone has
        // been syncing for a while is the normal case, not the exception.
        await ingestNewFiles(auditGenerationless: false)
    }

    private func armDirectory(_ folder: URL) {
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
            Task { await self?.directoryDidChange() }
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
        retryTask?.cancel()
        retryTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil
        retryDelayMilliseconds = 1_100
        failedSnapshots.removeAll()
        attemptedSnapshots.removeAll()
        generationlessAuditCursor = nil
        generationlessAuditStates.removeAll()
        priorityReconciliationRequested = false
        auditReconciliationRequested = false
        folder = nil
        seen.removeAll()
    }

    /// Directory events only reconcile work the directory can identify cheaply.
    /// Generation-less content audits stay on their bounded periodic cadence, so
    /// a burst of ignored NOTE_WRITE events cannot multiply full-file reads.
    func directoryDidChange() async {
        await ingestNewFiles(auditGenerationless: false)
    }

    /// Reads every new or changed file, plus one bounded audit slice when asked.
    private func ingestNewFiles(auditGenerationless: Bool) async {
        guard !isReconciling else {
            if auditGenerationless {
                auditReconciliationRequested = true
            } else {
                priorityReconciliationRequested = true
            }
            return
        }
        isReconciling = true
        defer { finishReconciliationPass() }

        guard let folder else {
            return
        }
        let names = (
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path))
                ?? []
        ).filter {
            Self.readable.contains(
                ($0 as NSString).pathExtension.lowercased()
            )
        }.sorted()
        let namesOnDisk = Set(names)
        seen = seen.filter { namesOnDisk.contains($0.key) }
        failedSnapshots = failedSnapshots.filter {
            namesOnDisk.contains($0.key)
        }
        attemptedSnapshots = attemptedSnapshots.filter {
            namesOnDisk.contains($0.key)
        }
        generationlessAuditStates = generationlessAuditStates.filter {
            namesOnDisk.contains($0.key)
        }

        var priority: [FileCandidate] = []
        var generationlessAudit: [FileCandidate] = []
        for name in names {
            let url = folder.appending(path: name)
            guard let observedGeneration = generation(of: url) else {
                scheduleRetry(backingOff: true)
                continue
            }
            let candidate = FileCandidate(
                name: name,
                url: url,
                generation: observedGeneration
            )
            // A failed replacement is the current observation. Letting an
            // older success win here sends the same unchanged malformed file
            // down the unbounded priority path on every pass.
            let prior = failedSnapshots[name] ?? seen[name]
            if observedGeneration.contentGeneration != nil,
               prior?.generation == observedGeneration {
                continue
            }
            if observedGeneration.contentGeneration == nil,
               prior?.generation == observedGeneration {
                generationlessAudit.append(candidate)
            } else {
                generationlessAuditStates.removeValue(forKey: name)
                priority.append(candidate)
            }
        }

        // New files and files whose metadata changed are never held behind the
        // audit budget.
        for candidate in priority {
            await inspect(candidate)
        }

        // A volume without generation identifiers cannot prove unchanged bytes
        // from metadata. Audit a rotating bounded slice so silent same-size,
        // same-mtime rewrites are eventually found without rereading the whole
        // archive every five seconds.
        if auditGenerationless {
            let audit = await runGenerationlessAudit(
                candidates: generationlessAudit
            )
            if let didCompleteGenerationlessAudit {
                await didCompleteGenerationlessAudit(
                    audit.files,
                    audit.readBytes
                )
            }
        }
    }

    private func inspect(_ candidate: FileCandidate) async {
        let name = candidate.name
        let url = candidate.url
        // A file still being written, or still downloading from iCloud, is
        // skipped rather than half-read. It will be picked up on the next pass
        // once it has settled.
        guard Self.isSettled(url) else {
            scheduleRetry()
            return
        }
        guard let snapshot = stableSnapshot(of: url) else {
            scheduleRetry()
            return
        }
        await process(
            snapshot,
            named: name,
            at: url,
            verifyAfterCommit: true
        )
    }

    private func process(
        _ snapshot: StableFileSnapshot,
        named name: String,
        at url: URL,
        verifyAfterCommit: Bool
    ) async {
        if failedSnapshots[name]?.identity == snapshot.identity {
            failedSnapshots[name] = ObservedFile(snapshot)
            return
        }
        failedSnapshots.removeValue(forKey: name)
        if seen[name]?.identity == snapshot.identity {
            seen[name] = ObservedFile(snapshot)
            return
        }
        if attemptedSnapshots[name] != snapshot.identity {
            retryDelayMilliseconds = 1_100
        }
        attemptedSnapshots[name] = snapshot.identity

        do {
            let batch = try BatchParser.parse(snapshot.data)
            didVerifySnapshot?(url)
            let result = try await store.ingest(
                batch,
                idempotencyKey: snapshot.identity.idempotencyKey,
                legacyIdempotencyKeys: [name]
            )
            finish(
                snapshot,
                named: name,
                at: url,
                verifyAfterCommit: verifyAfterCommit
            )
            emit(
                ReceiverEvent(
                    outcome: result.duplicate
                        ? .duplicate
                        : .stored(
                            records: result.stored,
                            deleted: result.deleted
                        )
                )
            )
        } catch BatchParseError.connectionTest {
            finish(
                snapshot,
                named: name,
                at: url,
                verifyAfterCommit: verifyAfterCommit
            )
        } catch is BatchParseError {
            Self.log.error("A file in the watched folder could not be read.")
            emit(ReceiverEvent(outcome: .rejected("A file could not be read")))
            if !verifyAfterCommit {
                failedSnapshots[name] = ObservedFile(snapshot)
            } else if let current = stableSnapshot(of: url),
                      current.identity == snapshot.identity {
                failedSnapshots[name] = ObservedFile(current)
            }
            scheduleRetry()
        } catch {
            Self.log.error(
                "A file in the watched folder could not be stored yet."
            )
            emit(
                ReceiverEvent(
                    outcome: .rejected("A file could not be stored yet")
                )
            )
            scheduleRetry(backingOff: true)
        }
    }

    private func runGenerationlessAudit(
        candidates: [FileCandidate]
    ) async -> FileAuditResult {
        guard !candidates.isEmpty else {
            return FileAuditResult(files: 0, readBytes: 0)
        }
        var ordered = rotatedAuditCandidates(candidates)
        if let activeName = generationlessAuditStates.keys.sorted().first,
           let activeIndex = ordered.firstIndex(where: {
               $0.name == activeName
           }) {
            let active = ordered.remove(at: activeIndex)
            ordered.insert(active, at: 0)
        }

        var files = 0
        var readBytes: UInt64 = 0
        for candidate in ordered {
            guard
                files < generationlessAuditFileLimit,
                readBytes < generationlessAuditReadByteLimit
            else {
                break
            }
            let remaining = generationlessAuditReadByteLimit - readBytes
            let advance = await advanceGenerationlessAudit(
                candidate,
                maximumReadBytes: remaining
            )
            files += 1
            readBytes += advance.readBytes
            if advance.advancesCursor {
                generationlessAuditCursor = candidate.name
            }
            if !advance.isComplete {
                break
            }
        }
        return FileAuditResult(files: files, readBytes: readBytes)
    }

    private func rotatedAuditCandidates(
        _ candidates: [FileCandidate]
    ) -> [FileCandidate] {
        let sorted = candidates.sorted { $0.name < $1.name }
        guard
            let cursor = generationlessAuditCursor,
            let next = sorted.firstIndex(where: { $0.name > cursor })
        else {
            return sorted
        }
        return Array(sorted[next...]) + Array(sorted[..<next])
    }

    private func advanceGenerationlessAudit(
        _ candidate: FileCandidate,
        maximumReadBytes: UInt64
    ) async -> FileAuditAdvance {
        guard maximumReadBytes > 0 else {
            return FileAuditAdvance(
                readBytes: 0,
                isComplete: false,
                advancesCursor: false
            )
        }
        guard Self.isSettled(candidate.url) else {
            scheduleRetry()
            return FileAuditAdvance(
                readBytes: 0,
                isComplete: true,
                advancesCursor: true
            )
        }

        var state = generationlessAuditStates[candidate.name]
            ?? GenerationlessAuditState(generation: candidate.generation)
        guard state.generation == candidate.generation else {
            generationlessAuditStates.removeValue(forKey: candidate.name)
            scheduleRetry()
            return FileAuditAdvance(
                readBytes: 0,
                isComplete: true,
                advancesCursor: true
            )
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: candidate.url)
        } catch {
            generationlessAuditStates.removeValue(forKey: candidate.name)
            scheduleRetry(backingOff: true)
            return FileAuditAdvance(
                readBytes: 0,
                isComplete: true,
                advancesCursor: true
            )
        }
        defer { try? handle.close() }

        var remaining = maximumReadBytes
        var readBytes: UInt64 = 0
        while remaining > 0 {
            guard generation(of: candidate.url) == state.generation else {
                generationlessAuditStates.removeValue(forKey: candidate.name)
                scheduleRetry()
                return FileAuditAdvance(
                    readBytes: readBytes,
                    isComplete: true,
                    advancesCursor: true
                )
            }
            do {
                try handle.seek(toOffset: state.offset)
                let request = Int(
                    min(remaining, GenerationlessAuditState.chunkBytes)
                )
                let chunk = try handle.read(upToCount: request) ?? Data()
                if !chunk.isEmpty {
                    state.hasher.update(data: chunk)
                    if state.phase == .verification {
                        state.verifiedData.append(chunk)
                    }
                    let count = UInt64(chunk.count)
                    state.offset += count
                    remaining -= count
                    readBytes += count
                }

                let reachedExpectedEnd = state.generation.size.map {
                    state.offset >= $0
                } ?? false
                guard chunk.isEmpty || reachedExpectedEnd else {
                    continue
                }

                let digest = Data(state.hasher.finalize())
                switch state.phase {
                case .fingerprint:
                    state.beginVerification(firstDigest: digest)
                    if remaining == 0 {
                        generationlessAuditStates[candidate.name] = state
                        return FileAuditAdvance(
                            readBytes: readBytes,
                            isComplete: false,
                            advancesCursor: false
                        )
                    }
                case .verification:
                    guard
                        state.firstDigest == digest,
                        generation(of: candidate.url) == state.generation
                    else {
                        generationlessAuditStates.removeValue(
                            forKey: candidate.name
                        )
                        return FileAuditAdvance(
                            readBytes: readBytes,
                            isComplete: true,
                            advancesCursor: true
                        )
                    }
                    generationlessAuditStates.removeValue(
                        forKey: candidate.name
                    )
                    let snapshot = StableFileSnapshot(
                        data: state.verifiedData,
                        generation: state.generation,
                        identity: FileIdentity(
                            digest: Self.hexDigest(digest)
                        )
                    )
                    await process(
                        snapshot,
                        named: candidate.name,
                        at: candidate.url,
                        // The incremental second pass is the stable
                        // verification. A same-metadata mutation during commit
                        // is found by the next rotating audit.
                        verifyAfterCommit: false
                    )
                    return FileAuditAdvance(
                        readBytes: readBytes,
                        isComplete: true,
                        advancesCursor: true
                    )
                }
            } catch {
                generationlessAuditStates.removeValue(forKey: candidate.name)
                scheduleRetry(backingOff: true)
                return FileAuditAdvance(
                    readBytes: readBytes,
                    isComplete: true,
                    advancesCursor: true
                )
            }
        }

        generationlessAuditStates[candidate.name] = state
        return FileAuditAdvance(
            readBytes: readBytes,
            isComplete: false,
            advancesCursor: false
        )
    }

    private func finishReconciliationPass() {
        isReconciling = false
        let shouldAudit = auditReconciliationRequested
        let shouldReconcilePriority = priorityReconciliationRequested
        auditReconciliationRequested = false
        priorityReconciliationRequested = false
        guard shouldAudit || shouldReconcilePriority else {
            return
        }
        Task { [weak self] in
            await self?.ingestNewFiles(
                auditGenerationless: shouldAudit
            )
        }
    }

    private func finish(
        _ snapshot: StableFileSnapshot,
        named name: String,
        at url: URL,
        verifyAfterCommit: Bool
    ) {
        seen[name] = ObservedFile(snapshot)
        failedSnapshots.removeValue(forKey: name)
        attemptedSnapshots.removeValue(forKey: name)
        retryDelayMilliseconds = 1_100

        guard verifyAfterCommit else {
            if generation(of: url) != snapshot.generation {
                scheduleRetry()
            }
            return
        }

        // The path can change while the store transaction is committing. The
        // bytes just committed are safe, but the new generation still needs a
        // pass of its own.
        if let current = stableSnapshot(of: url),
           current.identity == snapshot.identity {
            seen[name] = ObservedFile(current)
        } else {
            scheduleRetry()
        }
    }

    private func scheduleRetry(backingOff: Bool = false) {
        guard retryTask == nil else { return }
        let delay = backingOff ? retryDelayMilliseconds : 1_100
        if backingOff {
            retryDelayMilliseconds = min(retryDelayMilliseconds * 2, 60_000)
        }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            await self?.runScheduledRetry()
        }
    }

    private func runScheduledRetry() async {
        retryTask = nil
        await ingestNewFiles(auditGenerationless: false)
    }

    private func startPeriodicReconciliation() {
        let interval = reconciliationInterval
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                guard let self else {
                    return
                }
                await self.ingestNewFiles(auditGenerationless: true)
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

    private func stableSnapshot(of url: URL) -> StableFileSnapshot? {
        guard
            let before = generation(of: url),
            let first = try? Data(contentsOf: url),
            generation(of: url) == before,
            let verification = try? Data(contentsOf: url),
            verification == first,
            generation(of: url) == before
        else {
            return nil
        }
        let digest = Self.hexDigest(Data(SHA256.hash(data: first)))
        return StableFileSnapshot(
            data: first,
            generation: before,
            identity: FileIdentity(digest: digest)
        )
    }

    private static func hexDigest(_ digest: Data) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func generation(of url: URL) -> FileGeneration? {
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ]) else {
            return nil
        }
        return FileGeneration(
            size: values.fileSize.map(UInt64.init),
            modified: values.contentModificationDate,
            resourceIdentifier: values.fileResourceIdentifier as? Data,
            contentGeneration: generationIdentifierProvider(url)
        )
    }

    private static func contentGenerationIdentifier(of url: URL) -> Data? {
        let values = try? url.resourceValues(
            forKeys: [.generationIdentifierKey]
        )
        return values?.generationIdentifier as? Data
    }

    private func emit(_ event: ReceiverEvent) {
        for observer in observers {
            observer(event)
        }
    }
}

private struct FileGeneration: Equatable {
    let size: UInt64?
    let modified: Date?
    let resourceIdentifier: Data?
    let contentGeneration: Data?
}

private struct FileCandidate {
    let name: String
    let url: URL
    let generation: FileGeneration
}

private struct FileAuditResult {
    let files: Int
    let readBytes: UInt64
}

private struct FileAuditAdvance {
    let readBytes: UInt64
    let isComplete: Bool
    let advancesCursor: Bool
}

private struct GenerationlessAuditState {
    enum Phase {
        case fingerprint
        case verification
    }

    static let chunkBytes: UInt64 = 256 * 1_024

    let generation: FileGeneration
    var phase = Phase.fingerprint
    var offset: UInt64 = 0
    var hasher = SHA256()
    var firstDigest: Data?
    var verifiedData = Data()

    mutating func beginVerification(firstDigest: Data) {
        phase = .verification
        offset = 0
        hasher = SHA256()
        self.firstDigest = firstDigest
        verifiedData.removeAll(keepingCapacity: true)
        if let size = generation.size, size <= UInt64(Int.max) {
            verifiedData.reserveCapacity(Int(size))
        }
    }
}

private struct FileIdentity: Equatable {
    let digest: String

    var idempotencyKey: String {
        "folder-v2:\(digest)"
    }
}

private struct ObservedFile: Equatable {
    let generation: FileGeneration
    let identity: FileIdentity

    init(_ snapshot: StableFileSnapshot) {
        generation = snapshot.generation
        identity = snapshot.identity
    }
}

private struct StableFileSnapshot {
    let data: Data
    let generation: FileGeneration
    let identity: FileIdentity
}
