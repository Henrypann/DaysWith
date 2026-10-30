package com.henrypann.jinbao365.archive

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject

const val PROTOCOL_VERSION = 3

internal const val DELETION_GENERATION = "deletionGeneration"

/** 30 days of 86,400,000 milliseconds, added to firstPublishedAt. Not a calendar month. */
const val PURGE_WINDOW_MILLIS = 30L * 86_400_000L

const val MIN_RECORD_MEDIA = 0
const val MAX_RECORD_MEDIA = 30

/** Merge or a malformed snapshot cannot be published. Local data stays as it was. */
class ArchiveProtocolException(message: String) : Exception(message)

class ArchiveValidationException(message: String) : IllegalArgumentException(message)

data class EditStamp(
    val counter: Long,
    val at: Long,
    val deviceID: String,
    /** Unknown sibling keys on the stamp. They round-trip and are not a field envelope. */
    val extra: Map<String, JsonElement> = emptyMap(),
)

/**
 * A user-edited value. [conflict] is at most one losing value.
 * Unknown sibling keys on the envelope are kept in [extra].
 */
data class FieldEnvelope(
    val value: JsonElement,
    val edit: EditStamp,
    val conflict: JsonObject? = null,
    val extra: Map<String, JsonElement> = emptyMap(),
) {
    fun isNullValue(): Boolean = value is JsonNull
}

data class ArchiveRecord(
    val id: String,
    val title: FieldEnvelope?,
    val note: FieldEnvelope,
    val occurredAt: FieldEnvelope,
    val createdAt: FieldEnvelope,
    val assetIds: FieldEnvelope,
    val tombstone: FieldEnvelope,
    val extensions: Map<String, FieldEnvelope>,
    val unknownFields: Map<String, FieldEnvelope> = emptyMap(),
    /** Derived. Null means the snapshot has not been through merge yet. */
    val mediaOverflow: Boolean? = null,
)

data class MediaAsset(
    val id: String,
    val kind: String,
    val capturedAt: FieldEnvelope,
    val resourceIds: List<String>,
    val extensions: Map<String, FieldEnvelope>,
    val unknownFields: Map<String, FieldEnvelope> = emptyMap(),
    /** True when the archived original bytes contain a location. Absent on older snapshots. */
    val hasLocation: Boolean? = null,
)

data class MediaResource(
    val id: String,
    val assetID: String,
    val role: String,
    val contentType: String,
    val originalFilename: String,
    val byteCount: Long,
    val sha256: String,
    val objectKey: String,
    val extensions: Map<String, FieldEnvelope>,
    val possibleDuplicateOf: FieldEnvelope? = null,
    val unknownFields: Map<String, FieldEnvelope> = emptyMap(),
)

data class ArchiveSnapshot(
    val version: Int = PROTOCOL_VERSION,
    val records: List<ArchiveRecord>,
    val assets: List<MediaAsset>,
    val resources: List<MediaResource>,
    val extensions: Map<String, FieldEnvelope>,
    val unknownFields: Map<String, FieldEnvelope> = emptyMap(),
) {
    companion object {
        fun empty() = ArchiveSnapshot(
            version = PROTOCOL_VERSION,
            records = emptyList(),
            assets = emptyList(),
            resources = emptyList(),
            extensions = emptyMap(),
        )
    }
}

data class TimelineOrder(
    val records: List<String>,
    val assets: List<String>,
)

/** Missing means the initial legacy generation; an explicit null is invalid. */
internal fun deletionGeneration(envelope: FieldEnvelope): JsonObject? {
    val raw = envelope.extra[DELETION_GENERATION] ?: return null
    val generation = raw as? JsonObject ?: throw ArchiveProtocolException("deletionGeneration must be an object")
    if (generation.keys != setOf("counter", "at", "deviceID")) {
        throw ArchiveProtocolException("deletionGeneration must contain only counter, at, deviceID")
    }
    for (key in listOf("counter", "at")) {
        val number = generation[key] as? kotlinx.serialization.json.JsonPrimitive
            ?: throw ArchiveProtocolException("deletionGeneration.$key must be an integer")
        val parsed = number.content.toLongOrNull()
        if (number.isString || !Regex("(0|-?[1-9][0-9]*)").matches(number.content) ||
            parsed == null || parsed !in -MAX_PROTOCOL_INTEGER..MAX_PROTOCOL_INTEGER
        ) throw ArchiveProtocolException("deletionGeneration.$key must be a safe integer")
    }
    val device = generation["deviceID"] as? kotlinx.serialization.json.JsonPrimitive
    if (device == null || !device.isString || device.content.isEmpty()) {
        throw ArchiveProtocolException("deletionGeneration.deviceID must be nonempty text")
    }
    return generation
}

internal fun sameDeletionGeneration(left: FieldEnvelope, right: FieldEnvelope): Boolean =
    deletionGeneration(left) == deletionGeneration(right)

/** A known generation cannot silently become legacy through an older writer. */
internal fun requireGenerationPreserved(base: FieldEnvelope?, side: FieldEnvelope) {
    val generation = deletionGeneration(side)
    if (base?.let(::deletionGeneration) != null && generation == null) {
        throw ArchiveProtocolException("tombstone deletionGeneration was lost")
    }
}
