package com.henrypann.jinbao365.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.henrypann.jinbao365.R
import com.henrypann.jinbao365.startup.StartupArtworkCountdown
import com.henrypann.jinbao365.startup.StartupArtworkHandoff

private val StartupCream = Color(0xFFFDF6E9)

/** Neutral launch screen; private family illustrations are not distributed. */
@Composable
internal fun StartupArtworkScreen(artworkIndex: Int) {
    Box(Modifier.fillMaxSize().background(StartupCream).testTag("startupArtwork-$artworkIndex"),
        contentAlignment = Alignment.Center) {
        BrandWordmark()
    }
}

@Composable
internal fun StartupArtworkEntry(
    artworkIndex: Int,
    onProtectWindow: () -> Unit,
    appContent: @Composable () -> Unit,
) {
    var showingArtwork by remember { mutableStateOf(true) }
    val protect by rememberUpdatedState(onProtectWindow)
    val handoff = remember { StartupArtworkHandoff({ protect() }, { showingArtwork = false }) }
    if (showingArtwork) {
        StartupArtworkScreen(artworkIndex)
        StartupArtworkTimer(handoff::complete)
    } else appContent()
}

@Composable
private fun StartupArtworkTimer(onFinished: () -> Unit) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val countdown = remember { StartupArtworkCountdown() }
    val finish by rememberUpdatedState(onFinished)
    LaunchedEffect(lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            // The first resumed frame starts the clock; background time is never included.
            var previousFrame = withFrameNanos { it }
            while (!countdown.finished) {
                val frame = withFrameNanos { it }
                if (countdown.advance(frame - previousFrame, resumed = true)) finish()
                previousFrame = frame
            }
        }
    }
}
