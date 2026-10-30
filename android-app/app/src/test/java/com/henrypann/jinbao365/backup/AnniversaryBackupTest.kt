package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.archive.*
import com.henrypann.jinbao365.data.Anniversary
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.storage.StorageConfiguration
import com.henrypann.jinbao365.storage.StorageCredentials
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.time.LocalDate
import java.io.File
import kotlinx.serialization.json.*

class AnniversaryBackupTest {
    @get:Rule val temporary = TemporaryFolder()
    private val config = StorageConfiguration(bucket = "example-1234567890", prefix = ParentIdentity.Mom.prefix)
    private val credentials = StorageCredentials("fixtureID", "fixtureKey")
    private val device = "00000000-0000-4000-8000-000000000001"
    private val anniversary = Anniversary("00000000-0000-4000-8000-000000000099", ParentIdentity.Mom,
        "示例生日", LocalDate.of(2000, 2, 3))
    private val remote = MemoryCosStore(config)
    private val states = MemoryBackupState().apply { value = BackupState(bucket = config.bucket, prefix = config.prefix, paused = false) }
    private fun engine() = BackupEngine(states, { BackupConditions(config, true, false, false) },
        objectStore = { _, _, _ -> remote }, parent = ParentIdentity.Mom)

    @Test fun anniversaryOnlyChangesPublishAndCoverageChangesUntilCommitAndDeletionUsesTombstone() {
        val root = temporary.newFolder()
        val snapshot = ArchiveSnapshot.empty()
        val first = engine().runOnce(snapshot, root, config, credentials, device, 100, listOf(anniversary))
        assertEquals(2, V1Validator.latest(remote, BackupCancellation())!!.manifest.version)
        assertEquals(1, V1Validator.latest(remote, BackupCancellation())!!.commit.version)
        assertTrue(DefaultBackupStatusQuery().query(snapshot, states.value, 100, anniversaries = listOf(anniversary)).allCovered)
        val changed = anniversary.copy(title = "示例纪念日")
        assertFalse(DefaultBackupStatusQuery().query(snapshot, states.value, 101, anniversaries = listOf(changed)).allCovered)
        val second = engine().runOnce(snapshot, root, config, credentials, device, 101, listOf(changed))
        assertEquals(first.sequence + 1, second.sequence)
        assertNotEquals(first.manifestHash, second.manifestHash)
        val before = remote.writes.toList()
        val failure = assertThrows(BackupException::class.java) {
            engine().runOnce(snapshot, root, config, credentials, device, 102, emptyList())
        }
        assertEquals(BackupFailure.RecordLoss, failure.failure)
        assertEquals(before, remote.writes)
        val deleted = changed.copy(deletedAt = 103)
        engine().runOnce(snapshot, root, config, credentials, device, 103, listOf(deleted))
        assertEquals(listOf(deleted), V1Validator.latest(remote, BackupCancellation())!!.manifest.anniversaries)
        assertTrue(remote.writes.all { it.startsWith(ParentIdentity.Mom.prefix) })
    }

    @Test fun motherMediaSnapshotAndCommitWritesAllUseOwnPrefixAndDeviceMetadataRoundTrips() {
        val root = temporary.newFolder()
        val bytes = "离线照片".toByteArray()
        val hash = V1Json.sha256(bytes)
        val key = "objects/${hash.take(2)}/$hash"
        File(root, key).apply { parentFile!!.mkdirs(); writeBytes(bytes) }
        fun f(value: JsonElement) = FieldEnvelope(value, EditStamp(1, 100, device))
        val record = ArchiveRecord("record", f(JsonPrimitive("今天")), f(JsonPrimitive("散步")),
            f(buildJsonObject { put("utc", 100); put("zoneUnknown", true) }), f(JsonPrimitive(100)),
            f(JsonArray(listOf(JsonPrimitive("asset")))), f(JsonNull),
            mapOf("deviceManufacturer" to f(JsonPrimitive("离线制造商")), "deviceModel" to f(JsonPrimitive("离线型号"))))
        val asset = MediaAsset("asset", "photo", f(buildJsonObject { put("timeUnknown", true) }), listOf("resource", "preview"), emptyMap())
        val resource = MediaResource("resource", "asset", "photo", "image/jpeg", "photo.jpg", bytes.size.toLong(), hash, key, emptyMap())
        val snapshot = ArchiveSnapshot(records = listOf(record), assets = listOf(asset),
            resources = listOf(resource, resource.copy(id = "preview", role = "preview")), extensions = emptyMap())
        engine().runOnce(snapshot, root, config, credentials, device, 100, listOf(anniversary, anniversary.copy(owner = ParentIdentity.Dad)))
        assertTrue(remote.writes.any { it.startsWith(ParentIdentity.Mom.prefix + "objects/") })
        assertTrue(remote.writes.any { it.startsWith(ParentIdentity.Mom.prefix + "snapshots/") })
        assertTrue(remote.writes.any { it.startsWith(ParentIdentity.Mom.prefix + "commits/") })
        assertTrue(remote.writes.all { it.startsWith(ParentIdentity.Mom.prefix) })
        val manifest = V1Validator.latest(remote, BackupCancellation())!!.manifest
        assertEquals(listOf(anniversary), manifest.anniversaries)
        assertEquals("离线型号", manifest.moments.single().deviceModel)
        assertEquals("离线制造商", manifest.moments.single().deviceManufacturer)
    }

    @Test fun oldManifestReadsEmptyAnniversariesAndForeignOwnersOrMalformedDatesFail() {
        val old = V1Manifest(version = 1)
        assertTrue(V1Json.decodeManifest(V1Json.encodeManifest(old)).anniversaries.isEmpty())
        val manifest = V1Manifest(version = 2, anniversaries = listOf(anniversary))
        assertEquals(manifest, V1Json.decodeManifest(V1Json.encodeManifest(manifest)))
        assertThrows(V1ValidationException::class.java) { V1Validator.validate(manifest, ParentIdentity.Dad.prefix) }
        assertThrows(V1ValidationException::class.java) {
            V1Json.decodeManifest(V1Json.encodeManifest(manifest).toString(Charsets.UTF_8)
                .replace("2000-02-03", "2023-02-29").toByteArray())
        }
        assertThrows(V1ValidationException::class.java) { V1Validator.validate(manifest.copy(version = 3), config.prefix) }
    }
}
