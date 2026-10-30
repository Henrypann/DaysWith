package com.henrypann.jinbao365.media

import android.content.Context
import android.net.Uri
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.henrypann.jinbao365.archive.*
import com.henrypann.jinbao365.data.ArchiveDatabase
import com.henrypann.jinbao365.data.ArchiveRepository
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
import java.util.concurrent.Executor

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = android.app.Application::class)
class PendingMediaCoordinatorTest {
    @get:Rule val temp = TemporaryFolder()
    private val context get() = ApplicationProvider.getApplicationContext<Context>()

    private class QueueExecutor : Executor {
        val tasks = ArrayDeque<Runnable>()
        override fun execute(command: Runnable) { tasks.addLast(command) }
        fun drain() { while (tasks.isNotEmpty()) tasks.removeFirst().run() }
    }

    private fun fixture(test: (ArchiveRepository, MediaImportService, QueueExecutor, File) -> Unit) {
        // Robolectric changes filesDir between cases; AndroidX keeps its path cache statically.
        val cache = androidx.core.content.FileProvider::class.java.getDeclaredField("sCache").apply { isAccessible = true }
        (cache.get(null) as MutableMap<*, *>).clear()
        val db = Room.inMemoryDatabaseBuilder(context, ArchiveDatabase::class.java).allowMainThreadQueries().build()
        try {
            val repo = ArchiveRepository(db)
            val root = temp.newFolder()
            val importer = MediaImporter(root, PreviewEncoder { file, _ -> ("preview:" + file.readText()).toByteArray() },
                { _, _ -> false }, { _, _ -> CaptureTime.unknown() })
            test(repo, MediaImportService(repo, "test", importer) { 1_800_000_000_000L }, QueueExecutor(), root)
        } finally { db.close() }
    }

    private fun controller(repo: ArchiveRepository, service: MediaImportService, executor: Executor,
        factory: (Uri, ImportOrigin) -> ImportRequest = { uri, origin ->
            ImportRequest("photo.jpg", "image/jpeg", false, origin == ImportOrigin.PhotoPicker,
                { ByteArrayInputStream(uri.toString().toByteArray()) }, null, origin = origin)
        }) = PendingMediaCoordinator(context, repo, "test", service, executor, factory) { 1_800_000_000_000L }

    @Test fun queuedSelectionHasDurableDraftAndCannotCommitUntilReady() = fixture { repo, service, queue, _ ->
        val coordinator = controller(repo, service, queue)
        val task = coordinator.enqueueSelection(listOf(Uri.parse("content://fixture/one")), ImportOrigin.PhotoPicker)
        assertNotNull(repo.loadDraft(task.draftId))
        assertTrue(repo.loadSnapshot().records.isEmpty())
        assertThrows(ArchiveValidationException::class.java) { repo.commitDraft(task.draftId) }
        queue.drain()
        assertEquals(PendingMediaStatus.Ready, coordinator.tasksForDraft(task.draftId).single().status)
        assertEquals(ImportProvenance.SystemProvided, repo.loadDraft(task.draftId)!!.assets.single().importProvenance)
        val saved = repo.commitDraft(task.draftId)
        assertEquals(saved.id, repo.commitDraft(task.draftId).id)
        assertEquals(1, repo.loadSnapshot().records.size)
    }

    @Test fun processRecoveryImportsQueuedAndInterruptedTasksExactlyOnce() = fixture { repo, service, queue, _ ->
        val first = controller(repo, service, queue)
        val task = first.enqueueSelection(listOf(Uri.parse("content://fixture/recover")), ImportOrigin.Document)
        // Simulate loss of the process before its queued runnable ran.
        queue.tasks.clear()
        repo.transitionPendingMediaTask(task.id, setOf("Queued"), "Importing", completed = 1)
        val restarted = controller(repo, service, queue)
        restarted.resumeInterrupted()
        queue.drain()
        restarted.resumeInterrupted()
        queue.drain()
        assertEquals(1, repo.loadDrafts().size)
        assertEquals(1, repo.loadDraft(task.draftId)!!.assets.size)
        assertEquals(PendingMediaStatus.Ready, restarted.tasksForDraft(task.draftId).single().status)
        assertEquals(ImportProvenance.FileSelected, repo.loadDraft(task.draftId)!!.assets.single().importProvenance)
    }

