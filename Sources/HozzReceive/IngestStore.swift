import Foundation
import HozzCore
import HozzStore

/// A summary of one type's data, for dashboards and for answering questions.
public struct TypeSummary: Hashable, Sendable {
    public let type: String
    public let recordCount: Int
    public let unit: String?
    public let earliest: Date?
    public let latest: Date?

    public init(
        type: String,
        recordCount: Int,
        unit: String?,
        earliest: Date?,
        latest: Date?
    ) {
        self.type = type
        self.recordCount = recordCount
        self.unit = unit
        self.earliest = earliest
        self.latest = latest
    }
}

/// One bucket of aggregated values.
public struct AggregateBucket: Hashable, Sendable {
    public let start: Date
    public let sum: Double
    public let average: Double
    public let minimum: Double
    public let maximum: Double
    public let count: Int

    public init(
        start: Date,
        sum: Double,
        average: Double,
        minimum: Double,
        maximum: Double,
        count: Int
    ) {
        self.start = start
        self.sum = sum
        self.average = average
        self.minimum = minimum
        self.maximum = maximum
        self.count = count
    }
}

/// How to group values over time.
public enum BucketSize: String, CaseIterable, Sendable {
    case hour
    case day
    case week
    case month

    /// SQLite `strftime` pattern that collapses a timestamp to its bucket.
    var format: String {
        switch self {
        case .hour: "%Y-%m-%dT%H:00:00Z"
        case .day: "%Y-%m-%dT00:00:00Z"
        case .week: "%Y-W%W"
        case .month: "%Y-%m-01T00:00:00Z"
        }
    }
}

/// A phone that has delivered to this computer.
public struct KnownDevice: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    public let deliveredRecords: Int

    public init(
        name: String,
        firstSeenAt: Date,
        lastSeenAt: Date,
        deliveredRecords: Int
    ) {
        self.name = name
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.deliveredRecords = deliveredRecords
    }
}

/// A characteristic as the Mac holds it.
public struct StoredCharacteristic: Hashable, Sendable, Identifiable {
    public var id: String { type }
    public let type: String
    public let state: String?
    public let value: String?
    public let rawValue: Int?
    public let readAt: Date?

    public init(
        type: String,
        state: String?,
        value: String?,
        rawValue: Int?,
        readAt: Date?
    ) {
        self.type = type
        self.state = state
        self.value = value
        self.rawValue = rawValue
        self.readAt = readAt
    }

    /// The identifier without its HealthKit prefix, for reading.
    public var displayName: String {
        let prefix = "HKCharacteristicTypeIdentifier"
        var name = type.hasPrefix(prefix)
            ? String(type.dropFirst(prefix.count))
            : type
        name = name.replacingOccurrences(
            of: #"([a-z0-9])([A-Z])"#,
            with: "$1 $2",
            options: .regularExpression
        )
        return name
    }

    /// Whether Health actually gave a value, as opposed to answering that
    /// there is not one. Both are real answers and neither is a failure.
    public var isKnown: Bool {
        state == "known" && value != nil
    }
}

/// Records stored without being understood, grouped by kind.
public struct UnhandledSummary: Hashable, Sendable, Identifiable {
    public var id: String { kind }
    public let kind: String
    public let count: Int
    public let reason: String?
    public let lastSeenAt: Date?

    public init(kind: String, count: Int, reason: String?, lastSeenAt: Date?) {
        self.kind = kind
        self.count = count
        self.reason = reason
        self.lastSeenAt = lastSeenAt
    }
}

public struct IngestResult: Hashable, Sendable {
    public let stored: Int
    public let deleted: Int
    public let duplicate: Bool
    /// Lines that were not JSON at all. There is nothing to store and nothing
    /// to interpret, so this stays a bare count.
    public let unreadable: Int
    public let characteristics: Int
    /// Records stored without being understood. Not a loss — the bytes are on
    /// disk — but a signal that this receiver is behind the phone.
    public let unhandled: Int

