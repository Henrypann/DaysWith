package com.henrypann.jinbao365

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Read-only adapter. It never starts Room, creates keys, rewrites AtomicFiles, or uses the network. */
internal class LegacyUpgrade(
    private val files: File,
    private val noBackup: File,
    private val database: File,
    private val decrypt: (ByteArray) -> ByteArray = ::decryptLegacyCredentials,
) {
    constructor(context: Context) : this(context.filesDir, context.noBackupFilesDir,
        context.getDatabasePath("archive-v3.db"))

    private val media = linkedMapOf<String, Map<String, Any>>()
    private fun atomicPath(file: File): File? = File(file.path + ".bak").takeIf { it.exists() }
        ?: file.takeIf { it.exists() }
    private fun bytes(file: File, max: Int): ByteArray? = atomicPath(file)?.let {
        check(it.isFile && it.length() <= max)
        it.readBytes().also { value -> check(value.size <= max) }
    }
    private fun connectionBytes(): ByteArray? {
        val file = File(noBackup, "storage-connection.enc")
        val rollback = File(file.path + ".rollback")
        return if (atomicPath(rollback) != null) bytes(rollback, 16384)?.takeIf { it.isNotEmpty() }
        else bytes(file, 16384)
    }
    private fun connection(): JSONObject? {
        val encrypted = connectionBytes() ?: return null
        val plaintext = decrypt(encrypted)
        val record = try { JSONObject(plaintext.toString(Charsets.UTF_8)) } finally { plaintext.fill(0) }
        check(record.getInt("version") == 1)
        check(record.getString("bucket").matches(Regex("[a-z0-9][a-z0-9-]{1,48}-[0-9]{5,20}")))
        check(record.getString("region").matches(Regex("[a-z]{2}-[a-z][a-z0-9-]{1,40}")))
        val prefix = record.getString("prefix")
        check(prefix.length in 1..256 && prefix.endsWith('/') && !prefix.startsWith('/'))
        check(prefix.split('/').dropLast(1).all { it.matches(Regex("[A-Za-z0-9_-]+")) })
        // A disconnected configuration is preserved in the native source, not promoted to verified.
        if (record.getBoolean("verified")) {
            check(record.getString("secretID").matches(Regex("[A-Za-z0-9_-]{1,1024}")))
            check(record.getString("secretKey").matches(Regex("[A-Za-z0-9_+/=-]{1,1024}")))
        }
        return record
    }

    fun readCredentials(bucket: String, region: String): Map<String, String> {
        val c = checkNotNull(connection())
        check(c.getBoolean("verified") && c.getString("bucket") == bucket && c.getString("region") == region)
        return mapOf("secretID" to c.getString("secretID"), "secretKey" to c.getString("secretKey"))
    }

    fun prepare(testBuild: Boolean): Map<String, Any?>? {
        media.clear()
        val identityFile = File(noBackup, "parent-identity-v1")
        val writerFile = File(noBackup, "writer-device-id")
        val hasSource = database.exists() || atomicPath(identityFile) != null || writerFile.exists() ||
            atomicPath(File(noBackup, "storage-connection.enc")) != null ||
            atomicPath(File(noBackup, "storage-connection.enc.rollback")) != null
        if (!hasSource) return null
        val before = fingerprint()
        val identity = bytes(identityFile, 128)?.toString(Charsets.UTF_8)?.also { check(it == "dad" || it == "mom") }
        val deviceID = checkNotNull(bytes(writerFile, 128)).toString(Charsets.UTF_8).trim()
        check(UUID.fromString(deviceID).toString().equals(deviceID, ignoreCase = true))
        val connection = connection()
        val verified = connection?.getBoolean("verified") == true
        val archive = linkedMapOf<String, Any?>(
            "schemaVersion" to 2, "deviceID" to deviceID, "testBuild" to testBuild,
            "link" to if (verified) mapOf("verified" to mapOf("bucket" to connection.getString("bucket"),
                "region" to connection.getString("region"))) else mapOf("missing" to emptyMap<String, Any>()),
            "moments" to emptyList<Any>(), "anniversaries" to emptyList<Any>(),
            "remote" to emptyList<Any>(), "remoteAnniversaries" to emptyList<Any>(),
            "committedDrafts" to emptyMap<String, String>(),
        )
        if (identity != null) archive["identityFolder"] = identity
        if (database.exists()) {
            // Native Room uses TRUNCATE. A pending WAL/hot rollback needs native recovery, never recovery by this reader.
            check(!File(database.path + "-wal").let { it.exists() && it.length() > 0 })
            checkColdJournal(File(database.path + "-journal"))
            database.inputStream().use { input ->
                val header = ByteArray(20); check(input.read(header) == header.size)
                check(header[18] == 1.toByte() && header[19] == 1.toByte())
            }
            SQLiteDatabase.openDatabase(database.path, null,
                SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS,
                android.database.DatabaseErrorHandler { throw IllegalStateException("Legacy database is unreadable") }).use { db ->
                check(db.isReadOnly && db.version in 4..7)
                db.rawQuery("PRAGMA quick_check", null).use { check(it.moveToFirst() && it.getString(0) == "ok") }
                db.execSQL("BEGIN")
                try {
                    val records = rows(db, "records").map { rowRecord(it) }
                    val assets = rows(db, "assets").map { rowAsset(it) }.associateBy { it.getString("id") }
                    val resources = rows(db, "resources").associateBy { it.getString("id") }
                    // Pending work cannot be represented by the single Flutter composer. Keep the source intact and block.
                    if (db.version >= 6) check(rows(db, "pending_media_tasks").all {
                        it.getString("status") == "Cancelled" ||
                            it.getString("status") == "Ready" && it.getLong("completedItems") == it.getLong("totalItems")
                    })
                    if (db.version >= 7) check(rows(db, "pending_media_items").all {
                        it.getString("status") in setOf("Success", "Degraded", "Cancelled")
                    })
                    val drafts = rows(db, "drafts")
                    check(drafts.size <= 1)
                    if (records.isNotEmpty() || drafts.isNotEmpty()) check(identity != null)
                    val moments = records.map { moment(it, assets, resources, checkNotNull(identity)) }
                    archive["moments"] = moments
                    val commits = rows(db, "draft_commits").associate { it.getString("id") to it.getString("recordId") }
                    // Receipts may legitimately refer to permanently purged records; keep them for idempotence.
                    archive["committedDrafts"] = commits
                    if (db.version >= 5) archive["anniversaries"] = rows(db, "anniversaries")
                        .filter { it.getString("owner") == identity }.map { row ->
                            linkedMapOf<String, Any?>("id" to row.getString("id"), "owner" to row.getString("owner"),
                                "title" to row.getString("title"), "date" to row.getString("date"),
                                "updatedAt" to if (row.isNull("deletedAt")) 0L else row.getLong("deletedAt"),
                                "uploadEligibility" to "localOnly").apply {
                                if (!row.isNull("deletedAt")) put("deletedAt", row.getLong("deletedAt"))
                            }
                        }
                    drafts.singleOrNull()?.let { row ->
                        check(!commits.containsKey(row.getString("id")))
                        val payload = JSONObject(row.getString("payloadJson"))
                        val draftRecords = payload.getJSONArray("records").objects()
                        check(draftRecords.size == 1 && draftRecords[0].getString("id") == row.getString("id"))
                        val draftAssets = payload.getJSONArray("assets").objects().associateBy { it.getString("id") }
                        val draftResources = payload.getJSONArray("resources").objects().associateBy { it.getString("id") }
                        val record = draftRecords.single()
                        val result = moment(record, draftAssets, draftResources, checkNotNull(identity))
                        val draft = linkedMapOf<String, Any?>("id" to result["id"], "title" to result["title"],
                            "note" to result["note"], "occurredAt" to result["occurredAt"], "assets" to result["assets"],
                            "uploadEligibility" to "localOnly", "timeWasEdited" to true,
                            "hasImportedBatch" to true, "occurredAtIsEstimated" to
                                (value(record, "occurredAt") as? JSONObject)?.optBoolean("estimated", false))
                        if (!row.isNull("originalRecordJson")) {
                            val original = JSONObject(row.getString("originalRecordJson")).getJSONArray("records").objects().single()
                            val originalID = original.getString("id")
                            check(records.any { it.getString("id") == originalID })
                            draft["originalMomentID"] = originalID
                            draft["baselineRevision"] = revision(original)
                        }
                        archive["draft"] = draft
                    }
                } finally { db.execSQL("ROLLBACK") }
            }
        }
        check(before == fingerprint())
        return mapOf("archive" to archive, "mediaRoot" to files.canonicalPath,
            "mediaFiles" to media.values.toList(), "sourceFingerprint" to before,
            "credentialsRequired" to verified)
    }

    private fun rows(db: SQLiteDatabase, table: String): List<JSONObject> =
        db.rawQuery("SELECT * FROM `$table` ORDER BY rowid", null).use { cursor ->
            buildList {
                while (cursor.moveToNext()) add(JSONObject().apply {
                    cursor.columnNames.forEachIndexed { i, column ->
                        put(column, when (cursor.getType(i)) {
                            android.database.Cursor.FIELD_TYPE_NULL -> JSONObject.NULL
                            android.database.Cursor.FIELD_TYPE_INTEGER -> cursor.getLong(i)
                            else -> cursor.getString(i)
                        })
                    }
                })
            }
        }
    private fun rowRecord(row: JSONObject) = JSONObject().put("id", row.getString("id")).apply {
        listOf("title", "note", "occurredAt", "createdAt", "assetIds", "tombstone", "extensions").forEach { key ->
            val raw = row.getString(key + "Json")
            if (key != "title" || raw.trim() != "null")
                put(if (key == "assetIds") "assetIDs" else key, JSONObject(raw))
        }
    }
    private fun rowAsset(row: JSONObject) = JSONObject().put("id", row.getString("id"))
        .put("kind", row.getString("kind")).put("capturedAt", JSONObject(row.getString("capturedAtJson")))
        .put("resourceIDs", JSONArray(row.getString("resourceIdsJson")))
        .put("extensions", JSONObject(row.getString("extensionsJson")))
    private fun value(row: JSONObject, field: String): Any? = row.getJSONObject(field).get("value").takeUnless { it == JSONObject.NULL }
    private fun revision(record: JSONObject): Long = envelopes(record).maxOf { it.getJSONObject("edit").getLong("counter") }.coerceAtLeast(1)
    private fun envelopes(record: JSONObject): List<JSONObject> =
        listOf("title", "note", "occurredAt", "createdAt", "assetIDs", "tombstone").map { record.optJSONObject(it) }.filterNotNull() +
            (record.optJSONObject("extensions") ?: JSONObject()).let { ext -> ext.keys().asSequence().map { ext.getJSONObject(it) }.toList() }

    private fun moment(record: JSONObject, assets: Map<String, JSONObject>, resources: Map<String, JSONObject>, parent: String): Map<String, Any?> {
        val owner = record.optJSONObject("extensions")?.optJSONObject("parent")?.getString("value") ?: parent
        check(owner == "dad" || owner == "mom")
        val selected = (value(record, "assetIDs") as JSONArray).strings()
        check(selected.distinct().size == selected.size)
        return linkedMapOf<String, Any?>("id" to record.getString("id"),
            "title" to if (record.isNull("title")) "" else (value(record, "title") as String), "note" to (value(record, "note") as String),
            "occurredAt" to (value(record, "occurredAt") as JSONObject).let { if (it.optBoolean("timeUnknown")) 0L else it.getLong("utc") },
            "createdAt" to (value(record, "createdAt") as Number).toLong(),
            "updatedAt" to envelopes(record).maxOf { it.getJSONObject("edit").getLong("at") },
            "revision" to revision(record), "parent" to owner, "uploadEligibility" to "localOnly",
            "assets" to selected.map { asset(checkNotNull(assets[it]), resources) }).apply {
            (value(record, "tombstone") as? JSONObject)?.let { put("trashedAt", it.getLong("deletedAt")) }
        }
    }
    private fun asset(asset: JSONObject, resources: Map<String, JSONObject>): Map<String, Any?> {
        val capture = value(asset, "capturedAt") as JSONObject
        val provenance = asset.optJSONObject("extensions")?.optJSONObject("importProvenance")?.getString("value") ?: "unknown"
        val ids = asset.getJSONArray("resourceIDs").strings()
        check(ids.isNotEmpty() && ids.distinct().size == ids.size)
        return mapOf("id" to asset.getString("id"), "kind" to asset.getString("kind"),
            "capturedAt" to if (capture.optBoolean("timeUnknown")) 0L else capture.getLong("utc"),
            "provenance" to provenance,
            "captureMetadata" to mapOf("source" to "nativeAndroid", "isEstimated" to capture.optBoolean("estimated", false)),
            "resources" to ids.map { id -> resource(checkNotNull(resources[id]), asset.getString("id")) })
    }
    private fun resource(row: JSONObject, assetId: String): Map<String, Any?> {
        check((row.optString("assetID").takeIf { it.isNotEmpty() } ?: row.getString("assetId")) == assetId)
        val key = row.getString("objectKey")
        check(key.isNotEmpty() && !key.startsWith('/') && !key.contains('\\') && key.split('/').all { it != ".." && it != "." && it.isNotEmpty() })
        val root = File(files, "media").canonicalFile
        val source = File(root, key).canonicalFile
        check(source.path.startsWith(root.path + File.separator) &&
            source.path.startsWith(files.canonicalPath + File.separator) && source.isFile)
        val count = row.getLong("byteCount")
        val hash = row.getString("sha256")
        check(hash.matches(Regex("[a-f0-9]{64}")) && source.length() == count && sha256(source) == hash)
        val target = "legacy-media/$key"
        media[target] = mapOf("sourcePath" to source.path, "targetPath" to target, "sha256" to hash, "byteCount" to count)
        return mapOf("id" to row.getString("id"), "role" to row.getString("role"),
            "contentType" to row.getString("contentType"), "originalFilename" to row.getString("originalFilename"),
            "byteCount" to count, "sha256" to hash, "relativePath" to target)
    }
    private fun checkColdJournal(journal: File) {
        if (!journal.exists()) return
        check(journal.isFile)
        if (journal.length() == 0L) return
        // A completed SQLite transaction may retain a journal with a zeroed 28-byte header.
        // Read it without AtomicFile/recovery: never truncate, delete or replay native journals.
        journal.inputStream().use { input ->
            val header = ByteArray(28)
            check(input.read(header) == header.size && header.all { it == 0.toByte() })
        }
    }

    private fun fingerprint(): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val sources = listOf(database, File(database.path + "-wal"), File(database.path + "-shm"), File(database.path + "-journal")) +
            listOf("parent-identity-v1", "writer-device-id", "storage-connection.enc", "storage-connection.enc.rollback")
                .flatMap { listOf(File(noBackup, it), File(noBackup, "$it.bak")) }
        sources.forEach { file ->
            digest.update(file.name.toByteArray())
            digest.update((if (file.exists()) sha256(file) else "missing").toByteArray())
        }
        return digest.digest().hex()
    }
}

internal fun decryptLegacyCredentials(bytes: ByteArray): ByteArray {
    check(bytes.size >= 30 && bytes[0] == 1.toByte() && bytes[1] == 12.toByte())
    val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    val key = checkNotNull(store.getKey("jinbao365.storage.v1", null) as? SecretKey)
    return decryptLegacyCredentialsWithKey(bytes, key)
}
internal fun decryptLegacyCredentialsWithKey(bytes: ByteArray, key: SecretKey): ByteArray {
    check(bytes.size >= 30 && bytes[0] == 1.toByte() && bytes[1] == 12.toByte())
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(2, 14)))
    cipher.updateAAD("jinbao365.connection.v1".toByteArray())
    return cipher.doFinal(bytes, 14, bytes.size - 14)
}
private fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }
private fun JSONArray.strings() = (0 until length()).map { getString(it) }
private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
private fun sha256(file: File): String = MessageDigest.getInstance("SHA-256").let { digest ->
    file.inputStream().use { input -> val buffer = ByteArray(65536); while (true) {
        val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count)
    } }
    digest.digest().hex()
}
