package com.thatcube.hozz.projection

import com.thatcube.hozz.core.CanonicalRecord
import com.thatcube.hozz.core.HealthConnectProjection
import com.thatcube.hozz.generated.GeneratedContract
import com.thatcube.hozz.generated.MappingDisposition
import com.thatcube.hozz.generated.MappingQuality
import java.time.Instant
import kotlin.math.abs
import kotlin.math.roundToLong
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonObject

enum class ProjectionQuality {
    EXACT,
    LOSSY,
    ARCHIVE_ONLY,
    DELETE,
}

enum class ProjectionAction {
    INSERT,
    UPDATE,
    DELETE,
    NONE,
}

data class MappingWarning(
    val code: String,
    val canonicalId: String,
    val field: String?,
    val message: String,
)

sealed interface ProjectionDraft {
    val canonicalId: String
    val recordVersion: Long

    data class Delete(
        override val canonicalId: String,
        override val recordVersion: Long,
        val targetRecord: String,
        val healthConnectRecordId: String,
    ) : ProjectionDraft

    data class Steps(
        override val canonicalId: String,
        override val recordVersion: Long,
        val start: Instant,
        val end: Instant,
        val count: Long,
    ) : ProjectionDraft

    data class HeartRate(
        override val canonicalId: String,
        override val recordVersion: Long,
        val start: Instant,
        val end: Instant,
        val beatsPerMinute: Long,
    ) : ProjectionDraft

    data class Weight(
        override val canonicalId: String,
        override val recordVersion: Long,
        val time: Instant,
        val kilograms: Double,
    ) : ProjectionDraft

    data class Height(
        override val canonicalId: String,
        override val recordVersion: Long,
        val time: Instant,
        val meters: Double,
    ) : ProjectionDraft

    data class Sleep(
        override val canonicalId: String,
        override val recordVersion: Long,
        val start: Instant,
        val end: Instant,
        val stage: String,
    ) : ProjectionDraft

    data class Distance(
        override val canonicalId: String,
        override val recordVersion: Long,
        val start: Instant,
        val end: Instant,
        val meters: Double,
    ) : ProjectionDraft

    data class ActiveEnergy(
        override val canonicalId: String,
        override val recordVersion: Long,
        val start: Instant,
        val end: Instant,
        val kilocalories: Double,
    ) : ProjectionDraft

    data class Exercise(
        override val canonicalId: String,
        override val recordVersion: Long,
        val start: Instant,
        val end: Instant,
        val exerciseType: String,
        val sourceActivityType: Int,
    ) : ProjectionDraft
}

data class PlannedRecord(
    val source: CanonicalRecord,
    val quality: ProjectionQuality,
    val draft: ProjectionDraft?,
    val warnings: List<MappingWarning>,
    val action: ProjectionAction,
)

data class ProjectionPlan(val records: List<PlannedRecord>) {
    val exactCount: Int = records.count { it.quality == ProjectionQuality.EXACT }
    val lossyCount: Int = records.count { it.quality == ProjectionQuality.LOSSY }
    val archiveOnlyCount: Int =
        records.count { it.quality == ProjectionQuality.ARCHIVE_ONLY }
    val drafts: List<ProjectionDraft> = records.mapNotNull(PlannedRecord::draft)
    val warnings: List<MappingWarning> = records.flatMap(PlannedRecord::warnings)
    val insertCount: Int =
        records.count { it.action == ProjectionAction.INSERT }
    val updateCount: Int =
        records.count { it.action == ProjectionAction.UPDATE }
    val deleteCount: Int =
        records.count { it.action == ProjectionAction.DELETE }

    fun summary(): ProjectionSummary = ProjectionSummary(
        exactCount = exactCount,
        lossyCount = lossyCount,
        archiveOnlyCount = archiveOnlyCount,
        warningCounts = warnings.groupingBy(MappingWarning::code).eachCount(),
        targetRecords = drafts.mapTo(linkedSetOf(), ProjectionDraft::targetRecord),
        insertCount = insertCount,
        updateCount = updateCount,
        deleteCount = deleteCount,
    )
}

data class WarningDetail(
    val code: String,
    val message: String,
    val count: Int,
)

