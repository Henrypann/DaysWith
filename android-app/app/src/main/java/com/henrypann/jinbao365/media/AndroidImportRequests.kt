package com.henrypann.jinbao365.media

import android.content.ComponentName
import android.content.Context
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia
import androidx.activity.result.contract.ActivityResultContracts.PickMultipleVisualMedia
import androidx.core.content.ContextCompat
import java.io.InputStream

/** AndroidX chooses the document fallback only when a native/backported picker is unavailable. */
fun usesDocumentPicker(context: Context, maxItems: Int? = null): Boolean {
    val request = PickVisualMediaRequest(PickVisualMedia.ImageAndVideo)
    val pickerIntent = if (maxItems == null) PickVisualMedia().createIntent(context, request)
        else PickMultipleVisualMedia(maxItems).createIntent(context, request)
    if (pickerIntent.action == Intent.ACTION_OPEN_DOCUMENT) return true
    return shouldUseDocumentPicker(pickerIntent.action,
        pickerIntent.component ?: pickerIntent.resolveActivity(context.packageManager),
        manufacturer = Build.MANUFACTURER, brand = Build.BRAND)
}

internal fun shouldUseDocumentPicker(
    action: String?,
    resolvedPicker: ComponentName?,
    manufacturer: String = "",
    brand: String = "",
): Boolean = action == Intent.ACTION_OPEN_DOCUMENT

object AndroidImportRequests {
    /** Provider queries and URI resolution belong on the import executor. */
    fun create(context: Context, uri: Uri, fromPhotoPicker: Boolean): ImportRequest =
        create(context, uri, if (fromPhotoPicker) ImportOrigin.PhotoPicker else ImportOrigin.Document)

    fun create(context: Context, uri: Uri, origin: ImportOrigin): ImportRequest {
        val resolver = context.contentResolver
        val permission = ContextCompat.checkSelfPermission(context, MediaPermissions.ACCESS_MEDIA_LOCATION) == PackageManager.PERMISSION_GRANTED
        val original = if (origin == ImportOrigin.Camera || !permission) null else optionalMetadata {
            originalUri(uri, origin == ImportOrigin.PhotoPicker) {
                if (it.authority == DOWNLOADS_DOCUMENTS) downloadsMediaUri(context, it)
                else MediaStore.getMediaUri(context, it)
            }
        }
        return ImportRequest(
            displayName = optionalMetadata { displayName(context, uri) } ?: "照片",
            mimeType = optionalMetadata { resolver.getType(uri) } ?: "application/octet-stream",
            permissionGranted = permission,
            fromPhotoPicker = original != null || origin == ImportOrigin.PhotoPicker,
            openGiven = { resolver.openInputStream(uri) ?: throw java.io.FileNotFoundException("Selected media is unavailable") },
            openOriginal = original?.let { target -> { openOriginal(context, target) } },
            origin = origin,
        )
    }

    internal fun originalUri(uri: Uri, fromPhotoPicker: Boolean, mediaUriOf: (Uri) -> Uri?): Uri? {
        // Picker URIs use the media authority too, but reject requireOriginal on OPPO.
        // Only a real collection row is eligible; never guess a row ID from picker paths.
        if (isDirectMediaStoreUri(uri)) return MediaStore.setRequireOriginal(uri)
        if (uri.authority == MediaStore.AUTHORITY) return null
        if (uri.authority in setOf("com.android.providers.media.documents", DOWNLOADS_DOCUMENTS,
                "com.android.externalstorage.documents")) {
            return mediaUriOf(uri)?.takeIf(::isDirectMediaStoreUri)?.let(MediaStore::setRequireOriginal)
        }
        // An unknown provider has only its selected grant, never inferred original fidelity.
        return null
    }

