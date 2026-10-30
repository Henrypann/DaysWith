package com.henrypann.jinbao365.archive

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** True when the media list is longer than the manual-save maximum. Merge keeps every id. */
fun recordMediaOverflow(assetIds: JsonElement): Boolean =
    jsonStringList(assetIds).size > MAX_RECORD_MEDIA

object ArchiveValidation {
    fun requireManualRecord(record: ArchiveRecord) {
        val ids = jsonStringList(record.assetIds.value)
        val count = ids.size
        if (count !in MIN_RECORD_MEDIA..MAX_RECORD_MEDIA || ids.distinct().size != count) {
            throw ArchiveValidationException(
                "A record holds $MIN_RECORD_MEDIA to $MAX_RECORD_MEDIA media items.",
            )
        }
        val title = stringOrNull(record.title?.value ?: JsonNull).orEmpty()
        val note = stringOrNull(record.note.value).orEmpty()
        if (title.length > 200 || note.length > 10_000) {
            throw ArchiveValidationException("Title is limited to 200 characters and note to 10,000 UTF-16 units.")
        }
        if (count == 0 && !hasRecordText(title, note)) {
            throw ArchiveValidationException("Add a photo or write something.")
        }
    }


}

object ArchiveEdits {
    fun upsertManualRecord(snapshot: ArchiveSnapshot, record: ArchiveRecord): ArchiveSnapshot {
        val live = record.tombstone.isNullValue()
        if (live) {
            ArchiveValidation.requireManualRecord(record)

        }
        val stored = record.copy(mediaOverflow = recordMediaOverflow(record.assetIds.value))
        val records = (snapshot.records.filterNot { it.id == record.id } + stored)
            .sortedWith { left, right -> utf8Compare(left.id, right.id) }
        return snapshot.copy(records = records)
    }

    /**
     * Pre-publish purge. Omits a tombstoned record only when `purgeAfter`
     * is at or before [nowMillis] and [published] already stored a tombstone for
     * that id in the same deletion generation with an expired published deadline.
     * A tombstone created on this phone stays until a later publish.
     * Then drops
     * assets and resources nothing remaining references. Merge does not call this.
     */
    fun purgeExpired(
        snapshot: ArchiveSnapshot,
        nowMillis: Long,
        published: ArchiveSnapshot,
    ): ArchiveSnapshot {
        val publishedRecords = published.records.associateBy { it.id }
        val records = snapshot.records.filterNot { record ->
            publishedAndExpired(record.tombstone, nowMillis, publishedRecords[record.id]?.tombstone)
        }.map { it.copy(mediaOverflow = recordMediaOverflow(it.assetIds.value)) }
        val neededAssets = linkedSetOf<String>()
        for (record in records) neededAssets += jsonStringList(record.assetIds.value)
        val assets = snapshot.assets.filter { it.id in neededAssets }
        val neededResources = assets.flatMap { it.resourceIds }.toSet()
        return snapshot.copy(
            records = records,
            assets = assets,
            resources = snapshot.resources.filter { it.id in neededResources },
        )
    }

    private fun publishedAndExpired(
        tombstone: FieldEnvelope,
        nowMillis: Long,
        published: FieldEnvelope?,
    ): Boolean {
        requireGenerationPreserved(published, tombstone)
        if (published == null || published.isNullValue() || tombstone.isNullValue()) return false
        if (!sameDeletionGeneration(tombstone, published)) return false
        val pendingDeadline = readPurgeAfter(tombstone) ?: return false
        val publishedDeadline = readPurgeAfter(published) ?: return false
        return pendingDeadline <= nowMillis && publishedDeadline <= nowMillis
    }

    /**
     * A live-to-deleted tap stores deletedAt and inherits the previous generation.
     * Always pass [previous] for an existing entity, including a restored null.
     * The default is only for the initial legacy generation. Repeated deletes
     * without restore keep the clock; first publication stamps a new deletion.
     */
    fun tombstone(deletedAt: Long, edit: EditStamp, previous: FieldEnvelope? = null): FieldEnvelope {
        previous?.let(::deletionGeneration)
        val result = FieldEnvelope(
            value = JsonObject(mapOf("deletedAt" to JsonPrimitive(deletedAt))),
            edit = edit,
            extra = previous?.extra ?: emptyMap(),
        )
        // Repeated deletes without a restore are the same generation.
        previous?.let(::readFirstPublishedAt)?.let { return applyPublishClock(result, it) }
        previous?.let(::readPurgeAfter)?.let { deadline ->
            return result.copy(value = JsonObject(result.value as JsonObject + ("purgeAfter" to JsonPrimitive(deadline))))
        }
        return result
    }

