package com.thatcube.hozz.projection

import com.thatcube.hozz.core.CanonicalRecord
import com.thatcube.hozz.core.CanonicalValue
import com.thatcube.hozz.core.HealthConnectProjection
import com.thatcube.hozz.core.InMemoryCanonicalRecordStore
import com.thatcube.hozz.core.SourceLineage
import java.time.Instant
import kotlin.math.roundToLong
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProjectionPlannerTest {
    @Test
    fun firstSliceMapsEveryRequiredType() {
        val records = listOf(
            quantity("steps", "HKQuantityTypeIdentifierStepCount", 1.0, "count"),
            quantity("heart", "HKQuantityTypeIdentifierHeartRate", 1.0, "count/s"),
            quantity("weight", "HKQuantityTypeIdentifierBodyMass", 1.0, "kg"),
            quantity("height", "HKQuantityTypeIdentifierHeight", 1.0, "m"),
            category("sleep", 1),
            quantity(
                "distance",
                "HKQuantityTypeIdentifierDistanceWalkingRunning",
                1.0,
                "m",
            ),
            quantity(
                "energy",
                "HKQuantityTypeIdentifierActiveEnergyBurned",
                1.0,
                "kcal",
            ),
            workout("run", 37),
        )

        val plan = ProjectionPlanner.plan(records)

        assertEquals(4, plan.exactCount)
        assertEquals(0, plan.lossyCount)
        assertEquals(4, plan.archiveOnlyCount)
        assertEquals(4, plan.drafts.size)
        assertEquals(4, plan.insertCount)
    }

    @Test
    fun individualSleepStagesStayArchiveOnlyUntilSessionsAreAssembled() {
        val core = ProjectionPlanner.plan(category("core", 3))
        val inBed = ProjectionPlanner.plan(category("bed", 0))

        assertEquals(ProjectionQuality.ARCHIVE_ONLY, core.quality)
        assertEquals("sleep-session-required", core.warnings.single().code)
        assertEquals(ProjectionQuality.ARCHIVE_ONLY, inBed.quality)
        assertEquals("sleep-session-required", inBed.warnings.single().code)
    }

    @Test
    fun aggregateHeartRateIsNotInventedAsOneReading() {
        val record = quantity(
            "heart",
            "HKQuantityTypeIdentifierHeartRate",
            1.0,
            "count/s",
        ).copy(quantityCount = 30)

        val planned = ProjectionPlanner.plan(record)

        assertEquals(ProjectionQuality.ARCHIVE_ONLY, planned.quality)
        assertEquals("heart-rate-aggregate", planned.warnings.single().code)
        assertNull(planned.draft)
    }

    @Test
    fun unknownWorkoutProjectsAsOtherWithWarning() {
        val planned = ProjectionPlanner.plan(workout("future", 9_999))

        assertEquals(ProjectionQuality.LOSSY, planned.quality)
        assertEquals(
            "OTHER_WORKOUT",
            (planned.draft as ProjectionDraft.Exercise).exerciseType,
        )
        assertEquals("workout-activity-generalized", planned.warnings.single().code)
    }

    @Test
    fun mappedWorkoutWithRichDetailsIsStillReportedAsLossy() {
        val record = workout("run-with-statistics", 37).copy(
            rawJson =
                """
                {"events":[],"statistics":[{"type":"distance"}]}
                """.trimIndent(),
        )

        val planned = ProjectionPlanner.plan(record)

        assertEquals(ProjectionQuality.LOSSY, planned.quality)
        assertEquals("RUNNING", (planned.draft as ProjectionDraft.Exercise).exerciseType)
        assertEquals("workout-details-archive-only", planned.warnings.single().code)
    }

    @Test
    fun healthConnectLineageCannotLoopBackIntoSamePackage() {
        val record = quantity(
            "loop",
            "HKQuantityTypeIdentifierStepCount",
            1.0,
            "count",
        ).copy(
            lineage = listOf(
                SourceLineage(
                    store = "healthConnect",
                    packageName = "com.thatcube.hozz",
                    recordId = "loop",
                ),
            ),
        )

        val planned = ProjectionPlanner.plan(record)

        assertEquals(ProjectionQuality.ARCHIVE_ONLY, planned.quality)
        assertEquals("source-store-loop", planned.warnings.single().code)
    }

    @Test
    fun mappedTombstoneBecomesDeterministicHealthConnectDeletion() {
        val record = quantity(
            "deleted",
            "HKQuantityTypeIdentifierStepCount",
            1.0,
            "count",
            version = 2,
        ).copy(tombstone = true)

        val ledger = HealthConnectProjection(
            canonicalId = record.canonicalId,
            targetRecord = "StepsRecord",
            canonicalVersion = 1,
            healthConnectRecordId = "health-connect-id",
        )
        val planned = ProjectionPlanner.plan(record, ledger)

        assertEquals(ProjectionQuality.DELETE, planned.quality)
        assertEquals(ProjectionAction.DELETE, planned.action)
        val deletion = planned.draft as ProjectionDraft.Delete
        assertEquals(record.canonicalId, deletion.canonicalId)
        assertEquals(record.recordVersion, deletion.recordVersion)
        assertEquals("StepsRecord", deletion.targetRecord)
        assertEquals("health-connect-id", deletion.healthConnectRecordId)
    }

    @Test
    fun metadataUsesCanonicalIdentityAndMonotonicVersionForEveryRetry() {
        val draft = ProjectionPlanner.plan(
            quantity(
                id = "retry",
                type = "HKQuantityTypeIdentifierBodyMass",
                value = 1.0,
                unit = "kg",
                version = 7,
            ),
        ).draft!!

        val first = healthConnectMetadata(draft)
        val retry = healthConnectMetadata(draft)

        assertEquals("apple.healthkit:retry", first.clientRecordId)
        assertEquals(7, first.clientRecordVersion)
        assertEquals(first.clientRecordId, retry.clientRecordId)
        assertEquals(first.clientRecordVersion, retry.clientRecordVersion)
    }

    @Test
    fun pointHeartRateIsAValidProjection() {
        val instant = Instant.parse("2026-01-01T00:00:00Z")
        val record = quantity(
            "point-heart",
            "HKQuantityTypeIdentifierHeartRate",
            1.0,
            "count/s",
        ).copy(startTime = instant, endTime = instant)

        val planned = ProjectionPlanner.plan(record)

        assertEquals(ProjectionQuality.EXACT, planned.quality)
        assertEquals(instant, (planned.draft as ProjectionDraft.HeartRate).end)
    }

    @Test
    fun floatingHeartRateNoiseRoundsOnlyWithinATightTolerance() {
        val valid = listOf(
            62.0 / 60.0 to "count/s",
            62.00000000000001 to "count/min",
            119.99999999999999 to "count/min",
        )
        for ((value, unit) in valid) {
            val planned = ProjectionPlanner.plan(
                quantity("heart-$value", "HKQuantityTypeIdentifierHeartRate", value, unit),
            )
            assertEquals(value.toString(), ProjectionQuality.EXACT, planned.quality)
            assertEquals(
                value.toString(),
                value.times(if (unit == "count/s") 60 else 1).roundToLong(),
                (planned.draft as ProjectionDraft.HeartRate).beatsPerMinute,
            )
        }
        val outsideTolerance = ProjectionPlanner.plan(
            quantity(
                "heart-imprecise",
                "HKQuantityTypeIdentifierHeartRate",
                62.0001,
                "count/min",
            ),
        )
        assertEquals(ProjectionQuality.ARCHIVE_ONLY, outsideTolerance.quality)
        val nonfinite = ProjectionPlanner.plan(
            quantity(
                "heart-nan",
                "HKQuantityTypeIdentifierHeartRate",
                Double.NaN,
                "count/min",
            ),
        )
        assertEquals(ProjectionQuality.ARCHIVE_ONLY, nonfinite.quality)
    }

    @Test
    fun ledgerClassifiesInsertUpdateCurrentAndUnknownDelete() {
        val record = quantity(
            "weight-ledger",
            "HKQuantityTypeIdentifierBodyMass",
            1.0,
            "kg",
            version = 2,
        )
        val older = HealthConnectProjection(
            record.canonicalId,
            "WeightRecord",
            1,
            "health-id",
        )
        val current = older.copy(canonicalVersion = 2)

        assertEquals(ProjectionAction.INSERT, ProjectionPlanner.plan(record).action)
        assertEquals(
            ProjectionAction.UPDATE,
            ProjectionPlanner.plan(record, older).action,
        )
        val currentPlan = ProjectionPlanner.plan(record, current)
        assertEquals(ProjectionAction.NONE, currentPlan.action)
        assertNull(currentPlan.draft)

        val unknownDelete = ProjectionPlanner.plan(record.copy(tombstone = true))
        assertEquals(ProjectionAction.NONE, unknownDelete.action)
        assertNull(unknownDelete.draft)
    }

    @Test
    fun cumulativeTypesAreArchiveOnlyRatherThanDoubleCounted() {
        val records = listOf(
            quantity("steps", "HKQuantityTypeIdentifierStepCount", 1.0, "count"),
            quantity(
                "distance",
                "HKQuantityTypeIdentifierDistanceWalkingRunning",
                1.0,
                "m",
            ),
            quantity(
                "energy",
                "HKQuantityTypeIdentifierActiveEnergyBurned",
                1.0,
                "kcal",
            ),
        )

        val summary = ProjectionPlanner.plan(records).summary()

        assertEquals(3, summary.archiveOnlyCount)
        assertEquals(0, summary.pendingCount)
        assertEquals(3, summary.warningCounts["cumulative-source-overlap"])
        assertEquals(3, summary.warningDetails.single().count)
        assertTrue(
            summary.warningDetails.single().message.contains("inflate"),
        )

        val priorProjection = HealthConnectProjection(
            canonicalId = records.first().canonicalId,
            targetRecord = "StepsRecord",
            canonicalVersion = 1,
            healthConnectRecordId = "unsafe-old-projection",
        )
        val cleanup = ProjectionPlanner.plan(records.first(), priorProjection)
        assertEquals(ProjectionAction.DELETE, cleanup.action)
        assertEquals(ProjectionQuality.ARCHIVE_ONLY, cleanup.quality)
    }

    @Test
    fun newlyInvalidRecordDeletesItsPriorProjectionWithoutHidingWarning() {
        val record = quantity(
            "aggregated-heart-rate",
            "HKQuantityTypeIdentifierHeartRate",
            60.0,
            "count/min",
            version = 2,
        ).copy(quantityCount = 2)
        val prior = HealthConnectProjection(
            canonicalId = record.canonicalId,
            targetRecord = "HeartRateRecord",
            canonicalVersion = 1,
            healthConnectRecordId = "stale-heart-rate",
        )

        val planned = ProjectionPlanner.plan(record, prior)

        assertEquals(ProjectionQuality.ARCHIVE_ONLY, planned.quality)
        assertEquals(ProjectionAction.DELETE, planned.action)
        assertEquals("heart-rate-aggregate", planned.warnings.single().code)
        assertEquals(
            "stale-heart-rate",
            (planned.draft as ProjectionDraft.Delete).healthConnectRecordId,
        )
    }

    @Test
    fun everyArchiveOnlyTransitionCleansUpAnExistingProjection() {
        val prior = HealthConnectProjection(
            canonicalId = "apple.healthkit:transition",
            targetRecord = "WeightRecord",
            canonicalVersion = 1,
            healthConnectRecordId = "stale-projection",
        )
        val candidates = listOf(
            quantity(
                "transition",
                "HKQuantityTypeIdentifierBodyMass",
                1.0,
                "kg",
                version = 2,
            ).copy(
                lineage = listOf(
                    SourceLineage(
                        "healthConnect",
                        "com.thatcube.hozz",
                        "health-record",
                    ),
                ),
            ),
            base(
                "clinicalRecord",
                "transition",
                "HKClinicalTypeIdentifierAllergyRecord",
                version = 2,
            ),
            base("sample", "transition", "UnknownType", version = 2),
            quantity("transition", "UnknownType", 1.0, "count", version = 2),
        )

        for (record in candidates) {
            val planned = ProjectionPlanner.plan(record, prior)
            assertEquals(record.kind, ProjectionAction.DELETE, planned.action)
            assertTrue(record.kind, planned.warnings.isNotEmpty())
            assertEquals(
                "stale-projection",
                (planned.draft as ProjectionDraft.Delete).healthConnectRecordId,
            )
        }
    }

    @Test
    fun tombstoneDeleteIsPlannedOnlyOnceFromDurableLedger() = runBlocking {
        val record = quantity(
            "delete-once",
            "HKQuantityTypeIdentifierBodyMass",
            1.0,
            "kg",
            version = 2,
        ).copy(tombstone = true)
        val projection = HealthConnectProjection(
            record.canonicalId,
            "WeightRecord",
            1,
            "health-id",
        )
        val store = InMemoryCanonicalRecordStore()
        store.saveHealthConnectProjections(listOf(projection))

        val first = ProjectionPlanner.plan(
            record,
            store.healthConnectProjections(setOf(record.canonicalId))[
                record.canonicalId
            ],
        )
        assertEquals(ProjectionAction.DELETE, first.action)
        store.removeHealthConnectProjections(listOf(projection))
        val replay = ProjectionPlanner.plan(
            record,
            store.healthConnectProjections(setOf(record.canonicalId))[
                record.canonicalId
            ],
        )

        assertEquals(ProjectionAction.NONE, replay.action)
        assertNull(replay.draft)
    }

    @Test
    fun unsupportedAppleKindsRemainVisibleAsArchiveOnly() {
        for (kind in listOf(
            "electrocardiogram",
            "audiogram",
            "stateOfMind",
            "medicationDose",
            "clinicalRecord",
        )) {
            val record = base(kind, kind, "HKFixtureType")
            val planned = ProjectionPlanner.plan(record)
            assertEquals(kind, ProjectionQuality.ARCHIVE_ONLY, planned.quality)
            assertTrue(planned.warnings.isNotEmpty())
        }
    }

    private fun quantity(
        id: String,
        type: String,
        value: Double,
        unit: String,
        version: Long = 1,
    ): CanonicalRecord = base("quantity", id, type, version).copy(
        canonicalValue = CanonicalValue(value, unit),
        originalValue = CanonicalValue(value, unit, "$value $unit"),
        quantityCount = 1,
    )

    private fun category(id: String, value: Int): CanonicalRecord =
        base(
            "category",
            id,
            "HKCategoryTypeIdentifierSleepAnalysis",
        ).copy(categoryValue = value)

    private fun workout(id: String, activityType: Int): CanonicalRecord =
        base("workout", id, "HKWorkoutTypeIdentifier")
            .copy(activityType = activityType)

    private fun base(
        kind: String,
        id: String,
        type: String,
        version: Long = 1,
    ): CanonicalRecord = CanonicalRecord(
        canonicalId = "apple.healthkit:$id",
        parentCanonicalId = null,
        recordVersion = version,
        kind = kind,
        canonicalType = "archive.raw",
        type = type,
        startTime = Instant.parse("2026-01-01T00:00:00Z"),
        endTime = Instant.parse("2026-01-01T00:01:00Z"),
        canonicalValue = null,
        originalValue = null,
        categoryValue = null,
        activityType = null,
        quantityCount = null,
        sourceRecordId = id,
        sourceRecordVersion = version,
        sourceStore = "apple.healthkit",
        sourceBundleIdentifier = "com.example.fixture",
        sourceName = "Fixture",
        deviceJson = "{}",
        metadataJson = "{}",
        lineage = listOf(SourceLineage("apple.healthkit", recordId = id)),
        tombstone = false,
        rawJson = "{}",
    )
}
