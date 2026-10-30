package com.henrypann.jinbao365.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.ui.theme.DesignTokens

/** This phone's own deleted records, newest deletion first. Other phones' records never appear here. */
internal fun trashedMoments(snapshot: ArchiveSnapshot): List<MomentDetail> =
    snapshot.records.filter { !it.tombstone.isNullValue() }
        .sortedByDescending { it.tombstone.edit.at }
        .mapNotNull { momentDetailModel(snapshot, it.id) }

@Composable
internal fun TrashScreen(
    snapshot: ArchiveSnapshot,
    busy: Boolean,
    canRestore: (String) -> Boolean,
    onOpen: (String) -> Unit,
    onRestore: (String) -> Unit,
    onBack: () -> Unit,
) {
    BackHandler(onBack = onBack)
    val items = remember(snapshot) { trashedMoments(snapshot) }
    Column(Modifier.fillMaxSize().padding(DesignTokens.Spacing.m).testTag("trashScreen")) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack, modifier = Modifier.testTag("trashBack")) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回设置")
            }
            BrandPageTitle("回收站")
        }
        if (items.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                BrandEmptyState("回收站是空的", "删除的记录会先放在这里，可以随时恢复。", BrandIllustration.Quiet)
            }
        } else LazyColumn(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.s),
            contentPadding = PaddingValues(top = DesignTokens.Spacing.m, bottom = 112.dp)) {
            items(items, key = { it.id }) { moment ->
                Surface(color = DesignTokens.Colors.surface, shape = RoundedCornerShape(DesignTokens.Radius.l),
                    modifier = Modifier.fillMaxWidth().clickable { onOpen(moment.id) }.testTag("trashItem-${moment.id}")) {
                    Row(Modifier.padding(DesignTokens.Spacing.m), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(moment.title, style = MaterialTheme.typography.bodyLarge)
                            Text(moment.dateTimeLabel, color = DesignTokens.Colors.inkSecondary,
                                fontSize = DesignTokens.Typography.metaSize)
                        }
                        if (canRestore(moment.id)) TextButton(onClick = { onRestore(moment.id) }, enabled = !busy,
                            modifier = Modifier.testTag("trashRestore-${moment.id}")) { Text("恢复") }
                    }
                }
            }
        }
    }
}
