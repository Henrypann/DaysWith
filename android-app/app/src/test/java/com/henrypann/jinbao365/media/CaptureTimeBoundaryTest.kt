package com.henrypann.jinbao365.media

import com.henrypann.jinbao365.archive.ArchiveJson
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.time.Instant

class CaptureTimeBoundaryTest {
    @get:Rule val temp = TemporaryFolder()

    @Test
    fun exifRejectsOffsetsBeyondFourteenHoursAndProducesUnknownCapture() {
        listOf("+14:01", "-14:01", "+14:59", "-14:59", "+15:00", "-15:00", "+1401", "-1459").forEach {
            val capture = CaptureTime.fromExif("2024:06:01 12:00:00", it, "123")
            assertEquals(it, CaptureTime.unknown(), capture)
            assertImportRoundTrips(capture)
        }
    }

    @Test
    fun exifAcceptsBothFourteenHourBoundariesAndZuluWithSubseconds() {
        val cases = mapOf("+14:00" to "2024-05-31T22:00:00.123Z",
            "-14:00" to "2024-06-02T02:00:00.123Z", "Z" to "2024-06-01T12:00:00.123Z")
        cases.forEach { (offset, expected) ->
            val capture = CaptureTime.fromExif("2024:06:01 12:00:00", offset, "123")
            assertEquals(offset, capture.getValue("utcOffset").jsonPrimitive.content)
            assertEquals(Instant.parse(expected).toEpochMilli(), capture.getValue("utc").jsonPrimitive.long)
            assertImportRoundTrips(capture)
        }
        assertEquals(CaptureTime.fromExif("2024:06:01 12:00:00", "+14:00"),
            CaptureTime.fromExif("2024:06:01 12:00:00", "+1400"))
    }

    @Test
    fun videoRejectsOutOfRangeOffsetsInColonAndCompactForms() {
        listOf("+14:01", "-14:01", "+14:59", "-14:59", "+15:00", "-15:00", "+1401", "-1459", "+15", "-15").forEach {
            val capture = CaptureTime.fromVideoMetadata("20240601T120000.123$it")
            assertEquals(it, CaptureTime.unknown(), capture)
            assertImportRoundTrips(capture)
        }
    }

    @Test
    fun videoAcceptsBothFourteenHourBoundariesAndKeepsZuluZoneUnknown() {
        val positive = CaptureTime.fromVideoMetadata("20240601T120000.123+14:00")
        val negative = CaptureTime.fromVideoMetadata("20240601T120000.123-1400")
        val zulu = CaptureTime.fromVideoMetadata("20240601T120000.123Z")
        assertEquals("+14:00", positive.getValue("utcOffset").jsonPrimitive.content)
        assertEquals("-14:00", negative.getValue("utcOffset").jsonPrimitive.content)
        assertEquals(Instant.parse("2024-05-31T22:00:00.123Z").toEpochMilli(), positive.getValue("utc").jsonPrimitive.long)
        assertEquals(Instant.parse("2024-06-02T02:00:00.123Z").toEpochMilli(), negative.getValue("utc").jsonPrimitive.long)
        assertEquals(CaptureTime.zoneUnknown(Instant.parse("2024-06-01T12:00:00.123Z").toEpochMilli()), zulu)
        listOf(positive, negative, zulu).forEach(::assertImportRoundTrips)
        assertEquals(positive, CaptureTime.fromVideoMetadata("20240601T120000.123+14"))
    }

    @Test
    fun timeFactoriesCannotEmitAnInvalidZoneOrOffset() {
        listOf("Not/AZone", "UTC+08:00", "+08:00", "Z").forEach {
            assertEquals(CaptureTime.unknown(), CaptureTime.iana(10L, it))
        }
        listOf("+14:01", "-14:01", "+15:00", "-1500").forEach {
            assertEquals(CaptureTime.unknown(), CaptureTime.offsetKnown(10L, it))
        }
        val utc = Instant.parse("2024-06-01T00:00:00Z").toEpochMilli()
        listOf("Asia/Shanghai", "UTC", "GMT").forEach { assertImportRoundTrips(CaptureTime.iana(utc, it)) }
        listOf("+14:00", "-1400", "Z").forEach { assertImportRoundTrips(CaptureTime.offsetKnown(utc, it)) }
    }

    @Test
    fun aValidLeapDayKeepsItsInstantAndSubsecondsForExifAndVideo() {
        val utc = Instant.parse("2024-02-29T04:00:00.123Z").toEpochMilli()
        val exif = CaptureTime.fromExif("2024:02:29 12:00:00", "+08:00", "1234")
        val video = CaptureTime.fromVideoMetadata("20240229T120000.1234+0800")
        assertEquals(CaptureTime.offsetKnown(utc, "+08:00"), exif)
        assertEquals(exif, video)
        assertImportRoundTrips(exif)
        assertImportRoundTrips(video)
    }

