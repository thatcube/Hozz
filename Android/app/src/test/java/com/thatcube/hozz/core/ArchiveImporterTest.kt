package com.thatcube.hozz.core

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import com.thatcube.hozz.projection.ProjectionPlanner
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
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
    fun staleParentTombstoneCannotDeleteNewerChildren() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val liveParent = CanonicalRecordParser.parse(
            """
            {"canonicalId":"apple.healthkit:parent","canonicalType":"activity.steps","endDate":"2026-01-01T00:01:00Z","id":"parent","kind":"quantity","quantity":{"unit":"count","value":1},"recordVersion":3,"schemaVersion":1,"sourceRecord":{"id":"parent","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent(),
        )!!
        val child = CanonicalRecordParser.parse(
            """
            {"canonicalId":"apple.healthkit:child","canonicalType":"series.readings","endDate":"2026-01-01T00:01:00Z","id":"child","kind":"quantitySeriesReadings","parentCanonicalId":"apple.healthkit:parent","recordVersion":3,"sample":"parent","schemaVersion":1,"sourceRecord":{"id":"parent","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent(),
        )!!
        val staleTombstone = CanonicalRecordParser.parse(
            """
            {"canonicalId":"apple.healthkit:parent","canonicalType":"activity.steps","id":"parent","kind":"deletion","recordVersion":2,"schemaVersion":1,"sourceRecord":{"id":"parent","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"type":"HKQuantityTypeIdentifierStepCount"}
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

        assertEquals(
            vector["recordId"]!!.jsonPrimitive.content,
            CanonicalRecordParser.encodingFailureId(sourceId, sourceType),
        )
        val legacyError = CanonicalRecordParser.parse(
            """
            {"id":"$sourceId","kind":"sampleEncodingError","message":"fixture","schemaVersion":1,"type":"$sourceType"}
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
        val error =
            """
            {"id":"$sourceId","kind":"sampleEncodingError","message":"fixture","schemaVersion":1,"type":"$sourceType"}
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
