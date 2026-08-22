import Foundation
import HozzAcquire
import HozzCatalog
import HozzCore
import HozzDeliver
import HozzStore
import os

/// The result of one automatic sync pass.
public struct SyncOutcome: Equatable, Sendable {
    public let deliveredRecords: Int
    public let destinationCount: Int
    public let typesDrained: Int
    public let wasInterrupted: Bool
    public let waitingForUnlock: Bool

    public init(
        deliveredRecords: Int,
        destinationCount: Int,
        typesDrained: Int,
        wasInterrupted: Bool,
        waitingForUnlock: Bool
    ) {
        self.deliveredRecords = deliveredRecords
        self.destinationCount = destinationCount
        self.typesDrained = typesDrained
        self.wasInterrupted = wasInterrupted
        self.waitingForUnlock = waitingForUnlock
    }

    public static let idle = SyncOutcome(
        deliveredRecords: 0,
        destinationCount: 0,
        typesDrained: 0,
        wasInterrupted: false,
        waitingForUnlock: false
    )
}

/// Drains new Health data and hands it to every destination that is due.
///
/// The cursor rule is the same one the manual export uses, and for the same
/// reason: an anchor only advances once the data it covers has been accepted by
/// every destination that wanted it. A delivery that fails is retried from the
/// same cursor, so nothing is skipped, and stable per-record identifiers mean a
/// repeat is harmless.
///
/// This is the difference from a scheduler that exports "the last hour": a
/// missed window there is data lost forever, and an overlapping one is
/// duplicates. Anchors make both impossible.
public actor HealthSyncEngine {
    private static let log = Logger(
        subsystem: "com.thatcube.Hozz",
        category: "sync"
    )

    /// Records gathered before a batch is handed over. Small enough to fit in
    /// the few seconds and few megabytes a background launch is given.
    public static let batchRecordLimit = 5_000
    private static let pageSize = 500

    private let store: HozzStore
    private let source: any HealthDataSource
    private let delivery: DeliveryEngine
    private let allTypes: [HealthTypeKey]
    private let lease: ExportWriterLease

    public init(
        store: HozzStore,
        source: any HealthDataSource,
        delivery: DeliveryEngine,
        types: [HealthTypeKey],
        lease: ExportWriterLease = .shared
    ) {
        self.store = store
        self.source = source
        self.delivery = delivery
        self.allTypes = types
        self.lease = lease
    }

    /// Runs one pass, delivering to every destination that is due.
    ///
    /// Each destination is drained from its **own** cursor and committed
    /// independently. Sharing one cursor would be cheaper, but destinations are
    /// scheduled independently — one hourly, another daily, another manual — so
    /// a shared cursor advanced by whichever ran first would permanently skip
    /// that data for all the others.
    ///
    /// - Parameter limitTo: Types the observer flagged. Empty means check all.
    public func sync(
        limitTo dirtyTypes: Set<HealthTypeKey> = [],
        ignoringCadence: Bool = false,
        now: Date = .now
    ) async throws -> SyncOutcome {
        let destinations = try await delivery.dueDestinations(
            now: now,
            ignoringCadence: ignoringCadence
        )
        guard !destinations.isEmpty else {
            return .idle
        }
        // The manual exporter shares this store, so only one may drain at once.
        guard await lease.acquire() else {
            for destination in destinations {
                try? await delivery.markWaitingForSystem(destination.id)
            }
            return .idle
        }
        defer {
            Task { await lease.release() }
        }

        var deliveredRecords = 0
        var typesDrained = 0
        var interrupted = false
        var waitingForUnlock = false

        for destination in destinations {
            // Anything unexpected while handling one destination — an encoding
            // failure, a SQLite error — must not skip the destinations after
            // it. They are ordered deterministically, so the same ones would be
            // starved on every pass.
            let result: SyncOutcome
            do {
                result = try await sync(
                    destination: destination,
                    dirtyTypes: dirtyTypes,
                    now: now
                )
            } catch {
                Self.log.error("A destination could not be synced this pass.")
                interrupted = true
                continue
            }
            deliveredRecords += result.deliveredRecords
            typesDrained = max(typesDrained, result.typesDrained)
            interrupted = interrupted || result.wasInterrupted
            waitingForUnlock = waitingForUnlock || result.waitingForUnlock

            if result.waitingForUnlock {
                // Nothing can be read until the phone is unlocked, so there is
                // no point trying the remaining destinations.
                break
            }
        }

        return SyncOutcome(
            deliveredRecords: deliveredRecords,
            destinationCount: destinations.count,
            typesDrained: typesDrained,
            wasInterrupted: interrupted,
            waitingForUnlock: waitingForUnlock
        )
    }

    /// Drains and delivers for one destination, using only its own cursor.
    private func sync(
        destination: Destination,
        dirtyTypes: Set<HealthTypeKey>,
        now: Date
    ) async throws -> SyncOutcome {
        let scope = AnchorScope.destination(destination.id)
        let candidates = allTypes
            .filter { destination.includes($0) }
            .filter { dirtyTypes.isEmpty || dirtyTypes.contains($0) }

        var records: [HealthChange] = []
        var proposedAnchors: [HealthTypeKey: AnchorToken] = [:]
        var baseAnchors: [HealthTypeKey: AnchorToken?] = [:]
        var counts: [HealthTypeKey: Int] = [:]
        var interrupted = false
        var waitingForUnlock = false

        for type in candidates {
            if Task.isCancelled || records.count >= Self.batchRecordLimit {
                interrupted = true
                break
            }

            let base = try await store.committedAnchor(scope: scope, type: type)
            var anchor = base
            var collected: [HealthChange] = []

            drain: while true {
                if Task.isCancelled || records.count + collected.count >= Self.batchRecordLimit {
                    interrupted = true
                    break drain
                }
                do {
                    let page = try await source.changes(
                        for: type,
                        after: anchor,
                        limit: Self.pageSize
                    )
                    if !page.changes.isEmpty, page.proposedAnchor == anchor {
                        throw DrainError.nonAdvancingAnchor
                    }
                    collected.append(contentsOf: page.changes)
                    anchor = page.proposedAnchor
                    if page.changes.isEmpty {
                        break drain
                    }
                } catch {
                    let failure = HealthKitFailure.classify(
                        error,
                        typeIdentifier: type.rawValue
                    )
                    if failure.kind == .deviceLocked {
                        // The ordinary background case, not a failure.
                        waitingForUnlock = true
                        interrupted = true
                        break drain
                    }
                    try? await store.recordCoverage(
                        scope: scope,
                        type: type,
                        coverage: failure.coverageState,
                        failureReason: failure.underlyingDescription
                    )
                    break drain
                }
            }

            if !collected.isEmpty || anchor != base {
                records.append(contentsOf: collected)
                proposedAnchors[type] = anchor
                baseAnchors[type] = base
                counts[type] = collected.count
            }
            if waitingForUnlock {
                break
            }
        }

        guard !records.isEmpty else {
            // Nothing new for this destination. Still commit any cursor that
            // moved without data, so an empty stream is not re-read forever.
            try await commitAnchors(
                proposedAnchors,
                base: baseAnchors,
                counts: counts,
                scope: scope
            )
            return SyncOutcome(
                deliveredRecords: 0,
                destinationCount: 1,
                typesDrained: proposedAnchors.count,
                wasInterrupted: interrupted,
                waitingForUnlock: waitingForUnlock
            )
        }

        let payload = try DeliveryPayloadBuilder.build(
            records: records,
            format: destination.format
        )
        let batch = DeliveryBatch(
            // The key is derived from the bytes being sent, so a retry of the
            // same data reuses it and a receiver can discard the repeat, while
            // a retry that picked up newer data gets a new key and is stored.
            // Reusing a key for changed contents would silently lose records.
            id: DeliveryBatch.identifier(for: payload),
            sequence: try await delivery.nextSequence(for: destination.id),
            createdAt: now,
            recordCount: records.count,
            payload: payload,
            format: destination.format
        )

        do {
            _ = try await delivery.deliver(batch, to: destination, now: now)
        } catch {
            Self.log.error(
                "A destination did not accept its batch; it will be retried."
            )
            return SyncOutcome(
                deliveredRecords: 0,
                destinationCount: 1,
                typesDrained: proposedAnchors.count,
                wasInterrupted: true,
                waitingForUnlock: waitingForUnlock
            )
        }

        try await commitAnchors(
            proposedAnchors,
            base: baseAnchors,
            counts: counts,
            scope: scope
        )

        return SyncOutcome(
            deliveredRecords: records.count,
            destinationCount: 1,
            typesDrained: proposedAnchors.count,
            wasInterrupted: interrupted,
            waitingForUnlock: waitingForUnlock
        )
    }

    private func commitAnchors(
        _ anchors: [HealthTypeKey: AnchorToken],
        base: [HealthTypeKey: AnchorToken?],
        counts: [HealthTypeKey: Int],
        scope: AnchorScope
    ) async throws {
        guard !anchors.isEmpty else {
            return
        }
        let commits = anchors
            .map { type, anchor in
                PendingAnchorCommit(
                    type: type,
                    baseAnchor: base[type] ?? nil,
                    anchor: anchor,
                    coverage: .anchorClosed,
                    addedRecordCount: counts[type] ?? 0,
                    addedObservedCount: counts[type] ?? 0,
                    anchorClosedAt: .now
                )
            }
            .sorted { $0.type < $1.type }
        try await store.commit(commits, scope: scope)
    }
}

