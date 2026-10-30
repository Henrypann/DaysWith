package com.henrypann.jinbao365.ui

import androidx.activity.compose.BackHandler
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.ExperimentalFoundationApi
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
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.data.LocalSyncState
import com.henrypann.jinbao365.data.ParentIdentity
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.ui.unit.dp
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.ui.Alignment
import com.henrypann.jinbao365.backup.BackupSummary
import com.henrypann.jinbao365.storage.StorageConfiguration
import com.henrypann.jinbao365.storage.SavedConnection
import com.henrypann.jinbao365.storage.StorageConnectionController
import com.henrypann.jinbao365.ui.theme.DesignTokens
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun SettingsScreen(
    controller: StorageConnectionController,
    deviceId: String,
    mediaRoot: File,
    snapshot: ArchiveSnapshot,
    syncState: LocalSyncState?,
    onOpenTrash: () -> Unit,
    backupSummary: BackupSummary,
    backupConfiguration: StorageConfiguration?,
    onBackUpNow: () -> Unit,
    onPauseBackup: () -> Unit,
    onRetryFailed: () -> Unit,
    openCloudStorage: Boolean = false,
    onCloudStorageOpened: () -> Unit = {},
    parent: ParentIdentity? = null,
    backupError: String? = null,
    onBack: () -> Unit = {},
    showBack: Boolean = false,
    onImportFiles: () -> Unit = {},
    canImportFiles: Boolean = true,
) {
    BackHandler(showBack, onBack)
    var cloudStorage by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(openCloudStorage) {
        if (openCloudStorage) { cloudStorage = true; onCloudStorageOpened() }
    }
    val context = LocalContext.current
    val version = remember(context) {
        runCatching {
            @Suppress("DEPRECATION")
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            "版本 ${info.versionName ?: "未知"}（${info.longVersionCode}）"
        }.getOrDefault("暂时无法获取版本")
    }
    val mediaUsage by produceState("正在计算…", mediaRoot, snapshot) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                val bytes = mediaRoot.walkTopDown().filter { it.isFile }.sumOf { it.length() }
                localMediaSizeText(bytes)
            }.getOrDefault("暂时无法获取")
        }
    }
    val connection = controller.connection
    val configuration = when (connection) {
        is SavedConnection.Verified -> connection.configuration
        is SavedConnection.Configured -> connection.configuration
        else -> null
    }
    // Credential entry remains protected and clears transient inputs on lifecycle changes.
    StorageConnectionScreen(controller, mandatory = false) { changeCredentials, disconnect ->
        if (cloudStorage) {
            CloudStorageScreen(
                summary = backupSummary,
                bucket = backupConfiguration?.bucket ?: configuration?.bucket.orEmpty(),
                region = backupConfiguration?.region ?: configuration?.region.orEmpty(),
                prefix = backupConfiguration?.prefix.orEmpty(), deviceId = deviceId, backupError = backupError,
                onBackUpNow = onBackUpNow, onPause = onPauseBackup, onRetryFailed = onRetryFailed,
                onChangeCredentials = changeCredentials, onBack = { cloudStorage = false },
            )
        } else Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(DesignTokens.Spacing.m),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (showBack) IconButton(onClick = onBack, modifier = Modifier.testTag("settingsBack")) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回我的")
                }
                BrandPageTitle("设置")
            }
            Column(Modifier.padding(top = DesignTokens.Spacing.m),
                verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.l)) {
            SettingsGroup("家人") {
                Text("这台手机：${parent?.label ?: "尚未选择"}", Modifier.padding(DesignTokens.Spacing.m).testTag("phoneParent"))
                SettingsCaption("这台手机的记录都会署名${parent?.label.orEmpty()}，确认后不能修改。")
            }
            SettingsGroup("云存储") {
                Text(
                    if (connection is SavedConnection.Verified) "云存储已连接" else "需要连接云存储",
                    Modifier.padding(DesignTokens.Spacing.m).then(
                        if (connection is SavedConnection.Verified) Modifier.testTag("storageVerified") else Modifier,
                    ),
                    color = DesignTokens.Colors.ink,
                )
                SettingsValue("存储桶", configuration?.bucket ?: "—")
                SettingsValue("地域", configuration?.region ?: "—")
                SettingsValue("记录文件夹", backupConfiguration?.prefix ?: parent?.prefix ?: "—")
                SettingsRule()
                SettingsAction("修改连接信息", "changeCredentials", changeCredentials, !controller.busy)

            }
            SettingsGroup("备份") {
                if (backupSummary.hasFailure) {
                    SettingsAction(BACKUP_RETRY_MESSAGE, "settingsBackupStatus", onBackUpNow)
                } else SettingsValue("当前状态", backupStatusText(backupSummary), Modifier.testTag("settingsBackupStatus"))
                SettingsValue("待备份记录", backupSummary.unbackedRecordCount.toString())
                SettingsValue("待备份原文件", backupSummary.unbackedOriginalCount.toString())
                SettingsRule()
                SettingsAction("备份详情", "openCloudStorage", { cloudStorage = true })
                if (syncState?.resyncFromStart == true) {
                    SettingsCaption("这台手机正在同步，编辑暂时不可用。", Modifier.testTag("storageReadOnlyNotice"))
                }
            }
            SettingsGroup("这台手机") {
                SettingsValue("本地照片和视频", mediaUsage, Modifier.testTag("localMediaUsage"))
                SettingsCaption("只保存你亲手选择的照片、视频和文字。")
                SettingsRule()
                SettingsAction("从文件导入", "importFiles", onImportFiles, canImportFiles)
                SettingsRule()
                SettingsAction("回收站", "openTrash", onOpenTrash)

            }
            SettingsGroup("关于") {
                SettingsCaption("DaysWith · 一起留住长大的每一天")
                SettingsCaption(version, Modifier.testTag("appVersion"))
                SettingsRule()
                Column(Modifier.padding(DesignTokens.Spacing.m), verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)) {
                    Text("设备编号", style = MaterialTheme.typography.bodyMedium)
                    Text(deviceId, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace,
                        color = DesignTokens.Colors.inkSecondary)
                }
            }
            }
        }
    }
}

