package com.henrypann.jinbao365.media

/** Runtime permissions for unredacted originals and the required device-location gate. */
object MediaPermissions {
    const val ACCESS_MEDIA_LOCATION = "android.permission.ACCESS_MEDIA_LOCATION"
    const val READ_EXTERNAL_STORAGE = "android.permission.READ_EXTERNAL_STORAGE"
    const val READ_MEDIA_IMAGES = "android.permission.READ_MEDIA_IMAGES"
    const val READ_MEDIA_VIDEO = "android.permission.READ_MEDIA_VIDEO"
    const val READ_MEDIA_VISUAL_USER_SELECTED = "android.permission.READ_MEDIA_VISUAL_USER_SELECTED"
    const val ACCESS_FINE_LOCATION = "android.permission.ACCESS_FINE_LOCATION"
    const val ACCESS_COARSE_LOCATION = "android.permission.ACCESS_COARSE_LOCATION"

    fun toRequest(sdk: Int): List<String> = buildList {
        add(ACCESS_MEDIA_LOCATION)
        if (sdk >= 33) {
            add(READ_MEDIA_IMAGES)
            add(READ_MEDIA_VIDEO)
        } else {
            add(READ_EXTERNAL_STORAGE)
        }
    }

    fun locationToRequest(): List<String> = listOf(ACCESS_COARSE_LOCATION, ACCESS_FINE_LOCATION)

    fun canAccessLocation(granted: (String) -> Boolean): Boolean =
        granted(ACCESS_FINE_LOCATION) || granted(ACCESS_COARSE_LOCATION)

    fun canReadSelection(sdk: Int, granted: (String) -> Boolean): Boolean =
        if (sdk >= 33) granted(READ_MEDIA_IMAGES) && granted(READ_MEDIA_VIDEO)
        else granted(READ_EXTERNAL_STORAGE)

    fun canReadOriginals(sdk: Int, granted: (String) -> Boolean): Boolean =
        granted(ACCESS_MEDIA_LOCATION) && canReadSelection(sdk, granted)
}
