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
    /// How many of ``deliveredRecords`` came from the dated prime rather than
    /// the anchored sweep.
    ///
    /// Worth separating because they answer different questions. Sweep records
    /// are progress through a backlog whose size nobody knows; prime records
    /// are progress through a window whose size is known exactly, so only these
    /// can be turned into a fraction without inventing a denominator.
    public let primedRecords: Int
    /// Whether any type still has a dated window left to walk.
    ///
    /// False does not mean the history is complete — it means the *recent*
    /// window is. The sweep is still walking everything older, and a surface
    /// that read this as "done" would claim the gap does not exist.
    public let primingRemains: Bool

    public init(
        deliveredRecords: Int,
        destinationCount: Int,
        typesDrained: Int,
        wasInterrupted: Bool,
        waitingForUnlock: Bool,
        primedRecords: Int = 0,
        primingRemains: Bool = false
    ) {
        self.deliveredRecords = deliveredRecords
        self.destinationCount = destinationCount
        self.typesDrained = typesDrained
        self.wasInterrupted = wasInterrupted
        self.waitingForUnlock = waitingForUnlock
        self.primedRecords = primedRecords
        self.primingRemains = primingRemains
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

    /// The most of one pass's budget the dated prime may take.
    ///
    /// The prime goes first, because it is the only reader that can make the
    /// recent past appear and it is the reason somebody opening the app on
    /// their second day sees anything at all. But it does not get everything:
    /// a pass that spent its whole budget priming would stop the sweep dead,
    /// and the sweep is the only reader that will ever finish. Three quarters
    /// is enough for the prime to cross ninety days quickly while leaving the
    /// backlog moving every single pass.
    static let primeRecordCeiling = batchRecordLimit * 3 / 4

    /// The most of one pass's *bytes* the dated prime may take.
    ///
    /// The same reservation as the record ceiling, and for the same reason. A
    /// prime allowed to run right up to the byte limit would start a chunk at
    /// one byte below it and overshoot by a whole chunk, leaving the sweep's
    /// own guard tripped before it read anything. The prime finishes either
    /// way; the sweep would simply have lost that pass.
    static let primeByteCeiling = batchByteLimit * 3 / 4

    /// The most dated queries one type may spend in a single pass.
    ///
    /// A sparse type crosses its whole window in a handful of chunks because
    /// each empty chunk widens the next. This bounds the pathological case —
    /// a type that keeps returning just enough records to stay narrow — so one
    /// type cannot spend a whole background launch on queries.
    static let primeQueriesPerType = 24

    let store: HozzStore
    private let source: any HealthDataSource
    /// The dated reader, when there is one.
    ///
    /// Optional because the prime is an addition to a pipeline that works
    /// without it, and because a caller that has no dated reader should get the
    /// old behaviour exactly, rather than a prime that quietly does nothing.
    let datedSource: (any DatedHealthDataSource)?
    let primeSpan: TimeInterval
    private let delivery: DeliveryEngine
    let allTypes: [HealthTypeKey]
    private let lease: ExportWriterLease

    public init(
        store: HozzStore,
        source: any HealthDataSource,
        delivery: DeliveryEngine,
        types: [HealthTypeKey],
        datedSource: (any DatedHealthDataSource)? = nil,
        primeSpan: TimeInterval = PrimePlan.defaultSpan,
        lease: ExportWriterLease = .shared
    ) {
        self.store = store
        self.source = source
        self.delivery = delivery
        self.allTypes = types
        self.datedSource = datedSource
        self.primeSpan = primeSpan
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
        var primedRecords = 0
        var primingRemains = false
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
                // A destination that could not be evaluated is not a
                // destination that is finished. Leaving this alone would let a
                // pass where everything failed report nothing outstanding,
                // which reads downstream as "up to date" — a claim made on the
                // strength of never having looked.
                primingRemains = true
                continue
            }
            deliveredRecords += result.deliveredRecords
            // Carried up with the rest, and worth naming because leaving them
            // out is invisible: the fields have defaults, so an outcome that
            // dropped them still compiles, still looks right, and quietly turns
            // every sentence downstream that depends on them into one nobody
            // can ever see.
            primedRecords += result.primedRecords
            primingRemains = primingRemains || result.primingRemains
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
            waitingForUnlock: waitingForUnlock,
            primedRecords: primedRecords,
            primingRemains: primingRemains
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

        // The prime runs before the sweep and into the same batch. Before,
        // because the recent past is what somebody is waiting to see; the same
        // batch, because two batches would be two deliveries, two chances to
        // fail, and two places to be interrupted between reading and recording.
        let prime = try await primeRound(
            destination: destination,
            scope: scope,
            now: now
        )
        records.append(contentsOf: prime.changes)
        recordBytes += prime.bytes
        interrupted = interrupted || prime.wasInterrupted
        waitingForUnlock = waitingForUnlock || prime.waitingForUnlock

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
        // A type whose sweep ran dry without producing anything is committed
        // too, even though its cursor did not move. Health returns the same
        // anchor for an empty page, so without this a type that finished
        // exactly on a budget boundary stayed recorded as `draining` for good
        // — and the receiver would have been told, truthfully by the letter
        // and falsely in effect, that it is still waiting for records that do
        // not exist.
        let committable = states.filter { _, state in
            state.anchor != state.base || state.collected > 0 || state.isExhausted
        }

        // Built from what this pass is about to commit rather than from the
        // store, so a completion travels in the same batch as the records that
        // completed it. Reading the store here would report the previous
        // pass's coverage, and a type that finishes and is then never touched
        // again would never be reported finished at all.
        //
        // Stamped with the moment the coverage was *observed* rather than the
        // moment this pass ran, so an identical retry rebuilds identical bytes
        // and keeps the batch identity a receiver recognises it by. The digest
        // ignores timestamps, so it can be taken before the moment is known.
        let held = try await store.streamRecords(scope: scope)
        let passCoverage = Self.passCoverage(for: committable)
        // The digest is taken over the same reports that will be sent, windows
        // included. A digest that summarised less than the payload would let
        // the bytes change while the digest said they had not: the moment
        // stamped on them would be reused from an earlier pass, and a receiver
        // would be handed a widened window under a fingerprint claiming nothing
        // had changed.
        let digest = CoverageReporter.digest(
            of: CoverageReporter.reports(
                from: held,
                pass: passCoverage,
                primedWindows: prime.windows,
                observedAt: now
            )
        )
        let observedAt = await delivery.coverageObservation(
            digest: digest,
            now: now,
            for: destination.id
        )
        let coverage = CoverageReporter.reports(
            from: held,
            pass: passCoverage,
            // What the dated prime has genuinely delivered, as this batch will
            // leave it. A window widens only inside the transaction that
            // records the delivery, so a receiver is never told about a stretch
            // that a refused batch failed to carry.
            primedWindows: prime.windows,
            observedAt: observedAt
        )
        let coverageIsNews = destination.format.carriesCoverage
            && digest != destination.reportedCoverageDigest

        guard !records.isEmpty || coverageIsNews else {
            // Nothing new for this destination. Still commit any cursor that
            // moved without data, so an empty stream is not re-read forever.
            //
            // The prime's frontier is committed here too, and this is not a
            // detail: a type with nothing at all in the last ninety days walks
            // its whole window without producing a single record, and if that
            // only counted when something was delivered, its window would be
            // walked again on every pass, forever, and never be reported as
            // covered. An empty stretch that has been read is covered — the
            // claim "everything in this window is present" is true of nothing
            // in exactly the way it is true of something.
            try await commit(
                committable,
                prime: prime.commits,
                scope: scope
            )
            return SyncOutcome(
                deliveredRecords: 0,
                destinationCount: 1,
                typesDrained: touched.count,
                wasInterrupted: interrupted,
                waitingForUnlock: waitingForUnlock,
                primedRecords: 0,
                primingRemains: prime.remains
            )
        }

        let payload = try DeliveryPayloadBuilder.build(
            records: records,
            coverage: destination.format.carriesCoverage ? coverage : [],
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
            // Neither cursor moves. The prime re-reads the same chunk next
            // time, which is the trade this design makes on purpose: a repeat
            // the receiver absorbs, rather than a window claimed for data that
            // never arrived.
            return SyncOutcome(
                deliveredRecords: 0,
                destinationCount: 1,
                typesDrained: touched.count,
                wasInterrupted: true,
                waitingForUnlock: waitingForUnlock,
                primedRecords: 0,
                primingRemains: prime.remains
            )
        }

        try await commit(committable, prime: prime.commits, scope: scope)
        if coverageIsNews {
            // After the batch was accepted, so a refusal leaves the coverage
            // still owed rather than recorded as told.
            try? await delivery.recordCoverageDigest(digest, for: destination.id)
        }

        return SyncOutcome(
            deliveredRecords: records.count,
            destinationCount: 1,
            typesDrained: touched.count,
            wasInterrupted: interrupted,
            waitingForUnlock: waitingForUnlock,
            primedRecords: prime.changes.count,
            primingRemains: prime.remains
        )
    }

    /// What this destination should be told about how completely each type has
    /// been read.
    ///
    /// The store's records supply every type that has ever delivered anything;
    /// this pass overrides the ones it visited, using exactly the coverage
    /// ``commitAnchors`` is about to write, so the wire and the store cannot
    /// disagree about the same type in the same moment.
    static func passCoverage(
        for states: [HealthTypeKey: TypeState]
    ) -> [HealthTypeKey: CoverageReporter.PassCoverage] {
        var pass: [HealthTypeKey: CoverageReporter.PassCoverage] = [:]
        for (type, state) in states {
            pass[type] = CoverageReporter.PassCoverage(
                state: coverageState(for: state),
                deliveredCount: state.observedBefore + state.collected
            )
        }
        return pass
    }

    /// The one place that decides what a pass's reading of a type amounts to.
    ///
    /// An empty page is the only evidence that a type is caught up, and a type
    /// that has never produced anything stays indeterminate, because Health
    /// does not let Hozz tell a denied type from an empty one.
    static func coverageState(for state: TypeState) -> CoverageState {
        guard state.isExhausted else {
            return .draining
        }
        return state.observedBefore + state.collected == 0
            ? .authorizationIndeterminate
            : .anchorClosed
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
                if error is CancellationError || Task.isCancelled {
                    // The ordinary background case: iOS took its time back and
                    // the pass is checkpointing. Recording a coverage failure
                    // would report a healthy type as broken.
                    result.wasInterrupted = true
                    return result
                }
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

    /// Points every destination's prime at a fresh window and walks it again.
    ///
    /// The one thing somebody might genuinely want to ask for by hand. Health
    /// authorization can be widened in Settings long after Hozz first ran, and
    /// a prime that already covered its window has no way to notice: it
    /// finished, correctly, over the types it was allowed to see.
    ///
    /// Cheap to be wrong about. Re-reading delivers records the destination
    /// already holds, and the receiver upserts on `(id, type)`, so asking twice
    /// costs bytes rather than duplicates — while the cursors return to the new
    /// starting instant first, so nothing is claimed while it is being re-read.
    public func restartPrime(now: Date = .now) async throws {
        let window = PrimePlan.window(endingAt: now, span: primeSpan)
        for destination in try await delivery.destinations() {
            try await store.restartPrime(
                scope: .destination(destination.id),
                windowStart: window.start,
                startedAt: window.end,
                chunkSeconds: PrimePlan.initialChunk,
                at: now
            )
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
    /// The judgement itself lives in ``coverageState(for:)``, which the batch
    /// on the wire uses too: the receiver is told exactly what the store is
    /// about to record, in the same breath, or neither happens.
    ///
    /// Named for what it does rather than for the cursor it started with. It
    /// carries the dated prime's frontiers in the same transaction, and a
    /// function called `commitAnchors` that also moved something else would be
    /// the exact kind of quietly-wrong name this app cannot afford: the one
    /// thing a prime must never do is advance an anchor.
    private func commit(
        _ states: [HealthTypeKey: TypeState],
        prime primeCommits: [PendingPrimeCommit],
        scope: AnchorScope
    ) async throws {
        guard !states.isEmpty || !primeCommits.isEmpty else {
            return
        }
        let closedAt = Date.now
        let commits = states
            .compactMap { type, state -> PendingAnchorCommit? in
                guard let anchor = state.anchor else {
                    return nil
                }
                return PendingAnchorCommit(
                    type: type,
                    baseAnchor: state.base,
                    anchor: anchor,
                    coverage: Self.coverageState(for: state),
                    addedRecordCount: state.collected,
                    addedObservedCount: state.collected,
                    anchorClosedAt: state.isExhausted ? closedAt : nil
                )
            }
            .sorted { $0.type < $1.type }
        try await store.commit(
            commits,
            prime: primeCommits.sorted { $0.type < $1.type },
            scope: scope
        )
    }
}

/// Turns drained records into the bytes a destination expects.
enum DeliveryPayloadBuilder {
    /// Turns a pass's records into the destination's own format.
    ///
    /// The metrics and InfluxDB shapes reduce a record to one number, and a
    /// page of five hundred readings is not one number. Sent anyway, a reading
    /// page landed *inside the real metric* — an extra point under "heart
    /// rate", dated to the page rather than the reading, carrying no quantity
    /// and a unit of "count" — so anything counting points per metric counted
    /// pages as readings. They are left out of those two formats instead,
    /// which leaves a metrics destination exactly as it was before series
    /// expansion existed. Publishing the readings themselves as points is
    /// worth doing and is a change of its own: it needs the aggregate excluded
    /// in the same breath, or a mean over the measurement averages a number
    /// together with the numbers it is the average of.
    ///
    /// The lossless formats carry everything, unchanged.
    ///
    /// - Parameter coverage: what the phone knows about how completely each
    ///   type has been read. Written as ordinary lines beside the records,
    ///   because a receiver that has to be configured to expect a second
    ///   channel is a receiver that will not be, and coverage that only some
    ///   deliveries carry is worse than none.
    static func build(
        records: [HealthChange],
        coverage: [TypeCoverageReport] = [],
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

        // Appended after the records, so a receiver applying the batch in order
        // stores the samples before it is told what they amount to. The other
        // order would briefly assert a type complete while the last of it was
        // still being written, inside a transaction nobody can see into.
        let coverageLines = format.carriesCoverage
            ? CoverageReporter.lines(for: coverage)
            : []
        lines.append(contentsOf: coverageLines)

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
            let decoded = lines
                .compactMap(CompatiblePayloadBuilder.record(from:))
                .filter { !SeriesEncoding.isDetailKind($0.kind) }
            switch destination.payloadSchema {
            case .hozz:
                return try CompatiblePayloadBuilder.build(records: decoded)
            case .healthAutoExport:
                return try HealthAutoExportPayloadBuilder.build(records: decoded)
            }

        case .influx:
            return InfluxLineProtocol.build(
                records: lines
                    .compactMap(CompatiblePayloadBuilder.record(from:))
                    .filter { !SeriesEncoding.isDetailKind($0.kind) },
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
