package com.henrypann.jinbao365.media

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import com.henrypann.jinbao365.data.ArchiveRepository
import com.henrypann.jinbao365.data.PendingMediaTaskEntity
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.*
import java.io.File
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor

enum class PendingMediaStatus { AwaitingCapture, Queued, Importing, Ready, Failed, Cancelled }

data class PendingMediaTask(
    val id: String,
    val draftId: String,
    val origin: ImportOrigin,
    val status: PendingMediaStatus,
    val completedItems: Int,
    val totalItems: Int,
    val errorMessage: String?,
    val items: List<PendingMediaItem> = emptyList(),
)

enum class PendingMediaItemStatus { Queued, Importing, Success, Degraded, Failed, Cancelled }

data class PendingMediaItem(
    val id: String,
    val index: Int,
    val origin: ImportOrigin,
    val status: PendingMediaItemStatus,
    val assetId: String?,
    val errorMessage: String?,
    val provenance: com.henrypann.jinbao365.archive.ImportProvenance?,
)

data class PendingCapture(val taskId: String, val draftId: String, val outputUri: Uri)

/** Process-owned work. All public commands are blocking IO and must be called off main. */
class PendingMediaCoordinator(
    context: Context,
    private val repository: ArchiveRepository,
    private val deviceId: String,
    private val imports: MediaImportService,
    private val executor: Executor = ImportScheduler.executor,
    private val requestFactory: (Uri, ImportOrigin) -> ImportRequest = { uri, origin ->
        AndroidImportRequests.create(context.applicationContext, uri, origin)
    },
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    private val context = context.applicationContext
    private val running = ConcurrentHashMap.newKeySet<String>()
    private val cancelled = ConcurrentHashMap.newKeySet<String>()
    private val mutableRevision = MutableStateFlow(0L)
    val revision: StateFlow<Long> = mutableRevision.asStateFlow()
    private fun changed() = synchronized(mutableRevision) { mutableRevision.value += 1L }

    fun prepareCamera(draftId: String? = null): PendingCapture {
        val id = UUID.randomUUID().toString()
        val file = captureFile(id)
        check(file.parentFile!!.mkdirs() || file.parentFile!!.isDirectory) { "暂时无法准备拍照文件，请检查存储空间。" }
        check(file.createNewFile()) { "暂时无法准备拍照文件，请重试。" }
        try {
            val uri = captureUri(id)
            val task = newTask(id, draftId, ImportOrigin.Camera, PendingMediaStatus.AwaitingCapture, listOf(MediaSelection(uri, ImportOrigin.Camera)))
            repository.createPendingMediaTask(task, deviceId, nowMillis())
            changed()
            return PendingCapture(id, task.draftId, uri)
        } catch (error: Exception) {
            file.delete()
            file.parentFile?.delete()
            throw error
        }
    }

    /** Returns the same URI after activity/process recreation; never consumes a camera's in-flight file. */
    fun pendingCapture(): PendingCapture? = repository.pendingMediaTasks().firstOrNull {
        it.origin == ImportOrigin.Camera.name && it.status == PendingMediaStatus.AwaitingCapture.name
    }?.let { PendingCapture(it.id, it.draftId, captureUri(it.id)) }

    fun enqueueSelection(uris: List<Uri>, origin: ImportOrigin, draftId: String? = null): PendingMediaTask =
        enqueueSelections(uris.map { MediaSelection(it, origin) }, draftId)

    fun enqueueSelections(selections: List<MediaSelection>, draftId: String? = null): PendingMediaTask {
        require(selections.none { it.origin == ImportOrigin.Camera }) { "Use prepareCamera for camera capture." }
        requireSelectionSize(selections.size)
        selections.forEach { selection ->
            if (selection.origin != ImportOrigin.MediaStoreGallery) {
                try { context.contentResolver.takePersistableUriPermission(selection.uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                catch (_: SecurityException) { }
                catch (_: UnsupportedOperationException) { }
                catch (_: IllegalArgumentException) { }
            }
        }
        val task = newTask(UUID.randomUUID().toString(), draftId, selections.first().origin,
            PendingMediaStatus.Queued, selections)
        repository.createPendingMediaTask(task, deviceId, nowMillis())
        changed()
        schedule(task.id)
        return model(task)
    }

    fun finishCamera(taskId: String, success: Boolean) {
        val before = repository.pendingMediaTask(taskId) ?: return
        if (before.origin != ImportOrigin.Camera.name || before.status != PendingMediaStatus.AwaitingCapture.name) return
        if (!success) { cancel(taskId); return }
        repository.transitionPendingMediaTask(taskId, setOf(PendingMediaStatus.AwaitingCapture.name), PendingMediaStatus.Queued.name)
            ?: return
        changed()
        schedule(taskId)
    }

    fun tasksForDraft(draftId: String): List<PendingMediaTask> = repository.pendingMediaTasksForDraft(draftId).map(::model)

    fun retry(taskId: String) = retryItems(taskId, null)

    fun retryItem(taskId: String, itemId: String) = retryItems(taskId, itemId)

    private fun retryItems(taskId: String, itemId: String?) {
        val task = repository.retryPendingMediaItems(taskId, itemId) ?: return
        cancelled.remove(task.id)
        changed()
        schedule(task.id)
    }

    /** Removes only an unreadable selection; media already attached stays in the draft. */
    fun removeItem(taskId: String, itemId: String) {
        val task = repository.removePendingMediaItem(taskId, itemId) ?: return
        if (task.status == PendingMediaStatus.Ready.name) cleanupCapture(task)
        changed()
    }

    fun cancel(taskId: String) {
        cancelled.add(taskId)
        val task = repository.cancelPendingMediaTask(taskId) ?: return
        if (task.status == PendingMediaStatus.Cancelled.name && taskId !in running) cleanupCapture(task)
        changed()
    }

    /** Only call once at process initialization, before exposing new tasks. */
    fun resumeInterrupted() {
        repository.pendingMediaTasks().forEach { task ->
            when (task.status) {
                PendingMediaStatus.Importing.name -> {
                    repository.recoverPendingMediaItems(task.id)
                    repository.transitionPendingMediaTask(task.id, setOf(task.status), PendingMediaStatus.Queued.name)
                    schedule(task.id)
                }
                PendingMediaStatus.Queued.name -> { repository.recoverPendingMediaItems(task.id); schedule(task.id) }
                PendingMediaStatus.Ready.name, PendingMediaStatus.Cancelled.name -> cleanupCapture(task)
            }
        }
        changed()
    }

    private fun schedule(id: String) {
        if (!running.add(id)) return
        executor.execute {
            try {
                val task = repository.transitionPendingMediaTask(id, setOf(PendingMediaStatus.Queued.name), PendingMediaStatus.Importing.name)
                    ?: return@execute
                changed()
                repository.pendingMediaItems(id).forEach { candidate ->
                    checkImportCancellation { id in cancelled || repository.pendingMediaTask(id)?.status == PendingMediaStatus.Cancelled.name }
                    val item = repository.startPendingMediaItem(id, candidate.id) ?: return@forEach
                    changed()
                    try {
                        val request = requestFactory(Uri.parse(item.uri), ImportOrigin.valueOf(item.origin))
                        imports.importPendingItem(id, item.id, request,
                            isCancelled = { id in cancelled || repository.pendingMediaTask(id)?.status == PendingMediaStatus.Cancelled.name })
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Exception) {
                        repository.failPendingMediaItem(id, item.id, importErrorMessage(error))
                    }
                    changed()
                }
                repository.finishPendingMediaTask(id)
            } catch (_: CancellationException) {
                repository.cancelPendingMediaTask(id)
            } catch (error: Exception) {
                repository.transitionPendingMediaTask(id, setOf(PendingMediaStatus.Importing.name), PendingMediaStatus.Failed.name,
                    error = importErrorMessage(error))
            } finally {
                running.remove(id)
                repository.pendingMediaTask(id)?.let { task ->
                    if (task.status in setOf(PendingMediaStatus.Ready.name, PendingMediaStatus.Cancelled.name)) cleanupCapture(task)
                    // A retry may race with the previous worker's finally after Failed was published.
                    if (task.status == PendingMediaStatus.Queued.name) schedule(task.id)
                }
                changed()
            }
        }
    }

    private fun newTask(id: String, draftId: String?, origin: ImportOrigin, status: PendingMediaStatus, selections: List<MediaSelection>) =
        PendingMediaTaskEntity(id, draftId ?: UUID.randomUUID().toString(), origin.name, status.name,
            JsonArray(selections.map { buildJsonObject {
                put("uri", it.uri.toString()); put("origin", it.origin.name)
            } }).toString(), 0, selections.size, null, draftId == null)

    private fun model(task: PendingMediaTaskEntity) = PendingMediaTask(task.id, task.draftId, ImportOrigin.valueOf(task.origin),
        PendingMediaStatus.valueOf(task.status), task.completedItems, task.totalItems, task.errorMessage,
        repository.pendingMediaItems(task.id).map { item ->
            PendingMediaItem(item.id, item.position, ImportOrigin.valueOf(item.origin), PendingMediaItemStatus.valueOf(item.status),
                item.assetId, item.errorMessage, item.provenance?.let { com.henrypann.jinbao365.archive.ImportProvenance.fromWire(it) })
        })

    private fun captureFile(id: String): File {
        require(UUID.fromString(id).toString() == id) { "Invalid capture task identity." }
        return File(context.filesDir, "pending-media/$id/capture.jpg")
    }
    private fun captureUri(id: String): Uri = FileProvider.getUriForFile(context, "${context.packageName}.capture", captureFile(id))
    private fun cleanupCapture(task: PendingMediaTaskEntity) {
        if (task.origin != ImportOrigin.Camera.name) return
        try {
            val file = captureFile(task.id)
            context.revokeUriPermission(captureUri(task.id), Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            file.delete()
            file.parentFile?.delete()
        } catch (_: Exception) { /* The journal retains the task so the next process can retry cleanup. */ }
    }
}

/** Provider exception text can include private paths and URIs; persist only controlled copy. */
private fun importErrorMessage(error: Exception): String = when (error) {
    is ImportRejected -> error.message ?: "照片未能保存，请重试。"
    is SecurityException -> "照片的访问授权已失效，请重新选择。"
    is java.io.FileNotFoundException -> "这张照片暂时无法读取，请确认已下载到本机，或重新选择。"
    is java.io.IOException -> "照片暂时无法读取或存储空间不足，请检查后重试。"
    else -> "照片未能保存，请重试；也可以移除后重新选择。"
}
