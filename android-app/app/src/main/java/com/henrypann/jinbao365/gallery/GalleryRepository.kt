package com.henrypann.jinbao365.gallery

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.LruCache
import android.util.Size
import java.util.concurrent.Executors
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine

/** Bounded working set; cancellation reaches ContentResolver and the thumbnail provider. */
internal class GalleryRepository(context: Context) {
    private val resolver = context.applicationContext.contentResolver
    private val thumbnails = object : LruCache<String, Bitmap>(24 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.allocationByteCount
    }

    suspend fun page(key: GalleryPageKey, permissions: GalleryPermissionState, limit: Int = 120): GalleryPage {
        if (!permissions.readable) return GalleryPage(emptyList(), null)
        val captured = rows(key.capturedOffset, limit, knownTime = true, permissions)
        val added = rows(key.addedOffset, limit, knownTime = false, permissions)
        return mergeGalleryPage(captured, added, key, limit)
    }

    private suspend fun rows(offset: Int, limit: Int, knownTime: Boolean, access: GalleryPermissionState): List<GalleryMedia> =
        galleryIo { signal ->
            val types = buildList {
                if (access.images || access.selectedOnly) add(MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE)
                if (access.videos || access.selectedOnly) add(MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO)
            }
            if (types.isEmpty()) return@galleryIo emptyList()
            val typeFilter = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (${types.joinToString(",")})"
            val timeFilter = if (knownTime) "${MediaStore.Images.ImageColumns.DATE_TAKEN} > 0"
                else "(${MediaStore.Images.ImageColumns.DATE_TAKEN} IS NULL OR ${MediaStore.Images.ImageColumns.DATE_TAKEN} <= 0)"
            val args = Bundle().apply {
                putString(ContentResolver.QUERY_ARG_SQL_SELECTION, "$typeFilter AND $timeFilter AND ${MediaStore.MediaColumns.IS_PENDING} = 0")
                putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER,
                    "${if (knownTime) MediaStore.Images.ImageColumns.DATE_TAKEN else MediaStore.MediaColumns.DATE_ADDED} DESC, ${MediaStore.MediaColumns._ID} DESC")
                putInt(ContentResolver.QUERY_ARG_LIMIT, limit)
                putInt(ContentResolver.QUERY_ARG_OFFSET, offset)
            }
            val projection = arrayOf(MediaStore.MediaColumns._ID, MediaStore.Files.FileColumns.MEDIA_TYPE,
                MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.Images.ImageColumns.DATE_TAKEN,
                MediaStore.MediaColumns.DATE_ADDED, MediaStore.Video.VideoColumns.DURATION)
            val result = ArrayList<GalleryMedia>(limit)
            resolver.query(MediaStore.Files.getContentUri("external"), projection, args, signal)?.use { cursor ->
                val id = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val type = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
                val name = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                val taken = cursor.getColumnIndexOrThrow(MediaStore.Images.ImageColumns.DATE_TAKEN)
                val added = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
                val duration = cursor.getColumnIndex(MediaStore.Video.VideoColumns.DURATION)
                // A provider that ignores QUERY_ARG_LIMIT must not materialize the entire library.
                while (result.size < limit && cursor.moveToNext()) {
                    signal.throwIfCanceled()
                    val video = cursor.getInt(type) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                    val uri = ContentUris.withAppendedId(if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                        else MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cursor.getLong(id))
                    result += GalleryMedia(uri, cursor.getString(name).orEmpty(), video,
                        cursor.getLong(taken).takeIf { it > 0 }, cursor.getLong(added) * 1000,
                        if (duration >= 0) cursor.getLong(duration) else 0)
                }
            }
            result
        }

    suspend fun external(uri: Uri): GalleryMedia = galleryIo { signal ->
        var name = "所选媒体"
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null, signal)?.use { cursor ->
            if (cursor.moveToFirst()) name = cursor.getString(0).orEmpty().ifBlank { name }
        }
        GalleryMedia(uri, name, resolver.getType(uri)?.startsWith("video/") == true, null, 0)
    }

    suspend fun readable(uri: Uri): Boolean = galleryIo { signal ->
        try { resolver.openAssetFileDescriptor(uri, "r", signal)?.use { true } ?: false }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { false }
    }

    fun clearThumbnails() = thumbnails.evictAll()

    suspend fun thumbnail(uri: Uri, pixels: Int): Bitmap {
        val cacheKey = "$uri@$pixels"
        thumbnails.get(cacheKey)?.let { return it }
        return galleryIo { signal ->
            resolver.loadThumbnail(uri, Size(pixels, pixels), signal).also { thumbnails.put(cacheKey, it) }
        }
    }

    /** A display-sized decode, never used as an archive input. */
    suspend fun preview(uri: Uri, maxPixels: Int = 2048): Bitmap = galleryIo { signal ->
        signal.throwIfCanceled()
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, uri)) { decoder, info, _ ->
            val largest = maxOf(info.size.width, info.size.height)
            if (largest > maxPixels) decoder.setTargetSize((info.size.width.toLong() * maxPixels / largest).toInt().coerceAtLeast(1),
                (info.size.height.toLong() * maxPixels / largest).toInt().coerceAtLeast(1))
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }.also { signal.throwIfCanceled() }
    }
}

private val galleryExecutor = Executors.newFixedThreadPool(3) { runnable ->
    Thread(runnable, "gallery-media-io").apply { isDaemon = true }
}

private suspend fun <T> galleryIo(block: (CancellationSignal) -> T): T = suspendCancellableCoroutine { continuation ->
    val signal = CancellationSignal()
    val future = galleryExecutor.submit {
        try {
            val result = block(signal)
            if (continuation.isActive) continuation.resume(result)
        } catch (error: Exception) {
            if (continuation.isActive) continuation.resumeWithException(error)
        }
    }
    continuation.invokeOnCancellation { signal.cancel(); future.cancel(true) }
}
