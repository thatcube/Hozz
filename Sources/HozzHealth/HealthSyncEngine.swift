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

    /// Bytes gathered before a batch is handed over.
    ///
    /// A count alone stopped being a bound once series types arrived. An
    /// ordinary sample is a few hundred bytes, but one workout route or ECG
    /// record carries five hundred points and is tens of kilobytes, so five
    /// thousand of those would be hundreds of megabytes gathered in a launch
    /// iOS gives a few seconds and a few megabytes. Cutting the pass short
    /// costs nothing: each type's cursor is committed wherever it reached, and
    /// the pass reports itself as interrupted so the rest follows next time.
    public static let batchByteLimit = 4 * 1_024 * 1_024
    private static let pageSize = 500

    /// The smallest share a type gets before the pass moves on. Small enough
    /// that a hundred types fit inside one budget, large enough that a type
    /// with a handful of new records finishes in a single pass.
    public static let minimumFairShare = 50

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
        // An automatic pass does not wait: it runs again soon anyway, and
        // queueing behind a manual export would hold up the person watching.
        guard await lease.acquire(for: .automaticSync) else {
            for destination in destinations {
                try? await delivery.markWaitingForSystem(destination.id)
            }
            return .idle
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

        // Released here rather than in a detached task, so the lease is free
        // the moment the pass is, and a manual export waiting on it starts
        // immediately instead of at some unspecified later point.
        await lease.release()
        return SyncOutcome(
            deliveredRecords: deliveredRecords,
            destinationCount: destinations.count,
            typesDrained: typesDrained,
            wasInterrupted: interrupted,
            waitingForUnlock: waitingForUnlock
        )
    }

    /// Drains and delivers for one destination, using only its own cursor.
    ///
    /// Types are visited in two rounds. The first gives every type a small
    /// share, so a person sees *something* from everything rather than nothing
    /// until its turn comes round; the second spends whatever the shares left,
    /// so a large backlog still drains at close to full speed.
    ///
    /// A single pass in catalogue order was the alternative, and it starved by
    /// position: stand hours sit 4th and step count 197th, so someone with
    /// years of stand hours saw no step count at all until the stand hours
    /// finished — dozens of background passes later. It converged, but nobody
    /// waits that long before deciding an app is broken.
    private func sync(
        destination: Destination,
        dirtyTypes: Set<HealthTypeKey>,
        now: Date
    ) async throws -> SyncOutcome {
        let scope = AnchorScope.destination(destination.id)
        let candidates = Self.rotated(
            allTypes
                .filter { destination.includes($0) }
                .filter { dirtyTypes.isEmpty || dirtyTypes.contains($0) },
            at: now
        )

        var records: [HealthChange] = []
        var recordBytes = 0
        var states: [HealthTypeKey: TypeState] = [:]
        var interrupted = false
        var waitingForUnlock = false

        let share = Self.fairShare(candidateCount: candidates.count)

        rounds: for round in 0..<2 {
            for type in candidates {
                if Task.isCancelled {
                    interrupted = true
                    break rounds
                }
                guard
                    records.count < Self.batchRecordLimit,
                    recordBytes < Self.batchByteLimit
                else {
                    interrupted = true
                    break rounds
                }

                var state: TypeState
                if let existing = states[type] {
                    state = existing
                } else {
                    // Read once per pass, for the cursor and for how much this
                    // type has ever produced. The second is what decides
                    // whether an empty page means "caught up" or "nothing here".
                    let stored = try await store.streamRecord(
                        scope: scope,
                        type: type
                    )
                    state = TypeState(
                        base: stored?.committedAnchor,
                        observedBefore: stored?.observedCount ?? 0,
                        anchor: stored?.committedAnchor
                    )
                }
                if state.isExhausted {
                    continue
                }

                let allowance = round == 0
                    ? min(share, Self.batchRecordLimit - records.count)
                    : Self.batchRecordLimit - records.count
                let result = try await drain(
                    type: type,
                    from: state.anchor,
                    allowance: allowance,
                    byteAllowance: Self.batchByteLimit - recordBytes,
                    scope: scope
                )

                records.append(contentsOf: result.changes)
                recordBytes += result.bytes
                state.anchor = result.anchor
                state.collected += result.changes.count
                state.isExhausted = result.isExhausted
                states[type] = state

                interrupted = interrupted || result.wasInterrupted
                if result.waitingForUnlock {
                    waitingForUnlock = true
                    interrupted = true
                    break rounds
                }
            }
        }

        let touched = states.filter { _, state in
            state.anchor != state.base || state.collected > 0
        }

        guard !records.isEmpty else {
            // Nothing new for this destination. Still commit any cursor that
            // moved without data, so an empty stream is not re-read forever.
            try await commitAnchors(touched, scope: scope)
            return SyncOutcome(
                deliveredRecords: 0,
                destinationCount: 1,
                typesDrained: touched.count,
                wasInterrupted: interrupted,
                waitingForUnlock: waitingForUnlock
            )
        }

        let payload = try DeliveryPayloadBuilder.build(
            records: records,
            destination: destination
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
                typesDrained: touched.count,
                wasInterrupted: true,
                waitingForUnlock: waitingForUnlock
            )
        }

        try await commitAnchors(touched, scope: scope)

        return SyncOutcome(
            deliveredRecords: records.count,
            destinationCount: 1,
            typesDrained: touched.count,
            wasInterrupted: interrupted,
            waitingForUnlock: waitingForUnlock
        )
    }

    /// Where one type got to during this pass.
    struct TypeState {
        let base: AnchorToken?
        /// How many objects this type had ever produced before the pass.
        let observedBefore: Int
        var anchor: AnchorToken?
        var collected = 0
        /// Set only when Health returned an empty page, which is the one
        /// condition that means there is nothing more to read right now.
        var isExhausted = false
    }

    private struct TypeDrain {
        var changes: [HealthChange] = []
        var bytes = 0
        var anchor: AnchorToken?
        var isExhausted = false
        var wasInterrupted = false
        var waitingForUnlock = false
    }

    /// Reads one type until its allowance runs out or Health runs dry.
    ///
    /// The page size is trimmed to the allowance, so a share of fifty really
    /// costs fifty rather than a whole page — otherwise every type would take
    /// a full page in the first round and the fair share would be fiction.
    private func drain(
        type: HealthTypeKey,
        from start: AnchorToken?,
        allowance: Int,
        byteAllowance: Int,
        scope: AnchorScope
    ) async throws -> TypeDrain {
        var result = TypeDrain(anchor: start)
        guard allowance > 0, byteAllowance > 0 else {
            result.wasInterrupted = true
            return result
        }

        while true {
            if Task.isCancelled {
                result.wasInterrupted = true
                return result
            }
            let remaining = allowance - result.changes.count
            guard remaining > 0, result.bytes < byteAllowance else {
                result.wasInterrupted = true
                return result
            }

            do {
                let page = try await source.changes(
                    for: type,
                    after: result.anchor,
                    limit: min(Self.pageSize, remaining)
                )
                if !page.changes.isEmpty, page.proposedAnchor == result.anchor {
                    throw DrainError.nonAdvancingAnchor
                }
                result.changes.append(contentsOf: page.changes)
                result.bytes += page.changes.reduce(0) {
                    $0 + $1.approximateByteCount
                }
                result.anchor = page.proposedAnchor
                if page.changes.isEmpty {
                    result.isExhausted = true
                    return result
                }
            } catch {
                let failure = HealthKitFailure.classify(
                    error,
                    typeIdentifier: type.rawValue
                )
                if failure.kind == .deviceLocked {
                    // The ordinary background case, not a failure.
                    result.waitingForUnlock = true
                    result.wasInterrupted = true
                    return result
                }
                try? await store.recordCoverage(
                    scope: scope,
                    type: type,
                    coverage: failure.coverageState,
                    failureReason: failure.underlyingDescription
                )
                result.wasInterrupted = true
                return result
            }
        }
    }

    /// Rotates the order types are visited in, by the hour.
    ///
    /// The fair share already stops one type eating a whole pass, but the
    /// second round spends the remainder from the top of the list, so without
    /// this the same type would always get it. Deriving the offset from the
    /// clock keeps it deterministic and needs nothing stored.
    public static func rotated(_ types: [HealthTypeKey], at now: Date) -> [HealthTypeKey] {
        guard types.count > 1 else {
            return types
        }
        let slot = Int(now.timeIntervalSince1970 / 3_600)
        let offset = ((slot % types.count) + types.count) % types.count
        return Array(types[offset...] + types[..<offset])
    }

    /// Records each type may take before every other type has had a turn.
    public static func fairShare(candidateCount: Int) -> Int {
        guard candidateCount > 1 else {
            return batchRecordLimit
        }
        return min(
            pageSize,
            max(minimumFairShare, batchRecordLimit / candidateCount)
        )
    }

    /// Commits one cursor per type, saying honestly whether the type is caught
    /// up or merely further along.
    ///
    /// This used to write `anchorClosed` for everything it committed, so a
    /// type cut off by the budget with fifteen thousand records still to come
    /// was recorded as closed. Nothing was lost — the next pass re-reads from
    /// the anchor either way — but the store asserted something it could not
    /// know, and a progress display had no way to tell "caught up" from "cut
    /// off halfway".
    ///
    /// An empty page is the only evidence that a type is caught up, and a type
    /// that has never produced anything stays indeterminate, because Health
    /// does not let Hozz tell a denied type from an empty one.
    private func commitAnchors(
        _ states: [HealthTypeKey: TypeState],
        scope: AnchorScope
    ) async throws {
        guard !states.isEmpty else {
            return
        }
        let closedAt = Date.now
        let commits = states
            .compactMap { type, state -> PendingAnchorCommit? in
                guard let anchor = state.anchor else {
                    return nil
                }
                let observed = state.observedBefore + state.collected
                let coverage: CoverageState = if !state.isExhausted {
                    .draining
                } else if observed == 0 {
                    .authorizationIndeterminate
                } else {
                    .anchorClosed
                }
                return PendingAnchorCommit(
                    type: type,
                    baseAnchor: state.base,
                    anchor: anchor,
                    coverage: coverage,
                    addedRecordCount: state.collected,
                    addedObservedCount: state.collected,
                    anchorClosedAt: state.isExhausted ? closedAt : nil
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
        destination: Destination
    ) throws -> Data {
        let format = destination.format
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
            let decoded = lines.compactMap(CompatiblePayloadBuilder.record(from:))
            switch destination.payloadSchema {
            case .hozz:
                return try CompatiblePayloadBuilder.build(records: decoded)
            case .healthAutoExport:
                return try HealthAutoExportPayloadBuilder.build(records: decoded)
            }

        case .influx:
            return InfluxLineProtocol.build(
                records: lines.compactMap(CompatiblePayloadBuilder.record(from:)),
                options: destination.influxOptions
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
