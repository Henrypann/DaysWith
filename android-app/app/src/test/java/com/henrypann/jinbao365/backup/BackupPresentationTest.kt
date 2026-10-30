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

class BackupPresentationTest {
    private val config = StorageConfiguration(bucket = "jinbao-1250000000", prefix = "life/v1/android/")
    private val created = 1_000L
    private val overdueNow = created + BackupEngine.DAY_MILLIS + 1
    private val stamp = EditStamp(1, created, "local-device")

    @Test fun onlyBecomesOverdueStrictlyAfterTwentyFourHoursFromCreation() {
        val snapshot = snapshot()
        for (now in listOf(created - 1, created, overdueNow - 1)) {
            val result = derive(snapshot, now = now)
            assertEquals(ArchiveBackupBadge.None, result.records.getValue("record").badge)
            assertEquals(0, result.overdueOriginalCount)
        }
        val result = derive(snapshot)
        assertEquals(ArchiveBackupBadge.Overdue, result.records.getValue("record").badge)
        assertEquals(1, result.overdueOriginalCount)
    }

    @Test fun verificationObjectCoverageAndCurrentRecordCoverageAreAllRequired() {
        val snapshot = snapshot()
        val complete = completeState(snapshot)
        val receipt = checkNotNull(complete.receipt)
        val cases = listOf(
            complete.copy(receipt = null),
            complete.copy(objects = emptyMap()),
            complete.copy(receipt = receipt.copy(coveredObjectKeys = emptySet())),
            complete.copy(receipt = receipt.copy(coveredMomentHashes = emptyMap())),
        )
        for (state in cases) {
            val result = derive(snapshot, state)
            assertFalse(result.records.getValue("record").backedUp)
            assertEquals(ArchiveBackupBadge.Overdue, result.records.getValue("record").badge)
            assertEquals(1, result.overdueOriginalCount)
        }
        val result = derive(snapshot, complete)
        assertTrue(result.records.getValue("record").backedUp)
        assertEquals(ArchiveBackupBadge.None, result.records.getValue("record").badge)
        assertEquals(0, result.overdueOriginalCount)
    }

    @Test fun switchingBucketOrPrefixNeverUsesThePreviousFoldersReceipt() {
        val snapshot = snapshot()
        val state = completeState(snapshot)
        for (location in listOf(config.copy(bucket = "another-1250000000"), config.copy(prefix = "life/v1/other/"), null)) {
            val result = deriveBackupPresentation(snapshot, location, state, overdueNow)
            assertFalse(result.records.getValue("record").backedUp)
            assertEquals(1, result.overdueOriginalCount)
        }
    }

    @Test fun editingARecordInvalidatesCoverageEvenWhenItsOriginalBytesAreVerified() {
        val snapshot = snapshot()
        val state = completeState(snapshot)
        val edited = snapshot.copy(records = snapshot.records.map { it.copy(title = field(JsonPrimitive("Updated"))) })
        val result = derive(edited, state)
        assertEquals(ArchiveBackupBadge.Overdue, result.records.getValue("record").badge)
        assertEquals(1, result.overdueOriginalCount)
    }

    @Test fun activeUploadsAndChecksUseTheSpinnerIncludingPreviewObjects() {
        val snapshot = snapshot()
        val previewKey = key(snapshot.resources.first { it.role == "preview" })
        for (status in listOf(BackupObjectStatus.uploading, BackupObjectStatus.verifying)) {
            val state = state().copy(objects = mapOf(previewKey to BackupObjectState(status, firstQueuedAt = created)))
            assertEquals(ArchiveBackupBadge.Uploading, derive(snapshot, state, running = true).records.getValue("record").badge)
            val stopped = derive(snapshot, state)
            assertEquals(ArchiveBackupBadge.Overdue, stopped.records.getValue("record").badge)
            assertEquals(BackupObjectStatus.pending, stopped.queue.first { it.objectKey == previewKey }.status)
        }
    }

