package com.thatcube.hozz.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.health.connect.client.HealthConnectClient
import com.thatcube.hozz.HozzUiState
import com.thatcube.hozz.core.TimelineItem
import com.thatcube.hozz.projection.ProjectionQuality
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@Composable
fun HozzScreen(
    state: HozzUiState,
    onImport: () -> Unit,
    onWriteHealthConnect: () -> Unit,
    onExport: () -> Unit,
    onLoadMoreTimeline: () -> Unit,
) {
    val listState = rememberLazyListState()
    val nearTimelineEnd by remember {
        derivedStateOf {
            val layout = listState.layoutInfo
            val last = layout.visibleItemsInfo.lastOrNull()?.index ?: return@derivedStateOf false
            val hasScrolled = listState.firstVisibleItemIndex > 0 ||
                listState.firstVisibleItemScrollOffset > 0
            hasScrolled && last >= layout.totalItemsCount - 3
        }
    }
    LaunchedEffect(
        nearTimelineEnd,
        state.timelineNextCursor,
        state.timelineLoading,
    ) {
        if (
            nearTimelineEnd &&
            state.timelineNextCursor != null &&
            !state.timelineLoading &&
            !state.busy
        ) {
            onLoadMoreTimeline()
        }
    }
    Surface(modifier = Modifier.fillMaxSize()) {
        LazyColumn(
            state = listState,
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .padding(horizontal = 20.dp)
                .testTag("timeline-list"),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item {
                Spacer(Modifier.height(18.dp))
                Text(
                    text = "Your health archive",
                    style = MaterialTheme.typography.headlineLarge,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    text = "Receive a lossless archive, understand what can move, and choose each destination.",
                    modifier = Modifier.padding(top = 6.dp),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodyLarge,
                )
            }
            item {
                ArchiveRoute()
            }
            item {
                OutlinedButton(
                    onClick = onImport,
                    enabled = !state.busy,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(if (state.busy) "Working…" else "Open Hozz archive")
                }
            }
            state.status?.let { status ->
                item {
                    Text(
                        text = status,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
            if (state.totalRecordCount == 0) {
                item {
                    EmptyArchive()
                }
            } else {
                item {
                    ProjectionPreview(
                        state = state,
                        onWriteHealthConnect = onWriteHealthConnect,
                    )
                }
                item {
                    ExportCard(
                        enabled = !state.busy,
                        onExport = onExport,
                    )
                }
                item {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 8.dp),
                        verticalAlignment = Alignment.Bottom,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Text(
                            text = "Timeline",
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            text = "${state.timeline.size} records shown",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.testTag("timeline-count"),
                        )
                    }
                }
                if (state.timeline.isEmpty()) {
                    item {
                        Text(
                            text = "This archive contains tombstones but no live records.",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                } else {
                    items(
                        items = state.timeline,
                        key = TimelineItem::canonicalId,
                    ) { record ->
                        TimelineRow(record)
                    }
                    if (state.timelineNextCursor != null) {
                        item {
                            TextButton(
                                onClick = onLoadMoreTimeline,
                                enabled = !state.timelineLoading && !state.busy,
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Text(
                                    if (state.timelineLoading) {
                                        "Loading more records…"
                                    } else {
                                        "Load more records"
                                    }
                                )
                            }
                        }
                    }
                }
            }
            item {
                Spacer(Modifier.height(24.dp))
            }
        }
    }
}

@Composable
private fun ExportCard(enabled: Boolean, onExport: () -> Unit) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant,
        ),
        shape = RoundedCornerShape(20.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(18.dp)) {
            Text(
                text = "Move it onward",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "Save the complete canonical archive, including records Health Connect cannot represent.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(vertical = 8.dp),
            )
            OutlinedButton(
                onClick = onExport,
                enabled = enabled,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Save Hozz archive")
            }
        }
    }
}

@Composable
private fun ArchiveRoute() {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.primaryContainer,
        ),
        shape = RoundedCornerShape(24.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 18.dp, vertical = 20.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            RouteStop("Receive")
            Text("→", color = MaterialTheme.colorScheme.secondary)
            RouteStop("Understand", highlighted = true)
            Text("→", color = MaterialTheme.colorScheme.secondary)
            RouteStop("Move onward")
        }
    }
}

@Composable
private fun RowScope.RouteStop(label: String, highlighted: Boolean = false) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.weight(1f),
    ) {
        Box(
            modifier = Modifier
                .size(if (highlighted) 16.dp else 10.dp)
                .background(
                    if (highlighted) {
                        MaterialTheme.colorScheme.primary
                    } else {
                        MaterialTheme.colorScheme.outline
                    },
                    CircleShape,
                ),
        )
        Text(
            text = label,
            modifier = Modifier.padding(top = 8.dp),
            style = MaterialTheme.typography.labelMedium,
            fontWeight = if (highlighted) FontWeight.Bold else FontWeight.Medium,
        )
    }
}

