import Foundation

/// A destination's delivery position and health.
public struct DeliveryStateRecord: Equatable, Sendable {
    public let destinationID: UUID
    public let state: String
    public let lastAttemptAt: Date?
    public let lastSuccessAt: Date?
    public let nextAttemptAt: Date?
    public let consecutiveFailures: Int
    public let pendingBatchID: UUID?
    public let nextSequence: Int
    public let deliveredRecords: Int
    public let detail: String?

    public init(
        destinationID: UUID,
        state: String,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        nextAttemptAt: Date? = nil,
        consecutiveFailures: Int = 0,
        pendingBatchID: UUID? = nil,
        nextSequence: Int = 0,
        deliveredRecords: Int = 0,
        detail: String? = nil
    ) {
        self.destinationID = destinationID
        self.state = state
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.nextAttemptAt = nextAttemptAt
        self.consecutiveFailures = consecutiveFailures
        self.pendingBatchID = pendingBatchID
        self.nextSequence = nextSequence
        self.deliveredRecords = deliveredRecords
        self.detail = detail
    }
}

public struct DeliveryReceiptRecord: Equatable, Sendable {
    public let destinationID: UUID
    public let attemptedAt: Date
    public let recordCount: Int
    public let byteCount: UInt64
    public let state: String
    public let detail: String?
    public let artifactName: String?

    public init(
        destinationID: UUID,
        attemptedAt: Date,
        recordCount: Int,
        byteCount: UInt64,
        state: String,
        detail: String?,
        artifactName: String?
    ) {
        self.destinationID = destinationID
        self.attemptedAt = attemptedAt
        self.recordCount = recordCount
        self.byteCount = byteCount
        self.state = state
        self.detail = detail
        self.artifactName = artifactName
    }
}

extension HozzStore {
    // MARK: - Destinations

    /// Destinations are stored as their own JSON so the delivery layer can
    /// evolve its configuration without a schema migration for every option.
    /// Secrets are never part of that JSON; they live in the Keychain.
    public func saveDestination(
        id: UUID,
        payload: Data,
        createdAt: Date,
        at date: Date = .now
    ) throws {
        try database.run(
            """
            INSERT INTO destination (id, payload, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                payload = excluded.payload,
                updated_at = excluded.updated_at;
            """,
            [
                .text(id.uuidString.lowercased()),
                .text(String(decoding: payload, as: UTF8.self)),
                .real(createdAt.timeIntervalSince1970),
                .real(date.timeIntervalSince1970)
            ]
        )
    }

    public func destinationPayloads() throws -> [(id: UUID, payload: Data)] {
        try database.query(
            "SELECT id, payload FROM destination ORDER BY created_at;"
        ) { row in
            guard let id = UUID(uuidString: row.text(0)) else {
                throw HozzStoreError.corruptStoredValue("destination id \(row.text(0))")
            }
            return (id: id, payload: Data(row.text(1).utf8))
        }
    }

    public func deleteDestination(id: UUID) throws {
        try database.run(
            "DELETE FROM destination WHERE id = ?;",
            [.text(id.uuidString.lowercased())]
        )
    }

    // MARK: - Delivery state

    public func deliveryState(for destinationID: UUID) throws -> DeliveryStateRecord? {
        try database.query(
            """
            SELECT destination_id, state, last_attempt_at, last_success_at,
                   next_attempt_at, consecutive_failures, pending_batch_id,
                   next_sequence, delivered_records, detail
            FROM delivery_state WHERE destination_id = ?;
            """,
            [.text(destinationID.uuidString.lowercased())],
            row: Self.deliveryStateRecord
        ).first
    }

    public func allDeliveryStates() throws -> [DeliveryStateRecord] {
        try database.query(
            """
            SELECT destination_id, state, last_attempt_at, last_success_at,
                   next_attempt_at, consecutive_failures, pending_batch_id,
                   next_sequence, delivered_records, detail
            FROM delivery_state;
            """,
            row: Self.deliveryStateRecord
        )
    }

