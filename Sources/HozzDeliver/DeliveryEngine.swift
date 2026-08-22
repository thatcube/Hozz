import Foundation
import HozzCore
import HozzStore

/// Owns the user's destinations and the state of delivering to each.
///
/// The engine never reads Health itself. It is handed already-encoded records
/// and is responsible only for getting them to a destination exactly once,
/// eventually, without losing them if the attempt fails.
public actor DeliveryEngine {
    /// Retry schedule after consecutive failures. Deliberately gentle: a
    /// destination that is down is usually a computer that is switched off, and
    /// hammering it costs battery for nothing.
    public static let backoff: [TimeInterval] = [
        30, 2 * 60, 10 * 60, 30 * 60, 2 * 60 * 60, 6 * 60 * 60
    ]

    private let store: HozzStore
    private let credentials: DestinationCredentials
    private let channels: [DestinationKind: any DeliveryChannel]
    private var cache: [UUID: Destination] = [:]
    private var isLoaded = false

    public init(
        store: HozzStore,
        credentials: DestinationCredentials = DestinationCredentials(),
        channels: [DestinationKind: any DeliveryChannel] = [
            .folder: FolderDeliveryChannel(),
            .restAPI: RESTDeliveryChannel()
        ]
    ) {
        self.store = store
        self.credentials = credentials
        self.channels = channels
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

    public func save(_ destination: Destination) async throws {
        try await loadIfNeeded()
        let payload = try JSONEncoder().encode(destination)
        try await store.saveDestination(
            id: destination.id,
            payload: payload,
            createdAt: destination.createdAt
        )
        cache[destination.id] = destination

        if try await store.deliveryState(for: destination.id) == nil {
            try await store.saveDeliveryState(
                DeliveryStateRecord(
                    destinationID: destination.id,
                    state: DeliveryState.idle.rawValue
                )
            )
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

    /// Destinations that are enabled, configured, and due to run.
    public func dueDestinations(
        now: Date = .now,
        ignoringCadence: Bool = false
    ) async throws -> [Destination] {
        try await loadIfNeeded()
        var due: [Destination] = []

        for destination in cache.values.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard destination.isEnabled, destination.isConfigured else {
                continue
            }
            if ignoringCadence {
                // An explicit "sync now" bypasses both the cadence and any
                // backoff: the user is standing there asking for an answer.
                due.append(destination)
                continue
            }
            guard destination.cadence != .manual else {
                continue
            }
            let state = try await store.deliveryState(for: destination.id)

            // A destination that failed is held off until its backoff expires,
            // so one unreachable endpoint cannot spin the whole pipeline.
            if let nextAttempt = state?.nextAttemptAt, nextAttempt > now {
                continue
            }
            if let lastSuccess = state?.lastSuccessAt,
               now.timeIntervalSince(lastSuccess) < destination.cadence.minimumInterval {
                continue
            }
            due.append(destination)
        }
        return due
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
        now: Date = .now
    ) async throws -> DeliveryReceipt {
        guard let channel = channels[destination.kind] else {
            throw DeliveryError.notConfigured
        }

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
            )
        )

        do {
            let receipt = try await channel.deliver(batch, to: destination)
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
                )
            )
            try await store.appendReceipt(Self.record(receipt))
            return receipt
        } catch {
            let failure = error as? DeliveryError
                ?? .transport(error.localizedDescription)
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
                )
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
                )
            )
            throw failure
        }
    }

    /// Sends a batch without touching the destination's recorded state.
    ///
    /// Used by the connection test, which must not look like a real delivery in
    /// the history or move any cursor.
    public func deliverWithoutRecording(
        _ batch: DeliveryBatch,
        to destination: Destination
    ) async throws -> DeliveryReceipt {
        guard let channel = channels[destination.kind] else {
            throw DeliveryError.notConfigured
        }
        return try await channel.deliver(batch, to: destination)
    }

    /// The next sequence number to use for a destination.
    public func nextSequence(for destinationID: UUID) async throws -> Int {
        try await store.deliveryState(for: destinationID)?.nextSequence ?? 0
    }

    /// Records that Hozz is waiting on iOS rather than on the destination.
    public func markWaitingForSystem(_ destinationID: UUID) async throws {
        guard let previous = try await store.deliveryState(for: destinationID) else {
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
            }
        }
        isLoaded = true
    }
}
