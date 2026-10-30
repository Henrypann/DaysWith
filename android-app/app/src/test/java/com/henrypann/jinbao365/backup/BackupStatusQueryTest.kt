package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.archive.ArchiveRecord
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.archive.EditStamp
import com.henrypann.jinbao365.archive.FieldEnvelope
import com.henrypann.jinbao365.archive.MediaAsset
import com.henrypann.jinbao365.archive.MediaResource
import com.henrypann.jinbao365.storage.StorageConfiguration
import java.util.Base64
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BackupStatusQueryTest {
    private val query: BackupStatusQuery = DefaultBackupStatusQuery()
    private val config = StorageConfiguration(bucket = "jinbao-1250000000", prefix = "life/v1/android/")
    private val created = 1_000L
    private val day = BackupEngine.DAY_MILLIS
    private val now = created + day + 1
    private val recordId = "A57F2B38-076D-4C60-98AA-8B7E0BC638A5"

    @Test fun zeroMediaNoteRequiresAVerifiedCommittedReceipt() {
        val snapshot = snapshot()
        val pending = summary(snapshot)
        assertEquals(0, pending.unbackedOriginalCount)
        assertEquals(1, pending.unbackedRecordCount)
        assertEquals(BackupRecordStatus.Pending, pending.recordStatus(recordId))
        assertFalse(pending.allCovered)
        assertTrue(pending.hasOverdue)
        assertEquals(setOf(recordId), pending.overdueRecordIds)
        val covered = summary(snapshot, complete(snapshot))
        assertEquals(0, covered.unbackedRecordCount)
        assertEquals(BackupRecordStatus.BackedUp, covered.recordStatus(recordId))
        assertTrue(covered.allCovered)
        assertFalse(covered.hasOverdue)
        assertEquals("已备份", covered.statusLine)
    }

    @Test fun frozenButUncommittedNoteDoesNotHaveCoverage() {
        val snapshot = snapshot()
        val manifest = V1Mapper.map(snapshot, config.prefix)
        val pending = BackupPending(Base64.getEncoder().encodeToString(V1Json.encodeManifest(manifest)), "uncommitted", emptyMap())
        val result = summary(snapshot, state().copy(pending = pending, stage = "publishing"))
        assertEquals(BackupRecordStatus.Pending, result.recordStatus(recordId))
        assertNull(result.lastCommitAtMillis)
        assertNull(result.packedThroughMillis)
        assertFalse(result.allCovered)
    }

    @Test fun packedThroughMustCoverTheCurrentEditEvenIfHashesArePresent() {
        val snapshot = snapshot()
        val complete = complete(snapshot)
        for (packedThrough in listOf(null, created - 1)) {
            val result = summary(snapshot, complete.copy(receipt = complete.receipt!!.copy(packedThrough = packedThrough)))
            assertEquals(BackupRecordStatus.Pending, result.recordStatus(recordId))
            assertEquals(1, result.unbackedRecordCount)
        }
    }

    @Test fun editsAfterReceiptReturnNotesToPendingAndResetTextAge() {
        val before = snapshot()
        val edited = before.copy(records = before.records.map { it.copy(note = field(JsonPrimitive("Edited note"), now)) })
        val result = summary(edited, complete(before))
        assertEquals(BackupRecordStatus.Pending, result.recordStatus(recordId))
        assertEquals(1, result.unbackedRecordCount)
        assertFalse(result.hasOverdue)
        assertTrue(query.query(edited, complete(before), now + day + 1).hasOverdue)
    }

    @Test fun exactFingerprintsProtectAgainstSameTimestampEditsAndUnpackedOldRecords() {
        val original = snapshot()
        val state = complete(original).let { it.copy(receipt = it.receipt!!.copy(packedThrough = now)) }
        val edited = original.copy(records = original.records.map { it.copy(note = field(JsonPrimitive("Same timestamp, different text"))) })
        assertEquals(BackupRecordStatus.Pending, summary(edited, state).recordStatus(recordId))
        val secondId = "00000000-0000-4000-8000-000000000002"
        val added = original.copy(records = original.records + note(secondId))
        assertEquals(BackupRecordStatus.BackedUp, summary(added, state).recordStatus(recordId))
        assertEquals(BackupRecordStatus.Pending, summary(added, state).recordStatus(secondId))
    }

    @Test fun eachOriginalRequiresBothVerifiedBytesAndReceiptMembership() {
        val snapshot = snapshot(withMedia = true)
        val complete = complete(snapshot)
        val key = key(snapshot.resources.first())
        for (state in listOf(
            complete.copy(objects = emptyMap()),
            complete.copy(receipt = complete.receipt!!.copy(coveredObjectKeys = emptySet())),
            complete.copy(receipt = null),
        )) {
            val result = summary(snapshot, state)
            assertEquals(1, result.unbackedOriginalCount)
            assertEquals(1, result.overdueOriginalCount)
            assertEquals(1, result.unbackedRecordCount)
        }
        assertEquals(0, summary(snapshot, complete).unbackedOriginalCount)
        assertEquals(0, summary(snapshot, complete).overdueOriginalCount)
        assertEquals(BackupObjectStatus.verified, complete.objects.getValue(key).status)
    }

    @Test fun allCoveredIncludesPreviewsWhileOriginalCountsExcludeThem() {
        val snapshot = snapshot(withMedia = true)
        val complete = complete(snapshot)
        val previewKey = key(snapshot.resources.first { it.role == "preview" })
        val result = summary(snapshot, complete.copy(objects = complete.objects - previewKey))
        assertEquals(0, result.unbackedOriginalCount)
        assertEquals(1, result.unbackedRecordCount)
        assertFalse(result.allCovered)
        assertEquals("尚未备份", result.statusLine)
    }

    @Test fun sharedOriginalsAreCountedOnceAcrossLiveRecords() {
        val base = snapshot(withMedia = true)
        val snapshot = base.copy(records = base.records + base.records.single().copy(id = "other"), )
        val result = summary(snapshot)
        assertEquals(2, result.unbackedRecordCount)
        assertEquals(1, result.unbackedOriginalCount)
        assertEquals(1, result.overdueOriginalCount)
    }

    @Test fun trashedRecordsDoNotContributeToLiveCounts() {
        val base = snapshot(withMedia = true)
        val tombstone = field(JsonObject(mapOf("deletedAt" to JsonPrimitive(now))))
        val snapshot = base.copy(records = base.records.map { it.copy(tombstone = tombstone) }, )
        val result = summary(snapshot)
        assertEquals(0, result.unbackedOriginalCount)
        assertEquals(0, result.unbackedRecordCount)
        assertEquals(0, result.overdueOriginalCount)
        assertFalse(result.hasOverdue)
        assertEquals(BackupRecordStatus.LocalOnly, result.recordStatus(recordId))
    }

    @Test fun twentyFourHourBoundaryUsesOwnerCreationAndNotesUseLastEdit() {
        val snapshot = snapshot(withMedia = true)
        for (time in listOf(created - 1, created, created + day)) {
            assertEquals(0, query.query(snapshot, state(), time).overdueOriginalCount)
            assertFalse(query.query(snapshot, state(), time).hasOverdue)
        }
        assertEquals(1, query.query(snapshot, state(), created + day + 1).overdueOriginalCount)
        val recent = snapshot.copy(records = snapshot.records.map { it.copy(createdAt = field(JsonPrimitive(now), now)) })
        assertEquals(0, summary(recent).overdueOriginalCount)
        val itemSnapshot = recent.copy(records = emptyList(), )
        assertEquals(0, summary(itemSnapshot).overdueOriginalCount)
    }

    @Test fun destinationChangesAndMissingConfigurationCannotReuseReceipt() {
        val snapshot = snapshot(withMedia = true)
        val complete = complete(snapshot)
        for (destination in listOf(null, config.copy(bucket = "different-1250000000"), config.copy(prefix = "life/v1/other/"))) {
            val result = query.query(snapshot, complete, now, coordinator(complete).copy(configuration = destination))
            assertEquals(1, result.unbackedOriginalCount)
            assertEquals(1, result.unbackedRecordCount)
            assertNull(result.lastCommitAtMillis)
            assertNull(result.lastUploadAtMillis)
            assertFalse(result.allCovered)
            if (destination == null) assertEquals(BackupRecordStatus.LocalOnly, result.recordStatus(recordId))
        }
        val local = query.query(snapshot, null, now)
        assertEquals(BackupBlockReason.Connection, local.blockReason)
        assertEquals(BackupRecordStatus.LocalOnly, local.recordStatus(recordId))
        assertEquals(BackupRecordStatus.LocalOnly, local.recordStatus("missing-record"))
    }

    @Test fun failuresAreReportedWithoutPromotingTransientStopsToFailures() {
        val snapshot = snapshot(withMedia = true)
        val originalKey = key(snapshot.resources.first())
        val failed = state().copy(stage = "failed", lastError = "Upload failed.", objects = mapOf(originalKey to
            BackupObjectState(BackupObjectStatus.failed, "Upload failed.", firstQueuedAt = created)))
        val result = summary(snapshot, failed)
        assertEquals(BackupRecordStatus.Failed, result.recordStatus(recordId))
        assertEquals(1, result.failedCount)
        assertEquals(BackupBlockReason.Failed, result.blockReason)
        assertTrue(result.hasFailure)
        assertTrue(result.canRetryFailed)
        for (reason in listOf(BackupFailure.Wifi, BackupFailure.Paused, BackupFailure.Connection, BackupFailure.Credentials, BackupFailure.ReadOnly)) {
            val stopped = failed.copy(lastError = reason.text, objects = failed.objects.mapValues { it.value.copy(lastError = reason.text) })
            val summary = summary(snapshot, stopped)
            assertFalse(summary.recordStatus(recordId) == BackupRecordStatus.Failed)
            assertEquals(0, summary.failedCount)
            assertFalse(summary.hasFailure)
        }
    }

    @Test fun failedZeroMediaPublicationHasOneFailureAndAnAffectedRecord() {
        val snapshot = snapshot()
        val failed = state().copy(stage = "failed", lastError = "Commit read-back failed.")
        val result = summary(snapshot, failed)
        assertEquals(BackupRecordStatus.Failed, result.recordStatus(recordId))
        assertEquals(1, result.failedCount)
        assertEquals(0, result.unbackedOriginalCount)
        assertEquals(1, result.unbackedRecordCount)
    }

    @Test fun readOnlyFailureBlocksManualUploadEvenIfCoordinatorPreviouslyAllowedIt() {
        val snapshot = snapshot()
        val state = state().copy(stage = "failed", lastError = BackupFailure.OtherWriter.text)
        val result = query.query(snapshot, state, now, coordinator(state).copy(canBackUpNow = true, blockReason = BackupBlockReason.Background))
        assertEquals(BackupBlockReason.ReadOnly, result.blockReason)
        assertFalse(result.canBackUpNow)
        assertFalse(result.canRetryFailed)
        assertEquals("仅可查看", result.statusLine)
        // A stored read-only stop also gives a local-only detail status without a coordinator.
        val stopped = query.query(snapshot, state.copy(stage = "waiting", lastError = BackupFailure.ReadOnly.text), now)
        assertEquals(BackupRecordStatus.LocalOnly, stopped.recordStatus(recordId))
        assertEquals(BackupBlockReason.ReadOnly, stopped.blockReason)
    }

    @Test fun timestampsDescribeVerifiedObjectUploadAndCommitSeparately() {
        val snapshot = snapshot()
        val complete = complete(snapshot).copy(lastUploadAtMillis = 5_000L, lastSuccessfulBackupAt = 8_000L,
            receipt = complete(snapshot).receipt!!.copy(publishedAt = 7_000L))
        val result = summary(snapshot, complete)
        assertEquals(5_000L, result.lastUploadAtMillis)
        assertEquals(7_000L, result.lastCommitAtMillis)
        assertEquals(created, result.packedThroughMillis)
        // A note-only archive does not invent an object upload timestamp.
        assertNull(summary(snapshot, complete.copy(lastUploadAtMillis = null)).lastUploadAtMillis)
    }

    @Test fun runtimeProgressWifiPauseAndStateFailureAreProjectedForEveryScreen() {
        val snapshot = snapshot()
        val state = state()
        val progress = BackupProgress("uploading", "key", 2, 5)
        val running = query.query(snapshot, state, now, coordinator(state).copy(running = true, progress = progress))
        assertTrue(running.inProgress)
        assertEquals(progress, running.progress)
        assertEquals("正在备份…", running.statusLine)
        assertFalse(running.canBackUpNow)
        for (reason in listOf(BackupBlockReason.Offline, BackupBlockReason.Metered)) {
            val wifi = query.query(snapshot, state, now, coordinator(state).copy(blockReason = reason, canBackUpNow = true))
            assertEquals(if (reason == BackupBlockReason.Metered) BackupPolicy.WIFI_WAITING else "等待网络", wifi.statusLine)
            assertFalse(wifi.canBackUpNow)
        }
        val paused = query.query(snapshot, state.copy(paused = true), now)
        assertEquals("已暂停，点击立即备份开始", paused.statusLine)
        assertTrue(paused.canBackUpNow)
        assertFalse(paused.canPause)
        assertFalse(paused.canRetryFailed)
        val corrupt = query.query(snapshot, null, now, coordinator(state).copy(blockReason = BackupBlockReason.State, lastError = BackupFailure.StateRead.text))
        assertEquals(BackupBlockReason.State, corrupt.blockReason)
        assertEquals(BackupPolicy.RETRY_MESSAGE, corrupt.statusLine)
        assertTrue(corrupt.hasFailure)
        assertFalse(corrupt.canBackUpNow)
    }

    @Test fun malformedSnapshotFailsClosedWithoutPreventingStatusRendering() {
        val snapshot = snapshot(withMedia = true).let { it.copy(records = it.records.map { record -> record.copy(note = field(JsonPrimitive(123))) }) }
        val result = summary(snapshot, state().copy(stage = "failed", lastError = "Invalid record metadata."))
        assertEquals(BackupRecordStatus.Failed, result.recordStatus(recordId))
        assertEquals(1, result.unbackedOriginalCount)
        assertFalse(result.allCovered)
    }

    @Test fun summaryDefensivelyCopiesItsCollections() {
        val statuses = mutableMapOf(recordId to BackupRecordStatus.Pending)
        val overdue = mutableSetOf(recordId)
        val summary = BackupSummary(recordStatuses = statuses, overdueRecordIds = overdue)
        statuses[recordId] = BackupRecordStatus.BackedUp
        overdue.clear()
        assertEquals(BackupRecordStatus.Pending, summary.recordStatus(recordId))
        assertEquals(setOf(recordId), summary.overdueRecordIds)
    }

    private fun summary(snapshot: ArchiveSnapshot, state: BackupState = state()) = query.query(snapshot, state, now)
    private fun state() = BackupState(bucket = config.bucket, prefix = config.prefix, paused = false)
    private fun coordinator(state: BackupState) = BackupCoordinatorState(state = state, configuration = config,
        paused = state.paused, blockReason = null, canBackUpNow = true)

    private fun complete(snapshot: ArchiveSnapshot): BackupState {
        val manifest = V1Mapper.map(snapshot, config.prefix)
        val keys = manifest.resources.map { it.objectKey }.toSet()
        return state().copy(objects = keys.associateWith { BackupObjectState(BackupObjectStatus.verified, firstQueuedAt = created) },
            receipt = BackupReceipt(1, "commit", V1Json.sha256(V1Json.encodeManifest(manifest)), created,
                keys, BackupEngine.momentHashes(manifest),
                manifest.moments.maxOfOrNull { it.updatedAt }),
            stage = "complete")
    }

    private fun snapshot(withMedia: Boolean = false): ArchiveSnapshot {
        val resources = if (withMedia) listOf(resource("photo"), resource("preview")) else emptyList()
        return ArchiveSnapshot.empty().copy(records = listOf(note().let { if (!withMedia) it else it.copy(assetIds = field(JsonArray(listOf(JsonPrimitive("asset")))) ) }),
            assets = if (!withMedia) emptyList() else listOf(MediaAsset("asset", "photo", field(JsonObject(mapOf("timeUnknown" to JsonPrimitive(true)))),
                resources.map { it.id }, emptyMap())), resources = resources)
    }

    private fun note(id: String = recordId) = ArchiveRecord(id, field(JsonPrimitive("Title")), field(JsonPrimitive("A text-only note")),
        field(JsonObject(mapOf("utc" to JsonPrimitive(created)))), field(JsonPrimitive(created)), field(JsonArray(emptyList())),
        field(JsonNull), emptyMap())
    private fun resource(role: String) = MediaResource(role, "asset", role, "image/jpeg", "$role.jpg", 10,
        V1Json.sha256(role.toByteArray()), "local/$role.jpg", emptyMap())
    private fun key(resource: MediaResource) = "${config.prefix}objects/${resource.sha256.take(2)}/${resource.sha256}"
    private fun field(value: JsonElement, at: Long = created) = FieldEnvelope(value, EditStamp(at, at, "device"))
}
