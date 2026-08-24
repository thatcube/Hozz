import Foundation
import HozzAcquire
import HozzCatalog
import HozzCore
import HozzDeliver
import HozzStore
import os

/// The recent-first prime: a dated pass that fetches the last few months of
/// Health data straight away, so a dashboard has something true to say on the
/// first day rather than the fourth week.
///
/// **Why this exists.** The anchored sweep returns records in the order Health
/// stored them, which is not the order they happened, and that ordering is not
/// negotiable — it is the same property that lets the sweep see a sample
/// written retroactively, which a date window cannot. Measured on a real
/// archive, delivery managed a few thousand records an hour and only while iOS
/// granted background time, against a heart rate history of some 860,000
/// records. The dashboard showed step data ending in January 2023 because that
/// was as far as the cursor had walked. Nothing was wrong; it was simply going
/// to take weeks.
///
/// So this is a *second* reader, going the other way, and the two together say
/// something neither says alone: the sweep will eventually have everything, and
/// the prime already has the part somebody is looking at.
///
/// **Why it is safe to run both.** The receiver upserts on `(id, type)`, so a
/// record delivered by both readers costs bytes and nothing else. Every
/// decision below spends duplicates freely to avoid ever skipping.
///
/// **The one thing that must not go wrong.** A prime must never advance an
/// anchor. If it did, every record older than the primed window would be
/// skipped by the sweep permanently — the exact loss the anchors exist to
/// prevent, arriving through the door built to avoid it. The defence is
/// structural rather than careful: the dated protocol has no anchor in it, the
/// frontier lives in its own table, and no function turns one into the other.
extension HealthSyncEngine {
    private static let primeLog = Logger(
        subsystem: "com.thatcube.Hozz",
        category: "prime"
    )

    /// What one pass's priming produced, before anything is delivered.
    struct PrimeRound {
        var changes: [HealthChange] = []
        var bytes = 0
        /// Frontier advances, held back until the destination accepts the batch.
        var commits: [PendingPrimeCommit] = []
        /// Whether any type still has window left to walk after this pass.
        var remains = false
        var wasInterrupted = false
        var waitingForUnlock = false
    }

    /// Walks the dated window for as many types as this pass can afford.
    func primeRound(
        destination: Destination,
        scope: AnchorScope,
        now: Date
    ) async throws -> PrimeRound {
        var round = PrimeRound()
        guard let datedSource = self.datedSource else {
            return round
        }

        let eligible = allTypes
            .filter { destination.includes($0) }
            .filter(Self.canPrime)
        guard !eligible.isEmpty else {
            return round
        }

        // Seeding every eligible type before walking any of them, so a type
        // that this pass never reaches still gets the same window as the rest.
        // Windows fixed at one instant make the coverage of different types
        // comparable; windows fixed whenever a type happened to come up would
        // drift apart by however long the prime took.
        let window = PrimePlan.window(endingAt: now, span: primeSpan)
        for type in eligible {
            _ = try await store.beginPrime(
                scope: scope,
                type: type,
                windowStart: window.start,
                startedAt: window.end,
                chunkSeconds: PrimePlan.initialChunk,
                at: now
            )
        }

        let pending = try await store.primeRecords(scope: scope)
            .filter { eligible.contains($0.type) }
            // A stalled type is skipped whole. Its density is what stopped the
            // backfill, and the same density is waiting at the leading edge.
            .filter { $0.state != .stalled }
            .filter { record in
                record.frontier > record.windowStart
                    || record.coveredThrough
                        .addingTimeInterval(PrimePlan.topUpInterval) <= now
            }
        round.remains = !pending.isEmpty
        guard !pending.isEmpty else {
            return round
        }

        // What still owes a backfill, which is what "still priming" means to a
        // surface. A type whose backfill is done goes on topping up forever,
        // and reporting that as unfinished work would leave a progress display
        // that never completes.
        var owingBackfill = Set(
            pending
                .filter { $0.state == .priming && $0.frontier > $0.windowStart }
                .map(\.type)
        )

        // Least-covered first, rather than in catalogue order or by the clock.
        // Coverage then spreads across types instead of pooling in whichever
        // ones sort early: a dense type that can only manage a few days per
        // pass keeps yielding to the ones that have had nothing at all, and a
        // dashboard fills evenly rather than one row at a time.
        let ordered = pending.sorted { first, second in
            let left = Self.coveredFraction(first)
            let right = Self.coveredFraction(second)
            if left == right {
                return first.type < second.type
            }
            return left < right
        }

        for record in ordered {
            if Task.isCancelled {
                round.wasInterrupted = true
                break
            }
            // A chunk is delivered whole or not at all, so a type is only
            // started when there is room for a whole one. Starting anyway and
            // asking for a smaller page would make a *budget* limit look like a
            // density limit, and the walk would shrink its chunk in response —
            // permanently, since the chunk length is stored.
            guard
                round.changes.count + PrimePlan.chunkCapacity
                    <= Self.primeRecordCeiling,
                round.bytes < Self.batchByteLimit
            else {
                round.wasInterrupted = true
                break
            }

            let walk = await walkPrime(
                record: record,
                scope: scope,
                source: datedSource,
                allowance: Self.primeRecordCeiling - round.changes.count,
                byteAllowance: Self.batchByteLimit - round.bytes,
                now: now
            )

            round.changes.append(contentsOf: walk.changes)
            round.bytes += walk.bytes
            round.wasInterrupted = round.wasInterrupted || walk.wasInterrupted
            if let commit = walk.commit {
                round.commits.append(commit)
                if commit.state != .priming {
                    owingBackfill.remove(commit.type)
                }
            }
            if walk.waitingForUnlock {
                // Nothing can be read at all until the phone is unlocked, so
                // the remaining types would only repeat this failure.
                round.waitingForUnlock = true
                round.wasInterrupted = true
                break
            }
        }

        round.remains = !owingBackfill.isEmpty
        return round
    }

