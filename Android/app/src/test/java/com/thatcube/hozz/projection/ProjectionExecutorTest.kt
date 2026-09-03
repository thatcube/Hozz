package com.thatcube.hozz.projection

import com.thatcube.hozz.core.CanonicalRecord
import com.thatcube.hozz.core.CanonicalValue
import com.thatcube.hozz.core.HealthConnectProjection
import com.thatcube.hozz.core.InMemoryCanonicalRecordStore
import com.thatcube.hozz.core.SourceLineage
import java.io.IOException
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProjectionExecutorTest {
    @Test
    fun largeDeletionSetsUseBoundedPerTypeBatches() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val writer = FakeWriter()
        val operations = (1..501).map { index ->
            val record = tombstone("delete-batch-$index")
            val prior = projection(
                record.canonicalId,
                1,
                "health-$index",
            )
            store.saveHealthConnectProjections(listOf(prior))
            ProjectionPlanner.plan(record, prior)
        }

        val result = executor(store, writer).apply(operations)

        assertEquals(501, result.deleted)
        assertEquals(listOf(500, 1), writer.deleteBatchSizes)
        assertTrue(
            store.healthConnectProjections(
                operations.map { it.source.canonicalId }.toSet(),
            ).isEmpty(),
        )
    }

    @Test
    fun cancellationStopsWithoutMutatingLaterLedgerEntries() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val cancelled = live("cancelled")
        val later = live("must-not-run")
        val writer = FakeWriter(cancelUpserts = setOf(cancelled.canonicalId))

        var wasCancelled = false
        try {
            executor(store, writer).apply(
                listOf(
                    ProjectionPlanner.plan(cancelled),
                    ProjectionPlanner.plan(later),
                ),
            )
        } catch (_: CancellationException) {
            wasCancelled = true
        }

        assertTrue(wasCancelled)
        assertTrue(
            store.healthConnectProjections(
                setOf(cancelled.canonicalId, later.canonicalId),
            ).isEmpty(),
        )
    }

    @Test
    fun largeUpsertSetsUseBoundedHealthConnectBatches() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val writer = FakeWriter()
        val operations = (1..501).map { index ->
            ProjectionPlanner.plan(live("batch-$index"))
        }

        val result = executor(store, writer).apply(operations)

        assertEquals(501, result.inserted)
        assertEquals(listOf(500, 1), writer.batchSizes)
        assertEquals(
            501,
            store.healthConnectProjections(
                operations.map { it.source.canonicalId }.toSet(),
            ).size,
        )
    }

    @Test
    fun failedDeleteKeepsLedgerAndDoesNotSkipUnrelatedInsert() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val deletion = tombstone("delete-fails")
        val prior = projection(deletion.canonicalId, 1, "old-health-id")
        store.saveHealthConnectProjections(listOf(prior))
        val insertion = live("insert-succeeds")
        val writer = FakeWriter(failDeletes = setOf(deletion.canonicalId))
        val executor = executor(store, writer)

        val result = executor.apply(
            listOf(
                ProjectionPlanner.plan(deletion, prior),
                ProjectionPlanner.plan(insertion),
            ),
        )

        assertEquals(1, result.inserted)
        assertEquals(0, result.deleted)
        assertEquals(1, result.failures.size)
        assertEquals(
            prior,
            store.healthConnectProjections(setOf(deletion.canonicalId))[
                deletion.canonicalId
            ],
        )
        assertTrue(
            store.healthConnectProjections(setOf(insertion.canonicalId))
                .containsKey(insertion.canonicalId),
        )
    }

    @Test
    fun failedInsertAfterSuccessfulDeleteLeavesTruthfulLedgerAndContinues() =
        runBlocking {
            val store = InMemoryCanonicalRecordStore()
            val deletion = tombstone("delete-succeeds")
            val prior = projection(deletion.canonicalId, 1, "old-health-id")
            store.saveHealthConnectProjections(listOf(prior))
            val failed = live("insert-fails")
            val succeeded = live("insert-after-failure")
            val writer = FakeWriter(failUpserts = setOf(failed.canonicalId))
            val executor = executor(store, writer)

            val result = executor.apply(
                listOf(
                    ProjectionPlanner.plan(failed),
                    ProjectionPlanner.plan(deletion, prior),
                    ProjectionPlanner.plan(succeeded),
                ),
            )

            assertEquals(1, result.inserted)
            assertEquals(1, result.deleted)
            assertEquals(1, result.failures.size)
            val ledger = store.healthConnectProjections(
                setOf(deletion.canonicalId, failed.canonicalId, succeeded.canonicalId),
            )
            assertFalse(ledger.containsKey(deletion.canonicalId))
            assertFalse(ledger.containsKey(failed.canonicalId))
            assertTrue(ledger.containsKey(succeeded.canonicalId))
            assertEquals(
                listOf(
                    "delete:${deletion.canonicalId}",
                    "insert:${failed.canonicalId},${succeeded.canonicalId}",
                    "insert:${failed.canonicalId}",
                    "insert:${succeeded.canonicalId}",
                ),
                writer.calls,
            )
        }

    private fun executor(
        store: InMemoryCanonicalRecordStore,
        writer: HealthConnectProjectionWriter,
    ) = ProjectionExecutor(
        writer = writer,
        saveProjections = store::saveHealthConnectProjections,
        removeProjections = store::removeHealthConnectProjections,
    )

    private fun live(id: String) = record(id, version = 1, tombstone = false)

    private fun tombstone(id: String) =
        record(id, version = 2, tombstone = true)

    private fun record(
        id: String,
        version: Long,
        tombstone: Boolean,
    ) = CanonicalRecord(
        canonicalId = "apple.healthkit:$id",
        parentCanonicalId = null,
        recordVersion = version,
        kind = "quantity",
        canonicalType = "body.weight",
        type = "HKQuantityTypeIdentifierBodyMass",
        startTime = Instant.parse("2026-01-01T00:00:00Z"),
        endTime = Instant.parse("2026-01-01T00:00:00Z"),
        canonicalValue = CanonicalValue(1.0, "kg"),
        originalValue = CanonicalValue(1.0, "kg"),
        categoryValue = null,
        activityType = null,
        quantityCount = 1,
        sourceRecordId = id,
        sourceRecordVersion = version,
        sourceStore = "apple.healthkit",
        sourceBundleIdentifier = "com.example.source",
        sourceName = "Fixture",
        deviceJson = """{"model":"fixture"}""",
        metadataJson = """{"fixture":true}""",
        lineage = listOf(SourceLineage("apple.healthkit", null, id)),
        tombstone = tombstone,
        rawJson = "{}",
    )

    private fun projection(
        canonicalId: String,
        version: Long,
        recordId: String,
    ) = HealthConnectProjection(
        canonicalId = canonicalId,
        targetRecord = "WeightRecord",
        canonicalVersion = version,
        healthConnectRecordId = recordId,
    )

    private inner class FakeWriter(
        private val failDeletes: Set<String> = emptySet(),
        private val failUpserts: Set<String> = emptySet(),
        private val cancelUpserts: Set<String> = emptySet(),
    ) : HealthConnectProjectionWriter {
        val calls = mutableListOf<String>()
        val batchSizes = mutableListOf<Int>()
        val deleteBatchSizes = mutableListOf<Int>()

        override suspend fun writeUpserts(
            drafts: List<ProjectionDraft>,
        ): HealthConnectWriteResult {
            batchSizes += drafts.size
            calls += "insert:${drafts.joinToString(",") { it.canonicalId }}"
            if (drafts.any { it.canonicalId in cancelUpserts }) {
                throw CancellationException("cancelled")
            }
            if (drafts.any { it.canonicalId in failUpserts }) {
                throw IOException("insert failed")
            }
            return HealthConnectWriteResult(
                attempted = drafts.size,
                projections = drafts.map { draft ->
                    projection(
                        draft.canonicalId,
                        draft.recordVersion,
                        "health:${draft.canonicalId}",
                    )
                },
            )
        }

        override suspend fun delete(
            drafts: List<ProjectionDraft.Delete>,
        ): List<HealthConnectProjection> {
            deleteBatchSizes += drafts.size
            calls += "delete:${drafts.joinToString(",") { it.canonicalId }}"
            if (drafts.any { it.canonicalId in failDeletes }) {
                throw IOException("delete failed")
            }
            return drafts.map { draft ->
                projection(
                    draft.canonicalId,
                    draft.recordVersion,
                    draft.healthConnectRecordId,
                )
            }
        }
    }
}
