import Foundation
import HozzCore
import HozzStore

public enum SpooledExportSinkError: Error, LocalizedError, Equatable, Sendable {
    case staleBaseAnchor(type: String)
    case sinkClosed

    public var errorDescription: String? {
        switch self {
        case .staleBaseAnchor(let type):
            "Hozz refused to advance the cursor for \(type) because it moved underneath the drain."
        case .sinkClosed:
            "The export sink is no longer accepting writes."
        }
    }
}

/// Writes drained changes into a run's spool and advances cursors only once
/// those bytes are durable.
///
/// The durability rule is the whole point of this type:
///
/// - `commit` appends to the *open* part and stages the anchor in memory.
/// - Anchors reach the store only inside ``seal()``, after the part has been
///   flushed, closed, and its size recorded, in one store transaction.
/// - An open part is not durable, so on relaunch it is deleted and every type
///   it touched replays from its last sealed anchor.
///
/// The consequence is that a crash, a kill, or a reboot can duplicate work but
/// can never duplicate a record in the output and can never skip one.
public actor SpooledExportSink: DurableHealthChangeSink {
    /// Uncompressed bytes buffered into one part before it is sealed. Smaller
    /// parts cost more seals; larger parts cost more replay after a kill. At
    /// roughly half a kilobyte per record this checkpoints every 20–40 seconds
    /// of a large export, so an interruption rarely costs more than that.
    public static let defaultPartByteBudget = 16 * 1_024 * 1_024
    public static let defaultPartRecordBudget = 50_000

    private struct OpenPart {
        let sequence: Int
        let fileName: String
        let url: URL
        let output: any ExportOutput
        var recordCount = 0
        var byteCount = 0

        init(sequence: Int, fileName: String, url: URL, output: any ExportOutput) {
            self.sequence = sequence
            self.fileName = fileName
            self.url = url
            self.output = output
        }
    }

    private let store: HozzStore
    private let runID: UUID
    private let format: HealthExportFormat
    private let spoolDirectory: URL
    private let encoder: HealthSampleEncoder
    private let partByteBudget: Int
    private let partRecordBudget: Int

    private var openPart: OpenPart?
    private var nextSequence: Int
    private var pending: [HealthTypeKey: PendingAnchorCommit] = [:]
    private var storedAnchors: [HealthTypeKey: AnchorToken?] = [:]
    private var totalRecordCount: Int
    private var isClosed = false

    public init(
        store: HozzStore,
        runID: UUID,
        format: HealthExportFormat,
        spoolDirectory: URL,
        nextSequence: Int,
        totalRecordCount: Int,
        encoder: HealthSampleEncoder = HealthSampleEncoder(),
        partByteBudget: Int = SpooledExportSink.defaultPartByteBudget,
        partRecordBudget: Int = SpooledExportSink.defaultPartRecordBudget
    ) {
        self.store = store
        self.runID = runID
        self.format = format
        self.spoolDirectory = spoolDirectory
        self.encoder = encoder
        self.nextSequence = nextSequence
        self.totalRecordCount = totalRecordCount
        self.partByteBudget = partByteBudget
        self.partRecordBudget = partRecordBudget
    }

    public var recordCount: Int {
        totalRecordCount
    }

    public var hasOpenPart: Bool {
        openPart != nil
    }

    public var pendingAnchorCount: Int {
        pending.count
    }

    // MARK: - DurableHealthChangeSink

    public func committedAnchor(for type: HealthTypeKey) async throws -> AnchorToken? {
        if let staged = pending[type] {
            return staged.anchor
        }
        return try await storedAnchor(for: type)
    }

    public func commit(
        _ batch: HealthChangeBatch,
        for type: HealthTypeKey,
        baseAnchor: AnchorToken?
    ) async throws {
        guard !isClosed else {
            throw SpooledExportSinkError.sinkClosed
        }

        let effective = try await committedAnchor(for: type)
        guard effective == baseAnchor else {
            throw SpooledExportSinkError.staleBaseAnchor(type: type.rawValue)
        }

        var part = try await openPartForWriting()
        var written = 0
        var bytes = 0

        do {
            for change in batch.changes {
                let payload: Data = switch change {
                case .upsert(let object):
                    object.canonicalPayload
                case .delete(let deletion):
                    try encoder.encodeDeletion(
                        id: deletion.id,
                        typeIdentifier: deletion.type.rawValue
                    )
                }
                try part.output.write(payload)
                try part.output.write(Data([0x0A]))
                written += 1
                bytes += payload.count + 1
            }
        } catch {
            // A half-written page has bytes in the part but no staged anchor.
            // Sealing it would ship those records and then hand them out again
            // on replay, so the whole part is thrown away instead.
            await discardOpenPart()
            throw error
        }

        part.recordCount += written
        part.byteCount += bytes
        openPart = part
        totalRecordCount += written

        stage(
            type: type,
            baseAnchor: baseAnchor,
            anchor: batch.proposedAnchor,
            addedRecords: written,
            addedObserved: batch.changes.count,
            coverage: .draining
        )

        if part.byteCount >= partByteBudget || part.recordCount >= partRecordBudget {
            try await seal()
        }
    }

    public func markAnchorClosed(
        type: HealthTypeKey,
        anchor: AnchorToken,
        observedChangeCount: Int,
        hadPriorAnchor: Bool,
        at date: Date
    ) async throws {
        _ = hadPriorAnchor
        // HealthKit cannot distinguish a denied type from an empty one, so a
        // stream that closed without ever returning an object stays
        // indeterminate rather than claiming it was fully read.
        let observedForType = (pending[type]?.addedObservedCount ?? 0)
            + (try await storedRecord(for: type)?.observedCount ?? 0)
        let coverage: CoverageState = observedForType == 0
            ? .authorizationIndeterminate
            : .anchorClosed

        if var staged = pending[type] {
            staged = PendingAnchorCommit(
                type: type,
                baseAnchor: staged.baseAnchor,
                anchor: anchor,
                coverage: coverage,
                addedRecordCount: staged.addedRecordCount,
                addedObservedCount: staged.addedObservedCount,
                anchorClosedAt: date
            )
            pending[type] = staged
        } else {
            pending[type] = PendingAnchorCommit(
                type: type,
                baseAnchor: try await storedAnchor(for: type),
                anchor: anchor,
                coverage: coverage,
                addedRecordCount: 0,
                addedObservedCount: 0,
                anchorClosedAt: date
            )
        }
    }

    // MARK: - Records that are not Health objects

    /// Writes a run-level record such as the manifest or a per-type summary.
    public func writeRecord(_ object: [String: any Sendable]) async throws {
        guard !isClosed else {
            throw SpooledExportSinkError.sinkClosed
        }
        var part = try await openPartForWriting()
        let data = try JSONSerialization.data(
            withJSONObject: object as [String: Any],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try part.output.write(data)
        try part.output.write(Data([0x0A]))
        part.byteCount += data.count + 1
        openPart = part
    }

    /// Records a type that failed without advancing its cursor.
    public func recordFailure(
        type: HealthTypeKey,
        coverage: CoverageState,
        reason: String
    ) async throws {
        try await store.recordCoverage(
            scope: .run(runID),
            type: type,
            coverage: coverage,
            failureReason: reason
        )
    }

    // MARK: - Durability

    /// Flushes and closes the open part, then commits its staged anchors in a
    /// single store transaction.
    ///
    /// This is the only operation that advances a durable cursor. Staged
    /// anchors are taken and cleared before the store round trip, so a failure
    /// leaves the part open in the store — it is discarded on resume and its
    /// work replays. Anchors are never committed without the part that holds
    /// their bytes.
    public func seal() async throws {
        guard let part = openPart else {
            // Anything staged without an open part belongs to a seal that
            // failed. Those bytes are not durable, so the cursors stay put.
            pending.removeAll()
            return
        }

        openPart = nil
        let sealing = pending.values.sorted { $0.type < $1.type }
        pending.removeAll()

        let summary = try part.output.finish()
        try StoreLocation.harden(part.url)
        try await store.sealPart(
            runID: runID,
            sequence: part.sequence,
            byteCount: summary.compressedByteCount,
            uncompressedByteCount: summary.uncompressedByteCount,
            crc32: summary.crc32,
            recordCount: part.recordCount,
            commits: sealing,
            runRecordCount: totalRecordCount
        )

        for commit in sealing {
            storedAnchors[commit.type] = commit.anchor
        }
    }

    /// Abandons the open part without committing anything staged into it.
    ///
    /// The bytes were never durable, so the affected types simply replay from
    /// their last sealed cursor.
    public func discardOpenPart() async {
        guard let part = openPart else {
            pending.removeAll()
            return
        }

        part.output.abandon()
        try? FileManager.default.removeItem(at: part.url)
        totalRecordCount -= part.recordCount
        _ = try? await store.discardOpenParts(runID: runID)
        pending.removeAll()
        openPart = nil
    }

    public func close() async {
        isClosed = true
    }

    private func stage(
        type: HealthTypeKey,
        baseAnchor: AnchorToken?,
        anchor: AnchorToken,
        addedRecords: Int,
        addedObserved: Int,
        coverage: CoverageState
    ) {
        if let existing = pending[type] {
            pending[type] = PendingAnchorCommit(
                type: type,
                baseAnchor: existing.baseAnchor,
                anchor: anchor,
                coverage: coverage,
                addedRecordCount: existing.addedRecordCount + addedRecords,
                addedObservedCount: existing.addedObservedCount + addedObserved,
                anchorClosedAt: nil
            )
        } else {
            pending[type] = PendingAnchorCommit(
                type: type,
                baseAnchor: baseAnchor,
                anchor: anchor,
                coverage: coverage,
                addedRecordCount: addedRecords,
                addedObservedCount: addedObserved,
                anchorClosedAt: nil
            )
        }
    }

    private func storedAnchor(for type: HealthTypeKey) async throws -> AnchorToken? {
        if let cached = storedAnchors[type] {
            return cached
        }
        let anchor = try await store.committedAnchor(scope: .run(runID), type: type)
        storedAnchors[type] = anchor
        return anchor
    }

    private func storedRecord(for type: HealthTypeKey) async throws -> StreamRecord? {
        try await store.streamRecord(scope: .run(runID), type: type)
    }

    private func openPartForWriting() async throws -> OpenPart {
        if let openPart {
            return openPart
        }

        let sequence = nextSequence
        nextSequence += 1
        let fileName = Self.partFileName(
            runID: runID,
            sequence: sequence,
            format: format
        )
        let url = spoolDirectory.appending(path: fileName)

        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.protectionKey: StoreLocation.protection]
        ) else {
            throw HealthKitManualExporterError.cannotCreateExport
        }
        try StoreLocation.harden(url)

        // Every compressed format shares one spool representation: deflated
        // NDJSON. Only the final assembly differs.
        let output: any ExportOutput = switch format {
        case .ndjson, .csv, .json, .markdown, .sqlite, .gpx:
            try DeflateExportOutput(fileURL: url)
        case .raw:
            try RawExportOutput(fileURL: url)
        }

        _ = try await store.createPart(
            runID: runID,
            sequence: sequence,
            fileName: fileName
        )
        let part = OpenPart(
            sequence: sequence,
            fileName: fileName,
            url: url,
            output: output
        )
        openPart = part
        return part
    }

    public static func partFileName(
        runID: UUID,
        sequence: Int,
        format: HealthExportFormat
    ) -> String {
        let padded = String(format: "%04d", sequence)
        return "hozz-export-\(runID.uuidString.lowercased())-part-\(padded).\(format.partFileExtension)"
    }
}
