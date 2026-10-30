package com.henrypann.jinbao365.media

import com.henrypann.jinbao365.archive.isProtocolTimeZone
import com.henrypann.jinbao365.archive.isProtocolUtcOffset
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.longOrNull
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeFormatterBuilder
import java.time.format.DateTimeParseException
import java.time.format.ResolverStyle
import java.time.temporal.ChronoField

/**
 * Capture time is one of three forms. An offset is not stored in `timeZone`.
 * A container date that is only UTC does not claim the zone is Z.
 */
object CaptureTime {
    private val EXIF_LOCAL = DateTimeFormatter.ofPattern("uuuu:MM:dd HH:mm:ss")
        .withResolverStyle(ResolverStyle.STRICT)
    private val VIDEO_FORMATS = listOf("+HH:MM", "+HHMM", "+HH").map { pattern ->
        DateTimeFormatterBuilder()
            .appendPattern("uuuuMMdd'T'HHmmss")
            .optionalStart()
            .appendFraction(ChronoField.NANO_OF_SECOND, 1, 9, true)
            .optionalEnd()
            .appendOffset(pattern, "Z")
            .toFormatter()
            .withResolverStyle(ResolverStyle.STRICT)
    }

    fun fromExif(dateTime: String?, offset: String?, subSec: String? = null): JsonObject {
        if (dateTime.isNullOrBlank() || offset.isNullOrBlank()) return unknown()
        return try {
            val local = LocalDateTime.parse(dateTime.trim(), EXIF_LOCAL)
            val zone = ZoneOffset.of(normalizeOffset(offset.trim()))
            val utc = local.toInstant(zone).toEpochMilli() + subSecondMillis(subSec)
            if (isAfterCaptureFloor(utc)) offsetKnown(utc, zone.id) else unknown()
        } catch (_: DateTimeParseException) {
            unknown()
        } catch (_: java.time.DateTimeException) {
            unknown()
        }
    }

    /**
     * Container dates that end in Z are a UTC instant with no shooting zone.
     * An explicit numeric offset is stored as utcOffset. Instants before the
     * capture floor are unknown. Milliseconds in the container timestamp are kept.
     */
    fun fromVideoMetadata(raw: String?): JsonObject {
        if (raw.isNullOrBlank()) return unknown()
        val text = raw.trim()
        val instant = parseVideo(text) ?: return unknown()
        val utc = instant.toInstant().toEpochMilli()
        if (!isAfterCaptureFloor(utc)) return unknown()
        val offset = instant.offset
        if (offset == ZoneOffset.UTC && text.endsWith("Z", ignoreCase = true)) {
            return zoneUnknown(utc)
        }
        return offsetKnown(utc, offset.id)
    }

    fun iana(utc: Long, timeZone: String): JsonObject {
        if (!isProtocolTimeZone(timeZone)) return unknown()
        return JsonObject(
            mapOf(
                "timeUnknown" to JsonPrimitive(false),
                "utc" to JsonPrimitive(utc),
                "timeZone" to JsonPrimitive(timeZone),
            ),
        )
    }

    fun unknown(): JsonObject = JsonObject(mapOf("timeUnknown" to JsonPrimitive(true)))

    fun zoneUnknown(utc: Long): JsonObject = JsonObject(
        mapOf(
            "timeUnknown" to JsonPrimitive(false),
            "utc" to JsonPrimitive(utc),
            "zoneUnknown" to JsonPrimitive(true),
        ),
    )

    fun offsetKnown(utc: Long, utcOffset: String): JsonObject {
        val offset = normalizeOffset(utcOffset.trim())
        if (!isProtocolUtcOffset(offset)) return unknown()
        return JsonObject(
            mapOf(
                "timeUnknown" to JsonPrimitive(false),
                "utc" to JsonPrimitive(utc),
                "utcOffset" to JsonPrimitive(offset),
            ),
        )
    }

    /** Read stored metadata using only the fixed floor, independent of the reading device's clock. */
    fun atRead(capture: JsonObject): JsonObject {
        val timeUnknown = (capture["timeUnknown"] as? JsonPrimitive)?.booleanOrNull == true
        val utc = (capture["utc"] as? JsonPrimitive)?.longOrNull
        return if (timeUnknown || utc == null || !isAfterCaptureFloor(utc)) unknown() else capture
    }

    /** Apply the moving future limit once, when capture metadata enters the archive. */
    fun atImport(capture: JsonObject, nowMillis: Long): JsonObject {
        val accepted = atRead(capture)
        val utc = (accepted["utc"] as? JsonPrimitive)?.longOrNull ?: return unknown()
        return if (isNotFutureAtImport(utc, nowMillis)) accepted else unknown()
    }

    /** Record time. Only the fixed floor applies when deriving time from stored captures. */
    fun occurredAt(capture: JsonObject, nowMillis: Long): JsonObject {
        val unknown = (capture["timeUnknown"] as? JsonPrimitive)?.booleanOrNull == true
        val utc = (capture["utc"] as? JsonPrimitive)?.longOrNull
        if (unknown || utc == null || !isAfterCaptureFloor(utc)) {
            return JsonObject(
                mapOf(
                    "utc" to JsonPrimitive(nowMillis),
                    "zoneUnknown" to JsonPrimitive(true),
                    "estimated" to JsonPrimitive(true),
                ),
            )
        }
        val map = linkedMapOf<String, kotlinx.serialization.json.JsonElement>(
            "utc" to capture.getValue("utc"),
        )
        capture["timeZone"]?.let { map["timeZone"] = it }
        capture["utcOffset"]?.let { map["utcOffset"] = it }
        capture["zoneUnknown"]?.let { map["zoneUnknown"] = it }
        return JsonObject(map)
    }

    private fun parseVideo(text: String): java.time.OffsetDateTime? {
        for (format in VIDEO_FORMATS) {
            try {
                return java.time.OffsetDateTime.parse(text, format)
            } catch (_: DateTimeParseException) {
                continue
            }
        }
        return null
    }

    private fun subSecondMillis(subSec: String?): Int {
        if (subSec.isNullOrBlank()) return 0
        val digits = subSec.trim()
        if (digits.isEmpty() || digits.any { it !in '0'..'9' }) return 0
        return digits.take(3).padEnd(3, '0').toInt()
    }

    private fun normalizeOffset(offset: String): String {
        if (offset == "Z" || offset == "z") return "Z"
        if (offset.length == 5 && (offset[0] == '+' || offset[0] == '-')) {
            return offset.substring(0, 3) + ":" + offset.substring(3)
        }
        return offset
    }
}

/** Fixed, inclusive lower bound shared by import and stored capture derivation. */
internal fun isAfterCaptureFloor(utc: Long): Boolean = utc >= 315_619_200_000L

/** Import-only upper bound; adding a day must not wrap near Long.MAX_VALUE. */
internal fun isNotFutureAtImport(utc: Long, nowMillis: Long): Boolean =
    nowMillis > Long.MAX_VALUE - 86_400_000L || utc <= nowMillis + 86_400_000L
