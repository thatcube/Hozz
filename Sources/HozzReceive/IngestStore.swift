import Foundation
import HozzCore
import HozzStore

/// One reading from inside a quantity series, back out of the store.
public struct QuantitySeriesReading: Hashable, Sendable {
    /// Its absolute position in the sample, which is what makes it the same
    /// reading across a replay rather than merely another one.
    public let offset: Int
    public let value: Double
    public let unit: String?
    public let startDate: Date?
    public let endDate: Date?

    public init(
        offset: Int,
        value: Double,
        unit: String?,
        startDate: Date?,
        endDate: Date?
    ) {
        self.offset = offset
        self.value = value
        self.unit = unit
        self.startDate = startDate
        self.endDate = endDate
    }
}

/// How much of one expanded sample has actually arrived.
public struct QuantitySeriesState: Hashable, Sendable {
    public let sampleID: String
    public let type: String?
    /// What the phone said it wrote. `nil` until the end marker arrives, which
    /// is itself the honest answer to "is this finished": not yet.
    public let exportedReadings: Int?
    public let readingsHeld: Int

    public init(
        sampleID: String,
        type: String?,
        exportedReadings: Int?,
        readingsHeld: Int
    ) {
        self.sampleID = sampleID
        self.type = type
        self.exportedReadings = exportedReadings
        self.readingsHeld = readingsHeld
    }