    @Test fun captureCancellationDeletesOnlyUntouchedOwnedDraft() = fixture { repo, service, queue, _ ->
        val coordinator = controller(repo, service, queue)
        val capture = coordinator.prepareCamera()
        assertEquals(capture, coordinator.pendingCapture())
        assertThrows(ArchiveValidationException::class.java) { repo.commitDraft(capture.draftId) }
        coordinator.finishCamera(capture.taskId, false)
        assertNull(repo.loadDraft(capture.draftId))
        assertNull(coordinator.pendingCapture())
        assertFalse(File(context.filesDir, "pending-media/${capture.taskId}/capture.jpg").exists())
        val existing = repo.createDraft("test", 1_800_000_000_000L)
        val second = coordinator.prepareCamera(existing.record.id)
        coordinator.finishCamera(second.taskId, false)
        assertNotNull(repo.loadDraft(existing.record.id))
    }

    @Test fun cancelledCapturePreservesTextEnteredInItsDraft() = fixture { repo, service, queue, _ ->
        val coordinator = controller(repo, service, queue)
        val capture = coordinator.prepareCamera()
        repo.updateDraft(capture.draftId, "test", 1_800_000_000_000L) { it.copy(note = "keep my words") }
        coordinator.finishCamera(capture.taskId, false)
        assertNotNull(repo.loadDraft(capture.draftId))
    }

    @Test fun failedCameraRetainsFullSizeInputAndRetryCleansOnlyAfterDurableAttachment() = fixture { repo, service, queue, _ ->
        var fail = true
        val coordinator = controller(repo, service, queue) { uri, origin ->
            ImportRequest("camera.jpg", "image/jpeg", false, false, {
                if (fail) throw IOException("temporarily unreadable")
                context.contentResolver.openInputStream(uri)!!
            }, null, origin = origin)
        }
        val capture = coordinator.prepareCamera()
        val file = File(context.filesDir, "pending-media/${capture.taskId}/capture.jpg")
        file.writeText("camera-original-full-size")
        coordinator.finishCamera(capture.taskId, true)
        coordinator.finishCamera(capture.taskId, true) // duplicate Android callback
        queue.drain()
        assertEquals(PendingMediaStatus.Failed, coordinator.tasksForDraft(capture.draftId).single().status)
        assertTrue(file.isFile)
        assertThrows(ArchiveValidationException::class.java) { repo.commitDraft(capture.draftId) }
        fail = false
        coordinator.retry(capture.taskId)
        queue.drain()
        assertFalse(file.exists())
        assertEquals(1, repo.loadDraft(capture.draftId)!!.assets.size)
        assertEquals(ImportProvenance.Camera, repo.loadDraft(capture.draftId)!!.assets.single().importProvenance)
    }

    @Test fun awaitingCameraSurvivesProcessRecreationWithoutPrematureConsumption() = fixture { repo, service, queue, _ ->
        val coordinator = controller(repo, service, queue)
        val capture = coordinator.prepareCamera()
        File(context.filesDir, "pending-media/${capture.taskId}/capture.jpg").writeText("camera-still-writing")
        val restarted = controller(repo, service, queue)
        restarted.resumeInterrupted()
        queue.drain()
        assertEquals(capture, restarted.pendingCapture())
        assertTrue(repo.loadDraft(capture.draftId)!!.assets.isEmpty())
        restarted.finishCamera(capture.taskId, false)
    }

    @Test fun discardWhileSourceIsReadPreventsLateAppendAndRollsBackUnreferencedObjects() = fixture { repo, service, queue, root ->
        var draftId = ""
        val coordinator = controller(repo, service, queue) { _, origin ->
            ImportRequest("photo.jpg", "image/jpeg", false, false, {
                repo.discardDraft(draftId)
                ByteArrayInputStream("selected".toByteArray())
            }, null, origin = origin)
        }
        val task = coordinator.enqueueSelection(listOf(Uri.parse("content://fixture/discard")), ImportOrigin.Document)
        draftId = task.draftId
        queue.drain()
        assertNull(repo.loadDraft(draftId))
        assertTrue(repo.loadSnapshot().records.isEmpty())
        assertEquals(PendingMediaStatus.Cancelled, coordinator.tasksForDraft(draftId).single().status)
        assertTrue(root.walkTopDown().none { it.isFile })
    }

    @Test fun cancellationBeforeRunNeverOpensSourceAndLeavesNoEmptyOwnedDraft() = fixture { repo, service, queue, _ ->
        val coordinator = controller(repo, service, queue) { _, _ -> error("must not open cancelled source") }
        val task = coordinator.enqueueSelection(listOf(Uri.parse("content://fixture/cancel")), ImportOrigin.Document)
        coordinator.cancel(task.id)
        queue.drain()
        assertNull(repo.loadDraft(task.draftId))
        assertEquals(PendingMediaStatus.Cancelled, coordinator.tasksForDraft(task.draftId).single().status)
    }