data class ProjectionSummary(
    val exactCount: Int = 0,
    val lossyCount: Int = 0,
    val archiveOnlyCount: Int = 0,
    val warningCounts: Map<String, Int> = emptyMap(),
    val targetRecords: Set<String> = emptySet(),
    val insertCount: Int = 0,
    val updateCount: Int = 0,
    val deleteCount: Int = 0,
) {
    val mappedCount: Int
        get() = exactCount + lossyCount
    val pendingCount: Int
        get() = insertCount + updateCount + deleteCount
    val warningDetails: List<WarningDetail>
        get() = warningCounts.map { (code, count) ->
            WarningDetail(
                code = code,
                message = GeneratedContract.warningMessages[code]
                    ?: "This record cannot be represented exactly.",
                count = count,
            )
        }.sortedBy(WarningDetail::code)

    operator fun plus(other: ProjectionSummary): ProjectionSummary =
        ProjectionSummary(
            exactCount = exactCount + other.exactCount,
            lossyCount = lossyCount + other.lossyCount,
            archiveOnlyCount = archiveOnlyCount + other.archiveOnlyCount,
            warningCounts = (warningCounts.keys + other.warningCounts.keys)
                .associateWith { code ->
                    (warningCounts[code] ?: 0) + (other.warningCounts[code] ?: 0)
                },
            targetRecords = targetRecords + other.targetRecords,
            insertCount = insertCount + other.insertCount,
            updateCount = updateCount + other.updateCount,
            deleteCount = deleteCount + other.deleteCount,
        )
}

fun ProjectionDraft.targetRecord(): String = when (this) {
    is ProjectionDraft.Delete -> targetRecord
    is ProjectionDraft.Steps -> "StepsRecord"
    is ProjectionDraft.HeartRate -> "HeartRateRecord"
    is ProjectionDraft.Weight -> "WeightRecord"
    is ProjectionDraft.Height -> "HeightRecord"
    is ProjectionDraft.Sleep -> "SleepSessionRecord"
    is ProjectionDraft.Distance -> "DistanceRecord"
    is ProjectionDraft.ActiveEnergy -> "ActiveCaloriesBurnedRecord"
    is ProjectionDraft.Exercise -> "ExerciseSessionRecord"
}

object ProjectionPlanner {
    fun plan(
        records: List<CanonicalRecord>,
        projections: Map<String, HealthConnectProjection> = emptyMap(),
    ): ProjectionPlan =
        ProjectionPlan(records.map { record ->
            plan(record, projections[record.canonicalId])
        })

    fun plan(
        record: CanonicalRecord,
        projection: HealthConnectProjection? = null,
    ): PlannedRecord {
        if (record.hasVisitedHealthConnectTarget()) {
            return applyProjectionState(
                archiveOnly(record, "source-store-loop", "lineage"),
                projection,
            )
        }
        if (record.kind == "clinicalRecord") {
            return applyProjectionState(
                archiveOnly(record, "clinical-snapshot-incomplete"),
                projection,
            )
        }
        if (record.tombstone) {
            val existing = projection
                ?: return archiveOnly(record, "tombstone")
            return exact(
                record,
                ProjectionDraft.Delete(
                    canonicalId = record.canonicalId,
                    recordVersion = record.recordVersion,
                    targetRecord = existing.targetRecord,
                    healthConnectRecordId = existing.healthConnectRecordId,
                ),
                action = ProjectionAction.DELETE,
            )
        }
        if (record.kind in GeneratedContract.archiveOnlyKinds) {
            return applyProjectionState(
                archiveOnly(record, "unsupported-type"),
                projection,
            )
        }
        val mapping = GeneratedContract.recordMappings[record.type]
            ?: return applyProjectionState(
                archiveOnly(record, "unsupported-type"),
                projection,
            )
        if (mapping.sourceKind != record.kind) {
            return applyProjectionState(
                archiveOnly(record, "unsupported-type", "kind"),
                projection,
            )
        }
        if (mapping.quality == MappingQuality.ARCHIVE_ONLY) {
            if (projection != null) {
                return PlannedRecord(
                    source = record,
                    quality = ProjectionQuality.ARCHIVE_ONLY,
                    draft = ProjectionDraft.Delete(
                        canonicalId = record.canonicalId,
                        recordVersion = record.recordVersion,
                        targetRecord = projection.targetRecord,
                        healthConnectRecordId =
                            projection.healthConnectRecordId,
                    ),
                    warnings = listOf(
                        warning(
                            record,
                            mapping.warningCode ?: "unsupported-type",
                            null,
                        ),
                    ),
                    action = ProjectionAction.DELETE,
                )
            }
            return archiveOnly(
                record,
                mapping.warningCode ?: "unsupported-type",
            )
        }

        val planned = when (mapping.targetRecord) {
            "StepsRecord" -> steps(record)
            "HeartRateRecord" -> heartRate(record)
            "WeightRecord" -> weight(record)
            "HeightRecord" -> height(record)
            "SleepSessionRecord" -> sleep(record)
            "DistanceRecord" -> distance(record)
            "ActiveCaloriesBurnedRecord" -> activeEnergy(record)
            "ExerciseSessionRecord" -> exercise(record)
            else -> archiveOnly(record, "unsupported-type")
        }
        return applyProjectionState(planned, projection)
    }

