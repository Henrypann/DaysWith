package com.henrypann.jinbao365.editing

import com.henrypann.jinbao365.archive.*
import kotlinx.serialization.json.*
import java.time.ZoneId

const val MAX_MANUAL_TIME_MILLIS = 8_640_000_000_000_000L

/** UI-independent values; media order is the protocol assetIDs order. */
data class MomentDraft(
    val title: String = "",
    val note: String = "",
    val occurredAtMillis: Long,
    val assetIds: List<String> = emptyList(),
)

enum class MediaRemoval { Updated, NeedsDiscardConfirmation, DraftDiscarded, MovedToTrash }

fun momentDraft(record: ArchiveRecord) = MomentDraft(
    title = text(record.title?.value), note = text(record.note.value),
    occurredAtMillis = timeMillis(record), assetIds = assetIds(record),
)

internal fun assetIds(record: ArchiveRecord): List<String> = jsonStringList(record.assetIds.value)
internal fun text(value: JsonElement?): String = (value as? JsonPrimitive)?.takeIf { it.isString }?.content.orEmpty()
internal fun timeMillis(record: ArchiveRecord): Long =
    ((record.occurredAt.value as? JsonObject)?.get("utc") as? JsonPrimitive)?.longOrNull ?: 0L

internal fun nextStamp(previous: EditStamp?, deviceId: String, now: Long): EditStamp {
    val counter = previous?.counter ?: 0
    if (counter >= MAX_PROTOCOL_INTEGER) throw ArchiveValidationException("The edit counter is exhausted.")
    if (deviceId.isBlank() || now !in -MAX_PROTOCOL_INTEGER..MAX_PROTOCOL_INTEGER) {
        throw ArchiveValidationException("A valid device and edit time are required.")
    }
    return EditStamp(counter + 1, now, deviceId)
}

internal fun editedField(previous: FieldEnvelope?, value: JsonElement, deviceId: String, now: Long): FieldEnvelope =
    if (previous?.value == value) previous else FieldEnvelope(
        value, nextStamp(previous?.edit, deviceId, now), extra = previous?.extra.orEmpty(),
    )

internal fun manualTime(previous: JsonElement?, millis: Long, zone: ZoneId): JsonObject {
    if (millis !in 0L..MAX_MANUAL_TIME_MILLIS) throw ArchiveValidationException("Record time is out of range.")
    val fields = (previous as? JsonObject).orEmpty().filterKeys {
        it !in setOf("utc", "timeUnknown", "timeZone", "utcOffset", "zoneUnknown", "estimated")
    }.toMutableMap()
    fields["utc"] = JsonPrimitive(millis)
    when {
        isProtocolTimeZone(zone.id) -> fields["timeZone"] = JsonPrimitive(zone.id)
        isProtocolUtcOffset(zone.id) -> fields["utcOffset"] = JsonPrimitive(zone.id)
        else -> fields["zoneUnknown"] = JsonPrimitive(true)
    }
    return JsonObject(fields)
}

internal fun newDraftRecord(id: String, device: String, now: Long, zone: ZoneId): ArchiveRecord {
    if (id.isBlank()) throw ArchiveValidationException("A draft identity is required.")
    fun field(value: JsonElement) = editedField(null, value, device, now)
    return ArchiveRecord(id, field(JsonPrimitive("")), field(JsonPrimitive("")),
        field(manualTime(null, now, zone)), field(JsonPrimitive(now)), field(JsonArray(emptyList())),
        field(JsonNull), emptyMap())
}

/** Updates only changed fields and memberships; never rewrites unknown fields or unchanged stamps. */
internal fun editRecord(
    snapshot: ArchiveSnapshot, previous: ArchiveRecord, draft: MomentDraft,
    device: String, now: Long, zone: ZoneId, allowEmpty: Boolean = false,
): ArchiveRecord {
    if (!previous.tombstone.isNullValue()) throw ArchiveValidationException("Restore this record before editing it.")
    if (draft.assetIds.size > MAX_RECORD_MEDIA || draft.assetIds.distinct().size != draft.assetIds.size) {
        throw ArchiveValidationException("Choose 0–30 distinct media items.")
    }
    if (draft.assetIds.any { id -> snapshot.assets.none { it.id == id } }) {
        throw ArchiveValidationException("A selected media item is missing.")
    }
    fun field(before: FieldEnvelope?, value: JsonElement) = editedField(before, value, device, now)
    val edited = previous.copy(
        title = if (previous.title == null && draft.title.isEmpty()) null else field(previous.title, JsonPrimitive(draft.title)),
        note = field(previous.note, JsonPrimitive(draft.note)),
        occurredAt = if (draft.occurredAtMillis == timeMillis(previous)) previous.occurredAt
            else field(previous.occurredAt, manualTime(previous.occurredAt.value, draft.occurredAtMillis, zone)),
        assetIds = field(previous.assetIds, JsonArray(draft.assetIds.map(::JsonPrimitive))),
    )
    if (!allowEmpty) ArchiveValidation.requireManualRecord(edited)
    return edited.copy(mediaOverflow = false)
}

internal fun changeRecordTrash(record: ArchiveRecord, restore: Boolean, device: String, now: Long): ArchiveRecord {
    if (record.tombstone.isNullValue() == restore) return record
    val stamp = nextStamp(record.tombstone.edit, device, now)
    return record.copy(tombstone = if (restore) ArchiveEdits.restore(record.tombstone, stamp)
        else ArchiveEdits.tombstone(now, stamp, record.tombstone))
}
