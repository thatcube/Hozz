package com.thatcube.hozz.core

import android.content.ContentValues
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.time.Instant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SqliteCanonicalRecordStoreTest {
    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val databaseName = "hozz-archive-test.sqlite"
    private lateinit var store: SqliteCanonicalRecordStore

    @Before
    fun setUp() {
        context.deleteDatabase(databaseName)
        store = SqliteCanonicalRecordStore(context, databaseName)
    }

    @After
    fun tearDown() {
        store.close()
        context.deleteDatabase(databaseName)
    }

    @Test
    fun duplicateAndOlderVersionsCannotReplaceCurrentRecord() = runBlocking {
        val versionOne = record(version = 1, tombstone = false)
        val versionTwo = record(version = 2, tombstone = true)
        val child = record(version = 1, tombstone = false).copy(
            canonicalId = "apple.healthkit:test-record:detail",
            parentCanonicalId = versionOne.canonicalId,
            kind = "quantitySeriesReadings",
            canonicalType = "series.readings",
        )

        assertEquals(2, store.upsert(listOf(versionOne, child)).inserted)
        assertEquals(1, store.upsert(listOf(versionOne)).ignored)
        assertEquals(1, store.upsert(listOf(versionTwo)).updated)
        assertEquals(1, store.upsert(listOf(versionOne)).ignored)

        val stored = store.allRecords()
        assertEquals(2, stored.size)
        assertTrue(stored.all(CanonicalRecord::tombstone))
        assertTrue(stored.all { it.recordVersion == 2L })
        assertTrue(store.timeline().isEmpty())
    }

    @Test
    fun malformedArchiveDoesNotCommitEarlierBatches() = runBlocking {
        val valid =
            """
            {"endDate":"2026-01-01T00:01:00Z","id":"record-1","kind":"quantity","quantity":{"unit":"count","value":1},"schemaVersion":1,"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent()
        var failed = false

        try {
            ArchiveImporter(store, batchSize = 1).import(
                ByteArrayInputStream("$valid\nnot-json\n".toByteArray()),
            )
        } catch (_: ArchiveFormatException) {
            failed = true
        }

        assertTrue(failed)
        assertTrue(store.allRecords().isEmpty())
    }

    @Test
    fun secondStoreInstanceCannotEraseActiveImportStaging() = runBlocking {
        val session = store.beginImport()
        val staged = record(version = 1, tombstone = false)
        session.append(listOf(staged))
        val second = SqliteCanonicalRecordStore(context, databaseName)
        try {
            assertEquals(0, second.recordCount())
            session.commit()
            assertEquals(listOf(staged), second.allRecords())
        } finally {
            second.close()
        }
    }

    @Test
    fun concurrentImportSessionsRemainIsolated() = runBlocking {
        val firstSession = store.beginImport()
        val firstRecord = record(version = 1, tombstone = false)
        firstSession.append(listOf(firstRecord))
        val secondStore = SqliteCanonicalRecordStore(context, databaseName)
        val secondSession = secondStore.beginImport()
        val secondRecord = firstRecord.copy(
            canonicalId = "apple.healthkit:second-session",
            sourceRecordId = "second-session",
            lineage = listOf(
                SourceLineage("apple.healthkit", recordId = "second-session"),
            ),
        )
        try {
            secondSession.append(listOf(secondRecord))
            firstSession.discard()
            secondSession.commit()

            assertEquals(listOf(secondRecord), store.allRecords())
        } finally {
            secondStore.close()
        }
    }

    @Test
    fun closingOwnerReapsOnlyItsUncommittedTemporaryStaging() = runBlocking {
        val session = store.beginImport()
        session.append(listOf(record(version = 1, tombstone = false)))
        store.close()
        var commitFailed = false
        try {
            session.commit()
        } catch (_: IllegalStateException) {
            commitFailed = true
        } catch (_: android.database.sqlite.SQLiteException) {
            commitFailed = true
        }
        assertTrue(commitFailed)

        store = SqliteCanonicalRecordStore(context, databaseName)
        assertTrue(store.allRecords().isEmpty())
    }

    @Test
    fun exportUsesOneSnapshotAcrossDigestManifestAndPayload() = runBlocking {
        val first = record(version = 1, tombstone = false)
        val second = first.copy(
            canonicalId = "apple.healthkit:second",
            sourceRecordId = "second",
            lineage = listOf(
                SourceLineage("apple.healthkit", recordId = "second"),
            ),
        )
        store.upsert(listOf(first))
        val writer = SqliteCanonicalRecordStore(context, databaseName)
        val output = ByteArrayOutputStream()
        val writing = CountDownLatch(1)
        val continueWriting = CountDownLatch(1)
        val blocked = object : OutputStream() {
            private var firstWrite = true

            override fun write(value: Int) {
                if (firstWrite) {
                    firstWrite = false
                    writing.countDown()
                    check(continueWriting.await(10, TimeUnit.SECONDS))
                }
                output.write(value)
            }

            override fun write(buffer: ByteArray, offset: Int, length: Int) {
                for (index in offset until offset + length) {
                    write(buffer[index].toInt())
                }
            }
        }
        try {
            val export = async(Dispatchers.IO) {
                CanonicalArchiveExporter(store).export(blocked)
            }
            assertTrue(writing.await(10, TimeUnit.SECONDS))
            val concurrentWrite = async(Dispatchers.IO) {
                writer.upsert(listOf(second))
            }
            continueWriting.countDown()
            val result = export.await()
            concurrentWrite.await()

            val imported = InMemoryCanonicalRecordStore()
            val importResult = ArchiveImporter(imported).import(
                ByteArrayInputStream(output.toByteArray()),
            )
            assertEquals(1, result.recordCount)
            assertEquals(1, importResult.recordsRead)
            assertEquals(1, imported.recordCount())
            assertEquals(2, writer.recordCount())
        } finally {
            continueWriting.countDown()
            writer.close()
        }
    }

    @Test
    fun cursorWindowSafeRecordBoundAcceptsBelowAndRejectsAbove() = runBlocking {
        val under = """
            {"endDate":"2026-01-01T00:01:00Z","id":"under","kind":"quantity","padding":"${"x".repeat(400 * 1_024)}","quantity":{"unit":"count","value":1},"schemaVersion":1,"startDate":"2026-01-01T00:00:00Z","type":"steps"}
        """.trimIndent()
        ArchiveImporter(store).import(
            ByteArrayInputStream("$under\n".toByteArray()),
        )
        assertEquals(1, store.allRecords().size)

        val over = """
            {"endDate":"2026-01-01T00:01:00Z","id":"over","kind":"quantity","padding":"${"x".repeat(520 * 1_024)}","quantity":{"unit":"count","value":1},"schemaVersion":1,"startDate":"2026-01-01T00:00:00Z","type":"steps"}
        """.trimIndent()
        var rejected = false
        try {
            ArchiveImporter(store).import(
                ByteArrayInputStream("$over\n".toByteArray()),
            )
        } catch (_: ArchiveFormatException) {
            rejected = true
        }
        assertTrue(rejected)
        assertEquals(1, store.allRecords().size)
    }

    @Test
    fun largeRowsTraverseInByteBoundedPagesAndRoundTrip() = runBlocking {
        val padding = "x".repeat(400 * 1_024)
        val lines = (1..16).map { index ->
            """
            {"endDate":"2026-01-01T00:01:00Z","id":"large-$index","kind":"quantity","padding":"$padding","quantity":{"unit":"count","value":$index},"schemaVersion":1,"startDate":"2026-01-01T00:00:00Z","type":"steps"}
            """.trimIndent()
        }
        ArchiveImporter(store).import(
            ByteArrayInputStream(
                lines.joinToString("\n", postfix = "\n").toByteArray(),
            ),
        )
        val seen = mutableListOf<String>()
        var after: String? = null
        while (true) {
            val page = store.recordsPage(after, 500)
            if (page.isEmpty()) break
            assertTrue(page.sumOf { it.rawJson.toByteArray().size } <= 512 * 1_024)
            seen += page.map(CanonicalRecord::canonicalId)
            after = page.last().canonicalId
        }
        assertEquals(16, seen.size)
        assertEquals(seen.sorted(), seen)

        val timelineSeen = mutableSetOf<String>()
        var timelineCursor: TimelineCursor? = null
        while (true) {
            val page = store.timelinePage(timelineCursor, 200)
            if (page.records.isEmpty()) break
            assertTrue(
                page.records.sumOf { it.rawJson.toByteArray().size } <=
                    512 * 1_024,
            )
            timelineSeen += page.records.map(CanonicalRecord::canonicalId)
            timelineCursor = page.nextCursor
        }
        assertEquals(16, timelineSeen.size)

        val output = ByteArrayOutputStream()
        CanonicalArchiveExporter(store).export(output)
        val restored = InMemoryCanonicalRecordStore()
        ArchiveImporter(restored).import(
            ByteArrayInputStream(output.toByteArray()),
        )
        assertEquals(16, restored.recordCount())
    }

    @Test
    fun staleParentTombstoneDoesNotCascade() = runBlocking {
        val parent = record(version = 3, tombstone = false)
        val child = parent.copy(
            canonicalId = "apple.healthkit:test-record:detail",
            parentCanonicalId = parent.canonicalId,
            kind = "quantitySeriesReadings",
            canonicalType = "series.readings",
        )
        val staleTombstone = parent.copy(recordVersion = 2, tombstone = true)

        store.upsert(listOf(parent, child))
        store.upsert(listOf(staleTombstone))

        assertTrue(store.allRecords().none(CanonicalRecord::tombstone))
    }

    @Test
    fun ignoredLateZipBombRollsBackCanonicalAndRunStaging() = runBlocking {
        val seed = record(version = 1, tombstone = false)
        store.upsert(listOf(seed))
        val manifest =
            """
            {"archiveId":"fixture","createdAt":"2026-01-01T00:00:00Z","format":"hozz-ndjson","recordCount":1,"recordSchema":"hozz/v1/canonical-record","recordsEntry":"records.ndjson","schemaVersion":1}
            """.trimIndent().toByteArray()
        val records =
            """
            {"kind":"typeError","message":"fixture","schemaVersion":1,"type":"heart"}
            {"canonicalId":"apple.healthkit:new","canonicalType":"activity.steps","endDate":"2026-01-01T00:01:00Z","id":"new","kind":"quantity","lineage":[{"recordId":"new","store":"apple.healthkit"}],"quantity":{"unit":"count","value":1},"recordVersion":1,"schemaVersion":1,"sourceRecord":{"id":"new","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent().toByteArray()
        val zip = ByteArrayOutputStream().also { output ->
            ZipOutputStream(output).use { archive ->
                for ((name, bytes) in listOf(
                    ArchiveManifest.ENTRY_NAME to manifest,
                    "records.ndjson" to records,
                    "ignored.bin" to ByteArray(32 * 1_024) { 0 },
                )) {
                    archive.putNextEntry(ZipEntry(name))
                    archive.write(bytes)
                    archive.closeEntry()
                }
            }
        }.toByteArray()
        var failed = false

        try {
            ArchiveImporter(
                store,
                batchSize = 1,
                limits = ArchiveImportLimits(
                    maxInflatedBytes = 1_000_000,
                    maxEntryCompressionRatio = 2,
                    maxGlobalCompressionRatio = 1_000,
                    entryRatioSlackBytes = 0,
                    globalRatioSlackBytes = 1_000_000,
                ),
            ).import(ByteArrayInputStream(zip))
        } catch (_: ArchiveFormatException) {
            failed = true
        }

        assertTrue(failed)
        assertEquals(listOf(seed), store.allRecords())
        assertTrue(store.runRecordsPage(null, 100).isEmpty())
        store.close()
        store = SqliteCanonicalRecordStore(context, databaseName)
        assertEquals(listOf(seed), store.allRecords())
        assertTrue(store.runRecordsPage(null, 100).isEmpty())
    }

    @Test
    fun healthConnectLedgerIsMonotonicPersistentAndConditionallyRemoved() =
        runBlocking {
            val first = HealthConnectProjection(
                canonicalId = "apple.healthkit:weight",
                targetRecord = "WeightRecord",
                canonicalVersion = 1,
                healthConnectRecordId = "health-1",
            )
            store.saveHealthConnectProjections(listOf(first))
            store.saveHealthConnectProjections(
                listOf(first.copy(canonicalVersion = 0, healthConnectRecordId = "stale")),
            )
            assertEquals(
                first,
                store.healthConnectProjections(setOf(first.canonicalId))
                    .getValue(first.canonicalId),
            )

            val second = first.copy(
                canonicalVersion = 2,
                healthConnectRecordId = "health-2",
            )
            store.saveHealthConnectProjections(listOf(second))
            store.close()
            store = SqliteCanonicalRecordStore(context, databaseName)
            assertEquals(
                second,
                store.healthConnectProjections(setOf(second.canonicalId))
                    .getValue(second.canonicalId),
            )

            store.removeHealthConnectProjections(listOf(first))
            assertEquals(
                second,
                store.healthConnectProjections(setOf(second.canonicalId))
                    .getValue(second.canonicalId),
            )
            store.removeHealthConnectProjections(listOf(second))
            assertTrue(
                store.healthConnectProjections(setOf(second.canonicalId)).isEmpty(),
            )
        }

    @Test
    fun runRecordsPersistWithoutDuplicatingOnReplay() = runBlocking {
        val line =
            """
            { "kind" : "typeError", "schemaVersion" : 1, "type" : "heart", "message" : "fixture" }
            """.trimIndent()
        val importer = ArchiveImporter(store)

        importer.import(ByteArrayInputStream("$line\n".toByteArray()))
        importer.import(ByteArrayInputStream("$line\n".toByteArray()))
        store.close()
        store = SqliteCanonicalRecordStore(context, databaseName)

        val records = store.runRecordsPage(null, 100)
        assertEquals(1, records.size)
        assertEquals(line, records.single().rawJson)
    }

    @Test
    fun stagedSuccessResolvesEncodingErrorRegardlessOfCanonicalSortOrder() =
        runBlocking {
            val parent = record(version = 1, tombstone = false).copy(
                canonicalId = "apple.healthkit:000-parent",
                sourceRecordId = "000-parent",
            )
            val error = parent.copy(
                canonicalId = "apple.healthkit:zzz-error",
                parentCanonicalId = parent.canonicalId,
                kind = "sampleEncodingError",
                canonicalType = "archive.encoding-error",
                rawJson = """{"kind":"sampleEncodingError"}""",
            )
            val session = store.beginImport()
            session.append(listOf(parent, error))

            session.commit()

            val stored = store.allRecords().associateBy(CanonicalRecord::canonicalId)
            assertTrue(stored.getValue(error.canonicalId).tombstone)
            assertTrue(!stored.getValue(parent.canonicalId).tombstone)
        }

    @Test
    fun continuationErrorRequiresEndMarkerButParentDeletionStillWins() =
        runBlocking {
            val sourceId = "00000000-0000-0000-0000-000000000123"
            val endId = CanonicalRecordParser.seriesEndId(
                sourceId,
                "HKWorkoutRouteTypeIdentifier",
            )
            val errorId = CanonicalRecordParser.encodingFailureId(
                sourceId,
                "HKWorkoutRouteTypeIdentifier",
            )
            val parent = record(version = 1, tombstone = false).copy(
                canonicalId = "apple.healthkit:$sourceId",
                sourceRecordId = sourceId,
                kind = "workoutRoute",
                canonicalType = "activity.exercise-route",
                type = "HKWorkoutRouteTypeIdentifier",
                lineage = listOf(
                    SourceLineage("apple.healthkit", recordId = sourceId),
                ),
                rawJson =
                    """{"endDate":"2026-01-01T00:01:00Z","startDate":"2026-01-01T00:00:00Z"}""",
            )
            val error = parent.copy(
                canonicalId = "apple.healthkit:$errorId",
                parentCanonicalId = parent.canonicalId,
                resolutionCanonicalId = "apple.healthkit:$endId",
                recordVersion = 3,
                kind = "sampleEncodingError",
                canonicalType = "archive.encoding-error",
                rawJson = """{"kind":"sampleEncodingError"}""",
            )
            val end = parent.copy(
                canonicalId = "apple.healthkit:$endId",
                parentCanonicalId = parent.canonicalId,
                kind = "workoutRouteEnd",
                canonicalType = "activity.exercise-route-end",
            )

            store.upsert(listOf(parent, error))
            assertTrue(
                !store.allRecords()
                    .single { it.canonicalId == error.canonicalId }
                    .tombstone,
            )
            store.upsert(listOf(end))
            assertTrue(
                store.allRecords()
                    .single { it.canonicalId == error.canonicalId }
                    .tombstone,
            )

            store.close()
            context.deleteDatabase(databaseName)
            store = SqliteCanonicalRecordStore(context, databaseName)
            val session = store.beginImport()
            session.append(listOf(parent, error.copy(tombstone = true)))
            session.commit()
            assertTrue(
                !store.allRecords()
                    .single { it.canonicalId == error.canonicalId }
                    .tombstone,
            )

            store.close()
            context.deleteDatabase(databaseName)
            store = SqliteCanonicalRecordStore(context, databaseName)
            store.upsert(listOf(parent, error))
            store.upsert(
                listOf(
                    parent.copy(
                        kind = "deletion",
                        recordVersion = 2,
                        tombstone = true,
                    ),
                ),
            )
            assertTrue(store.allRecords().all(CanonicalRecord::tombstone))
        }

    @Test
    fun databaseUpgradeReconcilesAnExistingLiveEncodingError() = runBlocking {
        val parent = record(version = 1, tombstone = false).copy(
            canonicalId = "apple.healthkit:upgrade-parent",
            sourceRecordId = "upgrade-parent",
        )
        val error = parent.copy(
            canonicalId = "apple.healthkit:upgrade-error",
            parentCanonicalId = parent.canonicalId,
            kind = "sampleEncodingError",
            canonicalType = "archive.encoding-error",
            rawJson = """{"kind":"sampleEncodingError"}""",
        )
        store.upsert(listOf(error))
        store.close()
        context.openOrCreateDatabase(databaseName, 0, null).use { database ->
            database.insertOrThrow(
                "canonical_record",
                null,
                ContentValues().apply {
                    put("canonical_id", parent.canonicalId)
                    put("record_version", parent.recordVersion)
                    put("kind", parent.kind)
                    put("canonical_type", parent.canonicalType)
                    put("type", parent.type)
                    put("source_record_id", parent.sourceRecordId)
                    put("source_store", parent.sourceStore)
                    put("lineage_json", """[{"store":"apple.healthkit"}]""")
                    put("tombstone", 0)
                    put("raw_json", parent.rawJson)
                },
            )
            database.version = 7
        }

        store = SqliteCanonicalRecordStore(context, databaseName)

        val upgraded = store.allRecords()
            .associateBy(CanonicalRecord::canonicalId)
        assertTrue(upgraded.getValue(error.canonicalId).tombstone)
        assertTrue(!upgraded.getValue(parent.canonicalId).tombstone)
    }

    @Test
    fun databaseUpgradeRestoresContinuationErrorHiddenByOldConsumer() =
        runBlocking {
            val sourceId = "00000000-0000-0000-0000-000000000126"
            val endId = CanonicalRecordParser.seriesEndId(
                sourceId,
                "HKWorkoutRouteTypeIdentifier",
            )
            val errorId = CanonicalRecordParser.encodingFailureId(
                sourceId,
                "HKWorkoutRouteTypeIdentifier",
            )
            val parent = record(version = 1, tombstone = false).copy(
                canonicalId = "apple.healthkit:$sourceId",
                sourceRecordId = sourceId,
                kind = "workoutRoute",
                canonicalType = "activity.exercise-route",
                type = "HKWorkoutRouteTypeIdentifier",
                lineage = listOf(
                    SourceLineage("apple.healthkit", recordId = sourceId),
                ),
                rawJson =
                    """{"endDate":"2026-01-01T00:01:00Z","startDate":"2026-01-01T00:00:00Z"}""",
            )
            val error = CanonicalRecordParser.parse(
                """
                {"canonicalId":"apple.healthkit:$errorId","canonicalType":"archive.encoding-error","id":"$errorId","kind":"sampleEncodingError","lineage":[{"recordId":"$sourceId","store":"apple.healthkit"}],"message":"continuation failed","parentCanonicalId":"apple.healthkit:$sourceId","recordVersion":3,"resolutionCanonicalId":"apple.healthkit:$endId","schemaVersion":1,"sourceRecord":{"id":"$sourceId","store":"apple.healthkit","type":"HKWorkoutRouteTypeIdentifier"},"type":"HKWorkoutRouteTypeIdentifier"}
                """.trimIndent(),
                strictV1 = true,
            )!!
            store.upsert(listOf(parent, error))
            store.close()
            context.openOrCreateDatabase(databaseName, 0, null).use { database ->
                database.execSQL(
                    """
                    UPDATE canonical_record
                    SET resolution_canonical_id = NULL,
                        record_version = 4,
                        tombstone = 1,
                        raw_json = ?
                    WHERE canonical_id = ?
                    """.trimIndent(),
                    arrayOf(
                        error.rawJson.replace(
                            "\"kind\":",
                            "\"deleted\":true,\"kind\":",
                        ),
                        error.canonicalId,
                    ),
                )
                database.version = 8
            }

            store = SqliteCanonicalRecordStore(context, databaseName)

            val restored = store.allRecords()
                .single { it.canonicalId == error.canonicalId }
            assertTrue(!restored.tombstone)
            assertTrue(restored.recordVersion > 4)
            assertEquals(error.resolutionCanonicalId, restored.resolutionCanonicalId)

            val output = ByteArrayOutputStream()
            CanonicalArchiveExporter(store).export(output)
            val roundTrip = InMemoryCanonicalRecordStore()
            ArchiveImporter(roundTrip).import(
                ByteArrayInputStream(output.toByteArray()),
            )
            assertTrue(
                !roundTrip.allRecords()
                    .single { it.canonicalId == error.canonicalId }
                    .tombstone,
            )
        }

    private fun record(
        version: Long,
        tombstone: Boolean,
    ): CanonicalRecord = CanonicalRecord(
        canonicalId = "apple.healthkit:test-record",
        parentCanonicalId = null,
        recordVersion = version,
        kind = if (tombstone) "deletion" else "quantity",
        canonicalType = "activity.steps",
        type = "HKQuantityTypeIdentifierStepCount",
        startTime = if (tombstone) null else Instant.parse("2026-01-01T00:00:00Z"),
        endTime = if (tombstone) null else Instant.parse("2026-01-01T00:01:00Z"),
        canonicalValue = if (tombstone) null else CanonicalValue(1.0, "count"),
        originalValue = if (tombstone) null else CanonicalValue(1.0, "count"),
        categoryValue = null,
        activityType = null,
        quantityCount = if (tombstone) null else 1,
        sourceRecordId = "test-record",
        sourceRecordVersion = version,
        sourceStore = "apple.healthkit",
        sourceBundleIdentifier = "com.example.fixture",
        sourceName = "Fixture",
        deviceJson = "{}",
        metadataJson = "{}",
        lineage = listOf(
            SourceLineage("apple.healthkit", recordId = "test-record"),
        ),
        tombstone = tombstone,
        rawJson = "{}",
    )
}
