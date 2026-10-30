package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.archive.*
import com.henrypann.jinbao365.storage.StorageConfiguration
import com.henrypann.jinbao365.storage.StorageCredentials
import java.io.File
import java.io.OutputStream
import java.io.RandomAccessFile
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CancellationException
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class BackupEngineTest {
    @get:Rule val temporary = TemporaryFolder()
    private val config = StorageConfiguration(bucket = "example-1234567890", prefix = "life/v1/android/")
    private val credentials = StorageCredentials("testID", "testKey")
    private val device = "00000000-0000-4000-8000-000000000001"
    private val request = UUID.fromString("00000000-0000-4000-8000-000000000002")
    private val now = 1_700_000_000_000L
    private var uploadTime = now + 10
    private val states = MemoryBackupState().apply {
        value = BackupState(bucket = config.bucket, prefix = config.prefix, paused = false)
    }
    private val remote = MemoryCosStore(config)
    private val events = mutableListOf<BackupProgress>()
    private fun engine(store: CosObjectStore = remote, state: BackupStatePersistence = states, attempts: Int = 3,
                       cancellation: BackupCancellation = BackupCancellation(),
                       gate: () -> BackupConditions = { BackupConditions(store.configuration, true, false, false) }): BackupEngine {
        if (state.load() == null) state.save(BackupState(bucket = store.configuration.bucket,
            prefix = store.configuration.prefix, paused = false))
        return BackupEngine(state, gate, { _, _, _ -> store }, cancellation, { events += it }, { request }, {}, attempts,
            clock = { uploadTime }, allowCellular = false)
    }

    @Test fun missingCloudRecordRefusesAllWritesEvenWithValidReceipt() {
        val fixture = fixture()
        engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        val writes = remote.writes.toList()
        expect(BackupFailure.RecordLoss) {
            engine().runOnce(ArchiveSnapshot.empty(), fixture.root, config, credentials, device, now + 1)
        }
        assertEquals(writes, remote.writes)
        assertEquals(1L, states.value!!.receipt!!.sequence)
    }

    @Test fun replacingMissingRecordWithNewRecordDoesNotBypassLossGuard() {
        val fixture = fixture()
        engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        val writes = remote.writes.toList()
        expect(BackupFailure.RecordLoss) {
            engine().runOnce(fixture.snapshot.copy(records = fixture.snapshot.records.map { it.copy(id = "another") }),
                fixture.root, config, credentials, device, now + 1)
        }
        assertEquals(writes, remote.writes)
    }

    @Test fun explicitUserTombstoneCanBeBackedUp() {
        val fixture = fixture()
        engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        val deleted = fixture.snapshot.copy(records = fixture.snapshot.records.map { it.copy(
            tombstone = ArchiveEdits.tombstone(now + 1, EditStamp(2, now + 1, device), it.tombstone)) })
        assertEquals(2L, engine().runOnce(deleted, fixture.root, config, credentials, device, now + 1).sequence)
        assertEquals(now + 1, V1Validator.latest(remote, BackupCancellation())!!.manifest.moments.single().trashedAt)
        // A cloud tombstone is already explicit deletion evidence, so later compaction is safe.
        assertEquals(3L, engine().runOnce(ArchiveSnapshot.empty(), fixture.root, config, credentials, device, now + 2).sequence)
    }

    @Test fun birthdayDefaultAllowsCellularAndStillBlocksOffline() {
        val fixture = fixture()
        assertTrue(BackupPolicy.ALLOW_CELLULAR)
        BackupEngine(states, { BackupConditions(config, false, false, false) }, { _, _, _ -> remote })
            .runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        val writes = remote.writes.toList()
        expect(BackupFailure.Offline) {
            BackupEngine(states, { BackupConditions(config, false, false, false, networkConnected = false) }, { _, _, _ -> remote })
                .runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        }
        assertEquals(writes, remote.writes)
    }

    @Test fun validatorAndUnexpectedFailureTextIsOnlyExposedInLogs() {
        assertEquals(BackupPolicy.RETRY_MESSAGE, BackupEngine.safeError(V1ValidationException("English raw wire error")))
        assertEquals(BackupPolicy.RETRY_MESSAGE, BackupEngine.safeError(IllegalArgumentException("internal details")))
    }

    @Test fun firstPublishNoChangeAndSecondCommitUseRawParentHash() {
        val fixture = fixture()
        val first = engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        assertEquals(1L, first.sequence)
        assertEquals(now, first.packedThrough)
        val firstBytes = remote.data.getValue(commitKey(1))
        assertNull(V1Json.decodeCommit(firstBytes).parentHash)
        assertEquals(4, remote.data.size) // two files + snapshot + commit
        val writes = remote.writes.size
        assertEquals(first, engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now + 1))
        assertEquals(writes, remote.writes.size)
        val second = engine().runOnce(renamed(fixture.snapshot), fixture.root, config, credentials, device, now + 2)
        assertEquals(2L, second.sequence)
        assertEquals(V1Json.sha256(firstBytes), V1Json.decodeCommit(remote.data.getValue(commitKey(2))).parentHash)
        assertTrue(events.any { it.stage == "uploading" && it.objectKey != null && it.total == 2 })
        assertEquals(2, events.last().completed)
        assertEquals("complete", events.last().stage)
    }

    @Test fun sharedContentIsUploadedAndVerifiedOnlyOnce() {
        val fixture = fixture()
        val original = fixture.snapshot.resources.first()
        val duplicated = fixture.snapshot.resources.last().copy(byteCount = original.byteCount,
            sha256 = original.sha256, objectKey = original.objectKey)
        val snapshot = fixture.snapshot.copy(resources = listOf(original, duplicated))
        engine().runOnce(snapshot, fixture.root, config, credentials, device, now)
        assertEquals(1, states.value!!.objects.size)
        assertEquals(3, remote.data.size)
        assertEquals(1, events.last().completed)
        assertEquals(1, events.last().total)
    }

    @Test fun lastUploadOnlyAdvancesAfterVerifiedResourceTransfer() {
        val fixture = fixture()
        engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        assertEquals(uploadTime, states.value!!.lastUploadAtMillis)
        uploadTime += 100
        engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now + 1)
        assertEquals(now + 10, states.value!!.lastUploadAtMillis)
        engine().runOnce(renamed(fixture.snapshot), fixture.root, config, credentials, device, now + 2)
        assertEquals(now + 10, states.value!!.lastUploadAtMillis)
        assertEquals(now + 2, states.value!!.receipt!!.publishedAt)
    }

    @Test fun failedReadbackDoesNotRecordSuccessfulUploadTime() {
        val fixture = fixture()
        val corrupt = object : CosObjectStore by remote {
            override fun download(key: String, output: OutputStream): CosDownload {
                remote.download(key, output)
                return CosDownload(0, "0".repeat(64))
            }
        }
        expect(BackupFailure.ArchivedFile) {
            engine(store = corrupt).runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        }
        assertNull(states.value!!.lastUploadAtMillis)
        assertNull(states.value!!.receipt)
    }

    @Test fun emptyRemoteCannotSilentlyReplaceAnExistingReceipt() {
        val fixture = fixture()
        engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        remote.data.clear()
        val writes = remote.writes.size
        expect(BackupFailure.ReceiptMismatch) { engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now) }
        assertEquals(writes, remote.writes.size)
    }

    @Test fun invalidConfigurationHasFixedFailureAndProgressWithoutCloudAccess() {
        val fixture = fixture()
        expect(BackupFailure.Configuration) {
            engine().runOnce(fixture.snapshot, fixture.root, config.copy(region = "other-region"), credentials, device, now)
        }
        assertTrue(remote.writes.isEmpty())
        assertEquals("failed", events.last().stage)
        assertEquals(BackupFailure.Configuration.text, events.last().error)
    }

    @Test fun otherWriterAndLostReceiptBothRefuseAnyWrite() {
        val fixture = fixture()
        engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        val count = remote.writes.size
        expect(BackupFailure.OtherWriter) {
            engine().runOnce(fixture.snapshot, fixture.root, config, credentials,
                "00000000-0000-4000-8000-000000000099", now)
        }
        expect(BackupFailure.ReceiptMismatch) {
            engine(state = MemoryBackupState()).runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        }
        assertEquals(count, remote.writes.size)
    }

    @Test fun brokenChainFailsClosed() {
        val fixture = fixture()
        engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        val commit = V1Json.decodeCommit(remote.data.getValue(commitKey(1)))
        remote.data[commitKey(3)] = V1Json.encodeCommit(commit.copy(sequence = 3, parentHash = "0".repeat(64)))
        val count = remote.writes.size
        try { engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now); fail() }
        catch (failure: V1ValidationException) { assertTrue(failure.message!!.contains("sequence")) }
        assertEquals(count, remote.writes.size)
    }

    @Test fun lostPutResponseRetriesConflictAndExactReadback() {
        val fixture = fixture()
        remote.loseAfterPut = { true }
        val receipt = engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        assertEquals(1L, receipt.sequence)
        assertEquals(4, remote.conflicts)
        assertNull(states.value!!.pending)
    }

    @Test fun pendingSurvivesColdRestartAndAcknowledgesAlreadyPublishedCommit() {
        val fixture = fixture()
        val disk = BackupStateStore(temporary.newFolder("state"))
        engine(state = disk).runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        remote.loseAfterPut = { it == commitKey(2) }
        try { engine(state = disk, attempts = 1).runOnce(renamed(fixture.snapshot), fixture.root, config, credentials, device, now + 1); fail() }
        catch (_: CosException) { }
        val frozen = disk.load()!!.pending!!
        val restarted = BackupStateStore(temporary.root.resolve("state"))
        val result = engine(state = restarted).runOnce(fixture.snapshot, fixture.root, config, credentials, device, now + 999)
        assertEquals(2L, result.sequence)
        assertArrayEquals(Base64.getDecoder().decode(frozen.commitBytes), remote.data.getValue(commitKey(2)))
        assertEquals(now + 1, V1Json.decodeCommit(remote.data.getValue(commitKey(2))).createdAt)
        assertNull(restarted.load()!!.pending)
        assertFalse(remote.data.containsKey(commitKey(3)))
    }

    @Test fun frozenBytesAreDurableBeforeFirstMetadataWrite() {
        val fixture = fixture()
        remote.beforePut = { key, bytes ->
            if (key.contains("/snapshots/")) assertArrayEquals(bytes, Base64.getDecoder().decode(states.value!!.pending!!.manifestBytes))
            if (key.contains("/commits/")) assertArrayEquals(bytes, Base64.getDecoder().decode(states.value!!.pending!!.commitBytes))
        }
        engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
    }

    @Test fun conflictingMetadataBytesAreNeverAccepted() {
        val fixture = fixture()
        val manifest = V1Json.encodeManifest(V1Mapper.map(fixture.snapshot, config.prefix))
        val key = config.prefix + "snapshots/${V1Json.sha256(manifest)}.json"
        remote.data[key] = "different".toByteArray()
        expect(BackupFailure.ExistingMismatch) { engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now) }
        assertFalse(remote.data.containsKey(commitKey(1)))
        assertNotNull(states.value!!.pending)
        assertEquals("different", remote.data.getValue(key).toString(Charsets.UTF_8))
    }

    @Test fun corruptedDownloadRevokesVerificationAndDoesNotPublish() {
        val fixture = fixture()
        remote.corruptDownload = true
        expect(BackupFailure.ArchivedFile) { engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now) }
        assertTrue(states.value!!.objects.values.any { it.status == BackupObjectStatus.failed && it.lastError == BackupFailure.ArchivedFile.text })
        assertNull(states.value!!.receipt)
        assertTrue(remote.data.keys.none { it.contains("/snapshots/") || it.contains("/commits/") })
    }

    @Test fun missingOrChangedOriginalPreventsPublication() {
        val fixture = fixture()
        val resource = fixture.snapshot.resources.first()
        File(fixture.root, resource.objectKey).delete()
        expect(BackupFailure.MissingOriginal) { engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now) }
        File(fixture.root, resource.objectKey).writeBytes(ByteArray(resource.byteCount.toInt()) { 9 })
        expect(BackupFailure.ChangedOriginal) { engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now) }
        assertNull(states.value!!.receipt)
        assertTrue(remote.data.keys.none { it.contains("/commits/") })
    }

    @Test fun sameLengthChangedVerifiedOriginalFailsBeforeAnyNewWrite() {
        val fixture = fixture()
        val receipt = engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        val original = fixture.snapshot.resources.first()
        val file = File(fixture.root, original.objectKey)
        val originalModifiedAt = file.lastModified()
        val writesBefore = remote.writes.toList()
        file.writeBytes(ByteArray(original.byteCount.toInt()) { 9 })
        file.setLastModified(originalModifiedAt) // Even a matching timestamp cannot hide changed bytes.

        expect(BackupFailure.ChangedOriginal) {
            engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now + 1)
        }

        assertEquals(writesBefore, remote.writes)
        val key = config.prefix + original.objectKey
        assertEquals(BackupObjectStatus.failed, states.value!!.objects.getValue(key).status)
        assertEquals(receipt, states.value!!.receipt)
        assertFalse(remote.data.containsKey(commitKey(2)))
    }

    @Test fun firstConfigurationCannotUploadUntilPersistedPauseIsCleared() {
        val fixture = fixture()
        val untouched = MemoryBackupState()
        val runner = BackupEngine(untouched, { BackupConditions(config, true, false, false) },
            { _, _, _ -> remote })
        expect(BackupFailure.Paused) {
            runner.runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        }
        assertTrue(untouched.value!!.paused)
        assertTrue(remote.writes.isEmpty())
        untouched.value = untouched.value!!.copy(paused = false)
        assertEquals(1L, runner.runOnce(fixture.snapshot, fixture.root, config, credentials, device, now).sequence)
    }

    @Test fun zeroMediaNoteGetsCommitAndOnlyThenHasCoverage() {
        val fixture = fixture()
        val note = fixture.snapshot.records.single().copy(assetIds =
            fixture.snapshot.records.single().assetIds.copy(value = JsonArray(emptyList())))
        val snapshot = fixture.snapshot.copy(records = listOf(note), assets = emptyList(), resources = emptyList())
        val late = now + BackupEngine.DAY_MILLIS + 2
        assertEquals(setOf(note.id), engine().overdueRecordIds(snapshot, config, late))

        val receipt = engine().runOnce(snapshot, fixture.root, config, credentials, device, now + 100)
        assertEquals(now, receipt.packedThrough)
        assertTrue(receipt.coveredObjectKeys.isEmpty())
        assertNull(states.value!!.lastUploadAtMillis)
        assertEquals(2, remote.data.size) // A manifest and commit are required even without media.
        assertTrue(engine().overdueRecordIds(snapshot, config, late).isEmpty())
        assertEquals(setOf(note.id), engine().overdueRecordIds(renamed(snapshot), config, late))
    }

    @Test fun frozenCommitReceiptDoesNotClaimNewerLocalEdits() {
        val fixture = fixture()
        remote.loseAfterPut = { it.contains("/snapshots/") }
        try { engine(attempts = 1).runOnce(fixture.snapshot, fixture.root, config, credentials, device, now); fail() }
        catch (_: CosException) { }
        val receipt = engine().runOnce(renamed(fixture.snapshot), fixture.root, config, credentials, device, now + 999)
        assertEquals(now, receipt.packedThrough)
        assertEquals(1L, receipt.sequence)
        assertEquals(setOf("record-local"), engine().overdueRecordIds(renamed(fixture.snapshot), config,
            now + BackupEngine.DAY_MILLIS + 2))
    }

    @Test fun legacyReceiptWithoutPackedThroughRequiresNewVerifiedCommit() {
        val fixture = fixture()
        engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        states.value = states.value!!.copy(receipt = states.value!!.receipt!!.copy(packedThrough = null))
        assertEquals(setOf("record-local"), engine().overdueRecordIds(fixture.snapshot, config,
            now + BackupEngine.DAY_MILLIS + 1))
        val next = engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now + 1)
        assertEquals(2L, next.sequence)
        assertEquals(now, next.packedThrough)
    }

    @Test fun originalRemovedBetweenInspectionAndReadHasFixedErrorAndFailedState() {
        val fixture = fixture()
        val runner = BackupEngine(states, { BackupConditions(config, true, false, false) }, { _, _, _ -> remote },
            onProgress = { progress ->
                if (progress.stage == "pending") {
                    File(fixture.root, progress.objectKey!!.removePrefix(config.prefix)).delete()
                }
            })
        expect(BackupFailure.MissingOriginal) { runner.runOnce(fixture.snapshot, fixture.root, config, credentials, device, now) }
        assertTrue(states.value!!.objects.values.any { it.status == BackupObjectStatus.failed && it.lastError == BackupFailure.MissingOriginal.text })
        assertTrue(remote.writes.isEmpty())
    }

    @Test fun truncatedVerificationDownloadHasFixedIntegrityMessage() {
        val fixture = fixture()
        remote.downloadFailure = CosFailure.InvalidResponse
        expect(BackupFailure.ArchivedFile) { engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now) }
        assertTrue(states.value!!.objects.values.any { it.status == BackupObjectStatus.failed && it.lastError == BackupFailure.ArchivedFile.text })
        assertNull(states.value!!.receipt)
    }

    @Test fun stateWriteFailureBeforeMetadataCannotPublishAndIsReported() {
        val fixture = fixture()
        val disk = object : BackupStatePersistence {
            override fun load() = states.load()
            override fun save(state: BackupState) {
                if (state.pending != null) throw java.io.IOException("injected fsync failure")
                states.save(state)
            }
        }
        expect(BackupFailure.State) { engine(state = disk).runOnce(fixture.snapshot, fixture.root, config, credentials, device, now) }
        assertTrue(remote.data.keys.none { it.contains("/snapshots/") || it.contains("/commits/") })
        assertEquals("failed", events.last().stage)
        assertEquals(BackupFailure.State.text, events.last().error)
    }

    @Test fun previouslyExistingObjectsAreAcceptedOnlyWithMatchingHeadMetadata() {
        val fixture = fixture()
        fixture.snapshot.resources.forEach { remote.data[config.prefix + it.objectKey] = File(fixture.root, it.objectKey).readBytes(); remote.hashes[config.prefix + it.objectKey] = it.sha256 }
        assertEquals(1L, engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now).sequence)
        assertEquals(2, remote.conflicts)
        assertTrue(states.value!!.objects.values.all { it.status == BackupObjectStatus.verified })
    }

    @Test fun conflictingSizeHashOrAbsentMetadataFailsWithoutLooping() {
        for (mode in listOf("size", "hash", "absent")) {
            val fixture = fixture()
            val store = MemoryCosStore(config)
            fixture.snapshot.resources.forEach { resource ->
                val key = config.prefix + resource.objectKey
                store.data[key] = if (mode == "size") byteArrayOf(1) else File(fixture.root, resource.objectKey).readBytes()
                if (mode != "absent") store.hashes[key] = if (mode == "hash") "0".repeat(64) else resource.sha256
            }
            val state = MemoryBackupState()
            expect(BackupFailure.ExistingMismatch) {
                engine(store, state).runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
            }
            assertEquals(1, store.conflicts)
            assertEquals(1, store.headCalls)
            assertEquals(0, store.downloadCalls)
            assertNull(state.value!!.receipt)
            assertEquals(BackupFailure.ExistingMismatch.text, state.value!!.lastError)
        }
    }

    @Test fun multipartTransientFailureStartsAgainAtPartOneWithinTheSameRun() {
        val fixture = fixture(32 * 1024 * 1024 + 17)
        remote.losePart = 2
        engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        assertEquals(listOf(1, 2, 1, 2, 3, 4, 5), remote.uploadedPartNumbers)
        assertEquals(2, remote.initiations)
        assertEquals(0, remote.listPartsCalls)
        assertTrue(states.value!!.multipart.isEmpty())
    }

    @Test fun pendingManifestAndCommitRemainFrozenWhenLocalSnapshotChanges() {
        val fixture = fixture()
        remote.loseAfterPut = { it.contains("/snapshots/") }
        try { engine(attempts = 1).runOnce(fixture.snapshot, fixture.root, config, credentials, device, now); fail() }
        catch (_: CosException) { }
        val pending = states.value!!.pending!!
        engine().runOnce(renamed(fixture.snapshot), fixture.root, config, credentials, device, now + 1)
        assertArrayEquals(Base64.getDecoder().decode(pending.commitBytes), remote.data.getValue(commitKey(1)))
        assertEquals("", V1Validator.latest(remote, BackupCancellation())!!.manifest.moments.single().title)
        assertFalse(remote.data.containsKey(commitKey(2)))
        assertEquals(2L, engine().runOnce(renamed(fixture.snapshot), fixture.root, config, credentials, device, now + 2).sequence)
    }

    @Test fun multipartLostPartResponseRestartsWholeFileAcrossRestart() {
        val fixture = fixture(32 * 1024 * 1024 + 17)
        remote.losePart = 2
        try { engine(attempts = 1).runOnce(fixture.snapshot, fixture.root, config, credentials, device, now); fail() }
        catch (_: CosException) { }
        assertTrue(states.value!!.multipart.isEmpty())
        val result = engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now + 1)
        assertEquals(1L, result.sequence)
        assertEquals(listOf(1, 2, 1, 2, 3, 4, 5), remote.uploadedPartNumbers)
        assertEquals(0, remote.listPartsCalls)
        assertTrue(states.value!!.multipart.isEmpty())
        assertEquals(2, remote.initiations)
    }

    @Test fun multipartLostCompletionIsRecoveredByMatchingHeadMetadata() {
        val fixture = fixture(32 * 1024 * 1024 + 17)
        remote.loseComplete = true
        try { engine(attempts = 1).runOnce(fixture.snapshot, fixture.root, config, credentials, device, now); fail() }
        catch (_: CosException) { }
        assertTrue(states.value!!.multipart.isEmpty())
        engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now + 1)
        assertEquals(1, remote.initiations)
        assertTrue(states.value!!.multipart.isEmpty())
    }

    @Test fun configChangeResetsObjectsReceiptPendingAndMultipart() {
        val fixture = fixture()
        engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        // Stale sessions/frozen bytes from the old folder must never be inspected or resumed.
        states.value = states.value!!.copy(pending = BackupPending("invalid-old-bytes", "invalid-old-bytes", emptyMap()),
            multipart = mapOf("old-object" to BackupMultipart("old-upload")))
        val changed = config.copy(prefix = "life/v1/another/")
        val otherStore = MemoryCosStore(changed)
        expect(BackupFailure.Paused) {
            engine(otherStore).runOnce(fixture.snapshot, fixture.root, changed, credentials, device, now + 1)
        }
        assertTrue(otherStore.writes.isEmpty())
        assertNull(states.value!!.lastUploadAtMillis)
        assertNull(states.value!!.receipt)
        assertNull(states.value!!.pending)
        assertTrue(states.value!!.objects.isEmpty())
        assertTrue(states.value!!.multipart.isEmpty())
        states.value = states.value!!.copy(paused = false)
        val result = engine(otherStore).runOnce(fixture.snapshot, fixture.root, changed, credentials, device, now + 1)
        assertEquals(1L, result.sequence)
        assertEquals(changed.prefix, states.value!!.prefix)
        assertTrue(states.value!!.objects.keys.all { it.startsWith(changed.prefix) })
        assertEquals(4, remote.data.size)
        assertEquals(4, otherStore.data.size)
    }

    @Test fun preconditionsAndCancellationPreventWrites() {
        val fixture = fixture()
        val gates = listOf(
            BackupConditions(null, true, false, false) to BackupFailure.Connection,
            BackupConditions(config, false, false, false) to BackupFailure.Wifi,
            BackupConditions(config, true, true, false) to BackupFailure.Paused,
            BackupConditions(config, true, false, true) to BackupFailure.ReadOnly,
        )
        gates.forEach { (gate, failure) -> expect(failure) {
            engine(gate = { gate }).runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        } }
        expect(BackupFailure.Credentials) { engine().runOnce(fixture.snapshot, fixture.root, config, null, device, now) }
        val token = BackupCancellation().also { it.cancel() }
        try { engine(cancellation = token).runOnce(fixture.snapshot, fixture.root, config, credentials, device, now); fail() }
        catch (_: CancellationException) { }
        assertTrue(remote.writes.isEmpty())
    }

    @Test fun cancellationDuringTransferKeepsResumableState() {
        val fixture = fixture()
        val token = BackupCancellation()
        remote.beforePut = { _, _ -> token.cancel(); token.check() }
        try { engine(cancellation = token).runOnce(fixture.snapshot, fixture.root, config, credentials, device, now); fail() }
        catch (_: CancellationException) { }
        assertEquals("cancelled", states.value!!.stage)
        remote.beforePut = { _, _ -> }
        assertEquals(1L, engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now + 1).sequence)
    }

    @Test fun backgroundStopsBeforeVerificationAndStartsNoNextObject() {
        val fixture = fixture()
        var foreground = true
        remote.beforePut = { _, _ -> foreground = false }
        val runner = BackupEngine(states, { BackupConditions(config, true, false, false) }, { _, _, _ -> remote },
            stopAfterObject = { !foreground })
        try { runner.runOnce(fixture.snapshot, fixture.root, config, credentials, device, now); fail() }
        catch (_: CancellationException) { }
        assertEquals(1, remote.writes.size)
        assertEquals(0, states.value!!.objects.values.count { it.status == BackupObjectStatus.verified })
        assertEquals(2, states.value!!.objects.values.count { it.status == BackupObjectStatus.pending })
        assertNull(states.value!!.lastError)
        assertNull(states.value!!.receipt)
        assertEquals("cancelled", states.value!!.stage)
    }

    @Test fun pauseDuringTransferKeepsQueuePendingWithoutFailedObject() {
        val fixture = fixture()
        var paused = false
        remote.beforePut = { _, _ -> paused = true }
        expect(BackupFailure.Paused) {
            engine(gate = { BackupConditions(config, true, paused, false) })
                .runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        }
        assertTrue(states.value!!.objects.values.none { it.status == BackupObjectStatus.failed })
        assertNull(states.value!!.lastError)
        assertEquals("waiting", states.value!!.stage)
        assertNull(states.value!!.receipt)
    }

    @Test fun configurationResetPreservesPersistentPausePreference() {
        val fixture = fixture()
        states.value = BackupState(bucket = config.bucket, prefix = "another/folder/", paused = true)
        expect(BackupFailure.Paused) {
            engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        }
        assertTrue(states.value!!.paused)
        assertEquals(config.prefix, states.value!!.prefix)
        assertTrue(remote.writes.isEmpty())
    }

    @Test fun overdueRequiresVerifiedOriginalsAndPublishedCurrentRecord() {
        val fixture = fixture()
        val late = now + BackupEngine.DAY_MILLIS + 2
        assertTrue(engine().overdueRecordIds(fixture.snapshot, config, now + BackupEngine.DAY_MILLIS).isEmpty())
        assertEquals(setOf("record-local"), engine().overdueRecordIds(fixture.snapshot, config, late))
        engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        assertTrue(engine().overdueRecordIds(fixture.snapshot, config, late).isEmpty())
        assertEquals(setOf("record-local"), engine().overdueRecordIds(renamed(fixture.snapshot), config, late))
        val key = config.prefix + fixture.snapshot.resources.first().objectKey
        states.value = states.value!!.copy(objects = states.value!!.objects + (key to states.value!!.objects.getValue(key).copy(status = BackupObjectStatus.failed)))
        assertEquals(setOf("record-local"), engine().overdueRecordIds(fixture.snapshot, config, late))
    }

    @Test fun interruptedVersionOnePublicationKeepsExactIosCodableKeysTypesAndUppercaseUuids() {
        val fixture = fixture()
        // An upgrade must finish the exact frozen version-1 publication before emitting version 2.
        // Build the pending document from the local fixture, independently of the golden bytes.
        val legacyManifest = V1Json.encodeManifest(V1Mapper.map(fixture.snapshot, config.prefix).copy(version = 1))
        val legacyHash = V1Json.sha256(legacyManifest)
        val legacyCommit = V1Json.encodeCommit(V1Commit(sequence = 1, writerDeviceID = device.uppercase(), kind = "snapshot",
            manifestHash = legacyHash, manifestKey = config.prefix + "snapshots/$legacyHash.json", createdAt = now,
            requestID = request.toString().uppercase()))
        states.value = states.value!!.copy(pending = BackupPending(Base64.getEncoder().encodeToString(legacyManifest),
            Base64.getEncoder().encodeToString(legacyCommit),
            fixture.snapshot.resources.associate { config.prefix + it.objectKey to it.objectKey }))
        engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        val commit = remote.data.getValue(commitKey(1))
        val snapshotKey = V1Json.decodeCommit(commit).manifestKey
        val manifest = remote.data.getValue(snapshotKey)
        assertArrayEquals(golden("commits/00000000000000000001.json"), commit)
        assertArrayEquals(golden(snapshotKey.removePrefix(config.prefix)), manifest)
        val c = Json.parseToJsonElement(commit.toString(Charsets.UTF_8)).jsonObject
        assertEquals(setOf("createdAt", "kind", "manifestHash", "manifestKey", "requestID", "sequence", "version", "writerDeviceID"), c.keys)
        assertFalse(c.getValue("sequence").jsonPrimitive.isString)
        assertEquals(1L, c.getValue("sequence").jsonPrimitive.long)
        assertEquals("snapshot", c.getValue("kind").jsonPrimitive.content)
        listOf("writerDeviceID", "requestID").forEach { assertUuid(c.getValue(it).jsonPrimitive.content) }
        val m = Json.parseToJsonElement(manifest.toString(Charsets.UTF_8)).jsonObject
        assertEquals(setOf("assets", "moments", "resources", "version"), m.keys)
        listOf("assets", "moments", "resources").forEach { key -> m.getValue(key).jsonArray.forEach { assertUuid(it.jsonObject.getValue("id").jsonPrimitive.content) } }
        val moment = m.getValue("moments").jsonArray.single().jsonObject
        assertEquals(setOf("id", "title", "note", "occurredAt", "createdAt", "updatedAt", "assetIDs", "revision"), moment.keys)
        assertFalse(moment.getValue("occurredAt").jsonPrimitive.isString)
        moment.getValue("assetIDs").jsonArray.forEach { assertUuid(it.jsonPrimitive.content) }
        val asset = m.getValue("assets").jsonArray.single().jsonObject
        assertEquals(setOf("id", "kind", "capturedAt", "resourceIDs", "revision"), asset.keys)
        assertFalse(asset.getValue("capturedAt").jsonPrimitive.isString)
        asset.getValue("resourceIDs").jsonArray.forEach { assertUuid(it.jsonPrimitive.content) }
        m.getValue("resources").jsonArray.forEach { raw ->
            val resource = raw.jsonObject
            assertEquals(setOf("id", "assetID", "role", "contentType", "originalFilename", "byteCount", "sha256", "objectKey"), resource.keys)
            assertUuid(resource.getValue("assetID").jsonPrimitive.content)
            assertFalse(resource.getValue("byteCount").jsonPrimitive.isString)
            assertTrue(resource.getValue("objectKey").jsonPrimitive.content.startsWith(config.prefix + "objects/"))
        }
        V1Validator.latest(remote, BackupCancellation())!! // Also independently walks raw engine output.
    }

    @Test fun newPublicationMatchesVersionTwoGoldenAndKeepsCommitVersionOne() {
        val fixture = fixture()
        engine().runOnce(fixture.snapshot, fixture.root, config, credentials, device, now)
        val commitBytes = remote.data.getValue(commitKey(1))
        val commit = V1Json.decodeCommit(commitBytes)
        val manifestBytes = remote.data.getValue(commit.manifestKey)
        fun versionTwoGolden(name: String) = checkNotNull(javaClass.getResourceAsStream("/backup-v2/$name")).use { it.readBytes() }
        assertArrayEquals(versionTwoGolden("commits/00000000000000000001.json"), commitBytes)
        assertArrayEquals(versionTwoGolden(commit.manifestKey.removePrefix(config.prefix)), manifestBytes)
        assertEquals(1, commit.version)
        assertEquals(2, V1Json.decodeManifest(manifestBytes).version)
        assertEquals(setOf("anniversaries", "assets", "moments", "resources", "version"),
            Json.parseToJsonElement(manifestBytes.toString(Charsets.UTF_8)).jsonObject.keys)
        V1Validator.latest(remote, BackupCancellation())!!
    }

    private fun golden(name: String) = checkNotNull(javaClass.getResourceAsStream("/backup-v1/$name")).use { it.readBytes() }
    private fun assertUuid(id: String) { assertEquals(UUID.fromString(id).toString().uppercase(), id) }
    private fun commitKey(sequence: Long) = config.prefix + V1Json.commitRelativeKey(sequence)
    private fun expect(expected: BackupFailure, run: () -> Unit) {
        try { run(); fail("Expected $expected") } catch (failure: BackupException) { assertEquals(expected, failure.failure) }
    }
    private fun renamed(snapshot: ArchiveSnapshot) = snapshot.copy(records = snapshot.records.map {
        it.copy(title = FieldEnvelope(JsonPrimitive("changed"), EditStamp(2, now + 1, device)))
    })
    private data class Fixture(val snapshot: ArchiveSnapshot, val root: File)
    private fun fixture(originalSize: Int = 8): Fixture {
        val root = temporary.newFolder()
        val original = if (originalSize == 8) "original".toByteArray() else ByteArray(originalSize) { (it % 251).toByte() }
        val preview = "preview".toByteArray()
        val edit = EditStamp(1, now, device)
        fun field(value: JsonElement) = FieldEnvelope(value, edit)
        fun resource(id: String, role: String, bytes: ByteArray): MediaResource {
            val hash = V1Json.sha256(bytes)
            val key = "objects/${hash.take(2)}/$hash"
            File(root, key).apply { parentFile!!.mkdirs(); writeBytes(bytes) }
            return MediaResource(id, "asset-local", role, "image/jpeg", "$role.jpg", bytes.size.toLong(), hash, key, emptyMap())
        }
        val resources = listOf(resource("resource-original", "photo", original), resource("resource-preview", "preview", preview))
        val record = ArchiveRecord("record-local", null, field(JsonPrimitive("秋日 / café")),
            field(buildJsonObject { put("utc", now); put("timeZone", "Asia/Shanghai") }), field(JsonPrimitive(now)),
            field(JsonArray(listOf(JsonPrimitive("asset-local")))), field(JsonNull), emptyMap())
        val asset = MediaAsset("asset-local", "photo", field(buildJsonObject { put("timeUnknown", true) }), resources.map { it.id }, emptyMap())
        return Fixture(ArchiveSnapshot(records = listOf(record), assets = listOf(asset), resources = resources, extensions = emptyMap()), root)
    }
}

