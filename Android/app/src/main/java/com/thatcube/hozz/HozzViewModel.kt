package com.thatcube.hozz

import android.app.Application
import android.database.sqlite.SQLiteException
import android.net.Uri
import android.os.RemoteException
import androidx.health.connect.client.HealthConnectClient
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.thatcube.hozz.core.ArchiveFormatException
import com.thatcube.hozz.core.ArchiveImportResult
import com.thatcube.hozz.core.HozzCoreSnapshot
import com.thatcube.hozz.core.HozzCoreService
import com.thatcube.hozz.core.SafArchiveTransport
import com.thatcube.hozz.core.SafArchiveSink
import com.thatcube.hozz.core.TimelineCursor
import com.thatcube.hozz.core.TimelineItem
import com.thatcube.hozz.core.TimelineItemPage
import com.thatcube.hozz.projection.HealthConnectWriter
import com.thatcube.hozz.projection.ProjectionExecutionResult
import com.thatcube.hozz.projection.ProjectionExecutor
import com.thatcube.hozz.projection.ProjectionSummary
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class HozzUiState(
    val busy: Boolean = false,
    val timeline: List<TimelineItem> = emptyList(),
    val timelinePreviousCursor: TimelineCursor? = null,
    val timelineNextCursor: TimelineCursor? = null,
    val timelineLoading: Boolean = false,
    val projection: ProjectionSummary = ProjectionSummary(),
    val totalRecordCount: Int = 0,
    val runRecordCount: Int = 0,
    val lastImport: ArchiveImportResult? = null,
    val status: String? = null,
    val healthConnectStatus: Int = HealthConnectClient.SDK_UNAVAILABLE,
) {
    val hasArchive: Boolean
        get() = totalRecordCount > 0 || runRecordCount > 0
}

internal fun HozzUiState.beginningOperation(status: String): HozzUiState = copy(
    busy = true,
    timelineLoading = false,
    status = status,
)

internal fun HozzUiState.appending(page: TimelineItemPage): HozzUiState {
    val existing = timeline.mapTo(hashSetOf()) { it.canonicalId }
    val additions = page.records.filter { existing.add(it.canonicalId) }
    val combined = timeline + additions
    val dropped = (combined.size - MAX_RETAINED_TIMELINE_ITEMS).coerceAtLeast(0)
    val retained = combined.drop(dropped)
    return copy(
        timeline = retained,
        timelinePreviousCursor = if (dropped > 0) {
            retained.firstOrNull()?.cursor()
        } else {
            timelinePreviousCursor
        },
        timelineNextCursor = page.nextCursor.takeIf {
            page.records.isNotEmpty()
        },
        timelineLoading = false,
    )
}

internal fun HozzUiState.prepending(page: TimelineItemPage): HozzUiState {
    val existing = timeline.mapTo(hashSetOf()) { it.canonicalId }
    val additions = page.records.filter { existing.add(it.canonicalId) }
    val combined = additions + timeline
    val dropped = (combined.size - MAX_RETAINED_TIMELINE_ITEMS).coerceAtLeast(0)
    val retained = combined.take(MAX_RETAINED_TIMELINE_ITEMS)
    return copy(
        timeline = retained,
        timelinePreviousCursor = page.previousCursor.takeIf {
            page.records.isNotEmpty()
        },
        timelineNextCursor = if (dropped > 0) {
            retained.lastOrNull()?.cursor()
        } else {
            timelineNextCursor
        },
        timelineLoading = false,
    )
}

private fun TimelineItem.cursor(): TimelineCursor =
    TimelineCursor(endTime, canonicalId)

internal const val MAX_RETAINED_TIMELINE_ITEMS = 400

internal data class TimelineLoadRequest(
    val generation: Long,
    val cursor: TimelineCursor,
) {
    fun isCurrent(currentGeneration: Long, currentCursor: TimelineCursor?): Boolean =
        generation == currentGeneration && cursor == currentCursor
}

internal class HozzRefreshGeneration {
    var current: Long = 0
        private set

    fun beginRefresh(): Long {
        current += 1
        return current
    }

    fun beginOperation() {
        current += 1
    }

    fun isCurrent(generation: Long): Boolean = generation == current
}