    public func saveDeliveryState(_ record: DeliveryStateRecord) throws {
        try database.run(
            """
            INSERT INTO delivery_state (
                destination_id, state, last_attempt_at, last_success_at,
                next_attempt_at, consecutive_failures, pending_batch_id,
                next_sequence, delivered_records, detail
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(destination_id) DO UPDATE SET
                state = excluded.state,
                last_attempt_at = excluded.last_attempt_at,
                last_success_at = excluded.last_success_at,
                next_attempt_at = excluded.next_attempt_at,
                consecutive_failures = excluded.consecutive_failures,
                pending_batch_id = excluded.pending_batch_id,
                next_sequence = excluded.next_sequence,
                delivered_records = excluded.delivered_records,
                detail = excluded.detail;
            """,
            [
                .text(record.destinationID.uuidString.lowercased()),
                .text(record.state),
                record.lastAttemptAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                record.lastSuccessAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                record.nextAttemptAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .integer(Int64(record.consecutiveFailures)),
                record.pendingBatchID.map { .text($0.uuidString.lowercased()) } ?? .null,
                .integer(Int64(record.nextSequence)),
                .integer(Int64(record.deliveredRecords)),
                record.detail.map(SQLiteValue.text) ?? .null
            ]
        )
    }

    // MARK: - Receipts

    /// Appends a receipt and trims the history.
    ///
    /// The history is for the user to see what happened, not an audit log, so
    /// it is deliberately bounded rather than growing without limit.
    public func appendReceipt(
        _ receipt: DeliveryReceiptRecord,
        keeping limit: Int = 100
    ) throws {
        try database.transaction {
            try database.run(
                """
                INSERT INTO delivery_receipt (
                    destination_id, attempted_at, record_count, byte_count,
                    state, detail, artifact_name
                )
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """,
                [
                    .text(receipt.destinationID.uuidString.lowercased()),
                    .real(receipt.attemptedAt.timeIntervalSince1970),
                    .integer(Int64(receipt.recordCount)),
                    .integer(Int64(bitPattern: receipt.byteCount)),
                    .text(receipt.state),
                    receipt.detail.map(SQLiteValue.text) ?? .null,
                    receipt.artifactName.map(SQLiteValue.text) ?? .null
                ]
            )
            try database.run(
                """
                DELETE FROM delivery_receipt
                WHERE destination_id = ?
                  AND rowid NOT IN (
                    SELECT rowid FROM delivery_receipt
                    WHERE destination_id = ?
                    ORDER BY attempted_at DESC
                    LIMIT ?
                  );
                """,
                [
                    .text(receipt.destinationID.uuidString.lowercased()),
                    .text(receipt.destinationID.uuidString.lowercased()),
                    .integer(Int64(limit))
                ]
            )
        }
    }

    public func receipts(
        for destinationID: UUID,
        limit: Int = 50
    ) throws -> [DeliveryReceiptRecord] {
        try database.query(
            """
            SELECT destination_id, attempted_at, record_count, byte_count,
                   state, detail, artifact_name
            FROM delivery_receipt
            WHERE destination_id = ?
            ORDER BY attempted_at DESC
            LIMIT ?;
            """,
            [.text(destinationID.uuidString.lowercased()), .integer(Int64(limit))]
        ) { row in
            guard let id = UUID(uuidString: row.text(0)) else {
                throw HozzStoreError.corruptStoredValue("receipt id \(row.text(0))")
            }
            return DeliveryReceiptRecord(
                destinationID: id,
                attemptedAt: Date(timeIntervalSince1970: row.real(1)),
                recordCount: Int(row.integer(2)),
                byteCount: UInt64(bitPattern: row.integer(3)),
                state: row.text(4),
                detail: row.optionalText(5),
                artifactName: row.optionalText(6)
            )
        }
    }

    private static func deliveryStateRecord(
        _ row: SQLiteRow
    ) throws -> DeliveryStateRecord {
        guard let id = UUID(uuidString: row.text(0)) else {
            throw HozzStoreError.corruptStoredValue("delivery state id \(row.text(0))")
        }
        return DeliveryStateRecord(
            destinationID: id,
            state: row.text(1),
            lastAttemptAt: row.optionalReal(2).map(Date.init(timeIntervalSince1970:)),
            lastSuccessAt: row.optionalReal(3).map(Date.init(timeIntervalSince1970:)),
            nextAttemptAt: row.optionalReal(4).map(Date.init(timeIntervalSince1970:)),
            consecutiveFailures: Int(row.integer(5)),
            pendingBatchID: row.optionalText(6).flatMap(UUID.init(uuidString:)),
            nextSequence: Int(row.integer(7)),
            deliveredRecords: Int(row.integer(8)),
            detail: row.optionalText(9)
        )
    }
}
