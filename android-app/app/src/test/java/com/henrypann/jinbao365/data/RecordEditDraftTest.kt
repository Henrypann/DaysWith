package com.henrypann.jinbao365.data

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.henrypann.jinbao365.archive.*
import com.henrypann.jinbao365.media.*
import kotlinx.serialization.json.JsonPrimitive
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
import java.util.UUID

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = android.app.Application::class)
class RecordEditDraftTest {
    @get:Rule val temp = TemporaryFolder()
    private val context get() = ApplicationProvider.getApplicationContext<Context>()
    private val now = 1_800_000_000_000L
    private fun withRepository(block: (ArchiveRepository, MediaImportService, File) -> Unit) {
        val db = Room.inMemoryDatabaseBuilder(context, ArchiveDatabase::class.java).allowMainThreadQueries().build()
        try {
            val repo = ArchiveRepository(db)
            val root = temp.newFolder()
            val importer = MediaImporter(root, PreviewEncoder { file, _ -> ("preview:" + file.readText()).toByteArray() },
                { _, _ -> false }, { _, _ -> CaptureTime.unknown() })
            block(repo, MediaImportService(repo, "test", importer) { now + 1000 }, root)
        } finally { db.close() }
    }
    private fun original(repo: ArchiveRepository): ArchiveRecord {
        val draft = repo.createDraft("test", now)
        repo.updateDraft(draft.record.id, "test", now) { it.copy(note = "original words") }
        return repo.commitDraft(draft.record.id)
    }
    private fun request(bytes: String) = ImportRequest("photo.jpg", "image/jpeg", false, false,
        { ByteArrayInputStream(bytes.toByteArray()) }, null, origin = ImportOrigin.Camera)

    @Test fun isolatedEditorReusesDraftAndCommitsBackToOriginalDespiteOriginalSaveReceipt() = withRepository { repo, service, _ ->
        val original = original(repo) // The original already owns a draft_commits receipt.
        val editing = repo.createEditDraft(original.id)
        assertNotEquals(original.id, editing.record.id)
        assertEquals(original.id, editing.originalRecordId)
        assertEquals(editing, repo.createEditDraft(original.id))
        repo.updateDraft(editing.record.id, "test", now + 100) { it.copy(note = "edited words") }
        service.importToDraft(editing.record.id, listOf(request("new attachment")))
        assertEquals(original, repo.loadSnapshot().records.single())
        val saved = repo.commitDraft(editing.record.id)
        assertEquals(original.id, saved.id)
        assertEquals("edited words", saved.note.value.jsonPrimitive.content)
        assertEquals(original.createdAt, saved.createdAt)
        assertEquals(original.occurredAt, saved.occurredAt)
        assertEquals(1, jsonStringList(saved.assetIds.value).size)
        assertEquals(saved, repo.commitDraft(editing.record.id))
        assertEquals(1, repo.loadSnapshot().records.size)
        assertNull(repo.loadDraft(editing.record.id))
    }

    @Test fun discardEditorRetainsOriginalContentAndSharedMediaOnly() = withRepository { repo, service, root ->
        val draft = repo.createDraft("test", now)
        service.importToDraft(draft.record.id, listOf(request("existing attachment")))
        val original = repo.commitDraft(draft.record.id)
        val initial = repo.loadSnapshot()
        val editing = repo.createEditDraft(original.id)
        repo.updateDraft(editing.record.id, "test", now + 1) { it.copy(note = "do not save") }
        service.importToDraft(editing.record.id, listOf(request("discarded attachment")))
        service.discardDraft(editing.record.id)
        assertEquals(initial, repo.loadSnapshot())
        assertTrue(initial.resources.all { File(root, it.objectKey).exists() })
        assertEquals(initial.resources.size, root.walkTopDown().count { it.isFile })
    }

    @Test fun staleBaselineCannotOverwriteConcurrentChangesAndKeepsRecoverableDraft() = withRepository { repo, _, _ ->
        val original = original(repo)
        val editing = repo.createEditDraft(original.id)
        repo.updateDraft(editing.record.id, "test", now + 1) { it.copy(note = "stale draft") }
        val current = repo.editRecord(original.id, "test", now + 2) { it.copy(note = "newer saved edit") }
        assertThrows(ArchiveValidationException::class.java) { repo.commitDraft(editing.record.id) }
        assertEquals(current, repo.loadSnapshot().records.single())
        assertNotNull(repo.loadDraft(editing.record.id))
    }

    @Test fun trashAndReadOnlyRemainProtectedEvenWhenAnEditDraftAlreadyExists() = withRepository { repo, _, _ ->
        val original = original(repo)
        val editing = repo.createEditDraft(original.id)
        val trashed = repo.trashRecord(original.id, "test", now + 1)
        assertThrows(ArchiveValidationException::class.java) { repo.commitDraft(editing.record.id) }
        assertThrows(ArchiveValidationException::class.java) { repo.createEditDraft(original.id) }
        assertEquals(trashed, repo.loadSnapshot().records.single())
        val restored = repo.restoreRecord(original.id, "test", now + 2)
        val readOnly = restored.copy(extensions = restored.extensions +
            ("readOnly" to FieldEnvelope(JsonPrimitive(true), restored.createdAt.edit)))
        repo.saveSnapshot(repo.loadSnapshot().copy(records = listOf(readOnly)))
        assertThrows(ArchiveValidationException::class.java) { repo.createEditDraft(original.id) }
        assertThrows(ArchiveValidationException::class.java) { repo.commitDraft(editing.record.id) }
    }

    @Test fun baselineSurvivesDatabaseReopenAndNewEditsUseNewReceipt() {
        val name = "edit-draft-${UUID.randomUUID()}.db"
        fun open() = Room.databaseBuilder(context, ArchiveDatabase::class.java, name).allowMainThreadQueries().build()
        var db = open()
        try {
            var repo = ArchiveRepository(db)
            val original = original(repo)
            val editing = repo.createEditDraft(original.id)
            repo.updateDraft(editing.record.id, "test", now + 1) { it.copy(note = "after restart") }
            db.close()
            db = open()
            repo = ArchiveRepository(db)
            assertEquals(original, repo.loadDraft(editing.record.id)!!.originalRecord)
            assertEquals(editing.record.id, repo.createEditDraft(original.id).record.id)
            val saved = repo.commitDraft(editing.record.id)
            assertEquals("after restart", saved.note.value.jsonPrimitive.content)
            val next = repo.createEditDraft(original.id)
            assertNotEquals(editing.record.id, next.record.id)
            repo.updateDraft(next.record.id, "test", now + 2) { it.copy(note = "second edit") }
            assertEquals("second edit", repo.commitDraft(next.record.id).note.value.jsonPrimitive.content)
            assertEquals(1, repo.loadSnapshot().records.size)
        } finally { db.close(); context.deleteDatabase(name) }
    }
}
