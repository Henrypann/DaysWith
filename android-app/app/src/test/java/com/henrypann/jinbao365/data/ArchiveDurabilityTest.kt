package com.henrypann.jinbao365.data

import android.content.Context
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.test.core.app.ApplicationProvider
import com.henrypann.jinbao365.archive.ArchiveJson
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.media.CaptureTime
import com.henrypann.jinbao365.media.ImportRequest
import com.henrypann.jinbao365.media.MediaImporter
import com.henrypann.jinbao365.media.PreviewEncoder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.SQLiteMode
import java.io.ByteArrayInputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29, 31, 35])
@SQLiteMode(SQLiteMode.Mode.NATIVE)
class ArchiveDurabilityTest {
    @get:Rule val temp = TemporaryFolder()

    @Test
    fun completedImportsUseFullSynchronizationOnTheWriterAndSurviveReopen() = offMain {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val name = "durability-${UUID.randomUUID()}.db"
        val importer = importer(temp.newFolder())
        var expected = ArchiveSnapshot.empty()
        try {
            repeat(3) { generation ->
                val database = ArchiveDatabase.open(context, name)
                try {
                    assertDurableWriter(database)
                    val repository = ArchiveRepository(database)
                    assertEquals(ArchiveJson.canonical(expected), ArchiveJson.canonical(repository.loadSnapshot()))
                    if (generation < 2) {
                        val prepared = importer.import(request("original-$generation"), expected)
                        expected = prepared.saveToArchive(expected, "durable-test", 10L + generation, repository::saveSnapshot)
                        assertEquals(generation + 1, repository.loadSnapshot().records.size)
                    }
                    assertDurableWriter(database)
                } finally {
                    database.close()
                }
            }
        } finally {
            context.deleteDatabase(name)
        }
    }

    @Test
    fun existingCommittedWalRowsAndCursorAreRecoveredWithDurableSettings() = offMain {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val legacyName = "legacy-wal-${UUID.randomUUID()}.db"
        val upgradedName = "durable-upgrade-${UUID.randomUUID()}.db"
        val legacy = Room.databaseBuilder(context, ArchiveDatabase::class.java, legacyName)
            .setJournalMode(RoomDatabase.JournalMode.WRITE_AHEAD_LOGGING)
            .build()
        try {
            val repository = ArchiveRepository(legacy)
            repository.reconcileOwner("durable-test")
            val importer = importer(temp.newFolder())
            var expected = ArchiveSnapshot.empty()
            repeat(2) { generation ->
                val prepared = importer.import(request("legacy-original-$generation"), expected)
                expected = prepared.saveToArchive(expected, "durable-test", 10L + generation, repository::saveSnapshot)
            }
            legacy.runInTransaction {
                legacy.openHelper.writableDatabase.query("PRAGMA journal_mode").use { cursor ->
                    check(cursor.moveToFirst())
                    assertEquals("wal", cursor.getString(0))
                }
            }
            // Keep the legacy database open and idle: its committed rows are still in
            // WAL, rather than testing only a clean close that checkpoints them away.
            val oldFile = context.getDatabasePath(legacyName)
            val wal = File("${oldFile.path}-wal")
            assertTrue("fixture must contain committed WAL frames", wal.length() > 32)
            val newFile = context.getDatabasePath(upgradedName)
            oldFile.copyTo(newFile)
            wal.copyTo(File("${newFile.path}-wal"))
            val upgraded = ArchiveDatabase.open(context, upgradedName)
            try {
                val restored = ArchiveRepository(upgraded)
                assertDurableWriter(upgraded)
                assertEquals(ArchiveJson.canonical(expected), ArchiveJson.canonical(restored.loadSnapshot()))
                assertEquals(repository.localSyncState(), restored.localSyncState())
                assertEquals(2, restored.loadSnapshot().records.size)
                assertEquals(4, restored.loadSnapshot().resources.size)
            } finally {
                upgraded.close()
            }
        } finally {
            legacy.close()
            context.deleteDatabase(legacyName)
            context.deleteDatabase(upgradedName)
        }
    }

    private fun assertDurableWriter(database: ArchiveDatabase) {
        // A transaction pins queries to the connection that actually commits writes.
        database.runInTransaction {
            database.openHelper.writableDatabase.query("PRAGMA journal_mode").use { cursor ->
                check(cursor.moveToFirst())
                assertEquals("truncate", cursor.getString(0))
            }
            database.openHelper.writableDatabase.query("PRAGMA synchronous").use { cursor ->
                check(cursor.moveToFirst())
                assertEquals("write transaction must use FULL", 2, cursor.getInt(0))
            }
        }
    }

    private fun request(bytes: String) = ImportRequest("photo.jpg", "image/jpeg", true, false,
        { ByteArrayInputStream(bytes.toByteArray()) }, null)

    private fun importer(root: File) = MediaImporter(root,
        PreviewEncoder { _, _ -> "shared-preview".toByteArray() },
        { _, _ -> false }, { _, _ -> CaptureTime.unknown() })

    private fun offMain(block: () -> Unit) {
        val executor = Executors.newSingleThreadExecutor()
        try {
            executor.submit { block() }.get(30, TimeUnit.SECONDS)
        } finally {
            executor.shutdownNow()
        }
    }
}
