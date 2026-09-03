package com.thatcube.hozz.projection

import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.StepsRecord
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.time.Instant
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HealthConnectWriterIntegrationTest {
    @Test
    fun repeatedClientIdUpsertsInsteadOfDuplicating() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        assumeTrue(
            HealthConnectClient.getSdkStatus(context) ==
                HealthConnectClient.SDK_AVAILABLE,
        )
        val client = HealthConnectClient.getOrCreate(context)
        val permission = HealthPermission.getWritePermission(StepsRecord::class)
        assumeTrue(client.permissionController.getGrantedPermissions().contains(permission))

        val canonicalId = "apple.healthkit:hozz-integration-upsert"
        val start = Instant.now().minusSeconds(120)
        val end = start.plusSeconds(60)
        val versionOne = ProjectionDraft.Steps(
            canonicalId = canonicalId,
            recordVersion = 1,
            start = start,
            end = end,
            count = 1,
        )
        val versionTwo = versionOne.copy(recordVersion = 2, count = 2)
        val writer = HealthConnectWriter(context)

        try {
            val first = writer.write(listOf(versionOne))
            val retry = writer.write(listOf(versionOne))
            val updated = writer.write(listOf(versionTwo))

            assertEquals(1, first.attempted)
            assertEquals(1, retry.attempted)
            assertEquals(1, updated.attempted)
            assertEquals(1, first.insertedRecordIds.size)
            assertEquals(first.insertedRecordIds, retry.insertedRecordIds)
            assertEquals(first.insertedRecordIds, updated.insertedRecordIds)
        } finally {
            client.deleteRecords(
                recordType = StepsRecord::class,
                recordIdsList = emptyList(),
                clientRecordIdsList = listOf(canonicalId),
            )
        }
    }
}
