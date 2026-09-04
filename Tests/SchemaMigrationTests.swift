import Foundation
@testable import HozzReceive
import HozzStore
import XCTest

/// Someone's health history has to survive an upgrade.
///
/// The receiver's schema went from 1 to 8 in a single evening across five
/// agents' commits, and every user upgrading arrives from one of those
/// versions. The previous test for this built a database at the *current*
/// schema, dropped two tables, and set `user_version = 2` — so every other
/// table already existed, every `CREATE TABLE IF NOT EXISTS` was a no-op, and
/// the test passed while exercising almost none of the path.
///
/// These fixtures are built by construction: the actual tables and columns as
/// they existed at each version, populated, then opened with today's code.
/// Anything less repeats the shortcut that made the old test hollow.
final class SchemaMigrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The current schema. Every historical fixture must reach this.
    private static let currentVersion: Int64 = 12

    // MARK: - The historical schemas, as they actually were

    /// Tables as they existed at each version, in the order they were added.
    ///
    /// Written out rather than derived, because deriving them from today's
    /// code is what made the old test vacuous.
    private static let sampleTable = """
        CREATE TABLE IF NOT EXISTS sample (
            id TEXT NOT NULL, type TEXT NOT NULL, kind TEXT,
            start_date TEXT NOT NULL, end_date TEXT NOT NULL,
            value REAL, unit TEXT, source_name TEXT,
            raw BLOB NOT NULL, received_at TEXT NOT NULL,
            PRIMARY KEY (id, type)
        );
        CREATE INDEX IF NOT EXISTS sample_type_start ON sample (type, start_date);
        CREATE INDEX IF NOT EXISTS sample_start ON sample (start_date);
        CREATE TABLE IF NOT EXISTS batch (
            key TEXT PRIMARY KEY, received_at TEXT NOT NULL,
            record_count INTEGER NOT NULL
        );
        """

    private static let deviceTable = """
        CREATE TABLE IF NOT EXISTS device (
            name TEXT PRIMARY KEY, first_seen_at TEXT NOT NULL,
            last_seen_at TEXT NOT NULL,
            delivered_records INTEGER NOT NULL DEFAULT 0
        );
        """

    /// Version 3's `unhandled_record`, which crucially has **no**
    /// `parser_version` column. That column is the only one ever added to an
    /// existing table, so this is the one genuinely risky path.
    private static let characteristicAndQuarantine = """
        CREATE TABLE IF NOT EXISTS characteristic (
            type TEXT PRIMARY KEY, state TEXT, value TEXT,
            raw_value INTEGER, read_at TEXT,
            raw BLOB NOT NULL, received_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS unhandled_record (
            fingerprint TEXT PRIMARY KEY, kind TEXT, reason TEXT,
            raw BLOB NOT NULL, received_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS unhandled_kind ON unhandled_record (kind);
        """

    private static let parserVersionColumn = """
        ALTER TABLE unhandled_record
            ADD COLUMN parser_version INTEGER NOT NULL DEFAULT 0;
        """

    private static let seriesTables = """
        CREATE TABLE IF NOT EXISTS electrocardiogram (
            id TEXT PRIMARY KEY, start_date TEXT NOT NULL, end_date TEXT,
            classification TEXT, classification_raw INTEGER,
            symptoms_status TEXT, average_heart_rate REAL, sampling_hz REAL,
            expected_voltages INTEGER, source_name TEXT,
            raw BLOB NOT NULL, received_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS electrocardiogram_voltage_page (
            sample_id TEXT NOT NULL, sequence INTEGER NOT NULL,
            offset INTEGER NOT NULL, point_count INTEGER NOT NULL,
            points BLOB NOT NULL, PRIMARY KEY (sample_id, sequence)
        );
        CREATE TABLE IF NOT EXISTS audiogram (
            id TEXT PRIMARY KEY, start_date TEXT NOT NULL, end_date TEXT,
            source_name TEXT, raw BLOB NOT NULL, received_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS audiogram_point (
            audiogram_id TEXT NOT NULL, frequency REAL NOT NULL,
            ear TEXT NOT NULL, sensitivity REAL, unit TEXT, masked INTEGER,
            clamped INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (audiogram_id, frequency, ear)
        );
        """

    private static let moodAndMedicationTables = """
        CREATE TABLE IF NOT EXISTS state_of_mind (
            id TEXT PRIMARY KEY, start_date TEXT NOT NULL, end_date TEXT,
            valence REAL NOT NULL, classification TEXT, kind_of_entry TEXT,
            labels TEXT, associations TEXT, source_name TEXT,
            raw BLOB NOT NULL, received_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS medication_dose (
            id TEXT PRIMARY KEY, start_date TEXT NOT NULL,
            log_status TEXT NOT NULL, schedule_type TEXT, dose_quantity REAL,
            scheduled_dose_quantity REAL, unit TEXT, medication_name TEXT,
            medication_form TEXT, source_name TEXT,
            raw BLOB NOT NULL, received_at TEXT NOT NULL
        );
        """

    private static let workoutAndQuantitySeriesTables = """
        CREATE TABLE IF NOT EXISTS workout_detail (
            id TEXT PRIMARY KEY, start_date TEXT NOT NULL, end_date TEXT,
            activity_type INTEGER, duration_seconds REAL, source_name TEXT,
            received_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS workout_detail_start
            ON workout_detail (start_date);
        CREATE TABLE IF NOT EXISTS workout_statistic (
            workout_id TEXT NOT NULL, activity_id TEXT NOT NULL DEFAULT '',
            type TEXT NOT NULL, unit TEXT, sum REAL, average REAL,
            minimum REAL, maximum REAL,
            PRIMARY KEY (workout_id, activity_id, type)
        );
        CREATE TABLE IF NOT EXISTS workout_activity (
            id TEXT PRIMARY KEY, workout_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL, activity_type INTEGER,
            start_date TEXT NOT NULL, end_date TEXT
        );
        CREATE INDEX IF NOT EXISTS workout_activity_workout
            ON workout_activity (workout_id, ordinal);
        CREATE TABLE IF NOT EXISTS quantity_series_page (
            sample_id TEXT NOT NULL, type TEXT NOT NULL,
            sequence INTEGER NOT NULL, offset INTEGER NOT NULL,
            reading_count INTEGER NOT NULL, unit TEXT,
            start_date TEXT NOT NULL, end_date TEXT, readings BLOB NOT NULL,
            PRIMARY KEY (sample_id, sequence)
        );
        CREATE INDEX IF NOT EXISTS quantity_series_page_sample
            ON quantity_series_page (sample_id, offset);
        CREATE INDEX IF NOT EXISTS quantity_series_page_type
            ON quantity_series_page (type, start_date);
        CREATE TABLE IF NOT EXISTS quantity_series (
            sample_id TEXT PRIMARY KEY, type TEXT NOT NULL,
            exported_readings INTEGER NOT NULL,
            start_date TEXT NOT NULL, end_date TEXT
        );
        """

    private static let typeCoverageTable = """
        CREATE TABLE IF NOT EXISTS type_coverage (
            type TEXT PRIMARY KEY, state TEXT NOT NULL,
            delivered_count INTEGER, primed_from TEXT, primed_through TEXT,
            observed_at TEXT NOT NULL, received_at TEXT NOT NULL
        );
        """

    private static let legacyAliasTables = """
        CREATE TABLE IF NOT EXISTS sample_tombstone (
            id TEXT PRIMARY KEY, received_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sample_identity_alias (
            stable_id TEXT PRIMARY KEY, legacy_id TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS sample_identity_alias_legacy
            ON sample_identity_alias (legacy_id);
        CREATE TABLE IF NOT EXISTS sample_unresolved_legacy_deletion (
            stable_id TEXT PRIMARY KEY, type TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sample_alias_retirement (
            type TEXT NOT NULL, start_time TEXT NOT NULL,
            PRIMARY KEY (type, start_time)
        );
        """

    private static let aliasSignatureTable = """
        CREATE TABLE IF NOT EXISTS sample_alias_signature (
            stable_id TEXT PRIMARY KEY, type TEXT NOT NULL, kind TEXT,
            start_time TEXT NOT NULL, end_time TEXT NOT NULL, value REAL,
            unit TEXT, source_name TEXT
        );
        CREATE INDEX IF NOT EXISTS sample_alias_signature_lookup
            ON sample_alias_signature (
                type, start_time, end_time, kind, value, unit, source_name
            );
        """

    /// Builds a database exactly as version `version` left it, with data in it.
    private func makeHistoricalDatabase(version: Int64) throws -> URL {
        let url = root.appending(path: "store-v\(version)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        let databaseURL = url.appending(path: "hozz-received.sqlite")
        let database = try SQLiteDatabase(url: databaseURL)

        try database.execute(Self.sampleTable)
        if version >= 2 {
            try database.execute(Self.deviceTable)
        }
        if version >= 3 {
            try database.execute(Self.characteristicAndQuarantine)
        }
        if version >= 4 {
            try database.execute(Self.parserVersionColumn)
            try database.execute(
                """
                CREATE INDEX IF NOT EXISTS unhandled_parser_version
                    ON unhandled_record (parser_version);
                """
            )
        }
        if version >= 5 {
            try database.execute(Self.seriesTables)
        }
        if version >= 6 {
            try database.execute(Self.moodAndMedicationTables)
        }

        try seed(database, version: version)
        try database.execute("PRAGMA user_version = \(version)")
        database.close()
        return url
    }

    /// An archive as the selected receiver version wrote it, before receipts
    /// carried their durability semantics explicitly.
    private func makeReceiptDatabase(
        version: Int64,
        name: String,
        deletionHasTombstone: Bool? = nil
    ) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        let database = try SQLiteDatabase(
            url: url.appending(path: "hozz-received.sqlite")
        )
        try database.execute(Self.sampleTable)
        try database.execute(Self.deviceTable)
        try database.execute(Self.characteristicAndQuarantine)
        try database.execute(Self.parserVersionColumn)
        try database.execute(Self.seriesTables)
        try database.execute(Self.moodAndMedicationTables)
        try database.execute(Self.workoutAndQuantitySeriesTables)
        try database.execute(Self.typeCoverageTable)
        if version >= 10 {
            try database.execute(Self.legacyAliasTables)
        }
        if version >= 11 {
            try database.execute(Self.aliasSignatureTable)
        }
        try database.run(
            """
            INSERT INTO sample
                (id, type, kind, start_date, end_date, value, unit,
                 source_name, raw, received_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text("stale-value"), .text("steps"), .text("quantity"),
                .text("2026-01-01T09:00:00.000Z"),
                .text("2026-01-01T09:00:00.000Z"), .real(2),
                .text("count"), .text("iPhone"),
                .blob(Data(#"{"id":"stale-value","value":2}"#.utf8)),
                .text("2026-01-01T12:00:00.000Z")
            ]
        )
        try database.run(
            """
            INSERT INTO batch (key, received_at, record_count)
            VALUES (?, ?, ?)
            """,
            [
                .text("stale-upsert-receipt"),
                .text("2026-01-01T11:00:00.000Z"),
                .integer(1)
            ]
        )
        try database.run(
            """
            INSERT INTO sample
                (id, type, kind, start_date, end_date, value, unit,
                 source_name, raw, received_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text("deleted-before-upgrade"), .text("steps"),
                .text("quantity"), .text("2026-01-01T10:00:00.000Z"),
                .text("2026-01-01T10:00:00.000Z"), .real(1),
                .text("count"), .text("iPhone"),
                .blob(Data(#"{"id":"deleted-before-upgrade"}"#.utf8)),
                .text("2026-01-01T11:00:00.000Z")
            ]
        )
        try database.run(
            "DELETE FROM sample WHERE id = ?",
            [.text("deleted-before-upgrade")]
        )
        if deletionHasTombstone ?? (version >= 10) {
            try database.run(
                """
                INSERT INTO sample_tombstone (id, received_at)
                VALUES (?, ?)
                """,
                [
                    .text("deleted-before-upgrade"),
                    .text("2026-01-01T11:00:00.000Z")
                ]
            )
        }
        try database.run(
            """
            INSERT INTO batch (key, received_at, record_count)
            VALUES (?, ?, ?)
            """,
            [
                .text("legacy-deletion-receipt"),
                .text("2026-01-01T11:00:00.000Z"),
                .integer(0)
            ]
        )
        try database.execute("PRAGMA user_version = \(version)")
        database.close()
        return url
    }

    /// Representative data of everything that version could hold.
    private func seed(_ database: SQLiteDatabase, version: Int64) throws {
        for index in 0..<25 {
            try database.run(
                """
                INSERT INTO sample
                    (id, type, kind, start_date, end_date, value, unit,
                     source_name, raw, received_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text("sample-\(index)"),
                    .text("HKQuantityTypeIdentifierStepCount"),
                    .text("quantity"),
                    .text("2026-01-\(String(format: "%02d", index + 1))T09:00:00.000Z"),
                    .text("2026-01-\(String(format: "%02d", index + 1))T09:01:00.000Z"),
                    .real(Double(100 + index)),
                    .text("count"),
                    .text("Apple Watch"),
                    .blob(Data(#"{"kind":"quantity","sample":"s\#(index)"}"#.utf8)),
                    .text("2026-01-31T00:00:00.000Z")
                ]
            )
        }
        try database.run(
            "INSERT INTO batch (key, received_at, record_count) VALUES (?, ?, ?)",
            [.text("batch-1"), .text("2026-01-31T00:00:00.000Z"), .integer(25)]
        )

        if version >= 2 {
            try database.run(
                """
                INSERT INTO device (name, first_seen_at, last_seen_at, delivered_records)
                VALUES (?, ?, ?, ?)
                """,
                [
                    .text("Brando's iPhone"),
                    .text("2026-01-01T00:00:00.000Z"),
                    .text("2026-01-31T00:00:00.000Z"),
                    .integer(25)
                ]
            )
        }
        if version >= 3 {
            try database.run(
                """
                INSERT INTO characteristic (type, state, value, read_at, raw, received_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                [
                    .text("HKCharacteristicTypeIdentifierBloodType"),
                    .text("known"), .text("APositive"),
                    .text("2026-01-01T00:00:00.000Z"),
                    .blob(Data(#"{"state":"known","value":"APositive"}"#.utf8)),
                    .text("2026-01-31T00:00:00.000Z")
                ]
            )
            // A quarantined record from before promotion existed. Its
            // parser_version must end up at 0 so it is reconsidered once.
            let columns = version >= 4
                ? "(fingerprint, kind, reason, raw, received_at, parser_version)"
                : "(fingerprint, kind, reason, raw, received_at)"
            let placeholders = version >= 4 ? "(?, ?, ?, ?, ?, ?)" : "(?, ?, ?, ?, ?)"
            var parameters: [SQLiteValue] = [
                .text("fingerprint-1"), .text("futureKind"),
                .text("No place yet."),
                .blob(Data(#"{"kind":"futureKind"}"#.utf8)),
                .text("2026-01-31T00:00:00.000Z")
            ]
            if version >= 4 {
                parameters.append(.integer(0))
            }
            try database.run(
                "INSERT INTO unhandled_record \(columns) VALUES \(placeholders)",
                parameters
            )
        }
        if version >= 5 {
            try database.run(
                """
                INSERT INTO electrocardiogram
                    (id, start_date, classification, expected_voltages, raw, received_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                [
                    .text("ecg-1"), .text("2026-01-10T09:00:00.000Z"),
                    .text("sinusRhythm"), .integer(2),
                    .blob(Data(#"{"kind":"electrocardiogram"}"#.utf8)),
                    .text("2026-01-31T00:00:00.000Z")
                ]
            )
            try database.run(
                """
                INSERT INTO audiogram (id, start_date, raw, received_at)
                VALUES (?, ?, ?, ?)
                """,
                [
                    .text("audio-1"), .text("2026-01-11T09:00:00.000Z"),
                    .blob(Data(#"{"kind":"audiogram"}"#.utf8)),
                    .text("2026-01-31T00:00:00.000Z")
                ]
            )
        }
        if version >= 6 {
            try database.run(
                """
                INSERT INTO state_of_mind
                    (id, start_date, valence, classification, kind_of_entry,
                     labels, associations, raw, received_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text("mood-1"), .text("2026-01-12T09:00:00.000Z"),
                    .real(0.5), .text("pleasant"), .text("dailyMood"),
                    .text("content"), .text("work"),
                    .blob(Data(#"{"kind":"stateOfMind"}"#.utf8)),
                    .text("2026-01-31T00:00:00.000Z")
                ]
            )
            try database.run(
                """
                INSERT INTO medication_dose
                    (id, start_date, log_status, medication_name, raw, received_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                [
                    .text("dose-1"), .text("2026-01-13T09:00:00.000Z"),
                    .text("taken"), .text("Atorvastatin"),
                    .blob(Data(#"{"kind":"medicationDose"}"#.utf8)),
                    .text("2026-01-31T00:00:00.000Z")
                ]
            )
        }
    }

    // MARK: - Helpers

    private func tables(in databaseURL: URL) throws -> Set<String> {
        let database = try SQLiteDatabase(url: databaseURL)
        defer { database.close() }
        return Set(
            try database.query(
                "SELECT name FROM sqlite_master WHERE type = 'table'",
                row: { $0.text(0) }
            )
        )
    }

    private func version(of databaseURL: URL) throws -> Int64 {
        let database = try SQLiteDatabase(url: databaseURL)
        defer { database.close() }
        return try database.query(
            "PRAGMA user_version",
            row: { $0.integer(0) }
        ).first ?? -1
    }

    private func count(_ table: String, in databaseURL: URL) throws -> Int {
        let database = try SQLiteDatabase(url: databaseURL)
        defer { database.close() }
        return Int(
            try database.query(
                "SELECT count(*) FROM \(table)",
                row: { $0.integer(0) }
            ).first ?? -1
        )
    }

    /// Every table today's fresh install creates.
    private func freshInstallTables() throws -> Set<String> {
        let directory = root.appending(path: "fresh")
        let store = try IngestStore(directory: directory)
        Task { await store.close() }
        return try tables(in: directory.appending(path: "hozz-received.sqlite"))
    }

    // MARK: - Every upgrade path

    /// The test the old one claimed to be. Each historical version is built as
    /// it really was, opened with today's code, and checked for both structure
    /// and data.
    func testEveryHistoricalVersionUpgradesWithoutLosingAnything() async throws {
        let expectedTables = try freshInstallTables()

        for version in Int64(1)...6 {
            let directory = try makeHistoricalDatabase(version: version)
            let databaseURL = directory.appending(path: "hozz-received.sqlite")

            // Opening runs the migration.
            let store = try IngestStore(directory: directory)

            let samples = try await store.totalRecordCount()
            XCTAssertEqual(
                samples,
                25,
                "Upgrading from version \(version) lost samples."
            )

            // Spot-check a value and an identifier, because a migration that
            // creates the right tables and silently drops or blanks rows is
            // the failure that matters.
            let stored = try await store.samples(
                type: "HKQuantityTypeIdentifierStepCount",
                limit: 100
            )
            XCTAssertEqual(stored.count, 25, "from version \(version)")
            let first = try XCTUnwrap(
                stored.first { $0.id == "sample-7" },
                "A specific record vanished upgrading from version \(version)."
            )
            XCTAssertEqual(first.value, 107, "from version \(version)")
            XCTAssertEqual(first.unit, "count", "from version \(version)")
            XCTAssertEqual(first.sourceName, "Apple Watch", "from version \(version)")

            if version >= 3 {
                let characteristics = try await store.characteristics()
                XCTAssertEqual(
                    characteristics.first?.value,
                    "APositive",
                    "A characteristic was lost upgrading from version \(version)."
                )
            }
            if version >= 5 {
                let ecgs = try await store.electrocardiograms()
                XCTAssertEqual(
                    ecgs.first?.classification,
                    "sinusRhythm",
                    "An ECG was lost upgrading from version \(version)."
                )
            }
            if version >= 6 {
                let moods = try await store.moodEntries()
                XCTAssertEqual(moods.first?.valence, 0.5, "from version \(version)")
                let adherence = try await store.medicationAdherence()
                XCTAssertEqual(adherence.first?.taken, 1, "from version \(version)")
            }

            await store.close()

            XCTAssertEqual(
                try self.version(of: databaseURL),
                Self.currentVersion,
                "Version \(version) did not reach the current schema."
            )

            let after = try tables(in: databaseURL)
            XCTAssertTrue(
                expectedTables.isSubset(of: after),
                """
                Upgrading from version \(version) is missing \
                \(expectedTables.subtracting(after).sorted()).
                """
            )
        }
    }

    /// The one column ever added to an existing table, and therefore the only
    /// place a migration could have damaged data rather than merely omitted a
    /// table.
    func testTheQuarantineColumnIsAddedWithoutLosingQuarantinedRecords() async throws {
        let directory = try makeHistoricalDatabase(version: 3)
        let databaseURL = directory.appending(path: "hozz-received.sqlite")

        let store = try IngestStore(directory: directory)
        await store.close()

        let database = try SQLiteDatabase(url: databaseURL)
        defer { database.close() }

        let columns = try database.query(
            "PRAGMA table_info(unhandled_record)",
            row: { $0.text(1) }
        )
        XCTAssertTrue(columns.contains("parser_version"), "\(columns)")

        let rows = try database.query(
            "SELECT fingerprint, kind, parser_version FROM unhandled_record",
            row: { ($0.text(0), $0.text(1), $0.integer(2)) }
        )
        XCTAssertEqual(rows.count, 1, "The quarantined record was lost.")
        XCTAssertEqual(rows.first?.0, "fingerprint-1")
        XCTAssertEqual(
            rows.first?.2,
            Int64(BatchParser.parserVersion),
            """
            A record quarantined before promotion existed defaults to 0, which \
            is below every real parser version, so opening the store \
            reconsiders it exactly once and stamps it with the version that \
            examined it. Still 0 would mean the pass never looked at it.
            """
        )
    }

    // MARK: - Idempotency and interruption

    func testOpeningRepeatedlyChangesNothing() async throws {
        let directory = try makeHistoricalDatabase(version: 2)
        let databaseURL = directory.appending(path: "hozz-received.sqlite")

        for _ in 0..<3 {
            let store = try IngestStore(directory: directory)
            await store.close()
        }

        XCTAssertEqual(try count("sample", in: databaseURL), 25)
        XCTAssertEqual(try count("device", in: databaseURL), 1)
        XCTAssertEqual(try version(of: databaseURL), Self.currentVersion)
    }

    /// A Mac going to sleep, or an app being force-quit, during the first
    /// launch after an upgrade is a real scenario.
    ///
    /// The migration runs inside one transaction, so SQLite either applies all
    /// of it or none of it — there is no half-migrated state to reopen. This
    /// simulates the interrupted attempt by rolling the transaction back, then
    /// checks that the database is still the version it was and still opens.
    func testAnInterruptedMigrationLeavesTheDatabaseUsable() async throws {
        let directory = try makeHistoricalDatabase(version: 2)
        let databaseURL = directory.appending(path: "hozz-received.sqlite")

        do {
            let database = try SQLiteDatabase(url: databaseURL)
            defer { database.close() }
            // Part of the migration applies, then the process dies before the
            // version is bumped.
            try database.execute("BEGIN IMMEDIATE;")
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS characteristic (
                    type TEXT PRIMARY KEY, state TEXT, value TEXT,
                    raw_value INTEGER, read_at TEXT,
                    raw BLOB NOT NULL, received_at TEXT NOT NULL
                );
                """
            )
            try database.execute("ROLLBACK;")

            XCTAssertEqual(
                try database.query("PRAGMA user_version", row: { $0.integer(0) }).first,
                2,
                "A rolled-back migration must not have advanced the version."
            )
        }

        // Reopening completes it, with everything still there.
        let store = try IngestStore(directory: directory)
        let samples = try await store.totalRecordCount()
        await store.close()

        XCTAssertEqual(samples, 25, "The interrupted attempt cost records.")
        XCTAssertEqual(try version(of: databaseURL), Self.currentVersion)
        XCTAssertTrue(
            try tables(in: databaseURL).contains("workout_detail"),
            "Reopening after an interruption has to finish the job."
        )
    }

    /// A database already at the current version must not be touched.
    func testACurrentDatabaseIsLeftAlone() async throws {
        let directory = root.appending(path: "current")
        let store = try IngestStore(directory: directory)
        await store.close()

        let databaseURL = directory.appending(path: "hozz-received.sqlite")
        let before = try tables(in: databaseURL)

        let reopened = try IngestStore(directory: directory)
        await reopened.close()

        XCTAssertEqual(try tables(in: databaseURL), before)
        XCTAssertEqual(try version(of: databaseURL), Self.currentVersion)
    }

    func testVersionNineStaleUpsertIsIgnoredAndDeletionReplays() async throws {
        let directory = try makeReceiptDatabase(
            version: 9,
            name: "store-v9-receipts"
        )
        let databaseURL = directory.appending(path: "hozz-received.sqlite")
        let upgraded = try IngestStore(directory: directory)
        let staleValueReplay = try BatchParser.parse(
            Data(
                #"{"id":"stale-value","type":"steps","kind":"quantity","startDate":"2026-01-01T09:00:00.000Z","quantity":{"value":1,"unit":"count"}}"#.utf8
            )
        )
        let staleResult = try await upgraded.ingest(
            staleValueReplay,
            idempotencyKey: "stale-upsert-receipt"
        )
        XCTAssertTrue(staleResult.duplicate)
        let samplesAfterStaleReplay = try await upgraded.samples(type: "steps")
        let preserved = samplesAfterStaleReplay.first { $0.id == "stale-value" }
        XCTAssertEqual(preserved?.value, 2)

        let staleUpsert = try BatchParser.parse(
            Data(
                #"{"id":"deleted-before-upgrade","type":"steps","kind":"quantity","startDate":"2026-01-01T10:00:00.000Z","quantity":{"value":1,"unit":"count"}}"#.utf8
            )
        )
        _ = try await upgraded.ingest(
            staleUpsert,
            idempotencyKey: "stale-before-deletion-replay"
        )
        let resurrectedCount = try await upgraded.totalRecordCount()
        XCTAssertEqual(resurrectedCount, 2)

        let deletion = try BatchParser.parse(
            Data(
                #"{"id":"deleted-before-upgrade","type":"steps","kind":"deletion","deleted":true}"#.utf8
            )
        )
        let replay = try await upgraded.ingest(
            deletion,
            idempotencyKey: "legacy-deletion-receipt"
        )
        XCTAssertFalse(replay.duplicate)
        XCTAssertEqual(replay.deleted, 1)
        let countAfterReplay = try await upgraded.totalRecordCount()
        XCTAssertEqual(countAfterReplay, 1)

        _ = try await upgraded.ingest(
            staleUpsert,
            idempotencyKey: "stale-after-deletion-replay"
        )
        let finalCount = try await upgraded.totalRecordCount()
        XCTAssertEqual(finalCount, 1)
        let secondReplay = try await upgraded.ingest(
            deletion,
            idempotencyKey: "legacy-deletion-receipt"
        )
        XCTAssertTrue(secondReplay.duplicate)
        await upgraded.close()

        XCTAssertEqual(try version(of: databaseURL), Self.currentVersion)
        XCTAssertTrue(try tables(in: databaseURL).contains("sample_tombstone"))
        XCTAssertTrue(try tables(in: databaseURL).contains("sample_identity_alias"))
        XCTAssertTrue(
            try tables(in: databaseURL)
                .contains("sample_unresolved_legacy_deletion")
        )
        XCTAssertTrue(try tables(in: databaseURL).contains("sample_alias_retirement"))
        XCTAssertTrue(try tables(in: databaseURL).contains("sample_alias_signature"))
    }

    func testVersionTenAndElevenInheritedReceiptsRemainVersionZero() async throws {
        for version in [Int64(10), 11] {
            let directory = try makeReceiptDatabase(
                version: version,
                name: "store-v\(version)-receipt"
            )
            let migrated = try IngestStore(directory: directory)
            await migrated.close()
            let databaseURL = directory.appending(path: "hozz-received.sqlite")
            let database = try SQLiteDatabase(url: databaseURL)
            let inheritedVersions = try database.query(
                "SELECT receipt_version FROM batch ORDER BY key",
                row: { $0.integer(0) }
            )
            database.close()
            XCTAssertEqual(inheritedVersions, [0, 0], "version \(version)")

            let upgraded = try IngestStore(directory: directory)
            let staleValueReplay = try BatchParser.parse(
                Data(
                    #"{"id":"stale-value","type":"steps","kind":"quantity","startDate":"2026-01-01T09:00:00.000Z","quantity":{"value":1,"unit":"count"}}"#.utf8
                )
            )

            let result = try await upgraded.ingest(
                staleValueReplay,
                idempotencyKey: "stale-upsert-receipt"
            )

            XCTAssertTrue(result.duplicate, "version \(version)")
            let deletion = try BatchParser.parse(
                Data(
                    #"{"id":"deleted-before-upgrade","type":"steps","kind":"deletion","deleted":true}"#.utf8
                )
            )
            let deletionResult = try await upgraded.ingest(
                deletion,
                idempotencyKey: "legacy-deletion-receipt"
            )
            XCTAssertFalse(deletionResult.duplicate, "version \(version)")
            let samples = try await upgraded.samples(type: "steps")
            let preserved = samples.first { $0.id == "stale-value" }
            XCTAssertEqual(preserved?.value, 2, "version \(version)")
            await upgraded.close()

            let promoted = try SQLiteDatabase(url: databaseURL)
            let promotedVersions = try promoted.query(
                "SELECT receipt_version FROM batch ORDER BY key",
                row: { $0.integer(0) }
            )
            promoted.close()
            XCTAssertEqual(promotedVersions, [1, 1], "version \(version)")
        }
    }

    func testVersionElevenCarriedPreTenReceiptReplaysOnlyDeletion() async throws {
        let directory = try makeReceiptDatabase(
            version: 11,
            name: "store-v11-carried-v9-receipt",
            deletionHasTombstone: false
        )
        let databaseURL = directory.appending(path: "hozz-received.sqlite")
        let migrated = try IngestStore(directory: directory)
        await migrated.close()
        let raw = try SQLiteDatabase(url: databaseURL)
        let inheritedVersion = try raw.query(
            """
            SELECT receipt_version FROM batch
            WHERE key = 'legacy-deletion-receipt'
            """,
            row: { $0.integer(0) }
        ).first
        raw.close()
        XCTAssertEqual(inheritedVersion, 0)

        let store = try IngestStore(directory: directory)
        let resurrected = try BatchParser.parse(
            Data(
                #"{"id":"deleted-before-upgrade","type":"steps","kind":"quantity","startDate":"2026-01-01T10:00:00.000Z","quantity":{"value":9,"unit":"count"}}"#.utf8
            )
        )
        _ = try await store.ingest(
            resurrected,
            idempotencyKey: "newer-resurrection"
        )
        let carriedPayload = try BatchParser.parse(
            Data(
                """
                {"id":"stale-value","type":"steps","kind":"quantity","startDate":"2026-01-01T09:00:00.000Z","quantity":{"value":1,"unit":"count"}}
                {"id":"deleted-before-upgrade","type":"steps","kind":"deletion","deleted":true}
                """.utf8
            )
        )

        let replay = try await store.ingest(
            carriedPayload,
            idempotencyKey: "legacy-deletion-receipt"
        )

        XCTAssertFalse(replay.duplicate)
        XCTAssertEqual(replay.deleted, 1)
        let remaining = try await store.samples(type: "steps")
        XCTAssertEqual(remaining.map(\.id), ["stale-value"])
        XCTAssertEqual(remaining.first?.value, 2)
        _ = try await store.ingest(
            resurrected,
            idempotencyKey: "delayed-after-reconciliation"
        )
        let final = try await store.samples(type: "steps")
        XCTAssertEqual(final.map(\.id), ["stale-value"])
        XCTAssertEqual(final.first?.value, 2)
        await store.close()
    }

    func testVersionTenDatabaseGainsSignatureTable() async throws {
        let directory = root.appending(path: "version-ten")
        let store = try IngestStore(directory: directory)
        await store.close()
        let databaseURL = directory.appending(path: "hozz-received.sqlite")
        let database = try SQLiteDatabase(url: databaseURL)
        try database.execute(
            """
            DROP TABLE sample_alias_signature;
            INSERT OR REPLACE INTO sample_tombstone (id, received_at)
            VALUES ('deleted-before-stable', '2026-01-01T00:00:00.000Z');
            INSERT OR REPLACE INTO sample_alias_retirement (type, start_time)
            VALUES ('step_count', '2026-01-01T00:00:00.000Z');
            PRAGMA user_version = 10;
            """
        )
        database.close()

        let upgraded = try IngestStore(directory: directory)
        await upgraded.close()

        XCTAssertEqual(try version(of: databaseURL), Self.currentVersion)
        XCTAssertTrue(try tables(in: databaseURL).contains("sample_alias_signature"))
        let migrated = try SQLiteDatabase(url: databaseURL)
        defer { migrated.close() }
        XCTAssertEqual(
            try migrated.query(
                """
                SELECT COUNT(*) FROM sample_unresolved_legacy_deletion
                WHERE type = 'step_count'
                """,
                row: { $0.integer(0) }
            ).first,
            1
        )
    }

    /// Five agents added tables in one evening. Someone adding one to the
    /// fresh-install path and forgetting the upgrade path should fail here
    /// rather than ship a receiver that works for new users and quietly lacks
    /// a table for everyone else.
    func testAnUpgradedDatabaseMatchesAFreshInstallExactly() async throws {
        let expected = try freshInstallTables()

        let directory = try makeHistoricalDatabase(version: 1)
        let store = try IngestStore(directory: directory)
        await store.close()

        let upgraded = try tables(in: directory.appending(path: "hozz-received.sqlite"))
        XCTAssertEqual(
            upgraded.subtracting(expected),
            [],
            "An upgrade produced tables a fresh install does not have."
        )
        XCTAssertEqual(
            expected.subtracting(upgraded),
            [],
            "A fresh install has tables an upgrade does not create."
        )
    }

    // MARK: - The phone's own store

    /// The phone store holds the cursors. Corrupting one means either
    /// re-reading everything or silently skipping records, so it gets the same
    /// treatment even though it is simpler.
    func testThePhoneStoreUpgradesFromVersionOneWithoutLosingCursors() async throws {
        let directory = root.appending(path: "phone")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let databaseURL = StoreLocation.databaseURL(in: directory)

        // Version 1: stream_state only, with a cursor in it.
        do {
            let database = try SQLiteDatabase(url: databaseURL)
            defer { database.close() }
            try database.execute(
                """
                CREATE TABLE stream_state (
                    scope TEXT NOT NULL,
                    type_key TEXT NOT NULL,
                    coverage TEXT NOT NULL,
                    committed_anchor BLOB,
                    record_count INTEGER NOT NULL DEFAULT 0,
                    observed_count INTEGER NOT NULL DEFAULT 0,
                    anchor_closed_at REAL,
                    failure_reason TEXT,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (scope, type_key)
                );
                """
            )
            try database.run(
                """
                INSERT INTO stream_state
                    (scope, type_key, coverage, committed_anchor, record_count,
                     observed_count, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text("destination:abc"),
                    .text("HKQuantityTypeIdentifierStepCount"),
                    .text("anchorClosed"),
                    .blob(Data([0x01, 0x02, 0x03])),
                    .integer(5_000),
                    .integer(5_000),
                    .real(Date.now.timeIntervalSince1970)
                ]
            )
            try database.execute("PRAGMA user_version = 1;")
        }

        let store = try HozzStore(directory: directory)
        let version = try await store.schemaVersion()
        XCTAssertEqual(version, 5)

        let database = try SQLiteDatabase(url: databaseURL)
        defer { database.close() }

        let cursors = try database.query(
            """
            SELECT type_key, record_count, committed_anchor FROM stream_state
            """,
            row: { ($0.text(0), $0.integer(1), $0.blob(2)) }
        )
        XCTAssertEqual(cursors.count, 1, "The cursor was lost.")
        XCTAssertEqual(cursors.first?.1, 5_000)
        XCTAssertEqual(
            cursors.first?.2,
            Data([0x01, 0x02, 0x03]),
            """
            A cursor's anchor bytes must survive exactly. A changed anchor \
            means re-reading everything or silently skipping records.
            """
        )

        let tables = Set(
            try database.query(
                "SELECT name FROM sqlite_master WHERE type = 'table'",
                row: { $0.text(0) }
            )
        )
        XCTAssertTrue(tables.contains("destination"))
        XCTAssertTrue(tables.contains("delivery_state"))
        XCTAssertTrue(tables.contains("canonical_record_version"))
        XCTAssertTrue(
            tables.contains("prime_state"),
            """
            The dated prime's frontier must survive a migration from an older \
            store, and must arrive as its own table: an anchor and a frontier \
            sharing a row is one careless UPDATE away from losing history.
            """
        )
    }

    func testThePhoneStoreIsIdempotentAcrossReopens() async throws {
        let directory = root.appending(path: "phone-idempotent")

        for _ in 0..<3 {
            let store = try HozzStore(directory: directory)
            let version = try await store.schemaVersion()
            XCTAssertEqual(version, 5)
        }
    }
}
