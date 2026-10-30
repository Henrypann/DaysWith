package com.henrypann.jinbao365.data

import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.test.core.app.ApplicationProvider
import com.henrypann.jinbao365.archive.ArchiveJson
import com.henrypann.jinbao365.archive.ArchiveMerge
import com.henrypann.jinbao365.archive.ArchiveProtocolException
import com.henrypann.jinbao365.archive.ArchiveValidationException
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ArchiveRepositoryTest {
    @Test
    fun snapshotRoundTripsThroughRoomWithCurrentRecordColumns() {
        val repository = repository()
        val columns = repository.columnNames("records") +
            repository.columnNames("assets") +
            repository.columnNames("resources") +
            repository.columnNames("snapshot_meta")
        assertTrue(columns.contains("mediaOverflow"))
        assertEquals(setOf("id", "titleJson", "noteJson", "occurredAtJson", "createdAtJson", "assetIdsJson",
            "tombstoneJson", "extensionsJson", "unknownFieldsJson", "mediaOverflow"),
            repository.columnNames("records").toSet())

        val fixture = Json.parseToJsonElement(fixtureFile("unknown-fields.json").readText()).jsonObject
        val expected = ArchiveJson.parseSnapshot(fixture.getValue("expected").jsonObject)
        repository.saveSnapshot(expected)
        val loaded = repository.loadSnapshot()
        assertEquals(ArchiveJson.canonical(expected), ArchiveJson.canonical(loaded))
        assertTrue(loaded.records.single().unknownFields.containsKey("futureScore"))
        assertTrue(loaded.extensions.containsKey("rootHint"))
    }

    @Test
    fun mergeResultWithThirtyOneMediaSavesAndAManualRecordDoesNot() {
        val repository = repository()
        val fixture = Json.parseToJsonElement(fixtureFile("media-overflow.json").readText()).jsonObject
        val base = ArchiveJson.parseSnapshot(fixture.getValue("base").jsonObject)
        val local = ArchiveJson.parseSnapshot(fixture.getValue("local").jsonObject)
        val remote = ArchiveJson.parseSnapshot(fixture.getValue("remote").jsonObject)
        val merged = ArchiveMerge.merge(base, local, remote)
        repository.saveSnapshot(merged)
        val loaded = repository.loadSnapshot()
        assertEquals(ArchiveJson.canonical(merged), ArchiveJson.canonical(loaded))
        assertEquals(true, loaded.records.single().mediaOverflow)
        try {
            repository.saveManualRecord(loaded.records.single())
            throw AssertionError("manual save accepted 31 media")
        } catch (error: ArchiveValidationException) {
            assertTrue(error.message!!.contains("30"))
        }
        assertEquals(ArchiveJson.canonical(merged), ArchiveJson.canonical(repository.loadSnapshot()))
    }

    @Test
    fun aDifferentOwnerClearsTheSyncCursorAndKeepsTheSnapshot() {
        val repository = repository()
        val fixture = Json.parseToJsonElement(fixtureFile("unknown-fields.json").readText()).jsonObject
        val expected = ArchiveJson.parseSnapshot(fixture.getValue("expected").jsonObject)
        repository.saveSnapshot(expected)
        repository.reconcileOwner("phone-a")
        val fresh = checkNotNull(repository.localSyncState())
        assertEquals("phone-a", fresh.ownerDeviceId)
        assertNull(fresh.verifiedThroughSequence)
        assertFalse(fresh.resyncFromStart)

        repository.saveLocalSyncState(
            LocalSyncState(
                ownerDeviceId = "phone-a",
                verifiedThroughSequence = 4,
                verifiedThroughHash = "abc",
                resyncFromStart = false,
            ),
        )
        repository.reconcileOwner("phone-a")
        val kept = checkNotNull(repository.localSyncState())
        assertEquals(4L, kept.verifiedThroughSequence)
        assertEquals("abc", kept.verifiedThroughHash)
        assertFalse(kept.resyncFromStart)

        repository.reconcileOwner("phone-b")
        val cleared = checkNotNull(repository.localSyncState())
        assertEquals("phone-b", cleared.ownerDeviceId)
        assertNull(cleared.verifiedThroughSequence)
        assertNull(cleared.verifiedThroughHash)
        assertTrue(cleared.resyncFromStart)
        assertEquals(ArchiveJson.canonical(expected), ArchiveJson.canonical(repository.loadSnapshot()))
    }

    @Test
    fun migrationFromVersion1CreatesSyncStateAndKeepsRows() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        context.deleteDatabase(ArchiveDatabase.NAME)
        val helper = FrameworkSQLiteOpenHelperFactory().create(
            SupportSQLiteOpenHelper.Configuration.builder(context)
                .name(ArchiveDatabase.NAME)
                .callback(object : SupportSQLiteOpenHelper.Callback(1) {
                    override fun onCreate(db: SupportSQLiteDatabase) {
                        for (statement in schemaV1Statements()) db.execSQL(statement)
                        db.execSQL(
                            "CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT)",
                        )
                        db.execSQL(
                            "INSERT OR REPLACE INTO room_master_table (id, identity_hash) VALUES(42, ?)",
                            arrayOf(schemaIdentity(1)),
                        )
                        val columns = schemaRecordTextColumns(1)
                        db.execSQL(
                            "INSERT INTO records (${columns.joinToString(",")}) VALUES (${columns.joinToString(",") { "?" }})",
                            columns.map { if (it == "id") "rec-old" else "{}" }.toTypedArray(),
                        )
                    }

                    override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
                })
                .build(),
        )
        helper.writableDatabase.close()

        val database = Room.databaseBuilder(context, ArchiveDatabase::class.java, ArchiveDatabase.NAME)
            .addMigrations(ArchiveDatabase.MIGRATION_1_2, ArchiveDatabase.MIGRATION_2_3, ArchiveDatabase.MIGRATION_3_4, ArchiveDatabase.MIGRATION_4_5, ArchiveDatabase.MIGRATION_5_6, ArchiveDatabase.MIGRATION_6_7)
            .allowMainThreadQueries()
            .build()
        val repository = ArchiveRepository(database)
        assertTrue(repository.columnNames("sync_state").contains("ownerDeviceId"))
        database.openHelper.readableDatabase.query("SELECT id FROM records").use { cursor ->
            assertTrue(cursor.moveToFirst())
            assertEquals("rec-old", cursor.getString(0))
        }
        database.openHelper.readableDatabase.query(
            "SELECT identity_hash FROM room_master_table WHERE id = 42",
        ).use { cursor ->
            assertTrue(cursor.moveToFirst())
            assertEquals(schemaIdentity(7), cursor.getString(0))
        }
        repository.reconcileOwner("phone-a")
        assertEquals("phone-a", repository.localSyncState()?.ownerDeviceId)
        database.close()
    }

    @Test
    fun takeoverPublishesOnlyAfterVerifiedRecordsAndReceiptAreVisibleInTransaction() {
        val repository = repository()
        val restored = sampleSnapshot()
        val before = repository.loadSnapshot()
        var publications = 0
        val result = repository.restoreForTakeover(restored, "new-phone", 7, "head-hash", before) {
            publications++
            assertEquals(restored, repository.loadSnapshot())
            assertEquals(LocalSyncState("new-phone", 7, "head-hash", false), repository.localSyncState())
            "published"
        }
        assertEquals("published", result)
        assertEquals(1, publications)
        assertEquals(restored, repository.loadSnapshot())
    }

    @Test
    fun takeoverPublicationFailureRollsBackRecordsAndReceipt() {
        val repository = repository()
        val before = sampleSnapshot()
        repository.saveSnapshot(before)
        repository.reconcileOwner("old-phone")
        val receipt = checkNotNull(repository.localSyncState()).copy(verifiedThroughSequence = 2, verifiedThroughHash = "old-hash")
        repository.saveLocalSyncState(receipt)
        val restored = before.copy(records = listOf(before.records.single().copy(id = "restored-record")))
        var attempted = false
        try {
            repository.restoreForTakeover(restored, "new-phone", 7, "head-hash", before) {
                attempted = true
                throw java.io.IOException("fake writer failure")
            }
            throw AssertionError("takeover accepted failed publication")
        } catch (_: java.io.IOException) {
            assertTrue(attempted)
        }
        assertEquals(before, repository.loadSnapshot())
        assertEquals(receipt, repository.localSyncState())
    }

    @Test
    fun takeoverRejectsConcurrentLocalEditsBeforePublishing() {
        val repository = repository()
        val expected = ArchiveSnapshot.empty()
        val edited = sampleSnapshot()
        repository.saveSnapshot(edited)
        repository.reconcileOwner("phone")
        val receipt = repository.localSyncState()
        var published = false
        try {
            repository.restoreForTakeover(ArchiveSnapshot.empty(), "phone", 7, "head-hash", expected) {
                published = true
            }
            throw AssertionError("takeover replaced newer local records")
        } catch (_: ArchiveValidationException) {
            assertFalse(published)
        }
        assertEquals(edited, repository.loadSnapshot())
        assertEquals(receipt, repository.localSyncState())
    }

    private fun sampleSnapshot() = ArchiveJson.parseSnapshot(
        Json.parseToJsonElement(fixtureFile("unknown-fields.json").readText()).jsonObject.getValue("expected").jsonObject)

    @Test
    fun recordsAreReadOnlyDuringResyncFromCommit1() {
        val repository = repository()
        val fixture = Json.parseToJsonElement(fixtureFile("unknown-fields.json").readText()).jsonObject
        val expected = ArchiveJson.parseSnapshot(fixture.getValue("expected").jsonObject)
        repository.saveSnapshot(expected)
        repository.saveLocalSyncState(
            LocalSyncState(
                ownerDeviceId = "phone-a",
                verifiedThroughSequence = 4,
                verifiedThroughHash = "abc",
                resyncFromStart = true,
            ),
        )
        try {
            repository.saveSnapshot(expected)
            throw AssertionError("snapshot write accepted during resync")
        } catch (error: ArchiveValidationException) {
            assertTrue(error.message!!.contains("read-only"))
        }
        try {
            repository.saveManualRecord(expected.records.single())
            throw AssertionError("manual edit accepted during resync")
        } catch (error: ArchiveValidationException) {
            assertTrue(error.message!!.contains("read-only"))
        }
        assertEquals(ArchiveJson.canonical(expected), ArchiveJson.canonical(repository.loadSnapshot()))

        val cursor = checkNotNull(repository.localSyncState())
        try {
            repository.saveLocalSyncState(cursor.copy(resyncFromStart = false))
            throw AssertionError("cursor write cleared resync")
        } catch (error: ArchiveValidationException) {
            assertTrue(error.message!!.contains("read-only"))
        }
        assertEquals(true, repository.localSyncState()?.resyncFromStart)

        val tipped = expected.copy(records = listOf(expected.records.single().copy(id = "rec-tip")))
        repository.replaceWithChainTip(tipped)
        assertEquals("rec-tip", repository.loadSnapshot().records.single().id)
        assertEquals(ArchiveJson.canonical(tipped), ArchiveJson.canonical(repository.loadSnapshot()))
        assertEquals(false, repository.localSyncState()?.resyncFromStart)
        assertEquals(4L, repository.localSyncState()?.verifiedThroughSequence)
        try {
            repository.replaceWithChainTip(expected)
            throw AssertionError("chain replacement accepted after resync finished")
        } catch (error: ArchiveValidationException) {
            assertTrue(error.message!!.contains("resync"))
        }
        assertEquals("rec-tip", repository.loadSnapshot().records.single().id)
    }

    @Test
    fun deviceIdFileIsCreatedInTheNoBackupDirectory() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val identity = com.henrypann.jinbao365.archive.DeviceIdentity.fromContext(context)
        val id = identity.getOrCreate()
        val file = File(context.noBackupFilesDir, com.henrypann.jinbao365.archive.DeviceIdentity.FILE_NAME)
        assertTrue(file.isFile)
        assertEquals(id, file.readText())
        assertFalse(File(context.filesDir, com.henrypann.jinbao365.archive.DeviceIdentity.FILE_NAME).exists())
        assertTrue(context.noBackupFilesDir.absolutePath.contains("no_backup"))
    }

    private fun schemaV1Statements(): List<String> {
        val root = Json.parseToJsonElement(schemaFile(1).readText()).jsonObject
        val entities = root.getValue("database").jsonObject.getValue("entities").jsonArray
        val statements = mutableListOf<String>()
        for (entity in entities) {
            val objectValue = entity.jsonObject
            val table = objectValue.getValue("tableName").jsonPrimitive.content
            statements += objectValue.getValue("createSql").jsonPrimitive.content
                .replace("\${TABLE_NAME}", table)
            val indices = objectValue["indices"]?.jsonArray ?: continue
            for (index in indices) {
                statements += index.jsonObject.getValue("createSql").jsonPrimitive.content
                    .replace("\${TABLE_NAME}", table)
            }
        }
        return statements
    }

    private fun schemaIdentity(version: Int) = Json.parseToJsonElement(schemaFile(version).readText()).jsonObject
        .getValue("database").jsonObject.getValue("identityHash").jsonPrimitive.content

    private fun schemaRecordTextColumns(version: Int): List<String> =
        Json.parseToJsonElement(schemaFile(version).readText()).jsonObject.getValue("database").jsonObject
            .getValue("entities").jsonArray.single { it.jsonObject.getValue("tableName").jsonPrimitive.content == "records" }
            .jsonObject.getValue("fields").jsonArray.filter { it.jsonObject.getValue("affinity").jsonPrimitive.content == "TEXT" }
            .map { it.jsonObject.getValue("columnName").jsonPrimitive.content }

    private fun schemaFile(version: Int): File {
        var directory = File(checkNotNull(System.getProperty("user.dir")))
        while (true) {
            val nested = File(
                directory,
                "android-app/app/schemas/com.henrypann.jinbao365.data.ArchiveDatabase/$version.json",
            )
            if (nested.isFile) return nested
            val local = File(directory, "app/schemas/com.henrypann.jinbao365.data.ArchiveDatabase/$version.json")
            if (local.isFile) return local
            directory = directory.parentFile ?: error("schema $version.json not found")
        }
    }

    private fun repository(): ArchiveRepository {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val database = Room.inMemoryDatabaseBuilder(context, ArchiveDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        return ArchiveRepository(database)
    }

    private fun fixtureFile(name: String): File {
        var directory = File(checkNotNull(System.getProperty("user.dir")))
        repeat(8) {
            val candidate = File(directory, "android-app/app/src/test/resources/archive/$name")
            if (candidate.isFile) return candidate
            directory = directory.parentFile ?: return@repeat
        }
        throw ArchiveProtocolException("missing fixture $name")
    }
}
