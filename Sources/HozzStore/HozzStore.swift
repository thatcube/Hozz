import Foundation
import HozzCore

public enum HozzStoreError: Error, LocalizedError, Equatable, Sendable {
    /// A caller tried to advance an anchor from a base that is no longer the
    /// committed value. Retrying work must never skip a page, so the write is
    /// rejected rather than applied.
    case staleBaseAnchor(type: String)
    case unknownRun(UUID)
    case unknownPart(runID: UUID, sequence: Int)
    case partNotOpen(runID: UUID, sequence: Int)
    case runNotResumable(UUID)
    case corruptStoredValue(String)

    public var errorDescription: String? {
        switch self {
        case .staleBaseAnchor(let type):
            "Hozz refused to advance the cursor for \(type) because it changed underneath the drain."
        case .unknownRun(let id):
            "Export run \(id.uuidString) is not in the store."
        case .unknownPart(let runID, let sequence):
            "Part \(sequence) of export run \(runID.uuidString) is not in the store."
        case .partNotOpen(let runID, let sequence):
            "Part \(sequence) of export run \(runID.uuidString) is already sealed."
        case .runNotResumable(let id):
            "Export run \(id.uuidString) has already finished."
        case .corruptStoredValue(let detail):
            "Hozz could not read a stored value: \(detail)"
        }
    }
}