    /** Restore starts a new generation even if its null state is never published. */
    fun restore(previous: FieldEnvelope, edit: EditStamp): FieldEnvelope {
        deletionGeneration(previous)
        val generation = encodeEditStamp(edit.copy(extra = emptyMap()))
        val restored = FieldEnvelope(
            value = JsonNull,
            edit = edit,
            extra = previous.extra + (DELETION_GENERATION to generation),
        )
        deletionGeneration(restored)
        if (sameDeletionGeneration(previous, restored)) {
            throw ArchiveProtocolException("restore must use a new edit identity")
        }
        return restored
    }

    /**
     * Pre-publish stamp. [publishedAt] is the createdAt of the commit about to be
     * uploaded. An existing firstPublishedAt is kept, and the earlier of the pending
     * and same-generation published clocks wins. A legacy published deadline is
     * retained only in its generation. Does not change the tombstone edit stamp.
     * Returns a candidate: never persist its clock as pending until the commit is
     * confirmed. Failed attempts retry from the original pending snapshot.
     */
    fun stampFirstPublish(
        snapshot: ArchiveSnapshot,
        published: ArchiveSnapshot,
        publishedAt: Long,
    ): ArchiveSnapshot {
        val publishedRecords = published.records.associateBy { it.id }
        return snapshot.copy(
            records = snapshot.records.map { record ->
                record.copy(
                    tombstone = stampOne(record.tombstone, publishedRecords[record.id]?.tombstone, publishedAt),
                )
            },
        )
    }

    private fun stampOne(
        pending: FieldEnvelope,
        published: FieldEnvelope?,
        publishedAt: Long,
    ): FieldEnvelope {
        requireGenerationPreserved(published, pending)
        if (pending.isNullValue()) return pending
        val samePublished = published?.takeIf { sameDeletionGeneration(pending, it) && !it.isNullValue() }
        val clocks = listOfNotNull(readFirstPublishedAt(pending), samePublished?.let(::readFirstPublishedAt))
        if (clocks.isNotEmpty()) return applyPublishClock(pending, clocks.min())
        // Only an actually stored legacy deadline is evidence for this exception.
        if (samePublished != null && readPurgeAfter(samePublished) != null) {
            val value = pending.value as JsonObject
            return pending.copy(value = JsonObject(value + ("purgeAfter" to JsonPrimitive(readPurgeAfter(samePublished)!!))))
        }
        return applyPublishClock(pending, publishedAt)
    }
}

internal fun readPurgeAfter(envelope: FieldEnvelope): Long? =
    ((envelope.value as? JsonObject)?.get("purgeAfter") as? JsonPrimitive)
        ?.takeUnless { it.isString }?.content?.toLongOrNull()

internal fun readFirstPublishedAt(envelope: FieldEnvelope): Long? {
    if (envelope.isNullValue()) return null
    val value = envelope.value as? JsonObject ?: return null
    val raw = value["firstPublishedAt"] as? JsonPrimitive ?: return null
    if (raw.isString) return null
    return raw.content.toLongOrNull()
}

internal fun withoutPublishClock(envelope: FieldEnvelope): FieldEnvelope {
    if (envelope.isNullValue()) return envelope
    val value = envelope.value as? JsonObject ?: return envelope
    if ("firstPublishedAt" !in value) return envelope
    return envelope.copy(
        value = JsonObject(value.filterKeys { it != "firstPublishedAt" && it != "purgeAfter" }),
    )
}

internal fun applyPublishClock(envelope: FieldEnvelope, publishedAt: Long): FieldEnvelope {
    val value = envelope.value as? JsonObject ?: return envelope
    val map = value.toMutableMap()
    if (publishedAt !in -MAX_PROTOCOL_INTEGER..(MAX_PROTOCOL_INTEGER - PURGE_WINDOW_MILLIS)) {
        throw ArchiveProtocolException("publish clock is outside the protocol integer range")
    }
    map["firstPublishedAt"] = JsonPrimitive(publishedAt)
    map["purgeAfter"] = JsonPrimitive(publishedAt + PURGE_WINDOW_MILLIS)
    return envelope.copy(value = JsonObject(map))
}

/** Matches Foundation whitespacesAndNewlines, including NEXT LINE and ZERO WIDTH SPACE. */
fun isArchiveWhitespace(char: Char): Boolean = when (char.code) {
    in 0x0009..0x000D, 0x0020, 0x0085, 0x00A0, 0x1680,
    in 0x2000..0x200B, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 -> true
    else -> false
}
fun trimArchiveWhitespace(text: String): String = text.trim(::isArchiveWhitespace)
fun hasRecordText(title: String, note: String): Boolean =
    title.any { !isArchiveWhitespace(it) } || note.any { !isArchiveWhitespace(it) }
