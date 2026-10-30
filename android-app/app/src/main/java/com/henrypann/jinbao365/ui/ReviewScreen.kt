package com.henrypann.jinbao365.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.outlined.EventBusy
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.style.TextOverflow
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.ui.theme.DesignTokens
import java.io.File
import java.time.YearMonth
import java.time.ZoneId

@Composable
internal fun ReviewScreen(snapshot: ArchiveSnapshot, mediaRoot: File,
    onOpenMoment: (String) -> Unit, parentOf: (String) -> ParentIdentity? = { null },
    onOpenTimeline: () -> Unit = {}) {
    var selectedMonth by rememberSaveable { mutableStateOf<String?>(null) }
    val zone = ZoneId.systemDefault()
    val model = remember(snapshot, zone) { timelineModel(snapshot, zoneId = zone) }
    val months = remember(model) { reviewMonths(model) }
    val unknownCount = model.unknownDate.size
    val unknownRow: @Composable () -> Unit = {
        Surface(onClick = onOpenTimeline, modifier = Modifier.fillMaxWidth().testTag("reviewUnknownDate"),
            color = DesignTokens.Colors.surface, shape = RoundedCornerShape(20.dp)) {
            Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(Icons.Outlined.EventBusy, null, tint = DesignTokens.Colors.ink)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(unknownDateReviewText(unknownCount), style = MaterialTheme.typography.titleMedium)
                    Text("可在时光中查看", style = MaterialTheme.typography.bodySmall, color = DesignTokens.Colors.inkSecondary)
                }
                Icon(Icons.Filled.ChevronRight, null, tint = DesignTokens.Colors.inkSecondary)
            }
        }
    }
    BackHandler(selectedMonth != null) { selectedMonth = null }
    key(selectedMonth) {
        Column(Modifier.fillMaxSize().testTag("reviewScreen")) {
            val selected = selectedMonth?.let(YearMonth::parse)
            if (selected != null) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { selectedMonth = null }, modifier = Modifier.testTag("reviewBack")) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回回顾")
                    }
                    Text("${selected.year}年${selected.monthValue}月", style = MaterialTheme.typography.titleLarge)
                }
                TimelineScreen(snapshot, readOnly = true, mediaRoot = mediaRoot, onOpenMoment = onOpenMoment,
                    onAddPhotos = {}, month = selected, parentOf = parentOf)
            } else if (months.isEmpty()) {
                BrandPageTitle("回顾", Modifier.padding(16.dp))
                if (unknownCount > 0) Box(Modifier.padding(horizontal = 16.dp)) { unknownRow() }
                Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.Center) {
                    BrandEmptyState("回顾，从第一条记录开始", "轻点下方＋，留住今天。已有记录会按月份出现在这里。")
                }
            } else {
                Column(Modifier.padding(start = 16.dp, top = 16.dp, end = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    BrandPageTitle("回顾")
                    Text("${months.sumOf { it.recordCount }}条记录，留在${months.size}个月里。",
                        style = MaterialTheme.typography.bodySmall, color = DesignTokens.Colors.inkSecondary)
                }
                LazyColumn(Modifier.weight(1f).testTag("reviewMonths"),
                    contentPadding = PaddingValues(start = 16.dp, top = 16.dp, end = 16.dp, bottom = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    if (unknownCount > 0) item(key = "unknown-date") { unknownRow() }
                    items(months, key = { it.month.toString() }) { month ->
                        Surface(onClick = { selectedMonth = month.month.toString() },
                            modifier = Modifier.fillMaxWidth().testTag("reviewMonth-${month.month}"),
                            color = DesignTokens.Colors.surface, shape = RoundedCornerShape(20.dp)) {
                            Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Text(month.label, style = MaterialTheme.typography.titleLarge)
                                    FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp),
                                        verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                        listOf("${month.recordCount}条记录", "${month.photoCount}张照片", "${month.videoCount}段视频").forEach { label ->
                                            Text(label, modifier = Modifier.wrapContentWidth(unbounded = true),
                                                style = MaterialTheme.typography.bodySmall, softWrap = false,
                                                color = DesignTokens.Colors.inkSecondary)
                                        }
                                    }
                                    Text(month.moments.first().displayTitle, maxLines = 2, overflow = TextOverflow.Ellipsis,
                                        style = MaterialTheme.typography.bodyMedium)
                                }
                                Icon(Icons.Filled.ChevronRight, null, tint = DesignTokens.Colors.navy)
                            }
                        }
                    }
                }
            }
        }
    }
}
