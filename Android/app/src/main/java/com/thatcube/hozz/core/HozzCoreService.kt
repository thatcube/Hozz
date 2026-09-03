package com.thatcube.hozz.core

import android.content.Context
import com.thatcube.hozz.projection.ProjectionPlan
import com.thatcube.hozz.projection.ProjectionPlanner
import com.thatcube.hozz.projection.ProjectionSummary

data class HozzCoreSnapshot(
    val timeline: List<CanonicalRecord>,
    val projection: ProjectionSummary,
    val totalRecordCount: Int,
)

data class ProjectionDraftPage(
    val drafts: List<com.thatcube.hozz.projection.ProjectionDraft>,
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
        do {
            val page = store.recordsPage(after, PAGE_SIZE)
            if (page.isEmpty()) {
                break
            }
            projection += ProjectionPlanner.plan(page).summary()
            after = page.last().canonicalId
        } while (page.size == PAGE_SIZE)
        return HozzCoreSnapshot(
            timeline = store.timeline(),
            projection = projection,
            totalRecordCount = store.recordCount(),
        )
    }

    suspend fun projectionDraftPage(
        afterCanonicalId: String?,
    ): ProjectionDraftPage {
        val records = store.recordsPage(afterCanonicalId, PAGE_SIZE)
        return ProjectionDraftPage(
            drafts = ProjectionPlanner.plan(records).drafts,
            nextCanonicalId = records.lastOrNull()?.canonicalId,
        )
    }

    suspend fun export(sink: ArchiveSink): ArchiveExportResult =
        sink.open().use { output -> exporter.export(output) }

    fun close() {
        store.close()
    }

    private companion object {
        const val PAGE_SIZE = 500
    }
}
