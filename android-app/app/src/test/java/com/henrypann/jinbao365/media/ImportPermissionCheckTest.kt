package com.henrypann.jinbao365.media

import org.junit.Assert.*
import org.junit.Test

class ImportPermissionCheckTest {
    private fun gaps(sdk: Int, vararg granted: String) = ImportPermissionCheck.gaps(sdk) { it in granted }

    @Test fun selectionGrantsNeedNoBatchPermissionRequest() {
        assertTrue(ImportPermissionCheck.allToRequest(34).isEmpty())
        assertTrue(ImportPermissionCheck.allToRequest(30).isEmpty())
    }

    @Test fun reportsEachGapAndOnlyLocationGapsBlock() {
        assertEquals(listOf(PermissionGap.Location, PermissionGap.MediaLocation, PermissionGap.Photos), gaps(34))
        val photosOnly = gaps(34, MediaPermissions.READ_MEDIA_IMAGES, MediaPermissions.READ_MEDIA_VIDEO, MediaPermissions.ACCESS_COARSE_LOCATION)
        assertEquals(listOf(PermissionGap.MediaLocation), photosOnly)
        assertTrue(ImportPermissionCheck.blocking(photosOnly).isEmpty())
        val partial = gaps(34, MediaPermissions.READ_MEDIA_VISUAL_USER_SELECTED, MediaPermissions.ACCESS_MEDIA_LOCATION,
            MediaPermissions.ACCESS_FINE_LOCATION)
        assertEquals(listOf(PermissionGap.PhotosPartial), partial)
        assertTrue(ImportPermissionCheck.blocking(partial).isEmpty())
        assertEquals(emptyList<PermissionGap>(), gaps(30, MediaPermissions.READ_EXTERNAL_STORAGE,
            MediaPermissions.ACCESS_MEDIA_LOCATION, MediaPermissions.ACCESS_COARSE_LOCATION))
        PermissionGap.entries.forEach { assertTrue(ImportPermissionCheck.message(it).isNotBlank()) }
    }

    @Test fun permissionAndOriginalMessagesAreDistinct() {
        assertNotEquals(LocationPolicy.PERMISSION_MESSAGE, LocationPolicy.ORIGINAL_MESSAGE)
        assertTrue("拍摄地点" in LocationPolicy.PERMISSION_MESSAGE)
        assertTrue("去设置开启" in LocationPolicy.PERMISSION_MESSAGE)
        assertFalse(LocationPolicy.ORIGINAL_MESSAGE in LocationPolicy.SETTINGS_FIXABLE)
        assertTrue(LocationPolicy.LOCATION_PERMISSION_MESSAGE in LocationPolicy.SETTINGS_FIXABLE)
    }
}
