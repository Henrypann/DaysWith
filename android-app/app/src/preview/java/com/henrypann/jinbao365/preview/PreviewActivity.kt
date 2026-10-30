package com.henrypann.jinbao365.preview

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.henrypann.jinbao365.JinbaoApplication
import com.henrypann.jinbao365.debug.SeedScenes
import com.henrypann.jinbao365.storage.StorageConnectionController
import com.henrypann.jinbao365.storage.StorageConnectionStore
import com.henrypann.jinbao365.storage.StorageVerifier
import com.henrypann.jinbao365.ui.AppShell
import com.henrypann.jinbao365.ui.MainTab
import com.henrypann.jinbao365.ui.ParentIdentityScreen
import com.henrypann.jinbao365.ui.theme.JinbaoTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/** Only packaged in .preview. The OS sandbox, backup exclusions and absent INTERNET are independent guards. */
class PreviewActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as JinbaoApplication
        setContent {
            JinbaoTheme {
                var ready by remember { mutableStateOf(false) }
                var failure by remember { mutableStateOf(false) }
                var parent by remember { mutableStateOf(app.parentIdentity) }
                var tab by rememberSaveable { mutableStateOf(MainTab.Timeline) }
                val connection = remember {
                    StorageConnectionController(StorageConnectionStore(app),
                        StorageVerifier { _, _, _ -> error("UI preview has no cloud connection") })
                }
                DisposableEffect(connection) { onDispose { connection.close() } }
                LaunchedEffect(parent) {
                    if (parent == null) return@LaunchedEffect
                    try {
                        withContext(Dispatchers.IO) {
                            val marker = File(app.filesDir, "ui-preview-initialized")
                            // Never reseed an existing archive, including after an interrupted first launch.
                            if (!marker.exists() && app.archive.loadSnapshot().records.isEmpty() && app.archive.loadDrafts().isEmpty()) {
                                val seed = SeedScenes.seed(app)
                                SeedScenes.mediaRoot(app).copyRecursively(File(app.filesDir, "media"), overwrite = true)
                                app.archive.saveSnapshot(seed)
                            }
                            marker.writeText("1")
                        }
                        app.archiveUi.refresh()
                        ready = true
                    } catch (_: Exception) { failure = true }
                }
                Column(Modifier.fillMaxSize().statusBarsPadding()) {
                    Text("UI 测试版 · 示例数据与新增记录仅存本机", Modifier.padding(8.dp),
                        style = MaterialTheme.typography.bodySmall)
                    when {
                        failure -> Text("测试数据准备失败，请关闭后重试。已有记录不会重置。", Modifier.padding(16.dp))
                        parent == null -> Box(Modifier.weight(1f)) {
                            ParentIdentityScreen { selected ->
                                app.parentIdentityStore.confirm(selected)
                                parent = selected
                            }
                        }
                        ready -> Box(Modifier.weight(1f)) { AppShell(connection, tab, { tab = it }, localPreview = true) }
                        else -> CircularProgressIndicator(Modifier.padding(16.dp))
                    }
                }
            }
        }
    }
}
