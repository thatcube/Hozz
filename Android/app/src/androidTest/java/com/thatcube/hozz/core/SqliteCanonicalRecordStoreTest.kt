package com.thatcube.hozz.core

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.ByteArrayInputStream
import java.time.Instant
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
