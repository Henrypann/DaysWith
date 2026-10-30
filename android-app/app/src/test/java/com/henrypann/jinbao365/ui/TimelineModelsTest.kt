package com.henrypann.jinbao365.ui

import com.henrypann.jinbao365.archive.ArchiveRecord
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.archive.EditStamp
import com.henrypann.jinbao365.archive.FieldEnvelope
import com.henrypann.jinbao365.archive.MediaAsset
import com.henrypann.jinbao365.archive.MediaResource
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneId

class TimelineModelsTest {
    private val utc = ZoneId.of("UTC")

    @Test fun aspectClampKeepsSupportedCropsAndRejectsInvalidDimensions() {
        assertEquals(0.75f, clampAspectRatio(0.2f), 0f)
        assertEquals(1.5f, clampAspectRatio(4f), 0f)
        assertEquals(1.1f, clampAspectRatio(1.1f), 0f)
        listOf(0f, -1f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY).forEach {
            assertEquals(DEFAULT_MEDIA_ASPECT_RATIO, clampAspectRatio(it), 0f)
        }
    }

    @Test fun searchMatchesOnlyLiveTitleOrNoteWithoutChangingTheSnapshot() {
        val snapshot = snapshot(listOf(
            record("title", "2026-10-11T12:00:00Z", title = "Orange coat"),
            record("note", "2026-10-11T11:00:00Z", note = "An ORANGE afternoon"),
            record("orange-id", "2026-10-11T10:00:00Z", title = "Unrelated"),
            record("trashed", "2026-10-11T09:00:00Z", title = "Orange", trashed = true),
        ))
        val before = snapshot.copy()
        val result = timelineModel(snapshot, search = "  oRaNgE  ", zoneId = utc)
        assertEquals(listOf("title", "note"), result.days.flatMap { it.moments }.map { it.id })
        assertEquals(before, snapshot)
        assertEquals(TimelineEmptyState.Filtered, timelineModel(snapshot, search = "missing", zoneId = utc).emptyState)
        assertEquals(3, timelineModel(snapshot, search = " \t ", zoneId = utc).days.single().moments.size)
    }

    @Test fun waterfallKeepsPhotosAndNotesInterleavedInOneOrderedStreamWithFullWidthDayHeaders() {
        val snapshot = snapshot(listOf(
            record("older-note", "2026-10-10T23:00:00Z", note = "Yesterday"),
            record("b-photo", "2026-10-11T11:00:00Z", mediaIds = listOf("photo")),
            record("latest-photo", "2026-10-11T12:00:00Z", mediaIds = listOf("photo", "second")),
            record("a-note", "2026-10-11T11:00:00Z", note = "Between photographs"),
        ), listOf(media("photo"), media("second")))
        val entries = timelineWaterfallEntries(timelineModel(snapshot, zoneId = utc).days)
        assertEquals(listOf("month-2026-10", "day-2026-10-11", "moment-latest-photo", "moment-a-note", "moment-b-photo", "day-2026-10-10", "moment-older-note"), entries.map { it.key })
        assertEquals(listOf(true, true, false, false, false, true, false), entries.map { it.fullSpan })
        assertEquals("2026年10月", timelineMonthLabel((entries.first() as TimelineWaterfallEntry.MonthHeader).month))
        val cards = entries.filterIsInstance<TimelineWaterfallEntry.MomentCard>()
        assertEquals(listOf(false, true, false, true), cards.map { it.moment.isNote })
        assertEquals(listOf("photo", "second"), cards.first().moment.media.map { it.assetId })
        assertEquals(listOf(LocalDate.parse("2026-10-11"), LocalDate.parse("2026-10-10")),
            entries.filterIsInstance<TimelineWaterfallEntry.DayHeader>().map { it.date })
        assertEquals(entries.size, entries.map { it.key }.distinct().size)
    }

