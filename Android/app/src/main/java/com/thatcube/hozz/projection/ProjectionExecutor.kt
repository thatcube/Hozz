package com.thatcube.hozz.projection

import android.os.RemoteException
import com.thatcube.hozz.core.HealthConnectProjection
import com.thatcube.hozz.core.HealthConnectPendingAction
import com.thatcube.hozz.core.PendingHealthConnectOperation
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

data class ProjectionFailure(
    val canonicalId: String,
    val action: ProjectionAction,
    val message: String,
)

data class ProjectionExecutionResult(
    val inserted: Int = 0,
    val updated: Int = 0,
    val deleted: Int = 0,
    val failures: List<ProjectionFailure> = emptyList(),
    val failureCount: Int = failures.size,
    val retryCeilingReached: Boolean = false,
) {
    operator fun plus(other: ProjectionExecutionResult) =
        ProjectionExecutionResult(
            inserted = inserted + other.inserted,
            updated = updated + other.updated,
            deleted = deleted + other.deleted,
            failures = buildList {
                addAll(failures.take(MAX_RETAINED_PROJECTION_FAILURES))
                addAll(
                    other.failures.take(
                        MAX_RETAINED_PROJECTION_FAILURES - size,
                    ),
                )
            },
            failureCount = failureCount + other.failureCount,
            retryCeilingReached =
                retryCeilingReached || other.retryCeilingReached,
        )
}

