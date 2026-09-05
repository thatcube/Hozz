package com.thatcube.hozz

import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.thatcube.hozz.core.CanonicalRecord
import com.thatcube.hozz.core.CanonicalValue
import com.thatcube.hozz.core.SourceLineage
import com.thatcube.hozz.core.SqliteCanonicalRecordStore
import com.thatcube.hozz.core.TimelineCursor
import com.thatcube.hozz.core.TimelineItem
import com.thatcube.hozz.core.TimelineItemPage
import com.thatcube.hozz.ui.HozzScreen
import com.thatcube.hozz.ui.HozzTheme
import com.thatcube.hozz.projection.ProjectionPlanner
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HozzTimelinePaginationTest {
    @get:Rule
    val compose = createAndroidComposeRule<HozzTestActivity>()

    private lateinit var pages: List<TimelineItemPage>

    @Before
    fun createBoundedPages() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val database = "timeline-ui-${UUID.randomUUID()}.sqlite"
        val store = SqliteCanonicalRecordStore(context, database)
        try {
            val recent = (0 until 205).map { index ->
                record(
                    id = "small-${index.toString().padStart(3, '0')}",
                    type = "Timeline$index",
                    time = Instant.parse("2026-01-02T00:00:00Z")
                        .minusSeconds(index.toLong()),
                )
        }

            val padding = "x".repeat(300 * 1_024)
            val large = listOf(
                record(
                    id = "large-1",
                    type = "TimelineLargeOne",
                    time = Instant.parse("2026-01-01T03:00:00Z"),
                    padding = padding,
                ),
                record(
                    id = "large-2",
                    type = "TimelineLargeTwo",
                    time = Instant.parse("2026-01-01T02:00:00Z"),
                    padding = padding,
                ),
                record(
                    id = "large-final",
                    type = "TimelineFinal",
                    time = Instant.parse("2026-01-01T01:00:00Z"),
                    padding = padding,
                ),
            )
            (recent + large).chunked(25).forEach { store.upsert(it) }

            val loaded = mutableListOf<com.thatcube.hozz.core.TimelinePage>()
            var cursor: TimelineCursor? = null
            do {
                val page = store.timelinePage(cursor)
                loaded += page
                cursor = page.nextCursor
            } while (page.records.isNotEmpty())
            val nonempty = loaded.filter { it.records.isNotEmpty() }
            assertTrue(
                nonempty.all { page ->
                    page.records.sumOf { it.rawJson.toByteArray().size } <=
                        512 * 1_024
                }
            )
            assertTrue(nonempty.size >= 4)
            pages = loaded.map { page ->
                TimelineItemPage(
                    records = page.records.map { record ->
                        TimelineItem(
                            canonicalId = record.canonicalId,
                            displayType = record.displayType,
                            endTime = record.endTime,
                            projectionQuality =
                                ProjectionPlanner.plan(record).quality,
                        )
                    },
                    nextCursor = page.nextCursor,
                )
            }
        } finally {
            store.close()
            context.deleteDatabase(database)
        }
        }

    @Test
    fun scrollingLoadsPastRecordAndByteBoundsWithoutDuplicates() {
        var nextPage = 1
        var state by mutableStateOf(
            HozzUiState(
                timeline = pages.first().records,
                timelineNextCursor = pages.first().nextCursor,
                totalRecordCount = 208,
            )
        )
                compose.activity.runOnUiThread {
                    compose.activity.setContent {
                        HozzTheme {
                            HozzScreen(
                                state = state,
                                onImport = {},
                                onWriteHealthConnect = {},
                                onExport = {},
                                onLoadMoreTimeline = {
                                    state = state.appending(pages[nextPage])
                                    nextPage += 1
                                },
                            )
                        }
                    }
                }
        compose.waitForIdle()
        compose.waitUntil(10_000) { state.timeline.size == 200 }

        var loaded = 200
        while (loaded < 208) {
            compose.onNodeWithTag("timeline-list")
                .performScrollToIndex(loaded + 6)
            compose.waitUntil(10_000) { state.timeline.size > loaded }
            loaded = state.timeline.size
        }

        assertEquals(208, state.timeline.map(TimelineItem::canonicalId).toSet().size)
        compose.onNodeWithTag("timeline-list").performScrollToIndex(213)
        compose.onNodeWithText("Timeline Final").assertIsDisplayed()
    }

    @Test
    fun runOnlyArchiveRemainsVisibleAndExportable() {
        var exported = false
        compose.activity.runOnUiThread {
            compose.activity.setContent {
                HozzTheme {
                    HozzScreen(
                        state = HozzUiState(runRecordCount = 3),
                        onImport = {},
                        onWriteHealthConnect = {},
                        onExport = { exported = true },
                        onLoadMoreTimeline = {},
                    )
                }
            }
        }

        compose.onNodeWithText(
            "This archive contains 3 run and coverage records and no canonical samples.",
        ).assertIsDisplayed()
        compose.onNodeWithText("Save Hozz archive").performClick()
        compose.runOnIdle { assertTrue(exported) }
    }

    private fun record(
        id: String,
        type: String,
        time: Instant,
        padding: String = "",
    ): CanonicalRecord = CanonicalRecord(
        canonicalId = "test:$id",
        parentCanonicalId = null,
        recordVersion = 1,
        kind = "quantity",
        canonicalType = "test.timeline",
        type = type,
        startTime = time,
        endTime = time,
        canonicalValue = CanonicalValue(1.0, "count"),
        originalValue = CanonicalValue(1.0, "count"),
        categoryValue = null,
        activityType = null,
        quantityCount = null,
        sourceRecordId = id,
        sourceRecordVersion = 1,
        sourceStore = "test",
        sourceBundleIdentifier = null,
        sourceName = "Timeline test",
        deviceJson = null,
        metadataJson = null,
        lineage = listOf(SourceLineage("test", recordId = id)),
        tombstone = false,
        rawJson = """{"padding":"$padding"}""",
    )
}
