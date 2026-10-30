package com.henrypann.jinbao365.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.media.MediaMetadataRetriever
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import com.henrypann.jinbao365.archive.MediaResource
import com.henrypann.jinbao365.ui.theme.DesignTokens
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.max
import kotlin.math.roundToInt

private data class LocalPreview(val bitmap: Bitmap?, val aspect: Float = DEFAULT_MEDIA_ASPECT_RATIO)

/** The shared preview for cards and full-width moment pages. */
@Composable
internal fun LocalMedia(
    resource: MediaResource?,
    mediaRoot: File,
    modifier: Modifier = Modifier,
    clamp: Boolean = true,
    contentDescription: String? = null,
) {
    val targetPixels = (LocalConfiguration.current.screenWidthDp * LocalDensity.current.density)
        .roundToInt().coerceIn(256, 2048)
    val preview by produceState<LocalPreview?>(null, resource, mediaRoot, targetPixels) {
        value = withContext(Dispatchers.IO) { loadLocalPreview(resource, mediaRoot, targetPixels) }
    }
    val rawAspect = preview?.aspect ?: DEFAULT_MEDIA_ASPECT_RATIO
    val aspect = if (clamp) clampAspectRatio(rawAspect) else rawAspect
    Box(modifier.aspectRatio(1f / aspect).background(DesignTokens.Colors.photoPlaceholder)) {
        val bitmap = preview?.bitmap
        if (bitmap != null) {
            Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = contentDescription,
                modifier = Modifier.fillMaxSize().testTag("mediaPreview-${resource?.id}"),
                contentScale = if (clamp) ContentScale.Crop else ContentScale.Fit,
            )
        } else {
            Icon(
                Icons.Outlined.PhotoLibrary,
                contentDescription = contentDescription ?: "暂时无法显示预览",
                modifier = Modifier.align(Alignment.Center).size(DesignTokens.Spacing.l),
                tint = DesignTokens.Colors.inkSecondary,
            )
        }
    }
}

@Composable
internal fun rememberVideoDuration(resource: MediaResource?, mediaRoot: File): String? {
    val duration by produceState<String?>(null, resource, mediaRoot) {
        value = withContext(Dispatchers.IO) {
            resource?.let {
                runCatching {
                    val retriever = MediaMetadataRetriever()
                    try {
                        retriever.setDataSource(localMediaFile(mediaRoot, it.objectKey).absolutePath)
                        retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                            ?.toLongOrNull()?.let(::videoDurationLabel)
                    } finally {
                        retriever.release()
                    }
                }.getOrNull()
            }
        }
    }
    return duration
}

/** All file checks, bounds, EXIF, and sampled decoding stay off the UI thread. */
private fun loadLocalPreview(resource: MediaResource?, root: File, targetPixels: Int): LocalPreview {
    if (resource == null) return LocalPreview(null)
    return runCatching {
        val file = localMediaFile(root, resource.objectKey)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return LocalPreview(null)
        val orientation = runCatching {
            ExifInterface(file.absolutePath).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
        val swap = orientation in 5..8
        val width = if (swap) bounds.outHeight else bounds.outWidth
        val height = if (swap) bounds.outWidth else bounds.outHeight
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / sample > targetPixels * 2) sample *= 2
        val bitmap = BitmapFactory.decodeFile(file.absolutePath, BitmapFactory.Options().apply { inSampleSize = sample })
        LocalPreview(bitmap?.let { orientBitmap(it, orientation) }, height.toFloat() / width)
    }.getOrDefault(LocalPreview(null))
}

private fun localMediaFile(root: File, objectKey: String): File {
    val directory = root.canonicalFile
    val file = File(directory, objectKey).canonicalFile
    require(file.path.startsWith(directory.path + File.separator)) { "Media path is outside the archive." }
    return file
}

private fun orientBitmap(bitmap: Bitmap, orientation: Int): Bitmap {
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
