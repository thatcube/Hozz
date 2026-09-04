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
    val timelineNextCursor: TimelineCursor? = null,
    val timelineLoading: Boolean = false,
    val projection: ProjectionSummary = ProjectionSummary(),
    val totalRecordCount: Int = 0,
    val lastImport: ArchiveImportResult? = null,
    val status: String? = null,
    val healthConnectStatus: Int = HealthConnectClient.SDK_UNAVAILABLE,
)

internal fun HozzUiState.appending(page: TimelineItemPage): HozzUiState {
    val existing = timeline.mapTo(hashSetOf()) { it.canonicalId }
    val additions = page.records.filter { existing.add(it.canonicalId) }
    return copy(
        timeline = timeline + additions,
        timelineNextCursor = page.nextCursor.takeIf {
            page.records.isNotEmpty()
        },
        timelineLoading = false,
    )
}

internal data class TimelineLoadRequest(
    val generation: Long,
    val cursor: TimelineCursor,
) {
    fun isCurrent(currentGeneration: Long, currentCursor: TimelineCursor?): Boolean =
        generation == currentGeneration && cursor == currentCursor
}

class HozzViewModel(application: Application) : AndroidViewModel(application) {
    private val core = HozzCoreService(application)
    private val healthConnect = HealthConnectWriter(application)
    private val mutableState = MutableStateFlow(
        HozzUiState(healthConnectStatus = healthConnect.availability),
    )
    private var timelineGeneration = 0L

    val state: StateFlow<HozzUiState> = mutableState.asStateFlow()

    init {
        viewModelScope.launch {
            refresh()
        }
    }

    fun importArchive(uri: Uri) {
        viewModelScope.launch {
            mutableState.value = mutableState.value.copy(
                busy = true,
                status = "Reading the selected Hozz archive…",
            )
            try {
                val result = withContext(Dispatchers.IO) {
                    core.import(
                        SafArchiveTransport(
                            getApplication<Application>().contentResolver,
                            uri,
                        ),
                    )
                }

                refresh(
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
        val request = TimelineLoadRequest(timelineGeneration, cursor)
        mutableState.value = mutableState.value.copy(timelineLoading = true)
        viewModelScope.launch {
            try {
                val page = withContext(Dispatchers.IO) {
                    core.timelinePage(cursor)
                }
                if (!request.isCurrent(
                        timelineGeneration,
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

    fun exportArchive(uri: Uri) {
        viewModelScope.launch {
            mutableState.value = mutableState.value.copy(
                busy = true,
                status = "Writing the canonical Hozz archive…",
            )
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
                mutableState.value = mutableState.value.copy(
                    busy = false,
                    status = "Saved ${result.recordCount} canonical records.",
                )
            } catch (error: ArchiveFormatException) {
                fail(error.message ?: "Android could not create the archive.")
            } catch (error: CancellationException) {
                throw error
            } catch (error: IOException) {
                fail(error.message ?: "Android could not write the archive.")
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
            mutableState.value = mutableState.value.copy(
                busy = true,
                status = "Checking Health Connect write access…",
            )
            try {
                val missing = healthConnect.missingPermissions(
                    projection.targetRecords,
                )
                if (missing.isEmpty()) {
                    writeToHealthConnect(
                        healthConnect.requiredPermissions(projection.targetRecords),
                    )
                } else {
                    mutableState.value = mutableState.value.copy(busy = false)
                    requestPermissions(missing)
                }
            } catch (error: IOException) {
                fail(error.message ?: "Health Connect could not check permissions.")
            } catch (error: CancellationException) {
                throw error
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
            mutableState.value = mutableState.value.copy(
                busy = true,
                status = "Confirming Health Connect write access…",
            )
            val missing = try {
                healthConnect.missingPermissions(projection.targetRecords)
            } catch (error: CancellationException) {
                throw error
            } catch (error: IOException) {
                fail(error.message ?: "Health Connect could not check permissions.")
                return@launch
            } catch (error: CancellationException) {
                throw error
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
                mutableState.value = mutableState.value.copy(
                    busy = false,
                    status = "No records were written because write access was not granted.",
                )
                return@launch
            }
            writeToHealthConnect(permitted)
        }
    }

    private suspend fun writeToHealthConnect(
        permitted: Set<String>,
    ) {
        mutableState.value = mutableState.value.copy(
            busy = true,
            status = "Writing mapped records to Health Connect…",
        )
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
                result += withContext(Dispatchers.IO) {
                    executor.apply(permittedOperations)
                }
                after = page.nextCanonicalId
            } while (after != null)
            refresh(
                status = buildString {
                    append("Health Connect applied ")
                    append(result.inserted)
                    append(" inserts, ")
                    append(result.updated)
                    append(" updates, and ")
                    append(result.deleted)
                    append(" deletions.")
                    if (result.failures.isNotEmpty()) {
                        append(" ")
                        append(result.failures.size)
                        append(" records failed and remain pending.")
                    }
                    if (permissionDeferred > 0) {
                        append(" ")
                        append(permissionDeferred)
                        append(" records remain pending because write access was not granted.")
                    }
                },
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
    ) {
        timelineGeneration += 1
        val generation = timelineGeneration
        val snapshot = withContext(Dispatchers.IO) { core.snapshot() }
        if (generation != timelineGeneration) return
        mutableState.value = HozzUiState(
            busy = false,
            timeline = snapshot.timeline,
            timelineNextCursor = snapshot.timelineNextCursor,
            timelineLoading = false,
            projection = snapshot.projection,
            totalRecordCount = snapshot.totalRecordCount,
            lastImport = lastImport,
            status = status,
            healthConnectStatus = healthConnect.availability,
        )
    }

    private fun fail(message: String) {
        mutableState.value = mutableState.value.copy(
            busy = false,
            status = message,
        )
    }

    override fun onCleared() {
        core.close()
        super.onCleared()
    }
}
