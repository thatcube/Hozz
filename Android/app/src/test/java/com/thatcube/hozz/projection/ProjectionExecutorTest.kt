package com.thatcube.hozz.projection

import android.os.RemoteException
import androidx.health.connect.client.HealthConnectClient
import com.thatcube.hozz.healthConnectCompletionStatus
import com.thatcube.hozz.core.CanonicalRecord
import com.thatcube.hozz.core.CanonicalValue
import com.thatcube.hozz.core.HealthConnectProjection
import com.thatcube.hozz.core.HealthConnectPendingAction
import com.thatcube.hozz.core.InMemoryCanonicalRecordStore
import com.thatcube.hozz.core.PendingHealthConnectOperation
import com.thatcube.hozz.core.SourceLineage
import java.io.IOException
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProjectionExecutorTest {
    @Test
    fun standaloneProviderDeleteRetryIsRejectedSoApi28To33ProjectionIsGated() =
        runBlocking {
            val clientRecordId = "apple.healthkit:delete-recovery"
            val provider = StandaloneDeleteProviderFake(setOf(clientRecordId))

            provider.deleteByClientRecordId(clientRecordId)
            val retryAfterCrashBeforeLedgerCompletion = runCatching {
                provider.deleteByClientRecordId(clientRecordId)
            }.exceptionOrNull()

            assertTrue(retryAfterCrashBeforeLedgerCompletion is RemoteException)
            assertEquals(2, provider.deleteCalls)
            for (sdk in 28..33) {
                assertEquals(
                    HealthConnectClient.SDK_UNAVAILABLE,
                    healthConnectProjectionStatus(sdk) {
                        HealthConnectClient.SDK_AVAILABLE
                    },
                )
            }
            assertEquals(
                HealthConnectClient.SDK_AVAILABLE,
                healthConnectProjectionStatus(34) {
                    HealthConnectClient.SDK_AVAILABLE
                },
            )
        }

    @Test
    fun providerFailureAbortsLargeProjectionWithoutSingletonFanOut() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val failure = IOException("provider database unavailable")
        val writer = FakeWriter(providerUpsertFailure = failure)
        val operations = (1..10_000).map { index ->
            ProjectionPlanner.plan(live("provider-failure-$index"))
        }

        val thrown = runCatching {
            executor(store, writer).apply(operations)
        }.exceptionOrNull()

        assertTrue(thrown is IOException)
        assertEquals(failure.message, thrown?.message)
        assertEquals(listOf(500), writer.batchSizes)
        assertEquals(
            500,
            store.pendingHealthConnectOperations(
                operations.mapTo(linkedSetOf()) { it.source.canonicalId },
            ).size,
        )
    }

    @Test
    fun providerReceiptCountMismatchDoesNotRetryRecordsIndividually() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val writer = FakeWriter(providerReceiptCountMismatch = true)
        val operations = (1..10_000).map { index ->
            ProjectionPlanner.plan(live("receipt-mismatch-$index"))
        }

        val thrown = runCatching {
            executor(store, writer).apply(operations)
        }.exceptionOrNull()

        assertTrue(thrown is HealthConnectProviderProtocolException)
        assertEquals(listOf(500), writer.batchSizes)
        assertEquals(
            500,
            store.pendingHealthConnectOperations(
                operations.mapTo(linkedSetOf()) { it.source.canonicalId },
            ).size,
        )
    }

    @Test
    fun recordLocalFailuresRetainOnlyBoundedDetails() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val operations = (1..1_000).map { index ->
            ProjectionPlanner.plan(live("record-failure-$index"))
        }
        val failedIds = operations.mapTo(hashSetOf()) { it.source.canonicalId }
        val writer = FakeWriter(failUpserts = failedIds)
        val executor = executor(store, writer)

        val firstPage = executor.apply(operations.take(500))
        val callsAtCeiling = writer.batchSizes.size
        val secondPage = executor.apply(operations.drop(500))

        assertEquals(0, firstPage.inserted)
        assertEquals(100, firstPage.failureCount)
        assertEquals(MAX_RETAINED_PROJECTION_FAILURES, firstPage.failures.size)
        assertTrue(firstPage.retryCeilingReached)
        assertTrue(secondPage.retryCeilingReached)
        assertEquals(callsAtCeiling, writer.batchSizes.size)
        assertTrue(writer.batchSizes.size <= 101)
        val ids = operations.mapTo(linkedSetOf()) { it.source.canonicalId }
        val pending = store.pendingHealthConnectOperations(ids)
        assertEquals(500, pending.size)
        assertEquals(
            1_000,
            ProjectionPlanner.plan(
                operations.map(PlannedRecord::source),
                projections = store.healthConnectProjections(ids),
                pending = pending,
            ).summary().pendingCount,
        )
    }

    @Test
    fun exactlyHundredRecordLocalUpsertRetriesAllSucceedWithoutCeiling() =
        runBlocking {
            val store = InMemoryCanonicalRecordStore()
            val operations = (1..100).map { index ->
                ProjectionPlanner.plan(live("upsert-retry-$index"))
            }
            val writer = FakeWriter(failUpsertBatches = true)

            val result = executor(store, writer).apply(operations)

            assertEquals(100, result.inserted)
            assertEquals(0, result.failureCount)
            assertFalse(result.retryCeilingReached)
            assertEquals(
                "Health Connect applied 100 inserts, 0 updates, and 0 deletions.",
                healthConnectCompletionStatus(result, permissionDeferred = 0),
            )
        }

    @Test
    fun exactlyHundredRecordLocalDeleteRetriesAllSucceedWithoutCeiling() =
        runBlocking {
            val store = InMemoryCanonicalRecordStore()
            val operations = (1..100).map { index ->
                val record = tombstone("delete-retry-$index")
                val prior = projection(
                    record.canonicalId,
                    version = 1,
                    recordId = "health-delete-retry-$index",
                )
                store.saveHealthConnectProjections(listOf(prior))
                ProjectionPlanner.plan(record, prior)
            }
            val writer = FakeWriter(failDeleteBatches = true)

            val result = executor(store, writer).apply(operations)

            assertEquals(100, result.deleted)
            assertEquals(0, result.failureCount)
            assertFalse(result.retryCeilingReached)
            assertEquals(
                "Health Connect applied 0 inserts, 0 updates, and 100 deletions.",
                healthConnectCompletionStatus(result, permissionDeferred = 0),
            )
        }

    @Test
    fun unresolvedFailureCarriesAcrossEightyAndTwentyRetryPages() =
        runBlocking {
            val store = InMemoryCanonicalRecordStore()
            val firstPage = (1..80).map { index ->
                ProjectionPlanner.plan(live("eighty-$index"))
            }
            val secondPage = (1..20).map { index ->
                ProjectionPlanner.plan(live("twenty-$index"))
            }
            val failedId = firstPage.last().source.canonicalId
            val writer = FakeWriter(
                failUpserts = setOf(failedId),
                failUpsertBatches = true,
            )
            val executor = executor(store, writer)

            val firstResult = executor.apply(firstPage)
            val secondResult = executor.apply(secondPage)
            val combined = firstResult + secondResult

            assertEquals(79, firstResult.inserted)
            assertEquals(1, firstResult.failureCount)
            assertFalse(firstResult.retryCeilingReached)
            assertEquals(20, secondResult.inserted)
            assertEquals(0, secondResult.failureCount)
            assertTrue(secondResult.retryCeilingReached)
            assertEquals(99, combined.inserted)
            assertEquals(1, combined.failureCount)
            assertTrue(combined.retryCeilingReached)
        }

    @Test
    fun retryCeilingIsReportedWhenHundredAndFirstRecordRemainsUnattempted() =
        runBlocking {
            val store = InMemoryCanonicalRecordStore()
            val operations = (1..101).map { index ->
                ProjectionPlanner.plan(live("continuation-$index"))
            }
            val writer = FakeWriter(failUpsertBatches = true)

            val result = executor(store, writer).apply(operations)

            assertEquals(100, result.inserted)
            assertEquals(0, result.failureCount)
            assertTrue(result.retryCeilingReached)
            assertEquals(101, writer.batchSizes.size)
            assertEquals(
                100,
                store.healthConnectProjections(
                    operations.mapTo(linkedSetOf()) { it.source.canonicalId },
                ).size,
            )
        }

    @Test
    fun exhaustedRetryBudgetStopsLaterPageAndViewModelReportsPending() =
        runBlocking {
            val store = InMemoryCanonicalRecordStore()
            val firstPage = (1..100).map { index ->
                ProjectionPlanner.plan(live("page-one-$index"))
            }
            val laterPage = listOf(
                ProjectionPlanner.plan(live("page-two-1")),
            )
            val writer = FakeWriter(failUpsertBatches = true)
            val executor = executor(store, writer)
            var result = ProjectionExecutionResult()
            var pagesAttempted = 0

            for (page in listOf(firstPage, laterPage)) {
                pagesAttempted += 1
                val pageResult = executor.apply(page)
                result += pageResult
                if (pageResult.retryCeilingReached) break
            }

            assertEquals(2, pagesAttempted)
            assertEquals(100, result.inserted)
            assertTrue(result.retryCeilingReached)
            assertTrue(
                healthConnectCompletionStatus(result, permissionDeferred = 0)
                    .endsWith(
                        "The per-run retry limit was reached; " +
                            "remaining records stay pending.",
                    ),
            )
            assertTrue(
                store.healthConnectProjections(
                    setOf(laterPage.single().source.canonicalId),
                ).isEmpty(),
            )
        }

    @Test
    fun finalSingletonFailureAtRetryBoundaryReportsCeiling() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val operations = (1..100).map { index ->
            ProjectionPlanner.plan(live("final-failure-$index"))
        }
        val failedId = operations.last().source.canonicalId
        val writer = FakeWriter(
            failUpserts = setOf(failedId),
            failUpsertBatches = true,
        )

        val result = executor(store, writer).apply(operations)

        assertEquals(99, result.inserted)
        assertEquals(1, result.failureCount)
        assertEquals(failedId, result.failures.single().canonicalId)
        assertTrue(result.retryCeilingReached)
    }

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
        assertEquals(
            2,
            store.pendingHealthConnectOperations(
                setOf(cancelled.canonicalId, later.canonicalId),
            ).size,
        )
    }

    @Test
    fun callerCancellationWaitsForSubmittedMutationAndCompletion() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val record = live("cancel-after-submit")
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val writer = object : HealthConnectProjectionWriter {
            override suspend fun writeUpserts(
                drafts: List<ProjectionDraft>,
            ): HealthConnectWriteResult {
                started.complete(Unit)
                release.await()
                return HealthConnectWriteResult(
                    attempted = 1,
                    projections = listOf(
                        projection(
                            drafts.single().canonicalId,
                            drafts.single().recordVersion,
                            "health-after-cancel",
                        )
                    ),
                )
            }

            override suspend fun delete(
                drafts: List<ProjectionDraft.Delete>,
            ): List<HealthConnectProjection> = error("not used")
        }
        val job = launch {
            executor(store, writer).apply(listOf(ProjectionPlanner.plan(record)))
        }
        started.await()

        job.cancel()
        release.complete(Unit)
        job.join()

        assertEquals(
            "health-after-cancel",
            store.healthConnectProjections(setOf(record.canonicalId))
                .getValue(record.canonicalId)
                .healthConnectRecordId,
        )
        assertTrue(
            store.pendingHealthConnectOperations(setOf(record.canonicalId))
                .isEmpty(),
        )
    }

    @Test
    fun writeSuccessBeforeLedgerCompletionRemainsRecoverable() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val live = live("crash-window")
        val writer = FakeWriter()
        val executor = ProjectionExecutor(
            writer = writer,
            stageOperations = store::stageHealthConnectOperations,
            completeUpserts = { throw IOException("process stopped before commit") },
            completeDeletes = store::completeHealthConnectDeletes,
        )

        var failed = false
        try {
            executor.apply(listOf(ProjectionPlanner.plan(live)))
        } catch (_: IOException) {
            failed = true
        }

        assertTrue(failed)
        val pending = store.pendingHealthConnectOperations(setOf(live.canonicalId))
            .getValue(live.canonicalId)
        assertTrue(
            store.healthConnectProjections(setOf(live.canonicalId)).isEmpty(),
        )
        val deletion = ProjectionPlanner.plan(
            live.copy(recordVersion = 2, tombstone = true),
            pending = pending,
        )
        assertEquals(ProjectionAction.DELETE, deletion.action)
        assertEquals(
            live.canonicalId,
            (deletion.draft as ProjectionDraft.Delete).canonicalId,
        )
    }

    @Test
    fun committedTargetCannotBeReplacedByAnotherRecordType() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val canonicalId = "apple.healthkit:target-mutation"
        store.saveHealthConnectProjections(
            listOf(projection(canonicalId, 1, "health-weight")),
        )
        var rejected = false

        try {
            store.stageHealthConnectOperations(
                listOf(
                    PendingHealthConnectOperation(
                        canonicalId = canonicalId,
                        targetRecord = "HeightRecord",
                        canonicalVersion = 2,
                        action = HealthConnectPendingAction.UPSERT,
                    )
                )
            )
        } catch (_: IllegalStateException) {
            rejected = true
        }

        assertTrue(rejected)
        assertTrue(
            store.pendingHealthConnectOperations(setOf(canonicalId)).isEmpty(),
        )
    }

    @Test
    fun sameVersionPendingDeleteCannotBeReplacedByUpsert() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
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
        val store = InMemoryCanonicalRecordStore()
        val upsert = PendingHealthConnectOperation(
            canonicalId = "apple.healthkit:completed-retry",
            targetRecord = "WeightRecord",
            canonicalVersion = 1,
            action = HealthConnectPendingAction.UPSERT,
        )
        store.stageHealthConnectOperations(listOf(upsert))
        store.completeHealthConnectUpserts(
            listOf(projection(upsert.canonicalId, 1, "health-completed")),
        )

        store.stageHealthConnectOperations(listOf(upsert))

        assertTrue(
            store.pendingHealthConnectOperations(setOf(upsert.canonicalId)).isEmpty(),
        )
    }

    @Test
    fun completedDeleteRejectsStaleUpsertAndCannotEraseNewerLedger() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val canonicalId = "apple.healthkit:high-water"
        val upsertOne = PendingHealthConnectOperation(
            canonicalId = canonicalId,
            targetRecord = "WeightRecord",
            canonicalVersion = 1,
            action = HealthConnectPendingAction.UPSERT,
        )
        store.stageHealthConnectOperations(listOf(upsertOne))
        store.completeHealthConnectUpserts(
            listOf(projection(canonicalId, 1, "health-1")),
        )
        val deleteTwo = upsertOne.copy(
            canonicalVersion = 2,
            action = HealthConnectPendingAction.DELETE,
        )
        store.stageHealthConnectOperations(listOf(deleteTwo))
        store.completeHealthConnectDeletes(listOf(deleteTwo))
        store.completeHealthConnectUpserts(
            listOf(projection(canonicalId, 1, "late-health-1")),
        )
        assertTrue(
            store.healthConnectProjections(setOf(canonicalId)).isEmpty(),
        )

        var rejected = false
        try {
            store.stageHealthConnectOperations(listOf(upsertOne))
        } catch (_: IllegalStateException) {
            rejected = true
        }
        assertTrue(rejected)

        val upsertThree = upsertOne.copy(canonicalVersion = 3)
        store.stageHealthConnectOperations(listOf(upsertThree))
        val newest = projection(canonicalId, 3, "health-3")
        store.completeHealthConnectUpserts(listOf(newest))
        store.completeHealthConnectDeletes(listOf(deleteTwo))

        assertEquals(
            newest,
            store.healthConnectProjections(setOf(canonicalId))
                .getValue(canonicalId),
        )
    }

    @Test
    fun sameVersionArchiveOnlyCleanupCanDeleteCommittedProjection() = runBlocking {
        val store = InMemoryCanonicalRecordStore()
        val record = live("same-version-cleanup").copy(
            canonicalType = "activity.steps",
            type = "HKQuantityTypeIdentifierStepCount",
        )
        val prior = HealthConnectProjection(
            canonicalId = record.canonicalId,
            targetRecord = "StepsRecord",
            canonicalVersion = record.recordVersion,
            healthConnectRecordId = "legacy-step",
        )
        store.saveHealthConnectProjections(listOf(prior))

        val result = executor(store, FakeWriter()).apply(
            listOf(ProjectionPlanner.plan(record, prior)),
        )

        assertEquals(1, result.deleted)
        assertTrue(
            store.healthConnectProjections(setOf(record.canonicalId)).isEmpty(),
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
        stageOperations = store::stageHealthConnectOperations,
        completeUpserts = store::completeHealthConnectUpserts,
        completeDeletes = store::completeHealthConnectDeletes,
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
        private val providerUpsertFailure: IOException? = null,
        private val providerReceiptCountMismatch: Boolean = false,
        private val failUpsertBatches: Boolean = false,
        private val failDeleteBatches: Boolean = false,
    ) : HealthConnectProjectionWriter {
        val calls = mutableListOf<String>()
        val batchSizes = mutableListOf<Int>()
        val deleteBatchSizes = mutableListOf<Int>()

        override suspend fun writeUpserts(
            drafts: List<ProjectionDraft>,
        ): HealthConnectWriteResult {
            batchSizes += drafts.size
            calls += "insert:${drafts.joinToString(",") { it.canonicalId }}"
            providerUpsertFailure?.let { throw it }
            if (providerReceiptCountMismatch) {
                validateHealthConnectReceiptCount(
                    expected = drafts.size,
                    actual = drafts.size - 1,
                )
            }
            if (failUpsertBatches && drafts.size > 1) {
                throw IllegalArgumentException("upsert batch failed")
            }
            if (drafts.any { it.canonicalId in cancelUpserts }) {
                throw CancellationException("cancelled")
            }
            if (drafts.any { it.canonicalId in failUpserts }) {
                throw IllegalArgumentException("insert failed")
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
            if (failDeleteBatches && drafts.size > 1) {
                throw IllegalArgumentException("delete batch failed")
            }
            if (drafts.any { it.canonicalId in failDeletes }) {
                throw IllegalArgumentException("delete failed")
            }
            return drafts.map { draft ->
                HealthConnectProjection(
                    canonicalId = draft.canonicalId,
                    targetRecord = draft.targetRecord,
                    canonicalVersion = draft.recordVersion,
                    healthConnectRecordId =
                        draft.healthConnectRecordId.orEmpty(),
                )
            }
        }
    }

    private class StandaloneDeleteProviderFake(
        clientRecordIds: Set<String>,
    ) {
        private val clientRecordIds = clientRecordIds.toMutableSet()
        var deleteCalls = 0
            private set

        fun deleteByClientRecordId(clientRecordId: String) {
            deleteCalls += 1
            if (!clientRecordIds.remove(clientRecordId)) {
                throw RemoteException(
                    "Deleting the same record multiple times results in IPC failure.",
                )
            }
        }
    }
}
