package com.henrypann.jinbao365.ui

import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.staggeredgrid.LazyVerticalStaggeredGrid
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridCells
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridItemSpan
import androidx.compose.foundation.lazy.staggeredgrid.items
import androidx.compose.foundation.lazy.staggeredgrid.rememberLazyStaggeredGridState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.outlined.Collections
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.data.Anniversary
import com.henrypann.jinbao365.backup.BackupSummary
import com.henrypann.jinbao365.ui.theme.DesignTokens
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

private val TimelineNoteInk = Color(0xFF3A4A5E)
private val TimelinePhotoShape = RoundedCornerShape(16.dp)

@Composable
internal fun TimelineScreen(
    snapshot: ArchiveSnapshot,
    readOnly: Boolean,
    mediaRoot: File,
    onOpenMoment: (String) -> Unit,
    onAddPhotos: () -> Unit,
    month: YearMonth? = null,
    busy: Boolean = false,
    backupSummary: BackupSummary? = null,
    onOpenBackup: () -> Unit = {},
    onOpenSettings: () -> Unit = {},
    parentOf: (String) -> ParentIdentity? = { null },
    anniversaries: List<Anniversary> = emptyList(),
    onOpenAnniversaries: () -> Unit = {},
    todayOverride: LocalDate? = null,
) {
    var searchVisible by rememberSaveable(month?.toString()) { mutableStateOf(false) }
    var search by rememberSaveable(month?.toString()) { mutableStateOf("") }
    val zone = ZoneId.systemDefault()
    val currentLocalDate = rememberLocalToday()
    val today = todayOverride ?: currentLocalDate
    val anniversary = remember(anniversaries, today) { anniversaryReminder(anniversaries, today) }
    val model = remember(snapshot, readOnly, search, month, zone) {
        timelineModel(snapshot, readOnly, zone, search, month)
    }
    Column(Modifier.fillMaxSize().testTag(if (month == null) "timeline" else "monthTimeline-$month")) {
        BrandTimelineHeader(jinbaoAge(today)?.fullLabel ?: "留住一起度过的日子", searchVisible) {
            searchVisible = !searchVisible
            if (!searchVisible) search = ""
        }
        if (month == null && anniversary != null) {
            Surface(onClick = onOpenAnniversaries, color = DesignTokens.Colors.surface,
                shape = RoundedCornerShape(DesignTokens.Radius.m),
                modifier = Modifier.fillMaxWidth().padding(horizontal = DesignTokens.Spacing.m, vertical = DesignTokens.Spacing.s)
                    .testTag("anniversaryReminder")) {
                Row(Modifier.heightIn(min = 48.dp).padding(12.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Outlined.CalendarMonth, null, Modifier.size(24.dp), tint = DesignTokens.Colors.inkSecondary)
                    Text(anniversary.text, Modifier.weight(1f), color = DesignTokens.Colors.ink,
                        style = MaterialTheme.typography.bodySmall)
                    Icon(Icons.Filled.ChevronRight, null, Modifier.size(24.dp), tint = DesignTokens.Colors.inkSecondary)
                }
            }
        }
        if (searchVisible) {
            OutlinedTextField(
                value = search, onValueChange = { search = it },
                modifier = Modifier.fillMaxWidth().padding(horizontal = DesignTokens.Spacing.m).testTag("timelineSearch"),
                placeholder = { Text("搜索标题和文字") },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                singleLine = true, colors = brandFieldColors(), shape = RoundedCornerShape(DesignTokens.Radius.l),
            )
        }
        if (backupSummary?.hasOverdue == true && !backupSummary.inProgress) {
            Surface(onClick = onOpenBackup, color = DesignTokens.Colors.accentSoft,
                shape = RoundedCornerShape(DesignTokens.Radius.m),
                modifier = Modifier.fillMaxWidth().padding(horizontal = DesignTokens.Spacing.m).testTag("backupReminderBanner")) {
                Text(backupReminderText(backupSummary), Modifier.heightIn(min = 48.dp).padding(12.dp),
                    color = DesignTokens.Colors.ink, style = MaterialTheme.typography.bodySmall)
            }
        }
        val emptyState = model.emptyState
        if (emptyState != null) {
            TimelineEmpty(emptyState, readOnly, busy, month, onAddPhotos, Modifier.weight(1f))
        } else {
            MomentWaterfall(model.days, mediaRoot, today, zone, onOpenMoment,
                parentOf = parentOf, resetKey = "$search/$month", showMonthHeaders = month == null,
                unknownDate = model.unknownDate, modifier = Modifier.weight(1f))
        }
    }
}

