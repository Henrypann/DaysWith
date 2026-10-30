package com.henrypann.jinbao365.media

/** What is still missing for importing originals with their shooting location. */
enum class PermissionGap { Location, MediaLocation, Photos, PhotosPartial }

object ImportPermissionCheck {
    /** One request covers everything import needs. */
    fun allToRequest(sdk: Int): List<String> = emptyList()

    fun gaps(sdk: Int, granted: (String) -> Boolean): List<PermissionGap> = buildList {
        if (!MediaPermissions.canAccessLocation(granted)) add(PermissionGap.Location)
        if (!granted(MediaPermissions.ACCESS_MEDIA_LOCATION)) add(PermissionGap.MediaLocation)
        if (!MediaPermissions.canReadSelection(sdk, granted)) {
            add(if (sdk >= 34 && granted(MediaPermissions.READ_MEDIA_VISUAL_USER_SELECTED)) PermissionGap.PhotosPartial
                else PermissionGap.Photos)
        }
    }

    /** Import itself goes through the picker's per-item grant; only these two block saving originals. */
    fun blocking(gaps: List<PermissionGap>): List<PermissionGap> =
        emptyList()

    fun message(gap: PermissionGap): String = when (gap) {
        PermissionGap.Location -> "还没允许位置权限：不影响添加照片和视频。"
        PermissionGap.MediaLocation -> "还没允许读取照片的拍摄地点（访问照片位置信息）：仍可添加，拍摄地点可能不可用。" +
            "OPPO、小米等手机把它放在「照片和视频」权限里面，容易漏开。"
        PermissionGap.Photos -> "还没允许读取照片和视频：添加时仍可在选择器里挑选，但部分手机会因此关掉「访问照片位置信息」。"
        PermissionGap.PhotosPartial -> "你只允许了访问部分照片：能添加的只有你允许的那些，想从全部照片里选，请在设置里改成「允许全部」。"
    }
}
