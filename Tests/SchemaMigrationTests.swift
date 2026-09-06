import CryptoKit
import Foundation
import HozzCore
import HozzDeliver
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
    private static let currentVersion: Int64 = 14

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

    private static let legacyCompatibilityTables = """
        CREATE TABLE sample_legacy_compatibility_shape (
            legacy_id TEXT PRIMARY KEY, shape TEXT NOT NULL
        );
        CREATE TABLE sample_legacy_tombstone (
            type TEXT NOT NULL, start_time TEXT NOT NULL,
            legacy_id TEXT NOT NULL,
            PRIMARY KEY (type, start_time, legacy_id)
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
        if version >= 12 {
            try database.execute(
                """
                ALTER TABLE batch
                    ADD COLUMN receipt_version INTEGER NOT NULL DEFAULT 0;
                """
            )
        }
        if version >= 13 {
            try database.execute(Self.legacyCompatibilityTables)
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
            XCTAssertEqual(promotedVersions, [2, 2], "version \(version)")
        }
    }

    func testVersionOneFolderReceiptReplaysDeletionWithoutDowngradingUpserts()
        async throws
    {
        let directory = try makeReceiptDatabase(
            version: 12,
            name: "store-v12-version-one-folder-receipt"
        )
        let databaseURL = directory.appending(path: "hozz-received.sqlite")
        let payload = Data(
            """
            {"data":{
              "metrics":[{"name":"step_count","units":"count","data":[
                {"id":"preserved-stable","date":"2026-01-01 11:00:00 +0000","qty":1}
              ]}],
              "deletions":[
                {"id":"deleted-stable","name":"step_count",
                 "type":"HKQuantityTypeIdentifierStepCount","date":""}
              ]
            }}
            """.utf8
        )
        let digest = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
        let receiptKey = "folder-v2:\(digest)"
        let legacyID = "step_count:2026-01-01 10:00:00 +0000"
        let database = try SQLiteDatabase(url: databaseURL)
        try database.execute(
            """
            DELETE FROM sample;
            DELETE FROM batch;
            """
        )
        try database.run(
            """
            INSERT INTO sample
                (id, type, kind, start_date, end_date, value, unit,
                 source_name, raw, received_at)
            VALUES
                (?, 'step_count', 'quantity',
                 '2026-01-01T10:00:00.000Z',
                 '2026-01-01T10:00:00.000Z',
                 12, 'count', 'Watch', X'7B7D',
                 '2026-01-01T12:00:00.000Z'),
                ('preserved-stable', 'step_count', 'quantity',
                 '2026-01-01T11:00:00.000Z',
                 '2026-01-01T11:00:00.000Z',
                 99, 'count', 'Watch', X'7B7D',
                 '2026-01-01T12:00:00.000Z')
            """,
            [.text(legacyID)]
        )
        try database.run(
            """
            INSERT INTO sample_identity_alias (stable_id, legacy_id)
            VALUES ('deleted-stable', ?)
            """,
            [.text(legacyID)]
        )
        try database.run(
            """
            INSERT INTO batch
                (key, received_at, record_count, receipt_version)
            VALUES (?, '2026-01-01T12:00:00.000Z', 2, 1)
            """,
            [.text(receiptKey)]
        )
        database.close()

        let store = try IngestStore(directory: directory)
        let parsed = try BatchParser.parse(payload)
        let first = try await store.ingest(
            parsed,
            idempotencyKey: receiptKey
        )

        XCTAssertFalse(first.duplicate)
        XCTAssertEqual(first.stored, 0)
        XCTAssertEqual(first.deleted, 1)
        let samples = try await store.samples(type: "step_count")
        XCTAssertEqual(samples.map(\.id), ["preserved-stable"])
        XCTAssertEqual(samples.first?.value, 99)
        let second = try await store.ingest(
            parsed,
            idempotencyKey: receiptKey
        )
        XCTAssertTrue(second.duplicate)
        await store.close()

        let inspected = try SQLiteDatabase(url: databaseURL)
        defer { inspected.close() }
        XCTAssertEqual(
            try inspected.query(
                "SELECT receipt_version FROM batch WHERE key = ?",
                [.text(receiptKey)],
                row: { $0.integer(0) }
            ).first,
            2
        )
        XCTAssertEqual(
            try inspected.query(
                "SELECT COUNT(*) FROM sample_tombstone WHERE id IN (?, ?)",
                [.text("deleted-stable"), .text(legacyID)],
                row: { $0.integer(0) }
            ).first,
            2
        )
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

    func testVersionTwelveReconcilesLegacyHeartAndSleepShapesConservatively() async throws {
        let directory = try makeReceiptDatabase(
            version: 12,
            name: "version-twelve-legacy-metrics"
        )
        let databaseURL = directory.appending(path: "hozz-received.sqlite")
        let database = try SQLiteDatabase(url: databaseURL)
        try database.execute(
            """
            INSERT INTO sample
                (id, type, kind, start_date, end_date, value, unit,
                 source_name, raw, received_at)
            VALUES
                ('heart_rate:2026-01-01T10:00:00.000Z', 'heart_rate',
                 'quantity', '2026-01-01T10:00:00.000Z',
                 '2026-01-01T10:00:00.000Z', NULL, 'bpm', 'Watch', X'7B7D',
                 '2026-01-01T12:00:00.000Z'),
                ('heart-stable', 'heart_rate', 'quantity',
                 '2026-01-01T10:00:00.000Z',
                 '2026-01-01T10:00:00.000Z', 62, 'bpm', 'Watch', X'7B7D',
                 '2026-01-01T12:01:00.000Z'),
                ('heart_rate:2026-01-01T10:01:00.000Z', 'heart_rate',
                 'quantity', '2026-01-01T10:01:00.000Z',
                 '2026-01-01T10:01:00.000Z', NULL, 'bpm', 'Watch', X'7B7D',
                 '2026-01-01T12:00:00.000Z'),
                ('sleep_analysis:2026-01-01T11:00:00.000Z', 'sleep_analysis',
                 'quantity', '2026-01-01T11:00:00.000Z',
                 '2026-01-01T12:00:00.000Z', 1, 'hr', 'Watch', X'7B7D',
                 '2026-01-01T12:00:00.000Z'),
                ('sleep-stable', 'sleep_analysis', 'category',
                 '2026-01-01T11:00:00.000Z',
                 '2026-01-01T12:00:00.000Z', 5, 'hr', 'Watch', X'7B7D',
                 '2026-01-01T12:01:00.000Z'),
                ('sleep_analysis:2026-01-01T13:00:00.000Z', 'sleep_analysis',
                 'quantity', '2026-01-01T13:00:00.000Z',
                 '2026-01-01T14:00:00.000Z', 1, 'hr', 'Watch', X'7B7D',
                 '2026-01-01T14:01:00.000Z');
            INSERT INTO sample_alias_signature
                (stable_id, type, kind, start_time, end_time,
                 value, unit, source_name)
            VALUES
                ('heart-stable', 'heart_rate', 'quantity',
                 '2026-01-01T10:00:00.000Z',
                 '2026-01-01T10:00:00.000Z', 62, 'bpm', 'Watch'),
                ('sleep-stable', 'sleep_analysis', 'category',
                 '2026-01-01T11:00:00.000Z',
                 '2026-01-01T12:00:00.000Z', 5, 'hr', 'Watch');
            INSERT INTO sample_tombstone (id, received_at)
            VALUES (
                'sleep_analysis:2026-01-01T11:00:00.000Z',
                '2026-01-02T00:00:00.000Z'
            );
            INSERT INTO sample_alias_retirement (type, start_time)
            VALUES ('sleep_analysis', '2026-01-01T11:00:00.000Z');
            """
        )
        database.close()

        let upgraded = try IngestStore(directory: directory)

        XCTAssertEqual(try version(of: databaseURL), Self.currentVersion)
        let migratedHeart = try await upgraded.samples(type: "heart_rate")
        let migratedSleep = try await upgraded.samples(type: "sleep_analysis")
        XCTAssertEqual(
            migratedHeart.map(\.id),
            [
                "heart_rate:2026-01-01T10:01:00.000Z",
                "heart-stable"
            ]
        )
        XCTAssertEqual(
            migratedSleep.map(\.id),
            ["sleep_analysis:2026-01-01T13:00:00.000Z"],
            "A tombstone on either reconciled identity must remove both copies."
        )

        let migrated = try SQLiteDatabase(url: databaseURL)
        let aliases = try migrated.query(
            """
            SELECT stable_id, legacy_id FROM sample_identity_alias
            WHERE stable_id IN ('heart-stable', 'sleep-stable')
            ORDER BY stable_id
            """,
            row: { "\($0.text(0))=\($0.text(1))" }
        )
        let sleepLegacyTombstone = try migrated.query(
            """
            SELECT COUNT(*) FROM sample_tombstone
            WHERE id = 'sleep_analysis:2026-01-01T11:00:00.000Z'
            """,
            row: { $0.integer(0) }
        ).first
        migrated.close()
        XCTAssertEqual(
            aliases,
            [
                "heart-stable=heart_rate:2026-01-01T10:00:00.000Z",
                "sleep-stable=sleep_analysis:2026-01-01T11:00:00.000Z"
            ]
        )
        XCTAssertEqual(sleepLegacyTombstone, 1)

        _ = try await upgraded.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[
                      {"name":"heart_rate","units":"bpm","data":[
                        {"id":"heart-runtime","date":"2026-01-01T10:01:00.000Z",
                         "Min":63,"Avg":63,"Max":63,"source":"Watch"}]},
                      {"name":"sleep_analysis","units":"hr","data":[
                        {"id":"sleep-runtime",
                         "startDate":"2026-01-01T13:00:00.000Z",
                         "endDate":"2026-01-01T14:00:00.000Z",
                         "qty":1,"value":"Deep","rawValue":4,"source":"Watch"}]}
                    ]}}
                    """.utf8
                )
            ),
            idempotencyKey: "migrated-shape-runtime-reconciliation"
        )
        let reconciledHeart = try await upgraded.samples(type: "heart_rate")
        let reconciledSleep = try await upgraded.samples(type: "sleep_analysis")
        XCTAssertEqual(
            Set(reconciledHeart.map(\.id)),
            ["heart-stable", "heart-runtime"]
        )
        XCTAssertEqual(reconciledSleep.map(\.id), ["sleep-runtime"])
        XCTAssertEqual(reconciledSleep.first?.value, 4)

        _ = try await upgraded.ingest(
            try BatchParser.parse(
                Data(
                    #"{"id":"heart-runtime","kind":"deletion","schemaVersion":1,"type":"HKQuantityTypeIdentifierHeartRate"}"#
                        .utf8
                )
            ),
            idempotencyKey: "migrated-heart-delete"
        )
        let afterDeletion = try await upgraded.samples(type: "heart_rate")
        XCTAssertEqual(afterDeletion.map(\.id), ["heart-stable"])

        _ = try await upgraded.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"heart_rate","units":"bpm","data":[
                      {"id":"heart-runtime","date":"2026-01-01T10:01:00.000Z",
                       "Min":63,"Avg":63,"Max":63,"source":"Watch"}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "migrated-heart-replay"
        )
        let afterReplay = try await upgraded.samples(type: "heart_rate")
        XCTAssertEqual(afterReplay.map(\.id), ["heart-stable"])
        await upgraded.close()
    }

    func testVersionThirteenCountsEquivalentRetiredOffsetAliasBeforePairing()
        async throws
    {
        let directory = try makeReceiptDatabase(
            version: 12,
            name: "version-twelve-offset-alias-cardinality"
        )
        let databaseURL = directory.appending(path: "hozz-received.sqlite")
        let database = try SQLiteDatabase(url: databaseURL)
        try database.execute(
            """
            DELETE FROM sample;
            DELETE FROM batch;
            INSERT INTO sample
                (id, type, kind, start_date, end_date, value, unit,
                 source_name, raw, received_at)
            VALUES
                ('heart_rate:2026-01-01T05:00:00.000-05:00',
                 'heart_rate', 'quantity',
                 '2026-01-01T10:00:00.000Z',
                 '2026-01-01T10:00:00.000Z',
                 NULL, 'bpm', 'Watch', X'7B7D',
                 '2026-01-01T12:00:00.000Z'),
                ('stable-heart', 'heart_rate', 'quantity',
                 '2026-01-01T10:00:00.000Z',
                 '2026-01-01T10:00:00.000Z',
                 62, 'bpm', 'Watch', X'7B7D',
                 '2026-01-01T12:01:00.000Z');
            INSERT INTO sample_alias_signature
                (stable_id, type, kind, start_time, end_time,
                 value, unit, source_name)
            VALUES
                ('stable-heart', 'heart_rate', 'quantity',
                 '2026-01-01T10:00:00.000Z',
                 '2026-01-01T10:00:00.000Z',
                 62, 'bpm', 'Watch');
            INSERT INTO sample_tombstone (id, received_at)
            VALUES (
                'heart_rate:2026-01-01T10:00:00.000Z',
                '2026-01-02T00:00:00.000Z'
            );
            INSERT INTO sample_alias_retirement (type, start_time)
            VALUES ('heart_rate', '2026-01-01T10:00:00.000Z');
            """
        )
        database.close()

        let upgraded = try IngestStore(directory: directory)
        let samples = try await upgraded.samples(type: "heart_rate")
        XCTAssertEqual(
            Set(samples.map(\.id)),
            [
                "heart_rate:2026-01-01T05:00:00.000-05:00",
                "stable-heart"
            ],
            "Two equivalent legacy spellings are ambiguous, even when one is retired."
        )
        await upgraded.close()

        let inspected = try SQLiteDatabase(url: databaseURL)
        defer { inspected.close() }
        XCTAssertEqual(
            try inspected.query(
                """
                SELECT COUNT(*) FROM sample_identity_alias
                WHERE stable_id = 'stable-heart'
                """,
                row: { $0.integer(0) }
            ).first,
            0,
            "Migration must not guess which offset spelling named the stable sample."
        )
        XCTAssertEqual(
            try inspected.query(
                """
                SELECT COUNT(*) FROM sample_legacy_tombstone
                WHERE type = 'heart_rate'
                  AND start_time = '2026-01-01T10:00:00.000Z'
                """,
                row: { $0.integer(0) }
            ).first,
            1
        )
    }

    func testVersionTenRetirementSentinelPreservesEquivalentAliasAmbiguity()
        async throws
    {
        let legacyID = "heart_rate:2026-01-01T05:00:00.000-05:00"
        let retiredID = "heart_rate:2026-01-01T10:00:00.000Z"
        let directory = try makeAliasRepairDatabase(
            version: 10,
            legacyID: legacyID,
            retiredID: retiredID
        )
        try await assertAliasRepairRemainsAmbiguous(
            directory: directory,
            legacyID: legacyID,
            retiredID: retiredID,
            legacyRowSurvives: true
        )
    }

    func testVersionThirteenUnsafeMappingIsQuarantinedWithBothAliasIdentities()
        async throws
    {
        let legacyID = "heart_rate:2026-01-01T10:00:00.000Z"
        let retiredID = "heart_rate:2026-01-01T05:00:00.000-05:00"
        let directory = try makeAliasRepairDatabase(
            version: 13,
            legacyID: legacyID,
            retiredID: retiredID
        )
        try await assertAliasRepairRemainsAmbiguous(
            directory: directory,
            legacyID: legacyID,
            retiredID: retiredID,
            legacyRowSurvives: false
        )
    }

    private func makeAliasRepairDatabase(
        version: Int64,
        legacyID: String,
        retiredID: String
    ) throws -> URL {
        let directory = try makeReceiptDatabase(
            version: version,
            name: "alias-repair-v\(version)"
        )
        let database = try SQLiteDatabase(
            url: directory.appending(path: "hozz-received.sqlite")
        )
        defer { database.close() }
        try database.execute(
            """
            INSERT INTO sample
                (id, type, kind, start_date, end_date, value, unit,
                 source_name, raw, received_at)
            VALUES (
                'stable-heart', 'heart_rate', 'quantity',
                '2026-01-01T10:00:00.000Z', '2026-01-01T10:00:00.000Z',
                62, 'bpm', 'Watch', X'7B226B657074223A747275657D',
                '2026-01-01T12:01:00.000Z'
            );
            """
        )
        try database.run(
            """
            INSERT INTO sample_tombstone (id, received_at)
            VALUES (?, '2026-01-02T00:00:00.000Z')
            """,
            [.text(retiredID)]
        )
        if version == 10 {
            try database.run(
                """
                INSERT INTO sample
                    (id, type, kind, start_date, end_date, value, unit,
                     source_name, raw, received_at)
                VALUES (
                    ?, 'heart_rate', 'quantity',
                    '2026-01-01T10:00:00.000Z', '2026-01-01T10:00:00.000Z',
                    NULL, 'bpm', 'Watch', X'7B7D', '2026-01-01T12:00:00.000Z'
                )
                """,
                [.text(legacyID)]
            )
            try database.execute(
                """
                INSERT INTO sample_alias_retirement (type, start_time)
                VALUES ('heart_rate', '2026-01-01T10:00:00.000Z');
                """
            )
        } else {
            // The old version-13 repair already deleted this alias's sample.
            // Only its mapping, one-time shape, and retirement evidence survived.
            try database.execute(
                """
                INSERT INTO sample_alias_signature
                    (stable_id, type, kind, start_time, end_time,
                     value, unit, source_name)
                SELECT id, type, kind, start_date, end_date,
                       value, unit, source_name
                FROM sample WHERE id = 'stable-heart';
                INSERT INTO sample_unresolved_legacy_deletion (stable_id, type)
                VALUES (
                    'v10-retirement:heart_rate:2026-01-01T10:00:00.000Z',
                    'heart_rate'
                );
                INSERT INTO sample_alias_retirement (type, start_time)
                VALUES ('heart_rate', '2026-01-01T10:00:00.000Z');
                """
            )
            try database.run(
                """
                INSERT INTO sample_identity_alias (stable_id, legacy_id)
                VALUES ('stable-heart', ?)
                """,
                [.text(legacyID)]
            )
            try database.run(
                """
                INSERT INTO sample_legacy_compatibility_shape (legacy_id, shape)
                VALUES (?, 'heartRateRange')
                """,
                [.text(legacyID)]
            )
        }
        return directory
    }

    private func assertAliasRepairRemainsAmbiguous(
        directory: URL,
        legacyID: String,
        retiredID: String,
        legacyRowSurvives: Bool
    ) async throws {
        let databaseURL = directory.appending(path: "hozz-received.sqlite")
        let expectedIDs: Set<String> = legacyRowSurvives
            ? ["stable-heart", legacyID]
            : ["stable-heart"]
        let expectedRetiredIDs: Set<String> = legacyRowSurvives
            ? [retiredID]
            : [legacyID, retiredID]
        for _ in 0..<3 {
            let store = try IngestStore(directory: directory)
            let samples = try await store.samples(type: "heart_rate")
            XCTAssertEqual(Set(samples.map(\.id)), expectedIDs)
            XCTAssertEqual(samples.first { $0.id == "stable-heart" }?.value, 62)
            await store.close()

            let inspected = try SQLiteDatabase(url: databaseURL)
            XCTAssertEqual(
                try inspected.query(
                    "PRAGMA user_version",
                    row: { $0.integer(0) }
                ).first,
                Self.currentVersion
            )
            XCTAssertEqual(
                try inspected.query(
                    "SELECT COUNT(*) FROM sample_identity_alias",
                    row: { $0.integer(0) }
                ).first,
                0
            )
            let retiredIDs = try inspected.query(
                """
                SELECT legacy_id FROM sample_legacy_tombstone
                WHERE type = 'heart_rate'
                  AND start_time = '2026-01-01T10:00:00.000Z'
                """,
                row: { $0.text(0) }
            )
            XCTAssertEqual(Set(retiredIDs), expectedRetiredIDs)
            XCTAssertEqual(
                try inspected.query(
                    """
                    SELECT COUNT(*) FROM sample_unresolved_legacy_deletion
                    WHERE stable_id =
                        'v10-retirement:heart_rate:2026-01-01T10:00:00.000Z'
                    """,
                    row: { $0.integer(0) }
                ).first,
                1,
                "The v10 sentinel must remain available as retirement evidence."
            )
            XCTAssertEqual(
                try inspected.query(
                    "SELECT hex(raw) FROM sample WHERE id = 'stable-heart'",
                    row: { $0.text(0) }
                ).first,
                "7B226B657074223A747275657D"
            )
            XCTAssertEqual(
                try inspected.query(
                    "SELECT value FROM sample WHERE id = 'stale-value'",
                    row: { $0.real(0) }
                ).first,
                2
            )
            XCTAssertEqual(
                try inspected.query(
                    """
                    SELECT COUNT(*) FROM sample_tombstone
                    WHERE id IN ('stable-heart', ?)
                    """,
                    [.text(legacyID)],
                    row: { $0.integer(0) }
                ).first,
                0,
                "Candidate history is not proof that either identity was deleted."
            )
            inspected.close()
        }

        let store = try IngestStore(directory: directory)
        for aliasID in [legacyID, retiredID] {
            let date = String(aliasID.dropFirst("heart_rate:".count))
            let batch = try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"heart_rate","units":"bpm","data":[
                      {"id":"stable-heart","date":"\(date)",
                       "Min":62,"Avg":62,"Max":62,"source":"Watch"}
                    ]}]}}
                    """.utf8
                )
            )
            do {
                _ = try await store.ingest(
                    batch,
                    idempotencyKey: "ambiguous-replay-\(aliasID)"
                )
                XCTFail("Neither date spelling proves which legacy identity was retired.")
            } catch is UnresolvedLegacyAliasError {
                // Expected.
            }
        }
        do {
            _ = try await store.ingest(
                try BatchParser.parse(
                    Data(
                        #"{"id":"stable-heart","kind":"deletion","schemaVersion":1,"type":"HKQuantityTypeIdentifierHeartRate"}"#
                            .utf8
                    )
                ),
                idempotencyKey: "ambiguous-stable-deletion"
            )
            XCTFail("Deleting the stable ID must not guess between the candidates.")
        } catch is UnresolvedLegacyAliasError {
            // Expected.
        }
        let afterRejectedWrites = try await store.samples(type: "heart_rate")
        XCTAssertEqual(Set(afterRejectedWrites.map(\.id)), expectedIDs)
        XCTAssertEqual(afterRejectedWrites.first { $0.id == "stable-heart" }?.value, 62)

        let legacyDate = String(legacyID.dropFirst("heart_rate:".count))
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[],"deletions":[
                      {"name":"heart_rate","date":"\(legacyDate)"}
                    ]}}
                    """.utf8
                )
            ),
            idempotencyKey: "exact-legacy-deletion"
        )
        let afterLegacyDeletion = try await store.samples(type: "heart_rate")
        XCTAssertEqual(afterLegacyDeletion.map(\.id), ["stable-heart"])
        XCTAssertEqual(afterLegacyDeletion.first?.value, 62)
        await store.close()

        let reopened = try IngestStore(directory: directory)
        let final = try await reopened.samples(type: "heart_rate")
        XCTAssertEqual(final.map(\.id), ["stable-heart"])
        XCTAssertEqual(final.first?.value, 62)
        await reopened.close()
    }

    func testVersionThirteenStreamsLegacyShapesAndFourteenRepairsSetWise()
        throws
    {
        let directory = try makeReceiptDatabase(
            version: 12,
            name: "version-twelve-large-legacy-shape-set"
        )
        let databaseURL = directory.appending(path: "hozz-received.sqlite")
        let database = try SQLiteDatabase(url: databaseURL)
        defer { database.close() }
        try database.execute(
            """
            DELETE FROM sample;
            DELETE FROM batch;
            """
        )
        let insertSample = try database.prepared(
            """
            INSERT INTO sample
                (id, type, kind, start_date, end_date, value, unit,
                 source_name, raw, received_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'Watch', X'7B7D',
                    '2026-02-01T00:00:00.000Z')
            """
        )
        let insertSignature = try database.prepared(
            """
            INSERT INTO sample_alias_signature
                (stable_id, type, kind, start_time, end_time,
                 value, unit, source_name)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'Watch')
            """
        )
        defer {
            insertSample.finalize()
            insertSignature.finalize()
        }

        let count = 2_048
        let base = Date(timeIntervalSince1970: 1_767_225_600)
        let timestamp = Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        )
        for index in 0..<count {
            let startDate = base.addingTimeInterval(TimeInterval(index * 3_601))
            let start = timestamp.format(startDate)
            let isHeart = index.isMultiple(of: 2)
            let type = isHeart ? "heart_rate" : "sleep_analysis"
            let end = isHeart
                ? start
                : timestamp.format(startDate.addingTimeInterval(3_600))
            let legacyID = "\(type):\(start)"
            let stableID = "stable-\(index)"
            try insertSample.run([
                .text(legacyID),
                .text(type),
                .text("quantity"),
                .text(start),
                .text(end),
                isHeart ? .null : .real(1),
                .text(isHeart ? "bpm" : "hr")
            ])
            try insertSample.run([
                .text(stableID),
                .text(type),
                .text(isHeart ? "quantity" : "category"),
                .text(start),
                .text(end),
                .real(isHeart ? Double(60 + index % 40) : 5),
                .text(isHeart ? "bpm" : "hr")
            ])
            try insertSignature.run([
                .text(stableID),
                .text(type),
                .text(isHeart ? "quantity" : "category"),
                .text(start),
                .text(end),
                .real(isHeart ? Double(60 + index % 40) : 5),
                .text(isHeart ? "bpm" : "hr")
            ])
        }

        let statistics = try IngestStore.migrateToThirteen(
            database,
            from: 12
        )

        XCTAssertEqual(statistics.legacySamplesScanned, count)
        XCTAssertEqual(statistics.reconciliationPasses, 1)
        XCTAssertEqual(statistics.reconciliationCandidateRows, count)
        XCTAssertEqual(statistics.reconciledAliases, count)
        XCTAssertEqual(
            try database.query(
                "SELECT COUNT(*) FROM sample",
                row: { Int($0.integer(0)) }
            ).first,
            count
        )
        XCTAssertEqual(
            try database.query(
                "SELECT COUNT(*) FROM sample_identity_alias",
                row: { Int($0.integer(0)) }
            ).first,
            count
        )

        let insertTombstone = try database.prepared(
            """
            INSERT INTO sample_tombstone (id, received_at)
            VALUES (?, '2026-02-01T00:00:00.000Z')
            """
        )
        defer { insertTombstone.finalize() }
        let alternateTimestamp = Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: -18_000))
        )
        for index in 0..<count {
            let date = base.addingTimeInterval(TimeInterval(index * 3_601))
            let type = index.isMultiple(of: 2) ? "heart_rate" : "sleep_analysis"
            try insertTombstone.run([
                .text("\(type):\(alternateTimestamp.format(date))")
            ])
        }

        let repair = try IngestStore.migrateToFourteen(database, from: 13)
        XCTAssertEqual(repair.legacySamplesScanned, 0)
        XCTAssertEqual(repair.tombstonesScanned, count)
        XCTAssertEqual(repair.retirementLookups, count)
        XCTAssertEqual(repair.reconciliationPasses, 1)
        XCTAssertEqual(repair.reconciliationCandidateRows, count * 2)
        XCTAssertEqual(repair.reconciledAliases, 0)
        XCTAssertEqual(
            try database.query(
                "SELECT COUNT(*) FROM sample",
                row: { Int($0.integer(0)) }
            ).first,
            count
        )
        XCTAssertEqual(
            try database.query(
                "SELECT COUNT(*) FROM sample_identity_alias",
                row: { Int($0.integer(0)) }
            ).first,
            0
        )
        XCTAssertEqual(
            try database.query(
                "SELECT COUNT(*) FROM sample_legacy_tombstone",
                row: { Int($0.integer(0)) }
            ).first,
            count * 2
        )
        XCTAssertEqual(
            try IngestStore.migrateToFourteen(database, from: 14),
            LegacyTombstoneMigrationStatistics()
        )
    }

    func testVersionThirteenLegacyTombstonesScaleWithTombstonesNotCartesianPairs()
        throws
    {
        let directory = try makeReceiptDatabase(
            version: 12,
            name: "version-twelve-large-retirement-set"
        )
        let databaseURL = directory.appending(path: "hozz-received.sqlite")
        let database = try SQLiteDatabase(url: databaseURL)
        defer { database.close() }
        let insertRetirement = try database.prepared(
            """
            INSERT INTO sample_alias_retirement (type, start_time)
            VALUES (?, ?)
            """
        )
        let insertTombstone = try database.prepared(
            """
            INSERT INTO sample_tombstone (id, received_at)
            VALUES (?, '2026-02-01T00:00:00.000Z')
            """
        )
        defer {
            insertRetirement.finalize()
            insertTombstone.finalize()
        }

        let count = 1_024
        let base = Date(timeIntervalSince1970: 1_767_225_600)
        let timestamp = Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        )
        for offset in 0..<count {
            let start = timestamp.format(
                base.addingTimeInterval(TimeInterval(offset))
            )
            try insertRetirement.run([.text("step_count"), .text(start)])
            try insertTombstone.run([.text("step_count:\(start)")])
        }

        let statistics = try IngestStore.migrateToThirteen(
            database,
            from: 12
        )

        XCTAssertEqual(statistics.tombstonesScanned, count)
        XCTAssertEqual(
            statistics.retirementLookups,
            count,
            "Each tombstone should cause one indexed lookup, not one comparison per retirement."
        )
        XCTAssertEqual(
            try database.query(
                "SELECT COUNT(*) FROM sample_legacy_tombstone",
                row: { Int($0.integer(0)) }
            ).first,
            count
        )
        let plan = try database.query(
            """
            EXPLAIN QUERY PLAN
            SELECT 1 FROM sample_alias_retirement
            WHERE type = ? AND start_time = ?
            """,
            [.text("step_count"), .text(timestamp.format(base))],
            row: { $0.text(3) }
        )
        XCTAssertTrue(
            plan.contains { $0.contains("USING COVERING INDEX") },
            "The per-tombstone retirement lookup must use the (type, start_time) key: \(plan)"
        )
    }

    func testUpdatedLegacyHeartShapeCannotBeRelaxedIntoADifferentStableSample()
        async throws
    {
        let directory = try makeReceiptDatabase(
            version: 12,
            name: "version-twelve-updated-legacy-heart"
        )
        let databaseURL = directory.appending(path: "hozz-received.sqlite")
        let database = try SQLiteDatabase(url: databaseURL)
        try database.execute(
            """
            INSERT INTO sample
                (id, type, kind, start_date, end_date, value, unit,
                 source_name, raw, received_at)
            VALUES (
                'heart_rate:2026-01-01T10:00:00.000Z',
                'heart_rate', 'quantity',
                '2026-01-01T10:00:00.000Z',
                '2026-01-01T10:00:00.000Z',
                NULL, 'bpm', 'Watch', X'7B7D',
                '2026-01-01T12:00:00.000Z'
            );
            """
        )
        database.close()

        let upgraded = try IngestStore(directory: directory)
        _ = try await upgraded.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"heart_rate","units":"bpm","data":[
                      {"date":"2026-01-01T10:00:00.000Z",
                       "Min":63,"Avg":63,"Max":63,"source":"Watch"}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "current-no-id-heart"
        )
        _ = try await upgraded.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"heart_rate","units":"bpm","data":[
                      {"id":"stable-heart-62",
                       "date":"2026-01-01T10:00:00.000Z",
                       "Min":62,"Avg":62,"Max":62,"source":"Watch"}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "different-stable-heart"
        )

        let samples = try await upgraded.samples(type: "heart_rate")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: samples.map { ($0.id, $0.value) }),
            [
                "heart_rate:2026-01-01T10:00:00.000Z": 63,
                "stable-heart-62": 62
            ],
            "A stale migration marker must never delete the current no-ID reading."
        )
        await upgraded.close()

        let inspected = try SQLiteDatabase(url: databaseURL)
        defer { inspected.close() }
        XCTAssertEqual(
            try inspected.query(
                """
                SELECT COUNT(*) FROM sample_legacy_compatibility_shape
                WHERE legacy_id = 'heart_rate:2026-01-01T10:00:00.000Z'
                """,
                row: { $0.integer(0) }
            ).first,
            0,
            "Updating the row to the current shape must retire its one-time migration marker."
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
        XCTAssertEqual(version, 8)

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
        XCTAssertTrue(tables.contains("delivery_omission_seal"))
        XCTAssertTrue(tables.contains("canonical_record_version"))
        let destinationColumns = Set(
            try database.query("PRAGMA table_info(destination)") {
                $0.text(1)
            }
        )
        XCTAssertTrue(destinationColumns.contains("revision"))
        XCTAssertTrue(
            tables.contains("prime_state"),
            """
            The dated prime's frontier must survive a migration from an older \
            store, and must arrive as its own table: an anchor and a frontier \
            sharing a row is one careless UPDATE away from losing history.
            """
        )
    }

    func testVersionSevenMarksAdvancedLossyDestinationsForReplay() async throws {
        let directory = root.appending(path: "phone-lossy-replay")
        let store = try HozzStore(directory: directory)
        let type = HealthTypeKey("HKQuantityTypeIdentifierStepCount")
        let metrics = Destination(
            name: "Metrics with cursor",
            kind: .folder,
            format: .metrics,
            folderBookmark: Data("metrics".utf8)
        )
        let influx = Destination(
            name: "Influx with prime",
            kind: .restAPI,
            format: .influx,
            endpointURL: try XCTUnwrap(URL(string: "https://influx.example"))
        )
        let metricsWithoutState = Destination(
            name: "Unused metrics",
            kind: .folder,
            format: .metrics,
            folderBookmark: Data("unused".utf8)
        )
        let influxWithoutState = Destination(
            name: "Unused influx",
            kind: .restAPI,
            format: .influx,
            endpointURL: URL(string: "https://unused.example")
        )
        let lossless = Destination(
            name: "Lossless with cursor",
            kind: .folder,
            format: .ndjson,
            folderBookmark: Data("lossless".utf8)
        )
        let json = Destination(
            name: "JSON with prime",
            kind: .folder,
            format: .json,
            folderBookmark: Data("json".utf8)
        )
        let destinations = [
            metrics, influx, metricsWithoutState, influxWithoutState, lossless, json
        ]
        for destination in destinations {
            _ = try await store.saveDestination(
                id: destination.id,
                payload: try JSONEncoder().encode(destination),
                createdAt: destination.createdAt
            )
        }
        for destination in [metrics, lossless] {
            try await store.commit(
                [
                    PendingAnchorCommit(
                        type: type,
                        baseAnchor: nil,
                        anchor: AnchorToken(data: Data([0x01])),
                        coverage: .draining,
                        addedRecordCount: 1,
                        addedObservedCount: 1
                    )
                ],
                scope: .destination(destination.id)
            )
        }
        for destination in [influx, json] {
            _ = try await store.beginPrime(
                scope: .destination(destination.id),
                type: type,
                windowStart: Date(timeIntervalSince1970: 1),
                startedAt: Date(timeIntervalSince1970: 2),
                chunkSeconds: 60
            )
        }
        let unreadableID = UUID()
        _ = try await store.saveDestination(
            id: unreadableID,
            payload: Data("not JSON".utf8),
            createdAt: .now
        )
        await store.close()

        // Version 8 changes only data; the version-7 tables are identical.
        let database = try SQLiteDatabase(
            url: StoreLocation.databaseURL(in: directory)
        )
        try database.execute(
            """
            DELETE FROM delivery_omission_seal;
            PRAGMA user_version = 7;
            """
        )
        database.close()

        let upgraded = try HozzStore(directory: directory)
        let version = try await upgraded.schemaVersion()
        let metricsDebt = try await upgraded.deliveryOmissionFormats(for: metrics.id)
        let influxDebt = try await upgraded.deliveryOmissionFormats(for: influx.id)
        XCTAssertEqual(version, 8)
        XCTAssertEqual(metricsDebt, ["metrics"])
        XCTAssertEqual(influxDebt, ["influx"])
        for destination in [metricsWithoutState, influxWithoutState, lossless, json] {
            let formats = try await upgraded.deliveryOmissionFormats(
                for: destination.id
            )
            XCTAssertTrue(formats.isEmpty, destination.name)
        }
        let unreadableDebt = try await upgraded.deliveryOmissionFormats(
            for: unreadableID
        )
        XCTAssertTrue(unreadableDebt.isEmpty)
        let preservedCursor = try await upgraded.committedAnchor(
            scope: .destination(metrics.id),
            type: type
        )
        let preservedPrime = try await upgraded.primeRecord(
            scope: .destination(influx.id),
            type: type
        )
        XCTAssertEqual(preservedCursor, AnchorToken(data: Data([0x01])))
        XCTAssertNotNil(preservedPrime)

        let delivery = DeliveryEngine(store: upgraded, channels: [:])
        for (destination, format) in [(metrics, DeliveryFormat.ndjson), (influx, .json)] {
            let loaded = try await delivery.destination(id: destination.id)
            var broadened = try XCTUnwrap(loaded)
            broadened.format = format
            try await delivery.save(broadened)
            let stream = try await upgraded.streamRecord(
                scope: .destination(destination.id),
                type: type
            )
            let prime = try await upgraded.primeRecord(
                scope: .destination(destination.id),
                type: type
            )
            let debt = try await upgraded.deliveryOmissionFormats(for: destination.id)
            let saved = try await delivery.destination(id: destination.id)
            XCTAssertNil(stream)
            XCTAssertNil(prime)
            XCTAssertTrue(debt.isEmpty)
            XCTAssertEqual(saved?.format, format)
            XCTAssertEqual(saved?.isReplayPending, false)
        }
        let untouchedCursor = try await upgraded.committedAnchor(
            scope: .destination(lossless.id),
            type: type
        )
        let untouchedPrime = try await upgraded.primeRecord(
            scope: .destination(json.id),
            type: type
        )
        XCTAssertEqual(untouchedCursor, preservedCursor)
        XCTAssertNotNil(untouchedPrime)

        _ = try await upgraded.beginPrime(
            scope: .destination(metricsWithoutState.id),
            type: type,
            windowStart: Date(timeIntervalSince1970: 1),
            startedAt: Date(timeIntervalSince1970: 2),
            chunkSeconds: 60
        )
        await upgraded.close()
        let reopened = try HozzStore(directory: directory)
        for destination in destinations {
            let debt = try await reopened.deliveryOmissionFormats(for: destination.id)
            XCTAssertTrue(debt.isEmpty, "The historical repair must run only once.")
        }
        let newPrime = try await reopened.primeRecord(
            scope: .destination(metricsWithoutState.id),
            type: type
        )
        XCTAssertNotNil(newPrime)
        await reopened.close()
    }

    func testThePhoneStoreIsIdempotentAcrossReopens() async throws {
        let directory = root.appending(path: "phone-idempotent")

        for _ in 0..<3 {
            let store = try HozzStore(directory: directory)
            let version = try await store.schemaVersion()
            XCTAssertEqual(version, 8)
            await store.close()
        }
    }
}
