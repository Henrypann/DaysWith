package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.archive.*
import com.henrypann.jinbao365.data.ArchiveRepository
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.media.CaptureTime
import com.henrypann.jinbao365.media.ContentHash
import com.henrypann.jinbao365.media.MediaImportLocks
import com.henrypann.jinbao365.storage.StorageConfiguration
import com.henrypann.jinbao365.storage.StorageCredentials
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.Files
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import kotlinx.serialization.json.*

/** Restores only the immutable parent folder selected on this phone. All reads precede publication. */
class FolderTakeover(
    private val archive: ArchiveRepository,
    private val states: BackupStatePersistence,
    private val mediaRoot: File,
    private val objectStore: (StorageConfiguration, StorageCredentials, BackupCancellation) -> CosObjectStore =
        { configuration, credentials, cancellation -> CosObjectClient(configuration, credentials, cancellation) },
) {
    fun restore(
        root: StorageConfiguration,
        owner: ParentIdentity,
        credentials: StorageCredentials,
        deviceId: String,
        now: Long = System.currentTimeMillis(),
        cancellation: BackupCancellation = BackupCancellation(),
        isActive: () -> Boolean = { true },
    ): BackupReceipt = states.exclusive {
        fun checkpoint() {
            cancellation.check()
            check(isActive()) { "The verified parent destination changed during restore" }
        }
        val configuration = V1Destination.forParent(root, owner)
        configuration.validate()
        require(credentials.valid())
        val writer = V1Ids.canonical(deviceId, "writerDeviceID")
        val previousState = states.load()
        val previousSnapshot = archive.loadSnapshot()
        val previousAnniversaries = archive.loadAnniversaries()
        val objects = ParentScopedCosStore(objectStore(configuration, credentials, cancellation), owner)
        check(objects.configuration == configuration)
        checkpoint()
        val head = V1Validator.latest(objects, cancellation) ?: throw IOException("No snapshot to restore")
        val folder = File(mediaRoot, "restored/${UUID.randomUUID()}")
        check(folder.mkdirs()) { "Cannot stage restored originals" }
        try {
            val paths = mutableMapOf<String, String>()
            val stagedFiles = mutableMapOf<String, File>()
            for (resource in head.manifest.resources.distinctBy { it.objectKey }) {
                checkpoint()
                val file = File(folder, resource.sha256)
                FileOutputStream(file).use { output ->
                    // Hash actual written bytes again below; never trust transport metadata alone.
                    objects.download(resource.objectKey, object : java.io.OutputStream() {
                        private var count = 0L
                        override fun write(value: Int) = write(byteArrayOf(value.toByte()), 0, 1)
                        override fun write(bytes: ByteArray, offset: Int, length: Int) {
                            checkpoint()
                            count += length
                            check(count <= resource.byteCount) { "Restored original exceeds saved size" }
                            output.write(bytes, offset, length)
                        }
                    })
                    output.fd.sync()
                }
                verify(file, resource, ::checkpoint)
                stagedFiles[resource.objectKey] = file
                paths[resource.objectKey] = ContentHash.objectKey(resource.sha256)
            }
            val snapshot = project(head.manifest, writer, paths, previousSnapshot, owner)
            // Validate the entire local representation before any receipt or cloud mutation.
            ArchiveJson.parseSnapshot(ArchiveJson.encodeSnapshot(snapshot))
            checkpoint()
            val latest = V1Validator.latest(objects, cancellation)
            check(latest?.commitHash == head.commitHash) { "Cloud head changed during restore" }
            val commit = V1Commit(sequence = head.commit.sequence + 1, parentHash = head.commitHash,
                writerDeviceID = writer, kind = "takeover", manifestHash = head.commit.manifestHash,
                manifestKey = head.commit.manifestKey, createdAt = now,
                requestID = UUID.randomUUID().toString().uppercase(Locale.ROOT))
            val key = configuration.prefix + V1Json.commitRelativeKey(commit.sequence)
            V1Validator.validateCommit(commit, key, configuration.prefix, head.commit, head.commitHash)
            val bytes = V1Json.encodeCommit(commit)
            val receipt = BackupReceipt(head.commit.sequence, head.commitHash, head.commit.manifestHash, now,
                head.manifest.resources.map { it.objectKey }.toSet(), BackupEngine.momentHashes(head.manifest), head.packedThrough)
            val nextState = BackupState(bucket = configuration.bucket, prefix = configuration.prefix,
                receipt = receipt, lastSuccessfulBackupAt = now, stage = "restored", paused = false,
                takeover = BackupTakeover(writer, java.util.Base64.getEncoder().encodeToString(bytes)),
                objects = head.manifest.resources.associate { it.objectKey to
                    BackupObjectState(BackupObjectStatus.verified, firstQueuedAt = now) })
            // Match import's media -> Room lock order. Downloads stay outside the media lock,
            // but an import must not reuse newly installed originals before rollback finishes.
            synchronized(MediaImportLocks.forRoot(mediaRoot)) {
                val installedFiles = mutableListOf<File>()
                var stateTouched = false
                var completed = false
                try {
                    archive.restoreForTakeover(snapshot, deviceId, receipt.sequence, receipt.commitHash,
                        expectedSnapshot = previousSnapshot,
                        anniversaries = head.manifest.anniversaries,
                        expectedAnniversaries = previousAnniversaries) {
                        // The expected snapshot is checked before files enter canonical local paths.
                        // Reuse verified originals and track only new files for rollback.
                        for (resource in head.manifest.resources.distinctBy { it.objectKey }) {
                            checkpoint()
                            val target = File(mediaRoot, paths.getValue(resource.objectKey))
                            if (target.exists()) {
                                verify(target, resource, ::checkpoint)
                            } else {
                                check(target.parentFile!!.mkdirs() || target.parentFile!!.isDirectory) {
                                    "照片保存失败，请稍后重试"
                                }
                                Files.move(stagedFiles.getValue(resource.objectKey).toPath(), target.toPath())
                                installedFiles += target
                            }
                        }
                        // Room rolls back on any callback failure.
                        checkpoint()
                        stateTouched = true
                        states.save(nextState)
                        // No cloud writes belong to restore. The durable registration is published by
                        // ordinary backup only after this Room transaction has fully committed.
                        checkpoint()
                    }
                    completed = true
                    receipt
                } catch (failure: Exception) {
                    if (stateTouched) try { states.restore(previousState) }
                        catch (rollback: Exception) { failure.addSuppressed(rollback) }
                    throw failure
                } finally {
                    if (!completed) installedFiles.forEach { it.delete() }
                }
            }
        } finally {
            folder.deleteRecursively()
        }
    }

    private fun project(manifest: V1Manifest, writer: String, paths: Map<String, String>,
                        local: ArchiveSnapshot, owner: ParentIdentity): ArchiveSnapshot {
        fun aliases(kind: String, ids: List<String>) = ids.associateBy { V1Ids.map(kind, it) }
        val recordIds = aliases("record", local.records.map { it.id })
        val assetIds = aliases("asset", local.assets.map { it.id })
        val resourceIds = aliases("resource", local.resources.map { it.id })
        fun id(aliases: Map<String, String>, value: String) = aliases[value.uppercase(Locale.ROOT)] ?: value.uppercase(Locale.ROOT)
        fun field(value: JsonElement, at: Long, revision: Long = 0) = FieldEnvelope(value, EditStamp(revision, at, writer))
        val records = manifest.moments.map { moment ->
            fun f(value: JsonElement) = field(value, moment.updatedAt, moment.revision)
            ArchiveRecord(id = id(recordIds, moment.id), title = f(JsonPrimitive(moment.title)), note = f(JsonPrimitive(moment.note)),
                occurredAt = f(buildJsonObject { put("utc", moment.occurredAt); put("zoneUnknown", true) }),
                createdAt = f(JsonPrimitive(moment.createdAt)),
                assetIds = f(JsonArray(moment.assetIDs.map { JsonPrimitive(id(assetIds, it)) })),
                tombstone = f(moment.trashedAt?.let { buildJsonObject { put("deletedAt", it) } } ?: JsonNull),
                extensions = mapOf("parent" to f(JsonPrimitive(owner.folder))) +
                    listOfNotNull(moment.deviceManufacturer?.let { "deviceManufacturer" to f(JsonPrimitive(it)) },
                        moment.deviceModel?.let { "deviceModel" to f(JsonPrimitive(it)) }).toMap())
        }
        val assets = manifest.assets.map { asset ->
            val capturedAt = field(if (asset.capturedAt == 0L) buildJsonObject { put("timeUnknown", true) }
                else CaptureTime.atRead(CaptureTime.zoneUnknown(asset.capturedAt)), maxOf(0, asset.capturedAt), asset.revision)
            val provenance = ImportProvenance.fromWire(asset.importProvenance)
            MediaAsset(id(assetIds, asset.id), asset.kind,
                capturedAt, asset.resourceIDs.map { id(resourceIds, it) },
                if (provenance == ImportProvenance.Unknown) emptyMap() else mapOf(
                    ImportProvenance.EXTENSION_KEY to FieldEnvelope(JsonPrimitive(provenance.wireValue), capturedAt.edit)))
        }
        val resources = manifest.resources.map { resource ->
            MediaResource(id(resourceIds, resource.id), id(assetIds, resource.assetID), resource.role,
                resource.contentType, resource.originalFilename, resource.byteCount, resource.sha256,
                paths.getValue(resource.objectKey), emptyMap())
        }
        return local.copy(records = records + local.records.filter { old -> records.none { it.id == old.id } },
            assets = assets + local.assets.filter { old -> assets.none { it.id == old.id } },
            resources = resources + local.resources.filter { old -> resources.none { it.id == old.id } })
    }

    private fun verify(file: File, resource: V1Resource, checkpoint: () -> Unit) {
        check(file.length() == resource.byteCount) { "Restored original has a different byte count" }
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                checkpoint()
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        check(digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) } == resource.sha256) {
            "Restored original has a different SHA-256"
        }
    }

    companion object { const val FAILURE_MESSAGE = "恢复没完成，稍后再试" }
}
