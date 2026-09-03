package com.thatcube.hozz.core

import android.content.Context
import com.thatcube.hozz.projection.ProjectionPlan
import com.thatcube.hozz.projection.ProjectionPlanner
import com.thatcube.hozz.projection.PlannedRecord
import com.thatcube.hozz.projection.ProjectionSummary

data class HozzCoreSnapshot(
    val timeline: List<CanonicalRecord>,
    val projection: ProjectionSummary,
    val totalRecordCount: Int,
)

data class ProjectionDraftPage(
    val operations: List<PlannedRecord>,
    val nextCanonicalId: String?,
)

/**
 * Coarse in-process boundary used by the Android shell.
 *
 * A future Swift/JNI implementation can replace this service behind a
 * length-delimited JSON facade without moving SAF, Compose, or Health Connect
 * APIs into the portable core.
 */
class HozzCoreService(context: Context) {
    private val store = SqliteCanonicalRecordStore(context)
    private val importer = ArchiveImporter(store)
    private val exporter = CanonicalArchiveExporter(store)

    suspend fun import(transport: ArchiveTransport): ArchiveImportResult =
        transport.open().use { input -> importer.import(input) }

    suspend fun snapshot(): HozzCoreSnapshot {
        var after: String? = null
        var projection = ProjectionSummary()
        while (true) {
            val page = store.recordsPage(after, PAGE_SIZE)
            if (page.isEmpty()) {
                break
            }
            val ledger = store.healthConnectProjections(
                page.mapTo(linkedSetOf(), CanonicalRecord::canonicalId),
            )
            projection += ProjectionPlanner.plan(page, ledger).summary()
            after = page.last().canonicalId
        }
        val timeline = store.timelinePage()
        return HozzCoreSnapshot(
            timeline = timeline.records,
            projection = projection,
            totalRecordCount = store.recordCount(),
        )
    }

    suspend fun timelinePage(after: TimelineCursor?): TimelinePage =
        store.timelinePage(after)

    suspend fun projectionDraftPage(
        afterCanonicalId: String?,
    ): ProjectionDraftPage {
        val records = store.recordsPage(afterCanonicalId, PAGE_SIZE)
        val ledger = store.healthConnectProjections(
            records.mapTo(linkedSetOf(), CanonicalRecord::canonicalId),
        )
        return ProjectionDraftPage(
            operations = ProjectionPlanner.plan(records, ledger).records
                .filter { it.draft != null },
            nextCanonicalId = records.lastOrNull()?.canonicalId,
        )
    }

    suspend fun saveHealthConnectProjections(
        projections: List<HealthConnectProjection>,
    ) {
        store.saveHealthConnectProjections(projections)
    }

    suspend fun removeHealthConnectProjections(
        projections: List<HealthConnectProjection>,
    ) {
        store.removeHealthConnectProjections(projections)
    }

    suspend fun export(sink: ArchiveSink): ArchiveExportResult =
        sink.write(exporter::export)

    fun close() {
        store.close()
    }

    private companion object {
        const val PAGE_SIZE = 500
    }
}
