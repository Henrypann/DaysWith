package com.henrypann.jinbao365.media

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.henrypann.jinbao365.archive.ArchiveJson
import com.henrypann.jinbao365.archive.ArchiveRecord
import com.henrypann.jinbao365.archive.ArchiveValidationException
import com.henrypann.jinbao365.data.ArchiveDatabase
import com.henrypann.jinbao365.data.ArchiveRepository
import com.henrypann.jinbao365.editing.MediaRemoval
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31])
class MediaImportServiceTest {
    @get:Rule val temp = TemporaryFolder()

    @Test
    fun oneSelectionStaysInARestorableDraftUntilSaveAndRepeatedMediaCanBelongToANewRecord() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val name = "media-draft-${UUID.randomUUID()}.db"
        val root = temp.newFolder()
        var database = database(context, name)
        try {
            var repository = ArchiveRepository(database)
            repository.createDraft("android", 10, "draft-first")
            var service = service(repository, root)
            val draft = service.importToDraft("draft-first", listOf(request("third"), request("first"), request("third")))
            assertEquals(draft.assets.map { it.id }.toSet(), assetIds(draft.record).toSet())
            assertEquals(listOf(hashAsset("third"), hashAsset("first")), assetIds(draft.record))
            assertEquals(2, draft.assets.size)
            assertEquals(4, draft.resources.size)
            assertTrue(repository.loadSnapshot().records.isEmpty())
            val before = objects(root)
            database.close()
            database = database(context, name)
            repository = ArchiveRepository(database)
            service = service(repository, root)
            assertEquals(draft, repository.loadDraft("draft-first"))
            service.importToDraft("draft-first", listOf(request("second")))
            val firstRecord = repository.commitDraft("draft-first")
            assertEquals(listOf(hashAsset("third"), hashAsset("first"), hashAsset("second")), assetIds(firstRecord))
            assertNull(repository.loadDraft("draft-first"))
            assertTrue(objects(root).containsAll(before))
            repository.createDraft("android", 11, "draft-second")
            service.importToDraft("draft-second", listOf(request("first")))
            val secondRecord = repository.commitDraft("draft-second")
            assertEquals(listOf(hashAsset("first")), assetIds(secondRecord))
            val snapshot = repository.loadSnapshot()
            assertEquals(2, snapshot.records.size)
            assertEquals(3, snapshot.assets.size)
            assertEquals(6, snapshot.resources.size)
            assertFalse(service.importSingle(request("first")).inserted)
            assertEquals(2, repository.loadSnapshot().records.size)
            assertEquals(6, objects(root).size)
            ArchiveJson.parseSnapshot(ArchiveJson.canonical(snapshot))
        } finally {
            database.close()
            context.deleteDatabase(name)
        }
    }

    @Test
    fun anOverflowAppendRollsBackOnlyNewFilesAndLeavesTheDraftUnchanged() = withRepository { repository, _, root ->
        repository.createDraft("android", 10, "draft")
        val service = service(repository, root)
        val full = service.importToDraft("draft", (1..30).map { request("source-$it") })
        val before = objects(root)
        assertThrows(ArchiveValidationException::class.java) { service.importToDraft("draft", listOf(request("thirty-first"))) }
        assertEquals(full, repository.loadDraft("draft"))
        assertEquals(before, objects(root))
        assertTrue(repository.loadSnapshot().records.isEmpty())
    }

    @Test
    fun recordAppendKeepsSelectionOrderDeduplicatesAndPreservesOccurredAt() = withRepository { repository, _, root ->
        val service = service(repository, root)
        val before = service.importSingle(request("first")).record
        val progress = mutableListOf<Pair<Int, Int>>()
        val updated = service.importToRecord(before.id,
            listOf(request("third"), request("first"), request("second"), request("third")), before,
            onProgress = { completed, total -> progress += completed to total })
        assertEquals(listOf(hashAsset("first"), hashAsset("third"), hashAsset("second")), assetIds(updated))
        assertEquals(before.occurredAt, updated.occurredAt)
        assertEquals(before.assetIds.edit.counter + 1, updated.assetIds.edit.counter)
        assertEquals("android", updated.assetIds.edit.deviceID)
        assertEquals(20L, updated.assetIds.edit.at)
        assertEquals(4 to 4, progress.last())
        val snapshot = repository.loadSnapshot()
        assertEquals(updated, snapshot.records.single())
        assertEquals(3, snapshot.assets.size)
        assertEquals(6, snapshot.resources.size)
        assertEquals(6, objects(root).size)
    }

    @Test
    fun aThirtyFirstRecordMediaRollsBackNewFilesAndLeavesTheRecordUnchanged() = withRepository { repository, _, root ->
        repository.createDraft("android", 10, "full")
        val service = service(repository, root)
        service.importToDraft("full", (1..30).map { request("source-$it") })
        val full = repository.commitDraft("full")
        val snapshot = ArchiveJson.canonical(repository.loadSnapshot())
        val before = objects(root)
        val error = assertThrows(ArchiveValidationException::class.java) {
            service.importToRecord(full.id, listOf(request("source-1"), request("thirty-first")), full)
        }
        assertEquals("Choose 0–30 distinct media items.", error.message)
        assertEquals(snapshot, ArchiveJson.canonical(repository.loadSnapshot()))
        assertEquals(before, objects(root))
    }

    @Test
    fun staleRecordAppendRollsBackNewFilesAndLeavesTheCurrentRecordUnchanged() = withRepository { repository, _, root ->
        val service = service(repository, root)
        val stale = service.importSingle(request("saved")).record
        repository.editRecord(stale.id, "android", 30) { it.copy(note = "new note") }
        val snapshot = ArchiveJson.canonical(repository.loadSnapshot())
        val before = objects(root)
        val error = assertThrows(ArchiveValidationException::class.java) {
            service.importToRecord(stale.id, listOf(request("saved"), request("new")), stale)
        }
        assertEquals("This record changed. Reload before saving.", error.message)
        assertEquals(snapshot, ArchiveJson.canonical(repository.loadSnapshot()))
        assertEquals(before, objects(root))
    }

    @Test
    fun recordAppendDatabaseFailurePreservesSavedAndDraftFilesIncludingASharedPreview() = withRepository { repository, database, root ->
        val service = service(repository, root, "shared-preview")
        val saved = service.importSingle(request("saved")).record
        repository.createDraft("android", 10, "keeper")
        val keeper = service.importToDraft("keeper", listOf(request("draft-owned")))
        val snapshot = ArchiveJson.canonical(repository.loadSnapshot())
        val before = objects(root)
        database.openHelper.writableDatabase.execSQL(
            "CREATE TRIGGER reject_resource BEFORE INSERT ON resources BEGIN SELECT RAISE(ABORT, 'write failed'); END",
        )
        assertThrows(Exception::class.java) {
            service.importToRecord(saved.id, listOf(request("draft-owned"), request("new")), saved)
        }
        assertEquals(snapshot, ArchiveJson.canonical(repository.loadSnapshot()))
        assertEquals(keeper, repository.loadDraft("keeper"))
        assertEquals(before, objects(root))
        (repository.loadSnapshot().resources + keeper.resources).forEach { resource ->
            assertEquals(resource.sha256, File(root, resource.objectKey).inputStream().use { ContentHash.sha256(it).hex })
        }
    }

    @Test
    fun recordAppendChecksReadOnlyStateInsideCommitAndRollsBackNewFiles() = withRepository { repository, _, root ->
        repository.reconcileOwner("android")
        val saved = service(repository, root).importSingle(request("saved")).record
        val snapshot = ArchiveJson.canonical(repository.loadSnapshot())
        val before = objects(root)
        val importer = MediaImporter(root, PreviewEncoder { _, _ -> "preview".toByteArray() },
            { _, _ -> repository.reconcileOwner("restored-phone"); true }, { _, _ -> CaptureTime.unknown() })
        val service = MediaImportService(repository, "android", importer) { 20 }
        assertThrows(ArchiveValidationException::class.java) {
            service.importToRecord(saved.id, listOf(request("new")), saved)
        }
        assertEquals(snapshot, ArchiveJson.canonical(repository.loadSnapshot()))
        assertEquals(before, objects(root))
    }

    @Test
    fun trashedRecordAppendRollsBackNewFilesAndLeavesTheRecordUnchanged() = withRepository { repository, _, root ->
        val service = service(repository, root)
        val saved = service.importSingle(request("saved")).record
        val trashed = repository.trashRecord(saved.id, "android", 30)
        val snapshot = ArchiveJson.canonical(repository.loadSnapshot())
        val before = objects(root)
        assertThrows(ArchiveValidationException::class.java) {
            service.importToRecord(trashed.id, listOf(request("new")), trashed)
        }
        assertEquals(snapshot, ArchiveJson.canonical(repository.loadSnapshot()))
        assertEquals(before, objects(root))
    }

    @Test
    fun databaseFailurePreservesOldRecordsAndOtherDraftResourcesWithoutPartialAppend() = withRepository { repository, database, root ->
        val shared = service(repository, root, "shared-preview")
        shared.importSingle(request("saved"))
        repository.createDraft("android", 10, "keeper")
        shared.importToDraft("keeper", listOf(request("draft-owned")))
        repository.createDraft("android", 10, "target")
        val snapshot = ArchiveJson.canonical(repository.loadSnapshot())
        val draftBefore = repository.loadDraft("target")
        val before = objects(root)
        database.openHelper.writableDatabase.execSQL(
            "CREATE TRIGGER reject_draft BEFORE INSERT ON drafts BEGIN SELECT RAISE(ABORT, 'write failed'); END",
        )
        assertThrows(Exception::class.java) {
            shared.importToDraft("target", listOf(request("draft-owned"), request("new")))
        }
        assertEquals(snapshot, ArchiveJson.canonical(repository.loadSnapshot()))
        assertEquals(draftBefore, repository.loadDraft("target"))
        assertEquals(before, objects(root))
        assertEquals(1, repository.loadDraft("keeper")!!.assets.size)
    }

    @Test
    fun aDatabaseFailureOnTheLegacySinglePathDoesNotLeaveAHalfSnapshot() = withRepository { repository, database, root ->
        val service = service(repository, root, "shared-preview")
        service.importSingle(request("saved"))
        val before = objects(root)
        val snapshot = ArchiveJson.canonical(repository.loadSnapshot())
        database.openHelper.writableDatabase.execSQL(
            "CREATE TRIGGER reject_resource BEFORE INSERT ON resources BEGIN SELECT RAISE(ABORT, 'resource failed'); END",
        )
        assertThrows(Exception::class.java) { service.importSingle(request("new")) }
        assertEquals(snapshot, ArchiveJson.canonical(repository.loadSnapshot()))
        assertEquals(before, objects(root))
    }

    @Test
    fun readOnlyStateAppearingDuringPreparationIsCheckedInsideTheCommit() = withRepository { repository, _, root ->
        repository.reconcileOwner("android")
        repository.createDraft("android", 10, "draft")
        val before = repository.loadDraft("draft")
        val importer = MediaImporter(root, PreviewEncoder { _, _ -> "preview".toByteArray() },
            { _, _ -> repository.reconcileOwner("restored-phone"); true }, { _, _ -> CaptureTime.unknown() })
        val service = MediaImportService(repository, "android", importer) { 20 }
        assertThrows(ArchiveValidationException::class.java) { service.importToDraft("draft", listOf(request("new"))) }
        assertEquals(before, repository.loadDraft("draft"))
        assertTrue(repository.loadSnapshot().records.isEmpty())
        assertTrue(objects(root).isEmpty())
    }

    @Test
    fun rollbackRetainsAnObjectRecreatedForAnotherPersistentDraft() = withRepository { repository, _, root ->
        repository.createDraft("android", 10, "keeper")
        service(repository, root).importToDraft("keeper", listOf(request("shared")))
        val retained = repository.loadDraft("keeper")!!.resources
        retained.forEach { assertTrue(File(root, it.objectKey).delete()) }
        repository.createDraft("android", 10, "target")
        val broken = request("broken").copy(openGiven = { throw IOException("source unavailable") })
        assertThrows(IOException::class.java) { service(repository, root).importToDraft("target", listOf(request("shared"), broken)) }
        retained.forEach { resource ->
            assertTrue(File(root, resource.objectKey).isFile)
            assertEquals(resource.sha256, File(root, resource.objectKey).inputStream().use { ContentHash.sha256(it).hex })
        }
        assertTrue(repository.loadDraft("target")!!.assets.isEmpty())
    }

    @Test
    fun concurrentRecreatedImportersCommitBothRecordsWithoutLosingFilesOrExistingRecords() = withRepository { repository, database, root ->
        service(repository, root).importSingle(request("existing"))
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val slowImporter = MediaImporter(root, PreviewEncoder { file, _ ->
            entered.countDown()
            assertTrue(release.await(10, TimeUnit.SECONDS))
            "preview-${file.readText()}".toByteArray()
        }, { _, _ -> true }, { _, _ -> CaptureTime.unknown() })
        val first = MediaImportService(repository, "android", slowImporter) { 20 }
        val second = service(ArchiveRepository(database), root)
        val workers = Executors.newFixedThreadPool(2)
        try {
            val a = workers.submit<SingleImportResult> { first.importSingle(request("first")) }
            assertTrue(entered.await(10, TimeUnit.SECONDS))
            val started = CountDownLatch(1)
            val b = workers.submit<SingleImportResult> { started.countDown(); second.importSingle(request("second")) }
            assertTrue(started.await(10, TimeUnit.SECONDS))
            release.countDown()
            assertTrue(a.get(10, TimeUnit.SECONDS).inserted)
            assertTrue(b.get(10, TimeUnit.SECONDS).inserted)
            val snapshot = repository.loadSnapshot()
            assertEquals(3, snapshot.records.size)
            assertEquals(3, snapshot.assets.size)
            snapshot.resources.forEach { resource ->
                assertEquals(resource.sha256, File(root, resource.objectKey).inputStream().use { ContentHash.sha256(it).hex })
            }
        } finally {
            release.countDown()
            workers.shutdownNow()
        }
    }

    @Test
    fun discardingADraftDeletesOnlyExclusiveObjectsAndKeepsFormalAndOtherDraftMedia() = withRepository { repository, _, root ->
        val service = service(repository, root)
        val saved = service.importSingle(request("formal"))
        repository.trashRecord(saved.record.id, "android", 20)
        repository.createDraft("android", 10, "keeper")
        val keeper = service.importToDraft("keeper", listOf(request("shared")))
        repository.createDraft("android", 10, "target")
        val target = service.importToDraft("target", listOf(request("formal"), request("shared"), request("exclusive")))
        val exclusive = target.resources.filter { it.assetID == hashAsset("exclusive") }
        assertEquals(6, objects(root).size)
        service.discardDraft("target")
        assertNull(repository.loadDraft("target"))
        assertTrue(exclusive.all { !File(root, it.objectKey).exists() })
        assertTrue(keeper.resources.all { File(root, it.objectKey).isFile })
        assertTrue(repository.loadSnapshot().resources.all { File(root, it.objectKey).isFile })
        assertEquals(4, objects(root).size)
        service.discardDraft("keeper")
        assertEquals(2, objects(root).size)
        assertEquals(saved.record.id, repository.loadSnapshot().records.single().id)
    }

    @Test
    fun readOnlyRejectionLeavesDraftMetadataAndAllFilesUnchanged() = withRepository { repository, _, root ->
        repository.reconcileOwner("android")
        repository.createDraft("android", 10, "draft")
        val service = service(repository, root)
        val draft = service.importToDraft("draft", listOf(request("exclusive")))
        val before = objects(root)
        repository.reconcileOwner("restored-phone")
        assertThrows(ArchiveValidationException::class.java) { service.discardDraft("draft") }
        assertThrows(ArchiveValidationException::class.java) {
            service.removeDraftMedia("draft", hashAsset("exclusive"), confirmDiscard = true)
        }
        assertEquals(draft, repository.loadDraft("draft"))
        assertEquals(before, objects(root))
    }

    @Test
    fun removingMediaCleansReleasedObjectsButLastBlankDraftWaitsForConfirmation() = withRepository { repository, _, root ->
        repository.createDraft("android", 10, "draft")
        val service = service(repository, root)
        service.importToDraft("draft", listOf(request("first"), request("last")))
        assertEquals(MediaRemoval.Updated, service.removeDraftMedia("draft", hashAsset("first")))
        val retained = repository.loadDraft("draft")!!
        assertEquals(listOf(hashAsset("last")), assetIds(retained.record))
        assertEquals(1, retained.assets.size)
        assertEquals(2, retained.resources.size)
        assertEquals(2, objects(root).size)
        assertEquals(MediaRemoval.NeedsDiscardConfirmation, service.removeDraftMedia("draft", hashAsset("last")))
        assertEquals(retained, repository.loadDraft("draft"))
        assertEquals(2, objects(root).size)
        assertEquals(MediaRemoval.DraftDiscarded, service.removeDraftMedia("draft", hashAsset("last"), confirmDiscard = true))
        assertNull(repository.loadDraft("draft"))
        assertTrue(objects(root).isEmpty())
    }

    private fun withRepository(block: (ArchiveRepository, ArchiveDatabase, File) -> Unit) {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val database = Room.inMemoryDatabaseBuilder(context, ArchiveDatabase::class.java).allowMainThreadQueries().build()
        try { block(ArchiveRepository(database), database, temp.newFolder()) } finally { database.close() }
    }

    private fun database(context: Context, name: String) = Room.databaseBuilder(context, ArchiveDatabase::class.java, name)
        .allowMainThreadQueries().build()
    private fun service(repository: ArchiveRepository, root: File, sharedPreview: String? = null) = MediaImportService(
        repository, "android", MediaImporter(root, PreviewEncoder { file, _ ->
            (sharedPreview ?: "preview-${file.readText()}").toByteArray()
        }, { _, _ -> true }, { _, _ -> CaptureTime.unknown() }),
    ) { 20 }
    private fun request(original: String) = ImportRequest("$original.jpg", "image/jpeg", true, false,
        { ByteArrayInputStream(original.toByteArray()) }, null)
    private fun hashAsset(original: String) = "asset-${ContentHash.sha256(original.toByteArray()).hex.take(12)}"
    private fun assetIds(record: ArchiveRecord) = (record.assetIds.value as JsonArray).map { it.jsonPrimitive.content }
    private fun objects(root: File) = root.walkTopDown().filter { it.isFile }.map { it.relativeTo(root).path }.toSet()
}
