package com.henrypann.jinbao365.media

/** EXIF orientation values. Matches androidx.exifinterface.media.ExifInterface without linking Android. */
object ExifOrientation {
    const val NORMAL = 1
    const val FLIP_HORIZONTAL = 2
    const val ROTATE_180 = 3
    const val FLIP_VERTICAL = 4
    const val TRANSPOSE = 5
    const val ROTATE_90 = 6
    const val TRANSVERSE = 7
    const val ROTATE_270 = 8

    data class Transform(val degrees: Int, val flipHorizontal: Boolean)

    fun transform(orientation: Int): Transform = when (orientation) {
        FLIP_HORIZONTAL -> Transform(0, true)
        ROTATE_180 -> Transform(180, false)
        FLIP_VERTICAL -> Transform(180, true)
        TRANSPOSE -> Transform(90, true)
        ROTATE_90 -> Transform(90, false)
        TRANSVERSE -> Transform(270, true)
        ROTATE_270 -> Transform(270, false)
        else -> Transform(0, false)
    }
}
