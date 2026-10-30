package com.henrypann.jinbao365.ui

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.henrypann.jinbao365.gallery.GalleryMedia
import com.henrypann.jinbao365.gallery.GalleryRepository
import com.henrypann.jinbao365.media.MediaSelection
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.CancellationException

@Composable
internal fun GalleryPreview(
    media: List<GalleryMedia>, initialPage: Int, selected: List<MediaSelection>, repository: GalleryRepository,
    onToggle: (GalleryMedia) -> Unit, onBack: () -> Unit, onPage: (GalleryMedia) -> Unit, onLoadMore: () -> Unit,
) {
    val pager = rememberPagerState(initialPage = initialPage.coerceIn(0, media.lastIndex), pageCount = { media.size })
    var zoomed by remember { mutableStateOf(false) }
    LaunchedEffect(pager.currentPage) { zoomed = false; onPage(media[pager.currentPage]) }
    LaunchedEffect(pager.currentPage, media.size) { if (pager.currentPage >= media.size - 8) onLoadMore() }
    Dialog(onDismissRequest = onBack, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        BackHandler(onBack = onBack)
        Column(Modifier.fillMaxSize().background(Color.Black).systemBarsPadding().testTag("galleryPreview")) {
            val item = media[pager.currentPage]
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack, modifier = Modifier.testTag("galleryPreviewBack")) {
                    Icon(Icons.AutoMirrored.Rounded.ArrowBack, "返回网格", tint = Color.White)
                }
                Text("${pager.currentPage + 1}/${media.size}", color = Color.White, modifier = Modifier.weight(1f))
                GallerySelectionCircle(selected.indexOfFirst { it.uri == item.uri } + 1, { onToggle(item) })
            }
            HorizontalPager(state = pager, key = { media[it].uri.toString() }, userScrollEnabled = !zoomed,
                beyondViewportPageCount = 0, modifier = Modifier.weight(1f).fillMaxWidth()) { index ->
                val shown = media[index]
                if (shown.video) MediaVideoPlayer(shown.uri, active = index == pager.currentPage)
                else GalleryPhoto(shown.uri, repository, active = index == pager.currentPage,
                    onZoomed = { if (index == pager.currentPage) zoomed = it })
            }
            val formatter = remember { DateTimeFormatter.ofPattern("yyyy年M月d日 HH:mm").withZone(ZoneId.systemDefault()) }
            Column(Modifier.fillMaxWidth().padding(12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(item.capturedAtMillis?.let { formatter.format(Instant.ofEpochMilli(it)) } ?: "拍摄时间未知",
                    color = Color.White, style = MaterialTheme.typography.bodySmall)
                if (item.capturedAtMillis == null && item.addedAtMillis > 0) Text(
                    "按加入时间排列 · ${formatter.format(Instant.ofEpochMilli(item.addedAtMillis))}",
                    color = Color.LightGray, style = MaterialTheme.typography.labelSmall)
            }
        }
    }
}

@Composable
private fun GalleryPhoto(uri: Uri, repository: GalleryRepository, active: Boolean, onZoomed: (Boolean) -> Unit) {
    var attempt by remember(uri) { mutableIntStateOf(0) }
    var failed by remember(uri, attempt) { mutableStateOf(false) }
    val bitmap by produceState<android.graphics.Bitmap?>(null, uri, attempt) {
        value = try { repository.preview(uri) }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { failed = true; null }
    }
    var scale by remember(uri) { mutableFloatStateOf(1f) }
    var offset by remember(uri) { mutableStateOf(Offset.Zero) }
    LaunchedEffect(active) { if (!active) { scale = 1f; offset = Offset.Zero; onZoomed(false) } }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        if (bitmap == null) {
            if (failed) Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text("暂时无法预览这张照片。", color = Color.White)
                TextButton(onClick = { attempt++ }) { Text("重试", color = Color.White) }
            } else CircularProgressIndicator(color = Color.White)
        }
        bitmap?.let { image ->
            Image(image.asImageBitmap(), "照片预览", contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize()
                    .pointerInput(uri) {
                        detectTapGestures(onDoubleTap = {
                            scale = if (scale > 1f) 1f else 2.5f
                            offset = Offset.Zero
                            onZoomed(scale > 1f)
                        })
                    }
                    .pointerInput(uri) {
                        awaitEachGesture {
                            awaitFirstDown(requireUnconsumed = false)
                            do {
                                val event = awaitPointerEvent()
                                val pinch = event.changes.count { it.pressed } > 1
                                if (pinch || scale > 1f) {
                                    val pan = event.calculatePan()
                                    scale = (scale * event.calculateZoom()).coerceIn(1f, 5f)
                                    if (scale > 1f) {
                                        val maxX = size.width * (scale - 1f) / 2f
                                        val maxY = size.height * (scale - 1f) / 2f
                                        offset = Offset((offset.x + pan.x).coerceIn(-maxX, maxX), (offset.y + pan.y).coerceIn(-maxY, maxY))
                                    } else offset = Offset.Zero
                                    event.changes.forEach { it.consume() }
                                    onZoomed(scale > 1f)
                                }
                            } while (event.changes.any { it.pressed })
                        }
                    }
                    .graphicsLayer { scaleX = scale; scaleY = scale; translationX = offset.x; translationY = offset.y })
        }
    }
}