    @Test fun objectFailureUsesChineseRetryCopyWhileKeepingRawState() {
        val snapshot = snapshot()
        val failedKey = key(snapshot.resources.first { it.role == "preview" })
        val state = state().copy(objects = mapOf(failedKey to BackupObjectState(
            BackupObjectStatus.failed, "云端原件缺失或校验失败。", 3, created,
        )))
        val result = derive(snapshot, state)
        assertEquals(ArchiveBackupBadge.Failed, result.records.getValue("record").badge)
        assertEquals(BackupPolicy.RETRY_MESSAGE, result.records.getValue("record").failureReason)
        assertEquals(1, result.overdueOriginalCount)
        assertEquals(3, result.queue.first { it.objectKey == failedKey }.attempts)
        assertEquals("云端原件缺失或校验失败。", state.objects.getValue(failedKey).lastError)
        assertEquals(BackupPolicy.RETRY_MESSAGE, result.queue.first { it.objectKey == failedKey }.lastError)
    }

    @Test fun aPublishedReceiptCannotHideAnActiveOrFailedPreview() {
        val snapshot = snapshot()
        val complete = completeState(snapshot)
        val previewKey = key(snapshot.resources.first { it.role == "preview" })
        for ((status, badge) in listOf(
            BackupObjectStatus.uploading to ArchiveBackupBadge.Uploading,
            BackupObjectStatus.verifying to ArchiveBackupBadge.Uploading,
            BackupObjectStatus.failed to ArchiveBackupBadge.Failed,
        )) {
            val state = complete.copy(objects = complete.objects + (previewKey to BackupObjectState(
                status, lastError = if (status == BackupObjectStatus.failed) "The preview is missing." else null, firstQueuedAt = created,
            )))
            val result = derive(snapshot, state, running = true)
            assertFalse(result.records.getValue("record").backedUp)
            assertEquals(badge, result.records.getValue("record").badge)
            assertEquals(0, result.overdueOriginalCount)
        }
    }

    @Test fun failedPublicationDoesNotClaimVerifiedOriginalsAreBackedUp() {
        val snapshot = snapshot()
        val state = completeState(snapshot).copy(receipt = null, pending = pending(snapshot), stage = "failed", lastError = "The network timed out.")
        val result = derive(snapshot, state)
        assertEquals(ArchiveBackupBadge.Failed, result.records.getValue("record").badge)
        assertEquals(BackupPolicy.RETRY_MESSAGE, result.records.getValue("record").failureReason)
        assertEquals(1, result.overdueOriginalCount)
    }

    @Test fun publicationFailureDoesNotMarkAnAlreadyCoveredRecordAsFailed() {
        val original = snapshot()
        val extra = record("new-record")
        val snapshot = original.copy(records = original.records + extra)
        val state = completeState(original).copy(pending = pending(snapshot), stage = "failed", lastError = "The network timed out.")
        val result = derive(snapshot, state)
        assertEquals(ArchiveBackupBadge.None, result.records.getValue("record").badge)
        assertTrue(result.records.getValue("record").backedUp)
        assertEquals(ArchiveBackupBadge.Failed, result.records.getValue("new-record").badge)
        assertEquals(1, result.overdueOriginalCount)
    }

    @Test fun expectedPauseNetworkAndConnectionStopsAreWaitingInsteadOfFailures() {
        val snapshot = snapshot()
        val originalKey = key(snapshot.resources.first { it.role == "photo" })
        for (reason in listOf(BackupFailure.Paused, BackupFailure.Wifi, BackupFailure.ReadOnly, BackupFailure.Connection, BackupFailure.Credentials)) {
            val state = state().copy(pending = pending(snapshot), stage = "failed", lastError = reason.text,
                objects = mapOf(originalKey to BackupObjectState(BackupObjectStatus.failed, reason.text, firstQueuedAt = created)))
            val result = derive(snapshot, state, now = created)
            assertEquals(ArchiveBackupBadge.None, result.records.getValue("record").badge)
            assertNull(result.records.getValue("record").failureReason)
            assertEquals(BackupObjectStatus.pending, result.queue.first { it.objectKey == originalKey }.status)
        }
    }

