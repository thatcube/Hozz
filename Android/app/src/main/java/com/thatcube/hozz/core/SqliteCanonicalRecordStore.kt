package com.thatcube.hozz.core

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import com.thatcube.hozz.projection.ProjectionAction
import com.thatcube.hozz.projection.ProjectionPlanner
import com.thatcube.hozz.projection.ProjectionQuality
import com.thatcube.hozz.projection.ProjectionSummary
import com.thatcube.hozz.projection.targetRecord
import java.time.Instant
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class SqliteCanonicalRecordStore(
    context: Context,
    databaseName: String = "hozz-archive.sqlite",
) :
    SQLiteOpenHelper(context, databaseName, null, 13),
    CanonicalRecordStore {

    internal var parentStateLookupCountForTesting = 0L
        private set
    internal var recordMaterializationCountForTesting = 0L
        private set

    override fun onCreate(database: SQLiteDatabase) {
        database.execSQL(
            """
            CREATE TABLE canonical_record (
                canonical_id TEXT PRIMARY KEY,
                parent_canonical_id TEXT,
                resolution_canonical_id TEXT,
                record_version INTEGER NOT NULL,
                kind TEXT NOT NULL,
                canonical_type TEXT NOT NULL,
                type TEXT NOT NULL,
                start_time TEXT,
                end_time TEXT,
                canonical_value REAL,
                canonical_unit TEXT,
                canonical_description TEXT,
                original_value REAL,
                original_unit TEXT,
                original_description TEXT,
                category_value INTEGER,
                activity_type INTEGER,
                quantity_count INTEGER,
                source_record_id TEXT NOT NULL,
                source_record_version INTEGER,
                source_store TEXT NOT NULL,
                source_bundle_identifier TEXT,
                source_name TEXT,
                timeline_sort_key TEXT,
                device_json TEXT,
                metadata_json TEXT,
                lineage_json TEXT NOT NULL,
                tombstone INTEGER NOT NULL,
                raw_json TEXT NOT NULL
            )
            """.trimIndent(),
        )
        createRunRecordTables(database)
        createHealthConnectProjectionTable(database)
        createHealthConnectPendingTable(database)
        createHealthConnectOperationStateTable(database)
        createProjectionFactTables(database)
        database.execSQL(
            """
            CREATE INDEX canonical_record_timeline
            ON canonical_record (
                tombstone,
                timeline_sort_key DESC,
                canonical_id ASC
            )
            """.trimIndent(),
        )
        database.execSQL(
            """
            CREATE INDEX canonical_record_parent
            ON canonical_record (parent_canonical_id)
            """.trimIndent(),
        )
    }

    override fun onUpgrade(
        database: SQLiteDatabase,
        oldVersion: Int,
        newVersion: Int,
    ) {
        if (oldVersion < 2) {
            database.execSQL(
                """
                ALTER TABLE canonical_record
                ADD COLUMN canonical_type TEXT NOT NULL DEFAULT 'archive.raw'
                """.trimIndent(),
            )
            for ((type, mapping) in com.thatcube.hozz.generated.GeneratedContract.recordMappings) {
                database.execSQL(
                    "UPDATE canonical_record SET canonical_type = ? WHERE type = ?",
                    arrayOf(mapping.canonicalType, type),
                )
            }
            for ((kind, canonicalType) in
                com.thatcube.hozz.generated.GeneratedContract.archiveOnlyCanonicalTypes) {
                database.execSQL(
                    """
                    UPDATE canonical_record
                    SET canonical_type = ?
                    WHERE kind = ? AND canonical_type = 'archive.raw'
                    """.trimIndent(),
                    arrayOf(canonicalType, kind),
                )
            }
        }

        if (oldVersion < 3) {
            database.execSQL(
                """
                ALTER TABLE canonical_record
                ADD COLUMN source_record_version INTEGER
                """.trimIndent(),
            )
        }
        if (oldVersion < 4) {
            createStageTable(database)
        }
        if (oldVersion < 5) {
            database.execSQL(
                "ALTER TABLE canonical_record ADD COLUMN parent_canonical_id TEXT",
            )
            database.execSQL(
                """
                CREATE INDEX IF NOT EXISTS canonical_record_parent
                ON canonical_record (parent_canonical_id)
                """.trimIndent(),
            )
            if (oldVersion >= 4) {
                database.execSQL(
                    """
                    ALTER TABLE canonical_record_stage
                    ADD COLUMN parent_canonical_id TEXT
                    """.trimIndent(),
                )
            }
        }
        if (oldVersion < 6) {
            createRunRecordTables(database)
        }
        if (oldVersion < 7) {
            createHealthConnectProjectionTable(database)
        }
        if (oldVersion < 8) {
            createRunRecordTables(database)
            createHealthConnectProjectionTable(database)
        }
        if (oldVersion < 9) {
            if (!hasColumn(database, "canonical_record", "resolution_canonical_id")) {
                database.execSQL(
                    "ALTER TABLE canonical_record ADD COLUMN resolution_canonical_id TEXT",
                )
            }
            if (
                hasTable(database, "canonical_record_stage") &&
                !hasColumn(
                    database,
                    "canonical_record_stage",
                    "resolution_canonical_id",
                )
            ) {
                database.execSQL(
                    "ALTER TABLE canonical_record_stage " +
                        "ADD COLUMN resolution_canonical_id TEXT",
                )
            }
            restoreContinuationErrors(database)
        }
        if (oldVersion < 10) {
            database.execSQL("DROP TABLE IF EXISTS main.canonical_record_stage")
            database.execSQL("DROP TABLE IF EXISTS main.archive_run_record_stage")
        }
        if (oldVersion < 11) {
            if (!hasColumn(database, "canonical_record", "timeline_sort_key")) {
                database.execSQL(
                    "ALTER TABLE canonical_record ADD COLUMN timeline_sort_key TEXT",
                )
            }
            backfillTimelineSortKeys(database)
            database.execSQL("DROP INDEX IF EXISTS canonical_record_timeline")
            database.execSQL(
                """
                CREATE INDEX canonical_record_timeline
                ON canonical_record (
                    tombstone,
                    timeline_sort_key DESC,
                    canonical_id ASC
                )
                """.trimIndent(),
            )
            createHealthConnectPendingTable(database)
        }
        if (oldVersion < 12) {
            createHealthConnectOperationStateTable(database)
        }
        reconcileEncodingFailures(database)
        if (oldVersion < 13) {
            createProjectionFactTables(database)
            refreshAllProjectionFacts(database)
        }
    }

    override fun onOpen(database: SQLiteDatabase) {
        super.onOpen(database)
        createTemporaryStageTables(database)
    }

    override fun close() {
        super<SQLiteOpenHelper>.close()
    }

    override suspend fun upsert(records: List<CanonicalRecord>): MergeResult {
        val database = writableDatabase
        database.beginTransaction()
        try {
            val result = mergeIntoCanonical(database, records)
            database.setTransactionSuccessful()
            return result
        } finally {
            database.endTransaction()
        }
    }

    override suspend fun beginImport(): CanonicalImportSession {
        val database = writableDatabase
        val sessionId = UUID.randomUUID().toString()
        return object : CanonicalImportSession {
            private var finished = false
            private val mutex = Mutex()
            private var expectedCanonicalCount = 0L
            private var expectedRunCount = 0L

            override suspend fun append(records: List<CanonicalRecord>) =
                mutex.withLock {
                    check(!finished)
                    database.beginTransaction()
                    try {
                        for (record in records) {
                            val stagedVersion = existingVersion(
                                database = database,
                                table = "canonical_record_stage",
                                canonicalId = record.canonicalId,
                                sessionId = sessionId,
                            )
                            if (stagedVersion == null) {
                                database.insertOrThrow(
                                    "canonical_record_stage",
                                    null,
                                    stageValues(sessionId, record),
                                )
                            } else if (record.recordVersion > stagedVersion) {
                                database.update(
                                    "canonical_record_stage",
                                    stageValues(sessionId, record),
                                    "session_id = ? AND canonical_id = ?",
                                    arrayOf(sessionId, record.canonicalId),
                                )
                            }
                        }
                        expectedCanonicalCount = stageCount(
                            database,
                            "canonical_record_stage",
                            sessionId,
                        )
                        database.setTransactionSuccessful()
                    } finally {
                        database.endTransaction()
                    }
                }

            override suspend fun appendRunRecords(
                records: List<ArchiveRunRecord>,
            ) = mutex.withLock {
                check(!finished)
                database.beginTransaction()
                try {
                    for (record in records) {
                        database.insertWithOnConflict(
                            "archive_run_record_stage",
                            null,
                            runStageValues(sessionId, record),
                            SQLiteDatabase.CONFLICT_REPLACE,
                        )
                    }
                    expectedRunCount = stageCount(
                        database,
                        "archive_run_record_stage",
                        sessionId,
                    )
                    database.setTransactionSuccessful()
                } finally {
                    database.endTransaction()
                }
            }

            override suspend fun commit(): MergeResult = mutex.withLock {
                check(!finished)
                database.beginTransaction()
                val result = try {
                    verifyStageCount(
                        database,
                        "canonical_record_stage",
                        sessionId,
                        expectedCanonicalCount,
                    )
                    verifyStageCount(
                        database,
                        "archive_run_record_stage",
                        sessionId,
                        expectedRunCount,
                    )
                    var result = MergeResult()
                    materializeStagedParentGraph(database, sessionId)
                    var mergedCount = 0L
                    val blockedIncomingSubtrees = hashSetOf<String>()
                    database.query(
                        "canonical_record_stage",
                        null,
                        "session_id = ?",
                        arrayOf(sessionId),
                        null,
                        null,
                        "merge_depth, canonical_id",
                    ).use { cursor ->
                        while (cursor.moveToNext()) {
                            result += mergeOne(
                                database,
                                cursor.record(),
                                blockedIncomingSubtrees,
                            )
                            mergedCount += 1
                        }
                    }
                    if (mergedCount != expectedCanonicalCount) {
                        throw ArchiveFormatException(
                            "Canonical records contain a parent cycle.",
                        )
                    }
                    validateStagedAppliedParentGraph(database, sessionId)
                    restoreUnresolvedContinuationErrors(database)
                    reconcileEncodingFailures(database)
                    refreshProjectionFacts(
                        database,
                        stagedCanonicalIds(database, sessionId),
                    )
                    database.execSQL(
                        """
                        INSERT OR IGNORE INTO archive_run_record
                            (fingerprint, occurrence, kind, raw_json)
                        SELECT fingerprint, occurrence, kind, raw_json
                        FROM archive_run_record_stage
                        WHERE session_id = ?
                        ORDER BY ordinal
                        """.trimIndent(),
                        arrayOf(sessionId),
                    )
                    database.delete(
                        "canonical_record_stage",
                        "session_id = ?",
                        arrayOf(sessionId),
                    )
                    database.delete(
                        "archive_run_record_stage",
                        "session_id = ?",
                        arrayOf(sessionId),
                    )
                    database.delete(
                        "canonical_parent_winner_graph",
                        null,
                        null,
                    )
                    database.delete(
                        "canonical_parent_graph_seed",
                        null,
                        null,
                    )
                    database.setTransactionSuccessful()
                    result
                } finally {
                    database.endTransaction()
                }
                finished = true
                result
            }

            override suspend fun discard() = mutex.withLock {
                if (finished) return@withLock
                database.beginTransaction()
                try {
                    database.delete(
                        "canonical_record_stage",
                        "session_id = ?",
                        arrayOf(sessionId),
                    )
                    database.delete(
                        "archive_run_record_stage",
                        "session_id = ?",
                        arrayOf(sessionId),
                    )
                    database.setTransactionSuccessful()
                } finally {
                    database.endTransaction()
                }
                finished = true
            }
        }
    }

    override suspend fun timelinePage(
        after: TimelineCursor?,
        limit: Int,
    ): TimelinePage {
        val time = after?.sortTime?.let(::timelineSortKey)
        val selection = when {
            after == null -> "tombstone = 0"
            time == null ->
                "tombstone = 0 AND timeline_sort_key IS NULL " +
                    "AND canonical_id > ?"
            else ->
                "tombstone = 0 AND (" +
                    "timeline_sort_key < ? OR " +
                    "(timeline_sort_key = ? AND canonical_id > ?) OR " +
                    "timeline_sort_key IS NULL)"
        }
        val arguments = when {
            after == null -> null
            time == null -> arrayOf(after.canonicalId)
            else -> arrayOf(time, time, after.canonicalId)
        }
        val records = readableDatabase.query(
            "canonical_record",
            null,
            selection,
            arguments,
            null,
            null,
            "timeline_sort_key DESC, canonical_id",
            limit.coerceIn(1, 1_000).toString(),
        ).use { cursor ->
            buildList {
                var pageBytes = 0
                while (cursor.moveToNext()) {
                    val record = cursor.record()
                    val bytes = record.rawJson.toByteArray().size
                    if (isNotEmpty() && pageBytes + bytes > PAGE_RAW_BYTES) {
                        break
                    }
                    add(record)
                    pageBytes += bytes
                }
            }
        }
        return TimelinePage(
            records = records,
            nextCursor = records.lastOrNull()?.let {
                TimelineCursor(it.endTime ?: it.startTime, it.canonicalId)
            },
        )
    }

    override suspend fun timelinePageBefore(
        before: TimelineCursor,
        limit: Int,
    ): TimelinePage {
        val time = before.sortTime?.let(::timelineSortKey)
        val selection = if (time == null) {
            "tombstone = 0 AND (" +
                "timeline_sort_key IS NOT NULL OR " +
                "(timeline_sort_key IS NULL AND canonical_id < ?))"
        } else {
            "tombstone = 0 AND timeline_sort_key IS NOT NULL AND (" +
                "timeline_sort_key > ? OR " +
                "(timeline_sort_key = ? AND canonical_id < ?))"
        }
        val arguments = if (time == null) {
            arrayOf(before.canonicalId)
        } else {
            arrayOf(time, time, before.canonicalId)
        }
        val records = readableDatabase.query(
            "canonical_record",
            null,
            selection,
            arguments,
            null,
            null,
            "timeline_sort_key ASC, canonical_id DESC",
            limit.coerceIn(1, 1_000).toString(),
        ).use { cursor ->
            buildList {
                var pageBytes = 0
                while (cursor.moveToNext()) {
                    val record = cursor.record()
                    val bytes = record.rawJson.toByteArray().size
                    if (isNotEmpty() && pageBytes + bytes > PAGE_RAW_BYTES) {
                        break
                    }
                    add(record)
                    pageBytes += bytes
                }
            }.asReversed()
        }
        return TimelinePage(
            records = records,
            previousCursor = records.firstOrNull()?.let {
                TimelineCursor(it.endTime ?: it.startTime, it.canonicalId)
            },
            nextCursor = null,
        )
    }

    internal fun timelineQueryPlan(after: TimelineCursor?): List<String> {
        val time = after?.sortTime?.let(::timelineSortKey)
        val sql: String
        val arguments: Array<String>
        if (after == null) {
            sql = """
                EXPLAIN QUERY PLAN
                SELECT canonical_id FROM canonical_record
                WHERE tombstone = 0
                ORDER BY timeline_sort_key DESC, canonical_id
                LIMIT 200
            """.trimIndent()
            arguments = emptyArray()
        } else if (time == null) {
            sql = """
                EXPLAIN QUERY PLAN
                SELECT canonical_id FROM canonical_record
                WHERE tombstone = 0 AND timeline_sort_key IS NULL
                  AND canonical_id > ?
                ORDER BY timeline_sort_key DESC, canonical_id
                LIMIT 200
            """.trimIndent()
            arguments = arrayOf(after.canonicalId)
        } else {
            sql = """
                EXPLAIN QUERY PLAN
                SELECT canonical_id FROM canonical_record
                WHERE tombstone = 0 AND (
                  timeline_sort_key < ? OR
                  (timeline_sort_key = ? AND canonical_id > ?) OR
                  timeline_sort_key IS NULL
                )
                ORDER BY timeline_sort_key DESC, canonical_id
                LIMIT 200
            """.trimIndent()
            arguments = arrayOf(time, time, after.canonicalId)
        }
        return readableDatabase.rawQuery(sql, arguments).use { cursor ->
            buildList {
                while (cursor.moveToNext()) add(cursor.getString(3))
            }
        }
    }

    override suspend fun recordsPage(
        afterCanonicalId: String?,
        limit: Int,
    ): List<CanonicalRecord> = recordsPage(
        readableDatabase,
        afterCanonicalId,
        limit,
    )

    private fun recordsPage(
        database: SQLiteDatabase,
        afterCanonicalId: String?,
        limit: Int,
    ): List<CanonicalRecord> =
        database.query(
            "canonical_record",
            null,
            afterCanonicalId?.let { "canonical_id > ?" },
            afterCanonicalId?.let(::arrayOf),
            null,
            null,
            "canonical_id",
            limit.coerceIn(1, 1_000).toString(),
        ).use { cursor ->
            buildList {
                var pageBytes = 0
                while (cursor.moveToNext()) {
                    val record = cursor.record()
                    val bytes = record.rawJson.toByteArray().size
                    if (isNotEmpty() && pageBytes + bytes > PAGE_RAW_BYTES) {
                        break
                    }
                    add(record)
                    pageBytes += bytes
                }
            }
        }

    override suspend fun recordCount(): Int =
        readableDatabase.rawQuery(
            "SELECT COUNT(*) FROM canonical_record",
            null,
        ).use { cursor ->
            if (cursor.moveToFirst()) cursor.getInt(0) else 0
        }

    override suspend fun archiveOverview(): ArchiveOverview {
        val database = readableDatabase
        database.beginTransaction()
        return try {
            val counts = database.rawQuery(
                """
                SELECT
                    (SELECT COUNT(*) FROM canonical_record),
                    (SELECT COUNT(*) FROM archive_run_record)
                """.trimIndent(),
                null,
            ).use { cursor ->
                check(cursor.moveToFirst())
                cursor.getInt(0) to cursor.getInt(1)
            }
            var exactCount = 0
            var lossyCount = 0
            var archiveOnlyCount = 0
            var insertCount = 0
            var updateCount = 0
            var deleteCount = 0
            val targetRecords = linkedSetOf<String>()
            database.rawQuery(
                """
                WITH projection_state AS (
                    SELECT
                        canonical.tombstone,
                        canonical.record_version,
                        fact.quality AS base_quality,
                        fact.target_record AS base_target,
                        ledger.target_record AS ledger_target,
                        ledger.canonical_version AS ledger_version,
                        pending.target_record AS pending_target,
                        pending.action AS pending_action,
                        CASE
                            WHEN ledger.canonical_id IS NOT NULL
                              OR pending.canonical_id IS NOT NULL
                            THEN 1
                            ELSE 0
                        END AS has_projection_state
                    FROM canonical_record AS canonical
                    JOIN canonical_projection_fact AS fact
                      ON fact.canonical_id = canonical.canonical_id
                    LEFT JOIN health_connect_projection AS ledger
                      ON ledger.canonical_id = canonical.canonical_id
                    LEFT JOIN health_connect_pending_operation AS pending
                      ON pending.canonical_id = canonical.canonical_id
                ),
                effective AS (
                    SELECT
                        CASE
                            WHEN tombstone = 1 AND has_projection_state = 1
                                THEN 'DELETE'
                            ELSE base_quality
                        END AS quality,
                        CASE
                            WHEN tombstone = 1 OR base_target IS NULL
                                THEN CASE
                                    WHEN has_projection_state = 1 THEN 'DELETE'
                                    ELSE 'NONE'
                                END
                            WHEN ledger_target IS NULL
                                THEN CASE
                                    WHEN pending_action = 'UPSERT' THEN 'UPDATE'
                                    ELSE 'INSERT'
                                END
                            WHEN ledger_version >= record_version
                              AND pending_target IS NULL
                                THEN 'NONE'
                            ELSE 'UPDATE'
                        END AS action,
                        base_target,
                        ledger_target,
                        pending_target
                    FROM projection_state
                )
                SELECT
                    quality,
                    action,
                    CASE
                        WHEN action = 'DELETE'
                            THEN COALESCE(ledger_target, pending_target)
                        WHEN action IN ('INSERT', 'UPDATE')
                            THEN base_target
                        ELSE NULL
                    END AS target_record,
                    COUNT(*)
                FROM effective
                GROUP BY quality, action, target_record
                """.trimIndent(),
                null,
            ).use { cursor ->
                while (cursor.moveToNext()) {
                    val count = cursor.getInt(3)
                    when (ProjectionQuality.valueOf(cursor.getString(0))) {
                        ProjectionQuality.EXACT -> exactCount += count
                        ProjectionQuality.LOSSY -> lossyCount += count
                        ProjectionQuality.ARCHIVE_ONLY -> archiveOnlyCount += count
                        ProjectionQuality.DELETE -> Unit
                    }
                    when (ProjectionAction.valueOf(cursor.getString(1))) {
                        ProjectionAction.INSERT -> insertCount += count
                        ProjectionAction.UPDATE -> updateCount += count
                        ProjectionAction.DELETE -> deleteCount += count
                        ProjectionAction.NONE -> Unit
                    }
                    if (!cursor.isNull(2)) {
                        targetRecords += cursor.getString(2)
                    }
                }
            }
            val warningCounts = linkedMapOf<String, Int>()
            database.rawQuery(
                """
                SELECT warning.code, COUNT(*)
                FROM canonical_projection_warning AS warning
                JOIN canonical_record AS canonical
                  ON canonical.canonical_id = warning.canonical_id
                LEFT JOIN health_connect_projection AS ledger
                  ON ledger.canonical_id = canonical.canonical_id
                LEFT JOIN health_connect_pending_operation AS pending
                  ON pending.canonical_id = canonical.canonical_id
                WHERE canonical.tombstone = 0
                   OR (
                       ledger.canonical_id IS NULL
                       AND pending.canonical_id IS NULL
                   )
                GROUP BY warning.code
                ORDER BY warning.code
                """.trimIndent(),
                null,
            ).use { cursor ->
                while (cursor.moveToNext()) {
                    warningCounts[cursor.getString(0)] = cursor.getInt(1)
                }
            }
            database.setTransactionSuccessful()
            ArchiveOverview(
                canonicalRecordCount = counts.first,
                runRecordCount = counts.second,
                projection = ProjectionSummary(
                    exactCount = exactCount,
                    lossyCount = lossyCount,
                    archiveOnlyCount = archiveOnlyCount,
                    warningCounts = warningCounts,
                    targetRecords = targetRecords,
                    insertCount = insertCount,
                    updateCount = updateCount,
                    deleteCount = deleteCount,
                ),
            )
        } finally {
            database.endTransaction()
        }
    }

    override suspend fun allRecords(): List<CanonicalRecord> =
        readableDatabase.query(
            "canonical_record",
            null,
            null,
            null,
            null,
            null,
            "canonical_id",
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    add(cursor.record())
                }
            }
        }

    override suspend fun runRecordsPage(
        afterSequence: Long?,
        limit: Int,
    ): List<ArchiveRunRecord> = runRecordsPage(
        readableDatabase,
        afterSequence,
        limit,
    )

    private fun runRecordsPage(
        database: SQLiteDatabase,
        afterSequence: Long?,
        limit: Int,
    ): List<ArchiveRunRecord> =
        database.query(
            "archive_run_record",
            null,
            afterSequence?.let { "sequence > ?" },
            afterSequence?.let { arrayOf(it.toString()) },
            null,
            null,
            "sequence",
            limit.coerceIn(1, 1_000).toString(),
        ).use { cursor ->
            buildList {
                var pageBytes = 0
                while (cursor.moveToNext()) {
                    val record = ArchiveRunRecord(
                            kind = cursor.string("kind"),
                            rawJson = cursor.string("raw_json"),
                            fingerprint = cursor.string("fingerprint"),
                            occurrence = cursor.int("occurrence"),
                            ordinal = cursor.long("sequence"),
                        )
                    val bytes = record.rawJson.toByteArray().size
                    if (isNotEmpty() && pageBytes + bytes > PAGE_RAW_BYTES) {
                        break
                    }
                    add(record)
                    pageBytes += bytes
                }
            }
        }

    override suspend fun <T> withExportSnapshot(
        block: (CanonicalExportSnapshot) -> T,
    ): T {
        val database = readableDatabase
        database.execSQL("BEGIN DEFERRED TRANSACTION")
        return try {
            val result = block(
                object : CanonicalExportSnapshot {
                    override fun recordsPage(
                        afterCanonicalId: String?,
                        limit: Int,
                    ): List<CanonicalRecord> =
                        this@SqliteCanonicalRecordStore.recordsPage(
                            database,
                            afterCanonicalId,
                            limit,
                        )

                    override fun runRecordsPage(
                        afterSequence: Long?,
                        limit: Int,
                    ): List<ArchiveRunRecord> =
                        this@SqliteCanonicalRecordStore.runRecordsPage(
                            database,
                            afterSequence,
                            limit,
                        )
                },
            )
            database.execSQL("COMMIT")
            result
        } catch (error: Throwable) {
            database.execSQL("ROLLBACK")
            throw error
        }
    }

    override suspend fun healthConnectProjections(
        canonicalIds: Set<String>,
    ): Map<String, HealthConnectProjection> {
        if (canonicalIds.isEmpty()) {
            return emptyMap()
        }
        val placeholders = canonicalIds.joinToString(",") { "?" }
        return readableDatabase.rawQuery(
            """
            SELECT canonical_id, target_record, canonical_version,
                   health_connect_record_id
            FROM health_connect_projection
            WHERE canonical_id IN ($placeholders)
            """.trimIndent(),
            canonicalIds.toTypedArray(),
        ).use { cursor ->
            buildMap {
                while (cursor.moveToNext()) {
                    val projection = HealthConnectProjection(
                        canonicalId = cursor.getString(0),
                        targetRecord = cursor.getString(1),
                        canonicalVersion = cursor.getLong(2),
                        healthConnectRecordId = cursor.getString(3),
                    )
                    put(projection.canonicalId, projection)
                }
            }
        }
    }

    override suspend fun pendingHealthConnectOperations(
                canonicalIds: Set<String>,
            ): Map<String, PendingHealthConnectOperation> {
                if (canonicalIds.isEmpty()) return emptyMap()
                val placeholders = canonicalIds.joinToString(",") { "?" }
                return readableDatabase.rawQuery(
                    """
                    SELECT canonical_id, target_record, canonical_version, action
                    FROM health_connect_pending_operation
                    WHERE canonical_id IN ($placeholders)
                    """.trimIndent(),
                    canonicalIds.toTypedArray(),
                ).use { cursor ->
                    buildMap {
                        while (cursor.moveToNext()) {
                            val operation = PendingHealthConnectOperation(
                                canonicalId = cursor.getString(0),
                                targetRecord = cursor.getString(1),
                                canonicalVersion = cursor.getLong(2),
                                action = HealthConnectPendingAction.valueOf(
                                    cursor.getString(3),
                                ),
                            )
                            put(operation.canonicalId, operation)
                        }
                    }
                }
            }

    override suspend fun stageHealthConnectOperations(
                operations: List<PendingHealthConnectOperation>,
            ) {
                if (operations.isEmpty()) return
                val database = writableDatabase
                database.beginTransaction()
                try {
                    for (operation in operations) {
                        val completed = database.rawQuery(
                            """
                            SELECT target_record, canonical_version, action
                            FROM health_connect_operation_state
                            WHERE canonical_id = ?
                            """.trimIndent(),
                            arrayOf(operation.canonicalId),
                        ).use { cursor ->
                            if (cursor.moveToFirst()) {
                                Triple(
                                    cursor.getString(0),
                                    cursor.getLong(1),
                                    cursor.getString(2),
                                )
                            } else {
                                null
                            }
                        }
                        if (
                            completed?.first == operation.targetRecord &&
                            completed.second == operation.canonicalVersion &&
                            completed.third == operation.action.name
                        ) {
                            continue
                        }
                        val committed = database.rawQuery(
                            """
                            SELECT target_record, canonical_version
                            FROM health_connect_projection
                            WHERE canonical_id = ?
                            """.trimIndent(),
                            arrayOf(operation.canonicalId),
                        ).use { cursor ->
                            if (cursor.moveToFirst()) {
                                cursor.getString(0) to cursor.getLong(1)
                            } else {
                                null
                            }
                        }
                        check(
                            committed == null ||
                                (
                                    committed.first == operation.targetRecord &&
                                        (
                                            operation.canonicalVersion >
                                                committed.second ||
                                                (
                                                    operation.action ==
                                                        HealthConnectPendingAction.DELETE &&
                                                        operation.canonicalVersion ==
                                                        committed.second
                                                    )
                                            )
                                )
                        ) {
                            "Stale work cannot replace a committed Health Connect projection."
                        }
                        check(
                            completed == null ||
                                (
                                    completed.first == operation.targetRecord &&
                                        (
                                            operation.canonicalVersion >
                                                completed.second ||
                                                (
                                                    completed.third ==
                                                        HealthConnectPendingAction.UPSERT.name &&
                                                        operation.action ==
                                                        HealthConnectPendingAction.DELETE &&
                                                        operation.canonicalVersion ==
                                                        completed.second
                                                    )
                                            )
                                )
                        ) {
                            "Stale work cannot replace completed Health Connect state."
                        }
                        val current = database.rawQuery(
                            """
                            SELECT canonical_version, target_record, action
                            FROM health_connect_pending_operation
                            WHERE canonical_id = ?
                            """.trimIndent(),
                            arrayOf(operation.canonicalId),
                        ).use { cursor ->
                            if (cursor.moveToFirst()) {
                                Triple(
                                    cursor.getLong(0),
                                    cursor.getString(1),
                                    HealthConnectPendingAction.valueOf(cursor.getString(2)),
                                )
                            } else {
                                null
                            }
                        }
                        check(
                            current == null ||
                                (
                                    current.second == operation.targetRecord &&
                                        (
                                            operation.canonicalVersion > current.first ||
                                                (
                                                    operation.canonicalVersion == current.first &&
                                                        (
                                                            operation.action == current.third ||
                                                                (
                                                                    current.third ==
                                                                        HealthConnectPendingAction.UPSERT &&
                                                                        operation.action ==
                                                                            HealthConnectPendingAction.DELETE
                                                                    )
                                                            )
                                                    )
                                            )
                                )
                        ) {
                            "Stale work cannot replace a pending Health Connect operation."
                        }
                        val values = pendingValues(operation)
                        if (current == null) {
                            database.insertOrThrow(
                                "health_connect_pending_operation",
                                null,
                                values,
                            )
                        } else if (
                            operation.canonicalVersion > current.first ||
                            operation.action != current.third
                        ) {
                            database.update(
                                "health_connect_pending_operation",
                                values,
                                "canonical_id = ?",
                                arrayOf(operation.canonicalId),
                            )
                        }
                    }
                    database.setTransactionSuccessful()
                } finally {
                    database.endTransaction()
                }
            }

    override suspend fun completeHealthConnectUpserts(
                projections: List<HealthConnectProjection>,
            ) {
                if (projections.isEmpty()) return
                val database = writableDatabase
                database.beginTransaction()
                try {
                    for (projection in projections) {
                        val pending = database.rawQuery(
                            """
                            SELECT target_record, canonical_version, action
                            FROM health_connect_pending_operation
                            WHERE canonical_id = ?
                            """.trimIndent(),
                            arrayOf(projection.canonicalId),
                        ).use { cursor ->
                            if (cursor.moveToFirst()) {
                                Triple(
                                    cursor.getString(0),
                                    cursor.getLong(1),
                                    cursor.getString(2),
                                )
                            } else {
                                null
                            }
                        }
                        val completed = database.rawQuery(
                            """
                            SELECT canonical_version, action
                            FROM health_connect_operation_state
                            WHERE canonical_id = ?
                            """.trimIndent(),
                            arrayOf(projection.canonicalId),
                        ).use { cursor ->
                            if (cursor.moveToFirst()) {
                                cursor.getLong(0) to cursor.getString(1)
                            } else {
                                null
                            }
                        }
                        if (
                            pending?.first != projection.targetRecord ||
                            pending.second != projection.canonicalVersion ||
                            pending.third != HealthConnectPendingAction.UPSERT.name ||
                            (
                                completed != null &&
                                    completed.first >= projection.canonicalVersion
                                )
                        ) {
                            continue
                        }
                        saveProjection(database, projection)
                        saveOperationState(
                            database,
                            PendingHealthConnectOperation(
                                canonicalId = projection.canonicalId,
                                targetRecord = projection.targetRecord,
                                canonicalVersion = projection.canonicalVersion,
                                action = HealthConnectPendingAction.UPSERT,
                            ),
                        )
                        database.delete(
                            "health_connect_pending_operation",
                            """
                            canonical_id = ? AND canonical_version = ?
                            AND action = ?
                            """.trimIndent(),
                            arrayOf(
                                projection.canonicalId,
                                projection.canonicalVersion.toString(),
                                HealthConnectPendingAction.UPSERT.name,
                            ),
                        )
                    }
                    database.setTransactionSuccessful()
                } finally {
                    database.endTransaction()
                }
            }

    override suspend fun completeHealthConnectDeletes(
                operations: List<PendingHealthConnectOperation>,
            ) {
                if (operations.isEmpty()) return
                val database = writableDatabase
                database.beginTransaction()
                try {
                    for (operation in operations) {
                        val pending = database.rawQuery(
                            """
                            SELECT target_record, canonical_version, action
                            FROM health_connect_pending_operation
                            WHERE canonical_id = ?
                            """.trimIndent(),
                            arrayOf(operation.canonicalId),
                        ).use { cursor ->
                            if (cursor.moveToFirst()) {
                                Triple(
                                    cursor.getString(0),
                                    cursor.getLong(1),
                                    cursor.getString(2),
                                )
                            } else {
                                null
                            }
                        }
                        val completed = database.rawQuery(
                            """
                            SELECT canonical_version, action
                            FROM health_connect_operation_state
                            WHERE canonical_id = ?
                            """.trimIndent(),
                            arrayOf(operation.canonicalId),
                        ).use { cursor ->
                            if (cursor.moveToFirst()) {
                                cursor.getLong(0) to cursor.getString(1)
                            } else {
                                null
                            }
                        }
                        if (
                            pending?.first != operation.targetRecord ||
                            pending.second != operation.canonicalVersion ||
                            pending.third != HealthConnectPendingAction.DELETE.name ||
                            (
                                completed != null &&
                                    (
                                        completed.first >
                                            operation.canonicalVersion ||
                                            (
                                                completed.first ==
                                                    operation.canonicalVersion &&
                                                    completed.second !=
                                                    HealthConnectPendingAction.UPSERT.name
                                                )
                                        )
                                )
                        ) {
                            continue
                        }
                        database.delete(
                            "health_connect_projection",
                            "canonical_id = ? AND canonical_version <= ?",
                            arrayOf(
                                operation.canonicalId,
                                operation.canonicalVersion.toString(),
                            ),
                        )
                        saveOperationState(database, operation)
                        database.delete(
                            "health_connect_pending_operation",
                            """
                            canonical_id = ? AND canonical_version = ?
                            AND action = ?
                            """.trimIndent(),
                            arrayOf(
                                operation.canonicalId,
                                operation.canonicalVersion.toString(),
                                HealthConnectPendingAction.DELETE.name,
                            ),
                        )
                    }
                    database.setTransactionSuccessful()
                } finally {
                    database.endTransaction()
                }
            }

    override suspend fun saveHealthConnectProjections(
        projections: List<HealthConnectProjection>,
    ) {
        if (projections.isEmpty()) {
            return
        }
        val database = writableDatabase
        database.beginTransaction()
        try {
            for (projection in projections) {
                saveProjection(database, projection)
            }
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
    }

    override suspend fun removeHealthConnectProjections(
        projections: List<HealthConnectProjection>,
    ) {
        if (projections.isEmpty()) {
            return
        }
        val database = writableDatabase
        database.beginTransaction()
        try {
            for (projection in projections) {
                database.delete(
                    "health_connect_projection",
                    "canonical_id = ? AND health_connect_record_id = ?",
                    arrayOf(
                        projection.canonicalId,
                        projection.healthConnectRecordId,
                    ),
                )
            }
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
    }

    private fun materializeStagedParentGraph(
        database: SQLiteDatabase,
        sessionId: String,
    ) {
        database.delete("canonical_parent_winner_graph", null, null)
        database.execSQL(
            """
            WITH RECURSIVE reachable(canonical_id) AS (
                SELECT canonical_id
                FROM canonical_record_stage
                WHERE session_id = ?
                UNION
                SELECT CASE
                    WHEN staged.canonical_id IS NOT NULL
                         AND (
                             persisted.canonical_id IS NULL
                             OR staged.record_version >
                                 persisted.record_version
                         )
                        THEN staged.parent_canonical_id
                    ELSE persisted.parent_canonical_id
                END
                FROM reachable
                LEFT JOIN canonical_record_stage AS staged
                  ON staged.session_id = ?
                 AND staged.canonical_id = reachable.canonical_id
                LEFT JOIN canonical_record AS persisted
                  ON persisted.canonical_id = reachable.canonical_id
                WHERE CASE
                    WHEN staged.canonical_id IS NOT NULL
                         AND (
                             persisted.canonical_id IS NULL
                             OR staged.record_version >
                                 persisted.record_version
                         )
                        THEN staged.parent_canonical_id
                    ELSE persisted.parent_canonical_id
                END IS NOT NULL
            )
            INSERT INTO canonical_parent_winner_graph (
                canonical_id,
                parent_canonical_id
            )
            SELECT reachable.canonical_id,
                   CASE
                       WHEN staged.canonical_id IS NOT NULL
                            AND (
                                persisted.canonical_id IS NULL
                                OR staged.record_version >
                                    persisted.record_version
                            )
                           THEN staged.parent_canonical_id
                       ELSE persisted.parent_canonical_id
                   END
            FROM reachable
            LEFT JOIN canonical_record_stage AS staged
              ON staged.session_id = ?
             AND staged.canonical_id = reachable.canonical_id
            LEFT JOIN canonical_record AS persisted
              ON persisted.canonical_id = reachable.canonical_id
            """.trimIndent(),
            arrayOf(sessionId, sessionId, sessionId),
        )
        validateMaterializedParentGraph(database)
        database.execSQL(
            """
            UPDATE canonical_record_stage
            SET merge_depth = (
                SELECT winner.merge_depth
                FROM canonical_parent_winner_graph AS winner
                WHERE winner.canonical_id =
                    canonical_record_stage.canonical_id
            )
            WHERE session_id = ?
            """.trimIndent(),
            arrayOf(sessionId),
        )
    }

    private fun validateMaterializedParentGraph(
        database: SQLiteDatabase,
    ) {
        database.execSQL(
            """
            WITH RECURSIVE parent_depth(canonical_id, depth) AS (
                SELECT canonical_id, 0
                FROM canonical_parent_winner_graph
                WHERE parent_canonical_id IS NULL
                UNION ALL
                SELECT child.canonical_id, parent_depth.depth + 1
                FROM canonical_parent_winner_graph AS child
                JOIN parent_depth
                  ON child.parent_canonical_id = parent_depth.canonical_id
                WHERE parent_depth.depth <= ?
            )
            UPDATE canonical_parent_winner_graph
            SET merge_depth = (
                SELECT parent_depth.depth
                FROM parent_depth
                WHERE parent_depth.canonical_id =
                    canonical_parent_winner_graph.canonical_id
            )
            """.trimIndent(),
            arrayOf<Any>(MAX_CANONICAL_PARENT_DEPTH),
        )
        val maximumDepth = database.rawQuery(
            "SELECT MAX(merge_depth) FROM canonical_parent_winner_graph",
            null,
        ).use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else 0
        }
        if (maximumDepth > MAX_CANONICAL_PARENT_DEPTH) {
            throw ArchiveFormatException(
                "Canonical parent depth exceeds the " +
                    "$MAX_CANONICAL_PARENT_DEPTH level limit.",
            )
        }
        val hasCycle = database.rawQuery(
            """
            SELECT 1
            FROM canonical_parent_winner_graph
            WHERE merge_depth IS NULL
            LIMIT 1
            """.trimIndent(),
            null,
        ).use(Cursor::moveToFirst)
        if (hasCycle) {
            throw ArchiveFormatException(
                "Canonical records contain a parent cycle.",
            )
        }
    }

    private fun validateStagedAppliedParentGraph(
        database: SQLiteDatabase,
        sessionId: String,
    ) {
        database.delete("canonical_parent_graph_seed", null, null)
        database.execSQL(
            """
            INSERT OR IGNORE INTO canonical_parent_graph_seed (canonical_id)
            SELECT canonical_id
            FROM canonical_record_stage
            WHERE session_id = ?
            """.trimIndent(),
            arrayOf(sessionId),
        )
        materializeAppliedParentGraph(database)
        validateMaterializedParentGraph(database)
    }

    private fun materializeAppliedParentGraph(database: SQLiteDatabase) {
        database.delete("canonical_parent_winner_graph", null, null)
        database.execSQL(
            """
            WITH RECURSIVE affected(canonical_id) AS (
                SELECT canonical_id
                FROM canonical_parent_graph_seed
                UNION
                SELECT child.canonical_id
                FROM canonical_record AS child
                JOIN affected
                  ON child.parent_canonical_id = affected.canonical_id
            )
            INSERT INTO canonical_parent_winner_graph (
                canonical_id,
                parent_canonical_id
            )
            SELECT affected.canonical_id,
                   persisted.parent_canonical_id
            FROM affected
            LEFT JOIN canonical_record AS persisted
              ON persisted.canonical_id = affected.canonical_id
            """.trimIndent(),
        )
        database.execSQL(
            """
            WITH RECURSIVE closure(canonical_id) AS (
                SELECT canonical_id
                FROM canonical_parent_winner_graph
                UNION
                SELECT persisted.parent_canonical_id
                FROM closure
                JOIN canonical_record AS persisted
                  ON persisted.canonical_id = closure.canonical_id
                WHERE persisted.parent_canonical_id IS NOT NULL
            )
            INSERT OR IGNORE INTO canonical_parent_winner_graph (
                canonical_id,
                parent_canonical_id
            )
            SELECT closure.canonical_id,
                   persisted.parent_canonical_id
            FROM closure
            LEFT JOIN canonical_record AS persisted
              ON persisted.canonical_id = closure.canonical_id
            """.trimIndent(),
        )
    }

    private fun validateStoredParentGraph(
        database: SQLiteDatabase,
        canonicalIds: Iterable<String>,
    ) {
        database.delete("canonical_parent_graph_seed", null, null)
        var hasSeeds = false
        for (canonicalId in canonicalIds) {
            hasSeeds = true
            database.insertWithOnConflict(
                "canonical_parent_graph_seed",
                null,
                ContentValues().apply { put("canonical_id", canonicalId) },
                SQLiteDatabase.CONFLICT_IGNORE,
            )
        }
        if (!hasSeeds) return
        try {
            materializeAppliedParentGraph(database)
            validateMaterializedParentGraph(database)
        } finally {
            database.delete("canonical_parent_winner_graph", null, null)
            database.delete("canonical_parent_graph_seed", null, null)
        }
    }

    private fun mergeIntoCanonical(
        database: SQLiteDatabase,
        records: List<CanonicalRecord>,
    ): MergeResult {
        var result = MergeResult()
        val ordered = recordsInParentWinnerOrder(records) { canonicalId ->
            parentState(database, canonicalId)?.let {
                CanonicalParentWinner(
                    recordVersion = it.recordVersion,
                    parentCanonicalId = it.parentCanonicalId,
                )
            }
        }
        val blockedIncomingSubtrees = hashSetOf<String>()
        for (record in ordered) {
            result += mergeOne(database, record, blockedIncomingSubtrees)
        }
        validateStoredParentGraph(
            database,
            ordered.map(CanonicalRecord::canonicalId),
        )
        restoreUnresolvedContinuationErrors(database)
        reconcileEncodingFailures(database)
        refreshProjectionFacts(
            database,
            ordered.map(CanonicalRecord::canonicalId),
        )
        return result
    }

    private fun restoreUnresolvedContinuationErrors(database: SQLiteDatabase) {
        database.execSQL(
            """
            UPDATE canonical_record
            SET tombstone = 0,
                record_version = record_version + 1
            WHERE kind = 'sampleEncodingError'
              AND resolution_canonical_id IS NOT NULL
              AND tombstone = 1
              AND NOT EXISTS (
                  SELECT 1
                  FROM canonical_record AS parent
                  WHERE parent.canonical_id =
                            canonical_record.parent_canonical_id
                    AND parent.tombstone = 1
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM canonical_record AS resolver
                  WHERE resolver.canonical_id =
                            canonical_record.resolution_canonical_id
                    AND resolver.type = canonical_record.type
                    AND resolver.parent_canonical_id =
                            canonical_record.parent_canonical_id
                    AND resolver.tombstone = 0
                    AND resolver.kind = CASE
                        WHEN canonical_record.type =
                                'HKWorkoutRouteTypeIdentifier'
                            THEN 'workoutRouteEnd'
                        WHEN canonical_record.type =
                                'HKDataTypeIdentifierElectrocardiogram'
                            THEN 'electrocardiogramEnd'
                        ELSE 'quantitySeriesEnd'
                    END
              )
            """.trimIndent(),
        )
    }

    private fun reconcileEncodingFailures(database: SQLiteDatabase) {
        database.execSQL(
            """
            UPDATE canonical_record
            SET tombstone = 1,
                record_version = MAX(
                    canonical_record.record_version + 1,
                    (
                        SELECT resolver.record_version + 1
                        FROM canonical_record AS resolver
                        WHERE resolver.canonical_id = COALESCE(
                            canonical_record.resolution_canonical_id,
                            canonical_record.parent_canonical_id
                        )
                    )
                )
            WHERE kind = 'sampleEncodingError'
              AND tombstone = 0
              AND EXISTS (
                  SELECT 1
                  FROM canonical_record AS resolver
                  WHERE resolver.canonical_id = COALESCE(
                      canonical_record.resolution_canonical_id,
                      canonical_record.parent_canonical_id
                  )
                    AND resolver.kind != 'sampleEncodingError'
                    AND resolver.tombstone = 0
                    AND (
                        canonical_record.resolution_canonical_id IS NULL
                        OR (
                            resolver.kind IN (
                                CASE
                                    WHEN canonical_record.type =
                                            'HKWorkoutRouteTypeIdentifier'
                                        THEN 'workoutRouteEnd'
                                    WHEN canonical_record.type =
                                            'HKDataTypeIdentifierElectrocardiogram'
                                        THEN 'electrocardiogramEnd'
                                    ELSE 'quantitySeriesEnd'
                                END
                            )
                            AND resolver.type = canonical_record.type
                            AND resolver.parent_canonical_id =
                                canonical_record.parent_canonical_id
                        )
                    )
              )
            """.trimIndent(),
        )
    }

    private fun restoreContinuationErrors(database: SQLiteDatabase) {
        database.query(
            "canonical_record",
            arrayOf(
                "canonical_id",
                "parent_canonical_id",
                "raw_json",
                "record_version",
            ),
            "kind = 'sampleEncodingError'",
            null,
            null,
            null,
            null,
        ).use { cursor ->
            while (cursor.moveToNext()) {
                val canonicalId = cursor.getString(0)
                val parentId = if (cursor.isNull(1)) null else cursor.getString(1)
                val parsed = try {
                    CanonicalRecordParser.parse(cursor.getString(2))
                } catch (_: Exception) {
                    null
                } ?: continue
                val resolutionId = parsed.resolutionCanonicalId ?: continue
                val parent = parentId?.let { parentState(database, it) }
                val resolver = parentState(database, resolutionId)
                val hasValidEnd = resolver != null &&
                    resolver.kind ==
                    CanonicalRecordParser.seriesEndKind(parsed.type) &&
                    resolver.type == parsed.type &&
                    resolver.parentCanonicalId == parentId &&
                    !resolver.tombstone
                val values = ContentValues().apply {
                    put("resolution_canonical_id", resolutionId)
                    if (parent?.tombstone != true && !hasValidEnd) {
                        put(
                            "record_version",
                            maxOf(
                                cursor.getLong(3) + 1,
                                parsed.recordVersion,
                                3,
                            ),
                        )
                        put("tombstone", 0)
                    }
                }
                database.update(
                    "canonical_record",
                    values,
                    "canonical_id = ?",
                    arrayOf(canonicalId),
                )
            }
        }
    }

    private fun mergeOne(
        database: SQLiteDatabase,
        record: CanonicalRecord,
        blockedIncomingSubtrees: MutableSet<String>,
    ): MergeResult {
        if (
            !record.tombstone &&
            record.parentCanonicalId in blockedIncomingSubtrees
        ) {
            blockedIncomingSubtrees += record.canonicalId
            return MergeResult(ignored = 1)
        }
        val parent = record.parentCanonicalId?.let { parentState(database, it) }
        if (
            parent?.tombstone == true &&
            !record.tombstone &&
            record.recordVersion > parent.recordVersion
        ) {
            if (parentState(database, record.canonicalId)?.tombstone != false) {
                blockedIncomingSubtrees += record.canonicalId
            }
            return MergeResult(ignored = 1)
        }
        val effective = if (parent?.tombstone == true) {
            record.deferredByParentTombstone(parent.recordVersion)
        } else {
            record
        }
        val existing = parentState(database, effective.canonicalId)
        val result = when {
            existing == null -> {
                database.insertOrThrow("canonical_record", null, values(effective))
                MergeResult(
                    inserted = 1,
                    tombstones = if (effective.tombstone) 1 else 0,
                )
            }
            effective.recordVersion > existing.recordVersion -> {
                database.update(
                    "canonical_record",
                    values(effective),
                    "canonical_id = ?",
                    arrayOf(effective.canonicalId),
                )
                MergeResult(
                    updated = 1,
                    tombstones = if (effective.tombstone) 1 else 0,
                )
            }
            else -> MergeResult(ignored = 1)
        }
        val winningParent = parentState(database, effective.canonicalId)
        if (winningParent?.tombstone == true) {
            cascadeTombstone(
                database,
                effective.canonicalId,
                winningParent.recordVersion,
            )
        } else if (
            winningParent != null &&
            winningParent.kind != "sampleEncodingError"
        ) {
            database.execSQL(
                """
                UPDATE canonical_record
                SET tombstone = 1,
                    record_version = MAX(record_version + 1, ? + 1)
                WHERE parent_canonical_id = ?
                  AND kind = 'sampleEncodingError'
                  AND resolution_canonical_id IS NULL
                  AND tombstone = 0
                """.trimIndent(),
                arrayOf<Any>(
                    winningParent.recordVersion,
                    effective.canonicalId,
                ),
            )
        }
        return result
    }

    private fun cascadeTombstone(
        database: SQLiteDatabase,
        parentCanonicalId: String,
        parentVersion: Long,
    ) {
        database.execSQL(
            """
            WITH RECURSIVE descendants(canonical_id, inherited_version) AS (
                SELECT child.canonical_id,
                       CASE
                           WHEN child.tombstone = 1
                             OR child.kind = 'sampleEncodingError'
                               THEN MAX(child.record_version, ?)
                           ELSE ?
                       END
                FROM canonical_record AS child
                WHERE child.parent_canonical_id = ?
                  AND (
                      child.tombstone = 1
                      OR child.kind = 'sampleEncodingError'
                      OR child.record_version <= ?
                  )
                UNION
                SELECT child.canonical_id,
                       CASE
                           WHEN child.tombstone = 1
                             OR child.kind = 'sampleEncodingError'
                               THEN MAX(
                                   child.record_version,
                                   descendants.inherited_version
                               )
                           ELSE descendants.inherited_version
                       END
                FROM canonical_record AS child
                JOIN descendants
                  ON child.parent_canonical_id = descendants.canonical_id
                WHERE child.tombstone = 1
                   OR child.kind = 'sampleEncodingError'
                   OR child.record_version <= descendants.inherited_version
            )
            UPDATE canonical_record
            SET tombstone = 1,
                record_version = (
                    SELECT descendants.inherited_version
                    FROM descendants
                    WHERE descendants.canonical_id =
                        canonical_record.canonical_id
                )
            WHERE canonical_id IN (
                SELECT canonical_id
                FROM descendants
            )
            """.trimIndent(),
            arrayOf<Any>(
                parentVersion,
                parentVersion,
                parentCanonicalId,
                parentVersion,
            ),
        )
    }

    private fun parentState(
        database: SQLiteDatabase,
        canonicalId: String,
    ): StoredRecordState? {
        parentStateLookupCountForTesting += 1
        return database.query(
            "canonical_record",
            arrayOf(
                "record_version",
                "tombstone",
                "kind",
                "parent_canonical_id",
                "type",
            ),
            "canonical_id = ?",
            arrayOf(canonicalId),
            null,
            null,
            null,
        ).use { cursor ->
            if (cursor.moveToFirst()) {
                StoredRecordState(
                    recordVersion = cursor.getLong(0),
                    tombstone = cursor.getInt(1) != 0,
                    kind = cursor.getString(2),
                    parentCanonicalId = if (cursor.isNull(3)) {
                        null
                    } else {
                        cursor.getString(3)
                    },
                    type = cursor.getString(4),
                )
            } else {
                null
            }
        }
    }

    private fun existingVersion(
        database: SQLiteDatabase,
        table: String,
        canonicalId: String,
        sessionId: String? = null,
    ): Long? = database.query(
        table,
        arrayOf("record_version"),
        if (sessionId == null) "canonical_id = ?" else {
            "session_id = ? AND canonical_id = ?"
        },
        if (sessionId == null) arrayOf(canonicalId) else {
            arrayOf(sessionId, canonicalId)
        },
        null,
        null,
        null,
    ).use { cursor ->
        if (cursor.moveToFirst()) cursor.getLong(0) else null
    }

    private fun stageCount(
        database: SQLiteDatabase,
        table: String,
        sessionId: String,
    ): Long = database.rawQuery(
        "SELECT COUNT(*) FROM $table WHERE session_id = ?",
        arrayOf(sessionId),
    ).use { cursor ->
        if (cursor.moveToFirst()) cursor.getLong(0) else 0
    }

    private fun verifyStageCount(
        database: SQLiteDatabase,
        table: String,
        sessionId: String,
        expected: Long,
    ) {
        val actual = stageCount(database, table, sessionId)
        if (actual != expected) {
            throw ArchiveFormatException(
                "The active import staging set changed before commit.",
            )
        }
    }

    private fun stagedCanonicalIds(
        database: SQLiteDatabase,
        sessionId: String,
    ): List<String> = database.query(
        "canonical_record_stage",
        arrayOf("canonical_id"),
        "session_id = ?",
        arrayOf(sessionId),
        null,
        null,
        null,
    ).use { cursor ->
        buildList {
            while (cursor.moveToNext()) add(cursor.getString(0))
        }
    }

    private fun refreshAllProjectionFacts(database: SQLiteDatabase) {
        database.delete("canonical_projection_fact", null, null)
        database.delete("canonical_projection_warning", null, null)
        database.query(
            "canonical_record",
            null,
            null,
            null,
            null,
            null,
            null,
        ).use { cursor ->
            while (cursor.moveToNext()) {
                saveProjectionFact(database, cursor.record())
            }
        }
    }

    private fun refreshProjectionFacts(
        database: SQLiteDatabase,
        seedCanonicalIds: Iterable<String>,
    ) {
        database.delete("canonical_parent_graph_seed", null, null)
        var hasSeeds = false
        for (canonicalId in seedCanonicalIds) {
            hasSeeds = true
            database.insertWithOnConflict(
                "canonical_parent_graph_seed",
                null,
                ContentValues().apply { put("canonical_id", canonicalId) },
                SQLiteDatabase.CONFLICT_IGNORE,
            )
        }
        if (!hasSeeds) return
        try {
            database.rawQuery(
                """
                WITH RECURSIVE affected(canonical_id) AS (
                    SELECT canonical_id
                    FROM canonical_parent_graph_seed
                    UNION
                    SELECT child.canonical_id
                    FROM canonical_record AS child
                    JOIN affected
                      ON child.parent_canonical_id = affected.canonical_id
                      OR child.resolution_canonical_id = affected.canonical_id
                )
                SELECT canonical.*
                FROM canonical_record AS canonical
                JOIN affected
                  ON affected.canonical_id = canonical.canonical_id
                """.trimIndent(),
                null,
            ).use { cursor ->
                while (cursor.moveToNext()) {
                    saveProjectionFact(database, cursor.record())
                }
            }
        } finally {
            database.delete("canonical_parent_graph_seed", null, null)
        }
    }

    private fun saveProjectionFact(
        database: SQLiteDatabase,
        record: CanonicalRecord,
    ) {
        val planned = ProjectionPlanner.plan(record)
        database.insertWithOnConflict(
            "canonical_projection_fact",
            null,
            ContentValues().apply {
                put("canonical_id", record.canonicalId)
                put("quality", planned.quality.name)
                put("target_record", planned.draft?.targetRecord())
            },
            SQLiteDatabase.CONFLICT_REPLACE,
        )
        database.delete(
            "canonical_projection_warning",
            "canonical_id = ?",
            arrayOf(record.canonicalId),
        )
        for (warning in planned.warnings) {
            database.insertOrThrow(
                "canonical_projection_warning",
                null,
                ContentValues().apply {
                    put("canonical_id", record.canonicalId)
                    put("code", warning.code)
                },
            )
        }
    }

    private fun pendingValues(
        operation: PendingHealthConnectOperation,
    ): ContentValues = ContentValues().apply {
        put("canonical_id", operation.canonicalId)
        put("target_record", operation.targetRecord)
        put("canonical_version", operation.canonicalVersion)
        put("action", operation.action.name)
    }

    private fun saveProjection(
        database: SQLiteDatabase,
        projection: HealthConnectProjection,
    ) {
        val currentVersion = database.rawQuery(
            """
            SELECT canonical_version
            FROM health_connect_projection
            WHERE canonical_id = ?
            """.trimIndent(),
            arrayOf(projection.canonicalId),
        ).use { cursor ->
            if (cursor.moveToFirst()) cursor.getLong(0) else null
        }
        val values = ContentValues().apply {
            put("canonical_id", projection.canonicalId)
            put("target_record", projection.targetRecord)
            put("canonical_version", projection.canonicalVersion)
            put("health_connect_record_id", projection.healthConnectRecordId)
        }
        if (currentVersion == null) {
            database.insertOrThrow(
                "health_connect_projection",
                null,
                values,
            )
        } else if (projection.canonicalVersion >= currentVersion) {
            database.update(
                "health_connect_projection",
                values,
                "canonical_id = ?",
                arrayOf(projection.canonicalId),
            )
        }
    }

    private fun saveOperationState(
        database: SQLiteDatabase,
        operation: PendingHealthConnectOperation,
    ) {
        val current = database.rawQuery(
            """
            SELECT target_record, canonical_version
            FROM health_connect_operation_state
            WHERE canonical_id = ?
            """.trimIndent(),
            arrayOf(operation.canonicalId),
        ).use { cursor ->
            if (cursor.moveToFirst()) {
                cursor.getString(0) to cursor.getLong(1)
            } else {
                null
            }
        }
        if (current != null && current.second > operation.canonicalVersion) return
        check(current == null || current.first == operation.targetRecord) {
            "A canonical record cannot change its completed Health Connect target."
        }
        val values = pendingValues(operation)
        if (current == null) {
            database.insertOrThrow(
                "health_connect_operation_state",
                null,
                values,
            )
        } else {
            database.update(
                "health_connect_operation_state",
                values,
                "canonical_id = ?",
                arrayOf(operation.canonicalId),
            )
        }
    }

    private fun values(record: CanonicalRecord): ContentValues = ContentValues().apply {
        put("canonical_id", record.canonicalId)
        put("parent_canonical_id", record.parentCanonicalId)
        put("resolution_canonical_id", record.resolutionCanonicalId)
        put("record_version", record.recordVersion)
        put("kind", record.kind)
        put("canonical_type", record.canonicalType)
        put("type", record.type)
        put("start_time", record.startTime?.toString())
        put("end_time", record.endTime?.toString())
        put("canonical_value", record.canonicalValue?.value)
        put("canonical_unit", record.canonicalValue?.unit)
        put("canonical_description", record.canonicalValue?.description)
        put("original_value", record.originalValue?.value)
        put("original_unit", record.originalValue?.unit)
        put("original_description", record.originalValue?.description)
        put("category_value", record.categoryValue)
        put("activity_type", record.activityType)
        put("quantity_count", record.quantityCount)
        put("source_record_id", record.sourceRecordId)
        put("source_record_version", record.sourceRecordVersion)
        put("source_store", record.sourceStore)
        put("source_bundle_identifier", record.sourceBundleIdentifier)
        put("source_name", record.sourceName)
        put("timeline_sort_key", (record.endTime ?: record.startTime)?.let(::timelineSortKey))
        put("device_json", record.deviceJson)
        put("metadata_json", record.metadataJson)
        put("lineage_json", CanonicalRecordParser.lineageJson(record.lineage))
        put("tombstone", if (record.tombstone) 1 else 0)
        put("raw_json", record.rawJson)
    }

    private fun stageValues(
        sessionId: String,
        record: CanonicalRecord,
    ): ContentValues = ContentValues(values(record)).apply {
        remove("timeline_sort_key")
        put("session_id", sessionId)
    }

    private fun runStageValues(
        sessionId: String,
        record: ArchiveRunRecord,
    ): ContentValues = ContentValues().apply {
        put("session_id", sessionId)
        put("ordinal", record.ordinal)
        put("fingerprint", record.fingerprint)
        put("occurrence", record.occurrence)
        put("kind", record.kind)
        put("raw_json", record.rawJson)
    }

    private fun Cursor.record(): CanonicalRecord {
        recordMaterializationCountForTesting += 1
        return CanonicalRecord(
            canonicalId = string("canonical_id"),
            parentCanonicalId = nullableString("parent_canonical_id"),
            recordVersion = long("record_version"),
            kind = string("kind"),
            canonicalType = string("canonical_type"),
            type = string("type"),
            startTime = nullableString("start_time")?.let(Instant::parse),
            endTime = nullableString("end_time")?.let(Instant::parse),
            canonicalValue = nullableDouble("canonical_value")?.let {
                CanonicalValue(
                    value = it,
                    unit = nullableString("canonical_unit"),
                    description = nullableString("canonical_description"),
                )
            },
            originalValue = nullableDouble("original_value")?.let {
                CanonicalValue(
                    value = it,
                    unit = nullableString("original_unit"),
                    description = nullableString("original_description"),
                )
            },
            categoryValue = nullableInt("category_value"),
            activityType = nullableInt("activity_type"),
            quantityCount = nullableInt("quantity_count"),
            sourceRecordId = string("source_record_id"),
            sourceRecordVersion = nullableLong("source_record_version"),
            sourceStore = string("source_store"),
            sourceBundleIdentifier = nullableString("source_bundle_identifier"),
            sourceName = nullableString("source_name"),
            deviceJson = nullableString("device_json"),
            metadataJson = nullableString("metadata_json"),
            lineage = CanonicalRecordParser.lineage(string("lineage_json")),
            tombstone = int("tombstone") != 0,
            rawJson = string("raw_json"),
            resolutionCanonicalId = nullableString("resolution_canonical_id"),
        )
    }

    private fun Cursor.index(name: String): Int = getColumnIndexOrThrow(name)
    private fun Cursor.string(name: String): String = getString(index(name))
    private fun Cursor.long(name: String): Long = getLong(index(name))
    private fun Cursor.int(name: String): Int = getInt(index(name))
    private fun Cursor.nullableString(name: String): String? =
        index(name).let { if (isNull(it)) null else getString(it) }
    private fun Cursor.nullableDouble(name: String): Double? =
        index(name).let { if (isNull(it)) null else getDouble(it) }
    private fun Cursor.nullableInt(name: String): Int? =
        index(name).let { if (isNull(it)) null else getInt(it) }
    private fun Cursor.nullableLong(name: String): Long? =
        index(name).let { if (isNull(it)) null else getLong(it) }

    private companion object {
        const val PAGE_RAW_BYTES = 512 * 1_024
        fun createStageTable(database: SQLiteDatabase) {
            database.execSQL(
                """
                CREATE TABLE IF NOT EXISTS canonical_record_stage (
                    session_id TEXT NOT NULL,
                    canonical_id TEXT NOT NULL,
                    parent_canonical_id TEXT,
                    resolution_canonical_id TEXT,
                    record_version INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    canonical_type TEXT NOT NULL,
                    type TEXT NOT NULL,
                    start_time TEXT,
                    end_time TEXT,
                    canonical_value REAL,
                    canonical_unit TEXT,
                    canonical_description TEXT,
                    original_value REAL,
                    original_unit TEXT,
                    original_description TEXT,
                    category_value INTEGER,
                    activity_type INTEGER,
                    quantity_count INTEGER,
                    source_record_id TEXT NOT NULL,
                    source_record_version INTEGER,
                    source_store TEXT NOT NULL,
                    source_bundle_identifier TEXT,
                    source_name TEXT,
                    device_json TEXT,
                    metadata_json TEXT,
                    lineage_json TEXT NOT NULL,
                    tombstone INTEGER NOT NULL,
                    raw_json TEXT NOT NULL,
                    PRIMARY KEY (session_id, canonical_id)
                )
                """.trimIndent(),
            )
        }

        fun createRunRecordTables(database: SQLiteDatabase) {
            database.execSQL(
                """
                CREATE TABLE IF NOT EXISTS archive_run_record (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    fingerprint TEXT NOT NULL,
                    occurrence INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    raw_json TEXT NOT NULL,
                    UNIQUE (fingerprint, occurrence)
                )
                """.trimIndent(),
            )
        }

        fun createTemporaryStageTables(database: SQLiteDatabase) {
            database.execSQL(
                """
                CREATE TEMP TABLE IF NOT EXISTS canonical_record_stage (
                    session_id TEXT NOT NULL,
                    canonical_id TEXT NOT NULL,
                    parent_canonical_id TEXT,
                    resolution_canonical_id TEXT,
                    record_version INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    canonical_type TEXT NOT NULL,
                    type TEXT NOT NULL,
                    start_time TEXT,
                    end_time TEXT,
                    canonical_value REAL,
                    canonical_unit TEXT,
                    canonical_description TEXT,
                    original_value REAL,
                    original_unit TEXT,
                    original_description TEXT,
                    category_value INTEGER,
                    activity_type INTEGER,
                    quantity_count INTEGER,
                    source_record_id TEXT NOT NULL,
                    source_record_version INTEGER,
                    source_store TEXT NOT NULL,
                    source_bundle_identifier TEXT,
                    source_name TEXT,
                    device_json TEXT,
                    metadata_json TEXT,
                    lineage_json TEXT NOT NULL,
                    tombstone INTEGER NOT NULL,
                    raw_json TEXT NOT NULL,
                    merge_depth INTEGER,
                    PRIMARY KEY (session_id, canonical_id)
                )
                """.trimIndent(),
            )
            database.execSQL(
                """
                CREATE INDEX IF NOT EXISTS canonical_record_stage_parent
                ON canonical_record_stage (
                    session_id,
                    parent_canonical_id,
                    canonical_id
                )
                """.trimIndent(),
            )
            database.execSQL(
                """
                CREATE TEMP TABLE IF NOT EXISTS canonical_parent_winner_graph (
                    canonical_id TEXT PRIMARY KEY,
                    parent_canonical_id TEXT,
                    merge_depth INTEGER
                )
                """.trimIndent(),
            )
            database.execSQL(
                """
                CREATE INDEX IF NOT EXISTS canonical_parent_winner_graph_parent
                ON canonical_parent_winner_graph (parent_canonical_id)
                """.trimIndent(),
            )
            database.execSQL(
                """
                CREATE TEMP TABLE IF NOT EXISTS canonical_parent_graph_seed (
                    canonical_id TEXT PRIMARY KEY
                )
                """.trimIndent(),
            )
            database.execSQL(
                """
                CREATE TEMP TABLE IF NOT EXISTS archive_run_record_stage (
                    session_id TEXT NOT NULL,
                    ordinal INTEGER NOT NULL,
                    fingerprint TEXT NOT NULL,
                    occurrence INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    raw_json TEXT NOT NULL,
                    PRIMARY KEY (session_id, fingerprint, occurrence)
                )
                """.trimIndent(),
            )
        }

        fun hasColumn(
            database: SQLiteDatabase,
            table: String,
            column: String,
        ): Boolean = database.rawQuery(
            "PRAGMA table_info($table)",
            null,
        ).use { cursor ->
            val name = cursor.getColumnIndexOrThrow("name")
            generateSequence { if (cursor.moveToNext()) cursor else null }
                .any { it.getString(name) == column }
        }

        fun hasTable(database: SQLiteDatabase, table: String): Boolean =
            database.rawQuery(
                """
                SELECT 1 FROM sqlite_master
                WHERE type = 'table' AND name = ?
                """.trimIndent(),
                arrayOf(table),
            ).use(Cursor::moveToFirst)

        private fun timelineSortKey(instant: Instant): String = String.format(
            Locale.US,
            "%017d%09d",
            instant.epochSecond - Instant.MIN.epochSecond,
            instant.nano,
        )

        private fun backfillTimelineSortKeys(database: SQLiteDatabase) {
            database.rawQuery(
                """
                SELECT canonical_id, end_time, start_time
                FROM canonical_record
                """.trimIndent(),
                null,
            ).use { cursor ->
                while (cursor.moveToNext()) {
                    val text = when {
                        !cursor.isNull(1) -> cursor.getString(1)
                        !cursor.isNull(2) -> cursor.getString(2)
                        else -> null
                    }
                    val key = text?.let {
                        try {
                            timelineSortKey(Instant.parse(it))
                        } catch (_: Exception) {
                            null
                        }
                    }
                    database.update(
                        "canonical_record",
                        ContentValues().apply { put("timeline_sort_key", key) },
                        "canonical_id = ?",
                        arrayOf(cursor.getString(0)),
                    )
                }
            }
        }

        private data class StoredRecordState(
            val recordVersion: Long,
            val tombstone: Boolean,
            val kind: String,
            val parentCanonicalId: String?,
            val type: String,
        )
    }

    fun createHealthConnectProjectionTable(database: SQLiteDatabase) {
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS health_connect_projection (
                canonical_id TEXT PRIMARY KEY,
                target_record TEXT NOT NULL,
                canonical_version INTEGER NOT NULL,
                health_connect_record_id TEXT NOT NULL
            )
            """.trimIndent(),
        )
    }

    fun createHealthConnectPendingTable(database: SQLiteDatabase) {
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS health_connect_pending_operation (
                canonical_id TEXT PRIMARY KEY,
                target_record TEXT NOT NULL,
                canonical_version INTEGER NOT NULL,
                action TEXT NOT NULL
            )
            """.trimIndent(),
        )
    }

    fun createHealthConnectOperationStateTable(database: SQLiteDatabase) {
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS health_connect_operation_state (
                canonical_id TEXT PRIMARY KEY,
                target_record TEXT NOT NULL,
                canonical_version INTEGER NOT NULL,
                action TEXT NOT NULL
            )
            """.trimIndent(),
        )
    }

    fun createProjectionFactTables(database: SQLiteDatabase) {
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS canonical_projection_fact (
                canonical_id TEXT PRIMARY KEY,
                quality TEXT NOT NULL,
                target_record TEXT
            )
            """.trimIndent(),
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS canonical_projection_warning (
                canonical_id TEXT NOT NULL,
                code TEXT NOT NULL,
                PRIMARY KEY (canonical_id, code)
            )
            """.trimIndent(),
        )
        database.execSQL(
            """
            CREATE INDEX IF NOT EXISTS canonical_projection_fact_quality
            ON canonical_projection_fact (quality)
            """.trimIndent(),
        )
        database.execSQL(
            """
            CREATE INDEX IF NOT EXISTS canonical_projection_warning_code
            ON canonical_projection_warning (code)
            """.trimIndent(),
        )
        database.execSQL(
            """
            CREATE INDEX IF NOT EXISTS canonical_record_resolution
            ON canonical_record (resolution_canonical_id)
            """.trimIndent(),
        )
    }
}
