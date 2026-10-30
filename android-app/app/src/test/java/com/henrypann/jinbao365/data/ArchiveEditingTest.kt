package com.henrypann.jinbao365.data

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.henrypann.jinbao365.archive.*
import com.henrypann.jinbao365.editing.*
import com.henrypann.jinbao365.media.CaptureTime
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.SQLiteMode
import java.time.Instant
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@SQLiteMode(SQLiteMode.Mode.NATIVE)
class ArchiveEditingTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val database = Room.inMemoryDatabaseBuilder(context, ArchiveDatabase::class.java).allowMainThreadQueries().build()
    private val repository = ArchiveRepository(database)
    @After fun close() { database.close() }

    @Test fun draftsRemainLocalAndSaveIsAtomicAndIdempotent() {
        val draft = repository.createDraft("phone", 100, "draft")
        assertTrue(repository.loadSnapshot().records.isEmpty())
        assertEquals(draft, repository.loadDraft("draft"))
        invalid { repository.commitDraft("draft") }
        assertEquals(draft, repository.loadDraft("draft"))
        assertTrue(repository.loadSnapshot().records.isEmpty())
        repository.updateDraft("draft", "phone", 101) { it.copy(title = "  A day  ", note = "Remember") }
        val saved = repository.commitDraft("draft")
        assertEquals("  A day  ", saved.title!!.value.jsonPrimitive.content)
        assertEquals(saved, repository.commitDraft("draft"))
        assertEquals(1, repository.loadSnapshot().records.size)
        assertNull(repository.loadDraft("draft"))
        assertTrue(repository.loadDrafts().isEmpty())
        invalid { repository.createDraft("phone", 102, "draft") }
    }

    @Test fun unicodeWhitespaceAndUtf16LimitsMatchManualSaveRules() {
        repository.createDraft("phone", 100, "draft")
        repository.updateDraft("draft", "phone", 101) { it.copy(title = "\u0085\u00a0\u200b\u202f", note = "\t\n\u3000") }
        invalid { repository.commitDraft("draft") }
        repository.updateDraft("draft", "phone", 102) { it.copy(title = "😀".repeat(101)) }
        invalid { repository.commitDraft("draft") }
        repository.updateDraft("draft", "phone", 103) { it.copy(title = "😀".repeat(100), note = "a".repeat(10_001)) }
        invalid { repository.commitDraft("draft") }
        repository.updateDraft("draft", "phone", 104) { it.copy(note = "a".repeat(10_000)) }
        assertEquals(200, repository.commitDraft("draft").title!!.value.jsonPrimitive.content.length)
        repository.createDraft("phone", 105, "invisible")
        repository.updateDraft("invisible", "phone", 106) { it.copy(note = "\ufeff") }
        repository.commitDraft("invisible") // Foundation does not classify BOM as whitespace.
        assertTrue(hasRecordText("\u001c", "")) // Java whitespace includes this separator; Foundation does not.
    }

    @Test fun thirtyMediaCommitAndThirtyFirstAppendIsAtomic() {
        repository.createDraft("phone", 100, "draft")
        invalid { repository.appendDraftMedia("draft", emptyList()) }
        assertEquals(0L, repository.loadDraft("draft")!!.revision)
        val saved = repository.appendDraftMedia("draft", (1..30).map(::media))
        assertEquals(30, momentDraft(saved.record).assetIds.size)
        assertTrue(repository.loadSnapshot().assets.isEmpty())
        assertEquals(30, repository.retainedObjectKeys().size)
        invalid { repository.appendDraftMedia("draft", listOf(media(31))) }
        assertEquals(saved, repository.loadDraft("draft"))
        assertEquals(30, repository.retainedObjectKeys().size)
        val committed = repository.commitDraft("draft")
        assertEquals(30, momentDraft(committed).assetIds.size)
        assertEquals(30, repository.loadSnapshot().assets.size)
    }

    @Test fun invalidCommitDoesNotCopyDraftMediaOrConsumeDraft() {
        repository.createDraft("phone", 100, "draft")
        repository.appendDraftMedia("draft", listOf(media(1)))
        val before = repository.updateDraft("draft", "phone", 101) { it.copy(title = "x".repeat(201)) }
        invalid { repository.commitDraft("draft") }
        assertEquals(before, repository.loadDraft("draft"))
        assertEquals(ArchiveSnapshot.empty(), repository.loadSnapshot())
        assertEquals(setOf(media(1).resources.single().objectKey), repository.retainedObjectKeys())
    }

    @Test fun recordMediaAppendDeduplicatesInOrderAndChangesOnlyTheAssetIdsEnvelope() {
        val original = record("record", listOf("asset-1")).let { it.copy(
            assetIds = it.assetIds.copy(extra = mapOf("future" to JsonPrimitive("keep"))),


            unknownFields = mapOf("futureRecord" to field(JsonPrimitive("keep"))),
            extensions = mapOf("vendor" to field(JsonPrimitive("keep"))),
        ) }
        val before = repository.importRecord(original, listOf(media(1)))
        repository.createDraft("phone", 100, "other-draft")
        repository.appendDraftMedia("other-draft", listOf(media(2)))
        val duplicate = media(4).let { candidate -> candidate.copy(resources = listOf(
            candidate.resources.single().copy(sha256 = media(1).resources.single().sha256, objectKey = media(1).resources.single().objectKey),
        )) }
        val appended = repository.appendRecordMedia("record", listOf(media(3), duplicate, media(2), media(3)), before, "new-phone", 200)
        assertEquals(listOf("asset-1", "asset-3", "asset-2"), assetIds(appended))
        assertEquals(EditStamp(before.assetIds.edit.counter + 1, 200, "new-phone"), appended.assetIds.edit)
        assertEquals(before.assetIds.extra, appended.assetIds.extra)
        assertEquals(before, appended.copy(assetIds = before.assetIds))
        assertEquals(setOf("asset-1", "asset-2", "asset-3"), repository.loadSnapshot().assets.map { it.id }.toSet())
        assertEquals(3, repository.loadSnapshot().resources.size)
        assertEquals(appended, repository.appendRecordMedia("record", listOf(duplicate), appended, "new-phone", 201))
        assertEquals(appended, repository.loadSnapshot().records.single())
    }

    @Test fun emptyAndThirtyFirstRecordMediaAreRejectedWithoutWriting() {
        val before = repository.importRecord(record("record", (1..30).map { "asset-$it" }), (1..30).map(::media))
        val snapshot = repository.loadSnapshot()
        invalid { repository.appendRecordMedia("record", emptyList(), before, "phone", 101) }
        val error = assertThrows(ArchiveValidationException::class.java) {
            repository.appendRecordMedia("record", listOf(media(31)), before, "phone", 101)
        }
        assertEquals("Choose 0–30 distinct media items.", error.message)
        assertEquals(snapshot, repository.loadSnapshot())
    }

    @Test fun staleRecordMediaAppendIsRejectedWithoutWriting() {
        val original = repository.importRecord(record("record", listOf("asset-1")), listOf(media(1)))
        repository.editRecord("record", "phone", 101) { it.copy(note = "Newer edit") }
        val snapshot = repository.loadSnapshot()
        val error = assertThrows(ArchiveValidationException::class.java) {
            repository.appendRecordMedia("record", listOf(media(2)), original, "phone", 102)
        }
        assertEquals("This record changed. Reload before saving.", error.message)
        assertEquals(snapshot, repository.loadSnapshot())
    }

    @Test fun missingAndTrashedRecordsRejectMediaAppendWithoutWriting() {
        repository.importRecord(record("record", listOf("asset-1")), listOf(media(1)))
        val trashed = repository.trashRecord("record", "phone", 101)
        val snapshot = repository.loadSnapshot()
        invalid { repository.appendRecordMedia("missing", listOf(media(2)), null, "phone", 102) }
        val error = assertThrows(ArchiveValidationException::class.java) {
            repository.appendRecordMedia("record", listOf(media(2)), trashed, "phone", 102)
        }
        assertEquals("Restore this record before editing it.", error.message)
        assertEquals(snapshot, repository.loadSnapshot())
    }

    @Test fun draftCaptureSelectsTheEarliestTimeAfterTheFloorAndIgnoresEpoch() {
        val now = Instant.parse("2026-10-11T00:00:00Z").toEpochMilli()
        val normal = Instant.parse("2026-10-01T00:00:00Z").toEpochMilli()
        repository.createDraft("phone", now, "draft")
        val draft = repository.appendDraftMedia("draft", listOf(
            media(1, CaptureTime.zoneUnknown(0), now),
            media(2, CaptureTime.zoneUnknown(normal + 86_400_000L), now),
            media(3, CaptureTime.offsetKnown(normal, "+08:00"), now),
            media(4, CaptureTime.zoneUnknown(now + 86_400_001L), now),
        ))
        assertEquals(JsonObject(mapOf("utc" to JsonPrimitive(normal), "utcOffset" to JsonPrimitive("+08:00"))), draft.record.occurredAt.value)
        assertEquals(CaptureTime.zoneUnknown(0), draft.assets.first { it.id == "asset-1" }.capturedAt.value)
    }

    @Test fun unknownAndPreFloorDraftCapturesKeepTheEstimatedImportTimeFallback() {
        val now = Instant.parse("2026-10-11T00:00:00Z").toEpochMilli()
        repository.createDraft("phone", now - 100, "draft")
        val draft = repository.appendDraftMedia("draft", listOf(
            media(1, CaptureTime.zoneUnknown(0), now),
            media(2, CaptureTime.zoneUnknown(315_619_199_999L), now),
            media(3, CaptureTime.unknown(), now),
        ))
        assertEquals(JsonObject(mapOf("utc" to JsonPrimitive(now), "zoneUnknown" to JsonPrimitive(true),
            "estimated" to JsonPrimitive(true))), draft.record.occurredAt.value)
    }

    @Test fun draftCaptureIncludesTheFloorAndDoesNotApplyAnImportFutureLimit() {
        val now = Instant.parse("2026-10-11T00:00:00Z").toEpochMilli()
        listOf(315_619_200_000L, now + 2 * 86_400_000L).forEachIndexed { index, utc ->
            val id = "draft-$index"
            repository.createDraft("phone", now, id)
            val draft = repository.appendDraftMedia(id, listOf(media(index + 1, CaptureTime.zoneUnknown(utc), now)))
            assertEquals(JsonObject(mapOf("utc" to JsonPrimitive(utc), "zoneUnknown" to JsonPrimitive(true))), draft.record.occurredAt.value)
        }
    }

    @Test fun snapshotAndRepositoryReloadPreserveStoredFutureRecordAndCaptureTimes() {
        val now = Instant.parse("2026-10-11T00:00:00Z").toEpochMilli()
        val future = now + 2 * 86_400_000L
        val stored = media(1, CaptureTime.offsetKnown(future, "+08:00"), now)
        val occurred = JsonObject(mapOf("utc" to JsonPrimitive(future), "utcOffset" to JsonPrimitive("+08:00")))
        val original = record("record", listOf(stored.asset.id)).copy(occurredAt = field(occurred))
        val snapshot = ArchiveSnapshot.empty().copy(records = listOf(original), assets = listOf(stored.asset), resources = stored.resources)
        repository.saveSnapshot(snapshot)

        val reloaded = ArchiveRepository(database).loadSnapshot()
        val reparsed = ArchiveJson.parseSnapshot(ArchiveJson.encodeSnapshot(reloaded))
        for (read in listOf(reloaded, reparsed)) {
            assertEquals(original.occurredAt, read.records.single().occurredAt)
            assertEquals(stored.asset.capturedAt, read.assets.single().capturedAt)
            assertEquals(ArchiveOrder.of(snapshot), ArchiveOrder.of(read))
        }
    }

    @Test fun draftReusingStoredFutureCaptureDerivesTheSameTimeBeforeAndAfterThatDate() {
        val now = Instant.parse("2026-10-11T00:00:00Z").toEpochMilli()
        val future = now + 2 * 86_400_000L
        val stored = media(1, CaptureTime.offsetKnown(future, "+08:00"), now)
        val occurred = JsonObject(mapOf("utc" to JsonPrimitive(future), "utcOffset" to JsonPrimitive("+08:00")))
        val original = record("record", listOf(stored.asset.id)).copy(occurredAt = field(occurred))
        repository.saveSnapshot(ArchiveSnapshot.empty().copy(records = listOf(original), assets = listOf(stored.asset), resources = stored.resources))

        listOf(now, now + 3 * 86_400_000L).forEachIndexed { index, importTime ->
            val id = "draft-$index"
            repository.createDraft("phone", importTime, id)
            val duplicate = media(index + 2, CaptureTime.unknown(), importTime).let { candidate -> candidate.copy(resources = listOf(
                candidate.resources.single().copy(sha256 = stored.resources.single().sha256, objectKey = stored.resources.single().objectKey),
            )) }
            val draft = repository.appendDraftMedia(id, listOf(duplicate))
            assertEquals(listOf(stored.asset.id), assetIds(draft.record))
            assertEquals(occurred, draft.record.occurredAt.value)
            assertEquals(stored.asset.capturedAt, draft.assets.single().capturedAt)
            assertEquals(draft, repository.loadDraft(id))
        }
        val reloaded = repository.loadSnapshot()
        assertEquals(original.occurredAt, reloaded.records.single().occurredAt)
        assertEquals(stored.asset.capturedAt, reloaded.assets.single().capturedAt)
    }

    @Test fun lastMediaHasThreeDistinctOutcomesAndKeepsOriginalReferences() {
        repository.createDraft("phone", 100, "text")
        repository.appendDraftMedia("text", listOf(media(1)))
        repository.updateDraft("text", "phone", 101) { it.copy(title = "Memory",  ) }
        repository.commitDraft("text")
        assertEquals(MediaRemoval.Updated, repository.removeRecordMedia("text", "asset-1", "phone", 102))
        val text = repository.loadSnapshot().records.single()
        assertTrue(text.tombstone.isNullValue())

        repository.createDraft("phone", 100, "blank")
        repository.appendDraftMedia("blank", listOf(media(2)))
        val before = repository.loadDraft("blank")
        assertEquals(MediaRemoval.NeedsDiscardConfirmation, repository.removeDraftMedia("blank", "asset-2", "phone", 103))
        assertEquals(before, repository.loadDraft("blank"))
        assertEquals(MediaRemoval.DraftDiscarded, repository.removeDraftMedia("blank", "asset-2", "phone", 104, true))
        assertNull(repository.loadDraft("blank"))

        repository.createDraft("phone", 100, "saved")
        repository.appendDraftMedia("saved", listOf(media(3)))
        repository.commitDraft("saved")
        assertEquals(MediaRemoval.MovedToTrash, repository.removeRecordMedia("saved", "asset-3", "phone", 105))
        val trash = repository.loadSnapshot().records.first { it.id == "saved" }
        assertFalse(trash.tombstone.isNullValue())
        assertEquals(listOf("asset-3"), momentDraft(trash).assetIds)
        assertEquals(setOf(media(1).resources.single().objectKey, media(3).resources.single().objectKey), repository.retainedObjectKeys())
        assertTrue(repository.restoreRecord("saved", "phone", 106).tombstone.isNullValue())
    }

    @Test fun changedFieldsRetainExtrasAndUnchangedFieldsKeepExactEnvelopes() {
        val stamp = EditStamp(7, 20, "old", mapOf("futureClock" to JsonPrimitive("clock")))
        val extra = mapOf("future" to JsonPrimitive("envelope"))
        val original = record("record", listOf("asset-1")).let {
            it.copy(title = it.title!!.copy(extra = extra), note = it.note.copy(edit = stamp, extra = extra),
                unknownFields = mapOf("futureRecord" to field(JsonPrimitive("keep"))),
                extensions = mapOf("vendor" to field(JsonPrimitive("keep"))))
        }
        repository.importRecord(original, listOf(media(1)))
        val edited = repository.editRecord("record", "phone", 101, expectedRecord = original.copy(mediaOverflow = false, )) {
            it.copy(title = "Changed")
        }
        assertEquals(extra, edited.title!!.extra)
        assertEquals(original.note, edited.note)
        assertEquals(original.createdAt, edited.createdAt)
        assertEquals(original.unknownFields, edited.unknownFields)
        assertEquals(original.extensions, edited.extensions)
        invalid { repository.editRecord("record", "phone", 102, expectedRecord = original) { it.copy(note = "Stale") } }
        assertEquals("", repository.loadSnapshot().records.single().note.value.jsonPrimitive.content)
    }

    @Test fun legacyAbsentTitleAndTimeValueExtrasSurviveUnrelatedEdits() {
        val legacy = record("legacy", listOf("asset-1")).let { record -> record.copy(
            title = null,
            occurredAt = record.occurredAt.copy(value = JsonObject(record.occurredAt.value.jsonObject +
                ("futureTime" to JsonPrimitive("preserved"))))
        ) }
        repository.importRecord(legacy, listOf(media(1)))
        assertNull(repository.loadSnapshot().records.single().title)
        val edited = repository.editRecord("legacy", "phone", 101) { it.copy(note = "Notes", occurredAtMillis = 50) }
        assertNull(edited.title)
        assertEquals("preserved", edited.occurredAt.value.jsonObject.getValue("futureTime").jsonPrimitive.content)
        assertEquals(legacy.createdAt, edited.createdAt)
        assertNull(repository.loadSnapshot().records.single().title)
    }

    @Test fun removingDraftMediaReleasesOnlyItsOwnReferences() {
        repository.createDraft("phone", 100, "draft")
        repository.appendDraftMedia("draft", listOf(media(1), media(2)))
        assertEquals(MediaRemoval.Updated, repository.removeDraftMedia("draft", "asset-1", "phone", 101))
        val remaining = repository.loadDraft("draft")!!
        assertEquals(listOf("asset-2"), remaining.assets.map { it.id })
        assertEquals(setOf(media(2).resources.single().objectKey), repository.retainedObjectKeys())
        repository.updateDraft("draft", "phone", 102) { it.copy(title = "Text") }
        assertEquals(MediaRemoval.Updated, repository.removeDraftMedia("draft", "asset-2", "phone", 103))
        assertTrue(repository.loadDraft("draft")!!.assets.isEmpty())
        assertTrue(repository.retainedObjectKeys().isEmpty())
    }

    @Test fun identicalBytesWithConflictingKindFailClosed() {
        repository.importRecord(record("photo", listOf("asset-1")), listOf(media(1)))
        repository.createDraft("phone", 100, "draft")
        val conflicting = media(1).let { it.copy(asset = it.asset.copy(kind = "video")) }
        val before = repository.loadSnapshot()
        val draft = repository.loadDraft("draft")
        invalid { repository.appendDraftMedia("draft", listOf(conflicting)) }
        invalid { repository.importRecord(record("video", listOf("asset-1")), listOf(conflicting)) }
        assertEquals(before, repository.loadSnapshot())
        assertEquals(draft, repository.loadDraft("draft"))
    }

    @Test fun restoreThenDeleteCreatesANewDeletionGenerationWithoutReusingPublishClock() {
        repository.importRecord(record("record", listOf("asset-1")), listOf(media(1)))
        repository.trashRecord("record", "phone", 101)
        val first = ArchiveEdits.stampFirstPublish(repository.loadSnapshot(), ArchiveSnapshot.empty(), 102)
        repository.saveSnapshot(first)
        repository.restoreRecord("record", "phone", 103)
        val second = repository.trashRecord("record", "phone", 104)
        assertTrue(second.tombstone.extra.containsKey("deletionGeneration"))
        assertFalse(second.tombstone.value.jsonObject.containsKey("firstPublishedAt"))
        val published = ArchiveEdits.stampFirstPublish(repository.loadSnapshot(), first, 105)
        assertEquals(105L, published.records.single().tombstone.value.jsonObject.getValue("firstPublishedAt").jsonPrimitive.long)
    }

    @Test fun readOnlyGateRejectsEveryEditWithoutChangingDraftOrArchive() {
        repository.importRecord(record("record", listOf("asset-1")), listOf(media(1)))
        val draft = repository.createDraft("phone", 100, "draft")
        val snapshot = repository.loadSnapshot()
        repository.saveLocalSyncState(LocalSyncState("phone", 4, "hash", true))
        val actions = listOf<() -> Any?>(
            { repository.createDraft("phone", 101) }, { repository.updateDraft("draft", "phone", 101) { it.copy(title = "x") } },
            { repository.discardDraft("draft") }, { repository.commitDraft("draft") },
            { repository.appendDraftMedia("draft", listOf(media(2))) },
            { repository.appendRecordMedia("record", listOf(media(2)), null, "phone", 101) },
            { repository.importRecord(record("another", listOf("asset-2")), listOf(media(2))) },
            { repository.editRecord("record", "phone", 101) { it.copy(title = "x") } },
            { repository.removeDraftMedia("draft", "asset-1", "phone", 101, true) },
            { repository.removeRecordMedia("record", "asset-1", "phone", 101) },
            { repository.trashRecord("record", "phone", 101) }, { repository.restoreRecord("record", "phone", 101) },
            { repository.saveManualRecord(snapshot.records.single()) },
            { repository.saveSnapshot(snapshot) }, { repository.saveLocalSyncState(LocalSyncState("phone", 4, "hash", false)) },
        )
        actions.forEach { action ->
            try { action(); fail("edit bypassed resync") } catch (error: ArchiveValidationException) { assertTrue(error.message!!.contains("read-only")) }
        }
        assertEquals(snapshot, repository.loadSnapshot())
        assertEquals(draft, repository.loadDraft("draft"))
        repository.replaceWithChainTip(snapshot)
        repository.updateDraft("draft", "phone", 102) { it.copy(title = "Writable") }
    }

    @Test fun concurrentWritersOnIndependentRepositoriesDoNotLoseRecords() {
        val repositories = (1..4).map { ArchiveRepository(database) }
        val pool = Executors.newFixedThreadPool(4)
        val start = CountDownLatch(1)
        try {
            val futures = (1..16).map { i -> pool.submit {
                start.await()
                val repo = repositories[i % repositories.size]
                repo.createDraft("phone", 100, "draft-$i")
                repo.updateDraft("draft-$i", "phone", 101) { it.copy(title = "Record $i") }
                repo.commitDraft("draft-$i")
            } }
            start.countDown()
            futures.forEach { it.get(30, TimeUnit.SECONDS) }
            assertEquals((1..16).map { "draft-$it" }.toSet(), repository.loadSnapshot().records.map { it.id }.toSet())
            assertTrue(repository.loadDrafts().isEmpty())
        } finally { pool.shutdownNow() }
    }

    @Test fun syncGateCannotChangeBetweenEditReadAndCommit() {
        repository.createDraft("phone", 100, "record")
        repository.updateDraft("record", "phone", 101) { it.copy(title = "Before") }
        repository.commitDraft("record")
        val insideEdit = CountDownLatch(1)
        val releaseEdit = CountDownLatch(1)
        val gateAttempted = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(2)
        try {
            val edit = pool.submit {
                repository.editRecord("record", "phone", 102) {
                    insideEdit.countDown()
                    check(releaseEdit.await(10, TimeUnit.SECONDS))
                    it.copy(title = "Committed before gate")
                }
            }
            assertTrue(insideEdit.await(10, TimeUnit.SECONDS))
            val gate = pool.submit {
                gateAttempted.countDown()
                ArchiveRepository(database).saveLocalSyncState(LocalSyncState("phone", null, null, true))
            }
            assertTrue(gateAttempted.await(10, TimeUnit.SECONDS))
            releaseEdit.countDown()
            edit.get(20, TimeUnit.SECONDS)
            gate.get(20, TimeUnit.SECONDS)
            assertEquals("Committed before gate", momentDraft(repository.loadSnapshot().records.single()).title)
            invalid { repository.editRecord("record", "phone", 103) { it.copy(note = "Blocked") } }
            assertTrue(repository.localSyncState()!!.resyncFromStart)
        } finally { releaseEdit.countDown(); pool.shutdownNow() }
    }

    @Test fun draftRevisionRejectsOldEditorAndCaptureRetainsUnknownState() {
        val draft = repository.createDraft("phone", 100, "draft")
        repository.appendDraftMedia("draft", listOf(media(1)))
        invalid { repository.updateDraft("draft", "phone", 102, expectedRevision = draft.revision) { it.copy(title = "Old") } }
        val stored = repository.loadDraft("draft")!!
        val occurred = stored.record.occurredAt.value.jsonObject
        assertEquals(true, occurred.getValue("estimated").jsonPrimitive.boolean)
        assertEquals(true, occurred.getValue("zoneUnknown").jsonPrimitive.boolean)
        assertFalse(occurred.containsKey("timeZone"))
        assertEquals(JsonObject(mapOf("timeUnknown" to JsonPrimitive(true))), stored.assets.single().capturedAt.value)
    }

    @Test fun manualTimeBoundsAreNarrowerThanWireIntegerBounds() {
        repository.createDraft("phone", 100, "time")
        invalid { repository.updateDraft("time", "phone", 101) { it.copy(occurredAtMillis = -1) } }
        invalid { repository.updateDraft("time", "phone", 101) { it.copy(occurredAtMillis = MAX_MANUAL_TIME_MILLIS + 1) } }
        repository.updateDraft("time", "phone", 101) { it.copy(title = "Epoch", occurredAtMillis = 0) }
        assertEquals(0L, momentDraft(repository.commitDraft("time")).occurredAtMillis)
        repository.createDraft("phone", 100, "upper")
        repository.updateDraft("upper", "phone", 101) { it.copy(title = "Upper", occurredAtMillis = MAX_MANUAL_TIME_MILLIS) }
        assertEquals(MAX_MANUAL_TIME_MILLIS, momentDraft(repository.commitDraft("upper")).occurredAtMillis)
    }

    @Test fun draftAndSyncStateSurviveCloseAndReopenWithoutEnteringSnapshot() {
        val name = "draft-reopen-${UUID.randomUUID()}.db"
        fun open() = Room.databaseBuilder(context, ArchiveDatabase::class.java, name).allowMainThreadQueries().build()
        try {
            var db = open()
            val first = ArchiveRepository(db)
            first.reconcileOwner("phone")
            first.saveLocalSyncState(LocalSyncState("phone", 7, "hash7", false))
            first.createDraft("phone", 100, "persisted")
            first.appendDraftMedia("persisted", listOf(media(1)))
            val expected = first.updateDraft("persisted", "phone", 102) { it.copy(title = "After restart", note = "Notes", occurredAtMillis = 50) }
            db.close()
            db = open()
            try {
                val second = ArchiveRepository(db)
                assertEquals(expected, second.loadDraft("persisted"))
                assertEquals(LocalSyncState("phone", 7, "hash7", false), second.localSyncState())
                assertEquals(ArchiveSnapshot.empty(), second.loadSnapshot())
                second.commitDraft("persisted")
            } finally { db.close() }
            db = open()
            try { assertEquals(1, ArchiveRepository(db).loadSnapshot().records.size) } finally { db.close() }
        } finally { context.deleteDatabase(name) }
    }

    private fun invalid(block: () -> Any?) {
        try { block(); fail("invalid operation succeeded") } catch (_: ArchiveValidationException) { }
    }
    private fun field(value: JsonElement) = FieldEnvelope(value, EditStamp(1, 100, "phone"))
    private fun record(id: String, ids: List<String>) = ArchiveRecord(id, field(JsonPrimitive("")), field(JsonPrimitive("")),
        field(JsonObject(mapOf("utc" to JsonPrimitive(100), "zoneUnknown" to JsonPrimitive(true)))), field(JsonPrimitive(100)),
        field(JsonArray(ids.map(::JsonPrimitive))), field(JsonNull), emptyMap())
    private fun media(index: Int, capture: JsonObject = CaptureTime.unknown(), nowMillis: Long = 100): ImportedMedia {
        val hash = index.toString(16).padStart(64, '0')
        val resource = MediaResource("resource-$index", "asset-$index", "photo", "image/jpeg", "photo.jpg", 1, hash,
            "objects/${hash.take(2)}/$hash", emptyMap())
        return ImportedMedia(MediaAsset("asset-$index", "photo", FieldEnvelope(capture, EditStamp(1, nowMillis, "phone")),
            listOf(resource.id), emptyMap()), listOf(resource))
    }
}
