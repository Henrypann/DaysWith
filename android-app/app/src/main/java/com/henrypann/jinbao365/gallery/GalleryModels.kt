package com.henrypann.jinbao365.gallery

import android.Manifest
import android.net.Uri
import com.henrypann.jinbao365.media.MediaSelection
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

internal data class GalleryMedia(
    val uri: Uri,
    val name: String,
    val video: Boolean,
    val capturedAtMillis: Long?,
    val addedAtMillis: Long,
    val durationMillis: Long = 0,
) {
    val sortTimeMillis: Long get() = capturedAtMillis ?: addedAtMillis
    fun date(zone: ZoneId): LocalDate = Instant.ofEpochMilli(sortTimeMillis).atZone(zone).toLocalDate()
}

internal data class GalleryPageKey(val capturedOffset: Int = 0, val addedOffset: Int = 0)
internal data class GalleryPage(val items: List<GalleryMedia>, val next: GalleryPageKey?, val queriedRows: Int = 0)

/** Two independently ordered streams avoid SQL expressions unsupported by some MediaProviders. */
internal fun mergeGalleryPage(
    captured: List<GalleryMedia>,
    added: List<GalleryMedia>,
    key: GalleryPageKey,
    limit: Int,
): GalleryPage {
    require(limit > 0)
    val result = ArrayList<GalleryMedia>(limit)
    var a = 0
    var b = 0
    while (result.size < limit && (a < captured.size || b < added.size)) {
        val useCaptured = when {
            a >= captured.size -> false
            b >= added.size -> true
            else -> captured[a].sortTimeMillis >= added[b].sortTimeMillis
        }
        result += if (useCaptured) captured[a++] else added[b++]
    }
    val exhausted = a == captured.size && b == added.size && captured.size < limit && added.size < limit
    return GalleryPage(result, if (exhausted) null else GalleryPageKey(key.capturedOffset + a, key.addedOffset + b),
        captured.size + added.size)
}

internal data class GallerySelectionUpdate(val selected: List<MediaSelection>, val overflow: Int)

/** URI identity deduplicates system and document callbacks while preserving the first chosen source. */
internal fun appendGallerySelection(
    selected: List<MediaSelection>, additions: List<MediaSelection>, limit: Int,
): GallerySelectionUpdate {
    val unique = additions.distinctBy { it.uri.toString() }.filter { addition -> selected.none { it.uri == addition.uri } }
    val room = (limit - selected.size).coerceAtLeast(0)
    return GallerySelectionUpdate(selected + unique.take(room), (unique.size - room).coerceAtLeast(0))
}

internal fun toggleGallerySelection(selected: List<MediaSelection>, item: MediaSelection, limit: Int): GallerySelectionUpdate =
    if (selected.any { it.uri == item.uri }) GallerySelectionUpdate(selected.filterNot { it.uri == item.uri }, 0)
    else appendGallerySelection(selected, listOf(item), limit)

internal data class GalleryPermissionState(
    val images: Boolean,
    val videos: Boolean,
    val selectedOnly: Boolean,
    val mediaLocation: Boolean,
) {
    val readable get() = images || videos || selectedOnly
    val partial get() = selectedOnly && !(images && videos)
    val full get() = images && videos
}

internal fun galleryPermissions(sdk: Int, granted: (String) -> Boolean): GalleryPermissionState {
    val legacy = sdk <= 32 && granted(Manifest.permission.READ_EXTERNAL_STORAGE)
    return GalleryPermissionState(
        images = legacy || sdk >= 33 && granted(Manifest.permission.READ_MEDIA_IMAGES),
        videos = legacy || sdk >= 33 && granted(Manifest.permission.READ_MEDIA_VIDEO),
        selectedOnly = sdk >= 34 && granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED),
        mediaLocation = granted(Manifest.permission.ACCESS_MEDIA_LOCATION),
    )
}

internal fun galleryPermissionRequest(sdk: Int): List<String> = buildList {
    if (sdk >= 33) {
        add(Manifest.permission.READ_MEDIA_IMAGES)
        add(Manifest.permission.READ_MEDIA_VIDEO)
        if (sdk >= 34) add(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
    } else add(Manifest.permission.READ_EXTERNAL_STORAGE)
    add(Manifest.permission.ACCESS_MEDIA_LOCATION)
}