@Composable
private fun SettingsGroup(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.s)) {
        Text(title, style = MaterialTheme.typography.titleMedium, color = DesignTokens.Colors.navy)
        Surface(shape = RoundedCornerShape(DesignTokens.Radius.l), color = DesignTokens.Colors.surface,
            contentColor = DesignTokens.Colors.ink, modifier = Modifier.fillMaxWidth()) {
            Column(content = content)
        }
    }
}

@Composable
private fun SettingsValue(label: String, value: String, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().padding(horizontal = DesignTokens.Spacing.m, vertical = DesignTokens.Spacing.s),
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.m)) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Text(value, Modifier.weight(1f), color = DesignTokens.Colors.inkSecondary,
            style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.End)
    }
}

@Composable
private fun SettingsCaption(text: String, modifier: Modifier = Modifier) {
    Text(text, modifier.padding(horizontal = DesignTokens.Spacing.m, vertical = DesignTokens.Spacing.s),
        style = MaterialTheme.typography.bodySmall, color = DesignTokens.Colors.inkSecondary)
}

@Composable
private fun SettingsRule() {
    HorizontalDivider(Modifier.padding(horizontal = DesignTokens.Spacing.m), color = DesignTokens.Colors.separator)
}

@Composable
private fun SettingsAction(label: String, tag: String, onClick: () -> Unit, enabled: Boolean = true, destructive: Boolean = false) {
    TextButton(onClick = onClick, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag(tag),
        shape = RoundedCornerShape(DesignTokens.Radius.m),
        colors = ButtonDefaults.textButtonColors(contentColor = if (destructive) DesignTokens.Colors.destructive else DesignTokens.Colors.ink)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = DesignTokens.Spacing.s), verticalAlignment = Alignment.CenterVertically) {
            Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
            Icon(Icons.Filled.ChevronRight, null, tint = DesignTokens.Colors.inkSecondary)
        }
    }
}

internal fun localMediaSizeText(bytes: Long): String = when {
    bytes < 1_000L -> "${bytes.coerceAtLeast(0)}字节"
    bytes < 1_000_000L -> String.format(java.util.Locale.CHINA, "%.1f千字节", bytes / 1_000.0)
    bytes < 1_000_000_000L -> String.format(java.util.Locale.CHINA, "%.1f兆字节", bytes / 1_000_000.0)
    else -> String.format(java.util.Locale.CHINA, "%.1f吉字节", bytes / 1_000_000_000.0)
}
