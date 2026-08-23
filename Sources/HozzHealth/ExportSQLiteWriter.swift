import Foundation
import HozzStore

enum ExportSQLiteWriterError: Error, LocalizedError {
    case cannotCreateDatabase

    var errorDescription: String? {
        switch self {
        case .cannotCreateDatabase:
            "Hozz could not create the export database."
        }
    }
}

/// What the load actually did, which is what the file's own metadata reports
/// and what the tests assert against.
struct ExportSQLiteStatistics: Equatable {
    var linesRead = 0
    var sampleRows = 0
    var workoutRows = 0
    var workoutEventRows = 0
    var deletionRows = 0
    var characteristicRows = 0
    var issueRows = 0
    var logRows = 0
    var unreadableLines = 0
    var distinctSources = 0
    var distinctDevices = 0
    /// Records whose `(id, type)` already existed, so one row holds both. The
    /// spool is not supposed to contain any; the count is kept so the file can
    /// say if it did rather than quietly showing fewer rows than records.
    var collapsedDuplicates = 0
    /// The largest number of uncompressed record bytes handed to SQLite between
    /// two commits. This is the memory the load can be holding at once, and it
    /// is what makes "this streams" a measurable claim rather than an
    /// assertion.
    var peakUncommittedBytes = 0
}

/// Builds a queryable SQLite database from the NDJSON spool.
///
/// ## Why a database at all
///
/// The other formats are files you open. This one is a file you *ask
/// questions of*: it lands in Datasette, DuckDB, pandas, Grafana, or plain
/// `sqlite3` with no import step, and the questions people actually have about
/// their own health data — how did my resting heart rate move over three
/// years, do I sleep worse the night after a long run — are joins across types
/// over time.
///
/// ## Why one wide `sample` table
///
/// A table per Health type is the obvious shape and the wrong one. It makes
/// the single most valuable query — compare two types over the same period —
/// require knowing both table names in advance, and it turns "everything that
/// happened last Tuesday" into a union over a hundred tables. One `sample`
/// table with a `type` column and an index on `(type, start_date)` answers the
/// per-type query just as fast, and answers the cross-type one at all.
///
/// Workouts, deletions and characteristics are *not* forced into that table,
/// because they genuinely have different shapes: a workout has a duration, an
/// activity type and nested events; a deletion has no dates or values at all;
/// a characteristic has no time range. Flattening them would fill `sample`
/// with columns that are null for almost every row. They get their own tables,
/// and a `record` view unions the time-shaped ones back together for anyone
/// who wants a single timeline.
///
/// ## Why this is not lossy
///
/// Every row keeps the untouched spool line in `raw`. The typed columns are a
/// projection for querying, not a replacement, so metadata, workout events,
/// device details and any field a future encoder adds are all still there —
/// `json_extract(raw, '$...')` reaches anything the columns do not. That is
/// what lets this format be offered without the lossy label CSV carries.
///
/// ## Why it streams
///
/// A full history can be far larger than memory. Records are read one line at
/// a time and inserted through prepared statements, committed in bounded
/// batches, and indexes are built only after the load — building them during
/// it would rewrite the b-trees on every insert for no benefit.
enum ExportSQLiteWriter {
    /// The shape of the file, written to `PRAGMA user_version` so a tool — or a
    /// later version of Hozz — can tell which layout it is looking at.
    static let schemaVersion: Int32 = 1

    /// `PRAGMA application_id`, which is how `file(1)` and friends recognise an
    /// application's own SQLite format. "HOZZ" in ASCII.
    static let applicationID: Int32 = 0x484F_5A5A

    /// Records inserted between commits. Large enough that the per-transaction
    /// cost disappears, small enough that the page cache stays bounded.
    static let defaultBatchSize = 2_000

    struct Metadata {
        let runID: UUID
        let startedAt: Date
        let timeZone: TimeZone

        init(runID: UUID, startedAt: Date, timeZone: TimeZone = .current) {
            self.runID = runID
            self.startedAt = startedAt
            self.timeZone = timeZone
        }
    }

