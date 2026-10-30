package com.henrypann.jinbao365.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.outlined.CloudDone
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material.icons.outlined.CloudSync
import androidx.compose.material.icons.outlined.CloudUpload
import androidx.compose.material.icons.outlined.CloudQueue
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.*
import com.henrypann.jinbao365.viewing.PhotoPreviewCopy
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.backup.BackupSummary
import com.henrypann.jinbao365.backup.BackupBlockReason
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.ui.theme.DesignTokens

@Composable
internal fun MyScreen(snapshot: ArchiveSnapshot, parent: ParentIdentity?, backupStatus: String,
    draftCount: Int, onOpenArchive: () -> Unit, onOpenBackup: () -> Unit, onOpenSettings: () -> Unit,
    backupSummary: BackupSummary? = null,
    allowCellularOriginals: Boolean = false,
    onAllowCellularOriginals: (Boolean) -> Unit = {},
) {
    val months = remember(snapshot) { reviewMonths(snapshot) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp).testTag("myScreen")) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            BrandPageTitle("我的")
            Text("这台手机：${parent?.label ?: "尚未选择"}", style = MaterialTheme.typography.bodySmall,
                color = DesignTokens.Colors.inkSecondary)
        }
        Spacer(Modifier.height(16.dp))
        Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Surface(color = DesignTokens.Colors.surface, shape = RoundedCornerShape(20.dp),
            modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("成长档案", style = MaterialTheme.typography.titleLarge)
                Text("${months.sumOf { it.recordCount }}条记录 · ${months.size}个月的时光",
                    modifier = Modifier.testTag("archiveSummary"), color = DesignTokens.Colors.inkSecondary)
                if (draftCount > 0) Text("本机有${draftCount}条草稿，可从时光继续填写。", style = MaterialTheme.typography.bodySmall)
                TextButton(onClick = onOpenArchive, modifier = Modifier.testTag("myArchive")) { Text("翻开时光档案") }
            }
        }
        MyAction("云端备份", backupStatus, when (backupVisualState(backupSummary)) {
            BackupVisualState.Complete -> Icons.Outlined.CloudDone
            BackupVisualState.Disconnected -> Icons.Outlined.CloudOff
            BackupVisualState.Progress -> Icons.Outlined.CloudSync
            BackupVisualState.Failed -> Icons.Outlined.ErrorOutline
            BackupVisualState.Waiting -> Icons.Outlined.CloudUpload
            BackupVisualState.Loading -> Icons.Outlined.CloudQueue
        }, "myBackup", onOpenBackup)
        Surface(color = DesignTokens.Colors.surface, shape = RoundedCornerShape(20.dp),
            modifier = Modifier.fillMaxWidth().testTag("cellularOriginalPreference")) {
            Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(PhotoPreviewCopy.CELLULAR_TITLE, style = MaterialTheme.typography.titleMedium)
                    Text(PhotoPreviewCopy.CELLULAR_DETAIL, style = MaterialTheme.typography.bodySmall,
                        color = DesignTokens.Colors.inkSecondary)
                }
                Switch(
                    checked = allowCellularOriginals,
                    onCheckedChange = onAllowCellularOriginals,
                    modifier = Modifier.testTag("cellularOriginalSwitch"),
                    colors = SwitchDefaults.colors(
                        checkedTrackColor = DesignTokens.Colors.accent,
                        checkedThumbColor = DesignTokens.Colors.ink,
                        uncheckedTrackColor = DesignTokens.Colors.separator,
                        uncheckedThumbColor = DesignTokens.Colors.surface,
                        uncheckedBorderColor = DesignTokens.Colors.outline,
                    ),
                )
            }
        }
        MyAction("设置", "身份、云连接与本机存储", Icons.Outlined.Settings, "mySettings", onOpenSettings)
        Text("记录成长，收藏美好。", style = MaterialTheme.typography.bodySmall, color = DesignTokens.Colors.inkSecondary)
        }
    }
}

@Composable
private fun MyAction(title: String, subtitle: String, icon: ImageVector, tag: String, onClick: () -> Unit) {
    Surface(onClick = onClick, color = DesignTokens.Colors.surface, shape = RoundedCornerShape(20.dp),
        modifier = Modifier.fillMaxWidth().testTag(tag)) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Icon(icon, null, tint = DesignTokens.Colors.navy)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(title, style = MaterialTheme.typography.titleMedium)
                Text(subtitle, style = MaterialTheme.typography.bodySmall, color = DesignTokens.Colors.inkSecondary)
            }
            Icon(Icons.Filled.ChevronRight, null, tint = DesignTokens.Colors.inkSecondary)
        }
    }
}

internal enum class BackupVisualState { Loading, Disconnected, Progress, Failed, Complete, Waiting }

internal fun backupVisualState(summary: BackupSummary?): BackupVisualState = when {
    summary == null || summary.blockReason == BackupBlockReason.Loading -> BackupVisualState.Loading
    summary.inProgress -> BackupVisualState.Progress
    summary.hasFailure || summary.blockReason == BackupBlockReason.Credentials -> BackupVisualState.Failed
    summary.blockReason == BackupBlockReason.Connection -> BackupVisualState.Disconnected
    summary.blockReason in setOf(BackupBlockReason.ReadOnly, BackupBlockReason.Metered, BackupBlockReason.Offline) -> BackupVisualState.Waiting
    summary.allCovered -> BackupVisualState.Complete
    else -> BackupVisualState.Waiting
}
