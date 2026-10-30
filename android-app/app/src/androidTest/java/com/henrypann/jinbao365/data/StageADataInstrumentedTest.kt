package com.henrypann.jinbao365.data

import android.database.sqlite.SQLiteDatabase
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.henrypann.jinbao365.archive.ArchiveJson
import com.henrypann.jinbao365.archive.ArchiveValidationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

/** Native SQLite checks; every test owns a separate database, never the user's archive. */
@RunWith(AndroidJUnit4::class)
class StageADataInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val now = 1_790_000_000_000L

    @Test
    fun schema2UpgradePreservesSnapshotCursorAndSupportsDurableDrafts() {
        val name = "stage-a-migration-${UUID.randomUUID()}.db"
        val path = context.getDatabasePath(name)
        path.parentFile!!.mkdirs()
        SQLiteDatabase.openOrCreateDatabase(path, null).use { legacy ->
            asset("schema2-seeded.sql").lineSequence()
                .filter { it.isNotBlank() && !it.startsWith("--") }
                .forEach { legacy.execSQL(it) }
            legacy.version = 2
        }
        val expected = ArchiveJson.parseSnapshot(Json.parseToJsonElement(asset("schema2-expected.json")).jsonObject)
        try {
            withDatabase(name) { database ->
                val repository = ArchiveRepository(database)
                assertEquals(ArchiveJson.canonical(expected), ArchiveJson.canonical(repository.loadSnapshot()))
                assertEquals(LocalSyncState("stage-a-owner", 7, "stage-a-cursor", false), repository.localSyncState())
                repository.createDraft("stage-a-owner", now, id = "draft-after-upgrade")
                repository.updateDraft("draft-after-upgrade", "stage-a-owner", now + 1) {
                    it.copy(title = "Pending note", note = "Survives database reopen")
                }
                assertEquals(ArchiveJson.canonical(expected), ArchiveJson.canonical(repository.loadSnapshot()))
                assertDurable(database)
            }
            withDatabase(name) { database ->
                val repository = ArchiveRepository(database)
                assertEquals("Pending note", repository.loadDraft("draft-after-upgrade")!!.record.title!!.value.jsonPrimitive.content)
                assertEquals(ArchiveJson.canonical(expected), ArchiveJson.canonical(repository.loadSnapshot()))
                val saved = repository.commitDraft("draft-after-upgrade")
                assertEquals(saved, repository.commitDraft("draft-after-upgrade"))
                assertNull(repository.loadDraft("draft-after-upgrade"))
                assertEquals(expected.records.size + 1, repository.loadSnapshot().records.size)
            }
            withDatabase(name) { database ->
                val repository = ArchiveRepository(database)
                assertEquals("draft-after-upgrade", repository.commitDraft("draft-after-upgrade").id)
                assertEquals(expected.records.size + 1, repository.loadSnapshot().records.size)
                assertDurable(database)
            }
        } finally {
            context.deleteDatabase(name)
        }
    }

    @Test
    fun invalidSaveAndOwnerChangeKeepTheUncommittedDraft() {
        val name = "stage-a-readonly-${UUID.randomUUID()}.db"
        try {
            withDatabase(name) { database ->
                val repository = ArchiveRepository(database)
                repository.reconcileOwner("first-owner")
                val draft = repository.createDraft("first-owner", now)
                assertThrows(ArchiveValidationException::class.java) { repository.commitDraft(draft.record.id) }
                assertEquals(draft, repository.loadDraft(draft.record.id))
                repository.reconcileOwner("second-owner")
                assertThrows(ArchiveValidationException::class.java) {
                    repository.updateDraft(draft.record.id, "second-owner", now + 1) { it.copy(note = "Blocked") }
                }
                assertThrows(ArchiveValidationException::class.java) { repository.discardDraft(draft.record.id) }
                assertEquals(draft, repository.loadDraft(draft.record.id))
                assertTrue(repository.loadSnapshot().records.isEmpty())
            }
            withDatabase(name) { database ->
                val repository = ArchiveRepository(database)
                assertTrue(repository.localSyncState()!!.resyncFromStart)
                assertEquals(1, repository.loadDrafts().size)
                assertTrue(repository.loadSnapshot().records.isEmpty())
            }
        } finally {
            context.deleteDatabase(name)
        }
    }

    private fun asset(name: String) = instrumentation.context.assets.open("stage-a/$name").bufferedReader().use { it.readText() }

    private fun withDatabase(name: String, block: (ArchiveDatabase) -> Unit) {
        val database = ArchiveDatabase.open(context, name)
        try { block(database) } finally { database.close() }
    }

    private fun assertDurable(database: ArchiveDatabase) {
        database.openHelper.readableDatabase.query("PRAGMA journal_mode").use {
            assertTrue(it.moveToFirst())
            assertEquals("truncate", it.getString(0).lowercase())
        }
        database.openHelper.readableDatabase.query("PRAGMA synchronous").use {
            assertTrue(it.moveToFirst())
            assertEquals(2, it.getInt(0))
        }
    }
}
