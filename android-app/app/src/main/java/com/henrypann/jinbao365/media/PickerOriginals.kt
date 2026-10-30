package com.henrypann.jinbao365.media

/**
 * Maps a picker URI to an external MediaStore id. Import does not use this.
 * Picked photos are opened with MediaStore.setRequireOriginal.
 */
object PickerOriginals {
    fun mediaStoreUri(picker: String, video: Boolean): String? {
        val id = picker.substringAfterLast('/').substringBefore('?')
        if (id.toLongOrNull() == null) return null
        if (!picker.contains("/media/")) return null
        val collection = if (video) "video" else "images"
        return "content://media/external/$collection/media/$id"
    }
}
