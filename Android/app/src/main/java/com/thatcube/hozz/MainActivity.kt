package com.thatcube.hozz

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.health.connect.client.PermissionController
import com.thatcube.hozz.ui.HozzScreen
import com.thatcube.hozz.ui.HozzTheme

class MainActivity : ComponentActivity() {
    private val viewModel: HozzViewModel by viewModels()

    private val archivePicker = registerForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        uri?.let(viewModel::importArchive)
    }

    private val archiveCreator = registerForActivityResult(
        ActivityResultContracts.CreateDocument("application/zip"),
    ) { uri ->
        uri?.let(viewModel::exportArchive)
    }

    private val healthPermissions = registerForActivityResult(
        PermissionController.createRequestPermissionResultContract(),
    ) { granted ->
        viewModel.finishHealthConnectPermission(granted)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            val state by viewModel.state.collectAsStateWithLifecycle()
            HozzTheme {
                HozzScreen(
                    state = state,
                    onImport = {
                        archivePicker.launch(
                            arrayOf(
                                "application/zip",
                                "application/x-ndjson",
                                "application/json",
                                "application/octet-stream",
                            ),
                        )
                    },
                    onWriteHealthConnect = {
                        viewModel.prepareHealthConnectWrite(healthPermissions::launch)
                    },
                    onExport = {
                        archiveCreator.launch("hozz-canonical-archive.zip")
                    },
                    onLoadMoreTimeline = viewModel::loadMoreTimeline,
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        viewModel.refreshHealthConnectAvailability()
    }
}