    private fun applyProjectionState(
        planned: PlannedRecord,
        projection: HealthConnectProjection?,
    ): PlannedRecord {
        val draft = planned.draft
        if (draft == null) {
            return if (projection == null) {
                planned
            } else {
                planned.copy(
                    draft = ProjectionDraft.Delete(
                        canonicalId = planned.source.canonicalId,
                        recordVersion = planned.source.recordVersion,
                        targetRecord = projection.targetRecord,
                        healthConnectRecordId =
                            projection.healthConnectRecordId,
                    ),
                    action = ProjectionAction.DELETE,
                )
            }
        }
        if (projection == null) {
            return planned.copy(action = ProjectionAction.INSERT)
        }
        if (projection.canonicalVersion >= draft.recordVersion) {
            return planned.copy(draft = null, action = ProjectionAction.NONE)
        }
        return planned.copy(action = ProjectionAction.UPDATE)
    }

    private fun steps(record: CanonicalRecord): PlannedRecord {
        val value = record.canonicalValue?.value
            ?: return archiveOnly(record, "invalid-value", "quantity.value")
        val count = value.roundToLong()
        val interval = interval(record)
            ?: return archiveOnly(record, "invalid-value", "startDate")
        if (value != count.toDouble() || count !in 1..1_000_000) {
            return archiveOnly(record, "invalid-value", "quantity.value")
        }
        return exact(
            record,
            ProjectionDraft.Steps(
                record.canonicalId,
                record.recordVersion,
                interval.first,
                interval.second,
                count,
            ),
        )
    }

    private fun heartRate(record: CanonicalRecord): PlannedRecord {
        if ((record.quantityCount ?: 1) > 1) {
            return archiveOnly(record, "heart-rate-aggregate", "quantity.count")
        }
        val value = record.canonicalValue
            ?: return archiveOnly(record, "invalid-value", "quantity.value")
        val bpm = when (value.unit) {
            "count/s" -> value.value * 60
            "count/min" -> value.value
            else -> return archiveOnly(record, "invalid-value", "quantity.unit")
        }
        if (!bpm.isFinite()) {
            return archiveOnly(record, "invalid-value", "quantity.value")
        }
        val rounded = bpm.roundToLong()
        val interval = interval(record, allowPoint = true)
            ?: return archiveOnly(record, "invalid-value", "startDate")
        if (
            abs(bpm - rounded.toDouble()) > HEART_RATE_ROUNDING_TOLERANCE ||
            rounded !in 1..300
        ) {
            return archiveOnly(record, "invalid-value", "quantity.value")
        }

        return exact(
            record,
            ProjectionDraft.HeartRate(
                record.canonicalId,
                record.recordVersion,
                interval.first,
                interval.second,
                rounded,
            ),
        )
    }

    private const val HEART_RATE_ROUNDING_TOLERANCE = 1e-9

    private fun weight(record: CanonicalRecord): PlannedRecord {
        val value = record.canonicalValue
            ?: return archiveOnly(record, "invalid-value", "quantity.value")
        val time = record.startTime
            ?: return archiveOnly(record, "invalid-value", "startDate")
        if (value.unit != "kg" || value.value !in 0.0..1_000.0) {
            return archiveOnly(record, "invalid-value", "quantity")
        }
        return exact(
            record,
            ProjectionDraft.Weight(
                record.canonicalId,
                record.recordVersion,
                time,
                value.value,
            ),
        )
    }

    private fun height(record: CanonicalRecord): PlannedRecord {
        val value = record.canonicalValue
            ?: return archiveOnly(record, "invalid-value", "quantity.value")
        val time = record.startTime
            ?: return archiveOnly(record, "invalid-value", "startDate")
        if (value.unit != "m" || value.value !in 0.0..3.0) {
            return archiveOnly(record, "invalid-value", "quantity")
        }
        return exact(
            record,
            ProjectionDraft.Height(
                record.canonicalId,
                record.recordVersion,
                time,
                value.value,
            ),
        )
    }

    private fun sleep(record: CanonicalRecord): PlannedRecord {
        val value = record.categoryValue
            ?: return archiveOnly(record, "invalid-value", "value")
        val stage = GeneratedContract.sleepStages[value]
            ?: return archiveOnly(record, "unsupported-type", "value")
        if (stage.disposition == MappingDisposition.ARCHIVE_ONLY) {
            return archiveOnly(
                record,
                stage.warningCode ?: "unsupported-type",
                "value",
            )
        }
        val interval = interval(record)
            ?: return archiveOnly(record, "invalid-value", "startDate")
        val draft = ProjectionDraft.Sleep(
            record.canonicalId,
            record.recordVersion,
            interval.first,
            interval.second,
            stage.targetStage
                ?: return archiveOnly(record, "unsupported-type", "value"),
        )
        return if (stage.disposition == MappingDisposition.LOSSY) {
            lossy(record, draft, stage.warningCode ?: "unsupported-type", "value")
        } else {
            exact(record, draft)
        }
    }

