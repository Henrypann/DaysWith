package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.storage.StorageConfiguration
import com.henrypann.jinbao365.storage.StorageCredentials
import java.io.File
import java.io.OutputStream
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MultiDeviceReaderTest {
    @get:Rule val temporary = TemporaryFolder()
    private val root = StorageConfiguration(bucket = "example-1234567890")
    private val credentials = StorageCredentials("fixture-id", "fixture-key")
    private val data = linkedMapOf<String, ByteArray>()
    private val writes = mutableListOf<String>()
    private val now = 1_700_000_000_000L
    private fun uuid(n: Int) = "00000000-0000-4000-8000-${n.toString().padStart(12, '0')}"
    private val self = uuid(80)

    private inner class Shared(override val configuration: StorageConfiguration) : CosObjectStore {
        override fun list(prefix: String) = data.keys.filter { it.startsWith(prefix) }.sorted()
        override fun head(key: String) = data[key]?.let { CosObjectInfo(it.size.toLong(), V1Json.sha256(it)) }
        override fun get(key: String) = data[key]?.copyOf() ?: throw CosException(CosFailure.NotFound)
        override fun download(key: String, output: OutputStream): CosDownload {
            val bytes = get(key); output.write(bytes); return CosDownload(bytes.size.toLong(), V1Json.sha256(bytes))
        }
        override fun download(key: String, file: File): CosDownload = file.outputStream().use { download(key, it) }
        private fun no(): Nothing { throw AssertionError("reader must never write") }
        override fun put(key: String, bytes: ByteArray, contentType: String) { writes += key; no() }
        override fun putFile(key: String, file: File, contentType: String) = no()
        override fun initiateMultipart(key: String, contentType: String, sha256: String): String = no()
        override fun uploadPart(key: String, uploadId: String, partNumber: Int, file: File, offset: Long, length: Long): String = no()
        override fun listParts(key: String, uploadId: String): List<CosPart> = no()
        override fun completeMultipart(key: String, uploadId: String, parts: List<CosPart>) = no()
    }

    private fun publish(prefix: String, writer: String, momentId: Int, note: String, updatedAt: Long, withPhoto: Boolean = false, trashedAt: Long? = null) {
        val resources = if (!withPhoto) emptyList() else listOf("photo", "preview").mapIndexed { i, role ->
            val bytes = "orig-$momentId-$role".toByteArray()
            val hash = V1Json.sha256(bytes)
            val key = V1Layout.objectKey(prefix, hash)
            data[key] = bytes
            V1Resource(uuid(momentId * 10 + 3 + i), uuid(momentId * 10 + 2), role, "image/jpeg", "$role.jpg", bytes.size.toLong(), hash, key)
        }
        val manifest = V1Manifest(moments = listOf(V1Moment(uuid(momentId), note = note, occurredAt = now, createdAt = now,
            updatedAt = updatedAt, trashedAt = trashedAt, assetIDs = if (withPhoto) listOf(uuid(momentId * 10 + 2)) else emptyList())),
            assets = if (withPhoto) listOf(V1Asset(uuid(momentId * 10 + 2), "photo", now, resources.map { it.id })) else emptyList(),
            resources = resources)
        val bytes = V1Json.encodeManifest(manifest)
        val hash = V1Json.sha256(bytes)
        data[prefix + "snapshots/$hash.json"] = bytes
        val commit = V1Commit(sequence = 1, parentHash = null, writerDeviceID = writer, kind = "snapshot", manifestHash = hash,
            manifestKey = prefix + "snapshots/$hash.json", createdAt = updatedAt, requestID = uuid(99))
        data[prefix + V1Json.commitRelativeKey(1)] = V1Json.encodeCommit(commit)
    }

    @Test fun mergesLegacyAndDeviceChainsOfBothParentsExceptThisDevice() {
        val mom = ParentIdentity.Mom.prefix
        val dad = ParentIdentity.Dad.prefix
        publish(mom, uuid(70), 1, "旧版", now)                                   // legacy mom root
        publish("$mom${uuid(71)}/", uuid(71), 1, "新版", now + 5, withPhoto = true) // same moment, newer, X9 chain
        publish("$mom${uuid(72)}/", uuid(72), 2, "妈妈另一台", now)
        publish(dad, uuid(73), 3, "Redmi 旧数据", now)                            // legacy dad root by another writer
        publish("$dad${uuid(74)}/", uuid(74), 4, "爸爸另一台", now)
        publish("$dad$self/", self, 5, "本机", now)                              // own chain: already local
        val reader = ParentArchiveReader(temporary.newFolder("media")) { config, _, _ -> Shared(config) }
        val snapshot = reader.read(root, credentials, ParentIdentity.Dad, selfDeviceId = self)
        val notes = snapshot.records.associate { it.id to it.note.value.jsonPrimitive.content }
        assertEquals(mapOf(
            "remote:mom:record:${uuid(1)}" to "新版",
            "remote:mom:record:${uuid(2)}" to "妈妈另一台",
            "remote:dad:record:${uuid(3)}" to "Redmi 旧数据",
            "remote:dad:record:${uuid(4)}" to "爸爸另一台",
        ), notes)
        assertTrue(snapshot.resources.isNotEmpty())
        assertTrue(snapshot.resources.all { it.objectKey.startsWith("remote/mom/objects/") })
        assertTrue(writes.isEmpty())
        assertEquals(snapshot.records.toSet(), reader.loadCached(ParentIdentity.Dad, root).records.toSet())
    }

    @Test fun legacyRootWrittenByThisDeviceIsNotDuplicated() {
        publish(ParentIdentity.Dad.prefix, self, 6, "本机旧链", now)
        val reader = ParentArchiveReader(temporary.newFolder("media")) { config, _, _ -> Shared(config) }
        assertTrue(reader.read(root, credentials, ParentIdentity.Dad, selfDeviceId = self).records.isEmpty())
    }

    @Test fun newerDeletionInADeviceChainHidesTheLegacyCopyAndRestoreShowsItAgain() {
        val mom = ParentIdentity.Mom.prefix
        publish(mom, uuid(70), 1, "旧版", now)
        publish("$mom${uuid(71)}/", uuid(71), 1, "旧版", now + 5, trashedAt = now + 5)
        val reader = ParentArchiveReader(temporary.newFolder("media")) { config, _, _ -> Shared(config) }
        assertTrue(reader.read(root, credentials, ParentIdentity.Dad).records.isEmpty())
        assertTrue(reader.loadCached(ParentIdentity.Dad, root).records.isEmpty())
        // Restored later on the same phone: a newer live copy wins again.
        data.keys.filter { it.startsWith("$mom${uuid(71)}/") && "/commits/" in it }.forEach { data.remove(it) } // test double only
        publish("$mom${uuid(71)}/", uuid(71), 1, "恢复了", now + 9)
        assertEquals("恢复了", reader.read(root, credentials, ParentIdentity.Dad).records.single().note.value.jsonPrimitive.content)
    }
}