    @Test
    fun invalidExifDatesAndTimesAreUnknownInsteadOfNormalized() {
        listOf("2023:02:29 12:00:00", "2024:02:30 12:00:00", "2024:04:31 12:00:00",
            "2024:00:01 12:00:00", "2024:13:01 12:00:00", "2024:06:00 12:00:00",
            "2024:06:32 12:00:00", "2024:06:01 24:00:00", "2024:06:01 12:60:00",
            "2024:06:01 12:00:60").forEach {
            val capture = CaptureTime.fromExif(it, "+08:00", "123")
            assertEquals(it, CaptureTime.unknown(), capture)
            assertImportRoundTrips(capture)
        }
    }

    @Test
    fun invalidVideoDatesAndTimesAreUnknownInEveryOffsetFormat() {
        listOf("20230229T120000", "20240230T120000", "20240431T120000", "20240001T120000",
            "20241301T120000", "20240600T120000", "20240632T120000", "20240601T240000",
            "20240601T126000", "20240601T120060").forEach { date ->
            listOf("Z", "+08:00", "+0800", "+08").forEach { offset ->
                val capture = CaptureTime.fromVideoMetadata("$date.123$offset")
                assertEquals("$date$offset", CaptureTime.unknown(), capture)
                assertImportRoundTrips(capture)
            }
        }
    }

    @Test
    fun invalidExifSubsecondsDoNotExtractDigitsOrChangeTheKnownSecond() {
        val expected = CaptureTime.fromExif("2024:06:01 12:00:00", "+08:00")
        listOf("1a2", "12x", "1.2", "-12", "+12", "1 2", "１２", "١٢", "1\u0662").forEach {
            val capture = CaptureTime.fromExif("2024:06:01 12:00:00", "+08:00", it)
            assertEquals(it, expected, capture)
            assertImportRoundTrips(capture)
        }
    }

    @Test
    fun asciiExifSubsecondsStillPadTruncateAndTrim() {
        val second = CaptureTime.fromExif("2024:06:01 12:00:00", "+08:00").getValue("utc").jsonPrimitive.long
        mapOf("1" to 100L, "12" to 120L, "123" to 123L, "1234" to 123L, " 12 \n" to 120L,
            "000" to 0L, "" to 0L, " " to 0L).forEach { (subSec, millis) ->
            val capture = CaptureTime.fromExif("2024:06:01 12:00:00", "+08:00", subSec)
            assertEquals(subSec, second + millis, capture.getValue("utc").jsonPrimitive.long)
            assertImportRoundTrips(capture)
        }
    }

    @Test
    fun exifRejectsEveryInstantBeforeTheCaptureFloorAfterApplyingItsOffset() {
        listOf(
            Triple("1970:01:01 08:00:00", "+08:00", null),
            Triple("1975:06:01 12:00:00", "+08:00", null),
            Triple("1980:01:02 07:59:59", "+08:00", "999"),
        ).forEach { (date, offset, subSec) ->
            assertEquals(date, CaptureTime.unknown(), CaptureTime.fromExif(date, offset, subSec))
        }
    }

    @Test
    fun videoRejectsEveryInstantBeforeTheCaptureFloorAfterApplyingItsOffset() {
        listOf("19750601T120000Z", "19700101T080000+0800", "19800102T075959.999+08:00").forEach {
            assertEquals(it, CaptureTime.unknown(), CaptureTime.fromVideoMetadata(it))
        }
    }

    @Test
    fun exifAndVideoAcceptTheExactCaptureFloorAcrossOffsets() {
        val floor = Instant.parse("1980-01-02T00:00:00Z").toEpochMilli()
        assertEquals(315_619_200_000L, floor)
        assertEquals(CaptureTime.offsetKnown(floor, "Z"), CaptureTime.fromExif("1980:01:02 00:00:00", "Z"))
        assertEquals(CaptureTime.offsetKnown(floor, "+08:00"), CaptureTime.fromExif("1980:01:02 08:00:00", "+08:00"))
        assertEquals(CaptureTime.offsetKnown(floor, "-08:00"), CaptureTime.fromExif("1980:01:01 16:00:00", "-08:00"))
        assertEquals(CaptureTime.zoneUnknown(floor), CaptureTime.fromVideoMetadata("19800102T000000Z"))
        assertEquals(CaptureTime.offsetKnown(floor, "+08:00"), CaptureTime.fromVideoMetadata("19800102T080000+0800"))
        assertEquals(CaptureTime.offsetKnown(floor, "-08:00"), CaptureTime.fromVideoMetadata("19800101T160000-08"))
    }

    @Test
    fun captureFloorIsInclusiveAndIndependentOfTheImportClock() {
        assertFalse(isAfterCaptureFloor(0L))
        assertFalse(isAfterCaptureFloor(315_619_199_999L))
        assertTrue(isAfterCaptureFloor(315_619_200_000L))
        assertTrue(isAfterCaptureFloor(Long.MAX_VALUE))
    }

