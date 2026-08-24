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
                windowEnd: window.end,
                chunkSeconds: PrimePlan.initialChunk,
                at: now
            )
        }

        let pending = try await store.primeRecords(scope: scope)
            .filter { eligible.contains($0.type) }
            .filter { $0.state == .priming }
            .filter { $0.frontier > $0.windowStart }
        round.remains = !pending.isEmpty
        guard !pending.isEmpty else {
            return round
        }

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
                if commit.state == .priming {
                    round.remains = true
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

        return round
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

    /// Reads chunks of one type's window, newest first, until the budget ends.
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
        var seconds = record.chunkSeconds
        var state = PrimeState.priming
        var failureReason: String?
        var queries = 0

        loop: while true {
            if Task.isCancelled {
                walk.wasInterrupted = true
                break loop
            }
            guard
                walk.changes.count + PrimePlan.chunkCapacity <= allowance,
                walk.bytes < byteAllowance,
                queries < Self.primeQueriesPerType
            else {
                walk.wasInterrupted = true
                break loop
            }
            guard
                let chunk = PrimePlan.chunk(
                    frontier: frontier,
                    windowStart: record.windowStart,
                    seconds: seconds
                )
            else {
                state = .covered
                break loop
            }

            let batch: DatedHealthChanges
            do {
                batch = try await source.changes(
                    for: record.type,
                    from: chunk.lowerBound,
                    to: chunk.upperBound,
                    limit: PrimePlan.chunkCapacity
                )
            } catch {
                if error is CancellationError || Task.isCancelled {
                    // iOS taking its time back is the ordinary case, not a
                    // fault, and recording it as one would report a healthy
                    // type as broken.
                    walk.wasInterrupted = true
                    break loop
                }
                let failure = HealthKitFailure.classify(
                    error,
                    typeIdentifier: record.type.rawValue
                )
                walk.wasInterrupted = true
                if failure.kind == .deviceLocked {
                    walk.waitingForUnlock = true
                } else {
                    failureReason = failure.underlyingDescription
                    try? await store.recordPrimeState(
                        scope: scope,
                        type: record.type,
                        state: .priming,
                        failureReason: failure.underlyingDescription,
                        at: now
                    )
                }
                break loop
            }
            queries += 1

            if batch.isTruncated {
                // More in this stretch than a single bite can hold. Ask again
                // for a shorter one; nothing is delivered and the frontier has
                // not moved, so the retry costs a query and no correctness.
                if PrimePlan.isAtMinimum(seconds) {
                    // A minute of one type overflowing a five-hundred record
                    // bite is not something the dated reader can page through
                    // without either dropping records or holding more than a
                    // background launch is given. It stops and says so. The
                    // sweep still reaches every one of these records, so this
                    // costs speed rather than data — and a stalled prime keeps
                    // claiming exactly the window it had already delivered.
                    state = .stalled
                    failureReason =
                        "More records than one read can hold in the shortest window Hozz will ask for."
                    Self.primeLog.notice(
                        "A type is too dense for a dated read at the shortest window."
                    )
                    break loop
                }
                seconds = PrimePlan.narrowed(seconds)
                continue loop
            }

            walk.changes.append(contentsOf: batch.changes)
            walk.bytes += batch.changes.reduce(0) { $0 + $1.approximateByteCount }
            // The frontier moves to the chunk's start, and only in memory. It
            // reaches the store when the destination has accepted the batch —
            // that ordering is the whole resumability story, and reversing it
            // would claim a window that a failed delivery never carried.
            frontier = chunk.lowerBound
            seconds = PrimePlan.resized(seconds, after: batch.changes.count)

            if frontier <= record.windowStart {
                state = .covered
                break loop
            }
        }

        guard frontier < record.frontier || state != .priming else {
            return walk
        }
        walk.commit = PendingPrimeCommit(
            type: record.type,
            baseFrontier: record.frontier,
            frontier: frontier,
            chunkSeconds: seconds,
            addedRecordCount: walk.changes.count,
            state: state,
            failureReason: failureReason
        )
        return walk
    }

    /// How much of a window has genuinely been covered, from 0 to 1.
    static func coveredFraction(_ record: PrimeRecord) -> Double {
        let span = record.windowEnd.timeIntervalSince(record.windowStart)
        guard span > 0 else {
            return 1
        }
        let covered = record.windowEnd.timeIntervalSince(record.frontier)
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
