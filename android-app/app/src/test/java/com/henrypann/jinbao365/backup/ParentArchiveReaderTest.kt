package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.archive.ImportProvenance
import com.henrypann.jinbao365.archive.importProvenance
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.storage.StorageConfiguration
import com.henrypann.jinbao365.storage.StorageCredentials
import java.io.File
import java.util.concurrent.CancellationException
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ParentArchiveReaderTest {
    @get:Rule val temporary = TemporaryFolder()
    private val root = StorageConfiguration(bucket = "example-1234567890")
    private val config = root.copy(prefix = ParentIdentity.Mom.prefix)
    private val credentials = StorageCredentials("fixture-id", "fixture-key")
    private val remote = MemoryCosStore(config)
    private val mediaRoot by lazy { temporary.newFolder("media") }
    private val reader by lazy { ParentArchiveReader(mediaRoot) { requested, _, _ ->
        assertEquals(config, requested)
        remote
    } }
    private val now = 1_700_000_000_000L
    private fun uuid(number: Int) = "00000000-0000-4000-8000-${number.toString().padStart(12, '0')}"

    private fun manifest(capture: Long = now, textOnly: Boolean = false): V1Manifest {
        val resources = if (textOnly) emptyList() else listOf("photo", "preview").mapIndexed { index, role ->
            val bytes = "original-$role".toByteArray()
            val hash = V1Json.sha256(bytes)
            val key = config.prefix + "objects/${hash.take(2)}/$hash"
            remote.data[key] = bytes
            V1Resource(uuid(index + 3), uuid(2), role, "image/jpeg", "$role.jpg", bytes.size.toLong(), hash, key)
        }
        return V1Manifest(moments = listOf(V1Moment(uuid(1), note = "今天一起散步", occurredAt = now,
            createdAt = now, updatedAt = now, assetIDs = if (textOnly) emptyList() else listOf(uuid(2)))),
            assets = if (textOnly) emptyList() else listOf(V1Asset(uuid(2), "photo", capture, resources.map { it.id })),
            resources = resources)
    }

    private fun publish(manifest: V1Manifest, sequence: Long = 1) {
        val bytes = V1Json.encodeManifest(manifest)
        val hash = V1Json.sha256(bytes)
        val key = config.prefix + "snapshots/$hash.json"
        remote.data[key] = bytes
        val previous = if (sequence > 1) remote.data.getValue(config.prefix + V1Json.commitRelativeKey(sequence - 1)) else null
        val commit = V1Commit(sequence = sequence, parentHash = previous?.let(V1Json::sha256), writerDeviceID = uuid(90),
            kind = "snapshot", manifestHash = hash, manifestKey = key, createdAt = now, requestID = uuid(91))
        remote.data[config.prefix + V1Json.commitRelativeKey(sequence)] = V1Json.encodeCommit(commit)
    }

    @Test fun readsOtherParentOnlyAndProjectsReadOnlyNamespacedRecordsWithVerifiedLocalMedia() {
        publish(manifest())
        val snapshot = reader.read(root, credentials, ParentIdentity.Dad)
        assertEquals("remote:mom:record:${uuid(1)}", snapshot.records.single().id)
        assertEquals("mom", snapshot.records.single().extensions.getValue("parent").value.jsonPrimitive.content)
        assertTrue(snapshot.records.single().extensions.getValue("readOnly").value.jsonPrimitive.boolean)
        snapshot.resources.forEach { resource ->
            assertTrue(resource.objectKey.startsWith("remote/mom/objects/"))
            assertEquals(resource.sha256, V1Json.sha256(File(mediaRoot, resource.objectKey).readBytes()))
        }
        assertEquals(2, remote.downloadCalls)
        assertTrue(remote.writes.isEmpty())
        assertEquals(snapshot, reader.loadCached(ParentIdentity.Dad, root))
        reader.read(root, credentials, ParentIdentity.Dad)
        assertEquals(2, remote.downloadCalls) // Verified originals are reused, never downloaded twice.
        assertTrue(reader.loadCached(ParentIdentity.Mom, root).records.isEmpty())
        assertTrue(reader.loadCached(ParentIdentity.Dad, root.copy(bucket = "other-1234567890")).records.isEmpty())
    }

    @Test fun knownProvenanceSurvivesReadOnlyProjectionAndOfflineCacheWithoutMediaChanges() {
        for ((index, source) in ImportProvenance.entries.filter { it != ImportProvenance.Unknown }.withIndex()) {
            val base = manifest().copy(version = 2)
            publish(base.copy(assets = base.assets.map { it.copy(importProvenance = source.wireValue) }), index + 1L)
            val projected = reader.read(root, credentials, ParentIdentity.Dad)
            val asset = projected.assets.single()
            assertEquals(source, asset.importProvenance)
            assertEquals(asset.capturedAt.edit, asset.extensions.getValue(ImportProvenance.EXTENSION_KEY).edit)
            assertEquals(projected, reader.loadCached(ParentIdentity.Dad, root))
            assertEquals(base.resources.map { it.sha256 }.toSet(), projected.resources.map { it.sha256 }.toSet())
            assertTrue(remote.writes.isEmpty())
        }
        assertEquals(2, remote.downloadCalls)
    }

    @Test fun captureReadUsesTheFixedFloorAndAcceptsFutureDates() {
        for (capture in listOf(0L, ParentArchiveReader.CAPTURE_FLOOR_MILLIS - 1,
            ParentArchiveReader.CAPTURE_FLOOR_MILLIS, now + 100 * BackupEngine.DAY_MILLIS)) {
            publish(manifest(capture))
            val value = reader.read(root, credentials, ParentIdentity.Dad).assets.single().capturedAt.value.jsonObject
            assertEquals(capture < ParentArchiveReader.CAPTURE_FLOOR_MILLIS, value.getValue("timeUnknown").jsonPrimitive.boolean)
            if (capture >= ParentArchiveReader.CAPTURE_FLOOR_MILLIS) {
                assertEquals(capture, value.getValue("utc").jsonPrimitive.long)
                assertTrue(value.getValue("zoneUnknown").jsonPrimitive.boolean)
                assertNull(value["timeZone"])
            }
        }
    }

    @Test fun corruptDownloadCannotReplaceTheLastCompleteSnapshot() {
        publish(manifest(textOnly = true))
        val previous = reader.read(root, credentials, ParentIdentity.Dad)
        publish(manifest(), 2)
        remote.corruptDownload = true
        val failure = assertThrows(BackupException::class.java) { reader.read(root, credentials, ParentIdentity.Dad) }
        assertEquals(BackupFailure.ArchivedFile, failure.failure)
        assertEquals(previous, reader.loadCached(ParentIdentity.Dad, root))
        assertTrue(mediaRoot.walk().none { it.extension == "partial" })
        assertTrue(remote.writes.isEmpty())
    }

    @Test fun invalidManifestHashNeverPublishesLocalRecords() {
        publish(manifest())
        val commit = V1Json.decodeCommit(remote.data.getValue(config.prefix + V1Json.commitRelativeKey(1)))
        remote.data[commit.manifestKey] = V1Json.encodeManifest(V1Manifest())
        assertThrows(V1ValidationException::class.java) { reader.read(root, credentials, ParentIdentity.Dad) }
        assertTrue(reader.loadCached(ParentIdentity.Dad, root).records.isEmpty())
        assertEquals(0, remote.downloadCalls)
        assertTrue(remote.writes.isEmpty())
    }

    @Test fun backgroundCancelsReadWithoutDownloadsOrPublishingCache() {
        publish(manifest())
        assertThrows(CancellationException::class.java) {
            reader.read(root, credentials, ParentIdentity.Dad, isActive = { false })
        }
        assertEquals(0, remote.downloadCalls)
        assertTrue(reader.loadCached(ParentIdentity.Dad, root).records.isEmpty())
    }
}
