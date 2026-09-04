package com.thatcube.hozz.projection

import android.content.pm.PackageManager
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeightRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.records.metadata.DataOrigin
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.thatcube.hozz.core.InMemoryCanonicalRecordStore
import com.thatcube.hozz.core.HealthConnectPendingAction
import com.thatcube.hozz.core.PendingHealthConnectOperation
import com.thatcube.hozz.core.SqliteCanonicalRecordStore
import java.io.FileInputStream
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HealthConnectWriterIntegrationTest {
    @Test
    @Suppress("DEPRECATION")
    fun declaresWriteOnlyPermissionsIncludingLegacyCleanup() {
        val context = context()
        val requested = context.packageManager.getPackageInfo(
            context.packageName,
            PackageManager.GET_PERMISSIONS,
        ).requestedPermissions.orEmpty().filter {
            it.startsWith("android.permission.health.")
        }.toSet()
        val expected = setOf(
            HealthPermission.getWritePermission(HeartRateRecord::class),
            HealthPermission.getWritePermission(WeightRecord::class),
            HealthPermission.getWritePermission(HeightRecord::class),
            HealthPermission.getWritePermission(ExerciseSessionRecord::class),
            HealthPermission.getWritePermission(StepsRecord::class),
            HealthPermission.getWritePermission(DistanceRecord::class),
            HealthPermission.getWritePermission(
                ActiveCaloriesBurnedRecord::class,
            ),
            HealthPermission.getWritePermission(SleepSessionRecord::class),
        )

        assertEquals(expected, requested)
        assertTrue(requested.none { ".READ_" in it })
    }

    @Test
    fun provisionsWriteOnlyPermissionAndReadsBackOneVersionTwoHozzRecord() =
        runBlocking {
        val context = context()
        provisionWrite(context, WeightRecord::class.java.simpleName)
        val client = HealthConnectClient.getOrCreate(context)
        val canonicalId = "apple.healthkit:hozz-integration-upsert"
        val start = Instant.now().minusSeconds(120)
        val end = start.plusSeconds(60)
        val versionOne = ProjectionDraft.Weight(
            canonicalId = canonicalId,
            recordVersion = 1,
            time = start,
            kilograms = 1.0,
        )
        val versionTwo = versionOne.copy(recordVersion = 2, kilograms = 2.0)
        val writer = HealthConnectWriter(context)

        try {
            val first = writer.writeUpserts(listOf(versionOne))
            val retry = writer.writeUpserts(listOf(versionOne))
            val updated = writer.writeUpserts(listOf(versionTwo))
            assertEquals(1, first.attempted)
            assertEquals(1, retry.attempted)
            assertEquals(1, updated.attempted)
            assertEquals(
                first.projections.map { it.healthConnectRecordId },
                retry.projections.map { it.healthConnectRecordId },
            )
            assertEquals(
                first.projections.map { it.healthConnectRecordId },
                updated.projections.map { it.healthConnectRecordId },
            )
            val matches = client.readRecords(
                ReadRecordsRequest(
                    recordType = WeightRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(
                        start.minusSeconds(1),
                        end.plusSeconds(1),
                    ),
                    dataOriginFilter = setOf(DataOrigin(context.packageName)),
                ),
            ).records.filter {
                it.metadata.clientRecordId == canonicalId
            }
            assertEquals(1, matches.size)
            assertEquals(2, matches.single().metadata.clientRecordVersion)
        } finally {
            client.deleteRecords(
                recordType = WeightRecord::class,
                recordIdsList = weightRecordIds(
                    client,
                    context.packageName,
                    canonicalId,
                    start,
                    end,
                ),
                clientRecordIdsList = emptyList(),
            )
        }
    }

    @Test
    fun pointHeartRateWritesWithoutBroadReadPermission() = runBlocking {
        val context = context()
        provisionWrite(context, HeartRateRecord::class.java.simpleName)
        val client = HealthConnectClient.getOrCreate(context)
        val instant = Instant.now().minusSeconds(60)
        val canonicalId = "apple.healthkit:hozz-point-heart-rate"
        val draft = ProjectionDraft.HeartRate(
            canonicalId = canonicalId,
            recordVersion = 1,
            start = instant,
            end = instant,
            beatsPerMinute = 60,
        )
        val writer = HealthConnectWriter(context)
        var recordId: String? = null

        try {
            recordId = writer.writeUpserts(listOf(draft))
                .projections
                .single()
                .healthConnectRecordId
            val matches = client.readRecords(
                ReadRecordsRequest(
                    recordType = HeartRateRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(
                        instant.minusSeconds(1),
                        instant.plusSeconds(1),
                    ),
                    dataOriginFilter = setOf(DataOrigin(context.packageName)),
                ),
            ).records.filter {
                it.metadata.clientRecordId == canonicalId
            }
            assertEquals(1, matches.size)
            assertEquals(60, matches.single().samples.single().beatsPerMinute)
        } finally {
            recordId?.let {
                client.deleteRecords(
                    recordType = HeartRateRecord::class,
                    recordIdsList = listOf(it),
                    clientRecordIdsList = emptyList(),
                )
            }
        }
    }

    @Test
    fun ledgerBackedDeletionUsesReturnedRecordIdOnlyOnce() = runBlocking {
        val context = context()
        provisionWrite(context, WeightRecord::class.java.simpleName)
        val client = HealthConnectClient.getOrCreate(context)
        val writer = HealthConnectWriter(context)
        val canonicalId = "apple.healthkit:hozz-ledger-delete"
        val instant = Instant.now().minusSeconds(30)
        val draft = ProjectionDraft.Weight(
            canonicalId = canonicalId,
            recordVersion = 1,
            time = instant,
            kilograms = 1.0,
        )
        val receipt = writer.writeUpserts(listOf(draft)).projections.single()
        val ledger = InMemoryCanonicalRecordStore()
        ledger.saveHealthConnectProjections(listOf(receipt))
        val deletion = ProjectionDraft.Delete(
            canonicalId = canonicalId,
            recordVersion = 2,
            targetRecord = "WeightRecord",
            healthConnectRecordId = receipt.healthConnectRecordId,
        )

        val removed = writer.delete(listOf(deletion))
        ledger.removeHealthConnectProjections(removed)

        assertTrue(ledger.healthConnectProjections(setOf(canonicalId)).isEmpty())
        val matches = client.readRecords(
            ReadRecordsRequest(
                recordType = WeightRecord::class,
                timeRangeFilter = TimeRangeFilter.between(
                    instant.minusSeconds(1),
                    instant.plusSeconds(1),
                ),
                dataOriginFilter = setOf(DataOrigin(context.packageName)),
            ),
        ).records.filter {
            it.metadata.clientRecordId == canonicalId
        }
        assertTrue(matches.isEmpty())
    }

    @Test
    fun pendingWriteCrashWindowDeletesByClientRecordIdAfterRestart() = runBlocking {
            val context = context()
            provisionWrite(context, WeightRecord::class.java.simpleName)
            val client = HealthConnectClient.getOrCreate(context)
            val writer = HealthConnectWriter(context)
            val canonicalId = "apple.healthkit:pending-crash-delete"
            val instant = Instant.now().minusSeconds(30)
            val databaseName = "pending-${UUID.randomUUID()}.sqlite"
            var store = SqliteCanonicalRecordStore(context, databaseName)
            try {
                val pendingUpsert = PendingHealthConnectOperation(
                    canonicalId = canonicalId,
                    targetRecord = "WeightRecord",
                    canonicalVersion = 1,
                    action = HealthConnectPendingAction.UPSERT,
                )
                store.stageHealthConnectOperations(listOf(pendingUpsert))
                writer.writeUpserts(
                    listOf(
                        ProjectionDraft.Weight(
                            canonicalId = canonicalId,
                            recordVersion = 1,
                            time = instant,
                            kilograms = 1.0,
                        )
                    )
                )
                store.close()
                store = SqliteCanonicalRecordStore(context, databaseName)
                assertEquals(
                    pendingUpsert,
                    store.pendingHealthConnectOperations(setOf(canonicalId))
                        .getValue(canonicalId),
                )

                val pendingDelete = pendingUpsert.copy(
                    canonicalVersion = 2,
                    action = HealthConnectPendingAction.DELETE,
                )
                store.stageHealthConnectOperations(listOf(pendingDelete))
                val removed = writer.delete(
                    listOf(
                        ProjectionDraft.Delete(
                            canonicalId = canonicalId,
                            recordVersion = 2,
                            targetRecord = "WeightRecord",
                            healthConnectRecordId = null,
                        )
                    )
                )
                assertEquals(1, removed.size)
                store.completeHealthConnectDeletes(listOf(pendingDelete))

                assertTrue(
                    store.pendingHealthConnectOperations(setOf(canonicalId)).isEmpty(),
                )
                val matches = client.readRecords(
                    ReadRecordsRequest(
                        recordType = WeightRecord::class,
                        timeRangeFilter = TimeRangeFilter.between(
                            instant.minusSeconds(60),
                            instant.plusSeconds(60),
                        ),
                        dataOriginFilter = setOf(DataOrigin(context.packageName)),
                    )
                ).records.filter {
                    it.metadata.clientRecordId == canonicalId
                }

                assertTrue(matches.isEmpty())
            } finally {
                val ids = weightRecordIds(
                    client,
                    context.packageName,
                    canonicalId,
                    instant.minusSeconds(60),
                    instant.plusSeconds(60),
                )
                if (ids.isNotEmpty()) {
                    client.deleteRecords(WeightRecord::class, ids, emptyList())
                }
                store.close()
                context.deleteDatabase(databaseName)
            }
    }

    @Test
    fun clientRecordIdDeletionIsSafeWhenAbsentOrRepeated() = runBlocking {
        val context = context()
        provisionWrite(context, WeightRecord::class.java.simpleName)
        val writer = HealthConnectWriter(context)
        val draft = ProjectionDraft.Delete(
            canonicalId = "apple.healthkit:absent-client-record",
            recordVersion = 2,
            targetRecord = "WeightRecord",
            healthConnectRecordId = null,
        )

        assertEquals(1, writer.delete(listOf(draft)).size)
        assertEquals(1, writer.delete(listOf(draft)).size)
    }

    private suspend fun weightRecordIds(
        client: HealthConnectClient,
        packageName: String,
        canonicalId: String,
        start: Instant,
        end: Instant,
    ): List<String> = client.readRecords(
        ReadRecordsRequest(
            recordType = WeightRecord::class,
            timeRangeFilter = TimeRangeFilter.between(
                start.minusSeconds(1),
                end.plusSeconds(1),
            ),
            dataOriginFilter = setOf(DataOrigin(packageName)),
        ),
    ).records.filter {
        it.metadata.clientRecordId == canonicalId
    }.map { it.metadata.id }

    private suspend fun provisionWrite(
        context: android.content.Context,
        recordName: String,
    ) {
        assertEquals(
            HealthConnectClient.SDK_AVAILABLE,
            HealthConnectClient.getSdkStatus(context),
        )
        val permission = when (recordName) {
            HeartRateRecord::class.java.simpleName ->
                HealthPermission.getWritePermission(HeartRateRecord::class)
            WeightRecord::class.java.simpleName ->
                HealthPermission.getWritePermission(WeightRecord::class)
            else -> error("Unknown integration record $recordName")
        }
        grant(context.packageName, permission)
        val granted = HealthConnectClient.getOrCreate(context)
            .permissionController
            .getGrantedPermissions()
        assertTrue(granted.contains(permission))
        val readPermission = when (recordName) {
            HeartRateRecord::class.java.simpleName ->
                HealthPermission.getReadPermission(HeartRateRecord::class)
            WeightRecord::class.java.simpleName ->
                HealthPermission.getReadPermission(WeightRecord::class)
            else -> error("Unknown integration record $recordName")
        }
        assertFalse(granted.contains(readPermission))
    }

    private fun context(): android.content.Context =
        ApplicationProvider.getApplicationContext()

    private fun grant(packageName: String, permission: String) {
        val descriptor = InstrumentationRegistry.getInstrumentation()
            .uiAutomation
            .executeShellCommand("pm grant $packageName $permission")
        FileInputStream(descriptor.fileDescriptor).use { it.readBytes() }
        descriptor.close()
    }
}