    @Test fun monthAndSearchFiltersComposeUsingTheViewersLocalDay() {
        val snapshot = snapshot(listOf(
            record("local-october", "2026-09-30T17:00:00Z", title = "Warm coat"),
            record("plain-note", "2026-10-01T02:00:00Z", note = "Warm day"),
            record("september", "2026-09-30T10:00:00Z", title = "Warm coat"),
        ))
        val model = timelineModel(snapshot, search = "coat", month = YearMonth.of(2026, 10), zoneId = ZoneId.of("Asia/Shanghai"))
        assertEquals(LocalDate.of(2026, 10, 1), model.days.single().date)
        assertEquals("local-october", model.days.single().moments.single().id)
    }

    @Test fun emptyStatesDistinguishViewOnlyArchiveAndLocalFilters() {
        assertEquals(TimelineEmptyState.Writable, timelineModel(ArchiveSnapshot.empty(), zoneId = utc).emptyState)
        assertEquals(TimelineEmptyState.ReadOnly, timelineModel(ArchiveSnapshot.empty(), readOnly = true, zoneId = utc).emptyState)
        val snapshot = snapshot(listOf(record("note", "2026-10-11T12:00:00Z", note = "A day")))
        assertEquals(TimelineEmptyState.Filtered, timelineModel(snapshot, search = "missing", readOnly = true, zoneId = utc).emptyState)
    }

    @Test fun monthTitlesAlwaysIncludeTheYearForAdjacentMonths() {
        assertEquals("2026年10月", timelineMonthLabel(YearMonth.of(2026, 10)))
        assertEquals("2026年9月", timelineMonthLabel(YearMonth.of(2026, 9)))
        assertEquals("2025年10月", timelineMonthLabel(YearMonth.of(2025, 10)))
        assertEquals("2024年2月", timelineMonthLabel(YearMonth.of(2024, 2)))
        val entries = timelineWaterfallEntries(listOf(
            day("2026-10-16", "oct-new"),
            day("2026-10-02", "oct-old"),
            day("2026-09-30", "sep"),
            day("2025-10-01", "last-year"),
        ))
        val months = entries.filterIsInstance<TimelineWaterfallEntry.MonthHeader>()
        assertEquals(listOf(YearMonth.of(2026, 10), YearMonth.of(2026, 9), YearMonth.of(2025, 10)), months.map { it.month })
        assertEquals(listOf("2026年10月", "2026年9月", "2025年10月"), months.map { timelineMonthLabel(it.month) })
        assertEquals(listOf(
            "month-2026-10", "day-2026-10-16", "moment-oct-new", "day-2026-10-02", "moment-oct-old",
            "month-2026-09", "day-2026-09-30", "moment-sep", "month-2025-10", "day-2025-10-01", "moment-last-year",
        ), entries.map { it.key })
        assertTrue(months.all { it.fullSpan })
        assertEquals(listOf("day-2026-10-16", "moment-oct-new"), timelineWaterfallEntries(listOf(day("2026-10-16", "oct-new")), includeMonthHeaders = false).map { it.key })
    }

    @Test fun stickyMonthTitleSitsAboveTheDayAndYieldsToTheNextMonth() {
        val entries = timelineWaterfallEntries(listOf(day("2026-10-16", "new"), day("2026-09-30", "old")))
        val heights = mapOf(LocalDate.parse("2026-10-16") to 44, LocalDate.parse("2026-09-30") to 44)
        val monthHeights = mapOf(YearMonth.of(2026, 10) to 40, YearMonth.of(2026, 9) to 40)
        val resting = timelineStickyPins(entries, listOf(TimelineVisibleItem(0, 0, 40), TimelineVisibleItem(1, 40, 44)), heights, monthHeights, 44, 40)
        assertNull(resting.month)
        assertNull(resting.day)

        val scrolled = timelineStickyPins(entries, listOf(TimelineVisibleItem(1, 0, 44), TimelineVisibleItem(2, 44, 180)), heights, monthHeights, 44, 40)
        assertEquals(YearMonth.of(2026, 10), scrolled.month)
        assertEquals(0, scrolled.monthOffset)
        assertEquals(LocalDate.parse("2026-10-16"), scrolled.day?.date)
        assertEquals(40, scrolled.dayOffset)
        assertEquals("2026年10月", timelineMonthLabel(requireNotNull(scrolled.month)))

        val pushed = timelineStickyPins(entries, listOf(TimelineVisibleItem(1, -20, 44), TimelineVisibleItem(3, 10, 40)), heights, monthHeights, 44, 40)
        assertEquals(YearMonth.of(2026, 10), pushed.month)
        assertEquals(-30, pushed.monthOffset)
        assertEquals(10, pushed.dayOffset)

        val reviewEntries = timelineWaterfallEntries(listOf(day("2026-10-16", "new"), day("2026-09-30", "old")), includeMonthHeaders = false)
        val review = timelineStickyPins(reviewEntries, listOf(TimelineVisibleItem(0, -10, 44), TimelineVisibleItem(2, 30, 44)), heights, emptyMap(), 44, 40)
        assertNull(review.month)
        assertEquals(LocalDate.parse("2026-10-16"), review.day?.date)
        assertEquals(-14, review.dayOffset)
    }

