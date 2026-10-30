package com.henrypann.jinbao365.archive

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ArchiveTimeValidationTest {
    @Test
    fun zoneUnknownFalseIsRejectedWithOrWithoutAnotherZoneInBothTimeFields() {
        val alternatives = listOf(emptyMap(), mapOf("timeZone" to JsonPrimitive("Asia/Shanghai")),
            mapOf("utcOffset" to JsonPrimitive("+08:00")))
        alternatives.forEach { alternative ->
            assertInvalidInBothFields(alternative + ("zoneUnknown" to JsonPrimitive(false)))
        }
    }

    @Test
    fun zoneUnknownTrueCannotMixWithAnIanaZoneOrAnOffsetInEitherTimeField() {
        listOf(mapOf("timeZone" to JsonPrimitive("Asia/Shanghai")),
            mapOf("utcOffset" to JsonPrimitive("+08:00"))).forEach {
            assertInvalidInBothFields(it + ("zoneUnknown" to JsonPrimitive(true)))
        }
        assertInvalidInBothFields(mapOf("timeZone" to JsonPrimitive("Asia/Shanghai"),
            "utcOffset" to JsonPrimitive("+08:00")))
    }

    @Test
    fun zoneUnknownMustBeABooleanTrueInEitherTimeField() {
        listOf(JsonNull, JsonPrimitive("true"), JsonPrimitive(1), JsonObject(emptyMap())).forEach {
            assertInvalidInBothFields(mapOf("zoneUnknown" to it))
        }
    }

    @Test
    fun allThreeValidZoneFormsRoundTripInBothTimeFieldsAndKeepFutureFields() {
        listOf(mapOf("timeZone" to JsonPrimitive("Asia/Shanghai")),
            mapOf("utcOffset" to JsonPrimitive("+08:00")),
            mapOf("utcOffset" to JsonPrimitive("Z")),
            mapOf("zoneUnknown" to JsonPrimitive(true))).forEach { form ->
            val future = form + ("futureTimeDetail" to JsonPrimitive("kept"))
            val snapshot = snapshot(time(future), time(future, capture = true))
            assertEquals(snapshot, ArchiveJson.parseSnapshot(ArchiveJson.canonical(snapshot)))
        }
    }

    @Test
    fun unknownCaptureAndEstimatedOccurrenceRemainValid() {
        val snapshot = snapshot(time(mapOf("zoneUnknown" to JsonPrimitive(true),
            "estimated" to JsonPrimitive(true))), JsonObject(mapOf("timeUnknown" to JsonPrimitive(true))))
        assertEquals(snapshot, ArchiveJson.parseSnapshot(ArchiveJson.canonical(snapshot)))
    }

    @Test
    fun unknownAndFixedOffsetZoneIdsAreRejectedInBothTimeFields() {
        listOf("Not/AZone", "UTC+08:00", "GMT-01:00", "+08:00", "Z", "").forEach {
            assertInvalidInBothFields(mapOf("timeZone" to JsonPrimitive(it)))
        }
    }

    @Test
    fun estimatedFalseIsRejectedInBothTimeFields() {
        assertInvalidInBothFields(mapOf("zoneUnknown" to JsonPrimitive(true), "estimated" to JsonPrimitive(false)))
    }

    @Test
    fun offsetsAboveFourteenHoursAndInvalidMinutesAreRejectedInBothTimeFields() {
        listOf("+", "-").forEach { sign ->
            (1..59).forEach { minute ->
                assertInvalidInBothFields(mapOf("utcOffset" to JsonPrimitive("${sign}14:${minute.toString().padStart(2, '0')}")))
            }
            listOf("15:00", "18:00", "13:60").forEach {
                assertInvalidInBothFields(mapOf("utcOffset" to JsonPrimitive("$sign$it")))
            }
        }
    }

    @Test
    fun genuineZoneIdsAndOffsetBoundariesRoundTripInBothTimeFields() {
        val forms = listOf("Asia/Shanghai", "America/New_York", "Etc/GMT+8", "UTC", "GMT")
            .map { mapOf("timeZone" to JsonPrimitive(it)) } +
            listOf("+14:00", "-14:00", "+13:59", "-13:59", "+00:00", "-00:00", "Z")
                .map { mapOf("utcOffset" to JsonPrimitive(it)) }
        forms.forEach { form ->
            val snapshot = snapshot(time(form), time(form, capture = true))
            assertEquals(snapshot, ArchiveJson.parseSnapshot(ArchiveJson.canonical(snapshot)))
        }
    }

    private fun assertInvalidInBothFields(form: Map<String, JsonElement>) {
        val valid = mapOf("zoneUnknown" to JsonPrimitive(true))
        listOf(snapshot(time(form), time(valid, capture = true)),
            snapshot(time(valid), time(form, capture = true))).forEach {
            assertThrows(ArchiveProtocolException::class.java) {
                ArchiveJson.parseSnapshot(ArchiveJson.canonical(it))
            }
        }
    }

    private fun time(form: Map<String, JsonElement>, capture: Boolean = false): JsonObject = JsonObject(
        mapOf("utc" to JsonPrimitive(1_700_000_000_123L)) + form +
            (if (capture) mapOf("timeUnknown" to JsonPrimitive(false)) else emptyMap()),
    )

    private fun snapshot(occurredAt: JsonObject, capturedAt: JsonObject): ArchiveSnapshot {
        val edit = EditStamp(1L, 10L, "android")
        fun envelope(value: JsonElement) = FieldEnvelope(value, edit)
        val future = mapOf("futureField" to envelope(JsonPrimitive("kept")))
        val record = ArchiveRecord("record", envelope(JsonPrimitive("Photo")), envelope(JsonPrimitive("")),
            envelope(occurredAt), envelope(JsonPrimitive(10L)), envelope(JsonArray(listOf(JsonPrimitive("asset")))),
            envelope(JsonNull), emptyMap(), unknownFields = future)
        val asset = MediaAsset("asset", "photo", envelope(capturedAt), emptyList(), emptyMap(),
            unknownFields = future, hasLocation = true)
        return ArchiveSnapshot.empty().copy(records = listOf(record), assets = listOf(asset), unknownFields = future)
    }
}