    @discardableResult
    static func write(
        readingFrom sourceURL: URL,
        to destinationURL: URL,
        metadata: Metadata,
        batchSize: Int = defaultBatchSize,
        now: Date = .now
    ) throws -> ExportSQLiteStatistics {
        // A database left by an interrupted attempt would be opened and added
        // to rather than replaced, so it goes first — along with any side file
        // an earlier build may have left beside it.
        for url in StoreLocation.databaseFileURLs(for: destinationURL) {
            try? FileManager.default.removeItem(at: url)
        }
        // Created here rather than by SQLite so the file carries data
        // protection from the moment it exists, not from the moment the load
        // finishes.
        guard FileManager.default.createFile(
            atPath: destinationURL.path,
            contents: nil,
            attributes: [.protectionKey: StoreLocation.protection]
        ) else {
            throw ExportSQLiteWriterError.cannotCreateDatabase
        }
        try? StoreLocation.harden(destinationURL)

        let database = try SQLiteDatabase(url: destinationURL)
        defer { database.close() }

        do {
            let statistics = try load(
                into: database,
                readingFrom: sourceURL,
                metadata: metadata,
                batchSize: batchSize,
                now: now
            )
            return statistics
        } catch {
            database.close()
            for url in StoreLocation.databaseFileURLs(for: destinationURL) {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    private static func load(
        into database: SQLiteDatabase,
        readingFrom sourceURL: URL,
        metadata: Metadata,
        batchSize: Int,
        now: Date
    ) throws -> ExportSQLiteStatistics {
        // The file is disposable until the export completes: an interrupted
        // assembly is thrown away and rebuilt from the spool, which is still on
        // disk. Nothing here is a durable cursor, so paying for a rollback
        // journal and an fsync per commit would buy a guarantee the format
        // already has from somewhere else.
        try database.execute("PRAGMA journal_mode = OFF;")
        try database.execute("PRAGMA synchronous = OFF;")
        try database.execute("PRAGMA application_id = \(applicationID);")
        try database.execute("PRAGMA user_version = \(schemaVersion);")
        try database.execute(schema)

        var statistics = ExportSQLiteStatistics()
        var reader = try NDJSONLineReader(fileURL: sourceURL)
        defer { reader.close() }

        let sampleStatement = try database.prepared(sampleInsert)
        let workoutStatement = try database.prepared(workoutInsert)
        let eventStatement = try database.prepared(workoutEventInsert)
        let deletionStatement = try database.prepared(deletionInsert)
        let characteristicStatement = try database.prepared(characteristicInsert)
        let issueStatement = try database.prepared(issueInsert)
        let logStatement = try database.prepared(logInsert)

        var day = LocalDayFormatter(timeZone: metadata.timeZone)
        var sources: [SourceKey: Int] = [:]
        var devices: [DeviceKey: Int] = [:]
        var typeStates: [String: TypeState] = [:]
        var earliest: Date?
        var latest: Date?
        var manifest: [String: Any] = [:]
        var completion: [String: Any] = [:]

        var pendingRows = 0
        var pendingBytes = 0
        var isInTransaction = false

        func begin() throws {
            guard !isInTransaction else {
                return
            }
            try database.execute("BEGIN IMMEDIATE;")
            isInTransaction = true
        }
        func commit() throws {
            guard isInTransaction else {
                return
            }
            try database.execute("COMMIT;")
            isInTransaction = false
            statistics.peakUncommittedBytes = max(
                statistics.peakUncommittedBytes,
                pendingBytes
            )
            pendingRows = 0
            pendingBytes = 0
        }

        do {
            try begin()

            while let line = try reader.nextLine() {
                statistics.linesRead += 1
                pendingBytes += line.count

                guard let record = ExportRecord(line: line) else {
                    // A line Hozz cannot parse is still something Health
                    // returned. It is kept verbatim rather than skipped, so the
                    // count in `meta` and the row in `export_issue` agree with
                    // each other.
                    statistics.unreadableLines += 1
                    try issueStatement.run([
                        .null,
                        .null,
                        .text("This spool line could not be read as JSON."),
                        .blob(line)
                    ])
                    pendingRows += 1
                    if pendingRows >= batchSize {
                        try commit()
                        try begin()
                    }
                    continue
                }

                let rawText = String(decoding: record.raw, as: UTF8.self)

                switch record.kind {
                case "workout":
                    let start = record.startDate
                    let end = record.endDate
                    try workoutStatement.run([
                        text(record.id),
                        text(record.type),
                        text(start.map(ExportRecord.timestamp)),
                        text(end.map(ExportRecord.timestamp)),
                        epoch(start),
                        epoch(end),
                        text(start.map { day.day(for: $0) }),
                        record.activityType.map { SQLiteValue.integer($0) } ?? .null,
                        record.duration.map { SQLiteValue.real($0) } ?? .null,
                        text(record.sourceName),
                        text(record.sourceBundleIdentifier),
                        text(record.sourceVersion),
                        text(record.deviceName),
                        text(record.metadataJSON),
                        .text(rawText)
                    ])
                    statistics.workoutRows += 1
                    pendingRows += 1

                    for (ordinal, event) in record.workoutEvents.enumerated() {
                        try eventStatement.run([
                            text(record.id),
                            .integer(Int64(ordinal)),
                            ExportRecord.number(event["type"]).map {
                                SQLiteValue.integer(Int64($0))
                            } ?? .null,
                            text(
                                ExportRecord.date(event["startDate"])
                                    .map(ExportRecord.timestamp)
                            ),
                            text(
                                ExportRecord.date(event["endDate"])
                                    .map(ExportRecord.timestamp)
                            ),
                            text(ExportRecord.compactJSON(event["metadata"]))
                        ])
                        statistics.workoutEventRows += 1
                        pendingRows += 1
                    }
                    note(start: start, end: end, into: &earliest, &latest)
                    count(record, sources: &sources, devices: &devices)

                case "deletion":
                    try deletionStatement.run([
                        text(record.id),
                        text(record.type),
                        .text(rawText)
                    ])
                    statistics.deletionRows += 1
                    pendingRows += 1

                case "characteristic":
                    // Characteristics are not time series — one value that is
                    // true until it is not — so they get a table of their own
                    // rather than a `sample` row with every date column null.
                    try characteristicStatement.run([
                        text(record.type),
                        text(characteristicValue(record)),
                        .text(rawText)
                    ])
                    statistics.characteristicRows += 1
                    pendingRows += 1

                case "sampleEncodingError":
                    try issueStatement.run([
                        text(record.id),
                        text(record.type),
                        text(record.message),
                        .blob(record.raw)
                    ])
                    statistics.issueRows += 1
                    pendingRows += 1

                case let kind where ExportRecord.runKinds.contains(kind):
                    try logStatement.run([
                        .integer(Int64(statistics.logRows)),
                        .text(kind),
                        .text(rawText)
                    ])
                    statistics.logRows += 1
                    pendingRows += 1
                    switch kind {
                    case "manifest":
                        manifest = record.object
                    case "completion":
                        completion = record.object
                    case "typeSummary", "typeError":
                        merge(record, into: &typeStates)
                    default:
                        break
                    }

                default:
                    let start = record.startDate
                    let end = record.endDate
                    try sampleStatement.run([
                        text(record.id),
                        text(record.type),
                        .text(record.kind),
                        text(start.map(ExportRecord.timestamp)),
                        text(end.map(ExportRecord.timestamp)),
                        epoch(start),
                        epoch(end),
                        text(start.map { day.day(for: $0) }),
                        record.value.map { SQLiteValue.real($0) } ?? .null,
                        text(record.unit),
                        text(record.sourceName),
                        text(record.sourceBundleIdentifier),
                        text(record.sourceVersion),
                        text(record.deviceName),
                        text(record.metadataJSON),
                        .text(rawText)
                    ])
                    statistics.sampleRows += 1
                    pendingRows += 1
                    note(start: start, end: end, into: &earliest, &latest)
                    count(record, sources: &sources, devices: &devices)
                }

                if pendingRows >= batchSize {
                    try commit()
                    try begin()
                }
            }

            try commit()
        } catch {
            if isInTransaction {
                try? database.execute("ROLLBACK;")
            }
            throw error
        }

        statistics.distinctSources = sources.count
        statistics.distinctDevices = devices.count

        try database.transaction {
            for (source, count) in sources.sorted(by: { $0.key < $1.key }) {
                try database.run(
                    """
                    INSERT INTO source (name, bundle_id, version, record_count)
                    VALUES (?, ?, ?, ?)
                    """,
                    [
                        text(source.name),
                        text(source.bundleIdentifier),
                        text(source.version),
                        .integer(Int64(count))
                    ]
                )
            }
            for (device, count) in devices.sorted(by: { $0.key < $1.key }) {
                try database.run(
                    """
                    INSERT INTO device (name, manufacturer, model, record_count)
                    VALUES (?, ?, ?, ?)
                    """,
                    [
                        text(device.name),
                        text(device.manufacturer),
                        text(device.model),
                        .integer(Int64(count))
                    ]
                )
            }
            for state in typeStates.values.sorted(by: { $0.type < $1.type }) {
                try database.run(
                    """
                    INSERT INTO export_type
                        (type, state, records, queries, encoding_errors, message)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (type) DO UPDATE SET
                        state = excluded.state,
                        records = excluded.records,
                        queries = excluded.queries,
                        encoding_errors = excluded.encoding_errors,
                        message = excluded.message
                    """,
                    [
                        .text(state.type),
                        text(state.state),
                        state.records.map { SQLiteValue.integer(Int64($0)) } ?? .null,
                        state.queries.map { SQLiteValue.integer(Int64($0)) } ?? .null,
                        state.encodingErrors.map { SQLiteValue.integer(Int64($0)) }
                            ?? .null,
                        text(state.message)
                    ]
                )
            }
        }

        // A duplicated `(id, type)` collapses onto one row, which would
        // otherwise show up only as an unexplained shortfall.
        let storedSamples = try count(in: database, table: "sample")
        let storedWorkouts = try count(in: database, table: "workout")
        let storedDeletions = try count(in: database, table: "deletion")
        statistics.collapsedDuplicates =
            (statistics.sampleRows - storedSamples)
            + (statistics.workoutRows - storedWorkouts)
            + (statistics.deletionRows - storedDeletions)

        try writeMetadata(
            into: database,
            metadata: metadata,
            statistics: statistics,
            manifest: manifest,
            completion: completion,
            earliest: earliest,
            latest: latest,
            now: now
        )

        // Built last: maintaining four indexes across every insert costs far
        // more than one sort at the end.
        try database.execute(indexes)
        // Lets the query planner pick between those indexes rather than
        // guessing, which matters for exactly the cross-type queries this
        // format exists to make possible.
        try? database.execute("ANALYZE;")

        return statistics
    }

    // MARK: - Schema

    private static let schema = """
        -- Self-describing metadata: when the export ran, what it covered, and
        -- which time zone the local_day columns were bucketed in.
        CREATE TABLE meta (
            key TEXT PRIMARY KEY,
            value TEXT
        );

        -- Every time-shaped Health record except workouts. One table with a
        -- type column, so questions that span types are one query.
        CREATE TABLE sample (
            id TEXT NOT NULL,
            type TEXT NOT NULL,
            kind TEXT NOT NULL,
            start_date TEXT,
            end_date TEXT,
            start_epoch REAL,
            end_epoch REAL,
            -- The calendar day this fell on where the phone was, not in UTC.
            local_day TEXT,
            -- Category values are enumerations rather than measurements, so
            -- they land here with no unit. `kind` says which is which.
            value REAL,
            unit TEXT,
            source_name TEXT,
            source_bundle_id TEXT,
            source_version TEXT,
            device_name TEXT,
            metadata TEXT,
            -- The untouched export line. Everything the columns above leave
            -- out is still here, reachable with json_extract().
            raw TEXT NOT NULL,
            PRIMARY KEY (id, type)
        );

        CREATE TABLE workout (
            id TEXT PRIMARY KEY,
            type TEXT,
            start_date TEXT,
            end_date TEXT,
            start_epoch REAL,
            end_epoch REAL,
            local_day TEXT,
            activity_type INTEGER,
            duration_seconds REAL,
            source_name TEXT,
            source_bundle_id TEXT,
            source_version TEXT,
            device_name TEXT,
            metadata TEXT,
            raw TEXT NOT NULL
        );

        CREATE TABLE workout_event (
            workout_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            type INTEGER,
            start_date TEXT,
            end_date TEXT,
            metadata TEXT,
            PRIMARY KEY (workout_id, ordinal)
        );

        -- Records Health reported as deleted. Kept because an archive that
        -- drops them cannot tell a sample that never existed from one that was
        -- removed on purpose.
        CREATE TABLE deletion (
            id TEXT NOT NULL,
            type TEXT NOT NULL,
            raw TEXT NOT NULL,
            PRIMARY KEY (id, type)
        );

        CREATE TABLE characteristic (
            type TEXT PRIMARY KEY,
            value TEXT,
            raw TEXT NOT NULL
        );

        -- Per-type outcome, including the types that returned nothing. Apple
        -- does not let an app tell "denied" from "empty", so a state of
        -- authorizationIndeterminate means exactly that and is not a failure.
        CREATE TABLE export_type (
            type TEXT PRIMARY KEY,
            state TEXT,
            records INTEGER,
            queries INTEGER,
            encoding_errors INTEGER,
            message TEXT
        );

        -- Objects Health returned that Hozz could not encode, plus any spool
        -- line that could not be read. Present so the file never quietly holds
        -- less than the export saw.
        CREATE TABLE export_issue (
            id TEXT,
            type TEXT,
            message TEXT,
            raw BLOB
        );

        -- The run's own records, verbatim and in order.
        CREATE TABLE export_log (
            ordinal INTEGER PRIMARY KEY,
            kind TEXT NOT NULL,
            raw TEXT NOT NULL
        );

        CREATE TABLE source (
            name TEXT,
            bundle_id TEXT,
            version TEXT,
            record_count INTEGER
        );

        CREATE TABLE device (
            name TEXT,
            manufacturer TEXT,
            model TEXT,
            record_count INTEGER
        );

        -- One timeline over everything that has a time, so "what happened on
        -- this day" does not have to know which table to look in.
        CREATE VIEW record AS
            SELECT id, type, kind, start_date, end_date, start_epoch,
                   end_epoch, local_day, value, unit, source_name, device_name
              FROM sample
             UNION ALL
            SELECT id, type, 'workout', start_date, end_date, start_epoch,
                   end_epoch, local_day, duration_seconds, 'sec', source_name,
                   device_name
              FROM workout;

        -- The aggregate almost every question starts from.
        CREATE VIEW daily AS
            SELECT local_day,
                   type,
                   unit,
                   count(*) AS records,
                   sum(value) AS total,
                   avg(value) AS average,
                   min(value) AS minimum,
                   max(value) AS maximum
              FROM sample
             WHERE value IS NOT NULL
               AND local_day IS NOT NULL
             GROUP BY local_day, type, unit;
        """

    private static let indexes = """
        -- One type over a period: the most common query there is.
        CREATE INDEX sample_type_start ON sample (type, start_date);
        -- Everything in a window, across types.
        CREATE INDEX sample_start ON sample (start_date);
        -- Day-grouped aggregates, including the `daily` view.
        CREATE INDEX sample_day_type ON sample (local_day, type);
        -- "Only what my watch recorded".
        CREATE INDEX sample_source ON sample (source_name);
        CREATE INDEX workout_start ON workout (start_date);
        CREATE INDEX workout_day ON workout (local_day);
        CREATE INDEX workout_activity ON workout (activity_type, start_date);
        CREATE INDEX deletion_type ON deletion (type);
        """

    private static let sampleInsert = """
        INSERT INTO sample
            (id, type, kind, start_date, end_date, start_epoch, end_epoch,
             local_day, value, unit, source_name, source_bundle_id,
             source_version, device_name, metadata, raw)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (id, type) DO UPDATE SET
            kind = excluded.kind,
            start_date = excluded.start_date,
            end_date = excluded.end_date,
            start_epoch = excluded.start_epoch,
            end_epoch = excluded.end_epoch,
            local_day = excluded.local_day,
            value = excluded.value,
            unit = excluded.unit,
            source_name = excluded.source_name,
            source_bundle_id = excluded.source_bundle_id,
            source_version = excluded.source_version,
            device_name = excluded.device_name,
            metadata = excluded.metadata,
            raw = excluded.raw
        """

    private static let workoutInsert = """
        INSERT INTO workout
            (id, type, start_date, end_date, start_epoch, end_epoch, local_day,
             activity_type, duration_seconds, source_name, source_bundle_id,
             source_version, device_name, metadata, raw)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (id) DO UPDATE SET
            type = excluded.type,
            start_date = excluded.start_date,
            end_date = excluded.end_date,
            start_epoch = excluded.start_epoch,
            end_epoch = excluded.end_epoch,
            local_day = excluded.local_day,
            activity_type = excluded.activity_type,
            duration_seconds = excluded.duration_seconds,
            source_name = excluded.source_name,
            source_bundle_id = excluded.source_bundle_id,
            source_version = excluded.source_version,
            device_name = excluded.device_name,
            metadata = excluded.metadata,
            raw = excluded.raw
        """

    private static let workoutEventInsert = """
        INSERT INTO workout_event
            (workout_id, ordinal, type, start_date, end_date, metadata)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (workout_id, ordinal) DO UPDATE SET
            type = excluded.type,
            start_date = excluded.start_date,
            end_date = excluded.end_date,
            metadata = excluded.metadata
        """

    private static let deletionInsert = """
        INSERT INTO deletion (id, type, raw) VALUES (?, ?, ?)
        ON CONFLICT (id, type) DO UPDATE SET raw = excluded.raw
        """

    private static let characteristicInsert = """
        INSERT INTO characteristic (type, value, raw) VALUES (?, ?, ?)
        ON CONFLICT (type) DO UPDATE SET
            value = excluded.value,
            raw = excluded.raw
        """

    private static let issueInsert = """
        INSERT INTO export_issue (id, type, message, raw) VALUES (?, ?, ?, ?)
        """

    private static let logInsert = """
        INSERT INTO export_log (ordinal, kind, raw) VALUES (?, ?, ?)
        """

    // MARK: - Metadata

    private static func writeMetadata(
        into database: SQLiteDatabase,
        metadata: Metadata,
        statistics: ExportSQLiteStatistics,
        manifest: [String: Any],
        completion: [String: Any],
        earliest: Date?,
        latest: Date?,
        now: Date
    ) throws {
        var entries: [(String, String)] = [
            ("generator", "Hozz"),
            ("schema_version", String(schemaVersion)),
            ("export_run", metadata.runID.uuidString.lowercased()),
            ("started_at", ExportRecord.timestamp(metadata.startedAt)),
            ("assembled_at", ExportRecord.timestamp(now)),
            ("time_zone", metadata.timeZone.identifier),
            ("records_in_export", String(statistics.linesRead)),
            ("sample_rows", String(statistics.sampleRows)),
            ("workout_rows", String(statistics.workoutRows)),
            ("workout_event_rows", String(statistics.workoutEventRows)),
            ("deletion_rows", String(statistics.deletionRows)),
            ("characteristic_rows", String(statistics.characteristicRows)),
            ("issue_rows", String(statistics.issueRows)),
            ("unreadable_lines", String(statistics.unreadableLines)),
            ("collapsed_duplicates", String(statistics.collapsedDuplicates)),
            ("distinct_sources", String(statistics.distinctSources)),
            ("distinct_devices", String(statistics.distinctDevices))
        ]

        if let earliest {
            entries.append(("earliest_record", ExportRecord.timestamp(earliest)))
        }
        if let latest {
            entries.append(("latest_record", ExportRecord.timestamp(latest)))
        }

        // Copied out of the run's own records so the file explains its scope
        // without anyone having to read export_log.
        for (key, name) in [
            ("catalogVersion", "catalog_version"),
            ("coverage", "coverage"),
            ("attemptedTypes", "attempted_types"),
            ("catalogTypes", "catalog_types"),
            ("createdAt", "created_at")
        ] {
            if let value = manifest[key] {
                entries.append((name, String(describing: value)))
            }
        }
        for (key, name) in [
            ("completedAt", "completed_at"),
            ("records", "records_reported"),
            ("nonEmptyTypes", "non_empty_types"),
            ("zeroResultTypes", "zero_result_types"),
            ("failedTypes", "failed_types"),
            ("sampleEncodingErrors", "sample_encoding_errors")
        ] {
            if let value = completion[key] {
                entries.append((name, String(describing: value)))
            }
        }

        try database.transaction {
            for (key, value) in entries {
                try database.run(
                    "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                    [.text(key), .text(value)]
                )
            }
        }
    }

    // MARK: - Aggregates gathered while streaming

    /// Bounded by the number of distinct apps and devices that ever wrote to
    /// Health, which is dozens — not by the number of records.
    private struct SourceKey: Hashable, Comparable {
        let name: String?
        let bundleIdentifier: String?
        let version: String?

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.name ?? "", lhs.bundleIdentifier ?? "", lhs.version ?? "")
                < (rhs.name ?? "", rhs.bundleIdentifier ?? "", rhs.version ?? "")
        }
    }

    private struct DeviceKey: Hashable, Comparable {
        let name: String?
        let manufacturer: String?
        let model: String?

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.name ?? "", lhs.manufacturer ?? "", lhs.model ?? "")
                < (rhs.name ?? "", rhs.manufacturer ?? "", rhs.model ?? "")
        }
    }

    private struct TypeState {
        let type: String
        var state: String?
        var records: Int?
        var queries: Int?
        var encodingErrors: Int?
        var message: String?
    }

    private static func count(
        _ record: ExportRecord,
        sources: inout [SourceKey: Int],
        devices: inout [DeviceKey: Int]
    ) {
        let source = SourceKey(
            name: record.sourceName,
            bundleIdentifier: record.sourceBundleIdentifier,
            version: record.sourceVersion
        )
        if source.name != nil || source.bundleIdentifier != nil {
            sources[source, default: 0] += 1
        }

        let device = DeviceKey(
            name: record.deviceName,
            manufacturer: record.deviceManufacturer,
            model: record.deviceModel
        )
        if device.name != nil || device.model != nil {
            devices[device, default: 0] += 1
        }
    }

    private static func note(
        start: Date?,
        end: Date?,
        into earliest: inout Date?,
        _ latest: inout Date?
    ) {
        if let start {
            earliest = min(earliest ?? start, start)
        }
        if let end {
            latest = max(latest ?? end, end)
        } else if let start {
            latest = max(latest ?? start, start)
        }
    }

    private static func merge(
        _ record: ExportRecord,
        into states: inout [String: TypeState]
    ) {
        guard let type = record.type else {
            return
        }
        var state = states[type] ?? TypeState(type: type)
        if record.kind == "typeSummary" {
            state.state = record.object["state"] as? String
            state.records = ExportRecord.number(record.object["records"])
                .map { Int($0) }
            state.queries = ExportRecord.number(record.object["queries"])
                .map { Int($0) }
            state.encodingErrors =
                ExportRecord.number(record.object["encodingErrors"]).map { Int($0) }
        } else {
            state.state = record.object["coverage"] as? String
            state.message = record.message
        }
        states[type] = state
    }

    /// A characteristic's plain value, whatever shape the encoder gave it.
    private static func characteristicValue(_ record: ExportRecord) -> String? {
        if let text = record.object["value"] as? String {
            return text
        }
        if let number = ExportRecord.number(record.object["value"]) {
            return ExportRecord.plain(number)
        }
        if let quantity = record.object["quantity"] as? [String: Any],
           let number = ExportRecord.number(quantity["value"]) {
            return ExportRecord.plain(number)
        }
        return nil
    }

    private static func count(
        in database: SQLiteDatabase,
        table: String
    ) throws -> Int {
        let rows = try database.query(
            "SELECT count(*) FROM \(table)",
            row: { $0.integer(0) }
        )
        return Int(rows.first ?? 0)
    }

    private static func text(_ value: String?) -> SQLiteValue {
        value.map { SQLiteValue.text($0) } ?? .null
    }

    private static func epoch(_ date: Date?) -> SQLiteValue {
        date.map { SQLiteValue.real($0.timeIntervalSince1970) } ?? .null
    }
}