class ProjectionExecutor(
    private val writer: HealthConnectProjectionWriter,
    private val stageOperations:
        suspend (List<PendingHealthConnectOperation>) -> Unit,
    private val completeUpserts:
        suspend (List<HealthConnectProjection>) -> Unit,
    private val completeDeletes:
        suspend (List<PendingHealthConnectOperation>) -> Unit,
) {
    private var remainingSingletonAttempts =
        MAX_RECORD_LOCAL_RETRIES_PER_RUN

    suspend fun apply(
        operations: List<PlannedRecord>,
    ): ProjectionExecutionResult = executionMutex.withLock {
        applyLocked(operations)
    }

    private suspend fun applyLocked(
        operations: List<PlannedRecord>,
    ): ProjectionExecutionResult {
        var result = ProjectionExecutionResult()
        val deletions = operations
            .filter { it.action == ProjectionAction.DELETE }
            .mapNotNull { it.draft as? ProjectionDraft.Delete }
        for (
            chunk in deletions
                .groupBy(ProjectionDraft.Delete::targetRecord)
                .values
                .flatMap { it.chunked(MAX_PROJECTION_BATCH) }
        ) {
            if (remainingSingletonAttempts == 0) {
                return result.copy(retryCeilingReached = true)
            }
            stageOperations(
                chunk.map {
                    it.pending(HealthConnectPendingAction.DELETE)
                },
            )
            currentCoroutineContext().ensureActive()
            val batch = withContext(NonCancellable) {
                val attempted = attempt(
                    chunk.first().canonicalId,
                    ProjectionAction.DELETE,
                ) {
                    writer.delete(chunk)
                }
                if (attempted.value != null) {
                    result += acceptDeletions(chunk, attempted.value)
                    null
                } else {
                    attempted
                }
            }
            if (batch != null) {
                if (chunk.size == 1) {
                    remainingSingletonAttempts -= 1
                    result += ProjectionExecutionResult(
                        failures = listOfNotNull(batch.failure),
                    )
                    if (remainingSingletonAttempts == 0) {
                        return result.copy(retryCeilingReached = true)
                    }
                } else {
                    for (draft in chunk) {
                        if (remainingSingletonAttempts == 0) {
                            return result.copy(retryCeilingReached = true)
                        }
                        remainingSingletonAttempts -= 1
                        currentCoroutineContext().ensureActive()
                        result += withContext(NonCancellable) {
                            val single = attempt(
                                draft.canonicalId,
                                ProjectionAction.DELETE,
                            ) {
                                writer.delete(listOf(draft))
                            }
                            val removed = single.value
                            if (removed == null) {
                                ProjectionExecutionResult(
                                    failures = listOfNotNull(single.failure),
                                )
                            } else {
                                acceptDeletions(listOf(draft), removed)
                            }
                        }
                        if (remainingSingletonAttempts == 0) {
                            return result.copy(retryCeilingReached = true)
                        }
                    }
                }
            }
        }

        val upserts = operations.filter {
            it.action == ProjectionAction.INSERT ||
                it.action == ProjectionAction.UPDATE
        }
        for (chunk in upserts.chunked(MAX_PROJECTION_BATCH)) {
            if (remainingSingletonAttempts == 0) {
                return result.copy(retryCeilingReached = true)
            }
            val drafts = chunk.map { requireNotNull(it.draft) }
            stageOperations(
                drafts.map {
                    it.pending(HealthConnectPendingAction.UPSERT)
                },
            )
            currentCoroutineContext().ensureActive()
            val batch = withContext(NonCancellable) {
                val attempted = attempt(
                    drafts.first().canonicalId,
                    chunk.first().action,
                ) {
                    writer.writeUpserts(drafts)
                }
                if (attempted.value != null) {
                    result += acceptUpserts(chunk, attempted.value)
                    null
                } else {
                    attempted
                }
            }
            if (batch != null) {
                if (chunk.size == 1) {
                    remainingSingletonAttempts -= 1
                    result += ProjectionExecutionResult(
                        failures = listOfNotNull(batch.failure),
                    )
                    if (remainingSingletonAttempts == 0) {
                        return result.copy(retryCeilingReached = true)
                    }
                } else {
                    for (operation in chunk) {
                        if (remainingSingletonAttempts == 0) {
                            return result.copy(retryCeilingReached = true)
                        }
                        val draft = operation.draft ?: continue
                        remainingSingletonAttempts -= 1
                        currentCoroutineContext().ensureActive()
                        result += withContext(NonCancellable) {
                            val single = attempt(
                                draft.canonicalId,
                                operation.action,
                            ) {
                                writer.writeUpserts(listOf(draft))
                            }
                            val written = single.value
                            if (written == null) {
                                ProjectionExecutionResult(
                                    failures = listOfNotNull(single.failure),
                                )
                            } else {
                                acceptUpserts(listOf(operation), written)
                            }
                        }
                        if (remainingSingletonAttempts == 0) {
                            return result.copy(retryCeilingReached = true)
                        }
                    }
                }
            }
        }
        return result
    }

    private suspend fun acceptDeletions(
        drafts: List<ProjectionDraft.Delete>,
        removed: List<HealthConnectProjection>,
    ): ProjectionExecutionResult {
        val expected = drafts.associate {
            it.canonicalId to it.targetRecord
        }
        if (
            removed.size != drafts.size ||
            removed.associate {
                it.canonicalId to it.targetRecord
            } != expected
        ) {
            throw HealthConnectProviderProtocolException(
                "Health Connect acknowledged different deletions.",
            )
        }
        completeDeletes(
            drafts.map {
                it.pending(HealthConnectPendingAction.DELETE)
            },
        )
        return ProjectionExecutionResult(deleted = removed.size)
    }

    private suspend fun acceptUpserts(
        operations: List<PlannedRecord>,
        written: HealthConnectWriteResult,
    ): ProjectionExecutionResult {
        val expectedIds = operations.map { it.source.canonicalId }.toSet()
        if (
            written.attempted != operations.size ||
            written.projections.size != operations.size ||
            written.projections.map {
                it.canonicalId
            }.toSet() != expectedIds
        ) {
            throw HealthConnectProviderProtocolException(
                "Health Connect acknowledged different upserts.",
            )
        }
        completeUpserts(written.projections)
        return ProjectionExecutionResult(
            inserted = operations.count { it.action == ProjectionAction.INSERT },
            updated = operations.count { it.action == ProjectionAction.UPDATE },
        )
    }

    private data class Attempt<T : Any>(
        val value: T? = null,
        val failure: ProjectionFailure? = null,
    )

    private suspend fun <T : Any> attempt(
        canonicalId: String,
        action: ProjectionAction,
        operation: suspend () -> T,
    ): Attempt<T> {
        return try {
            Attempt(value = operation())
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            when (failureScope(error)) {
                ProjectionFailureScope.RECORD ->
                    failure(canonicalId, action, error)
                ProjectionFailureScope.PROVIDER,
                null,
                -> throw error
            }
        }
    }

    private fun ProjectionDraft.pending(
        action: HealthConnectPendingAction,
    ): PendingHealthConnectOperation = PendingHealthConnectOperation(
        canonicalId = canonicalId,
        targetRecord = targetRecord(),
        canonicalVersion = recordVersion,
        action = action,
    )

    private fun <T : Any> failure(
        canonicalId: String,
        action: ProjectionAction,
        error: Throwable,
    ): Attempt<T> =
        Attempt(
            failure = ProjectionFailure(
                canonicalId = canonicalId,
                action = action,
                message = error.message ?: error::class.java.simpleName,
            ),
        )

    private fun failureScope(error: Exception): ProjectionFailureScope? =
        when (error) {
            is HealthConnectProviderProtocolException ->
                ProjectionFailureScope.PROVIDER
            is IllegalArgumentException -> ProjectionFailureScope.RECORD
            is RemoteException,
            is IOException,
            is IllegalStateException,
            is SecurityException,
            -> ProjectionFailureScope.PROVIDER
            else -> null
        }

    private companion object {
        val executionMutex = Mutex()
    }
}

private enum class ProjectionFailureScope {
    RECORD,
    PROVIDER,
}

internal const val MAX_RETAINED_PROJECTION_FAILURES = 100
internal const val MAX_RECORD_LOCAL_RETRIES_PER_RUN = 100
private const val MAX_PROJECTION_BATCH = 500
