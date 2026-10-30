package com.henrypann.jinbao365.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import com.henrypann.jinbao365.backup.BackupSummary
import com.henrypann.jinbao365.backup.originalsNotBackedUpText
import com.henrypann.jinbao365.ui.theme.DesignTokens

/**
 * Settings destination hosted by Stage B. All coverage, status and action availability come
 * from BackupStatusQuery; this screen only renders that immutable result and sends callbacks.
 * Connection strings must contain display metadata only, never storage credentials.
 */
@Composable
fun CloudStorageScreen(
    summary: BackupSummary,
    bucket: String,
    region: String,
    prefix: String,
    onBackUpNow: () -> Unit,
    onPause: () -> Unit,
    onRetryFailed: () -> Unit,
    onChangeCredentials: () -> Unit,
    onBack: () -> Unit,
    deviceId: String? = null,
    backupError: String? = null,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onBack)
    Surface(
        modifier = modifier.fillMaxSize().testTag("cloudStorage"),
        color = DesignTokens.Colors.bg,
        contentColor = DesignTokens.Colors.ink,
    ) {
        Column(
            modifier = Modifier.verticalScroll(rememberScrollState()).padding(DesignTokens.Spacing.m),
            verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.m),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回", tint = DesignTokens.Colors.ink)
                }
                Text(
                    "云存储",
                    color = DesignTokens.Colors.ink,
                    style = TextStyle(
                        fontSize = DesignTokens.Typography.titleSize,
                        lineHeight = DesignTokens.Typography.titleLineHeight,
                        fontWeight = DesignTokens.Typography.titleWeight,
                    ),
                )
            }

            Text("让每一份成长记录安心留下", color = DesignTokens.Colors.inkSecondary, style = cloudStorageBodyStyle)
            CloudStorageGroup {
                Text(
                    backupStatusText(summary),
                    modifier = Modifier.testTag("backupStatusLine").then(
                        if (summary.hasFailure) Modifier.clickable(onClick = onBackUpNow) else Modifier
                    ),
                    color = if (summary.hasFailure) DesignTokens.Colors.problem else DesignTokens.Colors.ink,
                    style = cloudStorageTitleStyle,
                )
                Text(
                    "${summary.unbackedOriginalCount}个原文件尚未备份",
                    modifier = Modifier.testTag("unbackedOriginals"),
                    color = DesignTokens.Colors.navy,
                    style = cloudStorageTitleStyle,
                )
                Text(
                    "${summary.unbackedRecordCount}条记录尚未备份",
                    color = DesignTokens.Colors.inkSecondary,
                    style = cloudStorageCaptionStyle,
                )
                if (summary.hasOverdue) {
                    Text(
                        if (summary.overdueOriginalCount > 0)
                            "${summary.overdueOriginalCount}个原文件已等待超过24小时"
                        else "有记录超过24小时未备份",
                        color = DesignTokens.Colors.problem,
                        style = cloudStorageCaptionStyle,
                    )
                }
                if (summary.failedCount > 0) {
                    Text(
                        "${summary.failedCount}项备份失败，请重试",
                        color = DesignTokens.Colors.problem,
                        style = cloudStorageCaptionStyle,
                    )
                }
                if (backupError != null && summary.hasFailure) {
                    TextButton(onClick = onBackUpNow, modifier = Modifier.testTag("backupError"),
                        colors = ButtonDefaults.textButtonColors(contentColor = DesignTokens.Colors.problem)) {
                        Text(BACKUP_RETRY_MESSAGE, style = cloudStorageCaptionStyle)
                    }
                }
                if (summary.inProgress) {
                    val progress = summary.progress
                    if (progress != null && progress.total > 0) {
                        LinearProgressIndicator(
                            progress = { (progress.completed.toFloat() / progress.total).coerceIn(0f, 1f) },
                            modifier = Modifier.fillMaxWidth(),
                            color = DesignTokens.Colors.blue,
                            trackColor = DesignTokens.Colors.separator,
                        )
                        Text(
                            "已备份 ${progress.completed}/${progress.total} 个文件",
                            color = DesignTokens.Colors.inkSecondary,
                            style = cloudStorageCaptionStyle,
                        )
                    } else {
                        LinearProgressIndicator(
                            modifier = Modifier.fillMaxWidth(),
                            color = DesignTokens.Colors.blue,
                            trackColor = DesignTokens.Colors.separator,
                        )
                    }
                }
                CloudStorageValue("上次上传", displayBackupTime(summary.lastUploadAtMillis), Modifier.testTag("lastUpload"))
                CloudStorageValue("上次完成备份", displayBackupTime(summary.lastCommitAtMillis))
            }

            BrandPrimaryButton(
                onClick = onBackUpNow,
                enabled = summary.canBackUpNow,
                modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).testTag("backUpNow"),
                shape = RoundedCornerShape(DesignTokens.Radius.l),
                colors = ButtonDefaults.buttonColors(
                    containerColor = DesignTokens.Colors.accent,
                    contentColor = DesignTokens.Colors.onAccent,
                    disabledContainerColor = DesignTokens.Colors.surface,
                    disabledContentColor = DesignTokens.Colors.inkSecondary,
                ),
            ) {
                Text("立即备份", style = cloudStorageBodyStyle)
            }

            CloudStorageGroup {
                CloudStorageAction("暂停备份", onPause, summary.canPause, Modifier.testTag("pauseBackup"))
                CloudStorageAction("重试失败的文件", onRetryFailed, summary.canRetryFailed, Modifier.testTag("retryFailedBackups"))
            }

            CloudStorageGroup {
                Text("连接信息", color = DesignTokens.Colors.ink, style = cloudStorageTitleStyle)
                CloudStorageValue("存储桶", bucket.ifBlank { "尚未连接" })
                CloudStorageValue("地域", region.ifBlank { "尚未连接" })
                CloudStorageValue("记录文件夹", prefix.ifBlank { "/" })
                deviceId?.let { CloudStorageValue("设备编号", it) }
                CloudStorageAction("修改连接信息", onChangeCredentials)
            }
        }
    }
}

