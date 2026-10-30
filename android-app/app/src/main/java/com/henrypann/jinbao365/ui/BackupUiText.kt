package com.henrypann.jinbao365.ui

import com.henrypann.jinbao365.backup.BackupBlockReason
import com.henrypann.jinbao365.backup.BackupPolicy
import com.henrypann.jinbao365.backup.BackupRecordStatus
import com.henrypann.jinbao365.backup.BackupSummary

internal const val BACKUP_RETRY_MESSAGE = BackupPolicy.RETRY_MESSAGE

internal fun backupStatusText(summary: BackupSummary): String = when {
    summary.inProgress -> "正在备份"
    summary.hasFailure -> BACKUP_RETRY_MESSAGE
    summary.blockReason == BackupBlockReason.Loading -> "正在准备备份"
    summary.blockReason == BackupBlockReason.Connection -> "请连接云存储"
    summary.blockReason == BackupBlockReason.Credentials -> "请检查云存储密钥"
    summary.blockReason == BackupBlockReason.ReadOnly -> "正在同步，暂时只读"
    summary.blockReason == BackupBlockReason.Metered -> BackupPolicy.WIFI_WAITING
    summary.blockReason == BackupBlockReason.Offline -> "等待网络"
    summary.allCovered -> "已完成备份"
    summary.paused || summary.blockReason == BackupBlockReason.Paused -> "备份已暂停，轻点立即备份"
    summary.blockReason == BackupBlockReason.Background -> "请保持应用打开以继续备份"
    else -> "等待备份"
}

internal fun recordBackupStatusText(summary: BackupSummary, recordId: String): String =
    when (summary.recordStatus(recordId)) {
        BackupRecordStatus.BackedUp -> "已备份"
        BackupRecordStatus.LocalOnly -> "已保存在这台手机"
        BackupRecordStatus.Failed -> BACKUP_RETRY_MESSAGE
        BackupRecordStatus.Pending -> backupStatusText(summary)
    }

internal fun backupReminderText(summary: BackupSummary): String =
    "有记录超过24小时未备份，轻点立即备份"

internal fun backupProgressText(summary: BackupSummary): String =
    "正在备份 ${summary.progress?.completed ?: 0}/${summary.progress?.total ?: 0}，请保持打开"