/// Turns drained records into the bytes a destination expects.
enum DeliveryPayloadBuilder {
    static func build(
        records: [HealthChange],
        format: DeliveryFormat
    ) throws -> Data {
        let encoder = HealthSampleEncoder()
        var lines: [Data] = []
        lines.reserveCapacity(records.count)

        for record in records {
            switch record {
            case .upsert(let object):
                lines.append(object.canonicalPayload)
            case .delete(let deletion):
                lines.append(
                    try encoder.encodeDeletion(
                        id: deletion.id,
                        typeIdentifier: deletion.type.rawValue
                    )
                )
            }
        }

        switch format {
        case .ndjson:
            var payload = Data()
            for line in lines {
                payload.append(line)
                payload.append(0x0A)
            }
            return payload

        case .json:
            var payload = Data("[\n".utf8)
            for (index, line) in lines.enumerated() {
                if index > 0 {
                    payload.append(Data(",\n".utf8))
                }
                payload.append(line)
            }
            payload.append(Data("\n]\n".utf8))
            return payload

        case .csv:
            return try csv(from: lines)

        case .metrics:
            return try CompatiblePayloadBuilder.build(
                records: lines.compactMap(CompatiblePayloadBuilder.record(from:))
            )
        }
    }

    /// A single flat CSV, since an incremental batch spans several types and
    /// splitting it into files would defeat appending on the receiving end.
    private static func csv(from lines: [Data]) throws -> Data {
        var payload = Data(
            "id,type,kind,startDate,endDate,value,unit,sourceName,deleted\n".utf8
        )
        for line in lines {
            guard
                let object = try JSONSerialization.jsonObject(with: line)
                    as? [String: Any]
            else {
                continue
            }
            let kind = object["kind"] as? String ?? "sample"
            let quantity = object["quantity"] as? [String: Any]
            let source = object["source"] as? [String: Any]
            let fields = [
                object["id"] as? String ?? "",
                object["type"] as? String ?? "",
                kind,
                object["startDate"] as? String ?? "",
                object["endDate"] as? String ?? "",
                Self.number(quantity?["value"] ?? object["value"]),
                quantity?["unit"] as? String ?? "",
                source?["name"] as? String ?? "",
                kind == "deletion" ? "true" : "false"
            ]
            payload.append(
                Data((fields.map(escape).joined(separator: ",") + "\n").utf8)
            )
        }
        return payload
    }

    private static func number(_ value: Any?) -> String {
        switch value {
        case let value as Int:
            String(value)
        case let value as Double:
            value == value.rounded() && abs(value) < 1e15
                ? String(Int64(value))
                : String(value)
        case let value as NSNumber:
            value.stringValue
        default:
            ""
        }
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        else {
            return field
        }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
