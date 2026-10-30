package com.henrypann.jinbao365.debug

import android.content.Context
import android.content.res.Configuration
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.ui.AddMomentButton
import com.henrypann.jinbao365.ui.MomentDetailScreen
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.unit.dp
import com.henrypann.jinbao365.ui.ParentIdentityScreen
import com.henrypann.jinbao365.ui.TimelineScreen
import com.henrypann.jinbao365.ui.theme.DesignTokens
import com.henrypann.jinbao365.ui.theme.JinbaoTheme
import java.util.Locale

/** Shell-only debug scenes. No real archive, credentials, coordinator, or COS client is used. */
class SeedActivity : ComponentActivity() {
    override fun attachBaseContext(newBase: Context) {
        val configuration = Configuration(newBase.resources.configuration)
        configuration.setLocale(Locale.SIMPLIFIED_CHINESE)
        super.attachBaseContext(newBase.createConfigurationContext(configuration))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val initialScene = intent.getStringExtra("scene") ?: "timeline"
        setContent {
            JinbaoTheme {
                Surface(color = DesignTokens.Colors.bg, modifier = Modifier.fillMaxSize()) {
                    SeedContent(initialScene)
                }
            }
        }
    }

    @Composable
    private fun SeedContent(initialScene: String) {
        var scene by rememberSaveable { mutableStateOf(initialScene) }
        var snapshot by remember { mutableStateOf<ArchiveSnapshot?>(null) }
        var error by remember { mutableStateOf<String?>(null) }
        var recordId by rememberSaveable { mutableStateOf<String?>(null) }
        LaunchedEffect(Unit) {
            try {
                snapshot = SeedScenes.seed(applicationContext)
            } catch (failure: Exception) {
                Log.e("JinbaoSeed", "Could not generate local scene", failure)
                error = "示例记录没准备好，请重新打开。"
            }
        }
        when {
            scene == "onboarding_who" -> ParentIdentityScreen {
                // This scene deliberately skips photos/location/cloud gates, and never changes
                // the phone's real confirmed identity. Confirmation proceeds to the local scene.
                scene = "timeline"
            }
            scene !in setOf("timeline", "add_menu", "detail_other") -> CenteredText("暂时没有这个示例场景。")
            error != null -> CenteredText(checkNotNull(error))
            snapshot == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
            else -> {
                val data = checkNotNull(snapshot)
                if (scene == "detail_other" && recordId == null) {
                    recordId = data.records.firstOrNull { SeedScenes.parentOf(data, it.id) == com.henrypann.jinbao365.data.ParentIdentity.Mom }?.id
                }
                val selected = recordId
                if (selected != null) MomentDetailScreen(
                    snapshot = data, recordId = selected, mediaRoot = SeedScenes.mediaRoot(this), readOnly = true,
                    onBack = { recordId = null }, onEdit = {}, onTrash = {}, onRestore = {},
                    parent = SeedScenes.parentOf(data, selected),
                ) else Box(Modifier.fillMaxSize().systemBarsPadding()) {
                    TimelineScreen(
                        snapshot = data, readOnly = true, mediaRoot = SeedScenes.mediaRoot(this@SeedActivity),
                        onOpenMoment = { recordId = it }, onAddPhotos = {},
                        onOpenSettings = { scene = "onboarding_who" },
                        parentOf = { SeedScenes.parentOf(data, it) },
                    )
                    AddMomentButton(true, {}, {}, {}, Modifier.align(Alignment.BottomCenter).padding(bottom = 12.dp),
                        initiallyExpanded = scene == "add_menu")
                }
            }
        }
    }

    @Composable
    private fun CenteredText(message: String) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text(message) }
    }
}
