package com.henrypann.jinbao365.archive

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import java.time.ZoneId

private val jsonParser = Json { isLenient = false }

private val SNAPSHOT_KNOWN = setOf("version", "records", "items", "assets", "resources", "extensions")
private val RECORD_KNOWN = setOf(
    "id", "title", "note", "occurredAt", "createdAt", "assetIDs", "isOutfit",
    "links", "tombstone", "extensions", "mediaOverflow", "outfitConstraintOverflow",
)
private val ASSET_KNOWN = setOf("id", "kind", "capturedAt", "resourceIDs", "extensions", "hasLocation")
private val RESOURCE_KNOWN = setOf(
    "id", "assetID", "role", "contentType", "originalFilename", "byteCount",
    "sha256", "objectKey", "possibleDuplicateOf", "extensions",
)
private val ENVELOPE_KNOWN = setOf("value", "edit", "conflict")
private val INTEGER_LITERAL = Regex("(0|-?[1-9][0-9]*)")
private val SHA256_LITERAL = Regex("[0-9a-f]{64}")
private val EDIT_KNOWN = setOf("counter", "at", "deviceID")

/** Inclusive bounds. JSON numbers in Swift are doubles, which cannot tell 2^53 from 2^53+1. */
internal const val MAX_PROTOCOL_INTEGER = 9007199254740991L

object ArchiveJson {
    fun parseSnapshot(text: String): ArchiveSnapshot {
        val element = jsonParser.parseToJsonElement(text)
        val objectValue = element as? JsonObject
            ?: throw ArchiveProtocolException("snapshot is not an object")
        return parseSnapshot(objectValue)
    }

    fun parseSnapshot(objectValue: JsonObject): ArchiveSnapshot {
        rejectNonIntegerNumbers(objectValue, "snapshot")
        val version = objectValue.long("version")
        if (version != PROTOCOL_VERSION.toLong()) {
            throw ArchiveProtocolException("unsupported snapshot version $version")
        }
        val snapshot = ArchiveSnapshot(
            version = PROTOCOL_VERSION,
            records = objectValue.array("records").map { parseRecord(it.requireObject("record")) },
            assets = objectValue.array("assets").map { parseAsset(it.requireObject("asset")) },
            resources = objectValue.array("resources").map { parseResource(it.requireObject("resource")) },
            extensions = parseEnvelopeMap(objectValue["extensions"]),
            unknownFields = parseUnknown(objectValue, SNAPSHOT_KNOWN),
        )
        validateSnapshot(snapshot)
        return snapshot
    }

    fun encodeSnapshot(snapshot: ArchiveSnapshot): JsonObject {
        val map = linkedMapOf<String, JsonElement>(
            "version" to JsonPrimitive(snapshot.version),
            "records" to JsonArray(snapshot.records.map { encodeRecord(it) }),
            "assets" to JsonArray(snapshot.assets.map { encodeAsset(it) }),
            "resources" to JsonArray(snapshot.resources.map { encodeResource(it) }),
            "extensions" to encodeEnvelopeMap(snapshot.extensions),
        )
        snapshot.unknownFields.forEach { (key, envelope) -> map[key] = encodeEnvelope(envelope) }
        return sortedObject(map)
    }

    fun canonical(snapshot: ArchiveSnapshot): String = canonicalJson(encodeSnapshot(snapshot))

    fun encodeEnvelope(envelope: FieldEnvelope): JsonObject = encodeEnvelopePublic(envelope)
}

fun jsonStringList(value: JsonElement): List<String> {
    val array = value as? JsonArray ?: throw ArchiveProtocolException("expected a string list")
    return array.map { element ->
        val primitive = element as? JsonPrimitive ?: throw ArchiveProtocolException("expected a string id")
        if (!primitive.isString) throw ArchiveProtocolException("expected a string id")
        primitive.content
    }
}