    /// Whether everything the phone said it sent is here.
    ///
    /// False while the end marker is missing, because a series with no end
    /// marker is one still in flight — calling it complete would be a guess
    /// dressed as a fact.
    public var isComplete: Bool {
        guard let exportedReadings else {
            return false
        }
        return readingsHeld >= exportedReadings
    }
}

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

    /// The chart granularity this bucket is, so there is one set of rules about
    /// where a day begins rather than two that can drift apart.
    var granularity: ChartGranularity {
        switch self {
        case .hour: .hour
        case .day: .day
        case .week: .week
        case .month: .month
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

/// What a promotion pass recovered.
public struct PromotionResult: Hashable, Sendable {
    /// Records that were quarantined and are now stored properly.
    public let promoted: Int
    /// Records this parser still cannot read. They stay quarantined, and are
    /// not looked at again until the parser changes.
    public let stillUnhandled: Int

    public init(promoted: Int, stillUnhandled: Int) {
        self.promoted = promoted
        self.stillUnhandled = stillUnhandled
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
    /// Visible to the module rather than this file so the dashboard queries can
    /// live in files of their own. They are still actor-isolated, so every read
    /// is serialised against ingest exactly as it was before.
    let database: SQLiteDatabase
    /// Visible to the module for the same reason as `database`: the storage
    /// report needs to size the files on disk, not only the rows in them.
    let storeDirectory: URL

    public init(directory: URL) throws {
        try StoreLocation.prepareDirectory(directory)
        self.storeDirectory = directory
        self.database = try SQLiteDatabase(
            url: directory.appending(path: "hozz-received.sqlite")
        )
        try Self.migrate(database)
        // Opening the store is the moment a newer parser first meets an older
        // database, so it is where anything quarantined by a previous version
        // gets its second reading. On a healthy receiver this is one indexed
        // lookup that matches nothing.
        try? Self.promoteUnhandledRecords(in: database)
    }

    public func close() {
        database.close()
    }

    private static func migrate(_ database: SQLiteDatabase) throws {
        let version = try database.query("PRAGMA user_version", row: { $0.integer(0) })
            .first ?? 0
        guard version < 8 else {
            return
        }
        try database.transaction {
            // Before the schema below, not after, because that schema creates
            // an index on `parser_version`. A receiver upgrading from version
            // 3 already has `unhandled_record` without the column, so
            // CREATE TABLE IF NOT EXISTS leaves it alone and the index then
            // refers to a column that does not exist — which fails the whole
            // transaction and leaves the database unopenable rather than
            // merely unmigrated.
            //
            // An empty result means the table is absent, which is a fresh
            // install: nothing to alter, and the schema below creates it with
            // the column already present.
            //
            // The default of 0 is deliberately below every real parser
            // version, so rows quarantined before promotion existed are all
            // reconsidered exactly once.
            let quarantineColumns = try database.query(
                "PRAGMA table_info(unhandled_record)",
                row: { $0.text(1) }
            )
            if !quarantineColumns.isEmpty,
               !quarantineColumns.contains("parser_version") {
                try database.execute(
                    """
                    ALTER TABLE unhandled_record
                        ADD COLUMN parser_version INTEGER NOT NULL DEFAULT 0
                    """
                )
            }

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
                -- `parser_version` is the version of the parser that failed
                -- to read this row. It is what makes quarantine temporary
                -- rather than terminal: when the parser learns a shape, the
                -- promotion pass reconsiders exactly the rows an older parser
                -- gave up on, and leaves the rest alone.
                CREATE TABLE IF NOT EXISTS unhandled_record (
                    fingerprint TEXT PRIMARY KEY,
                    kind TEXT,
                    reason TEXT,
                    raw BLOB NOT NULL,
                    received_at TEXT NOT NULL,
                    parser_version INTEGER NOT NULL DEFAULT 0
                );

                CREATE INDEX IF NOT EXISTS unhandled_kind
                    ON unhandled_record (kind);
                -- The promotion pass asks "anything an older parser gave up
                -- on?", which on a healthy receiver matches nothing at all.
                CREATE INDEX IF NOT EXISTS unhandled_parser_version
                    ON unhandled_record (parser_version);

                -- One row per ECG reading.
                --
                -- These do not belong in `sample`. An ECG has no single value,
                -- so it landed there with an empty one, and its voltage pages
                -- landed beside it as more rows of the same type — which made
                -- "how many ECGs do I have" answer 2 for one reading, and made
                -- the classification, the thing a person actually wants to
                -- know, invisible.
                CREATE TABLE IF NOT EXISTS electrocardiogram (
                    id TEXT PRIMARY KEY,
                    start_date TEXT NOT NULL,
                    end_date TEXT,
                    classification TEXT,
                    classification_raw INTEGER,
                    symptoms_status TEXT,
                    average_heart_rate REAL,
                    sampling_hz REAL,
                    -- What the watch said it recorded. Compared against the
                    -- pages actually held, so a partial waveform is never
                    -- presented as a whole one.
                    expected_voltages INTEGER,
                    source_name TEXT,
                    raw BLOB NOT NULL,
                    received_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS ecg_start ON electrocardiogram (start_date);

                -- Voltages arrive in fixed-offset pages that may be delivered
                -- out of order, more than once, or not at all. Keyed by
                -- sequence so a replayed page overwrites rather than
                -- duplicates, and ordered by offset on read so arrival order
                -- does not matter.
                CREATE TABLE IF NOT EXISTS electrocardiogram_voltage_page (
                    sample_id TEXT NOT NULL,
                    sequence INTEGER NOT NULL,
                    offset INTEGER NOT NULL,
                    point_count INTEGER NOT NULL,
                    points BLOB NOT NULL,
                    PRIMARY KEY (sample_id, sequence)
                );

                CREATE INDEX IF NOT EXISTS ecg_page_sample
                    ON electrocardiogram_voltage_page (sample_id, offset);

                -- A hearing test is a set of thresholds per frequency, not one
                -- number, so it gets the same treatment for the same reason.
                CREATE TABLE IF NOT EXISTS audiogram (
                    id TEXT PRIMARY KEY,
                    start_date TEXT NOT NULL,
                    end_date TEXT,
                    source_name TEXT,
                    raw BLOB NOT NULL,
                    received_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS audiogram_start ON audiogram (start_date);

                -- Mood entries keep their sample row as well as this one:
                -- valence is a real number on a real scale, so it charts and
                -- compares through the ordinary tools. What does not fit a
                -- single column lives here.
                CREATE TABLE IF NOT EXISTS state_of_mind (
                    id TEXT PRIMARY KEY,
                    start_date TEXT NOT NULL,
                    end_date TEXT,
                    valence REAL NOT NULL,
                    classification TEXT,
                    -- momentaryEmotion or dailyMood. Averaging the two mixes a
                    -- snapshot with a summary of a whole day.
                    kind_of_entry TEXT,
                    labels TEXT,
                    associations TEXT,
                    source_name TEXT,
                    raw BLOB NOT NULL,
                    received_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS mood_start ON state_of_mind (start_date);

                -- A dose event's answer is its status, not a number. Only
                -- `taken` means the medicine was taken; skipped, snoozed and
                -- never-answered are three different ways of not taking it,
                -- and collapsing them answers "did I take my medication?"
                -- wrongly, which is worse than not answering.
                CREATE TABLE IF NOT EXISTS medication_dose (
                    id TEXT PRIMARY KEY,
                    start_date TEXT NOT NULL,
                    log_status TEXT NOT NULL,
                    schedule_type TEXT,
                    dose_quantity REAL,
                    scheduled_dose_quantity REAL,
                    unit TEXT,
                    medication_name TEXT,
                    medication_form TEXT,
                    source_name TEXT,
                    raw BLOB NOT NULL,
                    received_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS dose_start ON medication_dose (start_date);
                CREATE INDEX IF NOT EXISTS dose_medication
                    ON medication_dose (medication_name, start_date);

                -- What Health computed about how a workout went. The workout
                -- keeps its `sample` row as well — a workout's own number is
                -- its duration — so it still appears in type lists and counts.
                -- This holds the aggregates that row cannot.
                CREATE TABLE IF NOT EXISTS workout_detail (
                    id TEXT PRIMARY KEY,
                    start_date TEXT NOT NULL,
                    end_date TEXT,
                    activity_type INTEGER,
                    duration_seconds REAL,
                    source_name TEXT,
                    received_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS workout_detail_start
                    ON workout_detail (start_date);

                -- One row per measured quantity per workout, rather than a
                -- column per quantity: Health decides which statistics a
                -- workout carries, and a fixed set of columns would silently
                -- drop the ones this build had not thought of.
                CREATE TABLE IF NOT EXISTS workout_statistic (
                    workout_id TEXT NOT NULL,
                    -- Empty for the workout as a whole; otherwise the leg.
                    activity_id TEXT NOT NULL DEFAULT '',
                    type TEXT NOT NULL,
                    unit TEXT,
                    sum REAL,
                    average REAL,
                    minimum REAL,
                    maximum REAL,
                    PRIMARY KEY (workout_id, activity_id, type)
                );

                -- A triathlon is one workout and three efforts, and an average
                -- across all three describes none of them.
                CREATE TABLE IF NOT EXISTS workout_activity (
                    id TEXT PRIMARY KEY,
                    workout_id TEXT NOT NULL,
                    ordinal INTEGER NOT NULL,
                    activity_type INTEGER,
                    start_date TEXT NOT NULL,
                    end_date TEXT
                );

                CREATE INDEX IF NOT EXISTS workout_activity_workout
                    ON workout_activity (workout_id, ordinal);

                -- The readings behind a quantity aggregate. Kept out of
                -- `sample` on purpose: they carry their parent's type
                -- identifier, so a page stored there counts as a heart-rate
                -- reading when it is the packaging several hundred of them
                -- arrived in.
                --
                -- Keyed by sequence like the voltage pages, and for the same
                -- reason: a page replayed byte-for-byte overwrites itself
                -- rather than appearing twice.
                CREATE TABLE IF NOT EXISTS quantity_series_page (
                    sample_id TEXT NOT NULL,
                    type TEXT NOT NULL,
                    sequence INTEGER NOT NULL,
                    offset INTEGER NOT NULL,
                    reading_count INTEGER NOT NULL,
                    unit TEXT,
                    start_date TEXT NOT NULL,
                    end_date TEXT,
                    readings BLOB NOT NULL,
                    PRIMARY KEY (sample_id, sequence)
                );

                CREATE INDEX IF NOT EXISTS quantity_series_page_sample
                    ON quantity_series_page (sample_id, offset);

                CREATE INDEX IF NOT EXISTS quantity_series_page_type
                    ON quantity_series_page (type, start_date);

                -- One small row per expanded sample, holding the single fact
                -- its end marker adds: how many readings the phone actually
                -- wrote. Compared with what the pages hold, it tells a series
                -- the phone exported short apart from one where a page went
                -- missing on the way here. Deliberately narrow — no blob —
                -- because there is one of these per series and repeating the
                -- aggregate would cost more rows than the readings do.
                CREATE TABLE IF NOT EXISTS quantity_series (
                    sample_id TEXT PRIMARY KEY,
                    type TEXT NOT NULL,
                    exported_readings INTEGER NOT NULL,
                    start_date TEXT NOT NULL,
                    end_date TEXT
                );

                CREATE TABLE IF NOT EXISTS audiogram_point (
                    audiogram_id TEXT NOT NULL,
                    frequency REAL NOT NULL,
                    ear TEXT NOT NULL,
                    sensitivity REAL,
                    unit TEXT,
                    masked INTEGER,
                    -- A clamped reading is a bound, not a measurement: the
                    -- difference between "90 dB" and "at least 90 dB".
                    clamped INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (audiogram_id, frequency, ear)
                );
                """
            )

            try Self.rehomeMisfiledSeriesPages(database)

            try database.execute("PRAGMA user_version = 8")
        }
    }

    /// Moves series pages an earlier build filed as ordinary samples.
    ///
    /// A build between quantity series expansion landing and this table
    /// existing accepted reading pages through the generic path, because they
    /// parse perfectly well as samples — an id, a type, a start date — and so
    /// they sit in `sample` under their parent's type, inflating every count
    /// of it. They are moved rather than deleted: the whole record is in
    /// `raw`, so nothing has to be asked for again, and the phone would not
    /// re-send them anyway now its cursor has passed them.
    private static func rehomeMisfiledSeriesPages(
        _ database: SQLiteDatabase
    ) throws {
        let misfiled = try database.query(
            """
            SELECT id, type, raw FROM sample
            WHERE kind IN (?, ?)
            """,
            [
                .text(QuantitySeriesShape.elementKind),
                .text(QuantitySeriesShape.endKind)
            ],
            row: { ($0.text(0), $0.text(1), $0.blob(2) ?? Data()) }
        )
        guard !misfiled.isEmpty else {
            return
        }

        for (id, type, raw) in misfiled {
            guard
                let object = try? JSONSerialization.jsonObject(with: raw)
                    as? [String: Any]
            else {
                continue
            }
            if let page = QuantitySeriesShape.page(in: object) {
                try insert(page, into: database)
            } else if let end = QuantitySeriesShape.end(in: object) {
                try insert(end, into: database)
            } else {
                // Readable as neither shape. It stays exactly where it is
                // rather than being dropped for being inconvenient — a row
                // nobody can interpret is still a row somebody sent.
                continue
            }
            // Removed only once its contents are somewhere else, and matched
            // on the whole primary key so a row that merely shares an
            // identifier is untouched.
            try database.run(
                "DELETE FROM sample WHERE id = ? AND type = ?",
                [.text(id), .text(type)]
            )
        }
    }

    static func insert(
        _ page: ReceivedQuantitySeriesPage,
        into database: SQLiteDatabase
    ) throws {
        try database.run(
            """
            INSERT INTO quantity_series_page
                (sample_id, type, sequence, offset, reading_count, unit,
                 start_date, end_date, readings)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (sample_id, sequence) DO UPDATE SET
                type = excluded.type,
                offset = excluded.offset,
                reading_count = excluded.reading_count,
                unit = excluded.unit,
                start_date = excluded.start_date,
                end_date = excluded.end_date,
                readings = excluded.readings
            """,
            [
                .text(page.sampleID),
                .text(page.type),
                .integer(Int64(page.sequence)),
                .integer(Int64(page.offset)),
                .integer(Int64(page.count)),
                page.unit.map { SQLiteValue.text($0) } ?? .null,
                .text(Timestamps.text(from: page.startDate)),
                page.endDate.map { SQLiteValue.text(Timestamps.text(from: $0)) }
                    ?? .null,
                .blob(page.readings)
            ]
        )
    }

    static func insert(
        _ end: ReceivedQuantitySeriesEnd,
        into database: SQLiteDatabase
    ) throws {
        try database.run(
            """
            INSERT INTO quantity_series
                (sample_id, type, exported_readings, start_date, end_date)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (sample_id) DO UPDATE SET
                type = excluded.type,
                exported_readings = excluded.exported_readings,
                start_date = excluded.start_date,
                end_date = excluded.end_date
            """,
            [
                .text(end.sampleID),
                .text(end.type),
                .integer(Int64(end.exportedReadings)),
                .text(Timestamps.text(from: end.startDate)),
                end.endDate.map { SQLiteValue.text(Timestamps.text(from: $0)) }
                    ?? .null
            ]
        )
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
        // Checked after the duplicate test, so a batch already on disk is
        // still answered as stored when the disk is full — it *is* stored, and
        // refusing it would make the phone keep resending something this Mac
        // already holds.
        try checkThereIsRoom()

        var stored = 0
        var deleted = 0
        var storedCharacteristics = 0
        var storedUnhandled = 0
        let timestamp = Timestamps.text(from: now)

        // One transaction, so a batch is either wholly stored or wholly absent.
        // A half-applied batch would be indistinguishable from a complete one
        // on the next delivery, and the missing half would never be resent.
        try database.transaction {
            (stored, deleted, storedCharacteristics, storedUnhandled) =
                try Self.write(batch, at: timestamp, into: database)

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

    /// Writes a batch's contents. The caller owns the transaction, because both
    /// callers need other work committed alongside these rows: `ingest` records
    /// the idempotency key, and promotion deletes the quarantined copy.
    @discardableResult
    private static func write(
        _ batch: ParsedBatch,
        at timestamp: String,
        into database: SQLiteDatabase
    ) throws -> (Int, Int, Int, Int) {
        var stored = 0
        var deleted = 0
        var storedCharacteristics = 0
        var storedUnhandled = 0
        var storedElectrocardiograms = 0
        var storedVoltagePages = 0
        var storedQuantitySeriesPages = 0
        var storedAudiograms = 0

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
                    (fingerprint, kind, reason, raw, received_at, parser_version)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (fingerprint) DO UPDATE SET
                    kind = excluded.kind,
                    reason = excluded.reason,
                    raw = excluded.raw,
                    parser_version = excluded.parser_version
                """,
                [
                    .text(record.fingerprint),
                    record.kind.map { SQLiteValue.text($0) } ?? .null,
                    .text(record.reason),
                    .blob(record.raw),
                    .text(timestamp),
                    .integer(Int64(BatchParser.parserVersion))
                ]
            )
            storedUnhandled += 1
        }

        for ecg in batch.electrocardiograms {
            try database.run(
                """
                INSERT INTO electrocardiogram
                    (id, start_date, end_date, classification, classification_raw,
                     symptoms_status, average_heart_rate, sampling_hz,
                     expected_voltages, source_name, raw, received_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET
                    start_date = excluded.start_date,
                    end_date = excluded.end_date,
                    classification = excluded.classification,
                    classification_raw = excluded.classification_raw,
                    symptoms_status = excluded.symptoms_status,
                    average_heart_rate = excluded.average_heart_rate,
                    sampling_hz = excluded.sampling_hz,
                    expected_voltages = excluded.expected_voltages,
                    source_name = excluded.source_name,
                    raw = excluded.raw
                """,
                [
                    .text(ecg.id),
                    .text(Timestamps.text(from: ecg.startDate)),
                    ecg.endDate.map { SQLiteValue.text(Timestamps.text(from: $0)) } ?? .null,
                    ecg.classification.map { SQLiteValue.text($0) } ?? .null,
                    ecg.classificationRawValue.map { SQLiteValue.integer(Int64($0)) } ?? .null,
                    ecg.symptomsStatus.map { SQLiteValue.text($0) } ?? .null,
                    ecg.averageHeartRate.map { SQLiteValue.real($0) } ?? .null,
                    ecg.samplingHertz.map { SQLiteValue.real($0) } ?? .null,
                    ecg.expectedVoltages.map { SQLiteValue.integer(Int64($0)) } ?? .null,
                    ecg.sourceName.map { SQLiteValue.text($0) } ?? .null,
                    .blob(ecg.raw),
                    .text(timestamp)
                ]
            )
            storedElectrocardiograms += 1
        }

        // Keyed by sequence, so a page replayed byte-for-byte overwrites
        // itself rather than appearing twice in the waveform.
        for page in batch.voltagePages {
            try database.run(
                """
                INSERT INTO electrocardiogram_voltage_page
                    (sample_id, sequence, offset, point_count, points)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (sample_id, sequence) DO UPDATE SET
                    offset = excluded.offset,
                    point_count = excluded.point_count,
                    points = excluded.points
                """,
                [
                    .text(page.sampleID),
                    .integer(Int64(page.sequence)),
                    .integer(Int64(page.offset)),
                    .integer(Int64(page.count)),
                    .blob(page.points)
                ]
            )
            storedVoltagePages += 1
        }

        // Kept out of `sample` entirely, so a page of five hundred readings
        // never counts as a reading of the type it belongs to.
        for page in batch.quantitySeriesPages {
            try Self.insert(page, into: database)
            storedQuantitySeriesPages += 1
        }

        for end in batch.quantitySeriesEnds {
            try Self.insert(end, into: database)
        }

        for audiogram in batch.audiograms {
            try database.run(
                """
                INSERT INTO audiogram
                    (id, start_date, end_date, source_name, raw, received_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET
                    start_date = excluded.start_date,
                    end_date = excluded.end_date,
                    source_name = excluded.source_name,
                    raw = excluded.raw
                """,
                [
                    .text(audiogram.id),
                    .text(Timestamps.text(from: audiogram.startDate)),
                    audiogram.endDate.map { SQLiteValue.text(Timestamps.text(from: $0)) } ?? .null,
                    audiogram.sourceName.map { SQLiteValue.text($0) } ?? .null,
                    .blob(audiogram.raw),
                    .text(timestamp)
                ]
            )
            for point in audiogram.points {
                try database.run(
                    """
                    INSERT INTO audiogram_point
                        (audiogram_id, frequency, ear, sensitivity, unit, masked, clamped)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (audiogram_id, frequency, ear) DO UPDATE SET
                        sensitivity = excluded.sensitivity,
                        unit = excluded.unit,
                        masked = excluded.masked,
                        clamped = excluded.clamped
                    """,
                    [
                        .text(audiogram.id),
                        .real(point.frequency),
                        .text(point.ear),
                        point.sensitivity.map { SQLiteValue.real($0) } ?? .null,
                        point.unit.map { SQLiteValue.text($0) } ?? .null,
                        point.masked.map { SQLiteValue.integer($0 ? 1 : 0) } ?? .null,
                        .integer(point.clamped ? 1 : 0)
                    ]
                )
            }
            storedAudiograms += 1
        }


        for workout in batch.workoutDetails {
            try database.run(
                """
                INSERT INTO workout_detail
                    (id, start_date, end_date, activity_type, duration_seconds,
                     source_name, received_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET
                    start_date = excluded.start_date,
                    end_date = excluded.end_date,
                    activity_type = excluded.activity_type,
                    duration_seconds = excluded.duration_seconds,
                    source_name = excluded.source_name
                """,
                [
                    .text(workout.id),
                    .text(Timestamps.text(from: workout.startDate)),
                    workout.endDate.map { SQLiteValue.text(Timestamps.text(from: $0)) } ?? .null,
                    workout.activityType.map { SQLiteValue.integer(Int64($0)) } ?? .null,
                    workout.duration.map { SQLiteValue.real($0) } ?? .null,
                    workout.sourceName.map { SQLiteValue.text($0) } ?? .null,
                    .text(timestamp)
                ]
            )
            try writeStatistics(
                workout.statistics,
                workoutID: workout.id,
                activityID: "",
                into: database
            )

            for (ordinal, activity) in workout.activities.enumerated() {
                try database.run(
                    """
                    INSERT INTO workout_activity
                        (id, workout_id, ordinal, activity_type, start_date, end_date)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET
                        workout_id = excluded.workout_id,
                        ordinal = excluded.ordinal,
                        activity_type = excluded.activity_type,
                        start_date = excluded.start_date,
                        end_date = excluded.end_date
                    """,
                    [
                        .text(activity.id),
                        .text(workout.id),
                        .integer(Int64(ordinal)),
                        .integer(Int64(activity.activityType)),
                        .text(Timestamps.text(from: activity.startDate)),
                        activity.endDate.map { SQLiteValue.text(Timestamps.text(from: $0)) } ?? .null
                    ]
                )
                try writeStatistics(
                    activity.statistics,
                    workoutID: workout.id,
                    activityID: activity.id,
                    into: database
                )
            }
        }

        for mood in batch.moodEntries {
            try database.run(
                """
                INSERT INTO state_of_mind
                    (id, start_date, end_date, valence, classification,
                     kind_of_entry, labels, associations, source_name, raw, received_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET
                    start_date = excluded.start_date,
                    end_date = excluded.end_date,
                    valence = excluded.valence,
                    classification = excluded.classification,
                    kind_of_entry = excluded.kind_of_entry,
                    labels = excluded.labels,
                    associations = excluded.associations,
                    source_name = excluded.source_name,
                    raw = excluded.raw
                """,
                [
                    .text(mood.id),
                    .text(Timestamps.text(from: mood.startDate)),
                    mood.endDate.map { SQLiteValue.text(Timestamps.text(from: $0)) } ?? .null,
                    .real(mood.valence),
                    mood.classification.map { SQLiteValue.text($0) } ?? .null,
                    mood.kindOfEntry.map { SQLiteValue.text($0) } ?? .null,
                    .text(mood.labels.joined(separator: ", ")),
                    .text(mood.associations.joined(separator: ", ")),
                    mood.sourceName.map { SQLiteValue.text($0) } ?? .null,
                    .blob(mood.raw),
                    .text(timestamp)
                ]
            )
        }

        for dose in batch.medicationDoses {
            try database.run(
                """
                INSERT INTO medication_dose
                    (id, start_date, log_status, schedule_type, dose_quantity,
                     scheduled_dose_quantity, unit, medication_name,
                     medication_form, source_name, raw, received_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET
                    start_date = excluded.start_date,
                    log_status = excluded.log_status,
                    schedule_type = excluded.schedule_type,
                    dose_quantity = excluded.dose_quantity,
                    scheduled_dose_quantity = excluded.scheduled_dose_quantity,
                    unit = excluded.unit,
                    medication_name = excluded.medication_name,
                    medication_form = excluded.medication_form,
                    source_name = excluded.source_name,
                    raw = excluded.raw
                """,
                [
                    .text(dose.id),
                    .text(Timestamps.text(from: dose.startDate)),
                    .text(dose.logStatus),
                    dose.scheduleType.map { SQLiteValue.text($0) } ?? .null,
                    dose.doseQuantity.map { SQLiteValue.real($0) } ?? .null,
                    dose.scheduledDoseQuantity.map { SQLiteValue.real($0) } ?? .null,
                    dose.unit.map { SQLiteValue.text($0) } ?? .null,
                    dose.medicationName.map { SQLiteValue.text($0) } ?? .null,
                    dose.medicationForm.map { SQLiteValue.text($0) } ?? .null,
                    dose.sourceName.map { SQLiteValue.text($0) } ?? .null,
                    .blob(dose.raw),
                    .text(timestamp)
                ]
            )
        }
        _ = (
            storedElectrocardiograms,
            storedVoltagePages,
            storedQuantitySeriesPages,
            storedAudiograms
        )

        return (stored, deleted, storedCharacteristics, storedUnhandled)
    }


    private static func writeStatistics(
        _ statistics: [ReceivedWorkoutDetail.Statistic],
        workoutID: String,
        activityID: String,
        into database: SQLiteDatabase
    ) throws {
        for statistic in statistics {
            try database.run(
                """
                INSERT INTO workout_statistic
                    (workout_id, activity_id, type, unit, sum, average, minimum, maximum)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (workout_id, activity_id, type) DO UPDATE SET
                    unit = excluded.unit,
                    sum = excluded.sum,
                    average = excluded.average,
                    minimum = excluded.minimum,
                    maximum = excluded.maximum
                """,
                [
                    .text(workoutID),
                    .text(activityID),
                    .text(statistic.type),
                    .text(statistic.unit),
                    statistic.sum.map { SQLiteValue.real($0) } ?? .null,
                    statistic.average.map { SQLiteValue.real($0) } ?? .null,
                    statistic.minimum.map { SQLiteValue.real($0) } ?? .null,
                    statistic.maximum.map { SQLiteValue.real($0) } ?? .null
                ]
            )
        }
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

    /// Every reading held for one expanded sample, in the order they were
    /// measured.
    ///
    /// Ordered by the offset each page carries rather than by when it arrived,
    /// because pages are delivered independently and a series reassembled in
    /// arrival order would be a scrambled hour.
    public func quantitySeriesReadings(
        forSample sampleID: String
    ) throws -> [QuantitySeriesReading] {
        let pages = try database.query(
            """
            SELECT offset, unit, readings FROM quantity_series_page
            WHERE sample_id = ?
            ORDER BY offset
            """,
            [.text(sampleID)],
            row: { ($0.integer(0), $0.optionalText(1), $0.blob(2) ?? Data()) }
        )

        var readings: [QuantitySeriesReading] = []
        for (offset, unit, blob) in pages {
            guard
                let array = try? JSONSerialization.jsonObject(with: blob)
                    as? [[String: Any]]
            else {
                continue
            }
            for (index, object) in array.enumerated() {
                guard let value = BatchParser.numeric(object["value"]) else {
                    continue
                }
                readings.append(
                    QuantitySeriesReading(
                        offset: Int(offset) + index,
                        value: value,
                        unit: unit,
                        startDate: (object["startDate"] as? String)
                            .flatMap(Timestamps.date(from:)),
                        endDate: (object["endDate"] as? String)
                            .flatMap(Timestamps.date(from:))
                    )
                )
            }
        }
        return readings
    }

    /// What is known about one expanded sample: how many readings the phone
    /// said it wrote, and how many are actually here.
    ///
    /// The two differing is the whole point. Without the phone's number, a
    /// series with a page lost in transit is indistinguishable from one the
    /// phone exported short, and the receiver would report a partial hour as
    /// though it were the whole of it.
    public func quantitySeriesState(
        forSample sampleID: String
    ) throws -> QuantitySeriesState? {
        let held = Int(
            try database.query(
                """
                SELECT COALESCE(SUM(reading_count), 0)
                FROM quantity_series_page WHERE sample_id = ?
                """,
                [.text(sampleID)],
                row: { $0.integer(0) }
            ).first ?? 0
        )
        let declared = try database.query(
            """
            SELECT type, exported_readings FROM quantity_series
            WHERE sample_id = ?
            """,
            [.text(sampleID)],
            row: { ($0.text(0), Int($0.integer(1))) }
        ).first

        guard let declared else {
            guard held > 0 else {
                return nil
            }
            // Pages but no end marker: the series has not finished arriving,
            // which is a different thing from being complete.
            return QuantitySeriesState(
                sampleID: sampleID,
                type: nil,
                exportedReadings: nil,
                readingsHeld: held
            )
        }
        return QuantitySeriesState(
            sampleID: sampleID,
            type: declared.0,
            exportedReadings: declared.1,
            readingsHeld: held
        )
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

    /// Re-reads quarantined records with the current parser and moves anything
    /// now understood into its proper place.
    ///
    /// This is what makes quarantine temporary rather than terminal. A record
    /// the receiver could not read is kept because the phone will never send it
    /// again — the spool is bounded and there is no redelivery path — so
    /// without this it would be durable as bytes and permanently invisible to
    /// the charts, the exports, and every MCP tool. Keeping the bytes was only
    /// ever worth doing because of this pass.
    ///
    /// The transaction discipline is the same rule the acquisition anchors
    /// follow: the quarantined copy is deleted only inside the transaction that
    /// commits the real row. A crash between the two would otherwise lose the
    /// record for good, which is the exact outcome quarantine exists to
    /// prevent. A row that still does not parse is left untouched apart from
    /// its parser version, so it is not reconsidered until the parser has
    /// actually changed again.
    @discardableResult
    public func promoteUnhandledRecords(now: Date = .now) throws -> PromotionResult {
        try Self.promoteUnhandledRecords(in: database, now: now)
    }

    /// The pass itself, written against the database rather than the actor so
    /// that opening the store can run it before the actor is fully formed.
    @discardableResult
    private static func promoteUnhandledRecords(
        in database: SQLiteDatabase,
        now: Date = .now
    ) throws -> PromotionResult {
        // On a healthy receiver this matches nothing, which is the common case
        // and costs one indexed lookup.
        let pending = try database.query(
            """
            SELECT fingerprint, raw FROM unhandled_record
             WHERE parser_version < ?
             ORDER BY received_at
            """,
            [.integer(Int64(BatchParser.parserVersion))],
            row: { ($0.text(0), $0.blob(1) ?? Data()) }
        )
        guard !pending.isEmpty else {
            return PromotionResult(promoted: 0, stillUnhandled: 0)
        }

        var promoted = 0
        var remaining = 0
        let timestamp = Timestamps.text(from: now)

        for (fingerprint, raw) in pending {
            let batch: ParsedBatch?
            do {
                batch = try BatchParser.parse(raw)
            } catch {
                // A connection test, or something else that is not a batch.
                // Nothing to promote and nothing to lose.
                batch = nil
            }

            guard let batch, understood(batch) else {
                // Still beyond this parser. Recording the version it was last
                // examined by is the only change, so the next launch skips it.
                try database.run(
                    "UPDATE unhandled_record SET parser_version = ? WHERE fingerprint = ?",
                    [.integer(Int64(BatchParser.parserVersion)), .text(fingerprint)]
                )
                remaining += 1
                continue
            }

            try database.transaction {
                try write(batch, at: timestamp, into: database)
                // Only now, and only here: the real row and the removal of the
                // quarantined copy commit together or not at all.
                try database.run(
                    "DELETE FROM unhandled_record WHERE fingerprint = ?",
                    [.text(fingerprint)]
                )
            }
            promoted += 1
        }

        return PromotionResult(promoted: promoted, stillUnhandled: remaining)
    }

    /// Whether re-parsing actually produced something storable.
    ///
    /// A batch that comes back with the record still unhandled has not been
    /// understood, however successfully it parsed as JSON.
    private static func understood(_ batch: ParsedBatch) -> Bool {
        !batch.records.isEmpty
            || !batch.deletions.isEmpty
            || !batch.characteristics.isEmpty
    }

    /// Places a record in quarantine directly, for tests that need to stand in
    /// for a parser older than the one running.
    ///
    /// The promotion path is only meaningful across a version boundary, and a
    /// test cannot travel back to a build that did not understand a shape. This
    /// creates the state that build would have left behind.
    func quarantineForTesting(
        raw: Data,
        kind: String?,
        parserVersion: Int,
        now: Date = .now
    ) throws {
        try database.run(
            """
            INSERT INTO unhandled_record
                (fingerprint, kind, reason, raw, received_at, parser_version)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (fingerprint) DO UPDATE SET
                parser_version = excluded.parser_version
            """,
            [
                .text(BatchParser.fingerprint(of: raw)),
                kind.map { SQLiteValue.text($0) } ?? .null,
                .text("Quarantined by an earlier parser."),
                .blob(raw),
                .text(Timestamps.text(from: now)),
                .integer(Int64(parserVersion))
            ]
        )
    }

    /// One ECG reading with its waveform's completeness stated plainly.
    public struct StoredElectrocardiogram: Hashable, Sendable, Identifiable {
        public let id: String
        public let startDate: Date
        public let classification: String?
        public let symptomsStatus: String?
        public let averageHeartRate: Double?
        public let samplingHertz: Double?
        public let expectedVoltages: Int?
        public let heldVoltages: Int
        public let sourceName: String?

        public init(
            id: String,
            startDate: Date,
            classification: String?,
            symptomsStatus: String?,
            averageHeartRate: Double?,
            samplingHertz: Double?,
            expectedVoltages: Int?,
            heldVoltages: Int,
            sourceName: String?
        ) {
            self.id = id
            self.startDate = startDate
            self.classification = classification
            self.symptomsStatus = symptomsStatus
            self.averageHeartRate = averageHeartRate
            self.samplingHertz = samplingHertz
            self.expectedVoltages = expectedVoltages
            self.heldVoltages = heldVoltages
            self.sourceName = sourceName
        }

        /// Whether every measurement the Watch recorded is actually here.
        ///
        /// A waveform assembled from pages that are still arriving is a
        /// different thing from a complete recording, and showing one as the
        /// other would be a clinical-looking lie. When the Watch did not say
        /// how many to expect, this stays `false` rather than assuming.
        public var isComplete: Bool {
            guard let expectedVoltages, expectedVoltages > 0 else {
                return false
            }
            return heldVoltages >= expectedVoltages
        }
    }

    /// Every ECG reading, newest first.
    public func electrocardiograms(limit: Int = 200) throws -> [StoredElectrocardiogram] {
        try database.query(
            """
            SELECT e.id, e.start_date, e.classification, e.symptoms_status,
                   e.average_heart_rate, e.sampling_hz, e.expected_voltages,
                   COALESCE(SUM(p.point_count), 0), e.source_name
              FROM electrocardiogram e
              LEFT JOIN electrocardiogram_voltage_page p ON p.sample_id = e.id
             GROUP BY e.id
             ORDER BY e.start_date DESC
             LIMIT ?
            """,
            [.integer(Int64(limit))],
            row: { row in
                StoredElectrocardiogram(
                    id: row.text(0),
                    startDate: Timestamps.date(from: row.text(1)) ?? .distantPast,
                    classification: row.optionalText(2),
                    symptomsStatus: row.optionalText(3),
                    averageHeartRate: row.optionalReal(4),
                    samplingHertz: row.optionalReal(5),
                    expectedVoltages: row.optionalInteger(6).map { Int($0) },
                    heldVoltages: Int(row.integer(7)),
                    sourceName: row.optionalText(8)
                )
            }
        )
    }

    /// A reading's waveform, reassembled from its pages.
    ///
    /// Pages may arrive out of order, more than once, or not at all, so they
    /// are ordered by their absolute offset and gaps are reported rather than
    /// closed up. A caller is told what is missing instead of being handed a
    /// shorter waveform that looks whole.
    public struct VoltagePoint: Hashable, Sendable {
        public let secondsSinceStart: Double
        public let volts: Double

        public init(secondsSinceStart: Double, volts: Double) {
            self.secondsSinceStart = secondsSinceStart
            self.volts = volts
        }
    }

    public struct Waveform: Hashable, Sendable {
        public let points: [VoltagePoint]
        /// Whether every measurement the Watch recorded is present and in one
        /// unbroken run. A caller must not present an incomplete waveform as a
        /// whole recording.
        public let isComplete: Bool
        public let expected: Int?

        public init(points: [VoltagePoint], isComplete: Bool, expected: Int?) {
            self.points = points
            self.isComplete = isComplete
            self.expected = expected
        }
    }

    public func voltages(forElectrocardiogram id: String) throws -> Waveform {
        let pages = try database.query(
            """
            SELECT offset, point_count, points
              FROM electrocardiogram_voltage_page
             WHERE sample_id = ?
             ORDER BY offset
            """,
            [.text(id)],
            row: { ($0.integer(0), $0.integer(1), $0.blob(2) ?? Data()) }
        )

        let expected = try database.query(
            "SELECT expected_voltages FROM electrocardiogram WHERE id = ?",
            [.text(id)],
            row: { $0.optionalInteger(0).map { Int($0) } }
        ).first ?? nil

        var points: [VoltagePoint] = []
        var nextOffset = 0
        var contiguous = true
        for (offset, _, data) in pages {
            if Int(offset) != nextOffset {
                // A page is missing between the last one and this. The points
                // that did arrive are still returned; the gap is what makes
                // this waveform incomplete.
                contiguous = false
            }
            let decoded = (try? JSONSerialization.jsonObject(with: data))
                as? [[String: Any]] ?? []
            for entry in decoded {
                guard
                    let time = entry["timeSinceStart"] as? Double,
                    let volts = entry["volts"] as? Double
                else {
                    continue
                }
                points.append(VoltagePoint(secondsSinceStart: time, volts: volts))
            }
            nextOffset = Int(offset) + decoded.count
        }

        return Waveform(
            points: points,
            isComplete: contiguous && expected.map { points.count >= $0 } == true,
            expected: expected
        )
    }

    /// One hearing test's thresholds.
    public struct StoredAudiogramPoint: Hashable, Sendable {
        public let frequency: Double
        public let ear: String
        public let sensitivity: Double?
        public let unit: String?
        public let clamped: Bool

        public init(
            frequency: Double,
            ear: String,
            sensitivity: Double?,
            unit: String?,
            clamped: Bool
        ) {
            self.frequency = frequency
            self.ear = ear
            self.sensitivity = sensitivity
            self.unit = unit
            self.clamped = clamped
        }
    }

    public struct StoredAudiogram: Hashable, Sendable, Identifiable {
        public let id: String
        public let startDate: Date
        public let sourceName: String?
        public let points: [StoredAudiogramPoint]

        public init(
            id: String,
            startDate: Date,
            sourceName: String?,
            points: [StoredAudiogramPoint]
        ) {
            self.id = id
            self.startDate = startDate
            self.sourceName = sourceName
            self.points = points
        }
    }

    public func audiograms(limit: Int = 100) throws -> [StoredAudiogram] {
        let tests = try database.query(
            """
            SELECT id, start_date, source_name FROM audiogram
             ORDER BY start_date DESC LIMIT ?
            """,
            [.integer(Int64(limit))],
            row: { ($0.text(0), $0.text(1), $0.optionalText(2)) }
        )

        return try tests.map { id, start, source in
            let points = try database.query(
                """
                SELECT frequency, ear, sensitivity, unit, clamped
                  FROM audiogram_point
                 WHERE audiogram_id = ?
                 ORDER BY frequency, ear
                """,
                [.text(id)],
                row: { row in
                    StoredAudiogramPoint(
                        frequency: row.real(0),
                        ear: row.text(1),
                        sensitivity: row.optionalReal(2),
                        unit: row.optionalText(3),
                        clamped: row.integer(4) == 1
                    )
                }
            )
            return StoredAudiogram(
                id: id,
                startDate: Timestamps.date(from: start) ?? .distantPast,
                sourceName: source,
                points: points
            )
        }
    }


    public struct StoredMoodEntry: Hashable, Sendable {
        public let startDate: Date
        public let valence: Double
        public let classification: String?
        public let kindOfEntry: String?
        public let labels: String
        public let associations: String
    }

    public func moodEntries(
        from start: Date? = nil,
        limit: Int = 500
    ) throws -> [StoredMoodEntry] {
        var sql = """
            SELECT start_date, valence, classification, kind_of_entry,
                   labels, associations
              FROM state_of_mind
            """
        var parameters: [SQLiteValue] = []
        if let start {
            sql += " WHERE start_date >= ?"
            parameters.append(.text(Timestamps.text(from: start)))
        }
        sql += " ORDER BY start_date DESC LIMIT ?"
        parameters.append(.integer(Int64(limit)))

        return try database.query(sql, parameters) { row in
            StoredMoodEntry(
                startDate: Timestamps.date(from: row.text(0)) ?? .distantPast,
                valence: row.real(1),
                classification: row.optionalText(2),
                kindOfEntry: row.optionalText(3),
                labels: row.text(4),
                associations: row.text(5)
            )
        }
    }

    public struct MedicationAdherence: Hashable, Sendable {
        public let medication: String
        /// Counts per status, kept apart rather than reduced to a rate,
        /// because skipped, snoozed and never-answered are three different
        /// facts and only one of the four means the medicine was taken.
        public let statusCounts: [String: Int]
        public let earliest: Date?
        public let latest: Date?

        public var total: Int {
            statusCounts.values.reduce(0, +)
        }

        public var taken: Int {
            statusCounts["taken"] ?? 0
        }
    }

    public func medicationAdherence(
        from start: Date? = nil
    ) throws -> [MedicationAdherence] {
        var sql = """
            SELECT COALESCE(medication_name, 'Unnamed medication'), log_status,
                   COUNT(*), MIN(start_date), MAX(start_date)
              FROM medication_dose
            """
        var parameters: [SQLiteValue] = []
        if let start {
            sql += " WHERE start_date >= ?"
            parameters.append(.text(Timestamps.text(from: start)))
        }
        sql += " GROUP BY 1, 2 ORDER BY 1"

        let rows = try database.query(sql, parameters) { row in
            (
                row.text(0),
                row.text(1),
                Int(row.integer(2)),
                Timestamps.date(from: row.text(3)),
                Timestamps.date(from: row.text(4))
            )
        }

        var byMedication: [String: (counts: [String: Int], first: Date?, last: Date?)] = [:]
        for (name, status, count, first, last) in rows {
            var entry = byMedication[name] ?? ([:], nil, nil)
            entry.counts[status, default: 0] += count
            if let first {
                entry.first = min(entry.first ?? first, first)
            }
            if let last {
                entry.last = max(entry.last ?? last, last)
            }
            byMedication[name] = entry
        }

        return byMedication
            .map {
                MedicationAdherence(
                    medication: $0.key,
                    statusCounts: $0.value.counts,
                    earliest: $0.value.first,
                    latest: $0.value.last
                )
            }
            .sorted { $0.medication < $1.medication }
    }


    public struct StoredWorkoutStatistic: Hashable, Sendable {
        public let type: String
        public let unit: String?
        public let sum: Double?
        public let average: Double?
        public let minimum: Double?
        public let maximum: Double?
    }

    public struct StoredWorkoutActivity: Hashable, Sendable {
        public let activityType: Int
        public let startDate: Date
        public let statistics: [StoredWorkoutStatistic]
    }

    public struct StoredWorkout: Hashable, Sendable {
        public let id: String
        public let startDate: Date
        public let activityType: Int?
        public let duration: Double?
        public let sourceName: String?
        public let statistics: [StoredWorkoutStatistic]
        public let activities: [StoredWorkoutActivity]
    }

    private func statistics(
        workoutID: String,
        activityID: String
    ) throws -> [StoredWorkoutStatistic] {
        try database.query(
            """
            SELECT type, unit, sum, average, minimum, maximum
              FROM workout_statistic
             WHERE workout_id = ? AND activity_id = ?
             ORDER BY type
            """,
            [.text(workoutID), .text(activityID)],
            row: { row in
                StoredWorkoutStatistic(
                    type: row.text(0),
                    unit: row.optionalText(1),
                    sum: row.optionalReal(2),
                    average: row.optionalReal(3),
                    minimum: row.optionalReal(4),
                    maximum: row.optionalReal(5)
                )
            }
        )
    }

    /// Workouts with what Health computed about them, newest first.
    public func workouts(
        from start: Date? = nil,
        limit: Int = 100
    ) throws -> [StoredWorkout] {
        var sql = """
            SELECT id, start_date, activity_type, duration_seconds, source_name
              FROM workout_detail
            """
        var parameters: [SQLiteValue] = []
        if let start {
            sql += " WHERE start_date >= ?"
            parameters.append(.text(Timestamps.text(from: start)))
        }
        sql += " ORDER BY start_date DESC LIMIT ?"
        parameters.append(.integer(Int64(limit)))

        let rows = try database.query(sql, parameters) { row in
            (
                row.text(0),
                Timestamps.date(from: row.text(1)) ?? .distantPast,
                row.optionalInteger(2).map { Int($0) },
                row.optionalReal(3),
                row.optionalText(4)
            )
        }

        return try rows.map { id, start, activityType, duration, source in
            let legs = try database.query(
                """
                SELECT id, activity_type, start_date FROM workout_activity
                 WHERE workout_id = ? ORDER BY ordinal
                """,
                [.text(id)],
                row: { ($0.text(0), Int($0.integer(1)), $0.text(2)) }
            )
            return StoredWorkout(
                id: id,
                startDate: start,
                activityType: activityType,
                duration: duration,
                sourceName: source,
                statistics: try statistics(workoutID: id, activityID: ""),
                activities: try legs.map { legID, type, legStart in
                    StoredWorkoutActivity(
                        activityType: type,
                        startDate: Timestamps.date(from: legStart) ?? .distantPast,
                        statistics: try statistics(workoutID: id, activityID: legID)
                    )
                }
            )
        }
    }

    /// Aggregates one type into time buckets.
    ///
    /// Both `sum` and `average` are returned rather than one "value", because
    /// which is correct depends entirely on the type: summing heart rate is
    /// meaningless, and averaging step count understates a day. The caller — or
    /// the person reading it — has to choose, so hiding one of them would
    /// invite a confidently wrong answer.
    ///
    /// Buckets are local time. This used to group on
    /// `strftime('%Y-%m-%dT00:00:00Z', start_date)`, which is a *UTC* day, and
    /// that quietly misfiled every evening sample in a zone behind UTC: on the
    /// maintainer's own archive it moved 27,858 of 147,330 records — nineteen
    /// percent — to the following day. An assistant asked how many steps
    /// somebody did on Tuesday was answering with part of Monday.
    ///
    /// The implementation is deliberately shared with the dashboards' one, in
    /// ``series(type:plan:)``: two local-day implementations in one codebase is
    /// a future bug, and this one has been checked against the real archive.
    public func aggregate(
        type: String,
        bucket: BucketSize,
        from start: Date? = nil,
        to end: Date? = nil,
        timeZone: TimeZone = .current
    ) throws -> [AggregateBucket] {
        try localAggregate(
            type: type,
            bucket: bucket,
            from: start,
            to: end,
            timeZone: timeZone
        )
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
}