@Composable
private fun CloudStorageGroup(content: @Composable ColumnScope.() -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(DesignTokens.Radius.l),
        color = DesignTokens.Colors.surface,
        contentColor = DesignTokens.Colors.ink,
    ) {
        Column(
            modifier = Modifier.padding(DesignTokens.Spacing.m),
            verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.s),
            content = content,
        )
    }
}

@Composable
private fun CloudStorageValue(label: String, value: String, modifier: Modifier = Modifier) {
    Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)) {
        Text(label, color = DesignTokens.Colors.inkSecondary, style = cloudStorageCaptionStyle)
        Text(value, modifier = modifier, color = DesignTokens.Colors.ink, style = cloudStorageBodyStyle)
    }
}

@Composable
private fun CloudStorageAction(label: String, onClick: () -> Unit, enabled: Boolean = true, modifier: Modifier = Modifier) {
    TextButton(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.fillMaxWidth().heightIn(min = 48.dp),
        colors = ButtonDefaults.textButtonColors(
            contentColor = DesignTokens.Colors.ink,
            disabledContentColor = DesignTokens.Colors.inkSecondary,
        ),
    ) {
        Text(label, style = cloudStorageBodyStyle)
    }
}

internal fun displayBackupTime(millis: Long?): String = millis?.let { momentDateTimeLabel(it) } ?: "暂无"

private val cloudStorageTitleStyle = TextStyle(
    fontSize = DesignTokens.Typography.titleSize,
    lineHeight = DesignTokens.Typography.titleLineHeight,
    fontWeight = DesignTokens.Typography.titleWeight,
)
private val cloudStorageBodyStyle = TextStyle(
    fontSize = DesignTokens.Typography.bodySize,
    lineHeight = DesignTokens.Typography.bodyLineHeight,
    fontWeight = DesignTokens.Typography.bodyWeight,
)
private val cloudStorageCaptionStyle = TextStyle(
    fontSize = DesignTokens.Typography.captionSize,
    lineHeight = DesignTokens.Typography.captionLineHeight,
    fontWeight = DesignTokens.Typography.captionWeight,
)
