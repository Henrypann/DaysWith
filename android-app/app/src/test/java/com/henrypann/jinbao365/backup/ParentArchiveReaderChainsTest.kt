package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.data.Anniversary
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.storage.StorageConfiguration
import com.henrypann.jinbao365.storage.StorageCredentials
import java.io.File
import java.io.OutputStream
import java.time.LocalDate
import java.util.concurrent.CancellationException
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ParentArchiveReaderChainsTest {
    @get:Rule val temporary = TemporaryFolder()
    private val root = StorageConfiguration(bucket = "example-1234567890")
    private val credentials = StorageCredentials("fixture-id", "fixture-key")
    private val now = 1_700_000_000_000L
    private val mom = ParentIdentity.Mom.prefix
    private val data = linkedMapOf<String, ByteArray>()
    private val requested = mutableListOf<String>()
    private val stores = mutableListOf<MemoryCosStore>()
    private val downloads = mutableListOf<String>()
    private var corrupt = false
    private var afterDownload: (BackupCancellation) -> Unit = { }
    private var anniversaries = emptyList<Anniversary>()
    private val directory by lazy { temporary.newFolder("media") }
    private val reader by lazy {
        ParentArchiveReader(directory, { _, values, _ -> anniversaries = values }) { config, _, cancellation ->
            requested += config.prefix
            val memory = MemoryCosStore(config).apply { data.putAll(this@ParentArchiveReaderChainsTest.data); corruptDownload = corrupt }
            stores += memory
            object : CosObjectStore by memory {
                override fun download(key: String, output: OutputStream): CosDownload {
                    downloads += key
                    return memory.download(key, output).also { afterDownload(cancellation) }
                }
            }
        }
    }
    private fun uuid(number: Int) = "aabbccdd-0000-4000-8000-${number.toString(16).padStart(12, '0')}"
    private fun chain(number: Int) = mom + uuid(number) + "/"
    private fun moment(id: Int, note: String, updated: Long = now, revision: Long = 0, deleted: Long? = null) =
        V1Moment(uuid(id), note = note, occurredAt = now, createdAt = now, updatedAt = updated,
            revision = revision, trashedAt = deleted, assetIDs = emptyList())

    private fun photo(prefix: String, moment: V1Moment, content: String): V1Manifest {
        // All fixtures deliberately reuse the same wire media UUIDs in different chains.
        val resources = listOf("photo", "preview").mapIndexed { index, role ->
            val bytes = "$content-$role".toByteArray()
            val hash = V1Json.sha256(bytes)
            val key = V1Layout.objectKey(prefix, hash)
            data[key] = bytes
            V1Resource(uuid(102 + index), uuid(101), role, "image/jpeg", "$role.jpg", bytes.size.toLong(), hash, key)
        }
        return V1Manifest(moments = listOf(moment.copy(assetIDs = listOf(uuid(101)))),
            assets = listOf(V1Asset(uuid(101), "photo", now, resources.map { it.id })), resources = resources)
    }
    private fun publish(prefix: String, manifest: V1Manifest, created: Long = now) {
        val bytes = V1Json.encodeManifest(manifest)
        val hash = V1Json.sha256(bytes)
        val key = prefix + "snapshots/$hash.json"
        data[key] = bytes
        data[prefix + V1Json.commitRelativeKey(1)] = V1Json.encodeCommit(V1Commit(sequence = 1,
            parentHash = null, writerDeviceID = uuid(900), kind = "snapshot", manifestHash = hash,
            manifestKey = key, createdAt = created, requestID = uuid(901)))
    }
    private fun read() = reader.read(root, credentials, ParentIdentity.Dad)
    private fun assertNoWrites() = assertTrue(stores.all { it.writes.isEmpty() && it.initiations == 0 })
    private fun recordPhotoHash(snapshot: ArchiveSnapshot, note: String): String {
        val record = snapshot.records.single { it.note.value.jsonPrimitive.content == note }
        val assetId = record.assetIds.value.jsonArray.single().jsonPrimitive.content
        val asset = snapshot.assets.single { it.id == assetId }
        return snapshot.resources.single { it.id in asset.resourceIds && it.role == "photo" }.sha256
    }

    @Test fun deviceOnlyArchiveIsDiscoveredWithoutLegacyCommitsAndNeverReadsTestOrOwnParent() {
        publish(chain(1), photo(chain(1), moment(10, "latest mom photo"), "new"))
        publish(ParentIdentity.Dad.prefix, V1Manifest(moments = listOf(moment(11, "own parent"))))
        publish(V1Layout.TEST_ROOT + uuid(2) + "/", V1Manifest(moments = listOf(moment(12, "test"))))
        val snapshot = read()
        assertEquals(listOf("latest mom photo"), snapshot.records.map { it.note.value.jsonPrimitive.content })
        assertEquals(setOf(mom, chain(1)), requested.toSet())
        assertEquals(snapshot, reader.loadCached(ParentIdentity.Dad, root))
        assertNoWrites()
    }

    @Test fun newerRecordUsesItsOwnGraphAndIndependentChainMediaCannotAlias() {
        publish(mom, photo(mom, moment(10, "old"), "old"))
        publish(chain(1), photo(chain(1), moment(10, "new", now + 1), "new"))
        publish(chain(2), photo(chain(2), moment(11, "independent"), "independent"))
        val snapshot = read()
        assertEquals(2, snapshot.records.size)
        assertEquals(2, snapshot.assets.size)
        assertEquals(4, snapshot.resources.size)
        assertEquals(V1Json.sha256("new-photo".toByteArray()), recordPhotoHash(snapshot, "new"))
        assertEquals(V1Json.sha256("independent-photo".toByteArray()), recordPhotoHash(snapshot, "independent"))
        assertEquals(4, downloads.size) // Losing media graphs are not fetched.
        assertEquals(4, snapshot.resources.map { it.id }.distinct().size)
        assertEquals(snapshot, reader.loadCached(ParentIdentity.Dad, root))
        assertEquals(snapshot, read())
        assertEquals(4, downloads.size)
        assertNoWrites()
    }

    @Test fun missingOriginalsOfLosingCopiesDoNotBlockTheLatestPhoto() {
        val old = photo(mom, moment(10, "old"), "old")
        publish(mom, old)
        publish(chain(1), photo(chain(1), moment(10, "new", now + 1), "new"))
        old.resources.forEach { data.remove(it.objectKey) }
        val snapshot = read()
        assertEquals("new", snapshot.records.single().note.value.jsonPrimitive.content)
        assertEquals(2, downloads.size)
        assertEquals(snapshot, reader.loadCached(ParentIdentity.Dad, root))
        assertNoWrites()
    }

    @Test fun caseInsensitiveRecordMergeOrdersTimestampRevisionThenTombstoneAndStableChainTie() {
        val same = moment(10, "legacy", revision = 1)
        publish(mom, V1Manifest(moments = listOf(same)))
        publish(chain(1), V1Manifest(moments = listOf(same.copy(id = same.id.uppercase(), note = "revision", revision = 2))))
        assertEquals("revision", read().records.single().note.value.jsonPrimitive.content)
        publish(chain(2), V1Manifest(moments = listOf(same.copy(note = "deleted", revision = 2, trashedAt = now))))
        assertTrue(read().records.isEmpty())
        publish(chain(1), V1Manifest(moments = listOf(same.copy(note = "restored", updatedAt = now + 1))))
        assertEquals("restored", read().records.single().note.value.jsonPrimitive.content)
        publish(chain(2), V1Manifest(moments = listOf(same.copy(note = "tie winner", updatedAt = now + 1))))
        val snapshot = read()
        assertEquals("tie winner", snapshot.records.single().note.value.jsonPrimitive.content)
        assertEquals("remote:mom:record:${same.id.uppercase()}", snapshot.records.single().id)
        assertEquals(snapshot, reader.loadCached(ParentIdentity.Dad, root))
        assertNoWrites()
    }

    @Test fun anniversaryPublicationTimeAndEqualTimeDeletionSuppressLegacyCopy() {
        val item = Anniversary(uuid(10), ParentIdentity.Mom, "Birthday", LocalDate.of(2000, 1, 1))
        publish(mom, V1Manifest(version = 2, anniversaries = listOf(item)), now)
        publish(chain(1), V1Manifest(version = 2, anniversaries = listOf(item.copy(id = item.id.uppercase(), deletedAt = now))), now)
        read()
        assertNotNull(anniversaries.single().deletedAt)
        reader.loadCached(ParentIdentity.Dad, root)
        assertNotNull(anniversaries.single().deletedAt)
        publish(chain(2), V1Manifest(version = 2, anniversaries = listOf(item.copy(title = "Restored"))), now + 1)
        read()
        assertEquals("Restored", anniversaries.single().title)
        assertNull(anniversaries.single().deletedAt)
        assertNoWrites()
    }

    @Test fun malformedNewChainAndCorruptDownloadRetainCompleteCacheAndAnniversaries() {
        publish(mom, V1Manifest(moments = listOf(moment(10, "cached"))))
        val previous = read()
        val before = File(directory, "remote/${ParentArchiveReader.CACHE_V2}").readBytes()
        data[chain(1) + V1Json.commitRelativeKey(1)] = "invalid commit".toByteArray()
        assertThrows(V1ValidationException::class.java) { read() }
        assertArrayEquals(before, File(directory, "remote/${ParentArchiveReader.CACHE_V2}").readBytes())
        assertEquals(previous, reader.loadCached(ParentIdentity.Dad, root))
        publish(chain(1), photo(chain(1), moment(11, "corrupt photo"), "corrupt"))
        corrupt = true
        assertThrows(BackupException::class.java) { read() }
        assertEquals(previous, reader.loadCached(ParentIdentity.Dad, root))
        assertTrue(directory.walk().none { it.extension == "partial" })
        assertNoWrites()
    }

    @Test fun cancellationDuringMediaDownloadRetainsLastCompleteCache() {
        publish(mom, V1Manifest(moments = listOf(moment(10, "cached"))))
        val previous = read()
        publish(chain(1), photo(chain(1), moment(11, "new"), "new"))
        afterDownload = { it.cancel() }
        assertThrows(CancellationException::class.java) { read() }
        assertEquals(previous, reader.loadCached(ParentIdentity.Dad, root))
        assertTrue(directory.walk().none { it.extension == "partial" })
        assertNoWrites()
    }

    @Test fun legacySingleManifestCacheLoadsAndMigratesToMultiChainCache() {
        val manifest = V1Manifest(moments = listOf(moment(10, "legacy cache")))
        val old = File(directory, "remote/mom/snapshot.json").apply { parentFile!!.mkdirs() }
        old.writeText(buildJsonObject {
            put("bucket", root.bucket); put("region", root.region); put("prefix", mom); put("writer", uuid(900))
            put("manifest", V1Json.encodeManifest(manifest).toString(Charsets.UTF_8))
        }.toString())
        val previous = reader.loadCached(ParentIdentity.Dad, root)
        assertEquals("legacy cache", previous.records.single().note.value.jsonPrimitive.content)
        publish(mom, manifest)
        publish(chain(1), V1Manifest(moments = listOf(moment(11, "device cache"))))
        val current = read()
        assertEquals(2, current.records.size)
        assertEquals(current, reader.loadCached(ParentIdentity.Dad, root))
        assertTrue(reader.loadCached(ParentIdentity.Mom, root).records.isEmpty())
        assertTrue(reader.loadCached(ParentIdentity.Dad, root.copy(region = "ap-other")).records.isEmpty())
        assertNoWrites()
    }

    @Test fun cachedSourcesRejectCrossParentTestAndMalformedDevicePrefixes() {
        publish(chain(1), V1Manifest(moments = listOf(moment(10, "cached"))))
        read()
        val file = File(directory, "remote/${ParentArchiveReader.CACHE_V2}")
        val original = Json.parseToJsonElement(file.readText()).jsonObject
        val source = original.getValue("sources").jsonArray.single().jsonObject
        for (prefix in listOf(ParentIdentity.Dad.prefix, V1Layout.TEST_ROOT,
            chain(1).removeSuffix("/"), mom + "not-a-device/")) {
            val changed = JsonObject(original + ("sources" to JsonArray(listOf(JsonObject(source + ("prefix" to JsonPrimitive(prefix)))))))
            file.writeText(changed.toString())
            assertTrue("Rejected prefix $prefix", reader.loadCached(ParentIdentity.Dad, root).records.isEmpty())
        }
        assertNoWrites()
    }
}