@Composable
private fun TimelineFilterChip(label: String, selected: Boolean, onClick: () -> Unit) {
    FilterChip(
        selected = selected, onClick = onClick, label = { Text(label) },
        shape = RoundedCornerShape(DesignTokens.Radius.full), border = null,
        colors = FilterChipDefaults.filterChipColors(
            containerColor = DesignTokens.Colors.surface, labelColor = DesignTokens.Colors.inkSecondary,
            selectedContainerColor = DesignTokens.Colors.accent, selectedLabelColor = DesignTokens.Colors.onAccent,
        ),
    )
}

@Composable
private fun TimelineEmpty(
    state: TimelineEmptyState,
    readOnly: Boolean,
    busy: Boolean,
    month: YearMonth?,
    onAddPhotos: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(DesignTokens.Spacing.l).testTag("timelineEmpty"),
        verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        BrandEmptyState(when {
            state == TimelineEmptyState.Filtered -> "没有找到相关记录"
            month != null -> "这个月还没有记录"
            state == TimelineEmptyState.ReadOnly -> "这台手机暂时还没有记录"
            else -> "留住我们的第一个小日常"
        }, when {
            state == TimelineEmptyState.Filtered -> "换个词再找找吧"
            readOnly -> "同步完成后，记录会出现在这里"
            else -> "轻点下面的＋，存下照片或写一段话"
        }, if (state == TimelineEmptyState.Filtered) BrandIllustration.Explore else BrandIllustration.Quiet)
        if (!readOnly && state != TimelineEmptyState.Filtered) {
            Spacer(Modifier.height(DesignTokens.Spacing.m))
            BrandPrimaryButton(onClick = onAddPhotos, enabled = !busy, shape = RoundedCornerShape(DesignTokens.Radius.m),
                colors = ButtonDefaults.buttonColors(containerColor = DesignTokens.Colors.accent, contentColor = DesignTokens.Colors.onAccent),
                modifier = Modifier.testTag("emptyAddPhotos")) { Text("选照片或视频") }
        }
    }
}

