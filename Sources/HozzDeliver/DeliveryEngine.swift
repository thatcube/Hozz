import Foundation
import os
import HozzCore
import HozzStore

public struct DestinationSnapshot: Sendable {
    public let destination: Destination
    public let revision: Int64

    public init(destination: Destination, revision: Int64) {
        self.destination = destination
        self.revision = revision
    }
}

/// Owns the user's destinations and the state of delivering to each.
///
/// The engine never reads Health itself. It is handed already-encoded records
/// and is responsible only for getting them to a destination exactly once,
/// eventually, without losing them if the attempt fails.
public actor DeliveryEngine {
    private static let log = Logger(
        subsystem: "com.thatcube.Hozz",
        category: "delivery"
    )

    /// Retry schedule after consecutive failures. Deliberately gentle: a
    /// destination that is down is usually a computer that is switched off, and
    /// hammering it costs battery for nothing.
    public static let backoff: [TimeInterval] = [
        30, 2 * 60, 10 * 60, 30 * 60, 2 * 60 * 60, 6 * 60 * 60
    ]

    private let store: HozzStore
    private let credentials: DestinationCredentials
    private let channels: [DestinationKind: any DeliveryChannel]
    private let endpointRepairResolver:
        (@Sendable (Destination) async -> URL?)?
    private var cache: [UUID: Destination] = [:]
    private var revisions: [UUID: Int64] = [:]
    private var isLoaded = false

    public init(
        store: HozzStore,
        credentials: DestinationCredentials = DestinationCredentials(),
        channels: [DestinationKind: any DeliveryChannel] = [
            .folder: FolderDeliveryChannel(),
            .restAPI: RESTDeliveryChannel(),
            .mqtt: MQTTDeliveryChannel()
        ],
        endpointRepairResolver:
            (@Sendable (Destination) async -> URL?)? = nil
    ) {
        self.store = store
        self.credentials = credentials
        self.channels = channels
        self.endpointRepairResolver = endpointRepairResolver
    }

    // MARK: - Destinations

    public func destinations() async throws -> [Destination] {
        try await loadIfNeeded()
        return cache.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func destination(id: UUID) async throws -> Destination? {
        try await loadIfNeeded()
        return cache[id]
    }

    public func save(_ destination: Destination, now: Date = .now) async throws {
        try await loadIfNeeded()
        let previous = cache[destination.id]

        // Broadening what a destination accepts replays its history.
        //
        // This stops a bounded window, or a lossy format that recorded an
        // explicit omission, from losing records permanently. The cursors have
        // already moved past bytes the broader setting wants, so they are not
        // coming round again on their own. Clearing this destination's cursors
        // makes it read Health from the start; stable record identifiers let a
        // receiver absorb repeats.
        //
        // Re-reading is the cheap side of this trade and losing a reading is the
        // expensive one. A type that was excluded was never drained at all, so
        // switching it back on needs nothing.
        //
        // The marker is written first and cleared last, because the two writes
        // this needs cannot be made atomic from here. A crash between them would
        // otherwise leave the earlier starting point on disk with the cursors
        // intact and nothing left to notice, which is exactly the loss being
        // guarded against.
        var destination = destination
        Self.resolveFloor(&destination, previous: previous, now: now)
        let widenedWindow = previous.map {
            !$0.deliveryFloor.covers(destination.deliveryFloor)
        } ?? false
        let broadenedToLossless = previous.map {
            !$0.format.isLossless && destination.format.isLossless
        } ?? false
        if widenedWindow {
            destination.options[Destination.pendingReplayKey] = "1"
        }

        let stored = try await write(
            destination,
            replayingIfOmitted: broadenedToLossless
        )
        if stored.isReplayPending {
            try await settleReplay(for: stored)
        }

        // Re-saving a destination is how the user says "I fixed it", so a
        // parked destination is released. Without this, re-picking a moved
        // folder would leave it excluded from every automatic pass forever.
        let existing = try await store.deliveryState(for: destination.id)
        if existing == nil || existing?.state == DeliveryState.needsAttention.rawValue {
            try await store.saveDeliveryState(
                DeliveryStateRecord(
                    destinationID: destination.id,
                    state: DeliveryState.idle.rawValue,
                    lastSuccessAt: existing?.lastSuccessAt,
                    consecutiveFailures: 0,
                    nextSequence: existing?.nextSequence ?? 0,
                    deliveredRecords: existing?.deliveredRecords ?? 0
                )
            )
        }
    }

    /// Pins a bounded window to a concrete date, once.
    ///
    /// The date is worked out only when the choice itself changes, or when a
    /// bounded window has none yet. Re-picking the same option keeps the date
    /// already in force: moving it forward would quietly exclude readings that
    /// were being delivered a moment earlier, which is the failure this whole
    /// arrangement exists to remove.
    static func resolveFloor(
        _ destination: inout Destination,
        previous: Destination?,
        now: Date
    ) {
        guard destination.deliveryWindow.isBounded else {
            // Nothing is excluded, so a stored date would only be misleading.
            destination.options[Destination.windowFloorKey] = nil
            return
        }
        if previous?.deliveryWindow == destination.deliveryWindow,
           let inForce = previous?.options[Destination.windowFloorKey] {
            destination.options[Destination.windowFloorKey] = inForce
            return
        }
        guard let floor = destination.deliveryWindow.floor(now: now) else {
            return
        }
        destination.options[Destination.windowFloorKey] = Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        ).format(floor)
    }

    /// Persists a destination and keeps the in-memory copy in step.
    @discardableResult
    private func write(
        _ destination: Destination,
        replayingIfOmitted: Bool = false
    ) async throws -> Destination {
        let payload = try JSONEncoder().encode(destination)
        var replay = destination
        replay.options[Destination.pendingReplayKey] = "1"
        let expectedRevision = revisions[destination.id]
        let result = try await store.saveDestination(
            id: destination.id,
            payload: payload,
            replayPayloadIfOmitted: replayingIfOmitted
                ? try JSONEncoder().encode(replay)
                : nil,
            expectedRevision: expectedRevision,
            createdAt: destination.createdAt
        )
        let stored = result.usedReplayPayload ? replay : destination
        if let currentRevision = revisions[destination.id],
           currentRevision > result.revision {
            return cache[destination.id] ?? stored
        }
        cache[destination.id] = stored
        revisions[destination.id] = result.revision
        return stored
    }

    /// Applies one automatic repair to the latest stored destination, but only
    /// while it is still the configuration the caller captured.
    ///
    /// Starting from the persisted payload rather than the stale snapshot is
    /// what makes this a field patch: a refreshed bookmark cannot roll back a
    /// format edit, endpoint change, or any unrelated bookkeeping.
    private func patchDestination(
        id: UUID,
        expectedRevision: Int64,
        update: @escaping @Sendable (inout Destination) -> Void
    ) async throws -> Destination {
        let result = try await store.patchDestination(
            id: id,
            expectedRevision: expectedRevision
        ) { payload in
            var destination = try JSONDecoder().decode(
                Destination.self,
                from: payload
            )
            update(&destination)
            return try JSONEncoder().encode(destination)
        }
        let patched = try JSONDecoder().decode(
            Destination.self,
            from: result.payload
        )
        if revisions[id] == expectedRevision {
            cache[id] = patched
        }
        return patched
    }

    /// Carries out a replay this destination is owed, and only then forgets it.
    ///
    /// Safe to call more than once: clearing cursors that are already cleared
    /// does nothing, and the marker is removed last so an interruption leaves
    /// the work still owed rather than silently done.
    private func settleReplay(for destination: Destination) async throws {
        Self.log.info("A destination broadened what it accepts; its history will replay.")
        let expectedRevision = try revision(for: destination.id)
        try await store.deleteStreamState(scope: .destination(destination.id))
        _ = try await patchDestination(
            id: destination.id,
            expectedRevision: expectedRevision
        ) {
            $0.options[Destination.pendingReplayKey] = nil
        }
    }

    /// Removes a destination and the secret that belonged to it.
    public func delete(id: UUID) async throws {
        try await loadIfNeeded()
        if let destination = cache[id] {
            try? credentials.delete(for: destination.credentialKey)
        }
        try await store.deleteDestination(id: id)
        cache[id] = nil
        revisions[id] = nil
    }

    public func setSecret(_ secret: String?, for destination: Destination) throws {
        if let secret, !secret.isEmpty {
            try credentials.save(secret, for: destination.credentialKey)
        } else {
            try credentials.delete(for: destination.credentialKey)
        }
    }

    public func hasSecret(for destination: Destination) -> Bool {
        ((try? credentials.secret(for: destination.credentialKey)) ?? nil) != nil
    }

    // MARK: - State

    public func state(for destinationID: UUID) async throws -> DeliveryStateRecord? {
        try await store.deliveryState(for: destinationID)
    }

    public func receipts(
        for destinationID: UUID,
        limit: Int = 50
    ) async throws -> [DeliveryReceiptRecord] {
        try await store.receipts(for: destinationID, limit: limit)
    }

    /// Remembers which per-type coverage this destination has been told.
    ///
    /// Called only after a delivery is accepted, so a refused batch leaves the
    /// coverage still owed and it is offered again next pass. Deliberately not
    /// routed through ``save(_:now:)``: that method interprets a changed
    /// delivery window as a request to replay history, and this is bookkeeping
    /// about what has already been sent rather than a change the user made.
    public func recordCoverageDigest(
        _ digest: String,
        for destinationID: UUID
    ) async throws {
        try await loadIfNeeded()
        guard let destination = cache[destinationID] else {
            return
        }
        guard destination.options[Destination.coverageDigestKey] != digest else {
            return
        }
        let expectedRevision = try revision(for: destinationID)
        _ = try await patchDestination(
            id: destinationID,
            expectedRevision: expectedRevision
        ) {
            $0.options[Destination.coverageDigestKey] = digest
        }
    }

    /// When this destination's current coverage was observed.
    ///
    /// Returns the moment already recorded when the coverage has not changed,
    /// so a batch rebuilt after a refusal is byte-for-byte the batch that was
    /// refused — which is what lets the receiver recognise the retry rather
    /// than storing it twice. A changed set is dated to now and written down
    /// immediately, *before* anything is delivered, because an observation is
    /// not a claim about what a destination received.
    ///
    /// Failing to write the moment is not worth failing the pass over: the
    /// worst case is one batch that a retry cannot reproduce exactly, which is
    /// where this started rather than something worse.
    public func coverageObservation(
        digest: String,
        now: Date = .now,
        for destinationID: UUID
    ) async -> Date {
        guard
            let destination = try? await loadedDestination(destinationID)
        else {
            return now
        }
        let observation = CoverageReporter.observation(
            matching: digest,
            storedDigest: destination.observedCoverageDigest,
            storedMoment: destination.observedCoverageMoment,
            now: now
        )
        guard observation.isNew else {
            return observation.moment
        }

        if let expectedRevision = revisions[destinationID] {
            let moment = Destination.observedCoverageText(observation.moment)
            _ = try? await patchDestination(
                id: destinationID,
                expectedRevision: expectedRevision
            ) {
                $0.options[Destination.coverageObservedDigestKey] = digest
                $0.options[Destination.coverageObservedAtKey] = moment
            }
        }

        // Why this value has to survive being written down, kept from the
        // change that first diagnosed it:
        //
        // An instant carries more precision than the text it is written as, and
        // formatting then parsing does not always land back on the same double:
        // an instant written as `…57.869Z` can parse to one that formats as
        // `…57.868Z`. The next pass stamps its batch from the stored value, so
        // if the two differ the payloads differ by one character — same length,
        // same meaning, different bytes — and the batch identity is a hash of
        // those bytes. The receiver is handed what it should recognise as a
        // retry and stores it a second time, which on a receiver too old to
        // read these lines is a quarantined row per type per delivery, for
        // ever.
        //
        // That diagnosis was reached by round-tripping the moment through the
        // same text the next pass would read, which does work — but only while
        // the text written down is the text of the *unparsed* instant. Storing
        // the text of the parsed one instead is a one-line change that reads
        // like tidying and silently brings the bug back, because two passes
        // then derive their instant from two different strings. The exact form
        // has no such ordering to remember: the value is the value, whichever
        // side of a parse it arrives from.
        return observation.moment
    }

    private func loadedDestination(_ id: UUID) async throws -> Destination? {
        try await loadIfNeeded()
        return cache[id]
    }

    /// Destinations that are enabled, configured, and due to run.
    public func dueDestinations(
        now: Date = .now,
        ignoringCadence: Bool = false
    ) async throws -> [Destination] {
        let snapshots = try await dueDestinationSnapshots(
            now: now,
            ignoringCadence: ignoringCadence
        )
        return snapshots.map(\.destination)
    }

    public func dueDestinationSnapshots(
        now: Date = .now,
        ignoringCadence: Bool = false
    ) async throws -> [DestinationSnapshot] {
        try await loadIfNeeded()
        var due: [DestinationSnapshot] = []
        let snapshots = try cache.values
            .sorted(by: { $0.createdAt < $1.createdAt })
            .map {
                DestinationSnapshot(
                    destination: $0,
                    revision: try revision(for: $0.id)
                )
            }

        for snapshot in snapshots {
            let destination = snapshot.destination
            guard destination.isEnabled, destination.isConfigured else {
                continue
            }
            // A destination this build only half understands is never run, not
            // even when the user asks. Delivering it would mean substituting a
            // format, a schedule, or a precision they did not choose and
            // reporting that as a success.
            guard destination.isUsable else {
                continue
            }
            if ignoringCadence {
                // An explicit "sync now" bypasses both the cadence and any
                // backoff: the user is standing there asking for an answer.
                due.append(snapshot)
                continue
            }
            guard destination.cadence != .manual else {
                continue
            }
            let state = try await store.deliveryState(for: destination.id)

            // A destination that needs the user to fix something is not retried
            // on a timer. Without this it would be attempted on every single
            // pass, which is both a battery drain and, worse, a permanent
            // failure that no amount of waiting clears.
            if state?.state == DeliveryState.needsAttention.rawValue {
                continue
            }

            // A destination that failed transiently is held off until its
            // backoff expires, so one unreachable endpoint cannot spin the
            // whole pipeline.
            if let nextAttempt = state?.nextAttemptAt, nextAttempt > now {
                continue
            }
            if let lastSuccess = state?.lastSuccessAt,
               now.timeIntervalSince(lastSuccess) < destination.cadence.minimumInterval {
                continue
            }
            due.append(snapshot)
        }
        return due
    }

    private func revision(for destinationID: UUID) throws -> Int64 {
        guard let revision = revisions[destinationID] else {
            throw HozzStoreError.corruptStoredValue(
                "missing configuration revision for destination "
                    + destinationID.uuidString
            )
        }
        return revision
    }

    private func validateDestinationRevision(
        id: UUID,
        expectedRevision: Int64?
    ) async throws {
        guard let expectedRevision else {
            return
        }
        try await store.validateDestinationRevision(
            id: id,
            expectedRevision: expectedRevision
        )
    }

    // MARK: - Delivering

    /// Sends one batch, recording the outcome either way.
    ///
    /// A failure is never silent: it is written as a receipt with an honest
    /// state, and the destination is scheduled for another attempt.
    @discardableResult
    public func deliver(
        _ batch: DeliveryBatch,
        to destination: Destination,
        expectedRevision: Int64? = nil,
        now: Date = .now
    ) async throws -> DeliveryReceipt {
        let capturedRevision = expectedRevision ?? revisions[destination.id]
        try await validateDestinationRevision(
            id: destination.id,
            expectedRevision: capturedRevision
        )
        if let detail = destination.unsupportedDescription {
            // Recorded rather than thrown quietly, so the dashboard shows the
            // destination needing attention instead of it simply never
            // delivering anything again.
            try await recordUnusable(
                destination,
                detail: detail,
                expectedRevision: capturedRevision,
                now: now
            )
            throw DeliveryError.unsupportedSettings(detail)
        }
        guard let channel = channels[destination.kind] else {
            throw DeliveryError.notConfigured
        }

        // The destination's starting point is applied here rather than while
        // reading Health, and that separation is deliberate: acquisition stays
        // anchor-driven so a retroactively written sample is never missed, and
        // only the *sending* is narrowed. The date comes from the destination
        // rather than from `now`, so a retry an hour later — or a day later —
        // judges the same readings by the same line. See `DeliveryWindow`.
        let windowed: WindowedBatch
        do {
            windowed = try destination.deliveryWindow.apply(
                to: batch,
                destination: destination
            )
        } catch let error as DeliveryError {
            try await recordFailure(
                error,
                destination: destination,
                batch: batch,
                expectedRevision: capturedRevision,
                now: now
            )
            throw error
        }

        guard let windowedBatch = windowed.batch else {
            // Every record fell outside the window the user chose. Nothing was
            // sent, and that is a complete delivery of nothing rather than a
            // failure — but it is written down with the count, because a person
            // watching a destination receive nothing deserves to be told why.
            try await recordEmptyWindow(
                destination,
                excluded: windowed.excludedRecords,
                sequence: batch.sequence,
                expectedRevision: capturedRevision,
                now: now
            )
            return DeliveryReceipt(
                destinationID: destination.id,
                attemptedAt: now,
                recordCount: 0,
                byteCount: 0,
                state: .delivered,
                detail: Self.windowDetail(excluded: windowed.excludedRecords)
            )
        }

        // Values are converted into the destination's chosen units last, once
        // what is being sent has been settled. Nothing about the conversion can
        // add or remove a record — it only ever rewrites a number and the unit
        // beside it, together — so it cannot affect anything decided above.
        let batch = Self.inChosenUnits(windowedBatch, for: destination)

        let previous = try await store.deliveryState(for: destination.id)
        try await store.saveDeliveryState(
            DeliveryStateRecord(
                destinationID: destination.id,
                state: DeliveryState.delivering.rawValue,
                lastAttemptAt: now,
                lastSuccessAt: previous?.lastSuccessAt,
                nextAttemptAt: nil,
                consecutiveFailures: previous?.consecutiveFailures ?? 0,
                pendingBatchID: batch.id,
                nextSequence: max(previous?.nextSequence ?? 0, batch.sequence + 1),
                deliveredRecords: previous?.deliveredRecords ?? 0,
                detail: nil
            ),
            expectedDestinationRevision: capturedRevision
        )

        var destination = destination
        // A computer's address is not permanent: routers reassign them, laptops
        // move network, ports change when an app restarts. Without this, a
        // destination that worked yesterday retries a dead address forever and
        // the user is told only that it timed out.
        if let repairedEndpoint = await repairedEndpointIfNeeded(
            for: destination
        ) {
            if let capturedRevision {
                destination = try await patchDestination(
                    id: destination.id,
                    expectedRevision: capturedRevision
                ) {
                    $0.endpointURL = repairedEndpoint
                }
            } else {
                destination.endpointURL = repairedEndpoint
            }
        }

        do {
            try await validateDestinationRevision(
                id: destination.id,
                expectedRevision: capturedRevision
            )
            let delivered = try await channel.deliver(batch, to: destination)

            // Persist a refreshed folder bookmark so an ordinary folder move
            // does not decay into a permanent failure later.
            if let refreshed = delivered.refreshedBookmark,
               let capturedRevision {
                _ = try await patchDestination(
                    id: destination.id,
                    expectedRevision: capturedRevision
                ) {
                    $0.folderBookmark = refreshed
                }
            }

            // What the window left out is carried on the successful receipt as
            // well as the empty one. A destination that receives eleven of two
            // hundred readings has succeeded, and the other hundred and
            // eighty-nine are still a fact the user is entitled to.
            let receipt = windowed.excludedRecords > 0
                ? DeliveryReceipt(
                    destinationID: delivered.destinationID,
                    attemptedAt: delivered.attemptedAt,
                    recordCount: delivered.recordCount,
                    byteCount: delivered.byteCount,
                    state: delivered.state,
                    detail: [
                        delivered.detail,
                        Self.windowDetail(excluded: windowed.excludedRecords)
                    ].compactMap { $0 }.joined(separator: " "),
                    artifactName: delivered.artifactName,
                    refreshedBookmark: delivered.refreshedBookmark
                )
                : delivered

            try await validateDestinationRevision(
                id: destination.id,
                expectedRevision: capturedRevision
            )
            try await store.saveDeliveryState(
                DeliveryStateRecord(
                    destinationID: destination.id,
                    state: DeliveryState.delivered.rawValue,
                    lastAttemptAt: now,
                    lastSuccessAt: now,
                    nextAttemptAt: nil,
                    consecutiveFailures: 0,
                    pendingBatchID: nil,
                    nextSequence: max(previous?.nextSequence ?? 0, batch.sequence + 1),
                    deliveredRecords: (previous?.deliveredRecords ?? 0) + batch.recordCount,
                    detail: nil
                ),
                expectedDestinationRevision: capturedRevision
            )
            try await store.appendReceipt(
                Self.record(receipt),
                expectedDestinationRevision: capturedRevision
            )
            return receipt
        } catch let error as HozzStoreError {
            throw error
        } catch {
            let failure = error as? DeliveryError
                ?? .transport(error.localizedDescription)
            try await validateDestinationRevision(
                id: destination.id,
                expectedRevision: capturedRevision
            )
            try await recordFailure(
                failure,
                destination: destination,
                batch: batch,
                expectedRevision: capturedRevision,
                now: now
            )
            throw failure
        }
    }

    /// Rewrites a batch into the destination's chosen units.
    ///
    /// The record count is carried across untouched, because a conversion never
    /// changes it — and the identifier is re-derived from the new bytes,
    /// because it must. Two batches holding the same readings in different
    /// units are different bytes and have to be different batches, or a
    /// receiver honouring the idempotency key would keep whichever arrived
    /// first and silently discard the other.
    static func inChosenUnits(
        _ batch: DeliveryBatch,
        for destination: Destination
    ) -> DeliveryBatch {
        let converted = PayloadUnits.apply(
            destination.unitPreferences,
            to: batch.payload,
            format: batch.format
        )
        guard converted != batch.payload else {
            return batch
        }
        return DeliveryBatch(
            id: DeliveryBatch.identifier(for: converted),
            sequence: batch.sequence,
            createdAt: batch.createdAt,
            recordCount: batch.recordCount,
            payload: converted,
            format: batch.format
        )
    }

    /// Writes an honest record of a delivery that did not happen.
    ///
    /// Shared by every failure path, including the one where a delivery window
    /// could not be applied, so that no route out of `deliver` can return
    /// without the attempt appearing in the destination's history.
    private func recordFailure(
        _ failure: DeliveryError,
        destination: Destination,
        batch: DeliveryBatch,
        expectedRevision: Int64?,
        now: Date
    ) async throws {
        let previous = try await store.deliveryState(for: destination.id)
        let failures = (previous?.consecutiveFailures ?? 0) + 1
        let state = failure.deliveryState

        try await store.saveDeliveryState(
            DeliveryStateRecord(
                destinationID: destination.id,
                state: state.rawValue,
                lastAttemptAt: now,
                lastSuccessAt: previous?.lastSuccessAt,
                nextAttemptAt: Self.nextAttempt(
                    after: failures,
                    from: now,
                    isTransient: failure.isTransient
                ),
                consecutiveFailures: failures,
                // The batch is kept so the same identifier is reused on the
                // next attempt, which is what makes a retry idempotent.
                pendingBatchID: batch.id,
                nextSequence: previous?.nextSequence ?? batch.sequence,
                deliveredRecords: previous?.deliveredRecords ?? 0,
                detail: failure.errorDescription
            ),
            expectedDestinationRevision: expectedRevision
        )
        try await store.appendReceipt(
            DeliveryReceiptRecord(
                destinationID: destination.id,
                attemptedAt: now,
                recordCount: batch.recordCount,
                byteCount: UInt64(batch.payload.count),
                state: state.rawValue,
                detail: failure.errorDescription,
                artifactName: nil
            ),
            expectedDestinationRevision: expectedRevision
        )
    }

    /// Records a pass where the destination's window excluded everything.
    ///
    /// Counted as a success, because it is one: Hozz read Health, found nothing
    /// the user asked this destination to receive, and sent nothing. Treating
    /// it as a failure would put a permanent warning on a destination that is
    /// working exactly as configured.
    private func recordEmptyWindow(
        _ destination: Destination,
        excluded: Int,
        sequence: Int,
        expectedRevision: Int64?,
        now: Date
    ) async throws {
        let previous = try await store.deliveryState(for: destination.id)
        let detail = Self.windowDetail(excluded: excluded)
        try await store.saveDeliveryState(
            DeliveryStateRecord(
                destinationID: destination.id,
                state: DeliveryState.delivered.rawValue,
                lastAttemptAt: now,
                lastSuccessAt: now,
                nextAttemptAt: nil,
                consecutiveFailures: 0,
                pendingBatchID: nil,
                nextSequence: max(previous?.nextSequence ?? 0, sequence + 1),
                deliveredRecords: previous?.deliveredRecords ?? 0,
                detail: detail
            ),
            expectedDestinationRevision: expectedRevision
        )
        try await store.appendReceipt(
            DeliveryReceiptRecord(
                destinationID: destination.id,
                attemptedAt: now,
                recordCount: 0,
                byteCount: 0,
                state: DeliveryState.delivered.rawValue,
                detail: detail,
                artifactName: nil
            ),
            expectedDestinationRevision: expectedRevision
        )
    }

    /// What to say about records a window left out.
    ///
    /// Said plainly and with a number, because "nothing arrived" and "nothing
    /// arrived because you asked for today only" look identical from the
    /// receiving end, and only one of them is worth investigating.
    static func windowDetail(excluded: Int) -> String {
        excluded == 1
            ? "1 reading was older than this destination's limit and was not sent."
            : "\(excluded) readings were older than this destination's limit "
                + "and were not sent."
    }

    /// Sends a batch without touching the destination's recorded state.
    ///
    /// Used by the connection test, which must not look like a real delivery in
    /// the history or move any cursor.
    /// Re-resolves a computer that is no longer answering where it used to be.
    ///
    /// Only applies to a destination this person's own computer published, and
    /// only when the recorded address has actually stopped responding — so a
    /// working setup is never disturbed, and a destination the user typed by
    /// hand is never quietly repointed somewhere else.
    private func repairedEndpointIfNeeded(
        for destination: Destination
    ) async -> URL? {
        guard destination.kind == .restAPI else {
            return nil
        }
        if let endpointRepairResolver {
            return await endpointRepairResolver(destination)
        }
        guard let current = destination.endpointURL?.absoluteString,
              let savedToken = (try? credentials.secret(
                  for: destination.credentialKey
              )) ?? nil,
              let known = Self.matchingReceiver(
                  token: savedToken,
                  among: SharedReceiverStore(
                      accessGroup: SharedReceiverStore.resolvedAccessGroup()
                  ).publishedAll()
              )
        else {
            return nil
        }

        let probe = ReceiverProbe()
        if await probe.isReceiver(current) {
            return nil
        }
        guard let working = await probe.firstReachable(
            among: known.endpoints.filter { $0 != current }
        ) else {
            return nil
        }

        Self.log.info("A destination moved address and was re-resolved.")
        return URL(string: working)
    }

    /// The record belonging to this destination, not whichever Mac published
    /// most recently.
    ///
    /// Names and addresses both change. The token already stored in the
    /// destination's Keychain is the stable fact that identifies its Mac, and
    /// prevents a hand-entered REST destination with a similar name from being
    /// silently repointed.
    static func matchingReceiver(
        token: String,
        among receivers: [SharedReceiver]
    ) -> SharedReceiver? {
        receivers.first { $0.token == token }
    }

    /// Parks a destination Hozz cannot safely use, with a reason to show.
    private func recordUnusable(
        _ destination: Destination,
        detail: String,
        expectedRevision: Int64?,
        now: Date
    ) async throws {
        let previous = try await store.deliveryState(for: destination.id)
        try await store.saveDeliveryState(
            DeliveryStateRecord(
                destinationID: destination.id,
                state: DeliveryState.needsAttention.rawValue,
                lastAttemptAt: now,
                lastSuccessAt: previous?.lastSuccessAt,
                nextAttemptAt: nil,
                consecutiveFailures: previous?.consecutiveFailures ?? 0,
                pendingBatchID: previous?.pendingBatchID,
                nextSequence: previous?.nextSequence ?? 0,
                deliveredRecords: previous?.deliveredRecords ?? 0,
                detail: detail
            ),
            expectedDestinationRevision: expectedRevision
        )
        try await store.appendReceipt(
            DeliveryReceiptRecord(
                destinationID: destination.id,
                attemptedAt: now,
                recordCount: 0,
                byteCount: 0,
                state: DeliveryState.needsAttention.rawValue,
                detail: detail,
                artifactName: nil
            ),
            expectedDestinationRevision: expectedRevision
        )
    }

    public func deliverWithoutRecording(
        _ batch: DeliveryBatch,
        to destination: Destination
    ) async throws -> DeliveryReceipt {
        try await loadIfNeeded()
        if let detail = destination.unsupportedDescription {
            throw DeliveryError.unsupportedSettings(detail)
        }
        guard let channel = channels[destination.kind] else {
            throw DeliveryError.notConfigured
        }
        let savedBeforeTest = cache[destination.id]
        let savedRevision = revisions[destination.id]
        let mayPersistRepair =
            savedBeforeTest?.kind == destination.kind
                && savedBeforeTest?.endpointURL == destination.endpointURL
        var target = destination
        if let endpoint = await repairedEndpointIfNeeded(for: destination) {
            target.endpointURL = endpoint
        }
        let receipt = try await channel.deliver(batch, to: target)
        if mayPersistRepair,
           target != destination,
           let savedBeforeTest,
           let savedRevision,
           cache[destination.id] == savedBeforeTest,
           revisions[destination.id] == savedRevision {
            let repairedEndpoint = target.endpointURL
            _ = try? await patchDestination(
                id: destination.id,
                expectedRevision: savedRevision
            ) {
                $0.endpointURL = repairedEndpoint
            }
        }
        return receipt
    }

    /// The next sequence number to use for a destination.
    public func nextSequence(for destinationID: UUID) async throws -> Int {
        try await store.deliveryState(for: destinationID)?.nextSequence ?? 0
    }

    /// Records that Hozz is waiting on iOS rather than on the destination.
    ///
    /// Only a state that is genuinely idle is overwritten. Reading, then
    /// writing back every field, would otherwise let this roll back a delivery
    /// that succeeded while it was suspended.
    public func markWaitingForSystem(_ destinationID: UUID) async throws {
        guard let previous = try await store.deliveryState(for: destinationID) else {
            return
        }
        guard
            previous.state == DeliveryState.idle.rawValue
                || previous.state == DeliveryState.delivered.rawValue
        else {
            return
        }
        try await store.saveDeliveryState(
            DeliveryStateRecord(
                destinationID: destinationID,
                state: DeliveryState.waitingForSystem.rawValue,
                lastAttemptAt: previous.lastAttemptAt,
                lastSuccessAt: previous.lastSuccessAt,
                nextAttemptAt: previous.nextAttemptAt,
                consecutiveFailures: previous.consecutiveFailures,
                pendingBatchID: previous.pendingBatchID,
                nextSequence: previous.nextSequence,
                deliveredRecords: previous.deliveredRecords,
                detail: previous.detail
            )
        )
    }

    public static func nextAttempt(
        after failures: Int,
        from now: Date,
        isTransient: Bool
    ) -> Date? {
        guard isTransient else {
            // A folder that was deleted will not fix itself, so Hozz stops
            // retrying and says so instead of burning battery.
            return nil
        }
        let index = min(max(failures - 1, 0), backoff.count - 1)
        return now.addingTimeInterval(backoff[index])
    }

    private static func record(_ receipt: DeliveryReceipt) -> DeliveryReceiptRecord {
        DeliveryReceiptRecord(
            destinationID: receipt.destinationID,
            attemptedAt: receipt.attemptedAt,
            recordCount: receipt.recordCount,
            byteCount: receipt.byteCount,
            state: receipt.state.rawValue,
            detail: receipt.detail,
            artifactName: receipt.artifactName
        )
    }

    private func loadIfNeeded() async throws {
        guard !isLoaded else {
            return
        }
        let decoder = JSONDecoder()
        for row in try await store.destinationPayloads() {
            if let destination = try? decoder.decode(Destination.self, from: row.payload) {
                cache[row.id] = destination
                revisions[row.id] = row.revision
            }
        }
        isLoaded = true

        // A replay that was written down but never carried out is finished here,
        // on the first load after whatever interrupted it. Doing this at load
        // rather than only at save is what makes the marker worth having: a
        // destination whose window was widened just before the app was killed
        // gets its history back without the user having to touch it again.
        for destination in cache.values where destination.isReplayPending {
            try? await settleReplay(for: destination)
        }
    }
}