internal class HozzStateRefresher(
    private val state: MutableStateFlow<HozzUiState>,
    private val loadSnapshot: suspend () -> HozzCoreSnapshot,
    private val healthConnectStatus: () -> Int,
) {
    private val generation = HozzRefreshGeneration()

    val currentGeneration: Long
        get() = generation.current

    fun beginOperation(status: String) {
        generation.beginOperation()
        state.value = state.value.beginningOperation(status)
    }

    suspend fun refresh(
        lastImport: ArchiveImportResult? = state.value.lastImport,
        status: String? = state.value.status,
    ) = loadAndApply(
        lastImport = lastImport,
        status = status,
    )

    suspend fun finishOperation(
        status: String,
        lastImport: ArchiveImportResult? = state.value.lastImport,
    ) = loadAndApply(
        lastImport = lastImport,
        status = status,
    )

    private suspend fun loadAndApply(
        lastImport: ArchiveImportResult?,
        status: String?,
    ) {
        val refresh = generation.beginRefresh()
        val snapshot = try {
            loadSnapshot()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (generation.isCurrent(refresh)) {
                val refreshFailure = error.message?.let {
                    "The local archive view could not be refreshed: $it"
                } ?: "The local archive view could not be refreshed."
                state.value = state.value.copy(
                    busy = false,
                    timelineLoading = false,
                    lastImport = lastImport,
                    status = listOfNotNull(status, refreshFailure)
                        .joinToString(" "),
                    healthConnectStatus = healthConnectStatus(),
                )
            }
            return
        }
        if (!generation.isCurrent(refresh)) return
        state.value = HozzUiState(
            busy = false,
            timeline = snapshot.timeline,
            timelinePreviousCursor = snapshot.timelinePreviousCursor,
            timelineNextCursor = snapshot.timelineNextCursor,
            timelineLoading = false,
            projection = snapshot.projection,
            totalRecordCount = snapshot.totalRecordCount,
            runRecordCount = snapshot.runRecordCount,
            lastImport = lastImport,
            status = status,
            healthConnectStatus = healthConnectStatus(),
        )
    }
}

internal fun healthConnectCompletionStatus(
    result: ProjectionExecutionResult,
    permissionDeferred: Int,
): String = buildString {
    append("Health Connect applied ")
    append(result.inserted)
    append(" inserts, ")
    append(result.updated)
    append(" updates, and ")
    append(result.deleted)
    append(" deletions.")
    if (result.failureCount > 0) {
        append(" ")
        append(result.failureCount)
        append(" records failed and remain pending.")
    }
    if (result.retryCeilingReached) {
        append(" The per-run retry limit was reached; remaining records stay pending.")
    }
    if (permissionDeferred > 0) {
        append(" ")
        append(permissionDeferred)
        append(" records remain pending because write access was not granted.")
    }
}

class HozzViewModel(application: Application) : AndroidViewModel(application) {
    private val core = HozzCoreService(application)
    private val healthConnect = HealthConnectWriter(application)
    private val mutableState = MutableStateFlow(
        HozzUiState(healthConnectStatus = healthConnect.availability),
    )
    private val stateRefresher = HozzStateRefresher(
        state = mutableState,
        loadSnapshot = {
            withContext(Dispatchers.IO) { core.snapshot() }
        },
        healthConnectStatus = { healthConnect.availability },
    )

    val state: StateFlow<HozzUiState> = mutableState.asStateFlow()

    init {
        viewModelScope.launch {
            refresh()
        }
    }

    fun importArchive(uri: Uri) {
        viewModelScope.launch {
            beginOperation("Reading the selected Hozz archive…")
            try {
                val result = withContext(Dispatchers.IO) {
                    core.import(
                        SafArchiveTransport(
                            getApplication<Application>().contentResolver,
                            uri,
                        ),
                    )
                }

                stateRefresher.finishOperation(
                    lastImport = result,
                    status = buildString {
                        append("Archive imported: ")
                        append(result.merge.inserted)
                        append(" new, ")
                        append(result.merge.updated)
                        append(" updated, ")
                        append(result.merge.ignored)
                        append(" already current.")
                        if (result.runRecordsPreserved > 0) {
                            append(" Preserved ")
                            append(result.runRecordsPreserved)
                            append(" run and coverage records.")
                        }
                    },
                )
            } catch (error: ArchiveFormatException) {
                fail(error.message ?: "The selected file is not a Hozz archive.")
            } catch (error: CancellationException) {
                throw error
            } catch (error: IOException) {
                fail(error.message ?: "Android could not read the selected archive.")
            } catch (error: SQLiteException) {
                fail(error.message ?: "The local Hozz archive could not be updated.")
            } catch (error: SecurityException) {
                fail("Android did not grant access to the selected archive.")
            }
        }
    }