/// The durable record of what Hozz has read from Health and written to disk.
///
/// The store never holds Health sample values. It holds opaque cursors, coverage
/// state, counts, and the bookkeeping needed to resume an interrupted export.
public actor HozzStore {
    let database: SQLiteDatabase
    public let directory: URL
    public let databaseURL: URL
    public let spoolDirectory: URL

    public init(directory: URL) throws {
        try StoreLocation.prepareDirectory(directory)
        self.directory = directory
        self.databaseURL = StoreLocation.databaseURL(in: directory)
        self.spoolDirectory = try StoreLocation.spoolDirectory(in: directory)
        self.database = try SQLiteDatabase(url: databaseURL)

        try database.execute(
            """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = FULL;
            PRAGMA foreign_keys = ON;
            """
        )
        try Self.migrate(database)
        try Self.hardenDatabaseFiles(at: databaseURL)
    }

    /// Opens the store in the app's private support directory.
    public static func makeDefault(container: URL? = nil) throws -> HozzStore {
        try HozzStore(directory: StoreLocation.supportDirectory(in: container))
    }

    public func close() {
        database.close()
    }

    /// Re-applies protection and backup exclusion to files SQLite may have
    /// created since the store was opened.
    public func hardenFiles() throws {
        try Self.hardenDatabaseFiles(at: databaseURL)
    }

    private static func hardenDatabaseFiles(at databaseURL: URL) throws {
        for url in StoreLocation.databaseFileURLs(for: databaseURL) {
            try StoreLocation.harden(url)
        }
    }

    // MARK: - Schema

    private static func migrate(_ database: SQLiteDatabase) throws {
        let version = try database.query("PRAGMA user_version;") { row in
            Int(row.integer(0))
        }.first ?? 0

        if version < 1 {
            try database.transaction {
                try database.execute(
                    """
                    CREATE TABLE stream_state (
                        scope TEXT NOT NULL,
                        type_key TEXT NOT NULL,
                        committed_anchor BLOB,
                        coverage_state TEXT NOT NULL,
                        record_count INTEGER NOT NULL DEFAULT 0,
                        observed_count INTEGER NOT NULL DEFAULT 0,
                        anchor_closed_at REAL,
                        failure_reason TEXT,
                        updated_at REAL NOT NULL,
                        PRIMARY KEY (scope, type_key)
                    );

                    CREATE TABLE export_run (
                        id TEXT PRIMARY KEY NOT NULL,
                        state TEXT NOT NULL,
                        format TEXT NOT NULL,
                        started_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        finished_at REAL,
                        record_count INTEGER NOT NULL DEFAULT 0,
                        attempted_type_count INTEGER NOT NULL DEFAULT 0,
                        catalog_version TEXT NOT NULL,
                        sample_encoding_error_count INTEGER NOT NULL DEFAULT 0,
                        failure_reason TEXT,
                        final_file_name TEXT
                    );

                    CREATE TABLE export_part (
                        run_id TEXT NOT NULL
                            REFERENCES export_run(id) ON DELETE CASCADE,
                        sequence INTEGER NOT NULL,
                        file_name TEXT NOT NULL,
                        state TEXT NOT NULL,
                        byte_count INTEGER NOT NULL DEFAULT 0,
                        uncompressed_byte_count INTEGER NOT NULL DEFAULT 0,
                        crc32 INTEGER NOT NULL DEFAULT 0,
                        record_count INTEGER NOT NULL DEFAULT 0,
                        created_at REAL NOT NULL,
                        sealed_at REAL,
                        PRIMARY KEY (run_id, sequence)
                    );

                    CREATE INDEX export_run_state ON export_run(state);
                    """
                )
                try database.execute("PRAGMA user_version = 1;")
            }
        }

        if version < 2 {
            try database.transaction {
                try database.execute(
                    """
                    CREATE TABLE destination (
                        id TEXT PRIMARY KEY NOT NULL,
                        payload TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    );

                    CREATE TABLE delivery_state (
                        destination_id TEXT PRIMARY KEY NOT NULL
                            REFERENCES destination(id) ON DELETE CASCADE,
                        state TEXT NOT NULL,
                        last_attempt_at REAL,
                        last_success_at REAL,
                        next_attempt_at REAL,
                        consecutive_failures INTEGER NOT NULL DEFAULT 0,
                        pending_batch_id TEXT,
                        next_sequence INTEGER NOT NULL DEFAULT 0,
                        delivered_records INTEGER NOT NULL DEFAULT 0,
                        detail TEXT
                    );

                    CREATE TABLE delivery_receipt (
                        destination_id TEXT NOT NULL
                            REFERENCES destination(id) ON DELETE CASCADE,
                        attempted_at REAL NOT NULL,
                        record_count INTEGER NOT NULL,
                        byte_count INTEGER NOT NULL,
                        state TEXT NOT NULL,
                        detail TEXT,
                        artifact_name TEXT
                    );

                    CREATE INDEX delivery_receipt_destination
                        ON delivery_receipt(destination_id, attempted_at DESC);
                    """
                )
                try database.execute("PRAGMA user_version = 2;")
            }
        }
    }

    public func schemaVersion() throws -> Int {
        try database.query("PRAGMA user_version;") { row in
            Int(row.integer(0))
        }.first ?? 0
    }

    // MARK: - Stream state

    public func streamRecord(
        scope: AnchorScope,
        type: HealthTypeKey
    ) throws -> StreamRecord? {
        try database.query(
            """
            SELECT type_key, coverage_state, committed_anchor, record_count,
                   observed_count, anchor_closed_at, failure_reason, updated_at
            FROM stream_state
            WHERE scope = ? AND type_key = ?;
            """,
            [.text(scope.rawValue), .text(type.rawValue)],
            row: Self.streamRecord
        ).first
    }

    public func streamRecords(scope: AnchorScope) throws -> [StreamRecord] {
        try database.query(
            """
            SELECT type_key, coverage_state, committed_anchor, record_count,
                   observed_count, anchor_closed_at, failure_reason, updated_at
            FROM stream_state
            WHERE scope = ?
            ORDER BY type_key;
            """,
            [.text(scope.rawValue)],
            row: Self.streamRecord
        )
    }

    public func committedAnchor(
        scope: AnchorScope,
        type: HealthTypeKey
    ) throws -> AnchorToken? {
        try streamRecord(scope: scope, type: type)?.committedAnchor
    }

    /// Applies a batch of anchor advances atomically.
    ///
    /// Either every pending commit lands or none does, so a crash midway through
    /// sealing a part can never leave one type ahead of the data on disk.
    public func commit(
        _ commits: [PendingAnchorCommit],
        scope: AnchorScope,
        at date: Date = .now
    ) throws {
        guard !commits.isEmpty else {
            return
        }

        try database.transaction {
            for commit in commits {
                try apply(commit, scope: scope, at: date)
            }
        }
    }

    /// Records coverage for a type without advancing its anchor.
    public func recordCoverage(
        scope: AnchorScope,
        type: HealthTypeKey,
        coverage: CoverageState,
        failureReason: String? = nil,
        at date: Date = .now
    ) throws {
        try database.transaction {
            try database.run(
                """
                INSERT INTO stream_state (
                    scope, type_key, committed_anchor, coverage_state,
                    record_count, observed_count, anchor_closed_at,
                    failure_reason, updated_at
                )
                VALUES (?, ?, NULL, ?, 0, 0, NULL, ?, ?)
                ON CONFLICT(scope, type_key) DO UPDATE SET
                    coverage_state = excluded.coverage_state,
                    failure_reason = excluded.failure_reason,
                    updated_at = excluded.updated_at;
                """,
                [
                    .text(scope.rawValue),
                    .text(type.rawValue),
                    .text(coverage.rawValue),
                    failureReason.map(SQLiteValue.text) ?? .null,
                    .real(date.timeIntervalSince1970)
                ]
            )
        }
    }

    private func apply(
        _ commit: PendingAnchorCommit,
        scope: AnchorScope,
        at date: Date
    ) throws {
        let existing = try streamRecord(scope: scope, type: commit.type)
        guard existing?.committedAnchor == commit.baseAnchor else {
            throw HozzStoreError.staleBaseAnchor(type: commit.type.rawValue)
        }

        try database.run(
            """
            INSERT INTO stream_state (
                scope, type_key, committed_anchor, coverage_state,
                record_count, observed_count, anchor_closed_at,
                failure_reason, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(scope, type_key) DO UPDATE SET
                committed_anchor = excluded.committed_anchor,
                coverage_state = excluded.coverage_state,
                record_count = stream_state.record_count + ?,
                observed_count = stream_state.observed_count + ?,
                anchor_closed_at = excluded.anchor_closed_at,
                failure_reason = excluded.failure_reason,
                updated_at = excluded.updated_at;
            """,
            [
                .text(scope.rawValue),
                .text(commit.type.rawValue),
                .blob(commit.anchor.data),
                .text(commit.coverage.rawValue),
                .integer(Int64(commit.addedRecordCount)),
                .integer(Int64(commit.addedObservedCount)),
                commit.anchorClosedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                commit.failureReason.map(SQLiteValue.text) ?? .null,
                .real(date.timeIntervalSince1970),
                .integer(Int64(commit.addedRecordCount)),
                .integer(Int64(commit.addedObservedCount))
            ]
        )
    }

    public func deleteStreamState(scope: AnchorScope) throws {
        try database.run(
            "DELETE FROM stream_state WHERE scope = ?;",
            [.text(scope.rawValue)]
        )
    }

    private static func streamRecord(_ row: SQLiteRow) throws -> StreamRecord {
        guard let type = HealthTypeKey(rawValue: row.text(0)) else {
            throw HozzStoreError.corruptStoredValue("empty stream type key")
        }
        guard let coverage = CoverageState(rawValue: row.text(1)) else {
            throw HozzStoreError.corruptStoredValue(
                "unknown coverage state \(row.text(1))"
            )
        }

        return StreamRecord(
            type: type,
            coverage: coverage,
            committedAnchor: row.blob(2).map(AnchorToken.init(data:)),
            recordCount: Int(row.integer(3)),
            observedCount: Int(row.integer(4)),
            anchorClosedAt: row.optionalReal(5).map(Date.init(timeIntervalSince1970:)),
            failureReason: row.optionalText(6),
            updatedAt: Date(timeIntervalSince1970: row.real(7))
        )
    }

    // MARK: - Export runs

    public func createRun(
        id: UUID = UUID(),
        format: String,
        attemptedTypeCount: Int,
        catalogVersion: String,
        at date: Date = .now
    ) throws -> ExportRunRecord {
        try database.run(
            """
            INSERT INTO export_run (
                id, state, format, started_at, updated_at, finished_at,
                record_count, attempted_type_count, catalog_version,
                sample_encoding_error_count, failure_reason, final_file_name
            )
            VALUES (?, ?, ?, ?, ?, NULL, 0, ?, ?, 0, NULL, NULL);
            """,
            [
                .text(id.uuidString.lowercased()),
                .text(ExportRunState.running.rawValue),
                .text(format),
                .real(date.timeIntervalSince1970),
                .real(date.timeIntervalSince1970),
                .integer(Int64(attemptedTypeCount)),
                .text(catalogVersion)
            ]
        )
        guard let record = try run(id: id) else {
            throw HozzStoreError.unknownRun(id)
        }
        return record
    }

    public func run(id: UUID) throws -> ExportRunRecord? {
        try database.query(
            """
            SELECT id, state, format, started_at, updated_at, finished_at,
                   record_count, attempted_type_count, catalog_version,
                   sample_encoding_error_count, failure_reason, final_file_name
            FROM export_run WHERE id = ?;
            """,
            [.text(id.uuidString.lowercased())],
            row: Self.runRecord
        ).first
    }

    public func allRuns() throws -> [ExportRunRecord] {
        try database.query(
            """
            SELECT id, state, format, started_at, updated_at, finished_at,
                   record_count, attempted_type_count, catalog_version,
                   sample_encoding_error_count, failure_reason, final_file_name
            FROM export_run ORDER BY started_at DESC;
            """,
            row: Self.runRecord
        )
    }

    /// The most recent run that stopped at a checkpoint and can still resume.
    public func resumableRun() throws -> ExportRunRecord? {
        try database.query(
            """
            SELECT id, state, format, started_at, updated_at, finished_at,
                   record_count, attempted_type_count, catalog_version,
                   sample_encoding_error_count, failure_reason, final_file_name
            FROM export_run
            WHERE state IN (?, ?)
            ORDER BY started_at DESC
            LIMIT 1;
            """,
            [
                .text(ExportRunState.running.rawValue),
                .text(ExportRunState.paused.rawValue)
            ],
            row: Self.runRecord
        ).first
    }

    public func updateRun(
        id: UUID,
        state: ExportRunState,
        recordCount: Int? = nil,
        failureReason: String? = nil,
        finalFileName: String? = nil,
        finishedAt: Date? = nil,
        at date: Date = .now
    ) throws {
        try database.run(
            """
            UPDATE export_run SET
                state = ?,
                record_count = COALESCE(?, record_count),
                failure_reason = COALESCE(?, failure_reason),
                final_file_name = COALESCE(?, final_file_name),
                finished_at = COALESCE(?, finished_at),
                updated_at = ?
            WHERE id = ?;
            """,
            [
                .text(state.rawValue),
                recordCount.map { .integer(Int64($0)) } ?? .null,
                failureReason.map(SQLiteValue.text) ?? .null,
                finalFileName.map(SQLiteValue.text) ?? .null,
                finishedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .real(date.timeIntervalSince1970),
                .text(id.uuidString.lowercased())
            ]
        )
        guard database.changeCount > 0 else {
            throw HozzStoreError.unknownRun(id)
        }
    }

    public func deleteRun(id: UUID) throws {
        try database.transaction {
            try database.run(
                "DELETE FROM export_run WHERE id = ?;",
                [.text(id.uuidString.lowercased())]
            )
            try database.run(
                "DELETE FROM stream_state WHERE scope = ?;",
                [.text(AnchorScope.run(id).rawValue)]
            )
        }
    }

    /// Accumulates the number of samples whose canonical encoding failed.
    ///
    /// The count has to be durable: a resumed export would otherwise report
    /// zero encoding errors even though earlier, already-sealed parts contain
    /// explicit error records.
    public func addEncodingErrors(
        runID: UUID,
        count: Int,
        at date: Date = .now
    ) throws {
        guard count > 0 else {
            return
        }
        try database.run(
            """
            UPDATE export_run SET
                sample_encoding_error_count = sample_encoding_error_count + ?,
                updated_at = ?
            WHERE id = ?;
            """,
            [
                .integer(Int64(count)),
                .real(date.timeIntervalSince1970),
                .text(runID.uuidString.lowercased())
            ]
        )
        guard database.changeCount > 0 else {
            throw HozzStoreError.unknownRun(runID)
        }
    }

    private static func runRecord(_ row: SQLiteRow) throws -> ExportRunRecord {
        guard let id = UUID(uuidString: row.text(0)) else {
            throw HozzStoreError.corruptStoredValue("run identifier \(row.text(0))")
        }
        guard let state = ExportRunState(rawValue: row.text(1)) else {
            throw HozzStoreError.corruptStoredValue("run state \(row.text(1))")
        }

        return ExportRunRecord(
            id: id,
            state: state,
            format: row.text(2),
            startedAt: Date(timeIntervalSince1970: row.real(3)),
            updatedAt: Date(timeIntervalSince1970: row.real(4)),
            finishedAt: row.optionalReal(5).map(Date.init(timeIntervalSince1970:)),
            recordCount: Int(row.integer(6)),
            attemptedTypeCount: Int(row.integer(7)),
            catalogVersion: row.text(8),
            sampleEncodingErrorCount: Int(row.integer(9)),
            failureReason: row.optionalText(10),
            finalFileName: row.optionalText(11)
        )
    }

    // MARK: - Export parts

    public func createPart(
        runID: UUID,
        sequence: Int,
        fileName: String,
        at date: Date = .now
    ) throws -> ExportPartRecord {
        guard let run = try run(id: runID) else {
            throw HozzStoreError.unknownRun(runID)
        }
        guard run.state.isResumable else {
            throw HozzStoreError.runNotResumable(runID)
        }

        try database.run(
            """
            INSERT INTO export_part (
                run_id, sequence, file_name, state, byte_count,
                uncompressed_byte_count, crc32, record_count,
                created_at, sealed_at
            )
            VALUES (?, ?, ?, ?, 0, 0, 0, 0, ?, NULL);
            """,
            [
                .text(runID.uuidString.lowercased()),
                .integer(Int64(sequence)),
                .text(fileName),
                .text(ExportPartState.open.rawValue),
                .real(date.timeIntervalSince1970)
            ]
        )
        guard let part = try self.part(runID: runID, sequence: sequence) else {
            throw HozzStoreError.unknownPart(runID: runID, sequence: sequence)
        }
        return part
    }

    public func part(runID: UUID, sequence: Int) throws -> ExportPartRecord? {
        try database.query(
            """
            SELECT run_id, sequence, file_name, state, byte_count,
                   uncompressed_byte_count, crc32, record_count,
                   created_at, sealed_at
            FROM export_part WHERE run_id = ? AND sequence = ?;
            """,
            [.text(runID.uuidString.lowercased()), .integer(Int64(sequence))],
            row: Self.partRecord
        ).first
    }

    /// The spool file names a run owns, without decoding anything else.
    ///
    /// Deleting a run's files never needs to know whether a part was sealed,
    /// and asking would make discarding impossible in exactly the case where
    /// discarding is the only way out — a run whose part state this build
    /// cannot read. The escape hatch must not depend on the thing that is
    /// broken.
    public func partFileNames(runID: UUID) throws -> [String] {
        try database.query(
            """
            SELECT file_name FROM export_part WHERE run_id = ? ORDER BY sequence;
            """,
            [.text(runID.uuidString.lowercased())]
        ) { row in
            row.text(0)
        }
    }

    /// Part states stored for a run that this build does not recognise.
    ///
    /// A part's state is what says whether its bytes are durable, so a state
    /// this build cannot read leaves the run genuinely undecidable rather than
    /// merely awkward: treating the part as sealed could ship a half-written
    /// one, and treating it as open could delete bytes an anchor has already
    /// advanced past. Neither is recoverable, so the run cannot be continued —
    /// and the point of asking separately is to find that out *before*
    /// offering to continue it.
    ///
    /// Reads the raw strings rather than decoding, which is the only way to
    /// ask the question without hitting the failure being detected.
    public func unrecognisedPartStates(runID: UUID) throws -> [String] {
        try database.query(
            """
            SELECT DISTINCT state FROM export_part WHERE run_id = ?;
            """,
            [.text(runID.uuidString.lowercased())]
        ) { row in
            row.text(0)
        }
        .filter { ExportPartState(rawValue: $0) == nil }
        .sorted()
    }

    public func parts(runID: UUID) throws -> [ExportPartRecord] {
        try database.query(
            """
            SELECT run_id, sequence, file_name, state, byte_count,
                   uncompressed_byte_count, crc32, record_count,
                   created_at, sealed_at
            FROM export_part WHERE run_id = ? ORDER BY sequence;
            """,
            [.text(runID.uuidString.lowercased())],
            row: Self.partRecord
        )
    }

    /// Seals a part and commits every anchor it made durable, atomically.
    ///
    /// This is the only path that may advance a committed anchor. If the
    /// transaction fails, the part stays open and the anchors stay where they
    /// were, so the next attempt replays the same work instead of skipping it.
    public func sealPart(
        runID: UUID,
        sequence: Int,
        byteCount: UInt64,
        uncompressedByteCount: UInt64,
        crc32: UInt32,
        recordCount: Int,
        commits: [PendingAnchorCommit],
        runRecordCount: Int,
        at date: Date = .now
    ) throws {
        try database.transaction {
            guard let part = try part(runID: runID, sequence: sequence) else {
                throw HozzStoreError.unknownPart(runID: runID, sequence: sequence)
            }
            guard part.state == .open else {
                throw HozzStoreError.partNotOpen(runID: runID, sequence: sequence)
            }

            try database.run(
                """
                UPDATE export_part SET
                    state = ?, byte_count = ?, uncompressed_byte_count = ?,
                    crc32 = ?, record_count = ?, sealed_at = ?
                WHERE run_id = ? AND sequence = ?;
                """,
                [
                    .text(ExportPartState.sealed.rawValue),
                    .integer(Int64(bitPattern: byteCount)),
                    .integer(Int64(bitPattern: uncompressedByteCount)),
                    .integer(Int64(crc32)),
                    .integer(Int64(recordCount)),
                    .real(date.timeIntervalSince1970),
                    .text(runID.uuidString.lowercased()),
                    .integer(Int64(sequence))
                ]
            )

            for commit in commits {
                try apply(commit, scope: .run(runID), at: date)
            }

            try database.run(
                "UPDATE export_run SET record_count = ?, updated_at = ? WHERE id = ?;",
                [
                    .integer(Int64(runRecordCount)),
                    .real(date.timeIntervalSince1970),
                    .text(runID.uuidString.lowercased())
                ]
            )
        }
    }

    /// Forgets an unsealed part. Its bytes are not durable, so its anchors were
    /// never committed and the work simply replays.
    public func discardOpenParts(runID: UUID) throws -> [ExportPartRecord] {
        let open = try database.query(
            """
            SELECT run_id, sequence, file_name, state, byte_count,
                   uncompressed_byte_count, crc32, record_count,
                   created_at, sealed_at
            FROM export_part WHERE run_id = ? AND state = ?;
            """,
            [
                .text(runID.uuidString.lowercased()),
                .text(ExportPartState.open.rawValue)
            ],
            row: Self.partRecord
        )
        guard !open.isEmpty else {
            return []
        }

        try database.run(
            "DELETE FROM export_part WHERE run_id = ? AND state = ?;",
            [
                .text(runID.uuidString.lowercased()),
                .text(ExportPartState.open.rawValue)
            ]
        )
        return open
    }

    /// Replaces a run's part list with the single joined artifact and marks the
    /// run finished, in one transaction.
    ///
    /// These have to happen together. If the artifact could be recorded while
    /// the run stayed resumable, a resume would append a new part to a run
    /// whose earlier parts had already been absorbed and deleted.
    public func completeRun(
        runID: UUID,
        fileName: String,
        byteCount: UInt64,
        recordCount: Int,
        at date: Date = .now
    ) throws {
        try database.transaction {
            try database.run(
                "DELETE FROM export_part WHERE run_id = ?;",
                [.text(runID.uuidString.lowercased())]
            )
            try database.run(
                """
                INSERT INTO export_part (
                    run_id, sequence, file_name, state, byte_count,
                    uncompressed_byte_count, crc32, record_count,
                    created_at, sealed_at
                )
                VALUES (?, 0, ?, ?, ?, 0, 0, ?, ?, ?);
                """,
                [
                    .text(runID.uuidString.lowercased()),
                    .text(fileName),
                    .text(ExportPartState.sealed.rawValue),
                    .integer(Int64(bitPattern: byteCount)),
                    .integer(Int64(recordCount)),
                    .real(date.timeIntervalSince1970),
                    .real(date.timeIntervalSince1970)
                ]
            )
            try database.run(
                """
                UPDATE export_run SET
                    state = ?, final_file_name = ?, record_count = ?,
                    finished_at = ?, updated_at = ?
                WHERE id = ?;
                """,
                [
                    .text(ExportRunState.completed.rawValue),
                    .text(fileName),
                    .integer(Int64(recordCount)),
                    .real(date.timeIntervalSince1970),
                    .real(date.timeIntervalSince1970),
                    .text(runID.uuidString.lowercased())
                ]
            )
            guard database.changeCount > 0 else {
                throw HozzStoreError.unknownRun(runID)
            }
        }
    }

    /// The set of spool file names any run still depends on.
    public func referencedFileNames() throws -> Set<String> {
        let names = try database.query(
            "SELECT file_name FROM export_part;"
        ) { row in
            row.text(0)
        }
        let finals = try database.query(
            "SELECT final_file_name FROM export_run WHERE final_file_name IS NOT NULL;"
        ) { row in
            row.text(0)
        }
        return Set(names).union(finals)
    }

    private static func partRecord(_ row: SQLiteRow) throws -> ExportPartRecord {
        guard let runID = UUID(uuidString: row.text(0)) else {
            throw HozzStoreError.corruptStoredValue("part run identifier \(row.text(0))")
        }
        guard let state = ExportPartState(rawValue: row.text(3)) else {
            throw HozzStoreError.corruptStoredValue("part state \(row.text(3))")
        }

        return ExportPartRecord(
            runID: runID,
            sequence: Int(row.integer(1)),
            fileName: row.text(2),
            state: state,
            byteCount: UInt64(bitPattern: row.integer(4)),
            uncompressedByteCount: UInt64(bitPattern: row.integer(5)),
            crc32: UInt32(truncatingIfNeeded: row.integer(6)),
            recordCount: Int(row.integer(7)),
            createdAt: Date(timeIntervalSince1970: row.real(8)),
            sealedAt: row.optionalReal(9).map(Date.init(timeIntervalSince1970:))
        )
    }
}
