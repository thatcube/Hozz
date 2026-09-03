package com.thatcube.hozz.core

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import com.thatcube.hozz.generated.GeneratedContract
import com.thatcube.hozz.projection.ProjectionPlanner
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
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
        val sourceId = "00000000-0000-0000-0000-000000000201"
        val childId = CanonicalRecordParser.seriesRecordId(
            sourceId,
            "HKQuantityTypeIdentifierStepCount",
            "readings-0",
        )
        val live =
            """
            {"canonicalId":"apple.healthkit:$sourceId","endDate":"2026-01-01T00:01:00Z","id":"$sourceId","kind":"quantity","quantity":{"unit":"count","value":1},"recordVersion":1,"schemaVersion":1,"sourceRecord":{"id":"$sourceId","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent()
        val tombstone =
            """
            {"canonicalId":"apple.healthkit:$sourceId","id":"$sourceId","kind":"deletion","recordVersion":2,"schemaVersion":1,"sourceRecord":{"id":"$sourceId","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent()
        val child =
            """
            {"canonicalId":"apple.healthkit:$childId","canonicalType":"series.readings","endDate":"2026-01-01T00:01:00Z","id":"$childId","kind":"quantitySeriesReadings","parentCanonicalId":"apple.healthkit:$sourceId","recordVersion":1,"sample":"$sourceId","schemaVersion":1,"sequence":0,"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}
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
    fun staleParentTombstoneCannotDeleteNewerChildren() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val sourceId = "00000000-0000-0000-0000-000000000202"
        val childId = CanonicalRecordParser.seriesRecordId(
            sourceId,
            "HKQuantityTypeIdentifierStepCount",
            "readings-0",
        )
        val liveParent = CanonicalRecordParser.parse(
            """
            {"canonicalId":"apple.healthkit:$sourceId","canonicalType":"activity.steps","endDate":"2026-01-01T00:01:00Z","id":"$sourceId","kind":"quantity","quantity":{"unit":"count","value":1},"recordVersion":3,"schemaVersion":1,"sourceRecord":{"id":"$sourceId","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent(),
        )!!
        val child = CanonicalRecordParser.parse(
            """
            {"canonicalId":"apple.healthkit:$childId","canonicalType":"series.readings","endDate":"2026-01-01T00:01:00Z","id":"$childId","kind":"quantitySeriesReadings","parentCanonicalId":"apple.healthkit:$sourceId","recordVersion":3,"sample":"$sourceId","schemaVersion":1,"sequence":0,"sourceRecord":{"id":"$sourceId","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent(),
        )!!
        val staleTombstone = CanonicalRecordParser.parse(
            """
            {"canonicalId":"apple.healthkit:$sourceId","canonicalType":"activity.steps","id":"$sourceId","kind":"deletion","recordVersion":2,"schemaVersion":1,"sourceRecord":{"id":"$sourceId","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent(),
        )!!

        store.upsert(listOf(liveParent, child))
        store.upsert(listOf(staleTombstone))

        assertTrue(store.allRecords().none(CanonicalRecord::tombstone))
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
    fun nonIntegerManifestRecordCountIsRejected() {
        for (invalid in listOf("3.5", "\"3\"", "-1")) {
            var failed = false
            try {
                ArchiveManifest.parse(
                    """
                    {"archiveId":"fixture","createdAt":"2026-01-01T00:00:00Z","format":"hozz-ndjson","recordCount":$invalid,"recordSchema":"hozz/v1/canonical-record","recordsEntry":"records.ndjson","schemaVersion":1}
                    """.trimIndent(),
                )
            } catch (_: ArchiveFormatException) {
                failed = true
            }
            assertTrue(invalid, failed)
        }
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
        val sourceId = "00000000-0000-0000-0000-000000000203"
        val syntheticId = CanonicalRecordParser.seriesRecordId(
            sourceId,
            "HKQuantityTypeIdentifierHeartRate",
            "readings-0",
        )
        val record = CanonicalRecordParser.parse(
            """
            {"canonicalId":"apple.healthkit:$syntheticId","canonicalType":"series.readings","endDate":"2026-01-01T00:01:00Z","id":"$syntheticId","kind":"quantitySeriesReadings","lineage":[{"recordId":"$sourceId","store":"apple.healthkit"}],"parentCanonicalId":"apple.healthkit:$sourceId","recordVersion":1,"sample":"$sourceId","schemaVersion":1,"sequence":0,"sourceRecord":{"id":"$sourceId","store":"apple.healthkit","type":"HKQuantityTypeIdentifierHeartRate","vendorExtension":"kept"},"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierHeartRate"}
            """.trimIndent(),
        )!!
        val exported = CanonicalArchiveExporter(
            InMemoryCanonicalRecordStore(),
        ).canonicalJson(record)
        val jsonObject = Json.parseToJsonElement(exported).jsonObject

        assertEquals(syntheticId, jsonObject["id"]!!.jsonPrimitive.content)
        assertEquals(
            sourceId,
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

    @Test
    fun encodingFailureIdentityMatchesCrossPlatformFixture() {
        val fixture = requireNotNull(
            javaClass.getResourceAsStream("/hozz/v1/fixtures/identity-vectors.json"),
        ).use { it.readBytes() }.toString(Charsets.UTF_8)
        val vector = Json.parseToJsonElement(fixture)
            .jsonObject["encodingFailure"]!!
            .jsonObject
        val sourceId = vector["sourceRecordId"]!!.jsonPrimitive.content
        val sourceType = vector["sourceType"]!!.jsonPrimitive.content
        val errorId = vector["recordId"]!!.jsonPrimitive.content

        assertEquals(
            vector["recordId"]!!.jsonPrimitive.content,
            CanonicalRecordParser.encodingFailureId(sourceId, sourceType),
        )
        val legacyError = CanonicalRecordParser.parse(
            """
            {"id":"$errorId","kind":"sampleEncodingError","message":"fixture","parentCanonicalId":"apple.healthkit:$sourceId","schemaVersion":1,"sourceRecord":{"id":"$sourceId","store":"apple.healthkit","type":"$sourceType"},"type":"$sourceType"}
            """.trimIndent(),
        )!!
        assertEquals(
            vector["canonicalId"]!!.jsonPrimitive.content,
            legacyError.canonicalId,
        )
        assertEquals("apple.healthkit:$sourceId", legacyError.parentCanonicalId)
        assertEquals(sourceId, legacyError.sourceRecordId)
    }

    @Test
    fun laterSuccessAndDeletionResolveSyntheticEncodingError() = runBlocking {
        val sourceId = "00000000-0000-0000-0000-0000000000ee"
        val sourceType = "HKQuantityTypeIdentifierStepCount"
        val errorId = CanonicalRecordParser.encodingFailureId(sourceId, sourceType)
        val error =
            """
            {"id":"$errorId","kind":"sampleEncodingError","message":"fixture","parentCanonicalId":"apple.healthkit:$sourceId","schemaVersion":1,"sourceRecord":{"id":"$sourceId","store":"apple.healthkit","type":"$sourceType"},"type":"$sourceType"}
            """.trimIndent()
        val success =
            """
            {"canonicalId":"apple.healthkit:$sourceId","canonicalType":"activity.steps","endDate":"2026-01-01T00:01:00Z","id":"$sourceId","kind":"quantity","lineage":[{"recordId":"$sourceId","store":"apple.healthkit"}],"quantity":{"unit":"count","value":1},"recordVersion":1,"schemaVersion":1,"sourceRecord":{"id":"$sourceId","store":"apple.healthkit","type":"$sourceType"},"startDate":"2026-01-01T00:00:00Z","type":"$sourceType"}
            """.trimIndent()
        val deletion =
            """
            {"canonicalId":"apple.healthkit:$sourceId","canonicalType":"activity.steps","id":"$sourceId","kind":"deletion","lineage":[{"recordId":"$sourceId","store":"apple.healthkit"}],"recordVersion":2,"schemaVersion":1,"sourceRecord":{"id":"$sourceId","store":"apple.healthkit","type":"$sourceType"},"type":"$sourceType"}
            """.trimIndent()

        val successStore = InMemoryCanonicalRecordStore()
        ArchiveImporter(successStore).import(
            ByteArrayInputStream("$error\n$success\n".toByteArray()),
        )
        val successRows = successStore.allRecords()
        assertEquals(2, successRows.size)
        assertEquals(1, successRows.count { !it.tombstone })
        assertTrue(
            successRows.single { it.kind == "sampleEncodingError" }.tombstone,
        )

        val deletionStore = InMemoryCanonicalRecordStore()
        ArchiveImporter(deletionStore).import(
            ByteArrayInputStream("$error\n$deletion\n".toByteArray()),
        )
        assertTrue(deletionStore.allRecords().all(CanonicalRecord::tombstone))
    }

    @Test
    fun runRecordsSurviveDeterministicRoundTripVerbatim() = runBlocking {
        val runLines = listOf(
            """{ "kind" : "manifest", "schemaVersion" : 1, "run" : "r", "createdAt" : "2026-01-01T00:00:00Z" }""",
            """{"kind":"resume","schemaVersion":1,"run":"r","resumedAt":"2026-01-01T00:00:01Z"}""",
            """{"kind":"typeSummary","schemaVersion":1,"type":"steps","state":"authorizationIndeterminate"}""",
            """{"kind":"typeError","schemaVersion":1,"type":"heart","message":"denied"}""",
            """{"kind":"typeCoverage","schemaVersion":1,"type":"steps","state":"anchorClosed","complete":true,"observedAt":"2026-01-01T00:00:01Z"}""",
            """{"kind":"completion","schemaVersion":1,"run":"r","completedAt":"2026-01-01T00:00:02Z","records":3}""",
        )
        val payload = (
            runLines + fixture.toString(Charsets.UTF_8).lineSequence()
        ).joinToString("\n", postfix = "\n").toByteArray()
        val sourceStore = InMemoryCanonicalRecordStore()
        val imported = ArchiveImporter(sourceStore).import(
            ByteArrayInputStream(
                versionedZip(payload, recordCount = 3),
            ),
        )

        assertEquals(6, imported.runRecordsPreserved)
        assertEquals(
            runLines,
            sourceStore.runRecordsPage(null, 100).map(ArchiveRunRecord::rawJson),
        )

        val first = ByteArrayOutputStream()
        val second = ByteArrayOutputStream()
        CanonicalArchiveExporter(sourceStore).export(first)
        CanonicalArchiveExporter(sourceStore).export(second)
        assertTrue(first.toByteArray().contentEquals(second.toByteArray()))

        val targetStore = InMemoryCanonicalRecordStore()
        ArchiveImporter(targetStore).import(ByteArrayInputStream(first.toByteArray()))
        val third = ByteArrayOutputStream()
        CanonicalArchiveExporter(targetStore).export(third)
        assertTrue(first.toByteArray().contentEquals(third.toByteArray()))
        assertEquals(
            runLines,
            targetStore.runRecordsPage(null, 100).map(ArchiveRunRecord::rawJson),
        )
    }

    @Test
    fun seriesCompletionIdentityMatchesCrossPlatformFixture() {
        val fixture = requireNotNull(
            javaClass.getResourceAsStream("/hozz/v1/fixtures/identity-vectors.json"),
        ).use { it.readBytes().toString(Charsets.UTF_8) }
        val vector = Json.parseToJsonElement(fixture)
            .jsonObject["seriesCompletion"]!!
            .jsonObject
        val sourceId = vector["sourceRecordId"]!!.jsonPrimitive.content
        val sourceType = vector["sourceType"]!!.jsonPrimitive.content

        assertEquals(
            vector["recordId"]!!.jsonPrimitive.content,
            CanonicalRecordParser.seriesEndId(sourceId, sourceType),
        )
        assertEquals(
            vector["canonicalId"]!!.jsonPrimitive.content,
            GeneratedContract.canonicalId(
                GeneratedContract.SOURCE_STORE,
                CanonicalRecordParser.seriesEndId(sourceId, sourceType),
            ),
        )
    }

    @Test
    fun identicalCoverageLinesFromDifferentRunsRemainDistinct() = runBlocking {
        val coverage =
            """{"kind":"typeCoverage","schemaVersion":1,"type":"steps","state":"anchorClosed","complete":true,"observedAt":"2026-01-01T00:00:01Z"}"""
        val store = InMemoryCanonicalRecordStore()
        val importer = ArchiveImporter(store)
        for (run in listOf("run-a", "run-b")) {
            val lines = listOf(
                """{"kind":"manifest","schemaVersion":1,"run":"$run","createdAt":"2026-01-01T00:00:00Z"}""",
                coverage,
            ).joinToString("\n", postfix = "\n")
            importer.import(ByteArrayInputStream(lines.toByteArray()))
        }

        val preserved = store.runRecordsPage(null, 100)
        assertEquals(4, preserved.size)
        assertEquals(2, preserved.count { it.kind == "typeCoverage" })
    }

    @Test
    fun reenteredRunRetainsOccurrenceCountersWithoutDroppingRecords() =
        runBlocking {
            val summary =
                """{"kind":"typeSummary","schemaVersion":1,"type":"steps","state":"complete"}"""
            val lines = listOf(
                """{"kind":"manifest","schemaVersion":1,"run":"run-a","createdAt":"2026-01-01T00:00:00Z"}""",
                summary,
                """{"kind":"manifest","schemaVersion":1,"run":"run-b","createdAt":"2026-01-01T00:00:00Z"}""",
                summary,
                """{"kind":"manifest","schemaVersion":1,"run":"run-a","createdAt":"2026-01-01T00:00:00Z"}""",
                summary,
            ).joinToString("\n", postfix = "\n")
            val store = InMemoryCanonicalRecordStore()

            ArchiveImporter(store).import(
                ByteArrayInputStream(lines.toByteArray()),
            )

            assertEquals(6, store.runRecordsPage(null, 10).size)
        }

    @Test
    fun legacyCoverageIsNormalizedIntoAReimportableV1Archive() = runBlocking {
        val legacyCoverage =
            """{"kind":"typeCoverage","type":"steps","state":"anchorClosed","complete":true,"observedAt":"2026-01-01T00:00:01Z"}"""
        val source = InMemoryCanonicalRecordStore()
        ArchiveImporter(source).import(
            ByteArrayInputStream("$legacyCoverage\n".toByteArray()),
        )
        val output = ByteArrayOutputStream()
        CanonicalArchiveExporter(source).export(output)
        val target = InMemoryCanonicalRecordStore()
        ArchiveImporter(source).import(
            ByteArrayInputStream(output.toByteArray()),
        )

        val imported = ArchiveImporter(target).import(
            ByteArrayInputStream(output.toByteArray()),
        )

        assertFalse(imported.legacyArchive)
        assertEquals(1, imported.runRecordsPreserved)
        assertEquals(1, source.runRecordsPage(null, 10).size)
        assertTrue(
            target.runRecordsPage(null, 10).single().rawJson
                .contains("\"schemaVersion\":1"),
        )
    }

    @Test
    fun malformedLegacyOwnedFieldsNormalizeToStableStrictV1() = runBlocking {
        val legacy =
            """
            {"canonicalId":"apple.healthkit:legacy-normalized","device":[],"endDate":"2026-01-01T00:01:00Z","id":"legacy-normalized","kind":"quantity","lineage":["bad",{"firstNote":"kept-1","package":"","recordId":"legacy-normalized","store":"apple.healthkit"},{"package":42,"recordId":"legacy-normalized","secondNote":"kept-2","store":"apple.healthkit"}],"metadata":"bad","quantity":{"original":{"description":"source text","unit":"native"},"unit":"count","value":1},"recordVersion":1,"schemaVersion":1,"source":"bad","sourceRecord":"bad","startDate":"2026-01-01T00:00:00Z","type":"steps","vendorExtension":"kept"}
            """.trimIndent()
        val source = InMemoryCanonicalRecordStore()
        ArchiveImporter(source).import(
            ByteArrayInputStream("$legacy\n".toByteArray()),
        )
        val first = ByteArrayOutputStream()
        CanonicalArchiveExporter(source).export(first)
        val target = InMemoryCanonicalRecordStore()
        ArchiveImporter(target).import(ByteArrayInputStream(first.toByteArray()))
        val second = ByteArrayOutputStream()
        CanonicalArchiveExporter(target).export(second)

        assertTrue(first.toByteArray().contentEquals(second.toByteArray()))
        val normalized = CanonicalArchiveExporter(target)
            .canonicalJson(target.allRecords().single())
        val objectValue = Json.parseToJsonElement(normalized).jsonObject
        assertEquals(2, objectValue["lineage"]!!.jsonArray.size)
        assertEquals(
            "kept-1",
            objectValue["lineage"]!!.jsonArray[0]
                .jsonObject["firstNote"]!!.jsonPrimitive.content,
        )
        assertEquals(
            "kept-2",
            objectValue["lineage"]!!.jsonArray[1]
                .jsonObject["secondNote"]!!.jsonPrimitive.content,
        )
        assertEquals(
            "42",
            objectValue["lineage"]!!.jsonArray[1]
                .jsonObject["package"]!!.jsonPrimitive.content,
        )
        assertFalse(
            objectValue["lineage"]!!.jsonArray[0]
                .jsonObject.containsKey("package"),
        )
        val original = objectValue["quantity"]!!
            .jsonObject["original"]!!
            .jsonObject
        assertEquals(
            "source text",
            original["description"]!!.jsonPrimitive.content,
        )
        assertEquals("native", original["unit"]!!.jsonPrimitive.content)
        assertEquals(
            "kept",
            objectValue["vendorExtension"]!!.jsonPrimitive.content,
        )
        CanonicalRecordParser.validateStrict(normalized)
    }

    @Test
    fun legacyLineageWithoutOriginNormalizesToSourceOrigin() = runBlocking {
        val legacy =
            """
            {"canonicalId":"apple.healthkit:lineage-origin","endDate":"2026-01-01T00:01:00Z","id":"lineage-origin","kind":"quantity","lineage":[{"recordId":"other","store":"invalid:store"}],"quantity":{"unit":"count","value":1},"recordVersion":1,"schemaVersion":1,"sourceRecord":{"id":"lineage-origin","store":"apple.healthkit","type":"steps"},"startDate":"2026-01-01T00:00:00Z","type":"steps"}
            """.trimIndent()
        val store = InMemoryCanonicalRecordStore()
        ArchiveImporter(store).import(
            ByteArrayInputStream("$legacy\n".toByteArray()),
        )

        val line = CanonicalArchiveExporter(store)
            .canonicalJson(store.allRecords().single())
        val lineage = Json.parseToJsonElement(line)
            .jsonObject["lineage"]!!
            .jsonArray

        assertEquals(1, lineage.size)
        assertEquals(
            "apple.healthkit",
            lineage.single().jsonObject["store"]!!.jsonPrimitive.content,
        )
        assertEquals(
            "lineage-origin",
            lineage.single().jsonObject["recordId"]!!.jsonPrimitive.content,
        )
        CanonicalRecordParser.validateStrict(line)
    }

    @Test
    fun explicitFutureRunSchemaIsNeverDowngradedToV1() = runBlocking {
        val future =
            """{"kind":"typeSummary","schemaVersion":2,"type":"steps","state":"complete"}"""
        val store = InMemoryCanonicalRecordStore()
        var failed = false

        try {
            ArchiveImporter(store).import(
                ByteArrayInputStream("$future\n".toByteArray()),
            )
        } catch (_: ArchiveFormatException) {
            failed = true
        }

        assertTrue(failed)
        assertTrue(store.runRecordsPage(null, 10).isEmpty())
    }

    @Test
    fun normalizedLegacyRunCannotGrowPastCanonicalLimit() = runBlocking {
        val run =
            """{"kind":"typeSummary","padding":"fixture","state":"complete","type":"steps"}"""
        val archive = zip(
            listOf("records.ndjson" to "$run\n".toByteArray()),
        )
        val store = InMemoryCanonicalRecordStore()
        var rejected = false

        try {
            ArchiveImporter(
                store,
                limits = ArchiveImportLimits(
                    maxLegacyRecordBytes = run.toByteArray().size,
                    maxCanonicalRecordBytes = run.toByteArray().size,
                ),
            ).import(ByteArrayInputStream(archive))
        } catch (_: ArchiveFormatException) {
            rejected = true
        }

        assertTrue(rejected)
        assertTrue(store.runRecordsPage(null, 10).isEmpty())
    }

    @Test
    fun validZipAtInflatedLimitIsNotDoubleCounted() = runBlocking {
        val manifest = manifest(3)
        val archive = versionedZip(fixture, recordCount = 3)
        val store = InMemoryCanonicalRecordStore()

        val imported = ArchiveImporter(
            store,
            limits = ArchiveImportLimits(
                maxInflatedBytes = (manifest.size + fixture.size).toLong(),
                maxEntryCompressionRatio = 10_000,
                maxGlobalCompressionRatio = 10_000,
            ),
        ).import(ByteArrayInputStream(archive))

        assertEquals(3, imported.recordsRead)
    }

    @Test
    fun malformedUtf8RejectsWithoutCommittingEarlierRecords() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val valid = fixture.toString(Charsets.UTF_8).lineSequence().first()
            .toByteArray()
        val payload = valid + "\n".toByteArray() +
            byteArrayOf(0xC3.toByte(), 0x28) + "\n".toByteArray()
        var failed = false

        try {
            ArchiveImporter(store).import(ByteArrayInputStream(payload))
        } catch (_: ArchiveFormatException) {
            failed = true
        }

        assertTrue(failed)
        assertTrue(store.allRecords().isEmpty())
    }

    @Test
    fun strictV1RejectsMissingOrContradictoryCanonicalFields() = runBlocking {
        val valid = Json.parseToJsonElement(
            fixture.toString(Charsets.UTF_8).lineSequence().first(),
        ).jsonObject
        val invalidRecords = buildList {
            for (field in listOf(
                "canonicalId",
                "canonicalType",
                "id",
                "recordVersion",
                "type",
                "sourceRecord",
                "lineage",
                "startDate",
                "endDate",
                "quantity",
            )) {
                add(JsonObject(valid - field).toString())
            }
            val sourceRecord = valid["sourceRecord"]!!.jsonObject
            for (field in listOf("id", "store", "type")) {
                add(
                    JsonObject(
                        valid + (
                            "sourceRecord" to JsonObject(sourceRecord - field)
                        ),
                    ).toString(),
                )
            }
            add(
                JsonObject(
                    valid + (
                        "sourceRecord" to JsonObject(
                            valid["sourceRecord"]!!.jsonObject +
                                ("type" to JsonPrimitive("different")),
                        )
                    ),
                ).toString(),
            )
            add(JsonObject(valid + ("lineage" to JsonArray(emptyList()))).toString())
            add(JsonObject(valid + ("recordVersion" to JsonPrimitive(0))).toString())
            add(JsonObject(valid + ("recordVersion" to JsonPrimitive("1"))).toString())
            add(JsonObject(valid + ("kind" to JsonPrimitive(""))).toString())
            add(JsonObject(valid + ("kind" to JsonPrimitive(7))).toString())
            add(JsonObject(valid + ("startDate" to JsonPrimitive("not-a-date"))).toString())
            add(JsonObject(valid + ("quantity" to JsonObject(emptyMap()))).toString())
            add(
                JsonObject(
                    valid + (
                        "canonicalId" to JsonPrimitive(
                            "apple.healthkit:someone-else",
                        )
                    ),
                ).toString(),
            )
            add(
                JsonObject(
                    valid + (
                        "lineage" to JsonArray(
                            listOf(JsonPrimitive("not-an-object")),
                        )
                    ),
                ).toString(),
            )
        }

        for (invalid in invalidRecords) {
            val store = InMemoryCanonicalRecordStore()
            var failed = false
            try {
                ArchiveImporter(store).import(
                    ByteArrayInputStream(
                        versionedZip("$invalid\n".toByteArray(), recordCount = 1),
                    ),
                )
            } catch (_: ArchiveFormatException) {
                failed = true
            }
            assertTrue(invalid, failed)
            assertTrue(store.allRecords().isEmpty())
        }
    }

    @Test
    fun substitutedCanonicalTombstoneCannotOverwriteAnotherRecord() = runBlocking {
        val victim = CanonicalRecordParser.parse(
            fixture.toString(Charsets.UTF_8).lineSequence().first(),
            strictV1 = true,
        )!!
        val store = InMemoryCanonicalRecordStore()
        store.upsert(listOf(victim))
        val malicious =
            """
            {"canonicalId":"${victim.canonicalId}","canonicalType":"activity.steps","id":"other","kind":"deletion","lineage":[{"recordId":"other","store":"apple.healthkit"}],"recordVersion":99,"schemaVersion":1,"sourceRecord":{"id":"other","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent()
        var rejected = false

        try {
            ArchiveImporter(store).import(
                ByteArrayInputStream(
                    versionedZip("$malicious\n".toByteArray(), recordCount = 1),
                ),
            )
        } catch (_: ArchiveFormatException) {
            rejected = true
        }

        assertTrue(rejected)
        assertEquals(victim, store.allRecords().single())
        assertFalse(store.allRecords().single().tombstone)

        val forgedProvenance =
            """
            {"canonicalId":"${victim.canonicalId}","canonicalType":"activity.steps","id":"${victim.sourceRecordId}","kind":"deletion","lineage":[{"recordId":"attacker","store":"apple.healthkit"}],"recordVersion":99,"schemaVersion":1,"sourceRecord":{"id":"attacker","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent()
        rejected = false
        try {
            ArchiveImporter(store).import(
                ByteArrayInputStream(
                    versionedZip(
                        "$forgedProvenance\n".toByteArray(),
                        recordCount = 1,
                    ),
                ),
            )
        } catch (_: ArchiveFormatException) {
            rejected = true
        }
        assertTrue(rejected)
        assertEquals(victim, store.allRecords().single())

        val attackerSource = "00000000-0000-0000-0000-000000000299"
        val forgedError =
            """
            {"canonicalId":"${victim.canonicalId}","canonicalType":"archive.encoding-error","id":"${victim.sourceRecordId}","kind":"sampleEncodingError","lineage":[{"recordId":"$attackerSource","store":"apple.healthkit"}],"message":"forged","parentCanonicalId":"apple.healthkit:$attackerSource","recordVersion":99,"schemaVersion":1,"sourceRecord":{"id":"$attackerSource","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent()
        rejected = false
        try {
            ArchiveImporter(store).import(
                ByteArrayInputStream(
                    versionedZip("$forgedError\n".toByteArray(), recordCount = 1),
                ),
            )
        } catch (_: ArchiveFormatException) {
            rejected = true
        }
        assertTrue(rejected)
        assertEquals(victim, store.allRecords().single())

        val canonicalSource = "00000000-0000-0000-0000-000000000299"
        val aliasedSource = canonicalSource.replace("-", "").uppercase()
        val aliasedErrorId = CanonicalRecordParser.encodingFailureId(
            canonicalSource,
            "HKQuantityTypeIdentifierStepCount",
        )
        val aliasedError =
            """
            {"canonicalId":"apple.healthkit:$aliasedErrorId","canonicalType":"archive.encoding-error","id":"$aliasedErrorId","kind":"sampleEncodingError","lineage":[{"recordId":"$aliasedSource","store":"apple.healthkit"}],"message":"alias","parentCanonicalId":"apple.healthkit:$aliasedSource","recordVersion":99,"schemaVersion":1,"sourceRecord":{"id":"$aliasedSource","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent()
        rejected = false
        try {
            ArchiveImporter(store).import(
                ByteArrayInputStream(
                    versionedZip("$aliasedError\n".toByteArray(), recordCount = 1),
                ),
            )
        } catch (_: ArchiveFormatException) {
            rejected = true
        }
        assertTrue(rejected)

        val ambiguousNamespace =
            """
            {"canonicalId":"a:b:c","canonicalType":"activity.steps","id":"c","kind":"deletion","lineage":[{"recordId":"c","store":"a:b"}],"recordVersion":99,"schemaVersion":1,"sourceRecord":{"id":"c","store":"a:b","type":"HKQuantityTypeIdentifierStepCount"},"type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent()
        rejected = false
        try {
            CanonicalRecordParser.parse(ambiguousNamespace)
        } catch (_: ArchiveFormatException) {
            rejected = true
        }
        assertTrue(rejected)

        val badParent =
            """
            {"canonicalId":"apple.healthkit:detail","canonicalType":"series.readings","endDate":"2026-01-01T00:01:00Z","id":"detail","kind":"quantitySeriesReadings","lineage":[{"recordId":"other","store":"apple.healthkit"}],"parentCanonicalId":"${victim.canonicalId}","recordVersion":1,"sample":"other","schemaVersion":1,"sourceRecord":{"id":"other","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent()
        rejected = false
        try {
            ArchiveImporter(store).import(
                ByteArrayInputStream(
                    versionedZip("$badParent\n".toByteArray(), recordCount = 1),
                ),
            )
        } catch (_: ArchiveFormatException) {
            rejected = true
        }
        assertTrue(rejected)
        assertEquals(victim, store.allRecords().single())
    }

    @Test
    fun pendingImportMemoryAndOccurrenceTrackingAreBounded() = runBlocking {
        val lines = fixture.toString(Charsets.UTF_8)
            .lineSequence()
            .filter(String::isNotBlank)
            .take(2)
            .toList()
        val budget = lines.maxOf { it.toByteArray().size }.toLong() + 1
        val store = InMemoryCanonicalRecordStore()
        val imported = ArchiveImporter(
            store,
            batchSize = 500,
            limits = ArchiveImportLimits(maxPendingBatchBytes = budget),
        ).import(
            ByteArrayInputStream(
                lines.joinToString("\n", postfix = "\n").toByteArray(),
            ),
        )
        assertTrue(imported.peakPendingBytes <= budget)
        assertEquals(2, store.recordCount())

        val runStore = InMemoryCanonicalRecordStore()
        val runLines = """
            {"kind":"typeSummary","schemaVersion":1,"type":"steps","state":"one"}
            {"kind":"typeSummary","schemaVersion":1,"type":"heart","state":"two"}
        """.trimIndent()
        var rejected = false
        try {
            ArchiveImporter(
                runStore,
                limits = ArchiveImportLimits(maxRunOccurrenceKeys = 1),
            ).import(ByteArrayInputStream("$runLines\n".toByteArray()))
        } catch (_: ArchiveFormatException) {
            rejected = true
        }
        assertTrue(rejected)
        assertTrue(runStore.runRecordsPage(null, 10).isEmpty())
    }

    @Test
    fun acceptedLegacyRecordHasCanonicalNormalizationHeadroom() = runBlocking {
        val legacy =
            """
            {"endDate":"2026-01-01T00:01:00Z","id":"headroom","kind":"quantity","padding":"${"x".repeat(447 * 1_024 + 700)}","quantity":{"unit":"count","value":1},"schemaVersion":1,"startDate":"2026-01-01T00:00:00Z","type":"steps"}
            """.trimIndent()
        val store = InMemoryCanonicalRecordStore()

        ArchiveImporter(store).import(
            ByteArrayInputStream("$legacy\n".toByteArray()),
        )
        val normalized = CanonicalArchiveExporter(store)
            .canonicalJson(store.allRecords().single())

        val archive = ByteArrayOutputStream()
        CanonicalArchiveExporter(store).export(archive)
        val restored = InMemoryCanonicalRecordStore()
        ArchiveImporter(restored).import(
            ByteArrayInputStream(archive.toByteArray()),
        )
        assertTrue(normalized.toByteArray().size <= 512 * 1_024)
        assertTrue(normalized.toByteArray().size > 448 * 1_024)
        assertEquals(1, restored.recordCount())
        CanonicalRecordParser.validateStrict(normalized)
    }

    @Test
    fun legacyRecordThatExpandsPastCanonicalLimitRejectsAtomically() =
        runBlocking {
            val repeated = "x".repeat(90 * 1_024)
            val legacy =
                """
                {"endDate":"2026-01-01T00:01:00Z","id":"$repeated","kind":"quantity","quantity":{"unit":"count","value":1},"schemaVersion":1,"startDate":"2026-01-01T00:00:00Z","type":"$repeated"}
                """.trimIndent()
            val store = InMemoryCanonicalRecordStore()
            var rejected = false

            try {
                ArchiveImporter(store).import(
                    ByteArrayInputStream("$legacy\n".toByteArray()),
                )
            } catch (_: ArchiveFormatException) {
                rejected = true
            }

            assertTrue(rejected)
            assertTrue(store.allRecords().isEmpty())
        }

    @Test
    fun continuationFailureResolvesOnlyOnEndMarkerOrDeletion() = runBlocking {
        val parentId = "00000000-0000-0000-0000-000000000123"
        val parent = CanonicalRecordParser.parse(
            """
            {"canonicalId":"apple.healthkit:$parentId","canonicalType":"activity.exercise-route","endDate":"2026-01-01T00:01:00Z","id":"$parentId","kind":"workoutRoute","lineage":[{"recordId":"$parentId","store":"apple.healthkit"}],"recordVersion":1,"schemaVersion":1,"sourceRecord":{"id":"$parentId","store":"apple.healthkit","type":"HKWorkoutRouteTypeIdentifier"},"startDate":"2026-01-01T00:00:00Z","type":"HKWorkoutRouteTypeIdentifier"}
            """.trimIndent(),
            strictV1 = true,
        )!!
        val endId = CanonicalRecordParser.seriesEndId(
            parentId,
            "HKWorkoutRouteTypeIdentifier",
        )
        val errorId = CanonicalRecordParser.encodingFailureId(
            parentId,
            "HKWorkoutRouteTypeIdentifier",
        )
        val error = CanonicalRecordParser.parse(
            """
            {"canonicalId":"apple.healthkit:$errorId","canonicalType":"archive.encoding-error","id":"$errorId","kind":"sampleEncodingError","lineage":[{"recordId":"$parentId","store":"apple.healthkit"}],"message":"continuation failed","parentCanonicalId":"apple.healthkit:$parentId","recordVersion":3,"resolutionCanonicalId":"apple.healthkit:$endId","schemaVersion":1,"sourceRecord":{"id":"$parentId","store":"apple.healthkit","type":"HKWorkoutRouteTypeIdentifier"},"type":"HKWorkoutRouteTypeIdentifier"}
            """.trimIndent(),
            strictV1 = true,
        )!!
        val end = CanonicalRecordParser.parse(
            """
            {"canonicalId":"apple.healthkit:$endId","canonicalType":"activity.exercise-route-end","endDate":"2026-01-01T00:01:00Z","id":"$endId","kind":"workoutRouteEnd","lineage":[{"recordId":"$parentId","store":"apple.healthkit"}],"parentCanonicalId":"apple.healthkit:$parentId","recordVersion":1,"sample":"$parentId","schemaVersion":1,"sourceRecord":{"id":"$parentId","store":"apple.healthkit","type":"HKWorkoutRouteTypeIdentifier"},"startDate":"2026-01-01T00:00:00Z","type":"HKWorkoutRouteTypeIdentifier"}
            """.trimIndent(),
            strictV1 = true,
        )!!
        val store = InMemoryCanonicalRecordStore()
        store.upsert(listOf(parent, error))
        assertFalse(
            store.allRecords().single { it.canonicalId == error.canonicalId }.tombstone,
        )
        val archive = ByteArrayOutputStream()
        CanonicalArchiveExporter(store).export(archive)
        val roundTripStore = InMemoryCanonicalRecordStore()
        ArchiveImporter(roundTripStore).import(
            ByteArrayInputStream(archive.toByteArray()),
        )
        val roundTripError = roundTripStore.allRecords()
            .single { it.canonicalId == error.canonicalId }
        assertFalse(roundTripError.tombstone)
        assertEquals(error.resolutionCanonicalId, roundTripError.resolutionCanonicalId)

        val wrongEndStore = InMemoryCanonicalRecordStore()
        wrongEndStore.upsert(
            listOf(
                parent,
                error,
                end.copy(
                    kind = "electrocardiogramEnd",
                    canonicalType = "cardiac.electrocardiogram-end",
                ),
            ),
        )
        assertFalse(
            wrongEndStore.allRecords()
                .single { it.canonicalId == error.canonicalId }
                .tombstone,
        )
        val forgedTombstoneStore = InMemoryCanonicalRecordStore()
        forgedTombstoneStore.upsert(listOf(parent, error.copy(tombstone = true)))
        assertFalse(
            forgedTombstoneStore.allRecords()
                .single { it.canonicalId == error.canonicalId }
                .tombstone,
        )

        val reactivationStore = InMemoryCanonicalRecordStore()
        val headerError = error.copy(
            recordVersion = 1,
            resolutionCanonicalId = null,
        )
        reactivationStore.upsert(listOf(headerError, parent))
        assertTrue(
            reactivationStore.allRecords()
                .single { it.canonicalId == error.canonicalId }
                .tombstone,
        )
        reactivationStore.upsert(listOf(error))
        assertFalse(
            reactivationStore.allRecords()
                .single { it.canonicalId == error.canonicalId }
                .tombstone,
        )

        store.upsert(listOf(end))
        assertTrue(
            store.allRecords().single { it.canonicalId == error.canonicalId }.tombstone,
        )
        val resolvedVersion = store.allRecords()
            .single { it.canonicalId == error.canonicalId }
            .recordVersion
        val resolvedArchive = ByteArrayOutputStream()
        CanonicalArchiveExporter(store).export(resolvedArchive)
        val resolvedRoundTrip = InMemoryCanonicalRecordStore()
        ArchiveImporter(resolvedRoundTrip).import(
            ByteArrayInputStream(resolvedArchive.toByteArray()),
        )
        val roundTrippedResolvedError = resolvedRoundTrip.allRecords()
            .single { it.canonicalId == error.canonicalId }
        assertTrue(roundTrippedResolvedError.tombstone)
        assertEquals(resolvedVersion, roundTrippedResolvedError.recordVersion)

        val deletionStore = InMemoryCanonicalRecordStore()
        deletionStore.upsert(listOf(parent, error))
        deletionStore.upsert(
            listOf(
                parent.copy(
                    kind = "deletion",
                    recordVersion = 2,
                    tombstone = true,
                ),
            ),
        )
        assertTrue(deletionStore.allRecords().all(CanonicalRecord::tombstone))

        val masquerade = error.rawJson.replace(
            "apple.healthkit:$endId",
            parent.canonicalId,
        )
        var rejected = false
        try {
            CanonicalRecordParser.parse(masquerade, strictV1 = true)
        } catch (_: ArchiveFormatException) {
            rejected = true
        }
        assertTrue(rejected)

        val missingSyntheticId =
            """
            {"canonicalType":"activity.exercise-route-end","endDate":"2026-01-01T00:01:00Z","kind":"workoutRouteEnd","recordVersion":1,"schemaVersion":1,"sourceRecord":{"id":"$parentId","store":"apple.healthkit","type":"HKWorkoutRouteTypeIdentifier"},"startDate":"2026-01-01T00:00:00Z","type":"HKWorkoutRouteTypeIdentifier"}
            """.trimIndent()
        rejected = false
        try {
            CanonicalRecordParser.parse(missingSyntheticId)
        } catch (_: ArchiveFormatException) {
            rejected = true
        }
        assertTrue(rejected)
    }

    @Test
    fun legacyParentedRecordUsesSourceRecordIdentityWithoutSampleField() {
        val sourceId = "00000000-0000-0000-0000-000000000204"
        val endId = CanonicalRecordParser.seriesEndId(
            sourceId,
            "HKWorkoutRouteTypeIdentifier",
        )
        val record = CanonicalRecordParser.parse(
            """
            {"canonicalId":"apple.healthkit:$endId","canonicalType":"activity.exercise-route-end","endDate":"2026-01-01T00:01:00Z","id":"$endId","kind":"workoutRouteEnd","recordVersion":1,"schemaVersion":1,"sourceRecord":{"id":"$sourceId","store":"apple.healthkit","type":"HKWorkoutRouteTypeIdentifier"},"startDate":"2026-01-01T00:00:00Z","type":"HKWorkoutRouteTypeIdentifier"}
            """.trimIndent(),
        )!!

        assertEquals("apple.healthkit:$sourceId", record.parentCanonicalId)
    }

    @Test
    fun lateManifestRetroactivelyRequiresStrictCanonicalFields() = runBlocking {
        val legacyOnly =
            """
            {"endDate":"2026-01-01T00:01:00Z","id":"legacy","kind":"quantity","quantity":{"unit":"count","value":1},"schemaVersion":1,"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent().toByteArray()
        val runRecord =
            """
            {"kind":"typeError","schemaVersion":1,"type":"heart","message":"must roll back"}
            """.trimIndent().toByteArray()
        val archive = zip(
            listOf(
                "records.ndjson" to runRecord + "\n".toByteArray() + legacyOnly,
                ArchiveManifest.ENTRY_NAME to manifest(1),
            ),
        )
        val store = InMemoryCanonicalRecordStore()
        var failed = false

        try {
            ArchiveImporter(store).import(ByteArrayInputStream(archive))
        } catch (_: ArchiveFormatException) {
            failed = true
        }

        assertTrue(failed)
        assertTrue(store.allRecords().isEmpty())
        assertTrue(store.runRecordsPage(null, 100).isEmpty())
    }

    @Test
    fun ignoredLateZipBombRollsBackStagedRecords() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val seed = CanonicalRecordParser.parse(
            fixture.toString(Charsets.UTF_8).lineSequence().first(),
        )!!
        store.upsert(listOf(seed))
        val before = store.allRecords()
        val entries = listOf(
            ArchiveManifest.ENTRY_NAME to manifest(recordCount = 3),
            "records.ndjson" to fixture,
            "ignored.bin" to ByteArray(32 * 1_024) { 0 },
        )
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
            ).import(ByteArrayInputStream(zip(entries)))
        } catch (_: ArchiveFormatException) {
            failed = true
        }

        assertTrue(failed)
        assertEquals(before, store.allRecords())
        assertTrue(store.runRecordsPage(null, 100).isEmpty())
    }

    @Test
    fun zipEntryInflateAndRecordLimitsIncludeIgnoredContent() = runBlocking {
        val cases = listOf(
            ArchiveImportLimits(maxZipEntries = 1),
            ArchiveImportLimits(maxInflatedBytes = 256),
            ArchiveImportLimits(maxRecordLines = 2),
        )
        for (limits in cases) {
            val store = InMemoryCanonicalRecordStore()
            var failed = false
            try {
                ArchiveImporter(store, limits = limits).import(
                    ByteArrayInputStream(
                        zip(
                            listOf(
                                ArchiveManifest.ENTRY_NAME to manifest(3),
                                "records.ndjson" to fixture,
                                "ignored.bin" to ByteArray(1_024) { 1 },
                            ),
                        ),
                    ),
                )
            } catch (_: ArchiveFormatException) {
                failed = true
            }
            assertTrue(limits.toString(), failed)
            assertTrue(store.allRecords().isEmpty())
        }
    }

    @Test
    fun splitIgnoredEntriesCannotExploitPerEntryRatioSlack() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val archive = zip(
            listOf(
                ArchiveManifest.ENTRY_NAME to manifest(3),
                "records.ndjson" to fixture,
                "ignored-1.bin" to ByteArray(4 * 1_024) { 0 },
                "ignored-2.bin" to ByteArray(4 * 1_024) { 0 },
            ),
        )
        var failed = false

        try {
            ArchiveImporter(
                store,
                limits = ArchiveImportLimits(
                    maxInflatedBytes = 1_000_000,
                    maxEntryCompressionRatio = 1_000,
                    maxGlobalCompressionRatio = 2,
                    entryRatioSlackBytes = 8 * 1_024,
                    globalRatioSlackBytes = 4 * 1_024,
                ),
            ).import(ByteArrayInputStream(archive))
        } catch (_: ArchiveFormatException) {
            failed = true
        }

        assertTrue(failed)
        assertTrue(store.allRecords().isEmpty())
    }

    private fun manifest(recordCount: Int): ByteArray =
        """
        {"archiveId":"fixture","createdAt":"2026-01-01T00:00:00Z","format":"hozz-ndjson","recordCount":$recordCount,"recordSchema":"hozz/v1/canonical-record","recordsEntry":"records.ndjson","schemaVersion":1}
        """.trimIndent().toByteArray()

    private fun versionedZip(records: ByteArray, recordCount: Int): ByteArray =
        zip(
            listOf(
                ArchiveManifest.ENTRY_NAME to manifest(recordCount),
                "records.ndjson" to records,
            ),
        )

    private fun zip(entries: List<Pair<String, ByteArray>>): ByteArray =
        ByteArrayOutputStream().also { output ->
            ZipOutputStream(output).use { archive ->
                for ((name, bytes) in entries) {
                    archive.putNextEntry(ZipEntry(name))
                    archive.write(bytes)
                    archive.closeEntry()
                }
            }
        }.toByteArray()
}
