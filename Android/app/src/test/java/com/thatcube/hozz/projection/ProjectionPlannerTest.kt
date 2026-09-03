package com.thatcube.hozz.projection

import com.thatcube.hozz.core.CanonicalRecord
import com.thatcube.hozz.core.CanonicalValue
import com.thatcube.hozz.core.SourceLineage
import java.time.Instant
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

        assertEquals(8, plan.exactCount)
        assertEquals(0, plan.lossyCount)
        assertEquals(0, plan.archiveOnlyCount)
        assertEquals(8, plan.drafts.size)
    }

    @Test
    fun sleepCoreIsLossyAndInBedStaysArchiveOnly() {
        val core = ProjectionPlanner.plan(category("core", 3))
        val inBed = ProjectionPlanner.plan(category("bed", 0))

        assertEquals(ProjectionQuality.LOSSY, core.quality)
        assertEquals("sleep-core-to-light", core.warnings.single().code)
        assertEquals(ProjectionQuality.ARCHIVE_ONLY, inBed.quality)
        assertEquals("sleep-in-bed-overlap", inBed.warnings.single().code)
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

        val planned = ProjectionPlanner.plan(record)

        assertEquals(ProjectionQuality.EXACT, planned.quality)
        val deletion = planned.draft as ProjectionDraft.Delete
        assertEquals(record.canonicalId, deletion.canonicalId)
        assertEquals(record.recordVersion, deletion.recordVersion)
        assertEquals("StepsRecord", deletion.targetRecord)
    }

    @Test
    fun metadataUsesCanonicalIdentityAndMonotonicVersionForEveryRetry() {
        val draft = ProjectionPlanner.plan(
            quantity(
                id = "retry",
                type = "HKQuantityTypeIdentifierStepCount",
                value = 1.0,
                unit = "count",
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