    @Test fun savedRecordAttachmentsStayInDurableEditDraftUntilAtomicSave() = fixture { repo, service, queue, _ ->
        val initial = repo.createDraft("test", 1_800_000_000_000L)
        repo.updateDraft(initial.record.id, "test", 1_800_000_000_000L) { it.copy(note = "saved moment") }
        val original = repo.commitDraft(initial.record.id)
        val editing = repo.createEditDraft(original.id)
        val coordinator = controller(repo, service, queue)
        val task = coordinator.enqueueSelection(listOf(Uri.parse("content://fixture/attachment")), ImportOrigin.PhotoPicker, editing.record.id)
        assertThrows(ArchiveValidationException::class.java) { repo.commitDraft(editing.record.id) }
        queue.drain()
        assertEquals(original, repo.loadSnapshot().records.single())
        assertEquals(PendingMediaStatus.Ready, coordinator.tasksForDraft(editing.record.id).single().status)
        val saved = repo.commitDraft(task.draftId)
        assertEquals(original.id, saved.id)
        assertEquals(1, repo.loadSnapshot().records.size)
        assertEquals(1, jsonStringList(saved.assetIds.value).size)
    }

    @Test fun shaDuplicateRetainsFirstProvenanceInsteadOfInventingStrongerEvidence() = fixture { repo, service, queue, _ ->
        val coordinator = controller(repo, service, queue) { _, origin ->
            ImportRequest("same.jpg", "image/jpeg", true, origin == ImportOrigin.PhotoPicker,
                { ByteArrayInputStream("same".toByteArray()) },
                if (origin == ImportOrigin.Document) { { ByteArrayInputStream("same".toByteArray()) } } else null,
                origin = origin)
        }
        val first = coordinator.enqueueSelection(listOf(Uri.parse("content://fixture/first")), ImportOrigin.PhotoPicker)
        queue.drain()
        repo.commitDraft(first.draftId)
        val second = coordinator.enqueueSelection(listOf(Uri.parse("content://fixture/second")), ImportOrigin.Document)
        queue.drain()
        assertEquals(ImportProvenance.SystemProvided, repo.loadDraft(second.draftId)!!.assets.single().importProvenance)
    }
    @Test fun failedMiddleItemKeepsSuccessesAndRetryRestoresSelectionOrderWithoutDuplicates() = fixture { repo, service, queue, _ ->
        var fail = true
        val coordinator = controller(repo, service, queue) { uri, origin ->
            ImportRequest(uri.lastPathSegment!!, "image/jpeg", false, false, {
                if (uri.lastPathSegment == "two" && fail) throw IOException("unavailable")
                ByteArrayInputStream(uri.toString().toByteArray())
            }, null, origin = origin)
        }
        val task = coordinator.enqueueSelections(listOf(
            MediaSelection(Uri.parse("content://fixture/one"), ImportOrigin.MediaStoreGallery),
            MediaSelection(Uri.parse("content://fixture/two"), ImportOrigin.Document),
            MediaSelection(Uri.parse("content://fixture/three"), ImportOrigin.PhotoPicker)))
        queue.drain()
        val partial = coordinator.tasksForDraft(task.draftId).single()
        assertEquals(PendingMediaStatus.Failed, partial.status)
        assertEquals(listOf(PendingMediaItemStatus.Degraded, PendingMediaItemStatus.Failed, PendingMediaItemStatus.Degraded), partial.items.map { it.status })
        assertEquals(2, repo.loadDraft(task.draftId)!!.assets.size)
        val firstIds = jsonStringList(repo.loadDraft(task.draftId)!!.record.assetIds.value)
        fail = false
        coordinator.retryItem(task.id, partial.items[1].id)
        queue.drain()
        val done = coordinator.tasksForDraft(task.draftId).single()
        val ids = jsonStringList(repo.loadDraft(task.draftId)!!.record.assetIds.value)
        assertEquals(PendingMediaStatus.Ready, done.status)
        assertEquals(listOf(firstIds[0], done.items[1].assetId, firstIds[1]), ids)
        assertEquals(3, repo.loadDraft(task.draftId)!!.assets.size)
        coordinator.retry(task.id)
        queue.drain()
        assertEquals(ids, jsonStringList(repo.loadDraft(task.draftId)!!.record.assetIds.value))
    }