    /// What one dated read came back with.
    private enum ChunkRead {
        case read(DatedHealthChanges)
        /// iOS took its background time back. Ordinary, and not a fault.
        case interrupted
        /// Health cannot be read at all until the phone is unlocked.
        case locked
        case failed(String)
    }

    /// Whether either cursor moved away from where the stored record had them.
    private static func moved(
        _ frontier: Date,
        _ coveredThrough: Date,
        _ record: PrimeRecord
    ) -> Bool {
        frontier < record.frontier || coveredThrough > record.coveredThrough
    }

    /// One type's walk during one pass.
    private struct PrimeWalk {
        var changes: [HealthChange] = []
        var bytes = 0
        /// Nil when the frontier did not move, which is the normal shape of an
        /// interrupted or failed walk and must not be confused with progress.
        var commit: PendingPrimeCommit?
        var wasInterrupted = false
        var waitingForUnlock = false
    }

    /// Reads chunks of one type's window until the budget ends: the leading
    /// edge first, then further into the past.
    ///
    /// The order is not arbitrary. Data recorded this morning is at the end of
    /// the anchored sweep's queue, behind years of backlog, so this walk is the
    /// only thing that will deliver it this month — and somebody looking at a
    /// dashboard notices today missing long before they notice February.
    ///
    /// Never throws. A type that cannot be read is a fact about that type, and
    /// letting it abort the pass would take the other types' progress with it —
    /// including progress already staged in this batch.
    private func walkPrime(
        record: PrimeRecord,
        scope: AnchorScope,
        source: any DatedHealthDataSource,
        allowance: Int,
        byteAllowance: Int,
        now: Date
    ) async -> PrimeWalk {
        var walk = PrimeWalk()
        var frontier = record.frontier
        var coveredThrough = record.coveredThrough
        var seconds = record.chunkSeconds
        var state = record.state
        var failureReason: String?
        var queries = 0

        /// Reads one chunk, or says why it could not.
        ///
        /// Deliberately touches none of the walk's state: it takes a range and
        /// returns an answer. An earlier version recorded the failure from in
        /// here, which put a mutable local in the same isolation region as an
        /// actor call and was rejected — rightly, since it was also two places
        /// that could decide what the walk's state was.
        func read(_ chunk: Range<Date>) async -> ChunkRead {
            do {
                return .read(
                    try await source.changes(
                        for: record.type,
                        from: chunk.lowerBound,
                        to: chunk.upperBound,
                        limit: PrimePlan.chunkCapacity
                    )
                )
            } catch {
                if error is CancellationError || Task.isCancelled {
                    // iOS taking its time back is the ordinary case, not a
                    // fault, and recording it as one would report a healthy
                    // type as broken.
                    return .interrupted
                }
                let failure = HealthKitFailure.classify(
                    error,
                    typeIdentifier: record.type.rawValue
                )
                if failure.kind == .deviceLocked {
                    return .locked
                }
                return .failed(
                    failure.underlyingDescription ?? "Health could not be read."
                )
            }
        }

        /// Whether there is room for one more whole chunk.
        ///
        /// A chunk is delivered whole or not at all, so a walk only starts one
        /// it can hold. Asking for a smaller page instead would make a *budget*
        /// limit look like a density limit, and the walk would shrink its chunk
        /// in response — permanently, since the length is stored.
        func hasRoom() -> Bool {
            walk.changes.count + PrimePlan.chunkCapacity <= allowance
                && walk.bytes < byteAllowance
                && queries < Self.primeQueriesPerType
        }

        /// Handles a chunk that came back over capacity. Returns false when the
        /// walk cannot narrow any further and has to stop.
        func narrow() -> Bool {
            if PrimePlan.isAtMinimum(seconds) {
                // A minute of one type overflowing a five-hundred record bite
                // is not something the dated reader can page through without
                // either dropping records or holding more than a background
                // launch is given. It stops and says so. The sweep still
                // reaches every one of these records, so this costs speed
                // rather than data — and a stalled prime keeps claiming
                // exactly the stretch it had already delivered.
                state = .stalled
                failureReason =
                    "More records than one read can hold in the shortest window Hozz will ask for."
                Self.primeLog.notice(
                    "A type is too dense for a dated read at the shortest window."
                )
                return false
            }
            seconds = PrimePlan.narrowed(seconds)
            return true
        }

        // The leading edge, walked upwards so a half-finished top-up still
        // abuts what is already covered and can be recorded as it goes.
        topUp: while state != .stalled {
            if Task.isCancelled {
                walk.wasInterrupted = true
                break topUp
            }
            guard hasRoom() else {
                walk.wasInterrupted = true
                break topUp
            }
            guard
                let chunk = PrimePlan.topUp(
                    coveredThrough: coveredThrough,
                    ceiling: now,
                    seconds: seconds
                )
            else {
                break topUp
            }
            let batch: DatedHealthChanges
            switch await read(chunk) {
            case .read(let found):
                queries += 1
                batch = found
            case .interrupted:
                walk.wasInterrupted = true
                break topUp
            case .locked:
                walk.wasInterrupted = true
                walk.waitingForUnlock = true
                break topUp
            case .failed(let reason):
                walk.wasInterrupted = true
                failureReason = reason
                break topUp
            }
            if batch.isTruncated {
                if narrow() {
                    continue topUp
                }
                break topUp
            }

            walk.changes.append(contentsOf: batch.changes)
            walk.bytes += batch.changes.reduce(0) { $0 + $1.approximateByteCount }
            coveredThrough = chunk.upperBound
            seconds = PrimePlan.resized(seconds, after: batch.changes.count)
        }

        // Then backwards into the past, until the oldest instant aimed at.
        backfill: while state == .priming {
            if Task.isCancelled {
                walk.wasInterrupted = true
                break backfill
            }
            guard hasRoom() else {
                walk.wasInterrupted = true
                break backfill
            }
            guard
                let chunk = PrimePlan.chunk(
                    frontier: frontier,
                    windowStart: record.windowStart,
                    seconds: seconds
                )
            else {
                state = .covered
                break backfill
            }
            let batch: DatedHealthChanges
            switch await read(chunk) {
            case .read(let found):
                queries += 1
                batch = found
            case .interrupted:
                walk.wasInterrupted = true
                break backfill
            case .locked:
                walk.wasInterrupted = true
                walk.waitingForUnlock = true
                break backfill
            case .failed(let reason):
                walk.wasInterrupted = true
                failureReason = reason
                break backfill
            }
            if batch.isTruncated {
                if narrow() {
                    continue backfill
                }
                break backfill
            }

            walk.changes.append(contentsOf: batch.changes)
            walk.bytes += batch.changes.reduce(0) { $0 + $1.approximateByteCount }
            // The cursor moves to the chunk's edge, and only in memory. It
            // reaches the store when the destination has accepted the batch —
            // that ordering is the whole resumability story, and reversing it
            // would claim a stretch that a failed delivery never carried.
            frontier = chunk.lowerBound
            seconds = PrimePlan.resized(seconds, after: batch.changes.count)

            if frontier <= record.windowStart {
                state = .covered
                break backfill
            }
        }

        // A read that failed is recorded even when nothing moved, so the next
        // pass and any surface asking why can see it. It changes no cursor, so
        // the claim stays exactly what it was.
        if let failureReason, !Self.moved(frontier, coveredThrough, record) {
            try? await store.recordPrimeState(
                scope: scope,
                type: record.type,
                state: state,
                failureReason: failureReason,
                at: now
            )
        }

        guard Self.moved(frontier, coveredThrough, record) || state != record.state else {
            return walk
        }
        walk.commit = PendingPrimeCommit(
            type: record.type,
            baseFrontier: record.frontier,
            baseCoveredThrough: record.coveredThrough,
            frontier: frontier,
            coveredThrough: coveredThrough,
            chunkSeconds: seconds,
            addedRecordCount: walk.changes.count,
            state: state,
            failureReason: failureReason
        )
        return walk
    }

