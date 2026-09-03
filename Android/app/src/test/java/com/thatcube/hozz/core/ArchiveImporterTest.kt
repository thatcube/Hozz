package com.thatcube.hozz.core

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import com.thatcube.hozz.projection.ProjectionPlanner
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ArchiveImporterTest {
    private val fixture: ByteArray
        get() = requireNotNull(
            javaClass.getResourceAsStream("/hozz/v1/fixtures/canonical-records.ndjson"),
        ).use { it.readBytes() }

    @Test
    fun importingSameLegacyArchiveTwiceDoesNotDuplicateRecords() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val importer = ArchiveImporter(store, batchSize = 1)

        val first = importer.import(ByteArrayInputStream(fixture))
        val second = importer.import(ByteArrayInputStream(fixture))

        assertTrue(first.legacyArchive)
        assertEquals(3, first.merge.inserted)
        assertEquals(0, first.merge.ignored)
        assertEquals(0, second.merge.inserted)
        assertEquals(3, second.merge.ignored)
        assertEquals(3, store.allRecords().size)
    }

    @Test
    fun legacyAndVersionedAppleRecordsShareCanonicalIdentity() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val importer = ArchiveImporter(store)
        val legacy =
            """
            {"endDate":"2026-01-01T00:01:00Z","id":"same-record","kind":"quantity","quantity":{"unit":"count","value":1},"schemaVersion":1,"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent()
        val versioned =
            """
            {"canonicalId":"apple.healthkit:same-record","canonicalType":"activity.steps","endDate":"2026-01-01T00:01:00Z","id":"same-record","kind":"quantity","quantity":{"canonical":{"unit":"count","value":1},"unit":"count","value":1},"recordVersion":1,"schemaVersion":1,"sourceRecord":{"id":"same-record","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent()

        val first = importer.import(ByteArrayInputStream("$legacy\n".toByteArray()))
        val second = importer.import(ByteArrayInputStream("$versioned\n".toByteArray()))

        assertEquals(1, first.merge.inserted)
        assertEquals(1, second.merge.ignored)
        assertEquals("apple.healthkit:same-record", store.allRecords().single().canonicalId)
    }

    @Test
    fun versionedZipManifestSelectsItsNamedRecordStream() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val manifest =
            """
            {
              "schemaVersion": 1,
              "archiveId": "fixture",
              "format": "hozz-ndjson",
              "recordSchema": "hozz/v1/canonical-record",
              "recordsEntry": "records.ndjson",
              "createdAt": "2026-01-01T00:00:00Z",
              "recordCount": 3
            }
            """.trimIndent().toByteArray()
        val zip = ByteArrayOutputStream().also { output ->
            ZipOutputStream(output).use { archive ->
                archive.putNextEntry(ZipEntry(ArchiveManifest.ENTRY_NAME))
                archive.write(manifest)
                archive.closeEntry()
                archive.putNextEntry(ZipEntry("records.ndjson"))
                archive.write(fixture)
                archive.closeEntry()
            }
        }.toByteArray()

        val result = ArchiveImporter(store).import(ByteArrayInputStream(zip))

        assertFalse(result.legacyArchive)
        assertNotNull(result.manifest)
        assertEquals("records.ndjson", result.manifest?.recordsEntry)
        assertEquals(3, result.recordsRead)
        assertEquals(3, store.allRecords().size)
    }

    @Test
    fun exportedCanonicalArchiveRoundTripsWithoutLosingUnknownFields() = runBlocking {
        val sourceStore = InMemoryCanonicalRecordStore()
        ArchiveImporter(sourceStore).import(ByteArrayInputStream(fixture))
        val tombstone = CanonicalRecordParser.parse(
            """
            {"canonicalId":"apple.healthkit:removed","canonicalType":"activity.steps","id":"removed","kind":"deletion","recordVersion":2,"schemaVersion":1,"sourceRecord":{"id":"removed","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent(),
        )!!
        sourceStore.upsert(listOf(tombstone))
        val firstOutput = ByteArrayOutputStream()
        val secondOutput = ByteArrayOutputStream()

        val exporter = CanonicalArchiveExporter(sourceStore)
        val exported = exporter.export(firstOutput)
        exporter.export(secondOutput)
        val targetStore = InMemoryCanonicalRecordStore()
        val imported = ArchiveImporter(targetStore).import(
            ByteArrayInputStream(firstOutput.toByteArray()),
        )
        val replay = ArchiveImporter(targetStore).import(
            ByteArrayInputStream(firstOutput.toByteArray()),
        )

        assertEquals(4, exported.recordCount)
        assertTrue(firstOutput.toByteArray().contentEquals(secondOutput.toByteArray()))
        assertFalse(imported.legacyArchive)
        assertEquals(4, imported.merge.inserted)
        assertEquals(4, replay.merge.ignored)
        val records = targetStore.allRecords()
        assertEquals(4, records.size)
        assertTrue(records.all { it.rawJson.contains("\"canonicalType\"") })
        assertTrue(records.any { it.rawJson.contains("\"averageHeartRate\":0") })
        assertTrue(records.any { it.rawJson.contains("\"vendorExtension\":\"kept\"") })
        assertTrue(records.any { it.rawJson.contains("\"sourceLabel\":\"kept\"") })
        assertTrue(records.any { it.rawJson.contains("\"scale\":\"kept\"") })
        assertTrue(records.any { it.rawJson.contains("\"native\":\"kept\"") })
        assertTrue(records.any(CanonicalRecord::tombstone))
        assertEquals(
            ProjectionPlanner.plan(sourceStore.allRecords()).records.map {
                it.quality to it.warnings.map { warning -> warning.code }
            },
            ProjectionPlanner.plan(records).records.map {
                it.quality to it.warnings.map { warning -> warning.code }
            },
        )
    }

    @Test
    fun newerTombstoneReplacesRecordAndReplayIsIdempotent() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val importer = ArchiveImporter(store)
        val live =
            """
            {"canonicalId":"apple.healthkit:record-1","endDate":"2026-01-01T00:01:00Z","id":"record-1","kind":"quantity","quantity":{"unit":"count","value":1},"recordVersion":1,"schemaVersion":1,"sourceRecord":{"id":"record-1","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent()
        val tombstone =
            """
            {"canonicalId":"apple.healthkit:record-1","id":"record-1","kind":"deletion","recordVersion":2,"schemaVersion":1,"sourceRecord":{"id":"record-1","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent()
        val child =
            """
            {"canonicalId":"apple.healthkit:record-1:detail","canonicalType":"series.readings","endDate":"2026-01-01T00:01:00Z","id":"record-1-detail","kind":"quantitySeriesReadings","parentCanonicalId":"apple.healthkit:record-1","recordVersion":1,"sample":"record-1","schemaVersion":1,"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent()

        importer.import(
            ByteArrayInputStream("$live\n$child\n$tombstone\n".toByteArray()),
        )
        val replay = importer.import(
            ByteArrayInputStream("$live\n$child\n$tombstone\n".toByteArray()),
        )

        val stored = store.allRecords()
        assertEquals(2, stored.size)
        assertTrue(stored.all(CanonicalRecord::tombstone))
        assertTrue(stored.all { it.recordVersion == 2L })
        assertEquals(2, replay.merge.ignored)
        assertTrue(store.timeline().isEmpty())
    }

    @Test
    fun malformedLateRecordLeavesNoPartialImport() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val valid = fixture.toString(Charsets.UTF_8).lineSequence().first()

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
    fun versionedArchiveRejectsUndeclaredRecordStreamWithoutMutation() =
        runBlocking {
            val store = InMemoryCanonicalRecordStore()
            val manifest =
                """
                {"archiveId":"fixture","createdAt":"2026-01-01T00:00:00Z","format":"hozz-ndjson","recordSchema":"hozz/v1/canonical-record","recordsEntry":"records.ndjson","schemaVersion":1}
                """.trimIndent().toByteArray()
            val zip = ByteArrayOutputStream().also { output ->
                ZipOutputStream(output).use { archive ->
                    archive.putNextEntry(ZipEntry(ArchiveManifest.ENTRY_NAME))
                    archive.write(manifest)
                    archive.closeEntry()
                    archive.putNextEntry(ZipEntry("undeclared.ndjson"))
                    archive.write(fixture)
                    archive.closeEntry()
                }
            }.toByteArray()

            var failed = false
            try {
                ArchiveImporter(store).import(ByteArrayInputStream(zip))
            } catch (_: ArchiveFormatException) {
                failed = true
            }

            assertTrue(failed)
            assertTrue(store.allRecords().isEmpty())
        }

    @Test
    fun versionedArchiveMayPutManifestAfterItsDeclaredRecordStream() =
        runBlocking {
            val store = InMemoryCanonicalRecordStore()
            val manifest =
                """
                {"archiveId":"fixture","createdAt":"2026-01-01T00:00:00Z","format":"hozz-ndjson","recordCount":3,"recordSchema":"hozz/v1/canonical-record","recordsEntry":"records.ndjson","schemaVersion":1}
                """.trimIndent().toByteArray()
            val zip = ByteArrayOutputStream().also { output ->
                ZipOutputStream(output).use { archive ->
                    archive.putNextEntry(ZipEntry("records.ndjson"))
                    archive.write(fixture)
                    archive.closeEntry()
                    archive.putNextEntry(ZipEntry(ArchiveManifest.ENTRY_NAME))
                    archive.write(manifest)
                    archive.closeEntry()
                }
            }.toByteArray()

            val result = ArchiveImporter(store).import(ByteArrayInputStream(zip))

            assertFalse(result.legacyArchive)
            assertEquals(3, result.merge.inserted)
        }

    @Test
    fun mismatchedManifestRecordCountLeavesNoPartialImport() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val manifest =
            """
            {"archiveId":"fixture","createdAt":"2026-01-01T00:00:00Z","format":"hozz-ndjson","recordCount":4,"recordSchema":"hozz/v1/canonical-record","recordsEntry":"records.ndjson","schemaVersion":1}
            """.trimIndent().toByteArray()
        val zip = ByteArrayOutputStream().also { output ->
            ZipOutputStream(output).use { archive ->
                archive.putNextEntry(ZipEntry(ArchiveManifest.ENTRY_NAME))
                archive.write(manifest)
                archive.closeEntry()
                archive.putNextEntry(ZipEntry("records.ndjson"))
                archive.write(fixture)
                archive.closeEntry()
            }
        }.toByteArray()

        var failed = false
        try {
            ArchiveImporter(store).import(ByteArrayInputStream(zip))
        } catch (_: ArchiveFormatException) {
            failed = true
        }

        assertTrue(failed)
        assertTrue(store.allRecords().isEmpty())
    }

    @Test
    fun sourceRecordsWithoutSampleIdentityArePreservedDeterministically() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val importer = ArchiveImporter(store)
        val characteristics =
            """
            {"catalogVersion":"fixture","characteristics":{},"kind":"characteristics","readAt":"2026-01-01T00:00:00Z","schemaVersion":1}
            """.trimIndent()

        importer.import(ByteArrayInputStream("$characteristics\n".toByteArray()))
        importer.import(ByteArrayInputStream("$characteristics\n".toByteArray()))

        val record = store.allRecords().single()
        assertEquals("apple.healthkit:characteristics", record.canonicalId)
        assertEquals("person.characteristics", record.canonicalType)
        assertEquals(1, store.allRecords().size)
    }

    @Test
    fun reExportKeepsSyntheticRecordIdSeparateFromItsSourceRecordId() {
        val record = CanonicalRecordParser.parse(
            """
            {"canonicalId":"apple.healthkit:synthetic","canonicalType":"series.readings","endDate":"2026-01-01T00:01:00Z","id":"synthetic","kind":"quantitySeriesReadings","lineage":[{"recordId":"source","store":"apple.healthkit"}],"parentCanonicalId":"apple.healthkit:source","recordVersion":1,"sample":"source","schemaVersion":1,"sourceRecord":{"id":"source","store":"apple.healthkit","type":"HKQuantityTypeIdentifierHeartRate","vendorExtension":"kept"},"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierHeartRate"}
            """.trimIndent(),
        )!!
        val exported = CanonicalArchiveExporter(
            InMemoryCanonicalRecordStore(),
        ).canonicalJson(record)
        val jsonObject = Json.parseToJsonElement(exported).jsonObject

        assertEquals("synthetic", jsonObject["id"]!!.jsonPrimitive.content)
        assertEquals(
            "source",
            jsonObject["sourceRecord"]!!
                .jsonObject["id"]!!
                .jsonPrimitive
                .content,
        )
        assertEquals(
            "kept",
            jsonObject["sourceRecord"]!!
                .jsonObject["vendorExtension"]!!
                .jsonPrimitive
                .content,
        )
    }
}
