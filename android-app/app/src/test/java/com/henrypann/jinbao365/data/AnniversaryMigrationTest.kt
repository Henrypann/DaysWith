package com.henrypann.jinbao365.data

import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.test.core.app.ApplicationProvider
import com.henrypann.jinbao365.archive.ArchiveJson
import com.henrypann.jinbao365.media.CaptureTime
import com.henrypann.jinbao365.media.ImportOrigin
import com.henrypann.jinbao365.media.ImportRequest
import com.henrypann.jinbao365.media.MediaImporter
import com.henrypann.jinbao365.media.MediaImportService
import com.henrypann.jinbao365.media.PendingMediaCoordinator
import com.henrypann.jinbao365.media.PreviewEncoder
import java.io.ByteArrayInputStream
import java.util.concurrent.Executor
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.util.UUID

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AnniversaryMigrationTest {
    @Test fun everyHistoricalVersionPreservesAllRetainedRowsAndCreatesEmptyAnniversaries() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        for (version in 1..6) {
            val name = "anniversary-migration-${UUID.randomUUID()}.db"
            val retained = mutableMapOf<String, Map<String, String?>>()
            val helper = FrameworkSQLiteOpenHelperFactory().create(SupportSQLiteOpenHelper.Configuration.builder(context)
                .name(name).callback(object : SupportSQLiteOpenHelper.Callback(version) {
                    override fun onCreate(db: SupportSQLiteDatabase) {
                        val schema = schema(version)
                        for (raw in schema.getValue("entities").jsonArray) {
                            val entity = raw.jsonObject
                            val table = entity.getValue("tableName").jsonPrimitive.content
                            db.execSQL(entity.getValue("createSql").jsonPrimitive.content.replace("\${TABLE_NAME}", table))
                            entity["indices"]?.jsonArray?.forEach {
                                db.execSQL(it.jsonObject.getValue("createSql").jsonPrimitive.content.replace("\${TABLE_NAME}", table))
                            }
                            val fields = entity.getValue("fields").jsonArray.map { it.jsonObject }
                            val values = fields.associate { field ->
                                val column = field.getValue("columnName").jsonPrimitive.content
                                column to if (field.getValue("affinity").jsonPrimitive.content == "INTEGER") "1" else "$table-$column"
                            }
                            db.execSQL("INSERT INTO `$table` (${values.keys.joinToString(",") { "`$it`" }}) VALUES (${values.keys.joinToString(",") { "?" }})", values.values.toTypedArray())
                            if (table != "items") retained[table] = values
                        }
                    }
                    override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
                }).build())
            helper.writableDatabase
            helper.close()
            val database = Room.databaseBuilder(context, ArchiveDatabase::class.java, name)
                .addMigrations(ArchiveDatabase.MIGRATION_1_2, ArchiveDatabase.MIGRATION_2_3,
                    ArchiveDatabase.MIGRATION_3_4, ArchiveDatabase.MIGRATION_4_5, ArchiveDatabase.MIGRATION_5_6, ArchiveDatabase.MIGRATION_6_7)
                .allowMainThreadQueries().build()
            try {
                val db = database.openHelper.readableDatabase // Room also validates the complete schema.
                assertEquals(7, db.version)
                for ((table, expected) in retained) {
                    db.query("SELECT * FROM `$table`").use { cursor ->
                        assertTrue("v$version $table missing", cursor.moveToFirst())
                        cursor.columnNames.forEachIndexed { index, column ->
                            assertEquals("v$version $table.$column", expected[column], cursor.getString(index))
                        }
                        assertFalse(cursor.moveToNext())
                    }
                }
                if (version < 5) assertTrue(database.archiveDao().anniversaries().isEmpty())
                if (version < 6) assertTrue(database.archiveDao().pendingMediaTasks().isEmpty())
                assertTrue(database.archiveDao().pendingMediaItems("unknown").isEmpty())
            } finally { database.close(); context.deleteDatabase(name) }
        }
    }

    @Test fun version6TaskArraysExpandLazilyAndRetainDraftMediaWithoutReplayingReadyWork() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val name = "pending-media-v6-${UUID.randomUUID()}.db"
        val objectRoot = File(context.cacheDir, "pending-media-v6-${UUID.randomUUID()}").apply { mkdirs() }
        val fixtureStatuses = listOf("Ready", "Failed", "AwaitingCapture")
        val origins = mapOf("Ready" to ImportOrigin.Document, "Failed" to ImportOrigin.PhotoPicker,
            "AwaitingCapture" to ImportOrigin.Camera)
        val taskIds = fixtureStatuses.associateWith { UUID.randomUUID().toString() }
        val draftIds = fixtureStatuses.associateWith { UUID.randomUUID().toString() }
        val uris = fixtureStatuses.associateWith { "content://migration-fixture/${it.lowercase()}" }
        val expected = mutableMapOf<String, StoredDraft>()
        val draftRows = mutableMapOf<String, DraftEntity>()
        val seed = Room.inMemoryDatabaseBuilder(context, ArchiveDatabase::class.java).allowMainThreadQueries().build()
        try {
            val repository = ArchiveRepository(seed)
            val importer = MediaImporter(objectRoot, PreviewEncoder { file, _ -> ("preview:" + file.readText()).toByteArray() },
                { _, _ -> false }, { _, _ -> CaptureTime.unknown() })
            val service = MediaImportService(repository, "migration-test", importer) { 1_800_000_000_000L }
            fixtureStatuses.forEach { status ->
                val draftId = draftIds.getValue(status)
                repository.createDraft("migration-test", 1_800_000_000_000L, draftId)
                expected[status] = service.importToDraft(draftId, listOf(ImportRequest(
                    "$status.jpg", "image/jpeg", false, false,
                    { ByteArrayInputStream("original-$status".toByteArray()) }, null)))
                draftRows[status] = checkNotNull(seed.archiveDao().draft(draftId))
            }
        } finally { seed.close() }
        val helper = FrameworkSQLiteOpenHelperFactory().create(SupportSQLiteOpenHelper.Configuration.builder(context)
            .name(name).callback(object : SupportSQLiteOpenHelper.Callback(6) {
                override fun onCreate(db: SupportSQLiteDatabase) {
                    schema(6).getValue("entities").jsonArray.forEach { raw ->
                        val entity = raw.jsonObject
                        val table = entity.getValue("tableName").jsonPrimitive.content
                        db.execSQL(entity.getValue("createSql").jsonPrimitive.content.replace("\${TABLE_NAME}", table))
                        entity["indices"]?.jsonArray?.forEach {
                            db.execSQL(it.jsonObject.getValue("createSql").jsonPrimitive.content.replace("\${TABLE_NAME}", table))
                        }
                    }
                    fixtureStatuses.forEach { status ->
                        val draft = draftRows.getValue(status)
                        db.execSQL("INSERT INTO drafts (id, payloadJson, revision, originalRecordJson) VALUES (?, ?, ?, ?)",
                            arrayOf<Any?>(draft.id, draft.payloadJson, draft.revision, draft.originalRecordJson))
                        db.execSQL("INSERT INTO pending_media_tasks (id, draftId, origin, status, payloadJson, completedItems, totalItems, errorMessage, ownsDraft) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                            arrayOf<Any?>(taskIds.getValue(status), draft.id, origins.getValue(status).name, status,
                                JsonArray(listOf(JsonPrimitive(uris.getValue(status)))).toString(),
                                if (status == "Ready") 1 else 0, 1,
                                if (status == "Failed") "旧版失败提示" else null, 1))
                    }
                }
                override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
            }).build())
        helper.writableDatabase
        helper.close()
        val database = Room.databaseBuilder(context, ArchiveDatabase::class.java, name)
            .addMigrations(ArchiveDatabase.MIGRATION_6_7).allowMainThreadQueries().build()
        try {
            val repository = ArchiveRepository(database)
            assertEquals(7, database.openHelper.readableDatabase.version)
            // The SQL migration preserves the old journal; expansion happens on first repository access.
            assertTrue(taskIds.values.all { database.archiveDao().pendingMediaItems(it).isEmpty() })
            fixtureStatuses.forEach { status ->
                val taskId = taskIds.getValue(status)
                val before = checkNotNull(repository.pendingMediaTask(taskId))
                val item = repository.pendingMediaItems(taskId).single()
                assertEquals(taskId, item.taskId)
                assertEquals(0, item.position)
                assertEquals(uris.getValue(status), item.uri)
                assertEquals(origins.getValue(status).name, item.origin)
                assertEquals(when (status) { "Ready" -> "Success"; "Failed" -> "Failed"; else -> "Queued" }, item.status)
                assertNull(item.assetId) // Version 6 has an atomic batch receipt, never a guessed per-URI asset.
                assertEquals(if (status == "Failed") "旧版失败提示" else null, item.errorMessage)
                assertEquals(before, repository.pendingMediaTask(taskId))
                assertEquals(item, repository.pendingMediaItems(taskId).single()) // Idempotent lazy expansion.
                val retained = checkNotNull(repository.loadDraft(draftIds.getValue(status)))
                assertEquals(expected.getValue(status), retained)
                assertEquals(ArchiveJson.canonical(expected.getValue(status).snapshot()), ArchiveJson.canonical(retained.snapshot()))
                retained.resources.forEach { assertTrue(File(objectRoot, it.objectKey).isFile) }
            }
            val scheduled = mutableListOf<Runnable>()
            var sourceReads = 0
            val importer = MediaImporter(objectRoot, PreviewEncoder { _, _ -> "unused-preview".toByteArray() },
                { _, _ -> false }, { _, _ -> CaptureTime.unknown() })
            val coordinator = PendingMediaCoordinator(context, repository, "migration-test",
                MediaImportService(repository, "migration-test", importer), Executor { scheduled += it },
                requestFactory = { _, _ -> sourceReads++; error("Completed legacy work must never reopen a source") })
            coordinator.resumeInterrupted()
            assertTrue(scheduled.isEmpty())
            assertEquals(0, sourceReads)
            fixtureStatuses.forEach { status ->
                assertEquals(status, repository.pendingMediaTask(taskIds.getValue(status))!!.status)
                assertEquals(expected.getValue(status), repository.loadDraft(draftIds.getValue(status)))
            }
        } finally {
            database.close()
            context.deleteDatabase(name)
            objectRoot.deleteRecursively()
        }
    }

    private fun schema(version: Int): JsonObject {
        var directory = File(checkNotNull(System.getProperty("user.dir")))
        while (true) {
            for (prefix in listOf("app/schemas", "android-app/app/schemas")) {
                val file = File(directory, "$prefix/com.henrypann.jinbao365.data.ArchiveDatabase/$version.json")
                if (file.isFile) return Json.parseToJsonElement(file.readText()).jsonObject.getValue("database").jsonObject
            }
            directory = directory.parentFile ?: error("Historical schema missing")
        }
    }
}
