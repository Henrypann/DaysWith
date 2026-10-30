package com.henrypann.jinbao365.ui

import com.henrypann.jinbao365.archive.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.YearMonth
import java.time.ZoneId

class ReviewModelsTest {
    private val utc = ZoneId.of("UTC")

    @Test fun emptyAndDeletedArchivesHaveNoInventedMonths() {
        assertTrue(reviewMonths(ArchiveSnapshot.empty(), utc).isEmpty())
        assertTrue(reviewMonths(ArchiveSnapshot.empty().copy(records = listOf(record("deleted", "2026-10-01T00:00:00Z", deleted = true))), utc).isEmpty())
    }

    @Test fun monthsFollowViewerTimezoneAndSortAcrossYears() {
        val snapshot = ArchiveSnapshot.empty().copy(records = listOf(
            record("old", "2025-01-01T00:00:00Z"), record("boundary", "2025-12-31T17:00:00Z"),
            record("last", "2025-12-31T10:00:00Z"), record("deleted", "2027-01-01T00:00:00Z", deleted = true)))
        val before = ArchiveJson.canonical(snapshot)
        val months = reviewMonths(snapshot, ZoneId.of("Asia/Shanghai"))
        assertEquals(listOf(YearMonth.of(2026, 1), YearMonth.of(2025, 12), YearMonth.of(2025, 1)), months.map { it.month })
        assertEquals(listOf("boundary", "last", "old"), months.flatMap { it.moments }.map { it.id })
        assertEquals(YearMonth.of(2025, 12), reviewMonths(snapshot, utc).first().month)
        assertEquals(before, ArchiveJson.canonical(snapshot))
    }

    @Test fun countsUseDistinctVisibleAssetsAndKeepPhotoVideoAndNotes() {
        val snapshot = ArchiveSnapshot.empty().copy(records = listOf(
            record("dad", "2026-10-03T10:00:00Z", listOf("photo", "video")),
            record("mom", "2026-10-02T10:00:00Z", listOf("photo")),
            record("note", "2026-10-01T10:00:00Z"),
            record("deleted", "2026-10-04T10:00:00Z", listOf("unused"), deleted = true)),
            assets = listOf(asset("photo", "photo"), asset("video", "video"), asset("unused", "photo")))
        val month = reviewMonths(snapshot, utc).single()
        assertEquals(3, month.recordCount)
        assertEquals(1, month.photoCount)
        assertEquals(1, month.videoCount)
        assertEquals("3条记录 · 1张照片 · 1段视频", month.summary)
        assertEquals(listOf("dad", "mom", "note"), month.moments.map { it.id })
    }

    @Test fun leapDayAndSameTimestampKeepStableOrder() {
        val snapshot = ArchiveSnapshot.empty().copy(records = listOf(
            record("z", "2024-02-29T23:00:00Z"), record("a", "2024-02-29T23:00:00Z"), record("b", "2024-03-01T00:00:00Z")))
        val months = reviewMonths(snapshot, utc)
        assertEquals(listOf("b", "a", "z"), months.flatMap { it.moments }.map { it.id })
        assertEquals("2024年2月", months.last().label)
    }

    private fun field(value: JsonElement) = FieldEnvelope(value, EditStamp(1, 100, "test"))
    private fun record(id: String, time: String, assets: List<String> = emptyList(), deleted: Boolean = false) = ArchiveRecord(
        id, field(JsonPrimitive(id)), field(JsonPrimitive("记录")),
        field(JsonObject(mapOf("utc" to JsonPrimitive(Instant.parse(time).toEpochMilli())))), field(JsonPrimitive(100)),
        field(JsonArray(assets.map(::JsonPrimitive))), field(if (deleted) JsonObject(mapOf("deletedAt" to JsonPrimitive(100))) else JsonNull), emptyMap())
    private fun asset(id: String, kind: String) = MediaAsset(id, kind, field(JsonNull), emptyList(), emptyMap())
}
