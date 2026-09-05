package com.thatcube.hozz.core

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import com.networknt.schema.InputFormat
import com.networknt.schema.SchemaLocation
import com.networknt.schema.SchemaRegistry
import com.networknt.schema.SpecificationVersion
import com.thatcube.hozz.generated.GeneratedContract
import com.thatcube.hozz.projection.ProjectionAction
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
import org.junit.Assert.assertThrows
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
    fun stagedChildBeforeNewerLiveParentUsesFinalParentWinner() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val sourceId = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        val childId = CanonicalRecordParser.seriesRecordId(
            sourceId,
            "HKQuantityTypeIdentifierStepCount",
            "readings-0",
        )
        val oldParent = CanonicalRecordParser.parse(
            """
            {"canonicalId":"apple.healthkit:$sourceId","canonicalType":"activity.steps","id":"$sourceId","kind":"deletion","recordVersion":2,"schemaVersion":1,"sourceRecord":{"id":"$sourceId","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent(),
        )!!
        val oldChild = CanonicalRecordParser.parse(
            """
            {"canonicalId":"apple.healthkit:$childId","canonicalType":"series.readings","endDate":"2026-01-01T00:01:00Z","id":"$childId","kind":"quantitySeriesReadings","parentCanonicalId":"apple.healthkit:$sourceId","recordVersion":2,"sample":"$sourceId","schemaVersion":1,"sequence":0,"sourceRecord":{"id":"$sourceId","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent(),
        )!!
        val liveParent = CanonicalRecordParser.parse(
            """
            {"canonicalId":"apple.healthkit:$sourceId","canonicalType":"activity.steps","endDate":"2026-01-01T00:01:00Z","id":"$sourceId","kind":"quantity","quantity":{"unit":"count","value":3},"recordVersion":3,"schemaVersion":1,"sourceRecord":{"id":"$sourceId","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent(),
        )!!
        val liveChild = CanonicalRecordParser.parse(
            """
            {"canonicalId":"apple.healthkit:$childId","canonicalType":"series.readings","endDate":"2026-01-01T00:01:00Z","id":"$childId","kind":"quantitySeriesReadings","parentCanonicalId":"apple.healthkit:$sourceId","recordVersion":3,"sample":"$sourceId","schemaVersion":1,"sequence":0,"sourceRecord":{"id":"$sourceId","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent(),
        )!!
        assertTrue(liveChild.canonicalId < liveParent.canonicalId)
        store.upsert(listOf(oldParent, oldChild))
        assertTrue(
            store.allRecords()
                .single { it.canonicalId == liveChild.canonicalId }
                .tombstone,
        )

        val import = store.beginImport()
        import.append(listOf(liveChild, liveParent))
        import.commit()

        val merged = store.allRecords().associateBy(CanonicalRecord::canonicalId)
        assertFalse(merged.getValue(liveParent.canonicalId).tombstone)
        assertFalse(merged.getValue(liveChild.canonicalId).tombstone)

        val replay = store.beginImport()
        replay.append(listOf(liveChild, liveParent))
        assertEquals(2, replay.commit().ignored)
        assertFalse(
            store.allRecords()
                .single { it.canonicalId == liveChild.canonicalId }
                .tombstone,
        )
    }

    @Test
    fun stagedNestedChainUsesFinalParentWinnersBeforeEqualReplay() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val oldRoot = nestedRecord("z-root", null, 2, deleted = true)
        val oldParent = nestedRecord(
            "m-parent",
            oldRoot.canonicalId,
            2,
            deleted = false,
        )
        val oldChild = nestedRecord(
            "a-child",
            oldParent.canonicalId,
            2,
            deleted = false,
        )
        store.upsert(listOf(oldRoot, oldParent, oldChild))
        assertTrue(store.allRecords().all(CanonicalRecord::tombstone))

        val liveRoot = nestedRecord("z-root", null, 3, deleted = false)
        val liveParent = nestedRecord(
            "m-parent",
            liveRoot.canonicalId,
            3,
            deleted = false,
        )
        val liveChild = nestedRecord(
            "a-child",
            liveParent.canonicalId,
            3,
            deleted = false,
        )
        val childFirst = listOf(liveChild, liveParent, liveRoot)
        val import = store.beginImport()
        import.append(childFirst)
        import.commit()

        assertTrue(store.allRecords().none(CanonicalRecord::tombstone))
        val replay = store.beginImport()
        replay.append(childFirst)
        assertEquals(3, replay.commit().ignored)
        assertTrue(store.allRecords().none(CanonicalRecord::tombstone))
    }

    @Test
    fun newerChildWaitsForMissingParentWinnerAcrossImports() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val oldParent = nestedRecord(
            "missing-parent",
            parentCanonicalId = null,
            version = 2,
            deleted = true,
        )
        val liveChild = nestedRecord(
            "deferred-child",
            parentCanonicalId = oldParent.canonicalId,
            version = 3,
            deleted = false,
        )
        store.upsert(listOf(oldParent))

        val childOnly = store.beginImport()
        childOnly.append(listOf(liveChild))
        childOnly.commit()

        assertTrue(
            store.allRecords().none { it.canonicalId == liveChild.canonicalId },
        )

        val liveParent = nestedRecord(
            "missing-parent",
            parentCanonicalId = null,
            version = 3,
            deleted = false,
        )
        val complete = store.beginImport()
        complete.append(listOf(liveChild, liveParent))
        complete.commit()

        assertTrue(store.allRecords().none(CanonicalRecord::tombstone))
        val replay = store.beginImport()
        replay.append(listOf(liveChild, liveParent))
        assertEquals(2, replay.commit().ignored)
        assertTrue(store.allRecords().none(CanonicalRecord::tombstone))
    }

    @Test
    fun singleSelfParentIsRejectedBeforeMutation() {
        val selfParent = nestedRecord(
            "self-parent",
            parentCanonicalId = "test:self-parent",
            version = 1,
            deleted = false,
        )
        val store = InMemoryCanonicalRecordStore()

        val error = assertThrows(ArchiveFormatException::class.java) {
            runBlocking { store.upsert(listOf(selfParent)) }
        }

        assertEquals("Canonical records contain a parent cycle.", error.message)
        assertTrue(runBlocking { store.allRecords().isEmpty() })
    }

    @Test
    fun splitImportParentCycleIsRejectedAgainstPersistedGraph() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val first = nestedRecord(
            "split-a",
            parentCanonicalId = "test:split-b",
            version = 1,
            deleted = false,
        )
        store.upsert(listOf(first))
        val closing = nestedRecord(
            "split-b",
            parentCanonicalId = first.canonicalId,
            version = 1,
            deleted = false,
        )

        val import = store.beginImport()
        import.append(listOf(closing))
        val error = assertThrows(ArchiveFormatException::class.java) {
            runBlocking { import.commit() }
        }

        assertEquals("Canonical records contain a parent cycle.", error.message)
        assertEquals(listOf(first), store.allRecords())
    }

    @Test
    fun deferredIncomingWinnerCannotHideResultingPersistedCycle() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val persistedB = nestedRecord(
            "effective-b",
            parentCanonicalId = null,
            version = 1,
            deleted = false,
        )
        val persistedA = nestedRecord(
            "effective-a",
            parentCanonicalId = persistedB.canonicalId,
            version = 1,
            deleted = false,
        )
        val tombstonedC = nestedRecord(
            "effective-c",
            parentCanonicalId = null,
            version = 2,
            deleted = true,
        )
        store.upsert(listOf(persistedA, persistedB, tombstonedC))
        val before = store.allRecords()
        val deferredA = nestedRecord(
            "effective-a",
            parentCanonicalId = tombstonedC.canonicalId,
            version = 3,
            deleted = false,
        )
        val closingB = nestedRecord(
            "effective-b",
            parentCanonicalId = persistedA.canonicalId,
            version = 2,
            deleted = false,
        )

        val error = assertThrows(ArchiveFormatException::class.java) {
            runBlocking { store.upsert(listOf(deferredA, closingB)) }
        }

        assertEquals("Canonical records contain a parent cycle.", error.message)
        assertEquals(before, store.allRecords())
    }

    @Test
    fun parentDepthLimitUsesOneLookupPerWinnerAndRejectsDeeperGraph() =
        runBlocking {
            fun winner(index: Int): CanonicalParentWinner =
                CanonicalParentWinner(
                    recordVersion = 1,
                    parentCanonicalId = if (index == 0) {
                        null
                    } else {
                        "test:lookup-${index - 1}"
                    },
                )

            val persisted = (0 until MAX_CANONICAL_PARENT_DEPTH).associate {
                "test:lookup-$it" to winner(it)
            }
            val maximum = nestedRecord(
                "lookup-$MAX_CANONICAL_PARENT_DEPTH",
                parentCanonicalId =
                    "test:lookup-${MAX_CANONICAL_PARENT_DEPTH - 1}",
                version = 2,
                deleted = false,
            )
            var lookups = 0

            assertEquals(
                listOf(maximum),
                recordsInParentWinnerOrder(listOf(maximum)) { canonicalId ->
                    lookups += 1
                    persisted[canonicalId]
                },
            )
            assertTrue(lookups <= MAX_CANONICAL_PARENT_DEPTH + 1)

            val persistedAtLimit = persisted + (
                maximum.canonicalId to CanonicalParentWinner(
                    recordVersion = maximum.recordVersion,
                    parentCanonicalId = maximum.parentCanonicalId,
                )
            )
            val tooDeep = nestedRecord(
                "lookup-${MAX_CANONICAL_PARENT_DEPTH + 1}",
                parentCanonicalId = maximum.canonicalId,
                version = 2,
                deleted = false,
            )
            lookups = 0
            val error = assertThrows(ArchiveFormatException::class.java) {
                recordsInParentWinnerOrder(listOf(tooDeep)) { canonicalId ->
                    lookups += 1
                    persistedAtLimit[canonicalId]
                }
            }

            assertEquals(
                "Canonical parent depth exceeds the 64 level limit.",
                error.message,
            )
            assertTrue(lookups <= MAX_CANONICAL_PARENT_DEPTH + 2)

            val store = InMemoryCanonicalRecordStore()
            val chain = (0..MAX_CANONICAL_PARENT_DEPTH).map { index ->
                nestedRecord(
                    "memory-depth-$index",
                    parentCanonicalId = if (index == 0) {
                        null
                    } else {
                        "test:memory-depth-${index - 1}"
                    },
                    version = 1,
                    deleted = false,
                )
            }
            store.upsert(chain.asReversed())
            val memoryTooDeep = nestedRecord(
                "memory-depth-${MAX_CANONICAL_PARENT_DEPTH + 1}",
                parentCanonicalId = chain.last().canonicalId,
                version = 1,
                deleted = false,
            )
            val memoryError = assertThrows(ArchiveFormatException::class.java) {
                runBlocking { store.upsert(listOf(memoryTooDeep)) }
            }
            assertEquals(error.message, memoryError.message)
            assertEquals(chain.size, store.recordCount())
        }

    @Test
    fun reparentingRootCannotPushPersistedDescendantPastDepthLimit() =
        runBlocking {
            val store = InMemoryCanonicalRecordStore()
            val newRoot = nestedRecord(
                "reparent-new-root",
                parentCanonicalId = null,
                version = 1,
                deleted = false,
            )
            val chain = (0..MAX_CANONICAL_PARENT_DEPTH).map { index ->
                nestedRecord(
                    "reparent-$index",
                    parentCanonicalId = if (index == 0) {
                        null
                    } else {
                        "test:reparent-${index - 1}"
                    },
                    version = 1,
                    deleted = false,
                )
            }
            store.upsert(listOf(newRoot) + chain.asReversed())
            val before = store.allRecords()
            val reparented = chain.first().copy(
                parentCanonicalId = newRoot.canonicalId,
                recordVersion = 2,
            )

            val error = assertThrows(ArchiveFormatException::class.java) {
                runBlocking { store.upsert(listOf(reparented)) }
            }

            assertEquals(
                "Canonical parent depth exceeds the 64 level limit.",
                error.message,
            )
            assertEquals(before, store.allRecords())
        }

    @Test
    fun missingRootTombstoneAndLiveTransitionsReconcileDeepDescendants() =
        runBlocking {
            val store = InMemoryCanonicalRecordStore()
            val rootId = "test:deep-root"
            val parent = nestedRecord("deep-parent", rootId, 1, deleted = false)
            val child = nestedRecord(
                "deep-child",
                parent.canonicalId,
                1,
                deleted = false,
            )
            val grandchild = nestedRecord(
                "deep-grandchild",
                child.canonicalId,
                1,
                deleted = false,
            )
            store.upsert(listOf(grandchild, child, parent))
            assertTrue(store.allRecords().none(CanonicalRecord::tombstone))

            val tombstone = nestedRecord(
                "deep-root",
                parentCanonicalId = null,
                version = 2,
                deleted = true,
            )
            store.upsert(listOf(tombstone))
            assertTrue(store.allRecords().all(CanonicalRecord::tombstone))

            val liveRoot = nestedRecord("deep-root", null, 3, deleted = false)
            val liveParent = nestedRecord(
                "deep-parent",
                liveRoot.canonicalId,
                3,
                deleted = false,
            )
            val liveChild = nestedRecord(
                "deep-child",
                liveParent.canonicalId,
                3,
                deleted = false,
            )
            val liveGrandchild = nestedRecord(
                "deep-grandchild",
                liveChild.canonicalId,
                3,
                deleted = false,
            )
            val live = listOf(
                liveGrandchild,
                liveChild,
                liveParent,
                liveRoot,
            )
            store.upsert(live)

            assertTrue(store.allRecords().none(CanonicalRecord::tombstone))
            assertEquals(4, store.upsert(live).ignored)
        }

    @Test
    fun ignoredLiveChildBlocksItsIncomingSubtreeInMemory() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val root = nestedRecord(
            "blocked-root",
            parentCanonicalId = null,
            version = 2,
            deleted = true,
        )
        val child = nestedRecord(
            "blocked-child",
            parentCanonicalId = root.canonicalId,
            version = 3,
            deleted = false,
        )
        val grandchild = nestedRecord(
            "blocked-grandchild",
            parentCanonicalId = child.canonicalId,
            version = 3,
            deleted = false,
        )
        store.upsert(listOf(root))

        val result = store.upsert(listOf(grandchild, child))

        assertEquals(2, result.ignored)
        assertEquals(listOf(root), store.allRecords())
        assertTrue(store.timeline().isEmpty())
    }

    @Test
    fun deferredChildKeepsLedgerTransitionMonotonicWhenParentReturns() =
        runBlocking {
            val store = InMemoryCanonicalRecordStore()
            val parentOne = nestedRecord(
                "ledger-parent",
                parentCanonicalId = null,
                version = 1,
                deleted = false,
            )
            fun child(version: Long): CanonicalRecord = nestedRecord(
                "ledger-child",
                parentCanonicalId = parentOne.canonicalId,
                version = version,
                deleted = false,
            ).copy(
                kind = "quantity",
                canonicalType = "body.weight",
                type = "HKQuantityTypeIdentifierBodyMass",
                canonicalValue = CanonicalValue(70.0, "kg"),
                originalValue = CanonicalValue(70.0, "kg"),
                sourceRecordId = "ledger-child",
            )
            val childOne = child(1)
            store.upsert(listOf(parentOne, childOne))
            val projection = HealthConnectProjection(
                canonicalId = childOne.canonicalId,
                targetRecord = "WeightRecord",
                canonicalVersion = 1,
                healthConnectRecordId = "health-ledger-child",
            )
            store.saveHealthConnectProjections(listOf(projection))

            val parentTwo = nestedRecord(
                "ledger-parent",
                parentCanonicalId = null,
                version = 2,
                deleted = true,
            )
            store.upsert(listOf(parentTwo))
            val deletedChild = store.allRecords()
                .single { it.canonicalId == childOne.canonicalId }
            val deletion = ProjectionPlanner.plan(deletedChild, projection)
            assertEquals(ProjectionAction.DELETE, deletion.action)
            assertEquals(2L, deletion.draft?.recordVersion)
            val deleteOperation = PendingHealthConnectOperation(
                canonicalId = childOne.canonicalId,
                targetRecord = "WeightRecord",
                canonicalVersion = 2,
                action = HealthConnectPendingAction.DELETE,
            )
            store.stageHealthConnectOperations(listOf(deleteOperation))
            store.completeHealthConnectDeletes(listOf(deleteOperation))

            val childThree = child(3)
            assertEquals(1, store.upsert(listOf(childThree)).ignored)
            val deferred = store.allRecords()
                .single { it.canonicalId == childThree.canonicalId }
            assertEquals(2, deferred.recordVersion)
            assertEquals(
                ProjectionAction.NONE,
                ProjectionPlanner.plan(deferred).action,
            )

            val parentThree = nestedRecord(
                "ledger-parent",
                parentCanonicalId = null,
                version = 3,
                deleted = false,
            )
            store.upsert(listOf(childThree, parentThree))
            val restored = store.allRecords()
                .single { it.canonicalId == childThree.canonicalId }
            val insertion = ProjectionPlanner.plan(restored)
            assertEquals(ProjectionAction.INSERT, insertion.action)
            assertEquals(3L, insertion.draft?.recordVersion)
            val upsertOperation = PendingHealthConnectOperation(
                canonicalId = restored.canonicalId,
                targetRecord = "WeightRecord",
                canonicalVersion = 3,
                action = HealthConnectPendingAction.UPSERT,
            )

            store.stageHealthConnectOperations(listOf(upsertOperation))

            assertEquals(
                upsertOperation,
                store.pendingHealthConnectOperations(setOf(restored.canonicalId))[
                    restored.canonicalId
                ],
            )
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
    fun deeplyNestedRecordFailsWithBoundedArchiveFormatError() {
        val record = buildString {
            append(
                """{"endDate":"2026-01-01T00:01:00Z","extension":""",
            )
            repeat(20_000) { append("""{"nested":""") }
            append("null")
            repeat(20_000) { append('}') }
            append(
                ""","id":"deep","kind":"quantity","quantity":{"unit":"count","value":1},"schemaVersion":1,"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}""",
            )
        }
        val store = InMemoryCanonicalRecordStore()

        val error = assertThrows(ArchiveFormatException::class.java) {
            runBlocking {
                ArchiveImporter(store).import(
                    ByteArrayInputStream("$record\n".toByteArray()),
                )
            }
        }

        assertEquals(
            "Record line 1 is invalid: Record JSON exceeds the maximum nesting depth of 64.",
            error.message,
        )
        assertTrue(runBlocking { store.allRecords().isEmpty() })
    }

    @Test
    fun recordJsonNestingLimitIsExactAndIgnoresBracesInsideStrings() {
        fun deletionAtDepth(depth: Int): String = buildString {
            append("""{"id":"depth-boundary","kind":"deletion","metadata":""")
            repeat(depth - 1) { append("""{"nested":""") }
            append(""""literal {[{[ braces"""")
            repeat(depth - 1) { append('}') }
            append(
                ""","schemaVersion":1,"type":"HKQuantityTypeIdentifierStepCount"}""",
            )
        }

        assertNotNull(
            CanonicalRecordParser.parse(
                deletionAtDepth(ArchiveJson.MAX_NESTING_DEPTH),
            ),
        )
        val error = assertThrows(ArchiveFormatException::class.java) {
            CanonicalRecordParser.parse(
                deletionAtDepth(ArchiveJson.MAX_NESTING_DEPTH + 1),
            )
        }
        assertEquals(
            "Record JSON exceeds the maximum nesting depth of 64.",
            error.message,
        )
    }

    @Test
    fun everyRecordParserEntryPointNormalizesArrayRootFailure() {
        val parsers: List<() -> Unit> = listOf(
            { CanonicalRecordParser.parse("[]") },
            { CanonicalRecordParser.kind("[]") },
            { CanonicalRecordParser.runIdentifier("[]") },
            { CanonicalRecordParser.normalizedRunLine("[]") },
            { CanonicalRecordParser.validateStrict("[]") },
        )

        for (parser in parsers) {
            val error = assertThrows(ArchiveFormatException::class.java, parser)
            assertEquals("A record must be a JSON object.", error.message)
        }
    }

    @Test
    fun recordsFirstZipArrayRootFailsWithArchiveFormatError() {
        val store = InMemoryCanonicalRecordStore()
        val archive = zip(
            listOf(
                "records.ndjson" to "[]\n".toByteArray(),
                ArchiveManifest.ENTRY_NAME to manifest(recordCount = 0),
            ),
        )

        val error = assertThrows(ArchiveFormatException::class.java) {
            runBlocking {
                ArchiveImporter(store).import(ByteArrayInputStream(archive))
            }
        }

        assertEquals(
            "Record line 1 is invalid: A record must be a JSON object.",
            error.message,
        )
        assertTrue(runBlocking { store.allRecords().isEmpty() })
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
    fun everyRunKindStripsWrongKindSchemaFieldsAndPassesIndependentSchema() =
        runBlocking {
            val legacy = listOf(
                """{"canonicalId":42,"kind":"manifest","run":"run-a","createdAt":"2026-01-01T00:00:00Z"}""",
                """{"canonicalId":42,"kind":"resume","run":"run-a","resumedAt":"2026-01-01T00:01:00Z","records":1}""",
                """{"canonicalId":42,"kind":"typeSummary","type":"steps","state":"anchorClosed","records":1}""",
                """{"canonicalId":42,"kind":"typeError","type":"heart","message":"failed"}""",
                """{"canonicalId":42,"kind":"typeCoverage","type":"steps","state":"anchorClosed","complete":true,"observedAt":"2026-01-01T00:02:00Z"}""",
                """{"canonicalId":42,"kind":"completion","run":"run-a","completedAt":"2026-01-01T00:03:00Z","records":5}""",
            ).joinToString("\n", postfix = "\n")
            val store = InMemoryCanonicalRecordStore()
            ArchiveImporter(store).import(ByteArrayInputStream(legacy.toByteArray()))
            val output = ByteArrayOutputStream()

            CanonicalArchiveExporter(store).export(output)

            assertIndependentSchemaValid(output.toByteArray())
            assertFalse(recordStream(output.toByteArray()).contains("\"canonicalId\""))
        }

    @Test
    fun strictRunRejectsSchemaFieldsOwnedByAnotherKind() {
        var rejected = false
        try {
            CanonicalRecordParser.validateStrict(
                """{"kind":"manifest","schemaVersion":1,"run":"run-a","createdAt":"2026-01-01T00:00:00Z","records":7}""",
            )
        } catch (_: ArchiveFormatException) {
            rejected = true
        }
        assertTrue(rejected)
    }

    @Test
    fun strictKnownCanonicalKindRejectsSchemaFieldsOwnedByAnotherKind() {
        val malformed =
            """
            {"canonicalId":"apple.healthkit:wrong-fields","canonicalType":"activity.steps","complete":true,"endDate":"2026-01-01T00:01:00Z","id":"wrong-fields","kind":"quantity","lineage":[{"recordId":"wrong-fields","store":"apple.healthkit"}],"quantity":{"unit":"count","value":1},"recordVersion":1,"schemaVersion":1,"sourceRecord":{"id":"wrong-fields","store":"apple.healthkit","type":"HKQuantityTypeIdentifierStepCount"},"startDate":"2026-01-01T00:00:00Z","type":"HKQuantityTypeIdentifierStepCount"}
            """.trimIndent()
        var rejected = false
        try {
            CanonicalRecordParser.validateStrict(malformed)
        } catch (_: ArchiveFormatException) {
            rejected = true
        }
        assertTrue(rejected)
    }

    @Test
    fun futureCanonicalKindRetainsSchemaNamedFields() = runBlocking {
        val future =
            """
            {"canonicalId":"future.store:record-1","canonicalType":"future.measurement","endDate":"2026-01-01T00:01:00Z","id":"record-1","kind":"futureMeasurement","lineage":[{"recordId":"record-1","store":"future.store"}],"recordVersion":1,"schemaVersion":1,"sourceRecord":{"id":"record-1","store":"future.store","type":"FutureType"},"startDate":"2026-01-01T00:00:00Z","state":"critical","type":"FutureType"}
            """.trimIndent()
        val source = InMemoryCanonicalRecordStore()
        ArchiveImporter(source).import(
            ByteArrayInputStream(versionedZip("$future\n".toByteArray(), 1)),
        )
        val output = ByteArrayOutputStream()

        CanonicalArchiveExporter(source).export(output)

        assertIndependentSchemaValid(output.toByteArray())
        val emitted = Json.parseToJsonElement(
            recordStream(output.toByteArray()).trim(),
        ).jsonObject
        assertEquals("critical", emitted["state"]!!.jsonPrimitive.content)
    }

    @Test
    fun malformedLegacyOwnedFieldsNormalizeToStableStrictV1() = runBlocking {
        val legacy =
            """
            {"canonicalId":"apple.healthkit:legacy-normalized","complete":"yes","createdAt":"wrong-kind","device":[],"endDate":"2026-01-01T00:01:00Z","id":"legacy-normalized","kind":"quantity","lineage":["bad",{"firstNote":"kept-1","package":"","recordId":"legacy-normalized","store":"apple.healthkit"},{"package":42,"recordId":"legacy-normalized","secondNote":"kept-2","store":"apple.healthkit"}],"metadata":"bad","quantity":{"original":{"description":"source text","unit":"native"},"unit":"count","value":1},"recordVersion":1,"records":"wrong-kind","run":"wrong-kind","schemaVersion":1,"source":"bad","sourceRecord":"bad","startDate":"2026-01-01T00:00:00Z","type":"steps","vendorExtension":"kept"}
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
        assertIndependentSchemaValid(first.toByteArray())
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
        for (key in listOf("complete", "createdAt", "records", "run")) {
            assertFalse(objectValue.containsKey(key))
        }
        CanonicalRecordParser.validateStrict(normalized)
    }

    private fun assertIndependentSchemaValid(archive: ByteArray) {
        val schemaId =
            "https://hozz.brando.page/schema/hozz/v1/canonical-record.schema.json"
        val schemaText = requireNotNull(
            javaClass.getResourceAsStream("/hozz/v1/canonical-record.schema.json"),
        ).use { it.reader().readText() }
        val registry = SchemaRegistry.withDefaultDialect(
            SpecificationVersion.DRAFT_2020_12,
        ) { builder ->
            builder.schemas(mapOf(schemaId to schemaText))
        }
        val schema = registry.getSchema(SchemaLocation.of(schemaId))
        val records = recordStream(archive)

        records.lineSequence().filter(String::isNotBlank).forEachIndexed {
                index,
                line,
            ->
            val errors = schema.validate(line, InputFormat.JSON) { context ->
                context.executionConfig { config ->
                    config.formatAssertionsEnabled(true)
                }
            }
            assertTrue("record $index failed independent schema validation: $errors", errors.isEmpty())
        }
    }

    private fun recordStream(archive: ByteArray): String =
        ZipInputStream(ByteArrayInputStream(archive)).use { zip ->
            generateSequence { zip.nextEntry }
                .first { it.name.endsWith(".ndjson") }
            zip.readBytes().toString(Charsets.UTF_8)
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

    private fun nestedRecord(
        id: String,
        parentCanonicalId: String?,
        version: Long,
        deleted: Boolean,
    ): CanonicalRecord {
        val parent = parentCanonicalId?.let {
            ""","parentCanonicalId":"$it""""
        }.orEmpty()
        val deletion = if (deleted) ""","deleted":true""" else ""
        return CanonicalRecordParser.parse(
            """
            {"canonicalId":"test:$id","canonicalType":"archive.raw"$deletion,"endDate":"2026-01-01T00:01:00Z","id":"$id","kind":"futureNested","lineage":[{"recordId":"$id","store":"test"}]$parent,"recordVersion":$version,"schemaVersion":1,"sourceRecord":{"id":"$id","store":"test","type":"FutureNestedType"},"startDate":"2026-01-01T00:00:00Z","type":"FutureNestedType"}
            """.trimIndent(),
            strictV1 = true,
        )!!
    }

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
