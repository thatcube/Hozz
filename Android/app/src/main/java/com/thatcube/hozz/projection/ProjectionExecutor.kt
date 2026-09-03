package com.thatcube.hozz.projection

import android.os.RemoteException
import com.thatcube.hozz.core.HealthConnectProjection
import java.io.IOException
import kotlinx.coroutines.CancellationException

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
) {
    operator fun plus(other: ProjectionExecutionResult) =
        ProjectionExecutionResult(
            inserted = inserted + other.inserted,
            updated = updated + other.updated,
            deleted = deleted + other.deleted,
            failures = failures + other.failures,
        )
}

class ProjectionExecutor(
    private val writer: HealthConnectProjectionWriter,
    private val saveProjections:
        suspend (List<HealthConnectProjection>) -> Unit,
    private val removeProjections:
        suspend (List<HealthConnectProjection>) -> Unit,
) {
    suspend fun apply(
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
            val batch = attempt(
                chunk.first().canonicalId,
                ProjectionAction.DELETE,
            ) {
                writer.delete(chunk)
            }
            if (batch.value != null) {
                result += acceptDeletions(chunk, batch.value)
            } else if (chunk.size == 1) {
                result += ProjectionExecutionResult(
                    failures = listOfNotNull(batch.failure),
                )
            } else {
                for (draft in chunk) {
                    val single = attempt(
                        draft.canonicalId,
                        ProjectionAction.DELETE,
                    ) {
                        writer.delete(listOf(draft))
                    }
                    val removed = single.value
                    result += if (removed == null) {
                        ProjectionExecutionResult(
                            failures = listOfNotNull(single.failure),
                        )
                    } else {
                        acceptDeletions(listOf(draft), removed)
                    }
                }
            }
        }

        val upserts = operations.filter {
            it.action == ProjectionAction.INSERT ||
                it.action == ProjectionAction.UPDATE
        }
        for (chunk in upserts.chunked(MAX_PROJECTION_BATCH)) {
            val drafts = chunk.map { requireNotNull(it.draft) }
            val batch = attempt(drafts.first().canonicalId, chunk.first().action) {
                writer.writeUpserts(drafts)
            }
            if (batch.value != null) {
                result += acceptUpserts(chunk, batch.value)
            } else if (chunk.size == 1) {
                result += ProjectionExecutionResult(
                    failures = listOfNotNull(batch.failure),
                )
            } else {
                for (operation in chunk) {
                    val draft = operation.draft ?: continue
                    val single = attempt(draft.canonicalId, operation.action) {
                        writer.writeUpserts(listOf(draft))
                    }
                    val written = single.value
                    result += if (written == null) {
                        ProjectionExecutionResult(
                            failures = listOfNotNull(single.failure),
                        )
                    } else {
                        acceptUpserts(listOf(operation), written)
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
            it.canonicalId to it.healthConnectRecordId
        }
        check(
            removed.size == drafts.size &&
                removed.associate {
                    it.canonicalId to it.healthConnectRecordId
                } == expected,
        ) {
            "Health Connect acknowledged different deletions."
        }
        removeProjections(removed)
        return ProjectionExecutionResult(deleted = removed.size)
    }

    private suspend fun acceptUpserts(
        operations: List<PlannedRecord>,
        written: HealthConnectWriteResult,
    ): ProjectionExecutionResult {
        val expectedIds = operations.map { it.source.canonicalId }.toSet()
        check(
            written.attempted == operations.size &&
                written.projections.size == operations.size &&
                written.projections.map {
                    it.canonicalId
                }.toSet() == expectedIds,
        ) {
            "Health Connect acknowledged different upserts."
        }
        saveProjections(written.projections)
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
        } catch (error: RemoteException) {
            failure(canonicalId, action, error)
        } catch (error: IOException) {
            failure(canonicalId, action, error)
        } catch (error: IllegalArgumentException) {
            failure(canonicalId, action, error)
        } catch (error: IllegalStateException) {
            failure(canonicalId, action, error)
        } catch (error: SecurityException) {
            failure(canonicalId, action, error)
        }

    }

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
}

private const val MAX_PROJECTION_BATCH = 500
