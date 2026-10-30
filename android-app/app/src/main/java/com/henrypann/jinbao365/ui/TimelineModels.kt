package com.henrypann.jinbao365.ui

import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.archive.MediaResource
import com.henrypann.jinbao365.archive.jsonStringList
import com.henrypann.jinbao365.editing.momentDraft
import java.time.Instant
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

internal const val NOTE_CARD_MAX_LINES = 4
internal const val DEFAULT_MEDIA_ASPECT_RATIO = 1.25f

/** Matches iOS: a record time at or before the epoch is unknown, never "1970年1月1日". */
internal fun isKnownRecordTime(millis: Long): Boolean = millis > 0L

/** Sort key for cards in the unknown-date section; it is never formatted as a date. */
internal val UNKNOWN_RECORD_DATE: LocalDate = LocalDate.MIN

internal data class TimelineDay(val date: LocalDate, val moments: List<TimelineMoment>)

internal data class TimelineMoment(
    val id: String,
    val title: String,
    val note: String,
    val occurredAtMillis: Long,
    val media: List<TimelineMedia>,
) {
    val displayTitle: String get() = title.takeIf { it.isNotBlank() } ?: "值得留住的小日常"
    val isNote: Boolean get() = media.isEmpty()
}

internal data class TimelineMedia(
    val assetId: String,
    val kind: String,
    val preview: MediaResource?,
    val original: MediaResource?,
)

internal enum class TimelineEmptyState { Writable, ReadOnly, Filtered }

internal data class TimelineModel(
    val days: List<TimelineDay>,
    val emptyState: TimelineEmptyState?,
    val unknownDate: List<TimelineMoment> = emptyList(),
) {
    val recordCount: Int get() = days.sumOf { it.moments.size } + unknownDate.size
}

/** One ordered stream for both staggered-grid lanes; days alone span both columns. */
internal sealed interface TimelineWaterfallEntry {
    val date: LocalDate
    val key: String
    val fullSpan: Boolean

    data class MonthHeader(val month: YearMonth) : TimelineWaterfallEntry {
        override val date: LocalDate get() = month.atDay(1)
        override val key: String get() = "month-$month"
        override val fullSpan: Boolean get() = true
    }

    data class DayHeader(val day: TimelineDay) : TimelineWaterfallEntry {
        override val date: LocalDate get() = day.date
        override val key: String get() = "day-${day.date}"
        override val fullSpan: Boolean get() = true
    }

    data class MomentCard(override val date: LocalDate, val moment: TimelineMoment) : TimelineWaterfallEntry {
        override val key: String get() = "moment-${moment.id}"
        override val fullSpan: Boolean get() = false
    }

    /** Last section, after every dated month; its cards carry [UNKNOWN_RECORD_DATE]. */
    data class UnknownDateHeader(val count: Int) : TimelineWaterfallEntry {
        override val date: LocalDate get() = UNKNOWN_RECORD_DATE
        override val key: String get() = "unknown-date"
        override val fullSpan: Boolean get() = true
    }
}

internal const val UNKNOWN_DATE_SECTION_TITLE = "日期未知"

internal fun timelineCardTimeLabel(millis: Long, zone: ZoneId): String =
    if (!isKnownRecordTime(millis)) "时间未知"
    else Instant.ofEpochMilli(millis).atZone(zone).format(DateTimeFormatter.ofPattern("HH:mm", Locale.CHINA))

/** Four-digit year, even for adjacent months in the same year: `2026年10月`. */
internal fun timelineMonthLabel(month: YearMonth): String = "${month.year}年${month.monthValue}月"

internal fun timelineWaterfallEntries(
    days: List<TimelineDay>,
    includeMonthHeaders: Boolean = true,
    unknownDate: List<TimelineMoment> = emptyList(),
): List<TimelineWaterfallEntry> = buildList {
    var previousMonth: YearMonth? = null
    days.forEach { day ->
        val month = YearMonth.from(day.date)
        if (includeMonthHeaders && month != previousMonth) {
            add(TimelineWaterfallEntry.MonthHeader(month))
            previousMonth = month
        }
        add(TimelineWaterfallEntry.DayHeader(day))
        day.moments.forEach { add(TimelineWaterfallEntry.MomentCard(day.date, it)) }
    }
    if (unknownDate.isNotEmpty()) {
        add(TimelineWaterfallEntry.UnknownDateHeader(unknownDate.size))
        unknownDate.forEach { add(TimelineWaterfallEntry.MomentCard(UNKNOWN_RECORD_DATE, it)) }
    }
}

