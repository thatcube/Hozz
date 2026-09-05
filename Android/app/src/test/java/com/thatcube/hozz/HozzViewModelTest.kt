package com.thatcube.hozz

import com.thatcube.hozz.core.HozzCoreSnapshot
import com.thatcube.hozz.core.TimelineCursor
import com.thatcube.hozz.core.TimelineItem
import com.thatcube.hozz.core.TimelineItemPage
import com.thatcube.hozz.projection.ProjectionAction
import com.thatcube.hozz.projection.ProjectionExecutionResult
import com.thatcube.hozz.projection.ProjectionFailure
import com.thatcube.hozz.projection.ProjectionQuality
import com.thatcube.hozz.projection.ProjectionSummary
import java.io.IOException
import java.time.Instant
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HozzViewModelTest {
    @Test
    fun failedImportTerminalRefreshReplacesDiscardedStartupSnapshot() = runBlocking {
        assertTerminalRefresh("Import failed")
    }

    @Test
    fun successfulExportTerminalRefreshReplacesDiscardedStartupSnapshot() = runBlocking {
        assertTerminalRefresh("Saved 9 canonical records.")
    }

    @Test
    fun terminalRefreshFailureSettlesBusyAndPreservesCurrentSnapshot() = runBlocking {
        val current = item("current")
        val state = MutableStateFlow(
            HozzUiState(
                timeline = listOf(current),
                totalRecordCount = 1,
            ),
        )
        val refresher = HozzStateRefresher(
            state = state,
            loadSnapshot = { throw IOException("database locked") },
            healthConnectStatus = { 42 },
        )

        refresher.beginOperation("Working")
        refresher.finishOperation("Import failed.")

        assertFalse(state.value.busy)
        assertEquals(listOf(current), state.value.timeline)
        assertEquals(1, state.value.totalRecordCount)
        assertEquals(
            "Import failed. The local archive view could not be refreshed: database locked",
            state.value.status,
        )
        assertEquals(42, state.value.healthConnectStatus)
    }

    @Test
    fun startupRefreshFailureSettlesAsCurrentGenerationError() = runBlocking {
        val state = MutableStateFlow(HozzUiState())
        val refresher = HozzStateRefresher(
            state = state,
            loadSnapshot = { throw IOException("migration failed") },
            healthConnectStatus = { 42 },
        )

        refresher.refresh()

        assertFalse(state.value.busy)
        assertEquals(
            "The local archive view could not be refreshed: migration failed",
            state.value.status,
        )
        assertEquals(42, state.value.healthConnectStatus)
    }

    @Test
    fun staleStartupRefreshFailureCannotReplaceNewerSnapshot() = runBlocking {
        coroutineScope {
            val startupStarted = CompletableDeferred<Unit>()
            val failStartup = CompletableDeferred<Unit>()
            var loads = 0
            val current = HozzCoreSnapshot(
                timeline = listOf(item("current")),
                timelineNextCursor = null,
                projection = ProjectionSummary(),
                totalRecordCount = 1,
            )
            val state = MutableStateFlow(HozzUiState())
            val refresher = HozzStateRefresher(
                state = state,
                loadSnapshot = {
                    loads += 1
                    if (loads == 1) {
                        startupStarted.complete(Unit)
                        failStartup.await()
                        throw IOException("stale failure")
                    }
                    current
                },
                healthConnectStatus = { 42 },
            )
            val stale = async { refresher.refresh() }
            startupStarted.await()

            refresher.refresh(status = "Current")
            failStartup.complete(Unit)
            stale.await()

            assertEquals(listOf(item("current")), state.value.timeline)
            assertEquals(1, state.value.totalRecordCount)
            assertEquals("Current", state.value.status)
        }
    }

    @Test
    fun healthConnectStatusReportsTotalFailureCountBeyondRetainedDetails() {
        val retainedFailures = List(100) { index ->
            ProjectionFailure(
                canonicalId = "test:$index",
                action = ProjectionAction.INSERT,
                message = "failed",
            )
        }
        val result = ProjectionExecutionResult(
            inserted = 1,
            updated = 2,
            deleted = 3,
            failures = retainedFailures,
            failureCount = 1_000,
        )

        assertEquals(
            "Health Connect applied 1 inserts, 2 updates, and 3 deletions. " +
                "1000 records failed and remain pending.",
            healthConnectCompletionStatus(result, permissionDeferred = 0),
        )
    }

    @Test
    fun operationStartInvalidatesInFlightStartupRefresh() {
        val generation = HozzRefreshGeneration()
        val startupRefresh = generation.beginRefresh()
        var state = HozzUiState(
            timelineLoading = true,
            totalRecordCount = 0,
        )
        val staleSnapshot = HozzUiState(
            busy = false,
            totalRecordCount = 7,
            status = "Startup snapshot",
        )

        generation.beginOperation()
        state = state.beginningOperation("Importing")
        assertFalse(generation.isCurrent(startupRefresh))
        if (generation.isCurrent(startupRefresh)) {
            state = staleSnapshot
        }

        assertTrue(state.busy)
        assertFalse(state.timelineLoading)
        assertEquals(0, state.totalRecordCount)
        assertEquals("Importing", state.status)
    }

    @Test
    fun staleTimelineRequestCannotApplyAfterRefreshOrCursorChange() {
        val cursor = TimelineCursor(Instant.EPOCH, "test:200")
        val request = TimelineLoadRequest(generation = 4, cursor = cursor)

        assertTrue(request.isCurrent(4, cursor))
        assertFalse(request.isCurrent(5, cursor))
        assertFalse(
            request.isCurrent(
                4,
                TimelineCursor(Instant.EPOCH, "test:400"),
            )
        )
    }

    @Test
    fun appendingTimelinePageKeepsOnlyLightweightUniqueItems() {
        val first = item("test:first")
        val second = item("test:second")
        val cursor = TimelineCursor(Instant.EPOCH, second.canonicalId)
        val state = HozzUiState(
            timeline = listOf(first),
            timelineNextCursor = TimelineCursor(Instant.EPOCH, first.canonicalId),
            timelineLoading = true,
        )

        val appended = state.appending(
            TimelineItemPage(
                records = listOf(first, second),
                nextCursor = cursor,
            )
        )

        assertEquals(listOf(first, second), appended.timeline)
        assertEquals(cursor, appended.timelineNextCursor)
        assertFalse(appended.timelineLoading)
    }

    @Test
    fun timelineWindowStaysBoundedAndCanReloadEvictedNewerRecords() {
        val initial = (0 until 250).map { item("test:$it") }
        val older = (250 until 500).map { item("test:$it") }
        val state = HozzUiState(
            timeline = initial,
            timelineNextCursor = TimelineCursor(Instant.EPOCH, "test:249"),
        )

        val appended = state.appending(
            TimelineItemPage(
                records = older,
                nextCursor = TimelineCursor(Instant.EPOCH, "test:499"),
            ),
        )

        assertEquals(MAX_RETAINED_TIMELINE_ITEMS, appended.timeline.size)
        assertEquals("test:100", appended.timeline.first().canonicalId)
        assertEquals("test:100", appended.timelinePreviousCursor?.canonicalId)

        val restored = appended.prepending(
            TimelineItemPage(
                records = initial.take(100),
                previousCursor = TimelineCursor(Instant.EPOCH, "test:0"),
                nextCursor = null,
            ),
        )

        assertEquals(MAX_RETAINED_TIMELINE_ITEMS, restored.timeline.size)
        assertEquals("test:0", restored.timeline.first().canonicalId)
        assertEquals("test:399", restored.timeline.last().canonicalId)
        assertEquals("test:399", restored.timelineNextCursor?.canonicalId)
    }

    @Test
    fun runOnlySnapshotStillMarksArchivePresentAfterRefresh() = runBlocking {
        val state = MutableStateFlow(HozzUiState())
        val refresher = HozzStateRefresher(
            state = state,
            loadSnapshot = {
                HozzCoreSnapshot(
                    timeline = emptyList(),
                    timelineNextCursor = null,
                    projection = ProjectionSummary(),
                    totalRecordCount = 0,
                    runRecordCount = 3,
                )
            },
            healthConnectStatus = { 42 },
        )

        refresher.refresh()

        assertTrue(state.value.hasArchive)
        assertEquals(3, state.value.runRecordCount)
        assertEquals(0, state.value.totalRecordCount)
    }

    private fun item(id: String): TimelineItem = TimelineItem(
        canonicalId = id,
        displayType = id,
        endTime = Instant.EPOCH,
        projectionQuality = ProjectionQuality.ARCHIVE_ONLY,
    )

    private suspend fun assertTerminalRefresh(status: String) = coroutineScope {
        val startupStarted = CompletableDeferred<Unit>()
        val finishStartup = CompletableDeferred<Unit>()
        var loadCount = 0
        val staleStartup = HozzCoreSnapshot(
            timeline = listOf(item("stale")),
            timelineNextCursor = null,
            projection = ProjectionSummary(),
            totalRecordCount = 7,
        )
        val terminal = HozzCoreSnapshot(
            timeline = listOf(item("current")),
            timelineNextCursor = null,
            projection = ProjectionSummary(),
            totalRecordCount = 9,
        )
        val state = MutableStateFlow(HozzUiState())
        val refresher = HozzStateRefresher(
            state = state,
            loadSnapshot = {
                loadCount += 1
                if (loadCount == 1) {
                    startupStarted.complete(Unit)
                    finishStartup.await()
                    staleStartup
                } else {
                    terminal
                }
            },
            healthConnectStatus = { 42 },
        )

        val startup = async { refresher.refresh() }
        startupStarted.await()
        refresher.beginOperation("Working")
        assertTrue(state.value.busy)
        assertTrue(state.value.timeline.isEmpty())

        val completion = async { refresher.finishOperation(status) }
        completion.await()

        assertEquals(2, loadCount)
        assertFalse(state.value.busy)
        assertEquals(listOf(item("current")), state.value.timeline)
        assertEquals(9, state.value.totalRecordCount)
        assertEquals(status, state.value.status)
        assertEquals(42, state.value.healthConnectStatus)

        finishStartup.complete(Unit)
        startup.await()
        assertEquals(listOf(item("current")), state.value.timeline)
        assertEquals(9, state.value.totalRecordCount)
        assertEquals(status, state.value.status)
    }
}
