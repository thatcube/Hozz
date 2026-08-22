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

public struct IngestResult: Hashable, Sendable {
    public let stored: Int
    public let deleted: Int
    public let duplicate: Bool
    public let unreadable: Int

    public init(stored: Int, deleted: Int, duplicate: Bool, unreadable: Int) {
        self.stored = stored
        self.deleted = deleted
        self.duplicate = duplicate
        self.unreadable = unreadable
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
        guard version < 2 else {
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
                """
            )
            try database.execute("PRAGMA user_version = 2")
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
            unreadable: batch.unreadableCount
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