    @Test fun summaryDeduplicatesOriginalObjectsAndExcludesPreviewsAndYoungRecords() {
        val base = snapshot(listOf("asset", "duplicate", "young"))
        val original = base.resources.first { it.assetID == "asset" && it.role == "photo" }
        val snapshot = base.copy(
            records = listOf(record(), record("second", "duplicate"), record("young-record", "young", overdueNow)),
            resources = base.resources.map { if (it.assetID == "duplicate" && it.role == "photo") it.copy(sha256 = original.sha256) else it },
        )
        val result = derive(snapshot)
        assertEquals(1, result.overdueOriginalCount)
        assertEquals(5, result.queue.size)
        assertEquals(ArchiveBackupBadge.None, result.records.getValue("young-record").badge)
    }

    @Test fun livePhotoHasTwoOriginalsButItsPreviewNeverAddsToTheCount() {
        val base = snapshot()
        val image = base.resources.first { it.role == "photo" }.copy(role = "livePhotoImage")
        val video = resource("video", "asset", "livePhotoVideo").copy(contentType = "video/quicktime")
        val resources = listOf(image, video, base.resources.first { it.role == "preview" })
        val snapshot = base.copy(resources = resources, assets = base.assets.map { it.copy(kind = "livePhoto", resourceIds = resources.map { r -> r.id }) })
        assertEquals(2, derive(snapshot).overdueOriginalCount)
    }

    @Test fun queueRetainsFrozenObjectsAndUsesFilenameFallbackForUnknownHistory() {
        val snapshot = snapshot()
        val unknown = "${config.prefix}objects/ff/unknown-history"
        val state = state().copy(pending = pending(snapshot), objects = mapOf(unknown to BackupObjectState(
            BackupObjectStatus.failed, "Retry this file.", 2, created,
        )))
        val result = derive(ArchiveSnapshot.empty(), state)
        assertEquals(3, result.queue.size)
        assertTrue(result.queue.any { it.filename == "asset-photo.jpg" && it.byteCount == 10L })
        val history = result.queue.first { it.objectKey == unknown }
        assertEquals("unknown-history", history.filename)
        assertNull(history.byteCount)
        assertEquals(2, history.attempts)
    }

    @Test fun invalidV1MetadataStillProducesAVisibleFailureAndOriginalCount() {
        val base = snapshot()
        val snapshot = base.copy(records = base.records.map { it.copy(title = field(JsonPrimitive("x".repeat(201)))) })
        val result = derive(snapshot, state().copy(stage = "failed", lastError = "moments[record].title is too long."))
        assertEquals(ArchiveBackupBadge.Failed, result.records.getValue("record").badge)
        assertEquals(BackupPolicy.RETRY_MESSAGE, result.records.getValue("record").failureReason)
        assertEquals(1, result.overdueOriginalCount)
    }

    @Test fun summaryAndDetailUseTheRequestedCopy() {
        assertEquals("0 个原件尚未备份", originalsNotBackedUpText(0))
        assertEquals("1 个原件尚未备份", originalsNotBackedUpText(1))
        assertEquals("2 个原件尚未备份", originalsNotBackedUpText(2))
        assertEquals("已备份", recordBackupDetailText(RecordBackupPresentation(backedUp = true), waitingForWifi = true))
        assertEquals(BackupPolicy.WIFI_WAITING, recordBackupDetailText(RecordBackupPresentation(), waitingForWifi = true))
        assertEquals("正在上传…", recordBackupDetailText(RecordBackupPresentation(ArchiveBackupBadge.Uploading)))
        assertEquals(BackupPolicy.RETRY_MESSAGE, recordBackupDetailText(RecordBackupPresentation(ArchiveBackupBadge.Failed, failureReason = "Retry this file.")))
        assertEquals("尚未备份", recordBackupDetailText(RecordBackupPresentation(ArchiveBackupBadge.Overdue)))
        assertEquals("尚未备份", recordBackupDetailText(RecordBackupPresentation()))
    }

