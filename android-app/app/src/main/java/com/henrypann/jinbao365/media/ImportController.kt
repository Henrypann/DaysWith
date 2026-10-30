package com.henrypann.jinbao365.media

import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.data.ArchiveRepository
import java.util.concurrent.Executor

data class ImportState(
    val status: String = "正在读取记录…",
    val busy: Boolean = true,
    val recordCount: Int = 0,
    val assetCount: Int = 0,
    val resourceCount: Int = 0,
) {
    val archiveSummary: String
        get() = "已保存 $recordCount 条记录 · $assetCount 项照片和视频"
}

/** Process-owned imports survive tab changes and Activity recreation. Only the main thread publishes UI state. */
class ImportController(
    private val repository: ArchiveRepository,
    private val deviceId: String,
    private val importer: MediaImporter,
    private val executor: Executor = ImportScheduler.executor,
    private val publish: (() -> Unit) -> Unit = { Handler(Looper.getMainLooper()).post(it) },
) {
    private val importService = MediaImportService(repository, deviceId, importer)

    var state by mutableStateOf(ImportState())
        private set

    init {
        executor.execute {
            try {
                val snapshot = repository.loadSnapshot()
                val message = if (snapshot.records.isEmpty()) "还没有添加照片。" else "记录已载入。"
                publish { state = snapshot.state(message) }
            } catch (error: Exception) {
                publish { state = state.copy(status = "暂时无法读取记录，请重试。", busy = false) }
            }
        }
    }

    /** Called by an Activity result on the main thread; the request closes over application context only. */
    fun submit(request: () -> ImportRequest): Boolean {
        checkMainThread()
        if (state.busy) return false
        state = state.copy(status = "正在保存…", busy = true)
        executor.execute {
            try {
                val result = importService.importSingle(request())
                val updated = repository.loadSnapshot()
                val message = if (result.inserted) "已保存。" else "这张照片已经保存过了。"
                publish { state = updated.state("$message\n${summary(result.imported)}") }
            } catch (error: Exception) {
                publish { state = state.copy(status = (error as? ImportRejected)?.message ?: "暂时无法保存，请重试。", busy = false) }
            }
        }
        return true
    }

    fun showStatus(message: String) {
        checkMainThread()
        if (!state.busy) state = state.copy(status = message)
    }

    private fun checkMainThread() = check(Looper.myLooper() == Looper.getMainLooper()) {
        "导入操作需要在主线程执行。"
    }
}

private fun ArchiveSnapshot.state(status: String) = ImportState(
    status = status, busy = false,
    recordCount = records.size, assetCount = assets.size, resourceCount = resources.size,
)

private fun summary(imported: PreparedImport): String =
    when {
        imported.provenance == com.henrypann.jinbao365.archive.ImportProvenance.SystemProvided -> "照片已保存 · 系统提供版本。"
        imported.locationInOriginal -> "照片和拍摄位置已保存。"
        else -> "照片已保存，拍摄位置未知。"
    }