private fun TimelineWaterfallEntry.isUnknownDateSection(): Boolean = date == UNKNOWN_RECORD_DATE

internal data class TimelineVisibleItem(val index: Int, val y: Int, val height: Int)

internal data class TimelineStickyPins(
    val month: YearMonth? = null,
    val monthOffset: Int = 0,
    val day: TimelineDay? = null,
    val dayOffset: Int = 0,
)

/** Pins the month title that has scrolled off, and keeps the day row beneath it. */
internal fun timelineStickyPins(
    entries: List<TimelineWaterfallEntry>,
    visible: List<TimelineVisibleItem>,
    dayHeights: Map<LocalDate, Int>,
    monthHeights: Map<YearMonth, Int>,
    fallbackDayHeight: Int,
    fallbackMonthHeight: Int,
): TimelineStickyPins {
    val first = visible.filter { it.y + it.height > 0 }.minByOrNull { it.index } ?: return TimelineStickyPins()
    val active = entries.getOrNull(first.index) ?: return TimelineStickyPins()
    if (active.isUnknownDateSection()) return TimelineStickyPins()
    fun isSectionBoundary(index: Int, kind: Class<out TimelineWaterfallEntry>): Boolean =
        entries.getOrNull(index).let { kind.isInstance(it) || it is TimelineWaterfallEntry.UnknownDateHeader }
    val activeMonth = when (active) {
        is TimelineWaterfallEntry.MonthHeader -> active.month
        else -> YearMonth.from(active.date)
    }
    val monthIndex = entries.indexOfFirst { it is TimelineWaterfallEntry.MonthHeader && it.month == activeMonth }
    val monthHeight = monthHeights[activeMonth] ?: fallbackMonthHeight
    val monthItem = visible.firstOrNull { it.index == monthIndex }
    val monthPinned = monthIndex >= 0 && (monthItem == null || monthItem.y < 0)
    val nextMonthY = if (!monthPinned) null else visible.filter { item ->
        item.index > monthIndex && isSectionBoundary(item.index, TimelineWaterfallEntry.MonthHeader::class.java)
    }.minOfOrNull { it.y }
    val monthOffset = if (!monthPinned) 0 else minOf(0, (nextMonthY ?: Int.MAX_VALUE) - monthHeight)
    val monthOccupied = if (!monthPinned) 0 else (monthHeight + monthOffset).coerceAtLeast(0)

    val activeDay = when (active) {
        is TimelineWaterfallEntry.MonthHeader ->
            entries.asSequence().drop(first.index + 1).filterIsInstance<TimelineWaterfallEntry.DayHeader>().firstOrNull()?.date
        else -> active.date
    }
    val dayIndex = if (activeDay == null) -1 else entries.indexOfFirst {
        it is TimelineWaterfallEntry.DayHeader && it.date == activeDay
    }
    val dayHeader = entries.getOrNull(dayIndex) as? TimelineWaterfallEntry.DayHeader
    val dayHeight = if (activeDay == null) fallbackDayHeight else dayHeights[activeDay] ?: fallbackDayHeight
    val dayItem = visible.firstOrNull { it.index == dayIndex }
    val dayPinned = dayHeader != null && (dayItem == null || dayItem.y < monthOccupied)
    val nextDayY = if (!dayPinned) null else visible.filter { item ->
        item.index > dayIndex && isSectionBoundary(item.index, TimelineWaterfallEntry.DayHeader::class.java)
    }.minOfOrNull { it.y }
    val dayOffset = if (!dayPinned) 0 else minOf(monthOccupied, (nextDayY ?: Int.MAX_VALUE) - dayHeight)
    return TimelineStickyPins(
        month = if (monthPinned) activeMonth else null,
        monthOffset = monthOffset,
        day = if (dayPinned) dayHeader.day else null,
        dayOffset = dayOffset,
    )
}