@Composable
private fun MomentWaterfall(
    days: List<TimelineDay>, mediaRoot: File, today: LocalDate, zone: ZoneId,
    onOpenMoment: (String) -> Unit, parentOf: (String) -> ParentIdentity?, resetKey: String,
    showMonthHeaders: Boolean, unknownDate: List<TimelineMoment> = emptyList(), modifier: Modifier = Modifier,
) {
    val entries = remember(days, showMonthHeaders, unknownDate) { timelineWaterfallEntries(days, showMonthHeaders, unknownDate) }
    val firstKey = entries.firstOrNull()?.key
    val state = rememberLazyStaggeredGridState()
    var appliedFilterKey by rememberSaveable { mutableStateOf(resetKey) }
    LaunchedEffect(resetKey) {
        if (appliedFilterKey != resetKey) {
            state.scrollToItem(0)
            appliedFilterKey = resetKey
        }
    }
    BoxWithConstraints(modifier.fillMaxWidth().clipToBounds()) {
        val density = LocalDensity.current
        val headerHeights = remember(maxWidth, density.density, density.fontScale) { mutableStateMapOf<LocalDate, Int>() }
        val monthHeights = remember(maxWidth, density.density, density.fontScale) { mutableStateMapOf<YearMonth, Int>() }
        val fallbackHeight = with(density) { 44.dp.roundToPx() }
        val fallbackMonthHeight = with(density) { 44.dp.roundToPx() }
        // Staggered grids have no stickyHeader API. Pin the month title that scrolled away,
        // keep the current day row under it, and let the next header of the same kind push it off.
        val pinned by remember(entries, state, headerHeights, monthHeights) {
            derivedStateOf {
                timelineStickyPins(
                    entries,
                    state.layoutInfo.visibleItemsInfo.map { TimelineVisibleItem(it.index, it.offset.y, it.size.height) },
                    headerHeights,
                    monthHeights,
                    fallbackHeight,
                    fallbackMonthHeight,
                )
            }
        }
        val columns = if (density.fontScale >= 1.8f || (maxWidth < 360.dp && density.fontScale >= 1.3f)) 1 else 2
        LazyVerticalStaggeredGrid(
            columns = StaggeredGridCells.Fixed(columns), state = state,
            modifier = Modifier.fillMaxSize().testTag("timelineWaterfall"),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalItemSpacing = 0.dp,
            contentPadding = PaddingValues(start = DesignTokens.Spacing.m, end = DesignTokens.Spacing.m, bottom = DesignTokens.Spacing.m),
        ) {
            items(entries, key = { it.key }, span = { if (it.fullSpan) StaggeredGridItemSpan.FullLine else StaggeredGridItemSpan.SingleLane },
                contentType = {
                    when (it) {
                        is TimelineWaterfallEntry.MonthHeader -> "month"
                        is TimelineWaterfallEntry.DayHeader -> "day"
                        is TimelineWaterfallEntry.UnknownDateHeader -> "unknownDate"
                        is TimelineWaterfallEntry.MomentCard -> if (it.moment.isNote) "note" else "media"
                    }
                }) { entry ->
                when (entry) {
                    is TimelineWaterfallEntry.MonthHeader -> Column(Modifier.padding(
                        top = if (entry.key == firstKey) 0.dp else 12.dp, bottom = 4.dp)) {
                        TimelineMonthHeader(entry.month, Modifier.onSizeChanged { monthHeights[entry.month] = it.height }
                            .testTag("timelineMonth-${entry.month}"))
                    }
                    is TimelineWaterfallEntry.DayHeader -> Column(Modifier.padding(
                        top = if (days.firstOrNull()?.date == entry.date) 0.dp else 12.dp, bottom = 12.dp)) {
                        TimelineDayHeader(entry.day, today, Modifier.onSizeChanged { headerHeights[entry.date] = it.height }
                            .testTag("timelineDay-${entry.date}"))
                    }
                    is TimelineWaterfallEntry.UnknownDateHeader -> Column(Modifier.padding(
                        top = if (entry.key == firstKey) 0.dp else 12.dp, bottom = 12.dp)) {
                        TimelineUnknownDateHeader(entry.count, Modifier.testTag("timelineUnknownDate"))
                    }
                    is TimelineWaterfallEntry.MomentCard -> TimelineMomentCard(entry.moment, mediaRoot, zone, onOpenMoment,
                        parentOf(entry.moment.id), Modifier.padding(bottom = 16.dp))
                }
            }
        }
        val pins = pinned
        pins.day?.let { day ->
            val offset = pins.dayOffset
            TimelineDayHeader(day, today, Modifier.offset { IntOffset(0, offset) }.zIndex(0f)
                .fillMaxWidth().background(DesignTokens.Colors.bg).padding(horizontal = DesignTokens.Spacing.m)
                .heightIn(min = with(density) { (headerHeights[day.date] ?: fallbackHeight).toDp() })
                .onSizeChanged { headerHeights[day.date] = it.height }
                .testTag("timelineStickyDay").clearAndSetSemantics { })
        }
        pins.month?.let { month ->
            val offset = pins.monthOffset
            TimelineMonthHeader(month, Modifier.offset { IntOffset(0, offset) }.zIndex(1f)
                .fillMaxWidth().background(DesignTokens.Colors.bg).padding(horizontal = DesignTokens.Spacing.m)
                .heightIn(min = with(density) { (monthHeights[month] ?: fallbackMonthHeight).toDp() })
                .onSizeChanged { monthHeights[month] = it.height }
                .testTag("timelineStickyMonth").clearAndSetSemantics { })
        }
    }
}

@Composable
private fun TimelineMonthHeader(month: YearMonth, modifier: Modifier = Modifier) {
    Text(timelineMonthLabel(month), modifier.fillMaxWidth().heightIn(min = 44.dp)
        .background(DesignTokens.Colors.bg).padding(vertical = 8.dp),
        color = DesignTokens.Colors.ink, fontSize = DesignTokens.Typography.headlineSize,
        lineHeight = DesignTokens.Typography.headlineLineHeight, fontWeight = DesignTokens.Typography.headlineWeight)
}

@Composable
private fun TimelineUnknownDateHeader(count: Int, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().heightIn(min = 44.dp).background(DesignTokens.Colors.bg).padding(vertical = 8.dp)
        .semantics(mergeDescendants = true) { heading() },
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(UNKNOWN_DATE_SECTION_TITLE, Modifier.weight(1f), color = DesignTokens.Colors.ink,
            fontSize = DesignTokens.Typography.headlineSize, lineHeight = DesignTokens.Typography.headlineLineHeight,
            fontWeight = DesignTokens.Typography.headlineWeight)
        Text("${count}条", color = DesignTokens.Colors.inkSecondary, fontSize = DesignTokens.Typography.metaSize,
            lineHeight = DesignTokens.Typography.metaLineHeight, fontWeight = DesignTokens.Typography.metaWeight)
    }
}