    @Test fun settingsReadsOnlyTheAuthoritativeQuerySummary() {
        val snapshot = snapshot()
        val complete = completeState(snapshot)
        fun summary(state: BackupState = complete, gate: BackupBlockReason? = null, running: Boolean = false, paused: Boolean = false) =
            DefaultBackupStatusQuery().query(snapshot, state, overdueNow,
                BackupCoordinatorState(state = state, configuration = config, blockReason = gate, running = running, paused = paused))
        assertEquals("已备份", settingsBackupStatusText(summary()))
        assertFalse(settingsBackupNeedsAttention(summary()))
        assertEquals("正在备份…", settingsBackupStatusText(summary(running = true)))
        assertEquals("已暂停", settingsBackupStatusText(summary(paused = true)))
        for (gate in listOf(BackupBlockReason.Offline, BackupBlockReason.Metered)) {
            assertEquals(if (gate == BackupBlockReason.Metered) BackupPolicy.WIFI_WAITING else "等待网络", settingsBackupStatusText(summary(gate = gate)))
        }
        val failed = state().copy(stage = "failed", lastError = "Retry this file.")
        assertEquals(BackupPolicy.RETRY_MESSAGE, settingsBackupStatusText(summary(state = failed)))
        assertTrue(settingsBackupNeedsAttention(summary(state = failed)))
        assertEquals("仅可查看", settingsBackupStatusText(summary(gate = BackupBlockReason.ReadOnly)))
        assertTrue(settingsBackupNeedsAttention(summary(gate = BackupBlockReason.ReadOnly)))
        // A stale engine stage can never substitute for current snapshot coverage.
        assertEquals("尚未备份", settingsBackupStatusText(summary(state = complete.copy(receipt = null))))
    }

    private fun derive(snapshot: ArchiveSnapshot, state: BackupState? = null, now: Long = overdueNow, running: Boolean = false) =
        deriveBackupPresentation(snapshot, config, state, now, running)

    private fun state() = BackupState(bucket = config.bucket, prefix = config.prefix)
    private fun completeState(snapshot: ArchiveSnapshot): BackupState {
        val manifest = V1Mapper.map(snapshot, config.prefix)
        val keys = manifest.resources.map { it.objectKey }.toSet()
        return state().copy(
            objects = keys.associateWith { BackupObjectState(BackupObjectStatus.verified, firstQueuedAt = created) },
            receipt = BackupReceipt(1, "commit-hash", V1Json.sha256(V1Json.encodeManifest(manifest)), created,
                keys, BackupEngine.momentHashes(manifest),
                manifest.moments.maxOfOrNull { it.updatedAt }),
            lastSuccessfulBackupAt = created, stage = "complete",
        )
    }

    private fun pending(snapshot: ArchiveSnapshot) = BackupPending(
        manifestBytes = Base64.getEncoder().encodeToString(V1Json.encodeManifest(V1Mapper.map(snapshot, config.prefix))),
        commitBytes = "unused-by-presentation", sourcePaths = emptyMap(),
    )

    private fun snapshot(assetIds: List<String> = listOf("asset")): ArchiveSnapshot {
        val resources = assetIds.flatMap { listOf(resource("$it-photo", it, "photo"), resource("$it-preview", it, "preview")) }
        return ArchiveSnapshot.empty().copy(records = listOf(record()), resources = resources,
            assets = assetIds.map { id -> MediaAsset(id, "photo", field(JsonObject(mapOf("timeUnknown" to JsonPrimitive(true)))),
                resources.filter { it.assetID == id }.map { it.id }, emptyMap()) })
    }

    private fun record(id: String = "record", asset: String = "asset", createdAt: Long = created) = ArchiveRecord(
        id, field(JsonPrimitive("Title")), field(JsonPrimitive("Note")),
        field(JsonObject(mapOf("utc" to JsonPrimitive(0L), "zoneUnknown" to JsonPrimitive(true), "estimated" to JsonPrimitive(true)))),
        field(JsonPrimitive(createdAt)), field(JsonArray(listOf(JsonPrimitive(asset)))), field(JsonNull), emptyMap(),
    )
    private fun resource(id: String, asset: String, role: String) = MediaResource(
        id, asset, role, "image/jpeg", "$id.jpg", 10L, V1Json.sha256(id.toByteArray()), "local/$id", emptyMap(),
    )
    private fun key(resource: MediaResource) = "${config.prefix}objects/${resource.sha256.take(2)}/${resource.sha256}"
    private fun field(value: JsonElement) = FieldEnvelope(value, stamp)
}
