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
        /// The stretch each type has genuinely had delivered, as this batch
        /// will leave it.
        ///
        /// Built from what is about to be committed rather than from the store,
        /// for the same reason the coverage beside it is: the commit and the
        /// report travel in the same batch, so a window that widened is told to
        /// the receiver in the same breath as the records that widened it. Read
        /// from the store instead, every window would arrive one delivery late.
        var windows: [HealthTypeKey: CoverageReporter.PrimedWindow] = [:]
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

        let known = try await store.primeRecords(scope: scope)
            .filter { eligible.contains($0.type) }
        // Every type with a stretch to report, not only the ones this pass will
        // touch. A type whose backfill finished last week still holds its
        // months, and leaving it out would retract a true claim.
        for record in known {
            guard
                let covered = record.coveredWindow,
                let window = CoverageReporter.PrimedWindow(
                    from: covered.from,
                    through: covered.through
                )
            else {
                continue
            }
            round.windows[record.type] = window
        }

        let pending = known
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
                round.bytes < Self.primeByteCeiling
            else {
                round.wasInterrupted = true
                break
            }

            let walk = await walkPrime(
                record: record,
                scope: scope,
                source: datedSource,
                allowance: Self.primeRecordCeiling - round.changes.count,
                byteAllowance: Self.primeByteCeiling - round.bytes,
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
                if let window = CoverageReporter.PrimedWindow(
                    from: commit.frontier,
                    through: commit.coveredThrough
                ) {
                    round.windows[commit.type] = window
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
        // One length per walk. They measure different stretches of the same
        // type — this afternoon and some months ago — and a type can easily be
        // quiet in one and busy in the other. Shared, each walk hands the other
        // an estimate of a stretch it never read, which the other then spends
        // several queries disproving, on every pass, indefinitely.
        var backfillSeconds = record.chunkSeconds
        var topUpSeconds = record.topUpSeconds
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

        /// A shorter length to try after a chunk came back over capacity, or
        /// nil when the walk is already asking for the shortest it will.
        ///
        /// Narrows from the chunk's *actual* length rather than the length that
        /// was asked for, because those differ whenever a chunk was clipped by
        /// an edge — and asking again for a length that clips to the same
        /// window produces a byte-identical read and a guaranteed identical
        /// answer. A sparse type that had settled near the longest chunk and
        /// then meets a busy five minutes would spend nine reads of its budget
        /// discovering the same thing nine times.
        func narrowed(
            _ chunk: Range<Date>,
            from seconds: TimeInterval
        ) -> TimeInterval? {
            let asked = chunk.upperBound.timeIntervalSince(chunk.lowerBound)
            let effective = min(seconds, asked)
            guard !PrimePlan.isAtMinimum(effective) else {
                return nil
            }
            return PrimePlan.narrowed(effective)
        }

        /// What a walk says when it cannot narrow any further.
        ///
        /// A minute of one type overflowing a five-hundred record bite is not
        /// something the dated reader can page through without either dropping
        /// records or holding more than a background launch is given. It stops
        /// and says so. The sweep still reaches every one of these records, so
        /// this costs speed rather than data — and it keeps claiming exactly
        /// the stretch it had already delivered.
        let tooDense =
            "More records than one read can hold in the shortest window Hozz will ask for."

        // The leading edge, walked upwards so a half-finished top-up still
        // abuts what is already covered and can be recorded as it goes.
        //
        // The staleness gate lives here rather than only in the selection above,
        // because a type is also selected for having a backfill to do — and
        // without this, every type still working through its months would pay a
        // top-up query on every pass to discover that nothing had happened in
        // the last forty seconds. That is the cost this interval exists to
        // avoid, during the weeks when it applies to nearly every type.
        topUp: while
            state != .stalled,
            coveredThrough.addingTimeInterval(PrimePlan.topUpInterval) <= now
        {
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
                    seconds: topUpSeconds
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
                if let shorter = narrowed(chunk, from: topUpSeconds) {
                    topUpSeconds = shorter
                    continue topUp
                }
                // Deliberately does *not* mark the record stalled. A stall is a
                // statement about the backfill — the months this prime set out
                // to fetch — and a busy few minutes at the leading edge is not
                // evidence about them. Marking it here would freeze the record
                // out of every future pass, abandon a backfill that may be half
                // done, and make `isCovered` start reporting false about a
                // backfill that genuinely finished.
                topUpSeconds = PrimePlan.minimumChunk
                failureReason = tooDense
                Self.primeLog.notice(
                    "A type is too dense for a dated read at the shortest window."
                )
                break topUp
            }

            walk.changes.append(contentsOf: batch.changes)
            walk.bytes += batch.changes.reduce(0) { $0 + $1.approximateByteCount }
            coveredThrough = chunk.upperBound
            if PrimePlan.isFullLength(chunk, seconds: topUpSeconds) {
                topUpSeconds = PrimePlan.resized(
                    topUpSeconds,
                    after: batch.changes.count
                )
            }
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
                    seconds: backfillSeconds
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
                if let shorter = narrowed(chunk, from: backfillSeconds) {
                    backfillSeconds = shorter
                    continue backfill
                }
                backfillSeconds = PrimePlan.minimumChunk
                state = .stalled
                failureReason = tooDense
                Self.primeLog.notice(
                    "A type is too dense for a dated read at the shortest window."
                )
                break backfill
            }

            walk.changes.append(contentsOf: batch.changes)
            walk.bytes += batch.changes.reduce(0) { $0 + $1.approximateByteCount }
            // The cursor moves to the chunk's edge, and only in memory. It
            // reaches the store when the destination has accepted the batch —
            // that ordering is the whole resumability story, and reversing it
            // would claim a stretch that a failed delivery never carried.
            frontier = chunk.lowerBound
            // The months read fine, whatever the leading edge was doing. A
            // reason left over from the top-up would sit beside a state that
            // describes the backfill and read as a verdict on it.
            failureReason = nil
            if PrimePlan.isFullLength(chunk, seconds: backfillSeconds) {
                backfillSeconds = PrimePlan.resized(
                    backfillSeconds,
                    after: batch.changes.count
                )
            }

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

        // A length that was narrowed is worth keeping even when nothing else
        // moved. Without it a walk that spent nine reads finding out how dense
        // a stretch is would throw that away and spend them again next pass.
        guard
            Self.moved(frontier, coveredThrough, record)
                || state != record.state
                || backfillSeconds != record.chunkSeconds
                || topUpSeconds != record.topUpSeconds
        else {
            return walk
        }
        walk.commit = PendingPrimeCommit(
            type: record.type,
            baseFrontier: record.frontier,
            baseCoveredThrough: record.coveredThrough,
            frontier: frontier,
            coveredThrough: coveredThrough,
            chunkSeconds: backfillSeconds,
            topUpSeconds: topUpSeconds,
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
