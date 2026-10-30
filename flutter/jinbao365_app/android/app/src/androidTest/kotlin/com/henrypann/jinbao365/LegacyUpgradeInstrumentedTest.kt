package com.henrypann.jinbao365

import android.database.sqlite.SQLiteDatabase
import android.graphics.Bitmap
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator

/** Synthetic fixture only. Refuses physical devices and any pre-existing native archive or key. */
@RunWith(AndroidJUnit4::class)
class LegacyUpgradeInstrumentedTest {
    @Test fun nativeKeystoreFixtureMigratesReadOnly() {
        check(Build.HARDWARE in setOf("ranchu", "goldfish")) { "Fixture runs only on a disposable emulator" }
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val retain = InstrumentationRegistry.getArguments().getString("seedForFlutter") == "true"
        val parent = InstrumentationRegistry.getArguments().getString("fixtureParent") ?: "dad"
        check(parent == "dad" || parent == "mom")
        val alias = "jinbao365.storage.v1"
        val keystore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        check(!keystore.containsAlias(alias)) { "Refusing to replace an existing key" }
        val dbFile = context.getDatabasePath("archive-v3.db")
        check(!dbFile.exists()) { "Refusing to overwrite an existing archive" }
        check(!File(context.noBackupFilesDir, "parent-identity-v1").exists())
        check(!File(context.noBackupFilesDir, "storage-connection.enc").exists())
        check(!File(context.filesDir, "Jinbao365/archive.json").exists())
        val files = context.filesDir
        val noBackup = context.noBackupFilesDir
        val deviceID = "21dfd4ae-0bd5-438f-a359-2d7e3eb23877"
        val now = 1793000000000L
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setRandomizedEncryptionRequired(true).build())
        val key = generator.generateKey()
        val plain = JSONObject().put("version", 1).put("bucket", "fixture-1234567890").put("region", "ap-shanghai")
            .put("prefix", "life/v1/").put("verified", true).put("secretID", "fixtureID").put("secretKey", "fixtureKey")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, key); updateAAD("jinbao365.connection.v1".toByteArray())
        }
        File(noBackup, "storage-connection.enc").writeBytes(byteArrayOf(1, 12) + cipher.iv + cipher.doFinal(plain.toString().toByteArray()))
        File(noBackup, "parent-identity-v1").writeText(parent)
        File(noBackup, "writer-device-id").writeText(deviceID)
        val png = java.io.ByteArrayOutputStream().also { output ->
            Bitmap.createBitmap(120, 160, Bitmap.Config.ARGB_8888).apply { eraseColor(0xff007b83.toInt()) }
                .compress(Bitmap.CompressFormat.PNG, 100, output)
        }.toByteArray()
        val sha = hash(png)
        val objectKey = "objects/${sha.take(2)}/$sha"
        val mediaFile = File(files, "media/$objectKey").apply { parentFile!!.mkdirs(); writeBytes(png) }
        fun envelope(value: Any?) = JSONObject().put("value", value ?: JSONObject.NULL)
            .put("edit", JSONObject().put("counter", 1).put("at", now).put("deviceID", deviceID))
        fun record(id: String, trash: Boolean = false, withMedia: Boolean = false) = JSONObject()
            .put("id", id).put("title", envelope("UPGRADE $id")).put("note", envelope("Synthetic local migration fixture"))
            .put("occurredAt", envelope(JSONObject().put("utc", now).put("zoneUnknown", true)))
            .put("createdAt", envelope(now)).put("assetIDs", envelope(JSONArray(if (withMedia) listOf("fixture-photo") else emptyList<String>())))
            .put("tombstone", envelope(if (trash) JSONObject().put("deletedAt", now) else null))
            .put("extensions", JSONObject().put("parent", envelope(parent)))
        dbFile.parentFile!!.mkdirs()
        SQLiteDatabase.openOrCreateDatabase(dbFile, null).use { db ->
            val schema = JSONObject(instrumentation.context.assets.open("native-schema-7.json").bufferedReader().readText())
                .getJSONObject("database").getJSONArray("entities")
            for (i in 0 until schema.length()) {
                val table = schema.getJSONObject(i)
                db.execSQL(table.getString("createSql").replace("\${TABLE_NAME}", table.getString("tableName")))
            }
            db.version = 7
            for (r in listOf(record("fixture-saved", withMedia = true), record("fixture-trash", trash = true))) {
                db.execSQL("INSERT INTO records VALUES (?,?,?,?,?,?,?,?,?,?)", arrayOf<Any?>(r.getString("id"),
                    r.getJSONObject("title").toString(), r.getJSONObject("note").toString(),
                    r.getJSONObject("occurredAt").toString(), r.getJSONObject("createdAt").toString(),
                    r.getJSONObject("assetIDs").toString(), r.getJSONObject("tombstone").toString(),
                    r.getJSONObject("extensions").toString(), "{}", 0))
            }
            db.execSQL("INSERT INTO assets VALUES (?,?,?,?,?,?)", arrayOf<Any?>("fixture-photo", "photo",
                envelope(JSONObject().put("utc", now).put("timeUnknown", false).put("zoneUnknown", true)).toString(),
                JSONArray(listOf("fixture-original", "fixture-preview")).toString(),
                JSONObject().put("importProvenance", envelope("camera")).toString(), "{}"))
            for (role in listOf("original", "preview")) db.execSQL("INSERT INTO resources VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                arrayOf<Any?>("fixture-$role", "fixture-photo", role, "image/png", "fixture.png", png.size, sha, objectKey, null, "{}", "{}"))
            db.execSQL("INSERT INTO anniversaries VALUES (?,?,?,?,?,?,?)", arrayOf<Any?>("fixture-anniversary", parent, "UPGRADE anniversary", "2000-02-29", null, null, null))
            db.execSQL("INSERT INTO anniversaries VALUES (?,?,?,?,?,?,?)", arrayOf<Any?>("fixture-deleted-anniversary", parent, "UPGRADE deleted anniversary", "2000-01-01", now, null, null))
            val draft = JSONObject().put("records", JSONArray().put(record("fixture-draft")))
                .put("assets", JSONArray()).put("resources", JSONArray())
            db.execSQL("INSERT INTO drafts VALUES (?,?,?,?)", arrayOf<Any?>("fixture-draft", draft.toString(), 1, null))
            db.execSQL("INSERT INTO draft_commits VALUES (?,?)", arrayOf<Any?>("already-saved", "fixture-saved"))
            db.execSQL("INSERT INTO pending_media_tasks VALUES (?,?,?,?,?,?,?,?,?)", arrayOf<Any?>("done", "already-saved", "Picker", "Ready", "{}", 1, 1, null, 1))
            db.execSQL("INSERT INTO pending_media_items VALUES (?,?,?,?,?,?,?,?,?,?)", arrayOf<Any?>("done-item", "done", 0, "content://fixture", "Picker", "Success", "fixture-photo", 1, "camera", null))
        }
        fun sourceHashes() = (noBackup.walkTopDown().filter { it.isFile }.toList() +
            dbFile.parentFile!!.listFiles()!!.filter { it.name.startsWith("archive-v3.db") } + mediaFile)
            .associate { it.path to hash(it.readBytes()) }
        val before = sourceHashes()
        val prepared = LegacyUpgrade(context).prepare(true)!!
        val archive = JSONObject(prepared["archive"] as Map<*, *>)
        assertEquals(parent, archive.getString("identityFolder"))
        assertEquals(deviceID, archive.getString("deviceID"))
        assertTrue(archive.getBoolean("testBuild"))
        assertEquals(2, archive.getJSONArray("moments").length())
        assertEquals(2, archive.getJSONArray("anniversaries").length())
        assertTrue(archive.has("draft"))
        assertFalse(JSONObject(prepared).toString().contains("fixtureKey"))
        val credentials = LegacyUpgrade(context).readCredentials("fixture-1234567890", "ap-shanghai")
        assertTrue(credentials["secretID"] == "fixtureID" && credentials["secretKey"] == "fixtureKey")
        assertEquals(prepared, LegacyUpgrade(context).prepare(true))
        assertEquals(before, sourceHashes())
        // Verify production decrypt rejects modified ciphertext without changing its saved bytes/key.
        val modified = File(noBackup, "storage-connection.enc").readBytes().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() }
        try { decryptLegacyCredentials(modified); fail("Tampered GCM must fail") } catch (_: java.security.GeneralSecurityException) { }
        assertEquals(before, sourceHashes())
        if (!retain) {
            // Cleanup is limited to this test's disposable emulator fixtures, never production code.
            dbFile.parentFile!!.listFiles()!!.filter { it.name.startsWith("archive-v3.db") }.forEach { it.delete() }
            listOf("parent-identity-v1", "writer-device-id", "storage-connection.enc").forEach { File(noBackup, it).delete() }
            mediaFile.delete(); keystore.deleteEntry(alias)
        }
    }
    private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}