private fun parseRecord(objectValue: JsonObject): ArchiveRecord {
    return ArchiveRecord(
        id = objectValue.string("id"),
        title = objectValue["title"]?.let { parseEnvelope(it) },
        note = parseEnvelope(objectValue.require("note")),
        occurredAt = parseEnvelope(objectValue.require("occurredAt")),
        createdAt = parseEnvelope(objectValue.require("createdAt")),
        assetIds = parseEnvelope(objectValue.require("assetIDs")),
        tombstone = parseEnvelope(objectValue.require("tombstone")),
        extensions = parseEnvelopeMap(objectValue["extensions"]),
        unknownFields = parseUnknown(objectValue, RECORD_KNOWN),
        mediaOverflow = objectValue.optionalBoolean("mediaOverflow"),
    )
}

private fun parseAsset(objectValue: JsonObject): MediaAsset {
    return MediaAsset(
        id = objectValue.string("id"),
        kind = objectValue.string("kind"),
        capturedAt = parseEnvelope(objectValue.require("capturedAt")),
        resourceIds = jsonStringList(objectValue.require("resourceIDs")),
        extensions = parseEnvelopeMap(objectValue["extensions"]),
        unknownFields = parseUnknown(objectValue, ASSET_KNOWN),
        hasLocation = objectValue["hasLocation"]?.let { requireBoolean(it, "hasLocation") },
    )
}

private fun parseResource(objectValue: JsonObject): MediaResource {
    return MediaResource(
        id = objectValue.string("id"),
        assetID = objectValue.string("assetID"),
        role = objectValue.string("role"),
        contentType = objectValue.string("contentType"),
        originalFilename = objectValue.string("originalFilename"),
        byteCount = objectValue.long("byteCount"),
        sha256 = objectValue.string("sha256"),
        objectKey = objectValue.string("objectKey"),
        extensions = parseEnvelopeMap(objectValue["extensions"]),
        possibleDuplicateOf = objectValue["possibleDuplicateOf"]?.let { parseEnvelope(it) },
        unknownFields = parseUnknown(objectValue, RESOURCE_KNOWN),
    )
}

private fun parseEnvelope(element: JsonElement): FieldEnvelope {
    val objectValue = element as? JsonObject
        ?: throw ArchiveProtocolException("field envelope must be an object")
    if ("value" !in objectValue || "edit" !in objectValue) {
        throw ArchiveProtocolException("field envelope is missing value or edit")
    }
    val conflict = objectValue["conflict"]?.let {
        it as? JsonObject ?: throw ArchiveProtocolException("conflict must be an object")
    }
    val extra = objectValue.filterKeys { it !in ENVELOPE_KNOWN }
    return FieldEnvelope(
        value = objectValue.getValue("value"),
        edit = parseEdit(objectValue.getValue("edit")),
        conflict = conflict,
        extra = extra,
    )
}

private fun parseEnvelopeMap(element: JsonElement?): Map<String, FieldEnvelope> {
    if (element == null) return emptyMap()
    val objectValue = element as? JsonObject
        ?: throw ArchiveProtocolException("extensions must be an object")
    return objectValue.mapValues { (_, value) -> parseEnvelope(value) }
}

private fun parseUnknown(objectValue: JsonObject, known: Set<String>): Map<String, FieldEnvelope> {
    return objectValue
        .filterKeys { it !in known }
        .mapValues { (_, value) -> parseEnvelope(value) }
}

private fun parseEdit(element: JsonElement): EditStamp {
    val objectValue = element as? JsonObject ?: throw ArchiveProtocolException("edit stamp must be an object")
    return EditStamp(
        counter = objectValue.long("counter"),
        at = objectValue.long("at"),
        deviceID = objectValue.string("deviceID"),
        extra = objectValue.filterKeys { it !in EDIT_KNOWN },
    )
}

