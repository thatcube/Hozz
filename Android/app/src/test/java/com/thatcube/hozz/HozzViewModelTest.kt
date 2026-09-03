package com.thatcube.hozz

import com.thatcube.hozz.core.TimelineCursor
import com.thatcube.hozz.core.TimelineItem
import com.thatcube.hozz.core.TimelineItemPage
import com.thatcube.hozz.projection.ProjectionQuality
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HozzViewModelTest {
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

    private fun item(id: String): TimelineItem = TimelineItem(
        canonicalId = id,
        displayType = id,
        endTime = Instant.EPOCH,
        projectionQuality = ProjectionQuality.ARCHIVE_ONLY,
    )
}