@Composable
private fun TimelineDayHeader(day: TimelineDay, today: LocalDate, modifier: Modifier = Modifier) {
    val label = jinbaoDateHeader(day.date)
    Row(modifier.fillMaxWidth().heightIn(min = 44.dp).background(DesignTokens.Colors.bg).padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = DesignTokens.Colors.ink,
            fontSize = 15.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.weight(1f))
        Text("${day.moments.size}条",
            color = DesignTokens.Colors.inkSecondary, fontSize = DesignTokens.Typography.metaSize,
                lineHeight = DesignTokens.Typography.metaLineHeight, fontWeight = DesignTokens.Typography.metaWeight)
    }
}

@Composable
internal fun TimelineMomentCard(
    moment: TimelineMoment, mediaRoot: File, zone: ZoneId = ZoneId.systemDefault(), onOpenMoment: (String) -> Unit,
    parent: ParentIdentity? = null, modifier: Modifier = Modifier,
) {
    val open = Modifier.fillMaxWidth().clickable(role = Role.Button, onClickLabel = "打开记录") { onOpenMoment(moment.id) }
        .testTag("momentCard-${moment.id}")
    if (moment.isNote) {
        Column(modifier) {
        Column(Modifier.fillMaxWidth().clip(TimelinePhotoShape).background(DesignTokens.Colors.surface).then(open).padding(14.dp)) {
            val title = moment.title.trim()
            val note = moment.note.trim()
            if (title.isNotEmpty()) Text(title, color = DesignTokens.Colors.ink, fontSize = 15.sp, lineHeight = 21.sp,
                fontWeight = FontWeight.Bold)
            if (note.isNotEmpty()) Text(note, Modifier.padding(top = if (title.isNotEmpty()) 6.dp else 0.dp),
                color = TimelineNoteInk, fontSize = 14.sp, lineHeight = 22.sp, maxLines = NOTE_CARD_MAX_LINES,
                overflow = TextOverflow.Ellipsis)
            else if (title.isEmpty()) Text("值得留住的小日常", color = TimelineNoteInk, fontSize = 14.sp, lineHeight = 22.sp)
            MomentMeta(parent, moment, zone, Modifier.padding(top = 10.dp))
        }
        }
    } else Column(modifier) {
        Column(open) {
        val media = moment.media.first()
        val duration = if (media.kind == "video") rememberVideoDuration(media.original, mediaRoot) else null
        val live = media.kind == "motionPhoto" || media.kind == "livePhoto"
        Box(Modifier.fillMaxWidth().clip(TimelinePhotoShape)) {
            LocalMedia(media.preview, mediaRoot, Modifier.fillMaxWidth(), contentDescription = moment.displayTitle)
            if (moment.media.size > 1) {
                CardBadge(Modifier.align(Alignment.TopEnd).padding(DesignTokens.Spacing.s)) {
                    Icon(Icons.Outlined.Collections, null, modifier = Modifier.size(13.dp))
                    Text(moment.media.size.toString(), fontSize = DesignTokens.Typography.metaSize)
                }
            }
            if (media.kind == "video" || live) {
                CardBadge(Modifier.align(Alignment.BottomStart).padding(DesignTokens.Spacing.s)) {
                    Icon(Icons.Outlined.PlayArrow, if (live) "实况" else "视频", modifier = Modifier.size(14.dp))
                    Text(if (live) "实况" else duration ?: "视频", fontSize = DesignTokens.Typography.metaSize)
                }
            }
        }
        val title = moment.title.trim()
        if (title.isNotEmpty()) Text(title, Modifier.padding(top = 8.dp), color = DesignTokens.Colors.ink,
            fontSize = 15.sp, lineHeight = 21.sp, fontWeight = FontWeight.Medium, maxLines = 2, overflow = TextOverflow.Ellipsis)
        MomentMeta(parent, moment, zone, Modifier.padding(top = if (title.isNotEmpty()) 6.dp else 8.dp))
        }
    }
}

@Composable
private fun MomentMeta(parent: ParentIdentity?, moment: TimelineMoment, zone: ZoneId, modifier: Modifier = Modifier) {
    FlowRow(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp), itemVerticalAlignment = Alignment.CenterVertically) {
        parent?.let { TimelineParentBadge(it) }
        Text(timelineCardTimeLabel(moment.occurredAtMillis, zone),
            color = DesignTokens.Colors.inkSecondary, fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Normal)
    }
}

@Composable
private fun CardBadge(modifier: Modifier, content: @Composable RowScope.() -> Unit) {
    Surface(modifier, color = DesignTokens.Colors.onPhoto, contentColor = Color.White,
        shape = RoundedCornerShape(DesignTokens.Radius.full)) {
        Row(Modifier.padding(horizontal = DesignTokens.Spacing.s, vertical = DesignTokens.Spacing.xs),
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs), verticalAlignment = Alignment.CenterVertically,
            content = content)
    }
}