internal class MemoryBackupState : BackupStatePersistence {
    var value: BackupState? = null
    override fun load() = value
    override fun save(state: BackupState) { value = state }
    override fun restore(previous: BackupState?) { value = previous }
}

/** Fault injection is after persistence, so network failures model genuinely ambiguous writes. */
internal class MemoryCosStore(override val configuration: StorageConfiguration) : CosObjectStore {
    val data = linkedMapOf<String, ByteArray>()
    val hashes = mutableMapOf<String, String>()
    var headCalls = 0
    var downloadCalls = 0
    val writes = mutableListOf<String>()
    var conflicts = 0
    var loseAfterPut: (String) -> Boolean = { false }
    var beforePut: (String, ByteArray) -> Unit = { _, _ -> }
    var corruptDownload = false
    var downloadFailure: CosFailure? = null
    var losePart: Int? = null
    var loseComplete = false
    var listPartsCalls = 0
    var initiations = 0
    val uploadedPartNumbers = mutableListOf<Int>()
    private val sessions = mutableMapOf<String, MutableMap<Int, ByteArray>>()
    override fun list(prefix: String) = data.keys.filter { it.startsWith(prefix) }.sorted()
    override fun head(key: String): CosObjectInfo? { headCalls++; return data[key]?.let { CosObjectInfo(it.size.toLong(), hashes[key]) } }
    override fun get(key: String) = data[key]?.copyOf() ?: throw CosException(CosFailure.NotFound)
    override fun download(key: String, output: OutputStream): CosDownload {
        downloadCalls++
        downloadFailure?.let { throw CosException(it) }
        val bytes = if (corruptDownload) "corrupt".toByteArray() else get(key)
        output.write(bytes)
        return CosDownload(bytes.size.toLong(), V1Json.sha256(bytes))
    }
    override fun put(key: String, bytes: ByteArray, contentType: String) {
        beforePut(key, bytes)
        writes += key
        if (data.containsKey(key)) { conflicts++; throw CosException(CosFailure.Conflict) }
        data[key] = bytes.copyOf()
        hashes[key] = V1Json.sha256(bytes)
        if (loseAfterPut(key)) throw CosException(CosFailure.Network)
    }
    override fun putFile(key: String, file: File, contentType: String) = put(key, file.readBytes(), contentType)
    override fun initiateMultipart(key: String, contentType: String, sha256: String): String {
        if (data.containsKey(key)) throw CosException(CosFailure.Conflict)
        val id = "session-${++initiations}"
        sessions[id] = mutableMapOf()
        return id
    }
    override fun uploadPart(key: String, uploadId: String, partNumber: Int, file: File, offset: Long, length: Long): String {
        val bytes = ByteArray(length.toInt())
        RandomAccessFile(file, "r").use { it.seek(offset); it.readFully(bytes) }
        (sessions[uploadId] ?: throw CosException(CosFailure.NoSuchUpload))[partNumber] = bytes
        uploadedPartNumbers += partNumber
        if (losePart == partNumber) { losePart = null; throw CosException(CosFailure.Network) }
        return V1Json.sha256(bytes)
    }
    override fun listParts(key: String, uploadId: String): List<CosPart> {
        listPartsCalls++
        return (sessions[uploadId] ?: throw CosException(CosFailure.NoSuchUpload)).map { (n, bytes) -> CosPart(n, V1Json.sha256(bytes), bytes.size.toLong()) }
    }
    override fun completeMultipart(key: String, uploadId: String, parts: List<CosPart>) {
        val session = sessions[uploadId] ?: throw CosException(CosFailure.NoSuchUpload)
        val bytes = java.io.ByteArrayOutputStream()
        parts.forEach { part ->
            val b = session.getValue(part.partNumber)
            check(part.etag == V1Json.sha256(b)); bytes.write(b)
        }
        put(key, bytes.toByteArray(), "application/octet-stream")
        sessions.remove(uploadId)
        if (loseComplete) { loseComplete = false; throw CosException(CosFailure.Network) }
    }
}
