package com.thatcube.hozz.core

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class SqliteCanonicalRecordStore(
    context: Context,
    databaseName: String = "hozz-archive.sqlite",
) :
    SQLiteOpenHelper(context, databaseName, null, 10),
    CanonicalRecordStore {

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
        database.execSQL(
            """
            CREATE INDEX canonical_record_timeline
            ON canonical_record (tombstone, end_time DESC, start_time DESC)
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
        reconcileEncodingFailures(database)
    }

    override fun onOpen(database: SQLiteDatabase) {
        super.onOpen(database)
        createTemporaryStageTables(database)
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
                    database.query(
                        "canonical_record_stage",
                        null,
                        "session_id = ?",
                        arrayOf(sessionId),
                        null,
                        null,
                        "canonical_id",
                    ).use { cursor ->
                        while (cursor.moveToNext()) {
                            result += mergeOne(database, cursor.record())
                        }
                    }
                    restoreUnresolvedContinuationErrors(database)
                    reconcileEncodingFailures(database)
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

    override suspend fun timeline(limit: Int): List<CanonicalRecord> =
        readableDatabase.query(
            "canonical_record",
            null,
            "tombstone = 0",
            null,
            null,
            null,
            "COALESCE(end_time, start_time) DESC",
            limit.coerceIn(1, 1_000).toString(),
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    add(cursor.record())
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
                while (cursor.moveToNext()) {
                    add(cursor.record())
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
                while (cursor.moveToNext()) {
                    add(
                        ArchiveRunRecord(
                            kind = cursor.string("kind"),
                            rawJson = cursor.string("raw_json"),
                            fingerprint = cursor.string("fingerprint"),
                            occurrence = cursor.int("occurrence"),
                            ordinal = cursor.long("sequence"),
                        ),
                    )
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
                    put(
                        "health_connect_record_id",
                        projection.healthConnectRecordId,
                    )
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

    private fun mergeIntoCanonical(
        database: SQLiteDatabase,
        records: List<CanonicalRecord>,
    ): MergeResult {
        var result = MergeResult()
        for (record in records) {
            result += mergeOne(database, record)
        }
        restoreUnresolvedContinuationErrors(database)
        reconcileEncodingFailures(database)
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
    ): MergeResult {
        val effective = record.parentCanonicalId
            ?.let { parentState(database, it) }
            ?.takeIf(StoredRecordState::tombstone)
            ?.let { parent ->
                record.copy(
                    recordVersion = maxOf(
                        record.recordVersion,
                        parent.recordVersion,
                    ),
                    tombstone = true,
                )
            }
            ?: record
        val existingVersion = existingVersion(
            database = database,
            table = "canonical_record",
            canonicalId = effective.canonicalId,
        )
        val result = when {
            existingVersion == null -> {
                database.insertOrThrow("canonical_record", null, values(effective))
                MergeResult(
                    inserted = 1,
                    tombstones = if (effective.tombstone) 1 else 0,
                )
            }
            effective.recordVersion > existingVersion -> {
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
            database.execSQL(
                """
                UPDATE canonical_record
                SET tombstone = 1,
                    record_version = MAX(record_version, ?)
                WHERE parent_canonical_id = ?
                """.trimIndent(),
                arrayOf<Any>(
                    winningParent.recordVersion,
                    effective.canonicalId,
                ),
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

    private fun parentState(
        database: SQLiteDatabase,
        canonicalId: String,
    ): StoredRecordState? = database.query(
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

    private fun Cursor.record(): CanonicalRecord = CanonicalRecord(
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
                    PRIMARY KEY (session_id, canonical_id)
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
}
