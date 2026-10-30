package com.henrypann.jinbao365.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.henrypann.jinbao365.data.Anniversary
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.ui.theme.DesignTokens
import java.time.LocalDate

private val CountdownSoonInk = Color(0xFF6B5600)

@Composable
internal fun AnniversariesScreen(
    anniversaries: List<Anniversary>,
    parent: ParentIdentity?,
    busy: Boolean,
    onSave: (String?, String, LocalDate, () -> Unit) -> Unit,
    onDelete: (String) -> Unit,
    onBack: () -> Unit,
    onEditingChanged: (Boolean) -> Unit = {},
) {
    var editing by rememberSaveable { mutableStateOf(false) }
    var editingId by rememberSaveable { mutableStateOf<String?>(null) }
    var deleteId by rememberSaveable { mutableStateOf<String?>(null) }
    DisposableEffect(editing) {
        onEditingChanged(editing)
        onDispose { onEditingChanged(false) }
    }
    val today = rememberLocalToday()
    val entries = remember(anniversaries, today) { countdownEntries(anniversaries, today) }
    fun edit(item: Anniversary?) {
        editingId = item?.id
        editing = true
    }

    if (editing) {
        AnniversaryEditorScreen(
            initial = anniversaries.firstOrNull { it.id == editingId && canManageAnniversary(it, parent) },
            parent = parent, busy = busy, onSave = onSave, onDismiss = { editing = false },
            onDelete = if (editingId != null) { { deleteId = editingId; editing = false } } else null,
        )
        return
    }

    Column(Modifier.fillMaxSize().testTag("anniversariesScreen")) {
        Row(Modifier.fillMaxWidth().padding(start = DesignTokens.Spacing.m, end = DesignTokens.Spacing.s,
            top = DesignTokens.Spacing.s), verticalAlignment = Alignment.CenterVertically) {
            BrandPageTitle("纪念", Modifier.weight(1f))
            IconButton(onClick = { edit(null) }, enabled = parent != null && !busy,
                modifier = Modifier.testTag("addAnniversary")) {
                Icon(Icons.Filled.Add, "添加纪念日", tint = DesignTokens.Colors.navy)
            }
        }
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (entries.isEmpty()) item(key = "countdown-empty") {
                BrandEmptyState("把重要的日子记下来", "生日、纪念日，还有你们的小约定。", BrandIllustration.Happy)
            }
            itemsIndexed(entries, key = { _, entry -> "${entry.anniversary.owner.folder}:${entry.anniversary.id}" }) { index, entry ->
                CountdownCard(entry, featured = index == 0, showParent = entry.anniversary.owner != parent,
                    enabled = canManageAnniversary(entry.anniversary, parent) && !busy, onClick = { edit(entry.anniversary) })
            }
        }
    }

    val pendingDelete = entries.map { it.anniversary }.firstOrNull { it.id == deleteId && canManageAnniversary(it, parent) }
    if (pendingDelete != null) {
        AlertDialog(onDismissRequest = { deleteId = null }, shape = RoundedCornerShape(DesignTokens.Radius.l), title = { Text("删除纪念日？") },
            text = { Text("确定删除这条纪念日？删除后将从这台手机的列表中移除。") },
            confirmButton = { TextButton(onClick = { onDelete(pendingDelete.id); deleteId = null }, enabled = !busy,
                modifier = Modifier.testTag("confirmDeleteAnniversary"),
                colors = ButtonDefaults.textButtonColors(contentColor = DesignTokens.Colors.destructive)) { Text("删除") } },
            dismissButton = { TextButton(onClick = { deleteId = null }) { Text("取消") } })
    }
}

@Composable
private fun CountdownCard(entry: CountdownEntry, featured: Boolean, showParent: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val stacked = LocalDensity.current.fontScale >= 1.3f
    val minHeight = if (featured) 112.dp else 92.dp
    Surface(onClick = onClick, enabled = enabled, shape = RoundedCornerShape(20.dp),
        color = if (featured) DesignTokens.Colors.accentSoft else DesignTokens.Colors.surface,
        shadowElevation = 0.dp, tonalElevation = 0.dp, border = null,
        modifier = Modifier.fillMaxWidth().testTag("anniversary-${entry.anniversary.owner.folder}-${entry.anniversary.id}")) {
        val body = Modifier.fillMaxWidth().padding(18.dp).heightIn(min = minHeight - 36.dp)
        if (stacked) Column(body, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            CountdownFacts(entry, showParent, featured)
            CountdownFigure(entry, featured)
        } else Row(body, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            CountdownFacts(entry, showParent, featured, Modifier.weight(1f))
            CountdownFigure(entry, featured)
        }
    }
}

@Composable
private fun CountdownFacts(entry: CountdownEntry, showParent: Boolean, featured: Boolean, modifier: Modifier = Modifier) {
    val soon = featured && entry.daysUntil <= 7
    Column(modifier, verticalArrangement = Arrangement.spacedBy(if (soon) 7.dp else 12.dp)) {
        Text(entry.anniversary.title, color = DesignTokens.Colors.ink, fontSize = DesignTokens.Typography.bodySize,
            lineHeight = DesignTokens.Typography.bodyLineHeight, fontWeight = FontWeight.Bold)
        Text(entry.subtitleText, color = DesignTokens.Colors.inkSecondary, fontSize = DesignTokens.Typography.captionSize,
            lineHeight = DesignTokens.Typography.captionLineHeight, fontWeight = DesignTokens.Typography.captionWeight)
        if (soon) Text("就在这周", color = CountdownSoonInk,
            fontSize = DesignTokens.Typography.metaSize, lineHeight = DesignTokens.Typography.metaLineHeight,
            fontWeight = DesignTokens.Typography.metaWeight)
        if (showParent) ParentBadge(entry.anniversary.owner)
    }
}

@Composable
private fun CountdownFigure(entry: CountdownEntry, featured: Boolean) {
    val numberSize = if (featured) 44.sp else 36.sp
    Row(Modifier.testTag("countdownDays-${entry.anniversary.id}"), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        if (entry.daysUntil == 0) {
            Text("就是今天", Modifier.alignByBaseline(), style = countdownFigureStyle(numberSize, FontWeight.Bold, DesignTokens.Colors.ink))
        } else {
            Text("还有", Modifier.alignByBaseline(),
                style = countdownFigureStyle(DesignTokens.Typography.captionSize, FontWeight.Normal, DesignTokens.Colors.inkSecondary))
            Text(entry.daysUntil.toString(), Modifier.alignByBaseline(),
                style = countdownFigureStyle(numberSize, FontWeight.Bold, DesignTokens.Colors.ink, features = "tnum"))
            Text("天", Modifier.alignByBaseline(),
                style = countdownFigureStyle(DesignTokens.Typography.headlineSize, FontWeight.Normal, DesignTokens.Colors.inkSecondary))
        }
    }
}

private fun countdownFigureStyle(size: TextUnit, weight: FontWeight, color: Color, features: String? = null) = TextStyle(
    fontSize = size, lineHeight = size, fontWeight = weight, color = color, fontFeatureSettings = features,
    platformStyle = PlatformTextStyle(includeFontPadding = false),
)
