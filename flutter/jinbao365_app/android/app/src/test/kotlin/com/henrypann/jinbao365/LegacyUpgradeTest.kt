package com.henrypann.jinbao365

import android.database.sqlite.SQLiteDatabase
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], manifest = Config.NONE)
class LegacyUpgradeTest {
    @get:Rule val temporary = TemporaryFolder()
    private lateinit var files: File
    private lateinit var noBackup: File
    private lateinit var dbFile: File
    private lateinit var key: SecretKey
    private val device = "48d81e51-e26c-4094-8d26-0db1788db13b"
    private val now = 1793000000000L
    private val parent = "mom"

    @Before fun setup() {
        files = temporary.newFolder("files")
        noBackup = temporary.newFolder("no_backup")
        dbFile = File(temporary.newFolder("databases"), "archive-v3.db")
        key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        File(noBackup, "writer-device-id").writeText(device)
        File(noBackup, "parent-identity-v1").writeText(parent)
        val schema = JSONObject(javaClass.getResourceAsStream("/native-schema-7.json")!!.bufferedReader().readText())
            .getJSONObject("database")
        SQLiteDatabase.openOrCreateDatabase(dbFile, null).use { db ->
            val tables = schema.getJSONArray("entities")
            for (i in 0 until tables.length()) {
                val table = tables.getJSONObject(i)
                db.execSQL(table.getString("createSql").replace("\${TABLE_NAME}", table.getString("tableName")))
            }
            db.version = 7
        }
        saveConnection()
    }
    private fun reader() = LegacyUpgrade(files, noBackup, dbFile) { decryptLegacyCredentialsWithKey(it, key) }
    private fun envelope(value: Any?) = JSONObject().put("value", value ?: JSONObject.NULL)
        .put("edit", JSONObject().put("counter", 3).put("at", now).put("deviceID", device))
    private fun record(id: String, assetIDs: List<String> = emptyList(), deleted: Boolean = false, owner: String = parent) =
        JSONObject().put("id", id).put("title", envelope("标题 $id")).put("note", envelope("正文\n换行"))
            .put("occurredAt", envelope(JSONObject().put("utc", now - 1000).put("zoneUnknown", true)))
            .put("createdAt", envelope(now - 2000)).put("assetIDs", envelope(JSONArray(assetIDs)))
            .put("tombstone", envelope(if (deleted) JSONObject().put("deletedAt", now) else null))
            .put("extensions", JSONObject().put("parent", envelope(owner)))
    private fun addRecord(record: JSONObject) {
        SQLiteDatabase.openDatabase(dbFile.path, null, 0).use { db ->
            db.execSQL("INSERT INTO records VALUES (?,?,?,?,?,?,?,?,?,?)", arrayOf<Any?>(record.getString("id"),
                record.getJSONObject("title").toString(), record.getJSONObject("note").toString(),
                record.getJSONObject("occurredAt").toString(), record.getJSONObject("createdAt").toString(),
                record.getJSONObject("assetIDs").toString(), record.getJSONObject("tombstone").toString(),
                record.getJSONObject("extensions").toString(), "{}", 0))
        }
    }
    private fun addMedia(assetID: String, video: Boolean = false): Pair<JSONObject, List<JSONObject>> {
        val resources = listOf("original", "preview").map { role ->
            val data = "$assetID/$role/content".toByteArray()
            val sha = hash(data)
            val path = "objects/${sha.take(2)}/$sha"
            File(files, "media/$path").apply { parentFile!!.mkdirs(); writeBytes(data) }
            JSONObject().put("id", "$assetID-$role").put("assetID", assetID).put("role", role)
                .put("contentType", if (video && role == "original") "video/mp4" else "image/jpeg")
                .put("originalFilename", if (video && role == "original") "视频.mp4" else "照片.jpg")
                .put("byteCount", data.size).put("sha256", sha).put("objectKey", path).put("extensions", JSONObject())
        }
        val asset = JSONObject().put("id", assetID).put("kind", if (video) "video" else "photo")
            .put("capturedAt", envelope(JSONObject().put("timeUnknown", false).put("utc", now - 1000).put("utcOffset", "+08:00")))
            .put("resourceIDs", JSONArray(resources.map { it.getString("id") }))
            .put("extensions", JSONObject().put("importProvenance", envelope("camera")))
        SQLiteDatabase.openDatabase(dbFile.path, null, 0).use { db ->
            db.execSQL("INSERT INTO assets VALUES (?,?,?,?,?,?)", arrayOf<Any?>(assetID, asset.getString("kind"),
                asset.getJSONObject("capturedAt").toString(), asset.getJSONArray("resourceIDs").toString(),
                asset.getJSONObject("extensions").toString(), "{}"))
            resources.forEach { r -> db.execSQL("INSERT INTO resources VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                arrayOf<Any?>(r.getString("id"), assetID, r.getString("role"), r.getString("contentType"),
                    r.getString("originalFilename"), r.getLong("byteCount"), r.getString("sha256"),
                    r.getString("objectKey"), null, "{}", "{}")) }
        }
        return asset to resources
    }
    private fun saveConnection(verified: Boolean = true) {
        val plain = JSONObject().put("version", 1).put("bucket", "fixture-1234567890").put("region", "ap-shanghai")
            .put("prefix", "life/v1/").put("verified", verified).put("secretID", "fixtureID").put("secretKey", "fixtureKey")
        File(noBackup, "storage-connection.enc").writeBytes(encrypt(plain.toString().toByteArray(), key))
    }
    private fun encrypt(data: ByteArray, secret: SecretKey): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.ENCRYPT_MODE, secret)
        c.updateAAD("jinbao365.connection.v1".toByteArray())
        return byteArrayOf(1, 12) + c.iv + c.doFinal(data)
    }
    private fun archive(result: Map<String, Any?>) = JSONObject(result["archive"] as Map<*, *>)
    private fun hashes() = temporary.root.walkTopDown().filter { it.isFile }.associate { it.relativeTo(temporary.root).path to hash(it.readBytes()) }
    private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun blocked(action: () -> Unit) {
        val before = hashes()
        try { action(); fail("Unsafe source must not be migrated") } catch (_: Exception) { }
        assertEquals(before, hashes())
    }

    @Test fun fullSchemaMigratesIdentityOrderedPhotoVideoTrashAndLocalOnlyWithoutWritingSource() {
        addMedia("photo"); addMedia("video", true)
        addRecord(record("rec-active", listOf("video", "photo")))
        addRecord(record("rec-trash", deleted = true))
        SQLiteDatabase.openDatabase(dbFile.path, null, 0).use { db ->
            db.execSQL("INSERT INTO anniversaries VALUES (?,?,?,?,?,?,?)", arrayOf<Any?>("ann", parent, "纪念", "2000-02-29", now, null, null))
            db.execSQL("INSERT INTO anniversaries VALUES (?,?,?,?,?,?,?)", arrayOf<Any?>("remote", "dad", "另一位", "2000-01-01", null, null, null))
            db.execSQL("INSERT INTO draft_commits VALUES (?,?)", arrayOf<Any?>("saved-draft", "rec-active"))
        }
        val before = hashes()
        val result = reader().prepare(true)!!
        val a = archive(result)
        assertEquals(2, a.getInt("schemaVersion")); assertEquals(device, a.getString("deviceID"))
        assertEquals(parent, a.getString("identityFolder")); assertTrue(a.getBoolean("testBuild"))
        val moments = a.getJSONArray("moments")
        assertEquals(2, moments.length())
        val first = moments.getJSONObject(0)
        assertEquals("正文\n换行", first.getString("note")); assertEquals(now - 1000, first.getLong("occurredAt"))
        assertEquals("localOnly", first.getString("uploadEligibility"))
        assertEquals("video", first.getJSONArray("assets").getJSONObject(0).getString("kind"))
        assertEquals("camera", first.getJSONArray("assets").getJSONObject(1).getString("provenance"))
        assertEquals(now, moments.getJSONObject(1).getLong("trashedAt"))
        assertEquals(1, a.getJSONArray("anniversaries").length())
        assertEquals(now, a.getJSONArray("anniversaries").getJSONObject(0).getLong("deletedAt"))
        assertEquals("rec-active", a.getJSONObject("committedDrafts").getString("saved-draft"))
        assertFalse(a.has("backupJob")); assertTrue(result["credentialsRequired"] as Boolean)
        assertEquals(4, (result["mediaFiles"] as List<*>).size)
        assertFalse(JSONObject(result).toString().contains("fixtureKey"))
        assertEquals(before, hashes())
        assertEquals(result, reader().prepare(true)) // Cold-reader idempotence; Dart commits only once.
        val secrets = reader().readCredentials("fixture-1234567890", "ap-shanghai")
        assertTrue(secrets["secretID"] == "fixtureID" && secrets["secretKey"] == "fixtureKey")
        assertEquals(before, hashes())
    }

    @Test fun optionalNullTitleAndUnknownCaptureRemainReadable() {
        addMedia("unknown")
        addRecord(record("untitled", listOf("unknown")))
        SQLiteDatabase.openDatabase(dbFile.path, null, 0).use { db ->
            db.execSQL("UPDATE records SET titleJson='null'")
            db.execSQL("UPDATE assets SET capturedAtJson=?", arrayOf<Any?>(envelope(JSONObject().put("timeUnknown", true)).toString()))
        }
        val m = archive(reader().prepare(true)!!).getJSONArray("moments").getJSONObject(0)
        assertEquals("", m.getString("title"))
        assertEquals(0L, m.getJSONArray("assets").getJSONObject(0).getLong("capturedAt"))
    }
    @Test fun completedTaskReceiptsAndPurgedCommitReceiptRemainSafe() {
        addMedia("finished"); addRecord(record("kept", listOf("finished")))
        SQLiteDatabase.openDatabase(dbFile.path, null, 0).use { db ->
            db.execSQL("INSERT INTO draft_commits VALUES (?,?)", arrayOf<Any?>("past", "purged"))
            db.execSQL("INSERT INTO pending_media_tasks VALUES (?,?,?,?,?,?,?,?,?)", arrayOf<Any?>("task", "past", "Picker", "Ready", "{}", 1, 1, null, 1))
            db.execSQL("INSERT INTO pending_media_items VALUES (?,?,?,?,?,?,?,?,?,?)", arrayOf<Any?>("item", "task", 0, "content://fixture", "Picker", "Success", "finished", 1, "camera", null))
        }
        val a = archive(reader().prepare(true)!!)
        assertEquals("purged", a.getJSONObject("committedDrafts").getString("past"))
        assertEquals(1, a.getJSONArray("moments").length())
    }
    @Test fun cold512ByteZeroJournalPreservesAllSourceBytes() {
        addRecord(record("cold-journal-record"))
        val journal = File(dbFile.path + "-journal")
        journal.writeBytes(ByteArray(512))
        val before = hashes()
        val first = reader().prepare(true)!!
        assertEquals(1, archive(first).getJSONArray("moments").length())
        assertEquals(first, reader().prepare(true))
        assertEquals(before, hashes())
        assertEquals(512L, journal.length())
    }
    @Test fun clearedJournalHeaderCanRetainOldPagePayloadWithoutRecovery() {
        addRecord(record("cleared-header-record"))
        val journal = File(dbFile.path + "-journal")
        journal.writeBytes(ByteArray(8192) { if (it < 28) 0 else 85.toByte() })
        val before = hashes()
        assertEquals(1, archive(reader().prepare(true)!!).getJSONArray("moments").length())
        assertEquals(before, hashes())
    }
    @Test fun hotJournalWithSQLiteMagicAndHeaderNeverReplaysOrChangesBytes() {
        val bytes = ByteArray(8192)
        val header = java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.BIG_ENDIAN)
        header.put(byteArrayOf(0xd9.toByte(), 0xd5.toByte(), 0x05, 0xf9.toByte(), 0x20, 0xa1.toByte(), 0x63, 0xd7.toByte()))
        header.putInt(1) // Page count.
        header.putInt(12345) // Random checksum nonce.
        header.putInt(1) // Initial database size in pages.
        header.putInt(512) // Sector size.
        header.putInt(4096) // Page size.
        File(dbFile.path + "-journal").writeBytes(bytes)
        blocked { reader().prepare(true) }
    }
    @Test fun hotJournalAndWalAreNeverRecoveredByMigrationReader() {
        val journal = File(dbFile.path + "-journal")
        journal.writeText("pending native transaction")
        blocked { reader().prepare(true) }
        journal.delete()
        File(dbFile.path + "-wal").writeText("pending WAL transaction")
        blocked { reader().prepare(true) }
    }

    @Test fun dadIdentityAndRecordOwnerPreserved() {
        File(noBackup, "parent-identity-v1").writeText("dad")
        addRecord(record("dad-record", owner = "dad"))
        val a = archive(reader().prepare(true)!!)
        assertEquals("dad", a.getString("identityFolder"))
        assertEquals("dad", a.getJSONArray("moments").getJSONObject(0).getString("parent"))
    }
    @Test fun singleDraftRetainsAllMediaAndEditBaseline() {
        val (asset, resources) = addMedia("draft-photo")
        val original = record("original"); addRecord(original)
        val draft = record("draft", listOf("draft-photo"))
        val payload = JSONObject().put("records", JSONArray().put(draft)).put("assets", JSONArray().put(asset))
            .put("resources", JSONArray(resources))
        val baseline = JSONObject().put("records", JSONArray().put(original))
        SQLiteDatabase.openDatabase(dbFile.path, null, 0).use { db ->
            db.execSQL("INSERT INTO drafts VALUES (?,?,?,?)", arrayOf<Any?>("draft", payload.toString(), 1, baseline.toString()))
        }
        val d = archive(reader().prepare(true)!!).getJSONObject("draft")
        assertEquals("draft", d.getString("id")); assertEquals("original", d.getString("originalMomentID"))
        assertEquals(3, d.getInt("baselineRevision")); assertEquals(1, d.getJSONArray("assets").length())
        assertEquals("localOnly", d.getString("uploadEligibility"))
    }
    @Test fun multipleDraftsFailClosed() {
        SQLiteDatabase.openDatabase(dbFile.path, null, 0).use { db ->
            listOf("a", "b").forEach { db.execSQL("INSERT INTO drafts VALUES (?,?,?,?)", arrayOf<Any?>(it, "{}", 1, null)) }
        }
        blocked { reader().prepare(true) }
    }
    @Test fun pendingMediaFailsClosed() {
        SQLiteDatabase.openDatabase(dbFile.path, null, 0).use { db ->
            db.execSQL("INSERT INTO pending_media_tasks VALUES (?,?,?,?,?,?,?,?,?)", arrayOf<Any?>("task", "draft", "Camera", "AwaitingCapture", "{}", 0, 1, null, 1))
        }
        blocked { reader().prepare(true) }
    }
    @Test fun tamperedMediaAndPathTraversalFailClosed() {
        val (_, resources) = addMedia("broken"); addRecord(record("rec", listOf("broken")))
        File(files, "media/" + resources[0].getString("objectKey")).appendText("tamper")
        blocked { reader().prepare(true) }
        SQLiteDatabase.openDatabase(dbFile.path, null, 0).use { db ->
            db.execSQL("UPDATE resources SET objectKey='../outside' WHERE role='original'")
        }
        blocked { reader().prepare(true) }
    }
    @Test fun ciphertextTamperingWrongKeyAndWrongConnectionFailClosed() {
        blocked { reader().readCredentials("other-1234567890", "ap-shanghai") }
        val wrong = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        blocked { LegacyUpgrade(files, noBackup, dbFile) { decryptLegacyCredentialsWithKey(it, wrong) }.prepare(true) }
        val enc = File(noBackup, "storage-connection.enc")
        enc.writeBytes(enc.readBytes().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() })
        blocked { reader().prepare(true) }
    }
    @Test fun missingKeystoreKeyNeverCreatesReplacement() {
        blocked { LegacyUpgrade(files, noBackup, dbFile) { error("key unavailable") }.prepare(true) }
    }
    @Test fun rollbackAndBakReadPriorityDoesNotRenameOrEraseSources() {
        val enc = File(noBackup, "storage-connection.enc")
        File(enc.path + ".rollback.bak").writeBytes(enc.readBytes())
        enc.writeText("invalid newer ciphertext")
        File(enc.path + ".rollback").writeText("invalid newer rollback")
        File(noBackup, "parent-identity-v1.bak").writeText("dad")
        val before = hashes()
        val result = reader().prepare(true)!!
        assertEquals("dad", archive(result).getString("identityFolder"))
        assertTrue(result["credentialsRequired"] as Boolean)
        assertEquals(before, hashes())
    }
    @Test fun emptyRollbackIsMissingConnectionNotNewUncommittedBinding() {
        File(noBackup, "storage-connection.enc.rollback").writeBytes(byteArrayOf())
        val result = reader().prepare(true)!!
        assertFalse(result["credentialsRequired"] as Boolean)
        assertTrue(archive(result).getJSONObject("link").has("missing"))
    }
    @Test fun disconnectedIsNotPromotedAndCorruptDatabaseBlocks() {
        saveConnection(false)
        assertFalse(reader().prepare(true)!!["credentialsRequired"] as Boolean)
        dbFile.writeText("corrupt database")
        blocked { reader().prepare(true) }
    }
    @Test fun freshInstallReturnsNullAndMissingWriterBlocksExistingSource() {
        val blank = temporary.newFolder("empty")
        assertNull(LegacyUpgrade(blank, blank, File(blank, "archive-v3.db")).prepare(true))
        File(noBackup, "writer-device-id").delete()
        blocked { reader().prepare(true) }
    }
}