    fun refreshHealthConnectAvailability() {
        mutableState.value = mutableState.value.copy(
            healthConnectStatus = healthConnect.availability,
        )
    }

    fun loadMoreTimeline() {
        val cursor = mutableState.value.timelineNextCursor ?: return
        if (mutableState.value.timelineLoading) return
        val request = TimelineLoadRequest(stateRefresher.currentGeneration, cursor)
        mutableState.value = mutableState.value.copy(timelineLoading = true)
        viewModelScope.launch {
            try {
                val page = withContext(Dispatchers.IO) {
                    core.timelinePage(cursor)
                }
                if (!request.isCurrent(
                        stateRefresher.currentGeneration,
                        mutableState.value.timelineNextCursor,
                    )
                ) {
                    return@launch
                }
                mutableState.value = mutableState.value.appending(page)
            } catch (error: CancellationException) {
                throw error
            } catch (error: SQLiteException) {
                mutableState.value = mutableState.value.copy(
                    timelineLoading = false,
                    status = error.message
                        ?: "The next archive records could not be loaded.",
                )
            }
        }
    }

    fun loadPreviousTimeline() {
        val cursor = mutableState.value.timelinePreviousCursor ?: return
        if (mutableState.value.timelineLoading) return
        val request = TimelineLoadRequest(stateRefresher.currentGeneration, cursor)
        mutableState.value = mutableState.value.copy(timelineLoading = true)
        viewModelScope.launch {
            try {
                val page = withContext(Dispatchers.IO) {
                    core.timelinePageBefore(cursor)
                }
                if (!request.isCurrent(
                        stateRefresher.currentGeneration,
                        mutableState.value.timelinePreviousCursor,
                    )
                ) {
                    return@launch
                }
                mutableState.value = mutableState.value.prepending(page)
            } catch (error: CancellationException) {
                throw error
            } catch (error: SQLiteException) {
                mutableState.value = mutableState.value.copy(
                    timelineLoading = false,
                    status = error.message
                        ?: "The previous archive records could not be loaded.",
                )
            }
        }
    }

    fun exportArchive(uri: Uri) {
        viewModelScope.launch {
            beginOperation("Writing the canonical Hozz archive…")
            try {
                val result = withContext(Dispatchers.IO) {
                    core.export(
                        SafArchiveSink(
                            getApplication<Application>().contentResolver,
                            uri,
                            getApplication<Application>().cacheDir,
                        ),
                    )
                }
                stateRefresher.finishOperation(
                    "Saved ${result.recordCount} canonical records.",
                )
            } catch (error: ArchiveFormatException) {
                fail(error.message ?: "Android could not create the archive.")
            } catch (error: CancellationException) {
                throw error
            } catch (error: IOException) {
                fail(error.message ?: "Android could not write the archive.")
            } catch (error: SQLiteException) {
                fail(error.message ?: "The local Hozz archive could not be read.")
            } catch (error: SecurityException) {
                fail("Android did not grant access to the selected location.")
            }
        }
    }