@Composable
private fun EmptyArchive() {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant,
        ),
        shape = RoundedCornerShape(20.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(20.dp)) {
            Text(
                text = "No archive on this device",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = "Choose an NDJSON or ZIP export created by Hozz. Importing the same archive again updates the same records instead of duplicating them.",
                modifier = Modifier.padding(top = 6.dp),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun ProjectionPreview(
    state: HozzUiState,
    onWriteHealthConnect: () -> Unit,
) {
    val plan = state.projection
    var confirmsDeletion by remember { mutableStateOf(false) }
    if (confirmsDeletion) {
        AlertDialog(
            onDismissRequest = { confirmsDeletion = false },
            title = { Text("Delete projected records?") },
            text = {
                Text(
                    "This removes ${plan.deleteCount} records previously written " +
                        "by Hozz from Health Connect. Their canonical records " +
                        "remain in your Hozz archive.",
                )
            },
            confirmButton = {
                Button(
                    onClick = {
                        confirmsDeletion = false
                        onWriteHealthConnect()
                    },
                ) {
                    Text("Apply deletions")
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmsDeletion = false }) {
                    Text("Cancel")
                }
            },
        )
    }
    Card(
        shape = RoundedCornerShape(20.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(18.dp)) {
            Text(
                text = "Health Connect preview",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 14.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Count("Insert", plan.insertCount)
                Count("Update", plan.updateCount)
                Count("Delete", plan.deleteCount)
            }
            HorizontalDivider()
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Count("Exact", plan.exactCount)
                Count("Lossy", plan.lossyCount)
                Count("Archive only", plan.archiveOnlyCount)
            }
            if (plan.warningDetails.isNotEmpty()) {
                HorizontalDivider()
                Text(
                    text = "Mapping warnings",
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(top = 12.dp),
                )
                for (warning in plan.warningDetails) {
                    Text(
                        text = "${warning.count} × ${warning.message}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 6.dp),
                    )
                }
            }
            Text(
                text = "Hozz remains the complete copy. Health Connect receives only the mapped records you approve.",
                modifier = Modifier.padding(vertical = 12.dp),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
            )
            Button(
                onClick = {
                    if (plan.deleteCount > 0) {
                        confirmsDeletion = true
                    } else {
                        onWriteHealthConnect()
                    }
                },
                enabled = !state.busy &&
                    plan.pendingCount > 0 &&
                    state.healthConnectStatus == HealthConnectClient.SDK_AVAILABLE,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Write mapped records to Health Connect")
            }
            if (state.healthConnectStatus != HealthConnectClient.SDK_AVAILABLE) {
                Text(
                    text = "Health Connect is not available on this device. The imported archive remains usable in Hozz.",
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        }
    }
}

@Composable
private fun Count(label: String, value: Int) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = value.toString(),
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
        )
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun TimelineRow(record: TimelineItem) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface,
        ),
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(10.dp)
                    .background(
                        when (record.projectionQuality) {
                            ProjectionQuality.EXACT ->
                                MaterialTheme.colorScheme.secondary
                            ProjectionQuality.LOSSY ->
                                MaterialTheme.colorScheme.error
                            ProjectionQuality.ARCHIVE_ONLY ->
                                MaterialTheme.colorScheme.onSurfaceVariant
                            ProjectionQuality.DELETE ->
                                MaterialTheme.colorScheme.error
                        },
                        CircleShape,
                    ),
            )
            Column(
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 12.dp),
            ) {
                Text(
                    text = record.displayType,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    text = record.endTime?.let {
                        DateTimeFormatter.ofPattern("MMM d, yyyy · h:mm a")
                            .withZone(ZoneId.systemDefault())
                            .format(it)
                    } ?: "No measurement time",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            ProjectionBadge(record.projectionQuality)
        }
    }
}

@Composable
private fun ProjectionBadge(quality: ProjectionQuality) {
    val label = when (quality) {
        ProjectionQuality.EXACT -> "Mapped"
        ProjectionQuality.LOSSY -> "Lossy"
        ProjectionQuality.ARCHIVE_ONLY -> "Archive only"
        ProjectionQuality.DELETE -> "Delete"
    }
    val color: Color = when (quality) {
        ProjectionQuality.EXACT -> MaterialTheme.colorScheme.secondary
        ProjectionQuality.LOSSY -> MaterialTheme.colorScheme.error
        ProjectionQuality.ARCHIVE_ONLY -> MaterialTheme.colorScheme.onSurfaceVariant
        ProjectionQuality.DELETE -> MaterialTheme.colorScheme.error
    }
    Text(
        text = label,
        color = color,
        style = MaterialTheme.typography.labelSmall,
        fontWeight = FontWeight.Bold,
    )
}
