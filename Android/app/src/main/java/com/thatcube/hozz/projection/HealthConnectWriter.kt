package com.thatcube.hozz.projection

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeightRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.units.Energy
import androidx.health.connect.client.units.Length
import androidx.health.connect.client.units.Mass
import com.thatcube.hozz.core.HealthConnectProjection

data class HealthConnectWriteResult(
    val attempted: Int,
    val projections: List<HealthConnectProjection>,
)

interface HealthConnectProjectionWriter {
    suspend fun writeUpserts(
        drafts: List<ProjectionDraft>,
    ): HealthConnectWriteResult

    suspend fun delete(
        drafts: List<ProjectionDraft.Delete>,
    ): List<HealthConnectProjection>
}

class HealthConnectWriter(
    private val context: Context,
) : HealthConnectProjectionWriter {
    val availability: Int
        get() = HealthConnectClient.getSdkStatus(context)

    fun requiredPermissions(drafts: List<ProjectionDraft>): Set<String> =
        drafts.mapTo(linkedSetOf()) { draft ->
            requiredPermission(draft)
        }

    fun requiredPermission(draft: ProjectionDraft): String =
        HealthPermission.getWritePermission(recordClass(draft))

    fun requiredPermissions(targetRecords: Set<String>): Set<String> =
        targetRecords.mapTo(linkedSetOf()) { target ->
            HealthPermission.getWritePermission(recordClass(target))
        }

    suspend fun missingPermissions(targetRecords: Set<String>): Set<String> {
        val client = client()
        return requiredPermissions(targetRecords) -
            client.permissionController.getGrantedPermissions()
    }

    override suspend fun writeUpserts(
        drafts: List<ProjectionDraft>,
    ): HealthConnectWriteResult {
        if (drafts.isEmpty()) {
            return HealthConnectWriteResult(0, emptyList())
        }
        val client = client()
        val projections = mutableListOf<HealthConnectProjection>()
        val insertions = drafts.filterNot { it is ProjectionDraft.Delete }
        for (chunk in insertions.chunked(MAX_INSERT_RECORDS)) {
            val response = client.insertRecords(chunk.map(::record))
            require(response.recordIdsList.size == chunk.size) {
                "Health Connect returned a different number of record IDs."
            }
            projections += chunk.zip(response.recordIdsList) { draft, recordId ->
                HealthConnectProjection(
                    canonicalId = draft.canonicalId,
                    targetRecord = draft.targetRecord(),
                    canonicalVersion = draft.recordVersion,
                    healthConnectRecordId = recordId,
                )
            }
        }
        return HealthConnectWriteResult(insertions.size, projections)
    }

    override suspend fun delete(
        drafts: List<ProjectionDraft.Delete>,
    ): List<HealthConnectProjection> {
        if (drafts.isEmpty()) {
            return emptyList()
        }
        val client = client()
        val removed = mutableListOf<HealthConnectProjection>()
        for ((target, records) in drafts.groupBy(ProjectionDraft.Delete::targetRecord)) {
            for (chunk in records.chunked(MAX_INSERT_RECORDS)) {
                client.deleteRecords(
                    recordType = recordClass(target),
                    recordIdsList = chunk.map(
                        ProjectionDraft.Delete::healthConnectRecordId,
                    ),
                    clientRecordIdsList = emptyList(),
                )
                removed += chunk.map { draft ->
                    HealthConnectProjection(
                        canonicalId = draft.canonicalId,
                        targetRecord = draft.targetRecord,
                        canonicalVersion = draft.recordVersion,
                        healthConnectRecordId = draft.healthConnectRecordId,
                    )
                }
            }
        }
        return removed
    }

    private fun client(): HealthConnectClient {
        check(availability == HealthConnectClient.SDK_AVAILABLE) {
            "Health Connect is not available on this device."
        }
        return HealthConnectClient.getOrCreate(context)
    }

    private fun recordClass(draft: ProjectionDraft) = when (draft) {
        is ProjectionDraft.Delete -> recordClass(draft.targetRecord)
        is ProjectionDraft.Steps -> StepsRecord::class
        is ProjectionDraft.HeartRate -> HeartRateRecord::class
        is ProjectionDraft.Weight -> WeightRecord::class
        is ProjectionDraft.Height -> HeightRecord::class
        is ProjectionDraft.Sleep -> SleepSessionRecord::class
        is ProjectionDraft.Distance -> DistanceRecord::class
        is ProjectionDraft.ActiveEnergy -> ActiveCaloriesBurnedRecord::class
        is ProjectionDraft.Exercise -> ExerciseSessionRecord::class
    }

    private fun recordClass(targetRecord: String) = when (targetRecord) {
        "StepsRecord" -> StepsRecord::class
        "HeartRateRecord" -> HeartRateRecord::class
        "WeightRecord" -> WeightRecord::class
        "HeightRecord" -> HeightRecord::class
        "SleepSessionRecord" -> SleepSessionRecord::class
        "DistanceRecord" -> DistanceRecord::class
        "ActiveCaloriesBurnedRecord" -> ActiveCaloriesBurnedRecord::class
        "ExerciseSessionRecord" -> ExerciseSessionRecord::class
        else -> error("Unknown generated Health Connect record $targetRecord")
    }

    private fun record(draft: ProjectionDraft): Record {
        val metadata = healthConnectMetadata(draft)
        return when (draft) {
            is ProjectionDraft.Delete ->
                error("Deletion drafts are applied through deleteRecords.")
            is ProjectionDraft.Steps -> StepsRecord(
                startTime = draft.start,
                startZoneOffset = null,
                endTime = draft.end,
                endZoneOffset = null,
                count = draft.count,
                metadata = metadata,
            )
            is ProjectionDraft.HeartRate -> HeartRateRecord(
                startTime = draft.start,
                startZoneOffset = null,
                endTime = draft.end,
                endZoneOffset = null,
                samples = listOf(
                    HeartRateRecord.Sample(
                        time = draft.start,
                        beatsPerMinute = draft.beatsPerMinute,
                    ),
                ),
                metadata = metadata,
            )
            is ProjectionDraft.Weight -> WeightRecord(
                time = draft.time,
                zoneOffset = null,
                weight = Mass.kilograms(draft.kilograms),
                metadata = metadata,
            )
            is ProjectionDraft.Height -> HeightRecord(
                time = draft.time,
                zoneOffset = null,
                height = Length.meters(draft.meters),
                metadata = metadata,
            )
            is ProjectionDraft.Sleep -> SleepSessionRecord(
                startTime = draft.start,
                startZoneOffset = null,
                endTime = draft.end,
                endZoneOffset = null,
                metadata = metadata,
                stages = listOf(
                    SleepSessionRecord.Stage(
                        startTime = draft.start,
                        endTime = draft.end,
                        stage = sleepStage(draft.stage),
                    ),
                ),
            )
            is ProjectionDraft.Distance -> DistanceRecord(
                startTime = draft.start,
                startZoneOffset = null,
                endTime = draft.end,
                endZoneOffset = null,
                distance = Length.meters(draft.meters),
                metadata = metadata,
            )
            is ProjectionDraft.ActiveEnergy -> ActiveCaloriesBurnedRecord(
                startTime = draft.start,
                startZoneOffset = null,
                endTime = draft.end,
                endZoneOffset = null,
                energy = Energy.kilocalories(draft.kilocalories),
                metadata = metadata,
            )
            is ProjectionDraft.Exercise -> ExerciseSessionRecord(
                startTime = draft.start,
                startZoneOffset = null,
                endTime = draft.end,
                endZoneOffset = null,
                metadata = metadata,
                exerciseType = exerciseType(draft.exerciseType),
            )
        }
    }

    private fun sleepStage(stage: String): Int = when (stage) {
        "AWAKE" -> SleepSessionRecord.STAGE_TYPE_AWAKE
        "SLEEPING" -> SleepSessionRecord.STAGE_TYPE_SLEEPING
        "LIGHT" -> SleepSessionRecord.STAGE_TYPE_LIGHT
        "DEEP" -> SleepSessionRecord.STAGE_TYPE_DEEP
        "REM" -> SleepSessionRecord.STAGE_TYPE_REM
        else -> error("Unknown generated sleep stage $stage")
    }

    private fun exerciseType(type: String): Int = when (type) {
        "BIKING" -> ExerciseSessionRecord.EXERCISE_TYPE_BIKING
        "HIKING" -> ExerciseSessionRecord.EXERCISE_TYPE_HIKING
        "RUNNING" -> ExerciseSessionRecord.EXERCISE_TYPE_RUNNING
        "WALKING" -> ExerciseSessionRecord.EXERCISE_TYPE_WALKING
        "OTHER_WORKOUT" -> ExerciseSessionRecord.EXERCISE_TYPE_OTHER_WORKOUT
        else -> error("Unknown generated exercise type $type")
    }
}

internal fun healthConnectMetadata(draft: ProjectionDraft): Metadata =
    Metadata.unknownRecordingMethod(
        clientRecordId = draft.canonicalId,
        clientRecordVersion = draft.recordVersion,
    )

private const val MAX_INSERT_RECORDS = 500