    @Test
    fun importAcceptsExactlyOneDayAheadAndRejectsAnythingLater() {
        val now = Instant.parse("2026-10-11T00:00:00Z").toEpochMilli()
        val boundary = CaptureTime.fromExif("2026:10:12 08:00:00", "+08:00")
        val later = CaptureTime.fromVideoMetadata("20261012T000000.001Z")
        assertTrue(isNotFutureAtImport(now + 86_400_000L, now))
        assertFalse(isNotFutureAtImport(now + 86_400_001L, now))
        assertEquals(boundary, CaptureTime.atImport(boundary, now))
        assertEquals(CaptureTime.unknown(), CaptureTime.atImport(later, now))
        assertFalse("estimated" in CaptureTime.occurredAt(CaptureTime.atImport(boundary, now), now))
        assertEquals(JsonPrimitive(true), CaptureTime.occurredAt(CaptureTime.atImport(later, now), now)["estimated"])
    }

    @Test
    fun importRejectsUnknownMissingAndPreFloorCaptureTimes() {
        val now = Instant.parse("2026-10-11T00:00:00Z").toEpochMilli()
        listOf(
            CaptureTime.unknown(),
            JsonObject(mapOf("timeUnknown" to JsonPrimitive(false))),
            JsonObject(mapOf("timeUnknown" to JsonPrimitive(true), "utc" to JsonPrimitive(now))),
            CaptureTime.zoneUnknown(0L),
            CaptureTime.zoneUnknown(315_619_199_999L),
        ).forEach { assertEquals(CaptureTime.unknown(), CaptureTime.atImport(it, now)) }
        val boundary = CaptureTime.zoneUnknown(315_619_200_000L)
        assertEquals(boundary, CaptureTime.atImport(boundary, now))
    }

    @Test
    fun occurredAtKeepsTheFloorAndStoredFutureCaptureTimesRegardlessOfTheCurrentClock() {
        val now = Instant.parse("2026-10-11T00:00:00Z").toEpochMilli()
        listOf(315_619_200_000L, now + 86_400_000L, now + 2 * 86_400_000L).forEach { utc ->
            val occurred = CaptureTime.occurredAt(CaptureTime.offsetKnown(utc, "+08:00"), now)
            assertEquals(utc, occurred.getValue("utc").jsonPrimitive.long)
            assertEquals("+08:00", occurred.getValue("utcOffset").jsonPrimitive.content)
            assertFalse("estimated" in occurred)
            assertEquals(occurred, CaptureTime.occurredAt(CaptureTime.offsetKnown(utc, "+08:00"), now + 3 * 86_400_000L))
        }
    }

    @Test
    fun occurredAtEstimatesCaptureTimesBeforeTheFloor() {
        val now = Instant.parse("2026-10-11T00:00:00Z").toEpochMilli()
        val expected = JsonObject(mapOf("utc" to JsonPrimitive(now), "estimated" to JsonPrimitive(true),
            "zoneUnknown" to JsonPrimitive(true)))
        listOf(0L, 315_619_199_999L).forEach { utc ->
            assertEquals(expected, CaptureTime.occurredAt(CaptureTime.offsetKnown(utc, "+08:00"), now))
        }
    }

    @Test
    fun importFutureLimitDoesNotOverflowOrApplyTheCaptureFloor() {
        assertTrue(isNotFutureAtImport(Long.MAX_VALUE, Long.MAX_VALUE))
        assertTrue(isNotFutureAtImport(Long.MAX_VALUE, Long.MAX_VALUE - 86_400_000L))
        assertFalse(isNotFutureAtImport(Long.MAX_VALUE, Long.MAX_VALUE - 86_400_001L))
        assertTrue(isNotFutureAtImport(Long.MIN_VALUE + 86_400_000L, Long.MIN_VALUE))
        assertFalse(isNotFutureAtImport(Long.MIN_VALUE + 86_400_001L, Long.MIN_VALUE))
        assertTrue(isNotFutureAtImport(0L, 0L))
    }

    @Test
    fun readingStoredCaptureUsesOnlyTheFixedFloor() {
        val floor = 315_619_200_000L
        assertEquals(CaptureTime.unknown(), CaptureTime.atRead(CaptureTime.zoneUnknown(floor - 1)))
        listOf(floor, Long.MAX_VALUE).forEach { utc ->
            val stored = CaptureTime.zoneUnknown(utc)
            assertEquals(stored, CaptureTime.atRead(stored))
        }
        assertEquals(CaptureTime.unknown(), CaptureTime.atRead(CaptureTime.unknown()))
    }

    private fun assertImportRoundTrips(capture: JsonObject) {
        val importer = MediaImporter(temp.newFolder(), PreviewEncoder { _, _ -> "preview".toByteArray() },
            { _, _ -> false }, { _, _ -> capture })
        val prepared = importer.import(ImportRequest("photo.jpg", "image/jpeg", true, false,
            { ByteArrayInputStream("original".toByteArray()) }, null))
        val now = Instant.parse("2026-10-11T00:00:00Z").toEpochMilli()
        val snapshot = snapshotWithImport(ArchiveSnapshot.empty(), "android", now, prepared)
        assertEquals(capture, snapshot.assets.single().capturedAt.value)
        assertEquals(snapshot, ArchiveJson.parseSnapshot(ArchiveJson.canonical(snapshot)))
    }
}