private fun encodeRecord(record: ArchiveRecord): JsonObject {
    val map = linkedMapOf<String, JsonElement>(
        "id" to JsonPrimitive(record.id),
        "note" to encodeEnvelopePublic(record.note),
        "occurredAt" to encodeEnvelopePublic(record.occurredAt),
        "createdAt" to encodeEnvelopePublic(record.createdAt),
        "assetIDs" to encodeEnvelopePublic(record.assetIds),
        "tombstone" to encodeEnvelopePublic(record.tombstone),
        "extensions" to encodeEnvelopeMap(record.extensions),
    )
    record.title?.let { map["title"] = encodeEnvelopePublic(it) }
    record.mediaOverflow?.let { map["mediaOverflow"] = JsonPrimitive(it) }
    record.unknownFields.forEach { (key, envelope) -> map[key] = encodeEnvelopePublic(envelope) }
    return sortedObject(map)
}

private fun encodeAsset(asset: MediaAsset): JsonObject {
    val map = linkedMapOf<String, JsonElement>(
        "id" to JsonPrimitive(asset.id),
        "kind" to JsonPrimitive(asset.kind),
        "capturedAt" to encodeEnvelopePublic(asset.capturedAt),
        "resourceIDs" to JsonArray(asset.resourceIds.map { JsonPrimitive(it) }),
        "extensions" to encodeEnvelopeMap(asset.extensions),
    )
    asset.hasLocation?.let { map["hasLocation"] = JsonPrimitive(it) }
    asset.unknownFields.forEach { (key, envelope) -> map[key] = encodeEnvelopePublic(envelope) }
    return sortedObject(map)
}

private fun encodeResource(resource: MediaResource): JsonObject {
    val map = linkedMapOf<String, JsonElement>(
        "id" to JsonPrimitive(resource.id),
        "assetID" to JsonPrimitive(resource.assetID),
        "role" to JsonPrimitive(resource.role),
        "contentType" to JsonPrimitive(resource.contentType),
        "originalFilename" to JsonPrimitive(resource.originalFilename),
        "byteCount" to JsonPrimitive(resource.byteCount),
        "sha256" to JsonPrimitive(resource.sha256),
        "objectKey" to JsonPrimitive(resource.objectKey),
        "extensions" to encodeEnvelopeMap(resource.extensions),
    )
    resource.possibleDuplicateOf?.let { map["possibleDuplicateOf"] = encodeEnvelopePublic(it) }
    resource.unknownFields.forEach { (key, envelope) -> map[key] = encodeEnvelopePublic(envelope) }
    return sortedObject(map)
}

private fun encodeEnvelopePublic(envelope: FieldEnvelope): JsonObject {
    val map = linkedMapOf<String, JsonElement>(
        "value" to envelope.value,
        "edit" to encodeEditStamp(envelope.edit),
    )
    envelope.conflict?.let { map["conflict"] = it }
    envelope.extra.forEach { (key, value) -> map[key] = value }
    return sortedObject(map)
}

private fun encodeEnvelopeMap(envelopes: Map<String, FieldEnvelope>): JsonObject =
    sortedObject(envelopes.mapValues { (_, envelope) -> encodeEnvelopePublic(envelope) })

internal fun encodeEditStamp(edit: EditStamp): JsonObject {
    val map = linkedMapOf<String, JsonElement>(
        "counter" to JsonPrimitive(edit.counter),
        "at" to JsonPrimitive(edit.at),
        "deviceID" to JsonPrimitive(edit.deviceID),
    )
    edit.extra.forEach { (key, value) -> map[key] = value }
    return sortedObject(map)
}

internal fun sortedObject(entries: Map<String, JsonElement>): JsonObject {
    val ordered = entries.entries.sortedWith { left, right -> utf8Compare(left.key, right.key) }
    return JsonObject(ordered.associate { it.key to it.value })
}

private fun JsonObject.require(key: String): JsonElement =
    this[key] ?: throw ArchiveProtocolException("missing $key")

private fun JsonElement.requireObject(label: String): JsonObject =
    this as? JsonObject ?: throw ArchiveProtocolException("$label must be an object")

private fun JsonObject.array(key: String): JsonArray =
    this[key] as? JsonArray ?: throw ArchiveProtocolException("$key must be a list")

