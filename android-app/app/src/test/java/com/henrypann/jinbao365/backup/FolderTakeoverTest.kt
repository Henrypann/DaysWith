package com.henrypann.jinbao365.backup

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.henrypann.jinbao365.archive.*
import com.henrypann.jinbao365.data.*
import com.henrypann.jinbao365.editing.newDraftRecord
import com.henrypann.jinbao365.media.CaptureTime
import com.henrypann.jinbao365.media.ImportRequest
import com.henrypann.jinbao365.media.MediaImportService
import com.henrypann.jinbao365.media.MediaImporter
import com.henrypann.jinbao365.media.PreviewEncoder
import com.henrypann.jinbao365.storage.StorageConfiguration
import com.henrypann.jinbao365.storage.StorageCredentials
import java.io.File
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.serialization.json.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class FolderTakeoverTest {
    @get:Rule val temporary = TemporaryFolder()
    private val root = StorageConfiguration(bucket = "example-1234567890")
    private val destination = V1Destination.forParent(root, ParentIdentity.Dad)
    private val credentials = StorageCredentials("fake", "fake")
    private val oldDevice = "00000000-0000-4000-8000-000000000001"
    private val newDevice = "00000000-0000-4000-8000-000000000099"
    private val now = 1_700_000_000_000L
    private val remote = MemoryCosStore(destination)
    private val states = MemoryBackupState()
    private lateinit var database: ArchiveDatabase
    private lateinit var repository: ArchiveRepository
    private lateinit var media: File

    @Before fun prepareCloudAndReinstalledPhone() {
        database = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), ArchiveDatabase::class.java)
            .allowMainThreadQueries().build()
        repository = ArchiveRepository(database)
        repository.reconcileOwner(newDevice)
        media = temporary.newFolder("reinstalled-media")
        val originalMedia = temporary.newFolder("old-phone-media")
        val resources = (1..2).flatMap { number -> listOf("photo", "preview").map { role ->
            val bytes = "照片$number-$role".toByteArray()
            val hash = V1Json.sha256(bytes)
            val key = "objects/${hash.take(2)}/$hash"
            File(originalMedia, key).apply { parentFile!!.mkdirs(); writeBytes(bytes) }
            MediaResource("resource-$number-$role", "asset-$number", role, "image/jpeg", "照片$number.jpg",
                bytes.size.toLong(), hash, key, emptyMap())
        } }
        val records = (1..2).map { number -> note("record-$number", "记录$number").let { record ->
            record.copy(assetIds = record.assetIds.copy(value = JsonArray(listOf(JsonPrimitive("asset-$number")))))
        } }
        val assets = resources.groupBy { it.assetID }.map { (assetId, files) -> MediaAsset(assetId, "photo",
            FieldEnvelope(buildJsonObject { put("timeUnknown", true) }, EditStamp(0, now, oldDevice)),
            files.map { it.id }, emptyMap()) }
        val initial = ArchiveSnapshot(records = records, assets = assets, resources = resources, extensions = emptyMap())
        val oldStates = MemoryBackupState().apply { value = BackupState(bucket = destination.bucket,
            prefix = destination.prefix, paused = false) }
        BackupEngine(oldStates, { BackupConditions(destination, true, false, false) }, { _, _, _ -> remote })
            .runOnce(initial, originalMedia, destination, credentials, oldDevice, now)
        remote.writes.clear()
    }

    @After fun close() { database.close() }

    private fun restorationCommitted(receipt: BackupReceipt): Boolean = repository.localSyncState()?.let {
        it.ownerDeviceId == newDevice && !it.resyncFromStart && it.verifiedThroughSequence == receipt.sequence &&
            it.verifiedThroughHash == receipt.commitHash
    } == true

    private fun note(id: String, text: String) = newDraftRecord(id, newDevice, now, java.time.ZoneId.of("Asia/Shanghai")).let {
        it.copy(note = it.note.copy(value = JsonPrimitive(text)))
    }

    private fun takeover(store: CosObjectStore = remote, persistence: BackupStatePersistence = states) =
        FolderTakeover(repository, persistence, media, { config, _, _ ->
            assertEquals(destination, config)
            store
        }).restore(root, ParentIdentity.Dad, credentials, newDevice, now + 1)

    @Test fun reinstallTakeoverRestoresBothRecordsAndOriginalsThenNewRecordBacksUp() {
        assertTrue(repository.loadSnapshot().records.isEmpty())
        val receipt = takeover()
        val restored = repository.loadSnapshot()
        assertEquals(2, restored.records.size)
        assertEquals(setOf("记录1", "记录2"), restored.records.map { it.note.value.jsonPrimitive.content }.toSet())
        assertEquals(4, restored.resources.size)
        restored.resources.forEach { resource ->
            assertEquals("objects/${resource.sha256.take(2)}/${resource.sha256}", resource.objectKey)
            val file = File(media, resource.objectKey)
            assertEquals(resource.byteCount, file.length())
            assertEquals(resource.sha256, V1Json.sha256(file.readBytes()))
        }
        assertEquals(receipt, states.value!!.receipt)
        assertEquals(1L, receipt.sequence)
        assertEquals(newDevice.uppercase(), states.value!!.takeover!!.writerDeviceId)
        assertTrue(remote.writes.isEmpty())
        assertFalse(states.value!!.paused)
        repository.reconcileOwner(newDevice)
        assertFalse(repository.localSyncState()!!.resyncFromStart)
        repository.saveManualRecord(note("new-record", "今天会笑啦"))
        val next = BackupEngine(states, { BackupConditions(destination, false, false, false) }, { _, _, _ -> remote },
            isTakeoverReady = ::restorationCommitted)
            .runOnce(repository.loadSnapshot(), media, destination, credentials, newDevice, now + 2)
        assertEquals(3L, next.sequence)
        assertEquals(newDevice.uppercase(), V1Validator.latest(remote, BackupCancellation())!!.commit.writerDeviceID)
        assertNull(states.value!!.takeover)
        assertEquals(3, V1Validator.latest(remote, BackupCancellation())!!.manifest.moments.size)
    }

    @Test fun restoredAssetProvenanceUsesCaptureStampAndBacksUpWithoutChangingMedia() {
        val head = V1Validator.latest(remote, BackupCancellation())!!
        val sources = listOf(ImportProvenance.Camera, ImportProvenance.SystemProvided)
        val enriched = head.manifest.copy(assets = head.manifest.assets.mapIndexed { index, asset ->
            asset.copy(importProvenance = sources[index].wireValue)
        })
        val bytes = V1Json.encodeManifest(enriched)
        val hash = V1Json.sha256(bytes)
        val key = destination.prefix + "snapshots/$hash.json"
        remote.data[key] = bytes
        remote.data[destination.prefix + V1Json.commitRelativeKey(1)] = V1Json.encodeCommit(
            head.commit.copy(manifestHash = hash, manifestKey = key))

        takeover()
        val restored = repository.loadSnapshot()
        assertEquals(sources.toSet(), restored.assets.map { it.importProvenance }.toSet())
        restored.assets.forEach { asset ->
            assertEquals(asset.capturedAt.edit, asset.extensions.getValue(ImportProvenance.EXTENSION_KEY).edit)
        }
        val mapped = V1Mapper.map(restored, destination.prefix)
        assertEquals(enriched.assets, mapped.assets)
        assertEquals(enriched.resources, mapped.resources)
        assertTrue(remote.writes.isEmpty())
    }

    @Test fun missingLastOriginalLeavesLocalRecordsReceiptAndFilesUnchangedAndWritesNothing() {
        val resource = V1Validator.latest(remote, BackupCancellation())!!.manifest.resources.last()
        remote.data.remove(resource.objectKey)
        assertRestoreFailure()
    }

    @Test fun sameSizeWrongHashLeavesAllLocalStateUnchangedAndWritesNothing() {
        val resource = V1Validator.latest(remote, BackupCancellation())!!.manifest.resources.last()
        remote.data[resource.objectKey] = ByteArray(resource.byteCount.toInt()) { 42 }
        assertRestoreFailure()
    }

    @Test fun transportCannotClaimIntegrityForCorruptWrittenBytes() {
        val corrupt = object : CosObjectStore by remote {
            override fun download(key: String, output: OutputStream): CosDownload {
                val expected = remote.get(key)
                output.write(ByteArray(expected.size))
                return CosDownload(expected.size.toLong(), V1Json.sha256(expected))
            }
        }
        assertRestoreFailure(corrupt)
    }

    @Test fun receiptPersistenceFailureRollsBackRoomAndStagedFilesBeforeAnyCloudWrite() {
        val resource = V1Validator.latest(remote, BackupCancellation())!!.manifest.resources.first()
        val existing = File(media, "objects/${resource.sha256.take(2)}/${resource.sha256}")
        val bytes = remote.get(resource.objectKey)
        existing.parentFile!!.mkdirs()
        existing.writeBytes(bytes)
        val failing = object : BackupStatePersistence {
            override fun load() = states.load()
            override fun save(state: BackupState) { states.save(state); throw IOException("injected state fsync") }
            override fun restore(previous: BackupState?) = states.restore(previous)
        }
        assertRestoreFailure(persistence = failing, retainedFiles = listOf(existing))
        assertArrayEquals(bytes, existing.readBytes())
    }

    @Test fun concurrentImportWaitsForReceiptRollbackThenRetainsItsOriginal() {
        val resource = V1Validator.latest(remote, BackupCancellation())!!.manifest.resources.first { it.role == "photo" }
        val bytes = remote.get(resource.objectKey)
        val draftId = "concurrent-import"
        repository.createDraft(newDevice, now, draftId)
        val importer = MediaImporter(media, PreviewEncoder { _, _ -> "新导入的预览".toByteArray() },
            { _, _ -> true }, { _, _ -> CaptureTime.unknown() })
        val service = MediaImportService(repository, newDevice, importer) { now + 2 }
        val savingReceipt = CountDownLatch(1)
        val releaseFailure = CountDownLatch(1)
        val sourceOpened = CountDownLatch(1)
        val importStarted = CountDownLatch(1)
        val importThread = AtomicReference<Thread>()
        val request = ImportRequest("照片.jpg", "image/jpeg", true, false,
            { sourceOpened.countDown(); ByteArrayInputStream(bytes) }, null)
        val failing = object : BackupStatePersistence {
            override fun load() = states.load()
            override fun save(state: BackupState) {
                states.save(state)
                savingReceipt.countDown()
                check(releaseFailure.await(10, TimeUnit.SECONDS)) { "receipt failure was not released" }
                throw IOException("injected state fsync")
            }
            override fun restore(previous: BackupState?) = states.restore(previous)
        }
        val workers = Executors.newFixedThreadPool(2)
        try {
            val restoration = workers.submit<IOException> {
                try { takeover(persistence = failing); throw AssertionError("restore accepted a failed receipt save") }
                catch (failure: IOException) { failure }
            }
            assertTrue(savingReceipt.await(10, TimeUnit.SECONDS))
            val imported = workers.submit<StoredDraft> {
                importThread.set(Thread.currentThread())
                importStarted.countDown()
                service.importToDraft(draftId, listOf(request))
            }
            assertTrue(importStarted.await(10, TimeUnit.SECONDS))
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
            while (importThread.get().state != Thread.State.BLOCKED && sourceOpened.count > 0 &&
                System.nanoTime() < deadline) Thread.yield()
            assertEquals("import must wait before reusing restored originals", 1L, sourceOpened.count)
            assertEquals(Thread.State.BLOCKED, importThread.get().state)
            releaseFailure.countDown()
            assertEquals("injected state fsync", restoration.get(10, TimeUnit.SECONDS).message)
            val draft = imported.get(10, TimeUnit.SECONDS)
            assertEquals(draft, repository.loadDraft(draftId))
            draft.resources.forEach { importedResource ->
                val file = File(media, importedResource.objectKey)
                assertEquals(importedResource.byteCount, file.length())
                assertEquals(importedResource.sha256, V1Json.sha256(file.readBytes()))
            }
            assertArrayEquals(bytes, File(media, draft.resources.first { it.role == "photo" }.objectKey).readBytes())
            assertTrue(repository.loadSnapshot().records.isEmpty())
            assertNull(states.value)
            assertTrue(remote.writes.isEmpty())
        } finally {
            releaseFailure.countDown()
            workers.shutdownNow()
            assertTrue(workers.awaitTermination(10, TimeUnit.SECONDS))
        }
    }

    @Test fun changedLocalRecordDuringDownloadDoesNotGetOverwritten() {
        val concurrent = object : CosObjectStore by remote {
            override fun download(key: String, output: OutputStream): CosDownload {
                repository.saveManualRecord(note("concurrent", "下载时写下的记录"))
                return remote.download(key, output)
            }
        }
        try { takeover(concurrent); fail("concurrent local edit must stop restore") } catch (_: Exception) { }
        assertEquals("concurrent", repository.loadSnapshot().records.single().id)
        assertNull(states.value)
        assertTrue(remote.writes.isEmpty())
        assertTrue(media.walkTopDown().filter { it.isFile }.toList().isEmpty())
    }

    @Test fun lostRegistrationAcknowledgementIsReconciledAfterRestoreAndNeverRemovesData() {
        val receipt = takeover()
        remote.loseAfterPut = { it.contains("/commits/") }
        fun backup() = BackupEngine(states, { BackupConditions(destination, true, false, false) },
            { _, _, _ -> remote }, backoff = {}, maxAttempts = 1, isTakeoverReady = ::restorationCommitted)
            .runOnce(repository.loadSnapshot(), media, destination, credentials, newDevice, now + 2)
        try { backup(); fail("lost acknowledgement should remain retryable") } catch (_: CosException) { }
        assertEquals(2, repository.loadSnapshot().records.size)
        assertEquals(receipt, states.load()!!.receipt)
        assertNotNull(states.value!!.takeover)
        remote.loseAfterPut = { false }
        assertEquals(2L, backup().sequence)
        assertNull(states.value!!.takeover)
    }

    @Test fun registrationCannotPublishWhenRestoreTransactionDidNotCommit() {
        takeover()
        val snapshot = repository.loadSnapshot()
        // Simulate state JSON surviving a process death before the Room commit marker.
        repository.saveLocalSyncState(LocalSyncState(newDevice, null, null, false))
        try {
            BackupEngine(states, { BackupConditions(destination, true, false, false) }, { _, _, _ -> remote },
                isTakeoverReady = ::restorationCommitted)
                .runOnce(snapshot, media, destination, credentials, newDevice, now + 2)
            fail("uncommitted restore published")
        } catch (_: IllegalStateException) { }
        assertTrue(remote.writes.isEmpty())
        assertNotNull(states.value!!.takeover)
    }

    @Test fun unrelatedLocalRecordIsRetainedOnSuccessfulRestore() {
        repository.saveManualRecord(note("not-yet-backed-up", "本机新记录"))
        takeover()
        assertEquals(3, repository.loadSnapshot().records.size)
        assertTrue(repository.loadSnapshot().records.any { it.id == "not-yet-backed-up" })
    }

    private fun assertRestoreFailure(store: CosObjectStore = remote, persistence: BackupStatePersistence = states,
                                     retainedFiles: List<File> = emptyList()) {
        repository.saveManualRecord(note("local-before", "保留这条本机记录"))
        val before = repository.loadSnapshot()
        val sync = repository.localSyncState()
        val sentinel = File(media, "existing-original").apply { writeText("keep") }
        try { takeover(store, persistence); fail("incomplete restore accepted") } catch (_: Exception) { }
        assertEquals(before, repository.loadSnapshot())
        assertEquals(sync, repository.localSyncState())
        assertNull(states.value)
        assertEquals("keep", sentinel.readText())
        assertEquals((retainedFiles + sentinel).toSet(), media.walkTopDown().filter { it.isFile }.toSet())
        assertTrue(remote.writes.isEmpty())
    }
}
