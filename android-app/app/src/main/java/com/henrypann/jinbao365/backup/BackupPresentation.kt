package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.storage.StorageConfiguration

enum class ArchiveBackupBadge { None, Uploading, Failed, Overdue }

data class RecordBackupPresentation(
    val badge: ArchiveBackupBadge = ArchiveBackupBadge.None,
    val backedUp: Boolean = false,
    val failureReason: String? = null,
)

data class BackupQueueEntry(
    val objectKey: String,
    val filename: String,
    val byteCount: Long?,
    val status: BackupObjectStatus,
    val lastError: String? = null,
    val attempts: Int = 0,
)

data class BackupPresentation(
    val records: Map<String, RecordBackupPresentation> = emptyMap(),
    val overdueOriginalCount: Int = 0,
    val queue: List<BackupQueueEntry> = emptyList(),
)

/** Legacy queue/badge adapter; all coverage and aging come from [BackupStatusQuery]. */
fun deriveBackupPresentation(
    snapshot: ArchiveSnapshot,
    configuration: StorageConfiguration?,
    state: BackupState?,
    now: Long,
    running: Boolean = false,
): BackupPresentation {
    val summary = DefaultBackupStatusQuery().query(snapshot, state, now, BackupCoordinatorState(
        state = state, configuration = configuration, running = running,
        paused = state?.paused ?: true, blockReason = null,
    ))
    return BackupPresentation(summary.records, summary.overdueOriginalCount, summary.queue)
}

fun originalsNotBackedUpText(count: Int): String {
    require(count >= 0)
    return "$count 个原件尚未备份"
}

fun recordBackupDetailText(record: RecordBackupPresentation, waitingForWifi: Boolean = false): String = when {
    record.backedUp -> "已备份"
    record.badge == ArchiveBackupBadge.Uploading -> "正在上传…"
    record.badge == ArchiveBackupBadge.Failed -> BackupPolicy.RETRY_MESSAGE
    waitingForWifi -> BackupPolicy.WIFI_WAITING
    else -> "尚未备份"
}

fun queueStatusText(status: BackupObjectStatus): String = when (status) {
    BackupObjectStatus.pending -> "等待备份"
    BackupObjectStatus.uploading -> "正在上传…"
    BackupObjectStatus.verifying -> "正在校验…"
    BackupObjectStatus.verified -> "已校验"
    BackupObjectStatus.failed -> "失败"
}

fun settingsBackupStatusText(summary: BackupSummary): String = summary.statusLine

fun settingsBackupNeedsAttention(summary: BackupSummary): Boolean = summary.hasFailure ||
    summary.blockReason in setOf(BackupBlockReason.Credentials, BackupBlockReason.ReadOnly)
