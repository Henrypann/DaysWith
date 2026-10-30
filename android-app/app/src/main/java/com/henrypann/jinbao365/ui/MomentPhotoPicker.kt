package com.henrypann.jinbao365.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable

/** Each selected URI carries its own grant. Location permission is optional metadata. */
@Composable
internal fun rememberMomentPhotoPicker(
    enabled: Boolean,
    onPicked: (List<Uri>, Boolean) -> Unit,
    onError: (String) -> Unit,
    onActiveChanged: (Boolean) -> Unit = {},
): () -> Unit = rememberMediaPicker(enabled, false, onPicked, onError, onActiveChanged)

@Composable
internal fun rememberMomentDocumentPicker(
    enabled: Boolean,
    onPicked: (List<Uri>) -> Unit,
    onError: (String) -> Unit,
    onActiveChanged: (Boolean) -> Unit = {},
): () -> Unit = rememberMediaPicker(enabled, true, { uris, _ -> onPicked(uris) }, onError, onActiveChanged)

@Composable
private fun rememberMediaPicker(
    enabled: Boolean,
    documentOnly: Boolean,
    onPicked: (List<Uri>, Boolean) -> Unit,
    onError: (String) -> Unit,
    onActiveChanged: (Boolean) -> Unit,
): () -> Unit {
    val currentEnabled by rememberUpdatedState(enabled)
    val currentOnPicked by rememberUpdatedState(onPicked)
    val currentOnError by rememberUpdatedState(onError)
    val currentOnActiveChanged by rememberUpdatedState(onActiveChanged)
    var selecting by rememberSaveable { mutableStateOf(false) }
    fun finishSelection() { selecting = false; currentOnActiveChanged(false) }
    fun receive(uris: List<Uri>, fromPhotoPicker: Boolean) {
        finishSelection()
        // A restored result may arrive before the editor has finished loading.
        if (uris.isEmpty()) return
        val selected = uris.distinct()
        if (selected.size > 30) currentOnError("每条记录最多选择 30 张照片或视频。")
        else currentOnPicked(selected, fromPhotoPicker)
    }
    // AndroidX chooses the platform picker, supported system fallback, then documents only when unavailable.
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(30)) { receive(it, true) }
    val document = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { receive(it, false) }
    return {
        if (currentEnabled && !selecting) {
            selecting = true
            currentOnActiveChanged(true)
            try {
                if (documentOnly) document.launch(arrayOf("image/*", "video/*"))
                else picker.launch(PickVisualMediaRequest(PickVisualMedia.ImageAndVideo))
            } catch (_: Exception) {
                finishSelection()
                currentOnError("暂时无法打开选择器，请再试一次。")
            }
        }
    }
}
