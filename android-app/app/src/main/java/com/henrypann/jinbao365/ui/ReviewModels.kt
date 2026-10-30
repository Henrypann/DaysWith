package com.henrypann.jinbao365.ui

import com.henrypann.jinbao365.archive.ArchiveSnapshot
import java.time.YearMonth
import java.time.ZoneId

internal data class ReviewMonth(val month: YearMonth, val days: List<TimelineDay>) {
    val moments: List<TimelineMoment> get() = days.flatMap { it.moments }
    val recordCount: Int get() = moments.size
    private val media get() = moments.flatMap { it.media }.distinctBy { it.assetId }
    val photoCount: Int get() = media.count { it.kind != "video" }
    val videoCount: Int get() = media.count { it.kind == "video" }
    val label: String get() = "${month.year}年${month.monthValue}月"
    val summary: String get() = "${recordCount}条记录 · ${photoCount}张照片 · ${videoCount}段视频"
}

/** A read-only projection of the same visible, non-deleted records as the timeline. */
internal fun reviewMonths(snapshot: ArchiveSnapshot, zone: ZoneId = ZoneId.systemDefault()): List<ReviewMonth> =
    reviewMonths(timelineModel(snapshot, zoneId = zone))

internal fun reviewMonths(model: TimelineModel): List<ReviewMonth> =
    model.days.groupBy { YearMonth.from(it.date) }
        .toSortedMap(reverseOrder()).map { (month, days) -> ReviewMonth(month, days) }

/** Records without a known time are not counted in any month; review points to the timeline section. */
internal fun unknownDateReviewText(count: Int): String = "${count}条记录的日期未知"
