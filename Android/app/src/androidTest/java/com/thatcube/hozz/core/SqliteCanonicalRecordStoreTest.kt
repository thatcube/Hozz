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
    fun stagedChildSortedBeforeNewerLiveParentUsesFinalParentWinner() = runBlocking {
        val sourceId = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        val parentId = "apple.healthkit:$sourceId"
        val childId = "apple.healthkit:" + CanonicalRecordParser.seriesRecordId(
            sourceId,
            "HKQuantityTypeIdentifierStepCount",
            "readings-0",
        )
        val oldParent = record(version = 2, tombstone = true).copy(
            canonicalId = parentId,
            sourceRecordId = sourceId,
            lineage = listOf(SourceLineage("apple.healthkit", recordId = sourceId)),
        )
        val oldChild = record(version = 2, tombstone = false).copy(
            canonicalId = childId,
            parentCanonicalId = parentId,
            kind = "quantitySeriesReadings",
            canonicalType = "series.readings",
            sourceRecordId = sourceId,
            lineage = listOf(SourceLineage("apple.healthkit", recordId = sourceId)),
        )
        val liveParent = record(version = 3, tombstone = false).copy(
            canonicalId = parentId,
            sourceRecordId = sourceId,
            lineage = listOf(SourceLineage("apple.healthkit", recordId = sourceId)),
        )
        val liveChild = oldChild.copy(recordVersion = 3)
        assertTrue(liveChild.canonicalId < liveParent.canonicalId)
        store.upsert(listOf(oldParent, oldChild))

        val import = store.beginImport()
        import.append(listOf(liveChild, liveParent))
        import.commit()

        val merged = store.allRecords().associateBy(CanonicalRecord::canonicalId)
        assertTrue(!merged.getValue(liveParent.canonicalId).tombstone)
        assertTrue(!merged.getValue(liveChild.canonicalId).tombstone)

        val replay = store.beginImport()
        replay.append(listOf(liveChild, liveParent))
        assertEquals(2, replay.commit().ignored)
        assertTrue(
            !store.allRecords()
                .single { it.canonicalId == liveChild.canonicalId }
                .tombstone,
        )
    }

    @Test
    fun directAndStagedNestedChainsUseFinalParentWinners() = runBlocking {
        for ((prefix, staged) in listOf("direct" to false, "staged" to true)) {
            val old = nestedChain(prefix, version = 2, rootTombstone = true)
            store.upsert(old)
            assertTrue(
                store.allRecords()
                    .filter { it.canonicalId.startsWith("apple.healthkit:$prefix-") }
                    .all(CanonicalRecord::tombstone),
            )

            val live = nestedChain(prefix, version = 3, rootTombstone = false)
                .asReversed()
            val merge = if (staged) {
                store.beginImport().let { import ->
                    import.append(live)
                    import.commit()
                }
            } else {
                store.upsert(live)
            }
            assertEquals(3, merge.updated)
            assertTrue(
                store.allRecords()
                    .filter { it.canonicalId.startsWith("apple.healthkit:$prefix-") }
                    .none(CanonicalRecord::tombstone),
            )

            val replay = if (staged) {
                store.beginImport().let { import ->
                    import.append(live)
                    import.commit()
                }
            } else {
                store.upsert(live)
            }
            assertEquals(3, replay.ignored)
            assertTrue(
                store.allRecords()
                    .filter { it.canonicalId.startsWith("apple.healthkit:$prefix-") }
                    .none(CanonicalRecord::tombstone),
            )
        }
    }

    @Test
    fun newerChildWaitsForMissingParentInDirectAndStagedMerges() = runBlocking {
        suspend fun merge(
            records: List<CanonicalRecord>,
            staged: Boolean,
        ): MergeResult = if (staged) {
            store.beginImport().let { import ->
                import.append(records)
                import.commit()
            }
        } else {
            store.upsert(records)
        }

        for ((prefix, staged) in listOf("direct-missing" to false, "staged-missing" to true)) {
            val parentId = "$prefix-parent"
            val oldParent = nestedNode(
                id = parentId,
                parentCanonicalId = null,
                version = 2,
                tombstone = true,
            )
            val liveChild = nestedNode(
                id = "$prefix-child",
                parentCanonicalId = oldParent.canonicalId,
                version = 3,
                tombstone = false,
            )
            store.upsert(listOf(oldParent))

            merge(listOf(liveChild), staged)

            assertTrue(
                store.allRecords().none { it.canonicalId == liveChild.canonicalId },
            )

            val liveParent = nestedNode(
                id = parentId,
                parentCanonicalId = null,
                version = 3,
                tombstone = false,
            )
            merge(listOf(liveChild, liveParent), staged)

            val liveIds = setOf(liveParent.canonicalId, liveChild.canonicalId)
            assertTrue(
                store.allRecords()
                    .filter { it.canonicalId in liveIds }
                    .none(CanonicalRecord::tombstone),
            )
            assertEquals(2, merge(listOf(liveChild, liveParent), staged).ignored)
        }
    }

    @Test
    fun directAndStagedSingleSelfParentRejectConsistently() = runBlocking {
        val selfParent = nestedNode(
            id = "self-parent",
            parentCanonicalId = "apple.healthkit:self-parent",
            version = 1,
            tombstone = false,
        )

        val directError = try {
            store.upsert(listOf(selfParent))
            null
        } catch (error: ArchiveFormatException) {
            error
        }
        assertEquals(
            "Canonical records contain a parent cycle.",
            directError?.message,
        )
        assertTrue(store.allRecords().isEmpty())

        val import = store.beginImport()
        import.append(listOf(selfParent))
        val stagedError = try {
            import.commit()
            null
        } catch (error: ArchiveFormatException) {
            error
        }
        assertEquals(
            "Canonical records contain a parent cycle.",
            stagedError?.message,
        )
        import.discard()
        assertTrue(store.allRecords().isEmpty())
    }

    @Test
    fun splitImportCyclesRejectAgainstPersistedGraphInDirectAndStagedMerges() =
        runBlocking {
            for ((prefix, staged) in
                listOf("direct-cycle" to false, "staged-cycle" to true)) {
                val first = nestedNode(
                    id = "$prefix-a",
                    parentCanonicalId = "apple.healthkit:$prefix-b",
                    version = 1,
                    tombstone = false,
                )
                if (staged) {
                    store.beginImport().let { import ->
                        import.append(listOf(first))
                        import.commit()
                    }
                } else {
                    store.upsert(listOf(first))
                }
                val closing = nestedNode(
                    id = "$prefix-b",
                    parentCanonicalId = first.canonicalId,
                    version = 1,
                    tombstone = false,
                )

                val error = try {
                    if (staged) {
                        store.beginImport().let { import ->
                            import.append(listOf(closing))
                            import.commit()
                        }
                    } else {
                        store.upsert(listOf(closing))
                    }
                    null
                } catch (failure: ArchiveFormatException) {
                    failure
                }

                assertEquals(
                    "Canonical records contain a parent cycle.",
                    error?.message,
                )
                assertTrue(
                    store.allRecords().none { it.canonicalId == closing.canonicalId },
                )
            }
        }

    @Test
    fun deferredWinnerCannotHideResultingCycleInDirectAndStagedMerges() =
        runBlocking {
            for ((prefix, staged) in
                listOf("direct-effective" to false, "staged-effective" to true)) {
                val persistedB = nestedNode(
                    id = "$prefix-b",
                    parentCanonicalId = null,
                    version = 1,
                    tombstone = false,
                )
                val persistedA = nestedNode(
                    id = "$prefix-a",
                    parentCanonicalId = persistedB.canonicalId,
                    version = 1,
                    tombstone = false,
                )
                val tombstonedC = nestedNode(
                    id = "$prefix-c",
                    parentCanonicalId = null,
                    version = 2,
                    tombstone = true,
                )
                store.upsert(listOf(persistedA, persistedB, tombstonedC))
                val before = store.allRecords()
                    .filter { it.canonicalId.startsWith("apple.healthkit:$prefix-") }
                    .associateBy(CanonicalRecord::canonicalId)
                val deferredA = nestedNode(
                    id = "$prefix-a",
                    parentCanonicalId = tombstonedC.canonicalId,
                    version = 3,
                    tombstone = false,
                )
                val closingB = nestedNode(
                    id = "$prefix-b",
                    parentCanonicalId = persistedA.canonicalId,
                    version = 2,
                    tombstone = false,
                )

                val error = if (staged) {
                    val import = store.beginImport()
                    import.append(listOf(deferredA, closingB))
                    try {
                        import.commit()
                        null
                    } catch (failure: ArchiveFormatException) {
                        import.discard()
                        failure
                    }
                } else {
                    try {
                        store.upsert(listOf(deferredA, closingB))
                        null
                    } catch (failure: ArchiveFormatException) {
                        failure
                    }
                }

                assertEquals(
                    "Canonical records contain a parent cycle.",
                    error?.message,
                )
                assertEquals(
                    before,
                    store.allRecords()
                        .filter {
                            it.canonicalId.startsWith("apple.healthkit:$prefix-")
                        }
                        .associateBy(CanonicalRecord::canonicalId),
                )
            }
        }

    @Test
    fun parentDepthLimitIsConsistentInDirectAndStagedMerges() = runBlocking {
        suspend fun merge(
            records: List<CanonicalRecord>,
            staged: Boolean,
        ): MergeResult = if (staged) {
            store.beginImport().let { import ->
                import.append(records)
                import.commit()
            }
        } else {
            store.upsert(records)
        }

        for ((prefix, staged) in
            listOf("direct-depth" to false, "staged-depth" to true)) {
            val chain = (0..MAX_CANONICAL_PARENT_DEPTH).map { index ->
                nestedNode(
                    id = "$prefix-$index",
                    parentCanonicalId = if (index == 0) {
                        null
                    } else {
                        "apple.healthkit:$prefix-${index - 1}"
                    },
                    version = 1,
                    tombstone = false,
                )
            }
            val lookupsBefore = store.parentStateLookupCountForTesting
            merge(chain.asReversed(), staged)
            val parentLookups =
                store.parentStateLookupCountForTesting - lookupsBefore
            val maximumLookupsPerRecord = if (staged) 4 else 6
            assertTrue(
                "$prefix used $parentLookups parent lookups",
                parentLookups <= chain.size * maximumLookupsPerRecord,
            )
            val tooDeep = nestedNode(
                id = "$prefix-${MAX_CANONICAL_PARENT_DEPTH + 1}",
                parentCanonicalId = chain.last().canonicalId,
                version = 1,
                tombstone = false,
            )

            val error = try {
                merge(listOf(tooDeep), staged)
                null
            } catch (failure: ArchiveFormatException) {
                failure
            }

            assertEquals(
                "Canonical parent depth exceeds the 64 level limit.",
                error?.message,
            )
            assertTrue(
                store.allRecords().none {
                    it.canonicalId == tooDeep.canonicalId
                },
            )
        }
    }

    @Test
    fun reparentingAncestorPastDepthLimitRollsBackDirectAndStagedMerges() =
        runBlocking {
            for ((prefix, staged) in
                listOf("direct-reparent" to false, "staged-reparent" to true)) {
                val newRoot = nestedNode(
                    id = "$prefix-new-root",
                    parentCanonicalId = null,
                    version = 1,
                    tombstone = false,
                )
                val chain = (0..MAX_CANONICAL_PARENT_DEPTH).map { index ->
                    nestedNode(
                        id = "$prefix-$index",
                        parentCanonicalId = if (index == 0) {
                            null
                        } else {
                            "apple.healthkit:$prefix-${index - 1}"
                        },
                        version = 1,
                        tombstone = false,
                    )
                }
                store.upsert(listOf(newRoot) + chain.asReversed())
                val ids = (chain.map(CanonicalRecord::canonicalId) +
                    newRoot.canonicalId).toSet()
                val before = store.allRecords()
                    .filter { it.canonicalId in ids }
                    .associateBy(CanonicalRecord::canonicalId)
                val reparented = chain.first().copy(
                    parentCanonicalId = newRoot.canonicalId,
                    recordVersion = 2,
                )

                val error = if (staged) {
                    val import = store.beginImport()
                    import.append(listOf(reparented))
                    try {
                        import.commit()
                        null
                    } catch (failure: ArchiveFormatException) {
                        import.discard()
                        failure
                    }
                } else {
                    try {
                        store.upsert(listOf(reparented))
                        null
                    } catch (failure: ArchiveFormatException) {
                        failure
                    }
                }

                assertEquals(
                    "Canonical parent depth exceeds the 64 level limit.",
                    error?.message,
                )
                assertEquals(
                    before,
                    store.allRecords()
                        .filter { it.canonicalId in ids }
                        .associateBy(CanonicalRecord::canonicalId),
                )
            }
        }

    @Test
    fun missingRootTransitionsReconcileDeepDescendantsInDirectAndStagedMerges() =
        runBlocking {
            suspend fun merge(
                records: List<CanonicalRecord>,
                staged: Boolean,
            ): MergeResult = if (staged) {
                store.beginImport().let { import ->
                    import.append(records)
                    import.commit()
                }
            } else {
                store.upsert(records)
            }

            for ((prefix, staged) in
                listOf("direct-deep" to false, "staged-deep" to true)) {
                val rootId = "apple.healthkit:$prefix-root"
                val parent = nestedNode("$prefix-parent", rootId, 1, false)
                val child = nestedNode(
                    "$prefix-child",
                    parent.canonicalId,
                    1,
                    false,
                )
                val grandchild = nestedNode(
                    "$prefix-grandchild",
                    child.canonicalId,
                    1,
                    false,
                )
                merge(listOf(grandchild, child, parent), staged)

                val tombstone = nestedNode("$prefix-root", null, 2, true)
                merge(listOf(tombstone), staged)
                val ids = setOf(
                    tombstone.canonicalId,
                    parent.canonicalId,
                    child.canonicalId,
                    grandchild.canonicalId,
                )
                assertTrue(
                    store.allRecords()
                        .filter { it.canonicalId in ids }
                        .all(CanonicalRecord::tombstone),
                )

                val liveRoot = nestedNode("$prefix-root", null, 3, false)
                val liveParent = nestedNode(
                    "$prefix-parent",
                    liveRoot.canonicalId,
                    3,
                    false,
                )
                val liveChild = nestedNode(
                    "$prefix-child",
                    liveParent.canonicalId,
                    3,
                    false,
                )
                val liveGrandchild = nestedNode(
                    "$prefix-grandchild",
                    liveChild.canonicalId,
                    3,
                    false,
                )
                val live = listOf(
                    liveGrandchild,
                    liveChild,
                    liveParent,
                    liveRoot,
                )
                merge(live, staged)

                assertTrue(
                    store.allRecords()
                        .filter { it.canonicalId in ids }
                        .none(CanonicalRecord::tombstone),
                )
                assertEquals(4, merge(live, staged).ignored)
            }
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
    fun pendingHealthConnectOperationSurvivesRestartAndCompletesAtomically() =
        runBlocking {
            val pending = PendingHealthConnectOperation(
                canonicalId = "apple.healthkit:pending-weight",
                targetRecord = "WeightRecord",
                canonicalVersion = 1,
                action = HealthConnectPendingAction.UPSERT,
            )
            store.stageHealthConnectOperations(listOf(pending))
            store.close()
            store = SqliteCanonicalRecordStore(context, databaseName)

            assertEquals(
                pending,
                store.pendingHealthConnectOperations(setOf(pending.canonicalId))
                    .getValue(pending.canonicalId),
            )
            val projection = HealthConnectProjection(
                canonicalId = pending.canonicalId,
                targetRecord = pending.targetRecord,
                canonicalVersion = pending.canonicalVersion,
                healthConnectRecordId = "health-pending",
            )
            store.completeHealthConnectUpserts(listOf(projection))
            assertEquals(
                projection,
                store.healthConnectProjections(setOf(pending.canonicalId))
                    .getValue(pending.canonicalId),
            )
            assertTrue(
                store.pendingHealthConnectOperations(setOf(pending.canonicalId))
                    .isEmpty(),
            )

            val deletion = pending.copy(
                canonicalVersion = 2,
                action = HealthConnectPendingAction.DELETE,
            )
            store.stageHealthConnectOperations(listOf(deletion))
            store.completeHealthConnectDeletes(listOf(deletion))
            assertTrue(
                store.healthConnectProjections(setOf(pending.canonicalId)).isEmpty(),
            )
            assertTrue(
                store.pendingHealthConnectOperations(setOf(pending.canonicalId))
                    .isEmpty(),
            )
            store.close()
            store = SqliteCanonicalRecordStore(context, databaseName)
            var staleRejected = false
            try {
                store.stageHealthConnectOperations(listOf(pending))
            } catch (_: IllegalStateException) {
                staleRejected = true
            }
            assertTrue(staleRejected)
        }

    @Test
    fun sameVersionPendingDeleteCannotBeReplacedByUpsert() = runBlocking {
        val deletion = PendingHealthConnectOperation(
            canonicalId = "apple.healthkit:pending-delete",
            targetRecord = "WeightRecord",
            canonicalVersion = 2,
            action = HealthConnectPendingAction.DELETE,
        )
        store.stageHealthConnectOperations(listOf(deletion))

        var rejected = false
        try {
            store.stageHealthConnectOperations(
                listOf(deletion.copy(action = HealthConnectPendingAction.UPSERT)),
            )
        } catch (_: IllegalStateException) {
            rejected = true
        }

        assertTrue(rejected)
        assertEquals(
            deletion,
            store.pendingHealthConnectOperations(setOf(deletion.canonicalId))
                .getValue(deletion.canonicalId),
        )
    }

    @Test
    fun completedOperationCanBeStagedAgainAsIdempotentNoOp() = runBlocking {
        val upsert = PendingHealthConnectOperation(
            canonicalId = "apple.healthkit:completed-retry",
            targetRecord = "WeightRecord",
            canonicalVersion = 1,
            action = HealthConnectPendingAction.UPSERT,
        )
        store.stageHealthConnectOperations(listOf(upsert))
        store.completeHealthConnectUpserts(
            listOf(
                HealthConnectProjection(
                    canonicalId = upsert.canonicalId,
                    targetRecord = upsert.targetRecord,
                    canonicalVersion = upsert.canonicalVersion,
                    healthConnectRecordId = "health-completed",
                )
            )
        )

        store.stageHealthConnectOperations(listOf(upsert))

        assertTrue(
            store.pendingHealthConnectOperations(setOf(upsert.canonicalId)).isEmpty(),
        )
    }

    @Test
    fun timelineUsesIndexedFullPrecisionOrderAcrossPages() = runBlocking {
        val times = listOf(
            "fraction-999" to Instant.parse("2026-01-01T00:00:00.999999999Z"),
            "fraction-100" to Instant.parse("2026-01-01T00:00:00.100Z"),
            "fraction-001" to Instant.parse("2026-01-01T00:00:00.000000001Z"),
            "whole" to Instant.parse("2026-01-01T00:00:00Z"),
        )
        val records = times.map { (id, time) ->
            record(version = 1, tombstone = false).copy(
                canonicalId = "apple.healthkit:$id",
                sourceRecordId = id,
                startTime = time,
                endTime = time,
            )
        } + record(version = 1, tombstone = false).copy(
            canonicalId = "apple.healthkit:no-time",
            sourceRecordId = "no-time",
            startTime = null,
            endTime = null,
        )
        store.upsert(records)

        val seen = mutableListOf<String>()
        var cursor: TimelineCursor? = null
        do {
            val page = store.timelinePage(cursor, limit = 1)
            seen += page.records.map(CanonicalRecord::canonicalId)
            cursor = page.nextCursor
        } while (page.records.isNotEmpty())

        assertEquals(
            listOf(
                "apple.healthkit:fraction-999",
                "apple.healthkit:fraction-100",
                "apple.healthkit:fraction-001",
                "apple.healthkit:whole",
                "apple.healthkit:no-time",
            ),
            seen,
        )
        store.close()
        context.openOrCreateDatabase(databaseName, 0, null).use { database ->
            database.execSQL(
                "UPDATE canonical_record SET timeline_sort_key = NULL",
            )
            database.version = 10
        }
        store = SqliteCanonicalRecordStore(context, databaseName)
        val migratedOrder = store.timelinePage(null, limit = 10)
            .records
            .map(CanonicalRecord::canonicalId)
        assertEquals(
            seen,
            migratedOrder,
        )
        for (plan in listOf(
            store.timelineQueryPlan(null),
            store.timelineQueryPlan(
                TimelineCursor(times.first().second, "apple.healthkit:fraction-999"),
            ),
        )) {
            assertTrue(plan.any { it.contains("canonical_record_timeline") })
            assertTrue(plan.none { it.contains("TEMP B-TREE") })
        }
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

    private fun nestedChain(
        prefix: String,
        version: Long,
        rootTombstone: Boolean,
    ): List<CanonicalRecord> {
        val root = nestedNode("$prefix-z-root", null, version, rootTombstone)
        val parent = nestedNode(
            "$prefix-m-parent",
            root.canonicalId,
            version,
            tombstone = false,
        )
        val child = nestedNode(
            "$prefix-a-child",
            parent.canonicalId,
            version,
            tombstone = false,
        )
        return listOf(root, parent, child)
    }

    private fun nestedNode(
        id: String,
        parentCanonicalId: String?,
        version: Long,
        tombstone: Boolean,
    ): CanonicalRecord = record(version, tombstone).copy(
        canonicalId = "apple.healthkit:$id",
        parentCanonicalId = parentCanonicalId,
        sourceRecordId = id,
        lineage = listOf(SourceLineage("apple.healthkit", recordId = id)),
    )
}