private fun JsonObject.string(key: String): String {
    val primitive = this[key] as? JsonPrimitive ?: throw ArchiveProtocolException("$key must be a string")
    if (!primitive.isString) throw ArchiveProtocolException("$key must be a string")
    return primitive.content
}

private fun JsonObject.long(key: String): Long = requireInteger(this[key], key)

private fun requireInteger(element: JsonElement?, label: String): Long {
    val primitive = element as? JsonPrimitive ?: throw ArchiveProtocolException("$label must be an integer")
    if (primitive is JsonNull || primitive.isString) {
        throw ArchiveProtocolException("$label must be an integer")
    }
    return parseProtocolInteger(primitive.content, label)
}

private fun parseProtocolInteger(content: String, label: String): Long {
    if (!INTEGER_LITERAL.matches(content)) {
        throw ArchiveProtocolException("$label must be an integer")
    }
    val value = content.toLongOrNull() ?: throw ArchiveProtocolException("$label must be an integer")
    if (value !in -MAX_PROTOCOL_INTEGER..MAX_PROTOCOL_INTEGER) {
        throw ArchiveProtocolException("$label is outside ±(2^53-1)")
    }
    return value
}

private fun rejectNonIntegerNumbers(element: JsonElement, path: String) {
    when (element) {
        is JsonNull -> Unit
        is JsonObject -> element.forEach { (key, value) -> rejectNonIntegerNumbers(value, "$path.$key") }
        is JsonArray -> element.forEachIndexed { index, value ->
            rejectNonIntegerNumbers(value, "$path[$index]")
        }
        is JsonPrimitive -> {
            if (element.isString) return
            if (element.content == "true" || element.content == "false") return
            parseProtocolInteger(element.content, "protocol number at $path")
        }
    }
}

private fun validateSnapshot(snapshot: ArchiveSnapshot) {
    requireUnique(snapshot.records.map { it.id }, "record id")
    requireUnique(snapshot.assets.map { it.id }, "asset id")
    requireUnique(snapshot.resources.map { it.id }, "resource id")
    snapshot.records.forEach { record ->
        validateRecordTime(record.occurredAt.value)
        requireInteger(record.createdAt.value, "createdAt")
        validateTombstone(record.tombstone)
    }
    snapshot.assets.forEach { asset -> validateCapturedAt(asset.capturedAt.value) }
    snapshot.resources.forEach { resource -> validateResourceIdentity(resource) }
}

private fun requireUnique(ids: List<String>, label: String) {
    if (ids.size != ids.toSet().size) throw ArchiveProtocolException("duplicate $label")
}

private fun requireBoolean(element: JsonElement, label: String): Boolean {
    val primitive = element as? JsonPrimitive ?: throw ArchiveProtocolException("$label must be a boolean")
    if (primitive.isString) throw ArchiveProtocolException("$label must be a boolean")
    return primitive.booleanOrNull ?: throw ArchiveProtocolException("$label must be a boolean")
}

private fun validateRecordTime(value: JsonElement) {
    val objectValue = value as? JsonObject ?: throw ArchiveProtocolException("occurredAt value must be an object")
    if ("utc" !in objectValue) throw ArchiveProtocolException("occurredAt is missing utc")
    requireInteger(objectValue["utc"], "occurredAt.utc")
    validateZoneForm(objectValue, "occurredAt", allowEstimated = true)
}

private fun validateCapturedAt(value: JsonElement) {
    val objectValue = value as? JsonObject ?: throw ArchiveProtocolException("capturedAt value must be an object")
    if ("timeUnknown" !in objectValue) throw ArchiveProtocolException("capturedAt is missing timeUnknown")
    val unknown = requireBoolean(objectValue.getValue("timeUnknown"), "capturedAt.timeUnknown")
    if (unknown) {
        if (objectValue.keys.any { it != "timeUnknown" }) {
            throw ArchiveProtocolException("time-unknown capture must not include utc or a zone")
        }
        return
    }
    if ("utc" !in objectValue) throw ArchiveProtocolException("capturedAt is missing utc")
    requireInteger(objectValue["utc"], "capturedAt.utc")
    validateZoneForm(objectValue, "capturedAt", allowEstimated = false)
}