    private fun distance(record: CanonicalRecord): PlannedRecord {
        val value = record.canonicalValue
            ?: return archiveOnly(record, "invalid-value", "quantity.value")
        val interval = interval(record)
            ?: return archiveOnly(record, "invalid-value", "startDate")
        if (value.unit != "m" || value.value !in 0.0..1_000_000.0) {
            return archiveOnly(record, "invalid-value", "quantity")
        }
        return exact(
            record,
            ProjectionDraft.Distance(
                record.canonicalId,
                record.recordVersion,
                interval.first,
                interval.second,
                value.value,
            ),
        )
    }

    private fun activeEnergy(record: CanonicalRecord): PlannedRecord {
        val value = record.canonicalValue
            ?: return archiveOnly(record, "invalid-value", "quantity.value")
        val interval = interval(record)
            ?: return archiveOnly(record, "invalid-value", "startDate")
        if (value.unit != "kcal" || value.value !in 0.0..1_000_000.0) {
            return archiveOnly(record, "invalid-value", "quantity")
        }
        return exact(
            record,
            ProjectionDraft.ActiveEnergy(
                record.canonicalId,
                record.recordVersion,
                interval.first,
                interval.second,
                value.value,
            ),
        )
    }

    private fun exercise(record: CanonicalRecord): PlannedRecord {
        val activity = record.activityType
            ?: return archiveOnly(record, "invalid-value", "activityType")
        val interval = interval(record)
            ?: return archiveOnly(record, "invalid-value", "startDate")
        val mapped = GeneratedContract.workoutActivities[activity]
        val draft = ProjectionDraft.Exercise(
            record.canonicalId,
            record.recordVersion,
            interval.first,
            interval.second,
            mapped?.targetExercise ?: "OTHER_WORKOUT",
            activity,
        )
        val warnings = buildList {
            if (mapped == null) {
                add(warning(record, "workout-activity-generalized", "activityType"))
            }
            if (workoutHasArchiveOnlyDetails(record)) {
                add(warning(record, "workout-details-archive-only", "workout"))
            }
        }
        return if (warnings.isNotEmpty()) {
            PlannedRecord(
                source = record,
                quality = ProjectionQuality.LOSSY,
                draft = draft,
                warnings = warnings,
                action = ProjectionAction.INSERT,
            )
        } else {
            exact(record, draft)
        }
    }

    private fun workoutHasArchiveOnlyDetails(record: CanonicalRecord): Boolean {
        val jsonObject = Json.parseToJsonElement(record.rawJson).jsonObject
        return listOf("events", "statistics", "activities").any { field ->
            (jsonObject[field] as? JsonArray)?.isNotEmpty() == true
        }
    }

    private fun interval(
        record: CanonicalRecord,
        allowPoint: Boolean = false,
    ): Pair<Instant, Instant>? {
        val start = record.startTime ?: return null
        val end = record.endTime ?: return null
        return if (start < end || (allowPoint && start == end)) {
            start to end
        } else {
            null
        }
    }

    private fun exact(
        record: CanonicalRecord,
        draft: ProjectionDraft,
        action: ProjectionAction = ProjectionAction.INSERT,
    ): PlannedRecord = PlannedRecord(
        source = record,
        quality = if (action == ProjectionAction.DELETE) {
            ProjectionQuality.DELETE
        } else {
            ProjectionQuality.EXACT
        },
        draft = draft,
        warnings = emptyList(),
        action = action,
    )

    private fun lossy(
        record: CanonicalRecord,
        draft: ProjectionDraft,
        code: String,
        field: String? = null,
    ): PlannedRecord = PlannedRecord(
        source = record,
        quality = ProjectionQuality.LOSSY,
        draft = draft,
        warnings = listOf(warning(record, code, field)),
        action = ProjectionAction.INSERT,
    )

    private fun archiveOnly(
        record: CanonicalRecord,
        code: String,
        field: String? = null,
    ): PlannedRecord = PlannedRecord(
        source = record,
        quality = ProjectionQuality.ARCHIVE_ONLY,
        draft = null,
        warnings = listOf(warning(record, code, field)),
        action = ProjectionAction.NONE,
    )

    private fun warning(
        record: CanonicalRecord,
        code: String,
        field: String?,
    ): MappingWarning = MappingWarning(
        code = code,
        canonicalId = record.canonicalId,
        field = field,
        message = GeneratedContract.warningMessages[code]
            ?: "This record cannot be represented exactly.",
    )
}