    @Test fun recordsWithoutAKnownTimeLeaveTheMonthsAndFollowThemInTheirOwnSection() {
        val snapshot = snapshot(listOf(
            record("dated", "2026-10-11T12:00:00Z", title = "Warm coat"),
            recordAt("epoch", 0L, title = "Old coat"),
            recordAt("negative", -1L, note = "From an old phone"),
            recordAt("trashed-unknown", 0L, title = "Gone", trashed = true),
        ))
        val model = timelineModel(snapshot, zoneId = utc)
        assertEquals(listOf("dated"), model.days.flatMap { it.moments }.map { it.id })
        assertEquals(listOf("epoch", "negative"), model.unknownDate.map { it.id })
        assertEquals(3, model.recordCount)
        assertTrue(model.days.none { it.date.year == 1970 || it.date.year == 1969 })
        val entries = timelineWaterfallEntries(model.days, unknownDate = model.unknownDate)
        assertEquals(listOf("month-2026-10", "day-2026-10-11", "moment-dated", "unknown-date", "moment-epoch", "moment-negative"),
            entries.map { it.key })
        assertEquals(2, (entries[3] as TimelineWaterfallEntry.UnknownDateHeader).count)
        assertTrue(entries[3].fullSpan)

        assertEquals(listOf("epoch"), timelineModel(snapshot, search = "coat", zoneId = utc).unknownDate.map { it.id })
        assertTrue(timelineModel(snapshot, month = YearMonth.of(1970, 1), zoneId = utc).unknownDate.isEmpty())
        assertEquals(TimelineEmptyState.Writable, timelineModel(snapshot, month = YearMonth.of(1970, 1), zoneId = utc).emptyState)
        val onlyUnknown = timelineModel(snapshot(listOf(recordAt("epoch", 0L, note = "A day"))), zoneId = utc)
        assertNull(onlyUnknown.emptyState)
        assertEquals(listOf("unknown-date", "moment-epoch"), timelineWaterfallEntries(onlyUnknown.days, unknownDate = onlyUnknown.unknownDate).map { it.key })
    }

    @Test fun unknownDateSectionEndsTheStickyMonthAndDayPins() {
        val entries = timelineWaterfallEntries(listOf(day("2026-10-16", "new")),
            unknownDate = listOf(TimelineMoment("unknown", "", "", 0L, emptyList())))
        assertEquals(listOf("month-2026-10", "day-2026-10-16", "moment-new", "unknown-date", "moment-unknown"), entries.map { it.key })
        val heights = mapOf(LocalDate.parse("2026-10-16") to 44)
        val monthHeights = mapOf(YearMonth.of(2026, 10) to 40)
        val pushed = timelineStickyPins(entries, listOf(TimelineVisibleItem(2, -100, 160), TimelineVisibleItem(3, 30, 44)),
            heights, monthHeights, 44, 40)
        assertEquals(YearMonth.of(2026, 10), pushed.month)
        assertEquals(-10, pushed.monthOffset)
        assertEquals(LocalDate.parse("2026-10-16"), pushed.day?.date)
        assertEquals(-14, pushed.dayOffset)
        val inside = timelineStickyPins(entries, listOf(TimelineVisibleItem(3, -10, 44), TimelineVisibleItem(4, 34, 160)),
            heights, monthHeights, 44, 40)
        assertNull(inside.month)
        assertNull(inside.day)
    }

