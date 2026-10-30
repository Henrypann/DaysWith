package com.henrypann.jinbao365.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.henrypann.jinbao365.archive.MediaResource
import com.henrypann.jinbao365.archive.ImportProvenance
import com.henrypann.jinbao365.backup.BackupCancellation
import com.henrypann.jinbao365.ui.theme.DesignTokens
import com.henrypann.jinbao365.viewing.DownloadPlan
import com.henrypann.jinbao365.viewing.OriginalRequest
import com.henrypann.jinbao365.viewing.PartnerOriginalDownloader
import com.henrypann.jinbao365.viewing.PartnerOriginalResult
import com.henrypann.jinbao365.viewing.PhotoPreviewCopy
import com.henrypann.jinbao365.viewing.ViewerEntry
import com.henrypann.jinbao365.viewing.archiveFile
import com.henrypann.jinbao365.viewing.downloadPlan
import com.henrypann.jinbao365.viewing.downloadsOriginal
import com.henrypann.jinbao365.viewing.partnerCacheRelative
import java.io.File
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
internal fun PhotoViewer(
    media: List<MomentMedia>,
    initialPage: Int,
    mediaRoot: File,
    downloader: PartnerOriginalDownloader,
    allowCellular: Boolean,
    onBack: () -> Unit,
) {
    if (media.isEmpty()) return
    BackHandler(onBack = onBack)
    val entries = remember(media) { media.map { it.toViewerEntry() } }
    val pager = rememberPagerState(
        initialPage = initialPage.coerceIn(0, media.lastIndex),
        pageCount = { media.size },
    )
    var confirmed by rememberSaveable { mutableStateOf(false) }
    var ask by remember { mutableStateOf(false) }
    var attempts by remember { mutableIntStateOf(0) }
    val frames = remember { mutableStateMapOf<String, PartnerOriginalResult>() }
    var pagingEnabled by remember { mutableStateOf(true) }
    val plan = downloadPlan(entries, pager.currentPage)
    LaunchedEffect(plan.visibleId, plan.prefetchId, allowCellular, confirmed, attempts) {
        coroutineScope {
            fetchIds(plan).forEach { id ->
                launch {
                    val entry = entries.firstOrNull { it.assetId == id } ?: return@launch
                    val request = entry.request() ?: return@launch
                    val cancellation = BackupCancellation()
                    // Leaving the page disconnects the transfer instead of finishing a large video.
                    val watcher = launch { try { awaitCancellation() } finally { cancellation.cancel() } }
                    val result = try {
                        withContext(Dispatchers.IO) { downloader.fetch(request, allowCellular, confirmed, cancellation) }
                    } catch (_: CancellationException) {
                        return@launch
                    } finally {
                        watcher.cancel()
                    }
                    frames[id] = result
                    if (id == plan.visibleId && result is PartnerOriginalResult.NeedsConfirmation) ask = true
                }
            }
        }
    }
    val page = pager.currentPage
    val current = media[page]
    val currentResult = frames[current.assetId]
    Box(Modifier.fillMaxSize().background(Color.Black).testTag("photoViewer")) {
        HorizontalPager(
            state = pager,
            userScrollEnabled = pagingEnabled,
            beyondViewportPageCount = 1,
            key = { media[it].assetId },
            modifier = Modifier.fillMaxSize(),
        ) { index ->
            val item = media[index]
            val entry = entries[index]
            val result = frames[item.assetId]
            if (item.kind == "video") {
                VideoPage(
                    item = item,
                    mediaRoot = mediaRoot,
                    result = result,
                    active = index == page,
                    onRetry = {
                        frames.remove(item.assetId)
                        attempts++
                    },
                    onAsk = { ask = true },
                )
            } else {
                PhotoPage(
                    item = item,
                    entry = entry,
                    mediaRoot = mediaRoot,
                    downloader = downloader,
                    result = result,
                    showStatus = index == page,
                    onZoomed = { zoomed -> if (index == pager.currentPage) pagingEnabled = !zoomed },
                    onRetry = {
                        frames.remove(item.assetId)
                        attempts++
                    },
                    onAsk = { ask = true },
                )
            }
        }
        Row(
            Modifier.fillMaxWidth().align(Alignment.TopCenter)
                .background(Color.Black.copy(alpha = 0.45f))
                .padding(horizontal = DesignTokens.Spacing.xs).testTag("photoViewerHeader"),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack, modifier = Modifier.testTag("photoViewerClose")) {
                Icon(Icons.AutoMirrored.Rounded.ArrowBack, "关闭", tint = Color.White)
            }
            Column(Modifier.weight(1f).padding(vertical = 6.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    "${page + 1}/${media.size}",
                    color = Color.White,
                    fontSize = DesignTokens.Typography.metaSize,
                    modifier = Modifier.testTag("photoViewerCount"),
                )
                if (current.provenance != ImportProvenance.Unknown) Text(current.provenance.label,
                    color = Color.White.copy(alpha = 0.85f), fontSize = DesignTokens.Typography.captionSize,
                    modifier = Modifier.testTag("photoViewerProvenance"))
            }
            Box(Modifier.size(48.dp))
        }
    }
    if (ask && current.partner != null && currentResult !is PartnerOriginalResult.Ready) {
        AlertDialog(
            onDismissRequest = { ask = false },
            title = { Text(PhotoPreviewCopy.CELLULAR_DIALOG_TITLE) },
            text = {
                Text(if (current.kind == "video") {
                    PhotoPreviewCopy.CELLULAR_DIALOG_VIDEO +
                        (current.original?.byteCount?.let { "\n视频大小 ${localMediaSizeText(it)}" } ?: "")
                } else PhotoPreviewCopy.CELLULAR_DIALOG)
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        frames.keys.toList().forEach { id ->
                            if (frames[id] is PartnerOriginalResult.NeedsConfirmation) frames.remove(id)
                        }
                        confirmed = true
                        ask = false
                    },
                    modifier = Modifier.testTag("photoViewerCellularConfirm"),
                ) { Text(PhotoPreviewCopy.CELLULAR_CONFIRM) }
            },
            dismissButton = {
                TextButton(onClick = { ask = false }, modifier = Modifier.testTag("photoViewerCellularCancel")) {
                    Text(PhotoPreviewCopy.CELLULAR_CANCEL)
                }
            },
        )
    }
}

