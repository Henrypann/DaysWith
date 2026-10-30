package com.henrypann.jinbao365.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import com.henrypann.jinbao365.JinbaoApplication
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Full-size output is held by the durable task, never by a thumbnail Intent result. */
@Composable
internal fun rememberMomentCamera(
    app: JinbaoApplication,
    enabled: Boolean,
    draftId: String? = null,
    beforePrepare: suspend () -> Unit = {},
    onDraftReady: (String) -> Unit,
    onError: (String) -> Unit,
    onActiveChanged: (Boolean) -> Unit = {},
): () -> Unit {
    val scope = rememberCoroutineScope()
    val currentEnabled by rememberUpdatedState(enabled)
    val currentDraftId by rememberUpdatedState(draftId)
    val currentBeforePrepare by rememberUpdatedState(beforePrepare)
    val currentReady by rememberUpdatedState(onDraftReady)
    val currentError by rememberUpdatedState(onError)
    val currentActive by rememberUpdatedState(onActiveChanged)
    var taskId by rememberSaveable { mutableStateOf<String?>(null) }
    var captureDraftId by rememberSaveable { mutableStateOf<String?>(null) }
    var preparing by remember { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { success ->
        val task = taskId
        val targetDraft = captureDraftId
        // Do not re-check `enabled`: Activity recreation may still be loading its editor.
        if (task != null) scope.launch {
            try {
                withContext(Dispatchers.IO) { app.pendingMedia.finishCamera(task, success) }
                if (success && targetDraft != null) currentReady(targetDraft)
            } catch (_: Exception) { currentError("这张照片还没准备好，请从草稿重试。") }
            finally { taskId = null; captureDraftId = null; currentActive(false) }
        } else currentActive(false)
    }
    return {
        if (currentEnabled && !preparing) {
            preparing = true
            currentActive(true)
            scope.launch {
                try {
                    currentBeforePrepare()
                    val capture = withContext(Dispatchers.IO) {
                        app.pendingMedia.pendingCapture()?.takeIf { currentDraftId == null || it.draftId == currentDraftId }
                            ?: app.pendingMedia.prepareCamera(currentDraftId)
                    }
                    taskId = capture.taskId
                    captureDraftId = capture.draftId
                    try { launcher.launch(capture.outputUri) }
                    catch (_: Exception) {
                        withContext(Dispatchers.IO) { app.pendingMedia.cancel(capture.taskId) }
                        taskId = null; captureDraftId = null; currentActive(false)
                        currentError("这台手机暂时无法打开相机，请从相册选择照片。")
                    }
                } catch (_: Exception) {
                    currentActive(false)
                    currentError("暂时无法准备拍照，请稍后再试。")
                } finally { preparing = false }
            }
        }
    }
}