/** Height / width, matching the iOS 4:3 landscape through 2:3 portrait crop. */
internal fun clampAspectRatio(ratio: Float): Float =
    if (!ratio.isFinite() || ratio <= 0f) DEFAULT_MEDIA_ASPECT_RATIO else ratio.coerceIn(0.75f, 1.5f)

internal fun noteCardText(title: String, note: String): String =
    listOf(title.trim(), note.trim()).filter { it.isNotEmpty() }.joinToString("\n")
        .ifEmpty { "值得留住的小日常" }

/** A view projection; selection order and all stored fields remain untouched. */
internal fun timelineModel(
    snapshot: ArchiveSnapshot,
    readOnly: Boolean = false,
    zoneId: ZoneId = ZoneId.systemDefault(),
    search: String = "",
    month: YearMonth? = null,
): TimelineModel {
    val assets = snapshot.assets.associateBy { it.id }
    val resources = snapshot.resources.associateBy { it.id }
    val query = search.trim()
    val live = snapshot.records.filter { it.tombstone.isNullValue() }
    val scope = live.filter { record ->
        val millis = momentDraft(record).occurredAtMillis
        month == null || (isKnownRecordTime(millis) && YearMonth.from(Instant.ofEpochMilli(millis).atZone(zoneId)) == month)
    }
    val moments = scope.mapNotNull { record ->
        val draft = momentDraft(record)
        if (query.isNotEmpty() && !draft.title.contains(query, ignoreCase = true) &&
            !draft.note.contains(query, ignoreCase = true)) return@mapNotNull null
        TimelineMoment(
            id = record.id,
            title = draft.title,
            note = draft.note,
            occurredAtMillis = draft.occurredAtMillis,
            media = jsonStringList(record.assetIds.value).map { id ->
                val asset = assets[id]
                val owned = asset?.resourceIds.orEmpty().mapNotNull(resources::get).filter { it.assetID == id }
                TimelineMedia(
                    assetId = id,
                    kind = asset?.kind ?: "photo",
                    preview = owned.firstOrNull { it.role == "preview" }
                        ?: owned.firstOrNull { it.contentType.startsWith("image/") },
                    original = owned.firstOrNull { it.role != "preview" },
                )
            },
        )
    }.sortedWith(compareByDescending<TimelineMoment> { it.occurredAtMillis }.thenBy { it.id })
    val (dated, unknownDate) = moments.partition { isKnownRecordTime(it.occurredAtMillis) }
    val days = dated.groupBy { Instant.ofEpochMilli(it.occurredAtMillis).atZone(zoneId).toLocalDate() }
        .toSortedMap(reverseOrder()).map { (date, entries) -> TimelineDay(date, entries) }
    return TimelineModel(
        days = days,
        unknownDate = unknownDate.sortedBy { it.id },
        emptyState = when {
            days.isNotEmpty() || unknownDate.isNotEmpty() -> null
            scope.isNotEmpty() && query.isNotEmpty() -> TimelineEmptyState.Filtered
            readOnly -> TimelineEmptyState.ReadOnly
            else -> TimelineEmptyState.Writable
        },
    )
}

internal fun ownedPreviewResource(assetId: String?, snapshot: ArchiveSnapshot): MediaResource? {
    val asset = snapshot.assets.firstOrNull { it.id == assetId } ?: return null
    val resources = snapshot.resources.filter { it.id in asset.resourceIds && it.assetID == asset.id }
    return resources.firstOrNull { it.role == "preview" }
        ?: resources.firstOrNull { it.contentType.startsWith("image/") }
}

internal fun videoDurationLabel(durationMillis: Long): String {
    val seconds = (durationMillis / 1_000L).coerceAtLeast(0L)
    val hours = seconds / 3_600L
    val minutes = (seconds % 3_600L) / 60L
    return if (hours > 0) String.format(Locale.ROOT, "%d:%02d:%02d", hours, minutes, seconds % 60L)
    else String.format(Locale.ROOT, "%d:%02d", minutes, seconds % 60L)
}