    @Test fun partialFailureDoesNotBlockSavingSuccessAndCannotRetryAfterSave() = fixture { repo, service, queue, _ ->
        val coordinator = controller(repo, service, queue) { uri, origin ->
            ImportRequest("photo.jpg", "image/jpeg", false, false, {
                if (uri.lastPathSegment == "bad") throw SecurityException("private URI must not be persisted")
                ByteArrayInputStream("good".toByteArray())
            }, null, origin = origin)
        }
        val task = coordinator.enqueueSelection(listOf(Uri.parse("content://fixture/good"), Uri.parse("content://fixture/bad")), ImportOrigin.Document)
        queue.drain()
        val failed = coordinator.tasksForDraft(task.draftId).single().items.last()
        assertEquals("照片的访问授权已失效，请重新选择。", failed.errorMessage)
        val record = repo.commitDraft(task.draftId)
        coordinator.retryItem(task.id, failed.id)
        queue.drain()
        assertEquals(1, jsonStringList(record.assetIds.value).size)
        assertEquals(PendingMediaItemStatus.Cancelled, coordinator.tasksForDraft(task.draftId).single().items.last().status)
        assertNull(repo.loadDraft(task.draftId))
    }

    @Test fun removeFailedSelectionRetainsSuccessfulDraftAndCompletesTask() = fixture { repo, service, queue, _ ->
        val coordinator = controller(repo, service, queue) { uri, origin ->
            ImportRequest("photo.jpg", "image/jpeg", false, false, {
                if (uri.lastPathSegment == "bad") throw IOException("failure")
                ByteArrayInputStream("good".toByteArray())
            }, null, origin = origin)
        }
        val task = coordinator.enqueueSelection(listOf(Uri.parse("content://fixture/good"), Uri.parse("content://fixture/bad")), ImportOrigin.Document)
        queue.drain()
        coordinator.removeItem(task.id, coordinator.tasksForDraft(task.draftId).single().items.last().id)
        assertEquals(PendingMediaStatus.Ready, coordinator.tasksForDraft(task.draftId).single().status)
        assertEquals(1, repo.loadDraft(task.draftId)!!.assets.size)
    }

    @Test fun processRecoverySkipsDurableSuccessReceiptAndRetriesOnlyInterruptedItem() = fixture { repo, service, queue, _ ->
        val task = controller(repo, service, queue).enqueueSelection(listOf(Uri.parse("content://fixture/one"), Uri.parse("content://fixture/two")), ImportOrigin.Document)
        queue.tasks.clear()
        repo.transitionPendingMediaTask(task.id, setOf("Queued"), "Importing")
        val firstItem = repo.pendingMediaItems(task.id).first()
        repo.startPendingMediaItem(task.id, firstItem.id)
        service.importPendingItem(task.id, firstItem.id, ImportRequest("one", "image/jpeg", false, false,
            { ByteArrayInputStream("one".toByteArray()) }, null))
        repo.startPendingMediaItem(task.id, repo.pendingMediaItems(task.id).last().id)
        var opened = 0
        val restarted = controller(repo, service, queue) { uri, origin ->
            opened++
            ImportRequest("two", "image/jpeg", false, false, { ByteArrayInputStream("two".toByteArray()) }, null, origin = origin)
        }
        restarted.resumeInterrupted()
        queue.drain()
        assertEquals(1, opened)
        assertEquals(2, repo.loadDraft(task.draftId)!!.assets.size)
        assertEquals(PendingMediaStatus.Ready, restarted.tasksForDraft(task.draftId).single().status)
    }

    @Test fun version6UriArrayResumesAndReadyLegacyReceiptNeverReimports() = fixture { repo, service, queue, _ ->
        val taskId = java.util.UUID.randomUUID().toString()
        val draftId = java.util.UUID.randomUUID().toString()
        repo.createPendingMediaTask(com.henrypann.jinbao365.data.PendingMediaTaskEntity(
            taskId, draftId, "Document", "Queued", "[\"content://fixture/legacy\"]", 0, 1, null, true), "test", 1_800_000_000_000L)
        val coordinator = controller(repo, service, queue)
        coordinator.resumeInterrupted()
        queue.drain()
        assertEquals(1, repo.loadDraft(draftId)!!.assets.size)
        val readyId = java.util.UUID.randomUUID().toString()
        repo.createPendingMediaTask(com.henrypann.jinbao365.data.PendingMediaTaskEntity(
            readyId, draftId, "Document", "Ready", "[\"content://fixture/legacy\"]", 1, 1, null, false), "test", 1_800_000_000_000L)
        val restarted = controller(repo, service, queue) { _, _ -> error("completed legacy task must never reopen") }
        restarted.resumeInterrupted()
        queue.drain()
        val receipt = restarted.tasksForDraft(draftId).first { it.id == readyId }
        assertEquals(PendingMediaItemStatus.Success, receipt.items.single().status)
        assertNull(receipt.items.single().assetId)
        assertEquals(1, repo.loadDraft(draftId)!!.assets.size)
    }

}
