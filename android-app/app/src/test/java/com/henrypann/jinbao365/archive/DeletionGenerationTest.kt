package com.henrypann.jinbao365.archive

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class DeletionGenerationTest {
    private val old = 1_700_000_000_000L
    private val now = old + 40L * 86_400_000L
    private fun stamp(counter: Long, at: Long = now) = EditStamp(counter, at, "phone")
    private val oldDelete get() = applyPublishClock(ArchiveEdits.tombstone(old, stamp(1, old)), old)
    private fun redelete(): FieldEnvelope {
        val restored = ArchiveEdits.restore(oldDelete, stamp(2, old + 29L * 86_400_000L))
        return ArchiveEdits.tombstone(now, stamp(3), restored)
    }
    private fun snapshot(tombstone: FieldEnvelope): ArchiveSnapshot {
        fun field(v: JsonElement) = FieldEnvelope(v, stamp(1, old))
        return ArchiveSnapshot.empty().copy(
            records = listOf(ArchiveRecord(
                "record", field(JsonPrimitive("Title")), field(JsonPrimitive("")),
                field(buildJsonObject { put("utc", old); put("timeZone", "UTC") }),
                field(JsonPrimitive(old)), field(JsonArray(emptyList())), tombstone, emptyMap(),
            )),

        )
    }
    private fun assertProtocolFailure(block: () -> Unit) {
        try { block(); fail("expected protocol failure") } catch (_: ArchiveProtocolException) { }
    }

    @Test fun offlineRestoreThenRedeleteGetsThirtyDaysForRecords() {
        val pending = snapshot(redelete())
        val published = snapshot(oldDelete)
        val merged = ArchiveMerge.merge(published, pending, published)
        val candidate = ArchiveEdits.stampFirstPublish(merged, published, now)
        val kept = ArchiveEdits.purgeExpired(candidate, now, published)
        for (tomb in listOf(kept.records.single().tombstone)) {
            assertEquals(now, readFirstPublishedAt(tomb))
            assertEquals(now + PURGE_WINDOW_MILLIS, readPurgeAfter(tomb))
            assertEquals(deletionGeneration(pending.records.single().tombstone), deletionGeneration(tomb))
        }
        assertEquals(1, ArchiveEdits.purgeExpired(candidate, now + PURGE_WINDOW_MILLIS - 1, candidate).records.size)
        val purged = ArchiveEdits.purgeExpired(candidate, now + PURGE_WINDOW_MILLIS, candidate)
        assertTrue(purged.records.isEmpty())
    }

    @Test fun restoreMetadataSurvivesNullPersistenceAndRepeatedDelete() {
        val previous = oldDelete.copy(extra = mapOf("hint" to JsonPrimitive("keep")))
        val restored = ArchiveEdits.restore(previous, stamp(2))
        val saved = ArchiveJson.parseSnapshot(ArchiveJson.canonical(snapshot(restored))).records.single().tombstone
        assertTrue(saved.isNullValue()); assertEquals(deletionGeneration(restored), deletionGeneration(saved))
        assertNull(saved.conflict); assertEquals(JsonPrimitive("keep"), saved.extra["hint"])
        val first = applyPublishClock(ArchiveEdits.tombstone(now, stamp(3), saved), now)
        val repeat = ArchiveEdits.tombstone(now + 1, stamp(4), first)
        assertEquals(now, readFirstPublishedAt(repeat))
        assertEquals(deletionGeneration(restored), deletionGeneration(repeat))
        val next = ArchiveEdits.restore(repeat, stamp(5))
        assertNotEquals(deletionGeneration(saved), deletionGeneration(next))
        assertProtocolFailure { ArchiveEdits.restore(next, stamp(5)) }
    }

    @Test fun oldCycleOmissionKeepsNewCycleForRecordsThroughTheWalk() {
        val base = snapshot(oldDelete)
        val local = snapshot(redelete())
        val advanced = ArchiveSync.advanceOne(base, local, VerifiedCursor(1, "one"),
            CommitFetch.Found(2, ArchiveSnapshot.empty(), "two", parentHash = "one")) as WalkStep.Advanced
        assertEquals(1, advanced.pending.records.size)
        val candidate = ArchiveEdits.stampFirstPublish(advanced.pending, advanced.base, now)
        assertEquals(now, readFirstPublishedAt(candidate.records.single().tombstone))
        assertEquals(ArchiveJson.canonical(ArchiveMerge.merge(base, local, ArchiveSnapshot.empty())),
            ArchiveJson.canonical(ArchiveMerge.merge(base, ArchiveSnapshot.empty(), local)))
    }

    @Test fun lostGenerationFailsClosedForMergeStampAndPurgeIncludingOmission() {
        val base = snapshot(redelete())
        val lost = snapshot(redelete().copy(extra = emptyMap()))
        assertProtocolFailure { ArchiveMerge.merge(base, lost, base) }
        assertProtocolFailure { ArchiveMerge.merge(base, base, lost) }
        assertProtocolFailure { ArchiveMerge.merge(base, lost, ArchiveSnapshot.empty()) }
        assertProtocolFailure { ArchiveEdits.stampFirstPublish(lost, base, now) }
        assertProtocolFailure { ArchiveEdits.purgeExpired(lost, now, base) }
    }

    @Test fun knownGenerationClockCannotBeAuthorizedByLegacyOrLivePublishedState() {
        val pending = snapshot(applyPublishClock(redelete(), now))
        val restored = snapshot(ArchiveEdits.restore(oldDelete, stamp(2)))
        for (published in listOf(snapshot(oldDelete), restored, snapshot(redelete()))) {
            val result = ArchiveEdits.purgeExpired(pending, now + PURGE_WINDOW_MILLIS, published)
            assertEquals(1, result.records.size)
        }
    }

    @Test fun failedCandidateDoesNotMutatePendingAndRetryStartsAtSuccessfulCommitTime() {
        val pending = snapshot(redelete()); val base = snapshot(oldDelete)
        val before = ArchiveJson.canonical(pending)
        val failedAttempt = ArchiveEdits.stampFirstPublish(pending, base, now)
        val retry = ArchiveEdits.stampFirstPublish(pending, base, now + 10)
        assertEquals(before, ArchiveJson.canonical(pending))
        assertEquals(now, readFirstPublishedAt(failedAttempt.records.single().tombstone))
        assertEquals(now + 10, readFirstPublishedAt(retry.records.single().tombstone))
        val raced = ArchiveMerge.merge(base, pending, failedAttempt)
        assertEquals(now, readFirstPublishedAt(ArchiveEdits.stampFirstPublish(raced, failedAttempt, now + 10).records.single().tombstone))
    }

    @Test fun legacyPublishedDeadlineRemainsReadableAndReusableOnlyInLegacyGeneration() {
        val legacy = ArchiveEdits.tombstone(old, stamp(1, old)).copy(value = buildJsonObject {
            put("deletedAt", old); put("purgeAfter", old + PURGE_WINDOW_MILLIS)
        })
        val published = ArchiveJson.parseSnapshot(ArchiveJson.canonical(snapshot(legacy)))
        val stamped = ArchiveEdits.stampFirstPublish(snapshot(ArchiveEdits.tombstone(now, stamp(3))), published, now)
        assertNull(readFirstPublishedAt(stamped.records.single().tombstone))
        assertEquals(old + PURGE_WINDOW_MILLIS, readPurgeAfter(stamped.records.single().tombstone))
        val restored = ArchiveEdits.restore(legacy, stamp(2))
        val candidate = ArchiveEdits.stampFirstPublish(snapshot(ArchiveEdits.tombstone(now, stamp(3), restored)), published, now)
        assertEquals(now, readFirstPublishedAt(candidate.records.single().tombstone))
    }

    @Test fun malformedGenerationIsRejectedEvenOnNullTombstones() {
        val valid = encodeEditStamp(stamp(2))
        val invalid = listOf<JsonElement>(JsonNull, JsonPrimitive("generation"),
            JsonObject(valid - "at"), JsonObject(valid + ("extra" to JsonPrimitive(1))),
            JsonObject(valid + ("counter" to JsonPrimitive("2"))),
            JsonObject(valid + ("at" to JsonPrimitive(9007199254740992L))),
            JsonObject(valid + ("deviceID" to JsonPrimitive(""))))
        for (generation in invalid) {
            val tomb = FieldEnvelope(JsonNull, stamp(2), extra = mapOf(DELETION_GENERATION to generation))
            assertProtocolFailure { ArchiveJson.parseSnapshot(ArchiveJson.canonical(snapshot(tomb))) }
        }
    }

    @Test fun successiveExplicitGenerationsDoNotSharePublicationOrPurgeProof() {
        val generationOne = ArchiveEdits.restore(oldDelete, stamp(2, old + 1))
        val publishedOne = snapshot(applyPublishClock(ArchiveEdits.tombstone(old + 2, stamp(3, old + 2), generationOne), old + 2))
        val generationTwo = ArchiveEdits.restore(publishedOne.records.single().tombstone, stamp(4))
        val pending = snapshot(ArchiveEdits.tombstone(now, stamp(5), generationTwo))
        val merged = ArchiveMerge.merge(publishedOne, pending, publishedOne)
        assertNull(readFirstPublishedAt(merged.records.single().tombstone))
        val publishedTwo = ArchiveEdits.stampFirstPublish(merged, publishedOne, now)
        assertEquals(now, readFirstPublishedAt(publishedTwo.records.single().tombstone))
        assertEquals(1, ArchiveEdits.purgeExpired(publishedTwo, now + PURGE_WINDOW_MILLIS, publishedOne).records.size)
        val omitted = ArchiveMerge.merge(publishedOne, pending, ArchiveSnapshot.empty())
        assertEquals(deletionGeneration(generationTwo), deletionGeneration(omitted.records.single().tombstone))
    }

    @Test fun repeatedLegacyDeleteKeepsItsStoredDeadline() {
        val legacy = ArchiveEdits.tombstone(old, stamp(1, old)).copy(value = buildJsonObject {
            put("deletedAt", old); put("purgeAfter", old + PURGE_WINDOW_MILLIS)
        })
        val repeated = ArchiveEdits.tombstone(now, stamp(2), legacy)
        assertEquals(old + PURGE_WINDOW_MILLIS, readPurgeAfter(repeated))
        assertNull(readFirstPublishedAt(repeated))
    }

    @Test fun publishClockCannotOverflowProtocolIntegerRange() {
        assertProtocolFailure { applyPublishClock(redelete(), MAX_PROTOCOL_INTEGER) }
    }
}
