package com.henrypann.jinbao365.archive

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * One commit of a catch-up from [VerifiedCursor].
 *
 * The caller downloads a single commit, passes it here, and drops it after
 * the step returns. A confirmed gap halts and keeps local edits. A transient
 * failure retries the same sequence and does not move the cursor.
 */
object ArchiveSync {
    fun advanceOne(
        base: ArchiveSnapshot,
        pending: ArchiveSnapshot,
        verifiedThrough: VerifiedCursor,
        next: CommitFetch,
    ): WalkStep {
        val sequence = verifiedThrough.sequence + 1
        return when (next) {
            is CommitFetch.Transient -> WalkStep.Retry(
                base = base,
                pending = pending,
                verifiedThrough = verifiedThrough,
                sequence = sequence,
                reason = next.reason,
            )
            CommitFetch.NotFound -> haltMissing(base, pending, verifiedThrough, sequence)
            is CommitFetch.Found -> {
                if (next.sequence != sequence) {
                    halt(
                        base,
                        pending,
                        verifiedThrough,
                        "commit ${next.sequence} does not follow cursor ${verifiedThrough.sequence}",
                    )
                } else if (next.parentHash != verifiedThrough.commitHash) {
                    halt(
                        base,
                        pending,
                        verifiedThrough,
                        "commit parent does not match the cursor",
                    )
                } else {
                    val merged = try {
                        ArchiveMerge.merge(base, pending, next.snapshot)
                    } catch (error: ArchiveProtocolException) {
                        return halt(
                            base,
                            pending,
                            verifiedThrough,
                            "Merge failed (${error.message}). Local changes were kept",
                        )
                    }
                    WalkStep.Advanced(
                        base = next.snapshot,
                        pending = merged,
                        verifiedThrough = VerifiedCursor(sequence, next.commitHash),
                    )
                }
            }
        }
    }

    private fun haltMissing(
        base: ArchiveSnapshot,
        pending: ArchiveSnapshot,
        verifiedThrough: VerifiedCursor,
        sequence: Long,
    ): WalkStep.Halted = halt(base, pending, verifiedThrough, "commit $sequence is missing from the chain")

    private fun halt(
        base: ArchiveSnapshot,
        pending: ArchiveSnapshot,
        verifiedThrough: VerifiedCursor,
        reason: String,
    ): WalkStep.Halted {
        val count = unsyncedEditCount(base, pending)
        val changes = if (count == 1) "1 change" else "$count changes"
        return WalkStep.Halted(
            base = base,
            pending = pending,
            verifiedThrough = verifiedThrough,
            missingSequence = verifiedThrough.sequence + 1,
            unsyncedEdits = count,
            message = "$changes not yet synced. $reason.",
        )
    }
}

/** SHA-256 of commit `sequence`, the last commit this device merged. */
data class VerifiedCursor(val sequence: Long, val commitHash: String)

/** One download of the next commit. [NotFound] is a confirmed gap, not a timeout. */
sealed class CommitFetch {
    data class Found(
        val sequence: Long,
        val snapshot: ArchiveSnapshot,
        val commitHash: String,
        val parentHash: String,
    ) : CommitFetch()

    data object NotFound : CommitFetch()

    data class Transient(val reason: String) : CommitFetch()
}

sealed class WalkStep {
    data class Advanced(
        val base: ArchiveSnapshot,
        val pending: ArchiveSnapshot,
        val verifiedThrough: VerifiedCursor,
    ) : WalkStep()

    /**
     * Commit [missingSequence] is not in the chain. [pending] is unchanged.
     * [message] is "N changes not yet synced". N is changed records, not field edits.
     */
    data class Halted(
        val base: ArchiveSnapshot,
        val pending: ArchiveSnapshot,
        val verifiedThrough: VerifiedCursor,
        val missingSequence: Long,
        val unsyncedEdits: Int,
        val message: String,
    ) : WalkStep()

    /** Download failed. Retry [sequence]. The cursor stays put. */
    data class Retry(
        val base: ArchiveSnapshot,
        val pending: ArchiveSnapshot,
        val verifiedThrough: VerifiedCursor,
        val sequence: Long,
        val reason: String,
    ) : WalkStep()
}

private fun unsyncedEditCount(base: ArchiveSnapshot, pending: ArchiveSnapshot): Int {
    val baseJson = ArchiveJson.encodeSnapshot(base)
    val pendingJson = ArchiveJson.encodeSnapshot(pending)
    return differingIds(baseJson, pendingJson, "records")
}

private fun differingIds(base: JsonObject, pending: JsonObject, key: String): Int {
    val left = entitiesById(base, key)
    val right = entitiesById(pending, key)
    var count = 0
    for (id in left.keys + right.keys) {
        if (canonicalEntity(left[id]) != canonicalEntity(right[id])) count += 1
    }
    return count
}

private fun entitiesById(snapshot: JsonObject, key: String): Map<String, JsonObject> {
    return snapshot.getValue(key).jsonArray.associate { element ->
        val objectValue = element.jsonObject
        objectValue.getValue("id").jsonPrimitive.content to objectValue
    }
}

private fun canonicalEntity(entity: JsonObject?): String {
    if (entity == null) return ""
    val stripped = JsonObject(
        entity.filterKeys { it != "mediaOverflow" },
    )
    return canonicalJson(stripped)
}