private fun fetchIds(plan: DownloadPlan): List<String> = listOfNotNull(plan.visibleId, plan.prefetchId).distinct()

@Composable
private fun PhotoPage(
    item: MomentMedia,
    entry: ViewerEntry,
    mediaRoot: File,
    downloader: PartnerOriginalDownloader,
    result: PartnerOriginalResult?,
    showStatus: Boolean,
    onZoomed: (Boolean) -> Unit,
    onRetry: () -> Unit,
    onAsk: () -> Unit,
) {
    val local = item.partner == null
    val originalFile = when {
        local -> entry.localRelative?.let { archiveFile(mediaRoot, it) }?.takeIf { it.isFile }
        result is PartnerOriginalResult.Ready -> result.file
        else -> null
    }
    val thumbnail = entry.thumbnailRelative?.let { archiveFile(mediaRoot, it) }?.takeIf { it.isFile }
    val cachePresent = !local && entry.downloadsOriginal && entry.request()?.let { downloader.cacheFile(it) }?.isFile == true
    val loading = showStatus && entry.downloadsOriginal && originalFile == null && result == null && !cachePresent
    val failed = showStatus && result is PartnerOriginalResult.Failed
    val needsAsk = showStatus && result is PartnerOriginalResult.NeedsConfirmation
    val phase = when {
        local -> "local"
        result is PartnerOriginalResult.Ready -> "original"
        failed -> "failed"
        needsAsk -> "confirm"
        result == null && entry.downloadsOriginal -> "loading"
        else -> "thumbnail"
    }
    val shown = originalFile ?: thumbnail
    Box(Modifier.fillMaxSize().testTag("photoViewerPhase-$phase")) {
        if (thumbnail != null && thumbnail != shown) StillPhoto(thumbnail, "缩略图", Modifier.fillMaxSize())
        shown?.let {
            StillPhoto(it, when {
                local -> "原图"
                originalFile != null -> "对方原图"
                else -> "缩略图"
            }, Modifier.fillMaxSize(), onZoomed)
        }
        if (showStatus && (failed || needsAsk || loading)) {
            Column(
                Modifier.align(Alignment.BottomCenter).padding(bottom = 72.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                if (loading) {
                    Column(
                        Modifier.background(Color.Black.copy(alpha = 0.72f), RoundedCornerShape(DesignTokens.Radius.l))
                            .padding(horizontal = DesignTokens.Spacing.l, vertical = DesignTokens.Spacing.m),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.s),
                    ) {
                        CircularProgressIndicator(
                            color = DesignTokens.Colors.accent,
                            modifier = Modifier.size(36.dp).testTag("photoViewerLoading"),
                        )
                        Text(PhotoPreviewCopy.DOWNLOADING, color = Color.White, fontSize = DesignTokens.Typography.bodySize)
                    }
                }
                if (failed) {
                    Button(
                        onClick = onRetry,
                        modifier = Modifier.testTag("photoViewerRetry"),
                        shape = RoundedCornerShape(DesignTokens.Radius.full),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = DesignTokens.Colors.accent,
                            contentColor = DesignTokens.Colors.ink,
                        ),
                    ) { Text(PhotoPreviewCopy.DOWNLOAD_FAILED) }
                }
                if (needsAsk) {
                    Button(
                        onClick = onAsk,
                        modifier = Modifier.testTag("photoViewerAskCellular"),
                        shape = RoundedCornerShape(DesignTokens.Radius.full),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = DesignTokens.Colors.accent,
                            contentColor = DesignTokens.Colors.ink,
                        ),
                    ) { Text(PhotoPreviewCopy.USE_CELLULAR) }
                }
            }
        }
    }
}