    /// How much of the intended window has genuinely been covered, from 0 to 1.
    ///
    /// Measured from where the prime began rather than from the covered
    /// stretch's own length, because the top-up keeps extending that stretch
    /// past the instant it started at — and a fraction that could exceed one is
    /// not a fraction of anything.
    static func coveredFraction(_ record: PrimeRecord) -> Double {
        let span = record.startedAt.timeIntervalSince(record.windowStart)
        guard span > 0 else {
            return 1
        }
        let covered = record.startedAt.timeIntervalSince(record.frontier)
        return min(1, max(0, covered / span))
    }

    /// Whether a type can be primed by a dated read at all.
    ///
    /// Series types cannot. Their real content is a second stream hanging off
    /// each sample — a route's coordinates, an ECG's voltages — paged by
    /// position inside that sample, and a dated query has nowhere to carry that
    /// position. Priming one would deliver a route with no points in it and
    /// then claim the window was covered. They are left to the sweep, which is
    /// built for exactly this, and they simply report no primed window, which
    /// is true.
    static func canPrime(_ type: HealthTypeKey) -> Bool {
        guard let entry = HealthTypeCatalog.entriesByIdentifier[type.rawValue] else {
            // A type the catalogue does not know is not excluded here on a
            // guess. The dated reader will refuse it if it cannot read it, and
            // a refusal leaves the frontier where it was.
            return true
        }
        return entry.family != .series
    }
}
