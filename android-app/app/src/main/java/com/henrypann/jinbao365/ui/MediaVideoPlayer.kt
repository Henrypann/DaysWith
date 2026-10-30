package com.henrypann.jinbao365.ui

import android.media.AudioAttributes
import android.media.AudioManager
import android.net.Uri
import android.widget.VideoView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.delay

/** Movie playback goes to the media stream, so the ringer or silent mode never mutes it. */
internal val VIDEO_PLAYBACK_AUDIO: AudioAttributes = AudioAttributes.Builder()
    .setUsage(AudioAttributes.USAGE_MEDIA)
    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
    .build()

internal fun VideoView.useMoviePlaybackAudio() {
    setAudioAttributes(VIDEO_PLAYBACK_AUDIO)
    setAudioFocusRequest(AudioManager.AUDIOFOCUS_GAIN)
}

/** Platform decoder/player; only the visible, resumed page is allowed to play. */
@Composable
internal fun MediaVideoPlayer(uri: Uri, active: Boolean, tag: String = "galleryVideo") {
    val context = LocalContext.current
    var view by remember(uri) { mutableStateOf<VideoView?>(null) }
    var attempt by remember(uri) { mutableIntStateOf(0) }
    var ready by remember(uri, attempt) { mutableStateOf(false) }
    var playing by remember(uri, attempt) { mutableStateOf(false) }
    var position by remember(uri, attempt) { mutableFloatStateOf(0f) }
    var duration by remember(uri, attempt) { mutableIntStateOf(0) }
    var failed by remember(uri, attempt) { mutableStateOf(false) }
    var dragging by remember(uri) { mutableStateOf(false) }
    var resumed by remember { mutableStateOf(true) }
    DisposableEffect(context) {
        val owner = context.galleryActivity() as? LifecycleOwner
        resumed = owner?.lifecycle?.currentState?.isAtLeast(Lifecycle.State.RESUMED) != false
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> resumed = true
                Lifecycle.Event.ON_PAUSE, Lifecycle.Event.ON_STOP -> { resumed = false; view?.pause(); playing = false }
                else -> Unit
            }
        }
        owner?.lifecycle?.addObserver(observer)
        onDispose { owner?.lifecycle?.removeObserver(observer); view?.stopPlayback() }
    }
    LaunchedEffect(active, resumed) { if (!active || !resumed) { view?.pause(); playing = false } }
    LaunchedEffect(playing, active, resumed, dragging) {
        while (playing && active && resumed && !dragging) {
            position = (view?.currentPosition ?: 0).coerceAtLeast(0).toFloat()
            delay(200)
        }
    }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            key(uri, attempt) {
                AndroidView(factory = { ctx ->
                    VideoView(ctx).apply {
                        view = this
                        useMoviePlaybackAudio()
                        setOnPreparedListener { player ->
                            duration = player.duration.coerceAtLeast(0)
                            ready = true
                            seekTo(1)
                        }
                        setOnCompletionListener { playing = false; position = duration.toFloat() }
                        setOnErrorListener { _, _, _ -> failed = true; playing = false; true }
                        setVideoURI(uri)
                    }
                }, modifier = Modifier.fillMaxSize().testTag(tag), onRelease = { it.stopPlayback() })
            }
            if (failed) Column(Modifier.background(Color.Black.copy(alpha = .85f)).padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("暂时无法播放这个视频。", color = Color.White)
                TextButton(onClick = { view?.stopPlayback(); attempt++ }) { Text("重试", color = Color.White) }
            } else if (!ready) CircularProgressIndicator(color = Color.White)
        }
        Column(Modifier.fillMaxWidth().background(Color.Black).padding(horizontal = 12.dp)) {
            Slider(value = position.coerceIn(0f, duration.coerceAtLeast(1).toFloat()),
                onValueChange = { dragging = true; position = it },
                onValueChangeFinished = { view?.seekTo(position.toInt()); dragging = false },
                valueRange = 0f..duration.coerceAtLeast(1).toFloat(), enabled = ready && !failed,
                modifier = Modifier.fillMaxWidth().testTag("${tag}Seek"))
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                IconButton(enabled = ready && active && resumed && !failed, onClick = {
                    val player = view ?: return@IconButton
                    if (playing) { player.pause(); playing = false }
                    else { if (position >= duration && duration > 0) { player.seekTo(0); position = 0f }; player.start(); playing = true }
                }, modifier = Modifier.testTag("${tag}Play").semantics { stateDescription = if (playing) "播放中" else "已暂停" }) {
                    Icon(if (playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                        if (playing) "暂停" else "播放", tint = Color.White)
                }
                Text("${galleryDuration(position.toLong())}/${galleryDuration(duration.toLong())}",
                    color = Color.White, style = MaterialTheme.typography.labelSmall, modifier = Modifier.weight(1f))
            }
        }
    }
}
