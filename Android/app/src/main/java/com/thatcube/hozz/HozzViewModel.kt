package com.thatcube.hozz

import android.app.Application
import android.database.sqlite.SQLiteException
import android.net.Uri
import androidx.health.connect.client.HealthConnectClient
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.thatcube.hozz.core.ArchiveFormatException
import com.thatcube.hozz.core.ArchiveImportResult
import com.thatcube.hozz.core.CanonicalRecord
import com.thatcube.hozz.core.HozzCoreService
import com.thatcube.hozz.core.SafArchiveTransport
import com.thatcube.hozz.core.SafArchiveSink
import com.thatcube.hozz.projection.HealthConnectWriteResult
import com.thatcube.hozz.projection.HealthConnectWriter
import com.thatcube.hozz.projection.ProjectionSummary
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class HozzUiState(
    val busy: Boolean = false,
    val timeline: List<CanonicalRecord> = emptyList(),
    val projection: ProjectionSummary = ProjectionSummary(),
    val totalRecordCount: Int = 0,
    val lastImport: ArchiveImportResult? = null,
    val status: String? = null,
    val healthConnectStatus: Int = HealthConnectClient.SDK_UNAVAILABLE,
)

class HozzViewModel(application: Application) : AndroidViewModel(application) {
    private val core = HozzCoreService(application)
    private val healthConnect = HealthConnectWriter(application)
    private val mutableState = MutableStateFlow(
        HozzUiState(healthConnectStatus = healthConnect.availability),
    )

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
                    },
                )
            } catch (error: ArchiveFormatException) {
                fail(error.message ?: "The selected file is not a Hozz archive.")
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
                        ),
                    )
                }
                mutableState.value = mutableState.value.copy(
                    busy = false,
                    status = "Saved ${result.recordCount} canonical records.",
                )
            } catch (error: ArchiveFormatException) {
                fail(error.message ?: "Android could not create the archive.")
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
            if (projection.mappedCount == 0) {
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
                    writeToHealthConnect()
                } else {
                    mutableState.value = mutableState.value.copy(busy = false)
                    requestPermissions(missing)
                }
            } catch (error: IOException) {
                fail(error.message ?: "Health Connect could not check permissions.")
            } catch (error: IllegalStateException) {
                fail(error.message ?: "Health Connect is not available.")
            } catch (error: SecurityException) {
                fail("Health Connect refused the permission check.")
            }
        }
    }

    fun finishHealthConnectPermission(granted: Set<String>) {
        viewModelScope.launch {
            val projection = mutableState.value.projection
            if (granted.isEmpty()) {
                mutableState.value = mutableState.value.copy(
                    busy = false,
                    status = "No records were written because write access was not granted.",
                )
                return@launch
            }
            mutableState.value = mutableState.value.copy(
                busy = true,
                status = "Confirming Health Connect write access…",
            )
            val missing = try {
                healthConnect.missingPermissions(projection.targetRecords)
            } catch (error: IOException) {
                fail(error.message ?: "Health Connect could not check permissions.")
                return@launch
            } catch (error: IllegalStateException) {
                fail(error.message ?: "Health Connect is not available.")
                return@launch
            } catch (error: SecurityException) {
                fail("Health Connect refused the permission check.")
                return@launch
            }
            if (missing.isNotEmpty()) {
                mutableState.value = mutableState.value.copy(
                    busy = false,
                    status = "No records were written because write access was not granted.",
                )
                return@launch
            }
            writeToHealthConnect()
        }
    }

    private suspend fun writeToHealthConnect() {
        mutableState.value = mutableState.value.copy(
            busy = true,
            status = "Writing mapped records to Health Connect…",
        )
        try {
            var after: String? = null
            var attempted = 0
            do {
                val page = withContext(Dispatchers.IO) {
                    core.projectionDraftPage(after)
                }
                if (page.drafts.isNotEmpty()) {
                    val result: HealthConnectWriteResult =
                        withContext(Dispatchers.IO) {
                            healthConnect.write(page.drafts)
                        }
                    attempted += result.attempted
                }
                after = page.nextCanonicalId
            } while (after != null)
            mutableState.value = mutableState.value.copy(
                busy = false,
                status = "Health Connect accepted $attempted mapped records.",
            )
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
        val snapshot = withContext(Dispatchers.IO) { core.snapshot() }
        mutableState.value = HozzUiState(
            busy = false,
            timeline = snapshot.timeline,
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