private val UTC_OFFSET = Regex("""[+-](?:(?:0[0-9]|1[0-3]):[0-5][0-9]|14:00)""")
private val IANA_TIME_ZONES = ZoneId.getAvailableZoneIds() + setOf("UTC", "GMT")

internal fun isProtocolTimeZone(text: String): Boolean = text in IANA_TIME_ZONES

internal fun isProtocolUtcOffset(text: String): Boolean = text == "Z" || UTC_OFFSET.matches(text)

private fun validateZoneForm(objectValue: JsonObject, label: String, allowEstimated: Boolean) {
    val hasZone = "timeZone" in objectValue
    val hasOffset = "utcOffset" in objectValue
    val hasUnknownZone = "zoneUnknown" in objectValue
    if (hasUnknownZone && !requireBoolean(objectValue.getValue("zoneUnknown"), "$label.zoneUnknown")) {
        throw ArchiveProtocolException("$label.zoneUnknown must be true when present")
    }
    val modes = listOf(hasZone, hasOffset, hasUnknownZone).count { it }
    if (modes != 1) {
        throw ArchiveProtocolException(
            "$label must use one of timeZone, utcOffset, or zoneUnknown",
        )
    }
    if (hasZone) {
        val zone = objectValue["timeZone"] as? JsonPrimitive
        if (zone == null || !zone.isString || !isProtocolTimeZone(zone.content)) {
            throw ArchiveProtocolException("$label timeZone must be a platform IANA zone ID")
        }
    }
    if (hasOffset) {
        val offset = objectValue["utcOffset"] as? JsonPrimitive
        if (offset == null || !offset.isString || !isProtocolUtcOffset(offset.content)) {
            throw ArchiveProtocolException("$label utcOffset must be Z or ±HH:MM within ±14:00")
        }
    }
    if ("estimated" in objectValue) {
        if (!allowEstimated) throw ArchiveProtocolException("$label must not set estimated")
        if (!requireBoolean(objectValue.getValue("estimated"), "$label.estimated")) {
            throw ArchiveProtocolException("$label.estimated must be true when present")
        }
    }
}

private fun validateTombstone(envelope: FieldEnvelope) {
    deletionGeneration(envelope)
    val value = envelope.value
    if (value is JsonNull) return
    val objectValue = value as? JsonObject ?: throw ArchiveProtocolException("tombstone value must be null or an object")
    requireInteger(objectValue["deletedAt"], "deletedAt")
    val published = objectValue["firstPublishedAt"]
    if (published != null) {
        val first = requireInteger(published, "firstPublishedAt")
        val purgeAfter = requireInteger(objectValue["purgeAfter"], "purgeAfter")
        if (purgeAfter != first + PURGE_WINDOW_MILLIS) {
            throw ArchiveProtocolException("purgeAfter must be firstPublishedAt plus 30 days")
        }
    } else if ("purgeAfter" in objectValue) {
        requireInteger(objectValue["purgeAfter"], "purgeAfter")
    }
}

private fun validateResourceIdentity(resource: MediaResource) {
    if (!SHA256_LITERAL.matches(resource.sha256)) {
        throw ArchiveProtocolException("sha256 must be lowercase hex")
    }
    val expectedKey = "objects/${resource.sha256.take(2)}/${resource.sha256}"
    if (resource.objectKey != expectedKey) {
        throw ArchiveProtocolException("objectKey must be objects/<first two>/<sha256>")
    }
}

private fun JsonObject.boolean(key: String): Boolean {
    val element = this[key] ?: throw ArchiveProtocolException("$key must be a boolean")
    return requireBoolean(element, key)
}

private fun JsonObject.optionalBoolean(key: String): Boolean? {
    val element = this[key] ?: return null
    return requireBoolean(element, key)
}

internal fun stringOrNull(element: JsonElement): String? {
    val primitive = element as? JsonPrimitive ?: return null
    if (!primitive.isString) return null
    return primitive.content
}