    public init(
        stored: Int,
        deleted: Int,
        duplicate: Bool,
        unreadable: Int,
        characteristics: Int = 0,
        unhandled: Int = 0
    ) {
        self.stored = stored
        self.deleted = deleted
        self.duplicate = duplicate
        self.unreadable = unreadable
        self.characteristics = characteristics
        self.unhandled = unhandled
    }
}

/// The desktop's copy of the Health data a phone has delivered.
///
/// This is a genuine local database rather than a folder of files, because the
/// point of receiving on a computer is to be able to *ask questions* — over
/// years, across types, without loading gigabytes into memory. It is the same
/// SQLite layer the phone uses, so there is one set of durability rules.
///
/// Nothing here ever leaves the machine.
public actor IngestStore {
    private let database: SQLiteDatabase
    private let directory: URL

    public init(directory: URL) throws {
        try StoreLocation.prepareDirectory(directory)
        self.directory = directory
        self.database = try SQLiteDatabase(
            url: directory.appending(path: "hozz-received.sqlite")
        )
        try Self.migrate(database)
    }

    public func close() {
        database.close()
    }

    private static func migrate(_ database: SQLiteDatabase) throws {
        let version = try database.query("PRAGMA user_version", row: { $0.integer(0) })
            .first ?? 0
        guard version < 3 else {
            return
        }
        try database.transaction {
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS sample (
                    id TEXT NOT NULL,
                    type TEXT NOT NULL,
                    kind TEXT,
                    start_date TEXT NOT NULL,
                    end_date TEXT NOT NULL,
                    value REAL,
                    unit TEXT,
                    source_name TEXT,
                    raw BLOB NOT NULL,
                    received_at TEXT NOT NULL,
                    PRIMARY KEY (id, type)
                );

                CREATE INDEX IF NOT EXISTS sample_type_start
                    ON sample (type, start_date);
                CREATE INDEX IF NOT EXISTS sample_start
                    ON sample (start_date);

                -- A batch that arrives twice must not be stored twice. The key
                -- is the content hash the phone sends, so a retried delivery
                -- and a re-drained larger batch are correctly distinguished.
                -- Which phones have delivered, and when they were last heard
                -- from. Kept on disk because "is it working" is the question
                -- the user actually has, and an answer that resets every time
                -- the app relaunches cannot answer it.
                CREATE TABLE IF NOT EXISTS device (
                    name TEXT PRIMARY KEY,
                    first_seen_at TEXT NOT NULL,
                    last_seen_at TEXT NOT NULL,
                    delivered_records INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE IF NOT EXISTS batch (
                    key TEXT PRIMARY KEY,
                    received_at TEXT NOT NULL,
                    record_count INTEGER NOT NULL
                );

                -- Facts about the person rather than measurements of a moment:
                -- date of birth, biological sex, blood type, and the rest.
                --
                -- These cannot live in `sample`. That table requires a start
                -- date, and a characteristic has none — it is true until it is
                -- not, rather than measured at an instant. Giving it a fake
                -- date would make a standing fact look like a reading taken at
                -- export time, which is exactly what the phone refuses to do
                -- when it encodes them.
                --
                -- Keyed by type, so re-delivery replaces the value rather than
                -- appending a second one. A person has one blood type, not a
                -- time series of them.
                CREATE TABLE IF NOT EXISTS characteristic (
                    type TEXT PRIMARY KEY,
                    -- Health's own answer: known, notSet, unavailable, and so
                    -- on. Kept because a missing value that means "not shared"
                    -- and one that means "never set" are different facts, and
                    -- an assistant should not have to guess which it is.
                    state TEXT,
                    value TEXT,
                    raw_value INTEGER,
                    read_at TEXT,
                    raw BLOB NOT NULL,
                    received_at TEXT NOT NULL
                );

                -- Records this Mac could not interpret, kept whole.
                --
                -- A phone running a newer build can send a record shape this
                -- receiver has never heard of. Dropping it loses data
                -- permanently, because the phone has already advanced its
                -- cursor; refusing the batch wedges the destination, because
                -- the same bytes would be resent forever and every later
                -- record behind them would be blocked. Storing it
                -- uninterpreted is the only option that neither loses nor
                -- wedges, and the count is surfaced so someone can see there
                -- is something here to teach the receiver about.
                CREATE TABLE IF NOT EXISTS unhandled_record (
                    fingerprint TEXT PRIMARY KEY,
                    kind TEXT,
                    reason TEXT,
                    raw BLOB NOT NULL,
                    received_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS unhandled_kind
                    ON unhandled_record (kind);
                """
            )
            try database.execute("PRAGMA user_version = 3")
        }
    }

    /// Stores a batch, ignoring one that has already been stored.
    public func ingest(
        _ batch: ParsedBatch,
        idempotencyKey: String?,
        now: Date = .now
    ) throws -> IngestResult {
        if let idempotencyKey, try isKnownBatch(idempotencyKey) {
            return IngestResult(
                stored: 0,
                deleted: 0,
                duplicate: true,
                unreadable: batch.unreadableCount
            )
        }

        var stored = 0
        var deleted = 0
        var storedCharacteristics = 0
        var storedUnhandled = 0
        let timestamp = Timestamps.text(from: now)

        // One transaction, so a batch is either wholly stored or wholly absent.
        // A half-applied batch would be indistinguishable from a complete one
        // on the next delivery, and the missing half would never be resent.
        try database.transaction {
            for record in batch.records {
                try database.run(
                    """
                    INSERT INTO sample
                        (id, type, kind, start_date, end_date, value, unit,
                         source_name, raw, received_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id, type) DO UPDATE SET
                        kind = excluded.kind,
                        start_date = excluded.start_date,
                        end_date = excluded.end_date,
                        value = excluded.value,
                        unit = excluded.unit,
                        source_name = excluded.source_name,
                        raw = excluded.raw,
                        received_at = excluded.received_at
                    """,
                    [
                        .text(record.id),
                        .text(record.type),
                        record.kind.map { SQLiteValue.text($0) } ?? .null,
                        .text(Timestamps.text(from: record.startDate)),
                        .text(Timestamps.text(from: record.endDate)),
                        record.value.map { SQLiteValue.real($0) } ?? .null,
                        record.unit.map { SQLiteValue.text($0) } ?? .null,
                        record.sourceName.map { SQLiteValue.text($0) } ?? .null,
                        .blob(record.raw),
                        .text(timestamp)
                    ]
                )
                stored += 1
            }

            for deletion in batch.deletions {
                if let startDate = deletion.startDate, let type = deletion.type {
                    // The metrics shape carries no sample identifier, so a
                    // deletion can only be matched the same way its upserts
                    // were keyed.
                    try database.run(
                        "DELETE FROM sample WHERE type = ? AND start_date = ?",
                        [.text(type), .text(Timestamps.text(from: startDate))]
                    )
                } else {
                    try database.run(
                        "DELETE FROM sample WHERE id = ?",
                        [.text(deletion.id)]
                    )
                }
                deleted += database.changeCount
            }

            // A characteristic is a current fact, so re-delivery replaces the
            // value rather than appending another. Stored in the same
            // transaction as everything else, so a batch is still wholly
            // present or wholly absent.
            for characteristic in batch.characteristics {
                try database.run(
                    """
                    INSERT INTO characteristic
                        (type, state, value, raw_value, read_at, raw, received_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (type) DO UPDATE SET
                        state = excluded.state,
                        value = excluded.value,
                        raw_value = excluded.raw_value,
                        read_at = excluded.read_at,
                        raw = excluded.raw,
                        received_at = excluded.received_at
                    """,
                    [
                        .text(characteristic.type),
                        characteristic.state.map { SQLiteValue.text($0) } ?? .null,
                        characteristic.value.map { SQLiteValue.text($0) } ?? .null,
                        characteristic.rawValue
                            .map { SQLiteValue.integer(Int64($0)) } ?? .null,
                        characteristic.readAt
                            .map { SQLiteValue.text(Timestamps.text(from: $0)) }
                            ?? .null,
                        .blob(characteristic.raw),
                        .text(timestamp)
                    ]
                )
                storedCharacteristics += 1
            }

            // Kept rather than dropped. Keyed by content, so a retried
            // delivery stores one row instead of a second copy.
            for record in batch.unhandled {
                try database.run(
                    """
                    INSERT INTO unhandled_record
                        (fingerprint, kind, reason, raw, received_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (fingerprint) DO UPDATE SET
                        kind = excluded.kind,
                        reason = excluded.reason,
                        raw = excluded.raw
                    """,
                    [
                        .text(record.fingerprint),
                        record.kind.map { SQLiteValue.text($0) } ?? .null,
                        .text(record.reason),
                        .blob(record.raw),
                        .text(timestamp)
                    ]
                )
                storedUnhandled += 1
            }

            if let idempotencyKey {
                try database.run(
                    "INSERT OR REPLACE INTO batch (key, received_at, record_count) VALUES (?, ?, ?)",
                    [
                        .text(idempotencyKey),
                        .text(timestamp),
                        .integer(Int64(batch.records.count))
                    ]
                )
            }
        }

        return IngestResult(
            stored: stored,
            deleted: deleted,
            duplicate: false,
            unreadable: batch.unreadableCount,
            characteristics: storedCharacteristics,
            unhandled: storedUnhandled
        )
    }

    private func isKnownBatch(_ key: String) throws -> Bool {
        try !database.query(
            "SELECT 1 FROM batch WHERE key = ?",
            [.text(key)],
            row: { $0.integer(0) }
        ).isEmpty
    }

    /// Records that a phone delivered, and how much.
    public func noteDelivery(
        from device: String,
        records: Int,
        at date: Date = .now
    ) throws {
        let stamp = Timestamps.text(from: date)
        try database.run(
            """
            INSERT INTO device (name, first_seen_at, last_seen_at, delivered_records)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (name) DO UPDATE SET
                last_seen_at = excluded.last_seen_at,
                delivered_records = delivered_records + excluded.delivered_records
            """,
            [.text(device), .text(stamp), .text(stamp), .integer(Int64(records))]
        )
    }

    /// Every phone that has delivered, most recently heard from first.
    public func devices() throws -> [KnownDevice] {
        try database.query(
            """
            SELECT name, first_seen_at, last_seen_at, delivered_records
            FROM device ORDER BY last_seen_at DESC
            """,
            row: { row in
                KnownDevice(
                    name: row.text(0),
                    firstSeenAt: Timestamps.date(from: row.text(1)) ?? .distantPast,
                    lastSeenAt: Timestamps.date(from: row.text(2)) ?? .distantPast,
                    deliveredRecords: Int(row.integer(3))
                )
            }
        )
    }

    public func totalRecordCount() throws -> Int {
        Int(try database.query("SELECT COUNT(*) FROM sample", row: { $0.integer(0) }).first ?? 0)
    }

    /// Every type that has data, with enough detail to render a list.
    public func summaries() throws -> [TypeSummary] {
        try database.query(
            """
            SELECT type, COUNT(*), MAX(unit), MIN(start_date), MAX(start_date)
            FROM sample
            GROUP BY type
            ORDER BY type
            """,
            row: { row in
                TypeSummary(
                    type: row.text(0),
                    recordCount: Int(row.integer(1)),
                    unit: row.optionalText(2),
                    earliest: row.optionalText(3).flatMap(Timestamps.date(from:)),
                    latest: row.optionalText(4).flatMap(Timestamps.date(from:))
                )
            }
        )
    }

    /// Every characteristic the phone has sent, most useful first.
    ///
    /// These are the context that makes the measurements interpretable — a
    /// resting heart rate of 48 means something different at 34 than at 70 —
    /// so they are read as a set rather than one at a time.
    public func characteristics() throws -> [StoredCharacteristic] {
        try database.query(
            """
            SELECT type, state, value, raw_value, read_at
              FROM characteristic
             ORDER BY type
            """,
            row: { row in
                StoredCharacteristic(
                    type: row.text(0),
                    state: row.optionalText(1),
                    value: row.optionalText(2),
                    rawValue: row.optionalInteger(3).map { Int($0) },
                    readAt: row.optionalText(4).flatMap(Timestamps.date(from:))
                )
            }
        )
    }

    /// Records stored without being understood, grouped by kind.
    ///
    /// Surfaced so "this receiver is behind the phone" is a visible state
    /// rather than a silent one. The bytes are safe either way.
    public func unhandledSummary() throws -> [UnhandledSummary] {
        try database.query(
            """
            SELECT COALESCE(kind, 'unknown'), COUNT(*), MAX(reason), MAX(received_at)
              FROM unhandled_record
             GROUP BY COALESCE(kind, 'unknown')
             ORDER BY COUNT(*) DESC
            """,
            row: { row in
                UnhandledSummary(
                    kind: row.text(0),
                    count: Int(row.integer(1)),
                    reason: row.optionalText(2),
                    lastSeenAt: row.optionalText(3).flatMap(Timestamps.date(from:))
                )
            }
        )
    }

    public func unhandledCount() throws -> Int {
        Int(
            try database.query(
                "SELECT COUNT(*) FROM unhandled_record",
                row: { $0.integer(0) }
            ).first ?? 0
        )
    }

    /// Aggregates one type into time buckets.
    ///
    /// Both `sum` and `average` are returned rather than one "value", because
    /// which is correct depends entirely on the type: summing heart rate is
    /// meaningless, and averaging step count understates a day. The caller — or
    /// the person reading it — has to choose, so hiding one of them would
    /// invite a confidently wrong answer.
    public func aggregate(
        type: String,
        bucket: BucketSize,
        from start: Date? = nil,
        to end: Date? = nil
    ) throws -> [AggregateBucket] {
        var sql = """
            SELECT strftime('\(bucket.format)', start_date) AS bucket,
                   SUM(value), AVG(value), MIN(value), MAX(value), COUNT(*)
            FROM sample
            WHERE type = ? AND value IS NOT NULL
            """
        var parameters: [SQLiteValue] = [.text(type)]
        if let start {
            sql += " AND start_date >= ?"
            parameters.append(.text(Timestamps.text(from: start)))
        }
        if let end {
            sql += " AND start_date <= ?"
            parameters.append(.text(Timestamps.text(from: end)))
        }
        sql += " GROUP BY bucket ORDER BY bucket"

        return try database.query(sql, parameters) { row in
            AggregateBucket(
                start: Timestamps.date(from: row.text(0))
                    ?? Self.weekBucketDate(row.text(0))
                    ?? .distantPast,
                sum: row.real(1),
                average: row.real(2),
                minimum: row.real(3),
                maximum: row.real(4),
                count: Int(row.integer(5))
            )
        }
    }

    /// Raw samples, newest first, for inspection and export.
    public func samples(
        type: String? = nil,
        from start: Date? = nil,
        to end: Date? = nil,
        limit: Int = 1000
    ) throws -> [HealthRecord] {
        var sql = """
            SELECT id, type, kind, start_date, end_date, value, unit, source_name, raw
            FROM sample WHERE 1 = 1
            """
        var parameters: [SQLiteValue] = []
        if let type {
            sql += " AND type = ?"
            parameters.append(.text(type))
        }
        if let start {
            sql += " AND start_date >= ?"
            parameters.append(.text(Timestamps.text(from: start)))
        }
        if let end {
            sql += " AND start_date <= ?"
            parameters.append(.text(Timestamps.text(from: end)))
        }
        sql += " ORDER BY start_date DESC LIMIT ?"
        parameters.append(.integer(Int64(limit)))

        return try database.query(sql, parameters) { row in
            HealthRecord(
                id: row.text(0),
                type: row.text(1),
                kind: row.optionalText(2),
                startDate: Timestamps.date(from: row.text(3)) ?? .distantPast,
                endDate: Timestamps.date(from: row.text(4)) ?? .distantPast,
                value: row.optionalReal(5),
                unit: row.optionalText(6),
                sourceName: row.optionalText(7),
                raw: row.blob(8) ?? Data()
            )
        }
    }

    /// `%Y-W%W` is not a timestamp, so it needs converting back separately.
    private static func weekBucketDate(_ text: String) -> Date? {
        let parts = text.split(separator: "-W")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let week = Int(parts[1]) else {
            return nil
        }
        var components = DateComponents()
        components.yearForWeekOfYear = year
        components.weekOfYear = max(week, 1)
        components.weekday = 2
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: components)
    }
}
