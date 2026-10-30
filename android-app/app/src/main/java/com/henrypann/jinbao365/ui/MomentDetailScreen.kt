package com.henrypann.jinbao365.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.archive.ImportProvenance
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.backup.BackupSummary
import com.henrypann.jinbao365.ui.theme.DesignTokens
import com.henrypann.jinbao365.viewing.OriginalNetwork
import com.henrypann.jinbao365.viewing.PartnerOriginalDownloader
import java.io.File

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun MomentDetailScreen(
    snapshot: ArchiveSnapshot,
    recordId: String,
    mediaRoot: File,
    readOnly: Boolean,
    onBack: () -> Unit,
    onEdit: (String) -> Unit,
    onTrash: (String) -> Unit,
    onRestore: (String) -> Unit,
    busy: Boolean = false,
    backupSummary: BackupSummary? = null,
    parent: ParentIdentity? = null,
    onRetryBackup: () -> Unit = {},
    originals: PartnerOriginalDownloader? = null,
    allowCellularOriginals: Boolean = false,
) {
    val moment = remember(snapshot, recordId) { momentDetailModel(snapshot, recordId) }
    var viewerPage by rememberSaveable(recordId) { mutableStateOf<Int?>(null) }
    var confirmTrash by rememberSaveable(recordId) { mutableStateOf(false) }
    val downloader = originals ?: remember(mediaRoot) {
        PartnerOriginalDownloader(mediaRoot, { OriginalNetwork.Offline }, { _, _ -> null })
    }
    val openPage = viewerPage
    if (openPage != null && moment != null && moment.media.isNotEmpty()) {
        PhotoViewer(
            media = moment.media,
            initialPage = openPage.coerceIn(0, moment.media.lastIndex),
            mediaRoot = mediaRoot,
            downloader = downloader,
            allowCellular = allowCellularOriginals,
            onBack = { viewerPage = null },
        )
        return
    }
    BackHandler(onBack = onBack)
    Scaffold(
        containerColor = DesignTokens.Colors.bg,
        topBar = {
            TopAppBar(
                title = { Text(if (moment?.trashed == true) "回收站中的记录" else "小日常", style = MaterialTheme.typography.titleLarge) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "返回") } },
                actions = {
                    if (moment != null && !moment.trashed && !readOnly) {
                        IconButton(onClick = { onEdit(recordId) }, enabled = !busy,
                            modifier = Modifier.testTag("editMoment")) { Icon(Icons.Outlined.Edit, "编辑这条记录") }
                        IconButton(onClick = { confirmTrash = true }, enabled = !busy,
                            modifier = Modifier.testTag("trashMoment")) { Icon(Icons.Outlined.Delete, "删除这条记录") }
                    }
                    if (moment != null && moment.trashed && !readOnly) {
                        TextButton(onClick = { onRestore(recordId) }, enabled = !busy,
                            modifier = Modifier.testTag("restoreMoment")) { Text("恢复") }
                    }

                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = DesignTokens.Colors.bg),
            )
        },
    ) { padding ->
        if (moment == null) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                BrandEmptyState("暂时无法打开这条记录", "返回时间线，再试一次。", BrandIllustration.Quiet)
            }
        } else {
            LazyColumn(Modifier.fillMaxSize().padding(padding), verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.m),
                contentPadding = PaddingValues(bottom = 112.dp)) {
                backupSummary?.let { summary ->
                    item(key = "backup-status") {
                        Text(recordBackupStatusText(summary, recordId),
                            Modifier.padding(horizontal = DesignTokens.Spacing.m).testTag("momentBackupStatus").then(
                                if (summary.recordStatus(recordId) == com.henrypann.jinbao365.backup.BackupRecordStatus.Failed)
                                    Modifier.clickable(onClick = onRetryBackup) else Modifier
                            ),
                            color = DesignTokens.Colors.inkSecondary, fontSize = DesignTokens.Typography.metaSize)
                    }
                }
                if (moment.media.isNotEmpty()) item(key = "gallery-${moment.id}") {
                    val pager = rememberPagerState(pageCount = { moment.media.size })
                    Column(Modifier.fillMaxWidth()) {
                    Box(Modifier.fillMaxWidth()) {
                        HorizontalPager(state = pager, verticalAlignment = Alignment.Top,
                            key = { moment.media[it].assetId }, modifier = Modifier.testTag("momentGallery")) { page ->
                            val media = moment.media[page]
                            Box(Modifier.fillMaxWidth().clickable { viewerPage = page }.testTag("momentPhoto-$page")) {
                                LocalMedia(media.image, mediaRoot, Modifier.fillMaxWidth(), clamp = false,
                                    contentDescription = "${if (media.kind == "video") "视频预览" else "记录照片"} ${page + 1}")
                            }
                        }
                        val shownMedia = moment.media[pager.currentPage]
                        if (shownMedia.provenance != ImportProvenance.Unknown) Text(shownMedia.provenance.label,
                            color = DesignTokens.Colors.bg, fontSize = DesignTokens.Typography.captionSize,
                            modifier = Modifier.align(Alignment.BottomStart).padding(DesignTokens.Spacing.m)
                                .clip(RoundedCornerShape(DesignTokens.Radius.full)).background(DesignTokens.Colors.onPhoto)
                                .padding(horizontal = 10.dp, vertical = 5.dp).testTag("momentMediaProvenance"))
                        Text("${pager.currentPage + 1}/${moment.media.size}", color = DesignTokens.Colors.bg,
                            fontSize = DesignTokens.Typography.metaSize,
                            modifier = Modifier.testTag("momentGalleryCount").align(Alignment.BottomEnd).padding(DesignTokens.Spacing.m)
                                .clip(RoundedCornerShape(DesignTokens.Radius.full)).background(DesignTokens.Colors.onPhoto)
                                .padding(horizontal = 10.dp, vertical = 5.dp))
                    }
                    Text(moment.media[pager.currentPage].captureTimeLabel,
                        Modifier.padding(horizontal = DesignTokens.Spacing.m, vertical = 8.dp).testTag("momentCaptureTime"),
                        color = DesignTokens.Colors.inkSecondary, fontSize = DesignTokens.Typography.metaSize)
                    }
                }
                item {
                    Column(Modifier.padding(horizontal = DesignTokens.Spacing.m), verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.s)) {
                        parent?.let { ParentBadge(it) }
                        Text(moment.title, fontSize = DesignTokens.Typography.largeTitleSize,
                            lineHeight = DesignTokens.Typography.largeTitleLineHeight, fontWeight = DesignTokens.Typography.largeTitleWeight)
                        Text(moment.dateTimeLabel, color = DesignTokens.Colors.inkSecondary, fontSize = DesignTokens.Typography.metaSize)
                        if (readOnly) BrandStatusBanner("这条记录仅供查看。")
                        if (moment.trashed) BrandStatusBanner("这条记录在回收站中，恢复后会回到时光。")
                    }
                }
                if (moment.note.isNotBlank()) item {
                    Surface(color = DesignTokens.Colors.surface, shape = RoundedCornerShape(DesignTokens.Radius.l),
                        modifier = Modifier.fillMaxWidth().padding(horizontal = DesignTokens.Spacing.m)) {
                        Text(moment.note, Modifier.padding(DesignTokens.Spacing.l), style = MaterialTheme.typography.bodyLarge)
                    }
                }
            }
        }
    }
    if (confirmTrash) AlertDialog(
        onDismissRequest = { confirmTrash = false }, shape = RoundedCornerShape(DesignTokens.Radius.l),
        title = { Text("删除这条记录？") },
        text = { Text("删除后会移到回收站，可以在「我的 → 设置 → 回收站」里恢复。") },
        confirmButton = {
            TextButton(modifier = Modifier.testTag("confirmTrashMoment"), onClick = { confirmTrash = false; onTrash(recordId) }) {
                Text("删除", color = DesignTokens.Colors.destructive)
            }
        },
        dismissButton = { TextButton(onClick = { confirmTrash = false }) { Text("取消") } },
    )
}