internal enum class VideoPageState { Playable, Missing, Loading, NeedsConfirmation, Failed, Unavailable }

internal fun videoPageState(local: Boolean, localFileExists: Boolean, downloadable: Boolean, result: PartnerOriginalResult?): VideoPageState = when {
    local -> if (localFileExists) VideoPageState.Playable else VideoPageState.Missing
    !downloadable -> VideoPageState.Unavailable
    result is PartnerOriginalResult.Ready -> VideoPageState.Playable
    result is PartnerOriginalResult.NeedsConfirmation -> VideoPageState.NeedsConfirmation
    result is PartnerOriginalResult.Failed -> VideoPageState.Failed
    else -> VideoPageState.Loading
}

@Composable
private fun VideoPage(
    item: MomentMedia,
    mediaRoot: File,
    result: PartnerOriginalResult?,
    active: Boolean,
    onRetry: () -> Unit,
    onAsk: () -> Unit,
) {
    val local = item.partner == null
    val localFile = item.original?.takeIf { local }?.let { archiveFile(mediaRoot, it.objectKey) }?.takeIf { it.isFile }
    val state = videoPageState(local, localFile != null, item.toViewerEntry().downloadsOriginal, result)
    val playable = localFile ?: (result as? PartnerOriginalResult.Ready)?.file
    if (state == VideoPageState.Playable && playable != null) {
        Box(Modifier.fillMaxSize().testTag("photoViewerPhase-videoPlayback")) {
            MediaVideoPlayer(Uri.fromFile(playable), active = active, tag = "recordVideo")
        }
    } else {
        VideoPoster(item, mediaRoot, state, onRetry, onAsk)
    }
}

@Composable
private fun VideoPoster(item: MomentMedia, mediaRoot: File, state: VideoPageState, onRetry: () -> Unit, onAsk: () -> Unit) {
    val cover = item.thumbnail ?: item.image
    val duration = rememberVideoDuration(item.original?.takeIf { item.partner == null && fileExists(mediaRoot, it) }, mediaRoot)
    val size = item.original?.byteCount?.let { "大小 ${localMediaSizeText(it)}" } ?: PhotoPreviewCopy.SIZE_UNKNOWN
    Column(
        Modifier.fillMaxSize().testTag("photoViewerPhase-video"),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
            if (cover != null) StillPhoto(archiveFile(mediaRoot, cover.objectKey), "视频封面", Modifier.fillMaxSize())
        }
        Column(
            Modifier.padding(DesignTokens.Spacing.l).testTag("photoViewerVideoFooter"),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.s),
        ) {
            Text("时长 ${duration ?: PhotoPreviewCopy.DURATION_UNKNOWN}", color = Color.White, fontSize = DesignTokens.Typography.bodySize)
            Text(size, color = Color.White, fontSize = DesignTokens.Typography.bodySize, modifier = Modifier.testTag("photoViewerVideoSize"))
            when (state) {
                VideoPageState.Loading -> Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.s),
                ) {
                    CircularProgressIndicator(color = DesignTokens.Colors.accent,
                        modifier = Modifier.size(24.dp).testTag("photoViewerLoading"))
                    Text(PhotoPreviewCopy.DOWNLOADING_VIDEO, color = Color.White, fontSize = DesignTokens.Typography.bodySize)
                }
                VideoPageState.Failed -> VideoActionButton(PhotoPreviewCopy.DOWNLOAD_FAILED, "photoViewerRetry", onRetry)
                VideoPageState.NeedsConfirmation -> VideoActionButton(PhotoPreviewCopy.USE_CELLULAR_VIDEO, "photoViewerAskCellular", onAsk)
                VideoPageState.Missing, VideoPageState.Unavailable -> Text(
                    if (state == VideoPageState.Missing) PhotoPreviewCopy.VIDEO_MISSING else PhotoPreviewCopy.VIDEO_UNAVAILABLE,
                    color = DesignTokens.Colors.accent,
                    fontSize = DesignTokens.Typography.bodySize,
                    modifier = Modifier.testTag("photoViewerVideoHint"),
                )
                VideoPageState.Playable -> Unit
            }
        }
    }
}

@Composable
private fun VideoActionButton(label: String, tag: String, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        modifier = Modifier.testTag(tag),
        shape = RoundedCornerShape(DesignTokens.Radius.full),
        colors = ButtonDefaults.buttonColors(
            containerColor = DesignTokens.Colors.accent,
            contentColor = DesignTokens.Colors.ink,
        ),
    ) { Text(label) }
}