    @Test fun unknownTimesUseTheSameWordsAsIos() {
        assertEquals("时间未知", timelineCardTimeLabel(0L, utc))
        assertEquals("时间未知", timelineCardTimeLabel(-5L, utc))
        assertEquals("12:00", timelineCardTimeLabel(Instant.parse("2026-10-11T12:00:00Z").toEpochMilli(), utc))
        assertEquals("日期与时间未知", recordDateTimeLabel(0L, utc))
        assertEquals("10月11日 12:00", recordDateTimeLabel(Instant.parse("2026-10-11T12:00:00Z").toEpochMilli(), utc))
        assertEquals("日期未知", UNKNOWN_DATE_SECTION_TITLE)
        assertEquals("2条记录的日期未知", unknownDateReviewText(2))
        val snapshot = snapshot(listOf(recordAt("epoch", 0L, title = "Old"), record("dated", "2026-10-11T12:00:00Z", title = "New")))
        assertEquals("日期与时间未知", momentDetailModel(snapshot, "epoch")?.dateTimeLabel)
        assertEquals(listOf(YearMonth.of(2026, 10)), reviewMonths(snapshot, utc).map { it.month })
        assertEquals(1, reviewMonths(snapshot, utc).single().recordCount)
    }

    @Test fun noteTextAndVideoBadgesUseCompactReadableValues() {
        assertEquals("Title\nA note", noteCardText(" Title ", " A note "))
        assertEquals("A note", noteCardText(" ", " A note "))
        assertEquals("值得留住的小日常", noteCardText(" ", "\n"))
        assertEquals(4, NOTE_CARD_MAX_LINES)
        assertEquals("0:00", videoDurationLabel(-1_000))
        assertEquals("1:05", videoDurationLabel(65_800))
        assertEquals("1:02:03", videoDurationLabel(3_723_000))
    }

    private fun day(iso: String, id: String) = TimelineDay(LocalDate.parse(iso), listOf(TimelineMoment(id, "", "", 0L, emptyList())))

    private fun field(value: JsonElement) = FieldEnvelope(value, EditStamp(1, 100, "phone"))

    private fun record(
        id: String, time: String, title: String = "", note: String = "", mediaIds: List<String> = emptyList(),
        trashed: Boolean = false,
    ) = recordAt(id, Instant.parse(time).toEpochMilli(), title, note, mediaIds, trashed)

    private fun recordAt(
        id: String, millis: Long, title: String = "", note: String = "", mediaIds: List<String> = emptyList(),
        trashed: Boolean = false,
    ) = ArchiveRecord(
        id, field(JsonPrimitive(title)), field(JsonPrimitive(note)),
        field(JsonObject(mapOf("utc" to JsonPrimitive(millis), "zoneUnknown" to JsonPrimitive(true)))),
        field(JsonPrimitive(100)), field(JsonArray(mediaIds.map(::JsonPrimitive))), field(if (trashed) JsonObject(mapOf("deletedAt" to JsonPrimitive(100))) else JsonNull), emptyMap(),
    )

    private data class MediaFixture(val asset: MediaAsset, val resource: MediaResource)

    private fun media(id: String, kind: String = "photo"): MediaFixture {
        val resource = MediaResource("preview-$id", id, "preview", "image/jpeg", "$id.jpg", 1,
            "0".repeat(64), "objects/$id", emptyMap())
        return MediaFixture(MediaAsset(id, kind, field(JsonObject(mapOf("timeUnknown" to JsonPrimitive(true)))),
            listOf(resource.id), emptyMap()), resource)
    }

    private fun snapshot(records: List<ArchiveRecord>, media: List<MediaFixture> = emptyList()) =
        ArchiveSnapshot.empty().copy(records = records, assets = media.map { it.asset }, resources = media.map { it.resource })
}
