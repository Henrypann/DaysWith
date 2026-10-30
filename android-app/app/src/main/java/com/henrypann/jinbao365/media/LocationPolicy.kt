package com.henrypann.jinbao365.media

/**
 * Original access is optional. Selected bytes remain importable without location permissions;
 * the actual read path determines provenance independently of GPS metadata.
 */
object LocationPolicy {
    /** Permissions are complete, but the provider did not hand over the original file. */
    const val ORIGINAL_MESSAGE =
        "这张照片暂时无法读取，没有保存。" +
            "请确认照片已下载到本机后重试。"

    /** ACCESS_MEDIA_LOCATION is missing. On OPPO/Xiaomi it hides inside 照片和视频. */
    const val PERMISSION_MESSAGE =
        "还没允许读取照片的拍摄地点，这次没有保存。请点「去设置开启」，在「权限 → 照片和视频」里打开「访问照片位置信息」" +
            "（也可能叫「读取照片位置」），返回后再添加。"

    const val LOCATION_PERMISSION_MESSAGE =
        "还没允许位置权限，这次没有保存。DaysWith 需要它来保留照片里的拍摄地点。请点「去设置开启」，在「权限 → 位置信息」里选择「使用时允许」。"

    /** Messages that are fixed by changing a permission in system settings. */
    val SETTINGS_FIXABLE = setOf(PERMISSION_MESSAGE, LOCATION_PERMISSION_MESSAGE)

    fun select(choice: ImportChoice): ByteSource {
        return if (choice.permissionGranted && choice.fromPhotoPicker && choice.originalOpened)
            ByteSource.MediaStoreOriginal else ByteSource.GivenFile
    }
}

data class ImportChoice(
    val permissionGranted: Boolean,
    val fromPhotoPicker: Boolean,
    val originalOpened: Boolean,
    val locationPermissionGranted: Boolean = true,
)

enum class ByteSource {
    /** Open-document path. The bytes are the file the user named. */
    GivenFile,

    /** Photo picker. The bytes were opened with MediaStore.setRequireOriginal. */
    MediaStoreOriginal,
}

class ImportRejected(message: String) : IllegalStateException(message)
