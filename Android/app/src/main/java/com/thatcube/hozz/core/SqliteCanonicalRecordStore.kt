package com.thatcube.hozz.core

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.time.Instant
import java.util.UUID

class SqliteCanonicalRecordStore(
    context: Context,
    databaseName: String = "hozz-archive.sqlite",
) :
    SQLiteOpenHelper(context, databaseName, null, 5),
    CanonicalRecordStore {

    override fun onCreate(database: SQLiteDatabase) {
        database.execSQL(
            """
            CREATE TABLE canonical_record (
                canonical_id TEXT PRIMARY KEY,
                parent_canonical_id TEXT,
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
        createStageTable(database)
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
    }

    override fun onOpen(database: SQLiteDatabase) {
        super.onOpen(database)
        database.delete("canonical_record_stage", null, null)
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
        val sessionId = UUID.randomUUID().toString()
        return object : CanonicalImportSession {
            private var finished = false

            override suspend fun append(records: List<CanonicalRecord>) {
                check(!finished)
                val database = writableDatabase
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
                    database.setTransactionSuccessful()
                } finally {
                    database.endTransaction()
                }
            }

            override suspend fun commit(): MergeResult {
                check(!finished)
                val database = writableDatabase
                database.beginTransaction()
                try {
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
                    database.delete(
                        "canonical_record_stage",
                        "session_id = ?",
                        arrayOf(sessionId),
                    )
                    database.setTransactionSuccessful()
                    finished = true
                    return result
                } finally {
                    database.endTransaction()
                }
            }

            override suspend fun discard() {
                if (!finished) {
                    writableDatabase.delete(
                        "canonical_record_stage",
                        "session_id = ?",
                        arrayOf(sessionId),
                    )
                    finished = true
                }
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
    ): List<CanonicalRecord> =
        readableDatabase.query(
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

    private fun mergeIntoCanonical(
        database: SQLiteDatabase,
        records: List<CanonicalRecord>,
    ): MergeResult {
        var result = MergeResult()
        for (record in records) {
            result += mergeOne(database, record)
        }
        return result
    }

    private fun mergeOne(
        database: SQLiteDatabase,
        record: CanonicalRecord,
    ): MergeResult {
        val effective = record.parentCanonicalId
            ?.let { parentState(database, it) }
            ?.takeIf { it.second }
            ?.let { (parentVersion, _) ->
                record.copy(
                    recordVersion = maxOf(record.recordVersion, parentVersion),
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
        if (winningParent?.second == true) {
            database.execSQL(
                """
                UPDATE canonical_record
                SET tombstone = 1,
                    record_version = MAX(record_version, ?)
                WHERE parent_canonical_id = ?
                """.trimIndent(),
                arrayOf<Any>(winningParent.first, effective.canonicalId),
            )
        }
        return result
    }

    private fun parentState(
        database: SQLiteDatabase,
        canonicalId: String,
    ): Pair<Long, Boolean>? = database.query(
        "canonical_record",
        arrayOf("record_version", "tombstone"),
        "canonical_id = ?",
        arrayOf(canonicalId),
        null,
        null,
        null,
    ).use { cursor ->
        if (cursor.moveToFirst()) {
            cursor.getLong(0) to (cursor.getInt(1) != 0)
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

    private fun values(record: CanonicalRecord): ContentValues = ContentValues().apply {
        put("canonical_id", record.canonicalId)
        put("parent_canonical_id", record.parentCanonicalId)
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
    }
}