    internal fun isDirectMediaStoreUri(uri: Uri): Boolean {
        if (uri.scheme != "content" || uri.authority != MediaStore.AUTHORITY) return false
        val path = uri.pathSegments
        return path.size in 3..4 && path.firstOrNull() !in setOf("picker", "picker_get_content", "picker_transcoded") &&
            path.lastOrNull()?.toLongOrNull()?.let { it > 0 } == true &&
            ((path.size == 4 && path[1] in setOf("images", "video") && path[2] == "media") ||
                (path.size == 3 && path[1] == "file"))
    }

    private fun <T> optionalMetadata(block: () -> T): T? = try { block() }
        catch (error: java.util.concurrent.CancellationException) { throw error }
        catch (_: Exception) { null }

    /** Android 12 DownloadsProvider's msf:<id> names that exact MediaStore row. No filename search. */
    internal fun downloadsFileUri(uri: Uri): Uri? {
        if (uri.authority != DOWNLOADS_DOCUMENTS) return null
        val docId = DocumentsContract.getDocumentId(uri)
        if (!docId.startsWith("msf:")) return null
        val idText = docId.removePrefix("msf:")
        if (!idText.all(Char::isDigit)) return null
        val id = idText.toLongOrNull()?.takeIf { it > 0 } ?: return null
        return ContentUris.withAppendedId(MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL), id)
    }

    private fun downloadsMediaUri(context: Context, uri: Uri): Uri {
        val media = downloadsFileUri(uri) ?: throw ImportRejected(DOCUMENT_ORIGINAL_MESSAGE)
        val resolver = context.contentResolver
        // File IDs are provider internals. Validate the Downloads row and selected document before reading.
        val given = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
            ?.use { cursor ->
                if (!cursor.moveToFirst()) return@use null
                val name = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val size = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (name < 0 || size < 0 || cursor.isNull(name) || cursor.isNull(size)) return@use null
                cursor.getString(name) to cursor.getLong(size)
            } ?: throw ImportRejected(DOCUMENT_ORIGINAL_MESSAGE)
        val matches = resolver.query(media,
            arrayOf(MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.IS_DOWNLOAD),
            null, null, null,
        )?.use { cursor ->
            if (!cursor.moveToFirst()) return@use false
            val name = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
            val size = cursor.getColumnIndex(MediaStore.MediaColumns.SIZE)
            val download = cursor.getColumnIndex(MediaStore.MediaColumns.IS_DOWNLOAD)
            name >= 0 && size >= 0 && download >= 0 && !cursor.isNull(name) && !cursor.isNull(size) &&
                cursor.getInt(download) == 1 && cursor.getString(name) == given.first && cursor.getLong(size) == given.second
        } == true
        if (!matches || resolver.getType(uri) != resolver.getType(media)) {
            throw ImportRejected(DOCUMENT_ORIGINAL_MESSAGE)
        }
        return media
    }

    private const val DOWNLOADS_DOCUMENTS = "com.android.providers.downloads.documents"
    private const val DOCUMENT_ORIGINAL_MESSAGE = LocationPolicy.ORIGINAL_MESSAGE

    private fun openOriginal(context: Context, uri: Uri): InputStream {
        return run {
            if (Build.VERSION.SDK_INT < 31) {
                context.contentResolver.openInputStream(uri)
                    ?: throw ImportRejected(LocationPolicy.ORIGINAL_MESSAGE)
            } else {
                // Android 12 may transcode HEVC for consumers. Hash only original bytes.
                val options = Bundle().apply { putBoolean(MediaStore.EXTRA_ACCEPT_ORIGINAL_MEDIA_FORMAT, true) }
                val descriptor = context.contentResolver.openTypedAssetFileDescriptor(uri, "*/*", options)
                    ?: throw ImportRejected(LocationPolicy.ORIGINAL_MESSAGE)
                try {
                    descriptor.createInputStream()
                } catch (error: Exception) {
                    descriptor.close()
                    throw error
                }
            }
        }
    }

    private fun displayName(context: Context, uri: Uri): String {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) return cursor.getString(index) ?: "照片"
                }
            }
        return "照片"
    }
}