    fun prepareHealthConnectWrite(
        requestPermissions: (Set<String>) -> Unit,
    ) {
        viewModelScope.launch {
            val projection = mutableState.value.projection
            if (projection.pendingCount == 0) {
                mutableState.value = mutableState.value.copy(
                    status = "There are no mapped records to write.",
                )
                return@launch
            }
            beginOperation("Checking Health Connect write access…")
            try {
                val missing = healthConnect.missingPermissions(
                    projection.targetRecords,
                )
                if (missing.isEmpty()) {
                    writeToHealthConnect(
                        healthConnect.requiredPermissions(projection.targetRecords),
                    )
                } else {
                    stateRefresher.finishOperation(
                        mutableState.value.status
                            ?: "Health Connect write access is required.",
                    )
                    requestPermissions(missing)
                }
            } catch (error: IOException) {
                fail(error.message ?: "Health Connect could not check permissions.")
            } catch (error: CancellationException) {
                throw error
            } catch (error: RemoteException) {
                fail(error.message ?: "Health Connect could not check permissions.")
            } catch (error: IllegalStateException) {
                fail(error.message ?: "Health Connect is not available.")
            } catch (error: SecurityException) {
                fail("Health Connect refused the permission check.")
            }
        }
    }

    fun finishHealthConnectPermission(@Suppress("UNUSED_PARAMETER") granted: Set<String>) {
        viewModelScope.launch {
            val projection = mutableState.value.projection
            beginOperation("Confirming Health Connect write access…")
            val missing = try {
                healthConnect.missingPermissions(projection.targetRecords)
            } catch (error: CancellationException) {
                throw error
            } catch (error: IOException) {
                fail(error.message ?: "Health Connect could not check permissions.")
                return@launch
            } catch (error: RemoteException) {
                fail(error.message ?: "Health Connect could not check permissions.")
                return@launch
            } catch (error: IllegalStateException) {
                fail(error.message ?: "Health Connect is not available.")
                return@launch
            } catch (error: SecurityException) {
                fail("Health Connect refused the permission check.")
                return@launch
            }
            val permitted =
                healthConnect.requiredPermissions(projection.targetRecords) - missing
            if (permitted.isEmpty()) {
                stateRefresher.finishOperation(
                    "No records were written because write access was not granted.",
                )
                return@launch
            }
            writeToHealthConnect(permitted)
        }
    }

    private suspend fun writeToHealthConnect(
        permitted: Set<String>,
    ) {
        beginOperation("Writing mapped records to Health Connect…")
        try {
            var after: String? = null
            var result = ProjectionExecutionResult()
            var permissionDeferred = 0
            val executor = ProjectionExecutor(
                writer = healthConnect,
                stageOperations = core::stageHealthConnectOperations,
                completeUpserts = core::completeHealthConnectUpserts,
                completeDeletes = core::completeHealthConnectDeletes,
            )
            do {
                val page = withContext(Dispatchers.IO) {
                    core.projectionDraftPage(after)
                }
                val permittedOperations = page.operations.filter { operation ->
                    val draft = operation.draft ?: return@filter false
                    val allowed =
                        healthConnect.requiredPermission(draft) in permitted
                    if (!allowed) {
                        permissionDeferred += 1
                    }
                    allowed
                }
                val pageResult = withContext(Dispatchers.IO) {
                    executor.apply(permittedOperations)
                }
                result += pageResult
                if (pageResult.retryCeilingReached) {
                    break
                }
                after = page.nextCanonicalId
            } while (after != null)
            stateRefresher.finishOperation(
                status = healthConnectCompletionStatus(
                    result,
                    permissionDeferred,
                ),
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: RemoteException) {
            fail(error.message ?: "Health Connect could not complete the operation.")
        } catch (error: SQLiteException) {
            fail(error.message ?: "The Health Connect projection ledger could not be updated.")
        } catch (error: IOException) {
            fail(error.message ?: "Health Connect did not accept the records.")
        } catch (error: IllegalArgumentException) {
            fail(error.message ?: "A mapped record was outside Health Connect's limits.")
        } catch (error: IllegalStateException) {
            fail(error.message ?: "Health Connect is not available.")
        } catch (error: SecurityException) {
            fail("Health Connect write access was not granted.")
        }
    }

    private suspend fun refresh(
        lastImport: ArchiveImportResult? = mutableState.value.lastImport,
        status: String? = mutableState.value.status,
    ) = stateRefresher.refresh(lastImport, status)

    private fun beginOperation(status: String) {
        stateRefresher.beginOperation(status)
    }

    private suspend fun fail(message: String) {
        stateRefresher.finishOperation(message)
    }

    override fun onCleared() {
        core.close()
        super.onCleared()
    }
}
