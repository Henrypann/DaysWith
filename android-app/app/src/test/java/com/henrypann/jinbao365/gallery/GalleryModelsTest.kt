package com.henrypann.jinbao365.gallery

import android.Manifest
import android.net.Uri
import com.henrypann.jinbao365.media.ImportOrigin
import com.henrypann.jinbao365.media.MediaSelection
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.Instant
import java.time.ZoneId

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class GalleryModelsTest {
    private fun item(id: Int, taken: Long?, added: Long = 0) = GalleryMedia(Uri.parse("content://media/external/images/media/$id"),
        "$id.jpg", false, taken, added)
    private fun selected(id: Int, origin: ImportOrigin = ImportOrigin.MediaStoreGallery) = MediaSelection(item(id, null).uri, origin)

    @Test fun deniedPermissionHasNoMediaButDoesNotDependOnDeviceLocation() {
        val denied = galleryPermissions(35) { false }
        assertFalse(denied.readable)
        assertFalse(denied.mediaLocation)
        val requested = galleryPermissionRequest(35)
        assertFalse(Manifest.permission.ACCESS_FINE_LOCATION in requested)
        assertFalse(Manifest.permission.ACCESS_COARSE_LOCATION in requested)
    }

    @Test fun partialAuthorizationIsReadableAndCanBeSupplemented() {
        val access = galleryPermissions(35) { it == Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED }
        assertTrue(access.readable)
        assertTrue(access.partial)
        assertFalse(access.full)
        assertTrue(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED in galleryPermissionRequest(35))
    }

    @Test fun photoOnlyAuthorizationAndDeniedGpsStillAllowsBrowsing() {
        val access = galleryPermissions(35) { it == Manifest.permission.READ_MEDIA_IMAGES }
        assertTrue(access.images)
        assertFalse(access.videos)
        assertTrue(access.readable)
        assertFalse(access.mediaLocation)
    }

    @Test fun olderAndroidUsesSharedStoragePermissionAndOptionalExifPermission() {
        val access = galleryPermissions(32) { it == Manifest.permission.READ_EXTERNAL_STORAGE }
        assertTrue(access.full)
        assertFalse(access.mediaLocation)
        assertEquals(listOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.ACCESS_MEDIA_LOCATION), galleryPermissionRequest(32))
        assertFalse(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED in galleryPermissionRequest(33))
    }

    @Test fun currentFullGrantsOverrideTheSelectedMediaFlag() {
        val access = galleryPermissions(35) { true }
        assertTrue(access.full)
        assertFalse(access.partial)
    }

    @Test fun mergeOrdersUnknownCaptureTimesByAddedDateWithoutInventingCaptureFacts() {
        val captured = listOf(item(1, 900), item(2, 500), item(3, 100))
        val added = listOf(item(4, null, 1000), item(5, null, 600), item(6, null, 200))
        val page = mergeGalleryPage(captured, added, GalleryPageKey(), 4)
        assertEquals(listOf(4, 1, 5, 2), page.items.map { it.uri.lastPathSegment!!.toInt() })
        assertEquals(GalleryPageKey(2, 2), page.next)
        assertNull(page.items.first().capturedAtMillis)
        val last = mergeGalleryPage(captured.drop(2), added.drop(2), page.next!!, 4)
        assertEquals(listOf(6, 3), last.items.map { it.uri.lastPathSegment!!.toInt() })
        assertNull(last.next)
    }

    @Test fun fullPageDoesNotPrematurelyTerminateOneStream() {
        val page = mergeGalleryPage(listOf(item(1, 1000), item(2, 900)), emptyList(), GalleryPageKey(), 2)
        assertEquals(GalleryPageKey(2, 0), page.next)
        assertNull(mergeGalleryPage(emptyList(), emptyList(), page.next!!, 2).next)
    }

    @Test fun groupingUsesDisplayZoneOnlyWithoutChangingSourceTimestamp() {
        val original = Instant.parse("2026-10-15T23:30:00Z").toEpochMilli()
        val media = item(1, original)
        assertEquals("2026-10-16", media.date(ZoneId.of("Asia/Shanghai")).toString())
        assertEquals("2026-10-15", media.date(ZoneId.of("UTC")).toString())
        assertEquals(original, media.capturedAtMillis)
    }

    @Test fun multiSelectKeepsSequenceAcrossSourcesAndStopsAtLimit() {
        val existing = listOf(selected(1), selected(2, ImportOrigin.Document))
        val addition = listOf(selected(3, ImportOrigin.PhotoPicker), selected(2), selected(4))
        val result = appendGallerySelection(existing, addition, 3)
        assertEquals(listOf(1, 2, 3), result.selected.map { it.uri.lastPathSegment!!.toInt() })
        assertEquals(ImportOrigin.Document, result.selected[1].origin)
        assertEquals(1, result.overflow)
    }

    @Test fun cancelSelectionRenumbersAndReselectAppends() {
        val initial = listOf(selected(1), selected(2), selected(3))
        val removed = toggleGallerySelection(initial, selected(2), 30).selected
        assertEquals(listOf(selected(1), selected(3)), removed)
        assertEquals(listOf(selected(1), selected(3), selected(2)), toggleGallerySelection(removed, selected(2), 30).selected)
    }

    @Test fun thirtyCombinedItemsAndExistingRecordCapacityAreEnforced() {
        val result = appendGallerySelection(emptyList(), (1..35).map { selected(it) }, 30)
        assertEquals(30, result.selected.size)
        assertEquals(5, result.overflow)
        assertEquals(1, toggleGallerySelection(listOf(selected(1)), selected(2), 1).overflow)
        assertTrue(appendGallerySelection(emptyList(), listOf(selected(1)), 0).selected.isEmpty())
    }
}
