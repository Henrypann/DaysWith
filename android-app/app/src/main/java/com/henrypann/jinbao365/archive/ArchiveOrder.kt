package com.henrypann.jinbao365.archive

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/**
 * Timeline order derived from a snapshot. It is not stored and is not part of the manifest hash.
 * Records sort by user-set UTC, then id. Known capture times come first; time-unknown assets follow by id.
 */
object ArchiveOrder {
    fun of(snapshot: ArchiveSnapshot): TimelineOrder {
        val records = snapshot.records.sortedWith { left, right ->
            val compared = instant(left.occurredAt).compareTo(instant(right.occurredAt))
            if (compared != 0) compared else utf8Compare(left.id, right.id)
        }
        val assets = snapshot.assets.sortedWith { left, right ->
            val leftUnknown = timeUnknown(left.capturedAt)
            val rightUnknown = timeUnknown(right.capturedAt)
            if (leftUnknown != rightUnknown) return@sortedWith if (leftUnknown) 1 else -1
            if (!leftUnknown) {
                val compared = instant(left.capturedAt).compareTo(instant(right.capturedAt))
                if (compared != 0) return@sortedWith compared
            }
            utf8Compare(left.id, right.id)
        }
        return TimelineOrder(records.map { it.id }, assets.map { it.id })
    }

    private fun valueObject(envelope: FieldEnvelope): JsonObject? = envelope.value as? JsonObject

    private fun timeUnknown(envelope: FieldEnvelope): Boolean {
        val flag = valueObject(envelope)?.get("timeUnknown") as? JsonPrimitive ?: return false
        return flag.booleanOrNull == true
    }

    private fun instant(envelope: FieldEnvelope): Long {
        val utc = valueObject(envelope)?.get("utc") as? JsonPrimitive ?: return 0
        return utc.content.toLongOrNull() ?: 0
    }
}