private fun fileExists(root: File, resource: MediaResource): Boolean =
    archiveFile(root, resource.objectKey)?.isFile == true

@Composable
private fun StillPhoto(file: File?, description: String, modifier: Modifier, onZoomed: ((Boolean) -> Unit)? = null) {
    val target = (LocalConfiguration.current.screenWidthDp * LocalDensity.current.density * 2f)
        .roundToInt().coerceIn(512, 4096)
    val bitmap by produceState<Bitmap?>(null, file, target) {
        value = withContext(Dispatchers.IO) { file?.let { decodeStill(it, target) } }
    }
    val decoded = bitmap
    if (decoded != null) {
        ZoomableImage(decoded, description, modifier, zoomEnabled = onZoomed != null, onZoomed = onZoomed ?: {})
    }
}

@Composable
private fun ZoomableImage(
    bitmap: Bitmap,
    description: String,
    modifier: Modifier,
    zoomEnabled: Boolean,
    onZoomed: (Boolean) -> Unit,
) {
    var scale by remember(bitmap) { mutableFloatStateOf(1f) }
    var offset by remember(bitmap) { mutableStateOf(Offset.Zero) }
    LaunchedEffect(scale) { if (zoomEnabled) onZoomed(scale > 1.01f) }
    Image(
        bitmap = bitmap.asImageBitmap(),
        contentDescription = description,
        contentScale = ContentScale.Fit,
        modifier = modifier.testTag("photoViewerBitmap").pointerInput(zoomEnabled) {
            if (!zoomEnabled) return@pointerInput
            awaitEachGesture {
                awaitFirstDown(requireUnconsumed = false)
                do {
                    val event = awaitPointerEvent()
                    val pressed = event.changes.filter { it.pressed }
                    if (pressed.size >= 2) {
                        val span = (pressed[0].position - pressed[1].position).getDistance().coerceAtLeast(1f)
                        val previous = (pressed[0].previousPosition - pressed[1].previousPosition).getDistance().coerceAtLeast(1f)
                        val zoom = span / previous
                        val next = (scale * zoom).coerceIn(1f, 4f)
                        scale = next
                        if (next <= 1.01f) offset = Offset.Zero
                        pressed.forEach { it.consume() }
                    } else if (pressed.size == 1 && scale > 1.01f) {
                        val change = pressed[0]
                        val pan = change.position - change.previousPosition
                        if (abs(pan.x) + abs(pan.y) > 0f) {
                            offset += pan
                            change.consume()
                        }
                    }
                } while (event.changes.any { it.pressed })
            }
        }.graphicsLayer {
            scaleX = scale
            scaleY = scale
            translationX = offset.x
            translationY = offset.y
            transformOrigin = TransformOrigin.Center
        },
    )
}

private fun decodeStill(file: File, targetPixels: Int): Bitmap? = runCatching {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.absolutePath, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
    val orientation = runCatching {
        ExifInterface(file.absolutePath).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
    }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
    var sample = 1
    while (max(bounds.outWidth, bounds.outHeight) / sample > targetPixels * 2) sample *= 2
    val bitmap = BitmapFactory.decodeFile(file.absolutePath, BitmapFactory.Options().apply { inSampleSize = sample })
        ?: return null
    orientStill(bitmap, orientation)
}.getOrNull()

private fun orientStill(bitmap: Bitmap, orientation: Int): Bitmap {
    val matrix = Matrix()
    when (orientation) {
        2 -> matrix.setScale(-1f, 1f)
        3 -> matrix.setRotate(180f)
        4 -> matrix.setScale(1f, -1f)
        5 -> { matrix.setRotate(90f); matrix.postScale(-1f, 1f) }
        6 -> matrix.setRotate(90f)
        7 -> { matrix.setRotate(-90f); matrix.postScale(-1f, 1f) }
        8 -> matrix.setRotate(-90f)
        else -> return bitmap
    }
    return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true).also {
        if (it !== bitmap) bitmap.recycle()
    }
}

internal fun MomentMedia.toViewerEntry(): ViewerEntry {
    val cache = if (partner != null && original != null) partnerCacheRelative(partner, original.sha256) else original?.objectKey
    return ViewerEntry(
        assetId = assetId,
        kind = kind,
        partner = partner,
        sha256 = original?.sha256,
        byteCount = original?.byteCount,
        thumbnailRelative = thumbnail?.objectKey ?: image?.objectKey,
        localRelative = if (partner == null) original?.objectKey ?: image?.objectKey else cache,
    )
}

internal fun ViewerEntry.request(): OriginalRequest? {
    if (!downloadsOriginal || partner == null || sha256 == null || byteCount == null) return null
    return OriginalRequest(partner, sha256, byteCount)
}
