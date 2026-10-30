package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.data.Anniversary
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.storage.StorageConfiguration
import com.henrypann.jinbao365.storage.StorageCredentials
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest
import java.util.Base64
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CancellationException

/** The host must read these on its worker thread from the verified connection, network and repository. */
data class BackupConditions(
    val verifiedConfiguration: StorageConfiguration?,
    val unmeteredWifi: Boolean,
    val paused: Boolean,
    val readOnly: Boolean,
    val networkConnected: Boolean = true,
)

enum class BackupFailure(val text: String) {
    Configuration("请检查存储桶、地域和存储路径。"),
    Connection("请先连接云存储。"),
    Credentials("暂时无法读取云存储凭据，请解锁手机后重试。"),
    Wifi(BackupPolicy.WIFI_WAITING),
    Offline("等待网络"),
    RecordLoss(BackupPolicy.RETRY_MESSAGE),
    Paused("备份已暂停。"),
    ReadOnly("记录正在恢复，目前只能查看。"),
    OtherWriter("这个文件夹已经由另一台手机使用。"),
    ReceiptMismatch("云端记录与这台手机的备份凭证不一致，请保留本机原件并检查文件夹。"),
    MissingOriginal("本机缺少原件，请重新导入后备份。"),
    ChangedOriginal("原件与保存时的校验值不一致，请重新导入后备份。"),
    OriginalRead("无法读取原件，请保留本机原件后重试。"),
    ArchivedFile("云端原件缺失或校验失败。"),
    ExistingMismatch("云端已有同名文件，但大小或校验值不同。没有覆盖，请检查云存储。"),
    MetadataLimit("记录数据超过当前支持的大小。"),
    State("无法保存备份进度，请保留本机原件后重试。"),
    StateRead("无法读取备份进度，请保留本机原件后重试。"),
}
class BackupException(val failure: BackupFailure, val objectKey: String? = null) : Exception(failure.text)
data class BackupProgress(val stage: String, val objectKey: String?, val completed: Int, val total: Int, val error: String? = null)

/**
 * Synchronous worker-thread operation. No scheduler, UI, Room mutations or credential persistence.
 * A frozen interrupted publication is completed first; newer edits wait for the next run.
 * The conditions provider is mandatory and rechecked before every transfer and retry.
 */
class BackupEngine(
    private val states: BackupStatePersistence,
    private val conditions: () -> BackupConditions,
    private val objectStore: (StorageConfiguration, StorageCredentials, BackupCancellation) -> CosObjectStore =
        { configuration, credentials, cancellation -> CosObjectClient(configuration, credentials, cancellation) },
    private val cancellation: BackupCancellation = BackupCancellation(),
    private val onProgress: (BackupProgress) -> Unit = {},
    private val requestId: () -> UUID = UUID::randomUUID,
    private val backoff: (Long) -> Unit = { Thread.sleep(it) },
    private val maxAttempts: Int = 3,
    private val stopAfterObject: () -> Boolean = { false },
    private val clock: () -> Long = System::currentTimeMillis,
    private val allowCellular: Boolean = BackupPolicy.ALLOW_CELLULAR,
    private val isTakeoverReady: (BackupReceipt) -> Boolean = { false },
    private val parent: ParentIdentity? = null,
) {
    init { require(maxAttempts in 1..10) }
    fun cancel() = cancellation.cancel()

    fun runOnce(snapshot: ArchiveSnapshot, mediaRoot: File, config: StorageConfiguration,
                credentials: StorageCredentials?, deviceId: String, now: Long,
                anniversaries: List<Anniversary> = emptyList()): BackupReceipt = states.exclusive {
        fun earlyFailure(failure: BackupFailure): Nothing {
            onProgress(BackupProgress("failed", null, 0, 0, failure.text))
            throw BackupException(failure)
        }
        try { config.validate(); require(now in 0..8_640_000_000_000_000L) }
        catch (_: IllegalArgumentException) { earlyFailure(BackupFailure.Configuration) }
        val writer = try {
            require(Regex("[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}").matches(deviceId))
            UUID.fromString(deviceId).toString().uppercase(Locale.ROOT)
        } catch (_: IllegalArgumentException) { earlyFailure(BackupFailure.Configuration) }
        val loaded = try { states.load() } catch (_: Exception) { earlyFailure(BackupFailure.StateRead) }
        var state = loaded?.takeIf { it.bucket == config.bucket && it.prefix == config.prefix }
            ?: BackupState(bucket = config.bucket, prefix = config.prefix, paused = true)
        // Process death or a previous interrupted transfer must not look active in a new run.
        state = state.copy(multipart = emptyMap(), objects = state.objects.mapValues { (_, value) ->
            if (value.status in setOf(BackupObjectStatus.uploading, BackupObjectStatus.verifying))
                value.copy(status = BackupObjectStatus.pending) else value
        })
        var currentKey: String? = null
        var total = 0
        var completed = 0
        fun save(next: BackupState) {
            try { states.save(next) } catch (_: Exception) { throw BackupException(BackupFailure.State) }
            state = next
        }
        fun report(stage: String, key: String? = null, error: String? = null) {
            currentKey = key
            try { save(state.copy(stage = stage, lastError = error)) }
            finally { onProgress(BackupProgress(stage, key, completed, total, error)) }
        }
        fun objectBoundary() {
            if (stopAfterObject()) throw CancellationException("应用已进入后台。")
        }
        fun checkpoint() {
            objectBoundary()
            cancellation.check()
            val value = conditions()
            when {
                value.verifiedConfiguration != config -> throw BackupException(BackupFailure.Connection)
                credentials?.valid() != true -> throw BackupException(BackupFailure.Credentials)
                state.paused || value.paused -> throw BackupException(BackupFailure.Paused)
                value.readOnly -> throw BackupException(BackupFailure.ReadOnly)
                !value.networkConnected -> throw BackupException(BackupFailure.Offline)
                !allowCellular && !value.unmeteredWifi -> throw BackupException(BackupFailure.Wifi)
            }
        }
        fun <T> retry(operation: () -> T): T {
            var attempt = 0
            while (true) {
                checkpoint()
                try { return operation() }
                catch (failure: CosException) {
                    checkpoint()
                    attempt++
                    if (failure.failure !in setOf(CosFailure.Network, CosFailure.Timeout) || attempt >= maxAttempts) throw failure
                    // Sliced waits make pause/disconnect/cancellation responsive during exponential backoff.
                    var remaining = 1_000L shl (attempt - 1)
                    while (remaining > 0) {
                        checkpoint()
                        val delay = minOf(100L, remaining)
                        try { backoff(delay) } catch (_: InterruptedException) {
                            Thread.currentThread().interrupt(); throw CancellationException()
                        }
                        remaining -= delay
                    }
                }
            }
        }
        fun mark(key: String, status: BackupObjectStatus, error: String? = null, attempted: Boolean = false) {
            val previous = state.objects[key] ?: BackupObjectState(firstQueuedAt = now)
            if (previous.status == BackupObjectStatus.verified && status != BackupObjectStatus.verified) completed--
            save(state.copy(lastUploadAtMillis = if (status == BackupObjectStatus.verified) clock() else state.lastUploadAtMillis,
                objects = state.objects + (key to previous.copy(status = status,
                lastError = error, attempts = if (attempted) previous.attempts + 1 else previous.attempts))))
            report(status.name, key, error)
        }
        try {
            objectBoundary()
            checkpoint()
            report("checkingOwnership") // Also durably binds/reset the location before any cloud access.
            val raw = objectStore(config, checkNotNull(credentials), cancellation)
            // Real service writes require the separately persisted identity, never a credential-derived guess.
            if (parent == null && raw is CosObjectClient) throw BackupException(BackupFailure.Configuration)
            val scoped = parent?.let { ParentScopedCosStore(raw, it) } ?: raw
            val objects = CheckedCosStore(scoped, ::checkpoint)
            if (objects.configuration != config) throw BackupException(BackupFailure.Configuration)
            var registrationHead = retry { V1Validator.latest(objects, cancellation) }
            state.takeover?.let { registration ->
                check(registration.writerDeviceId == writer) { "Writer registration belongs to a different installation" }
                val registeredBytes = decodeBytes(registration.commitBytes)
                val registered = V1Json.decodeCommit(registeredBytes)
                val registeredHash = V1Json.sha256(registeredBytes)
                val parent = checkNotNull(state.receipt)
                check(isTakeoverReady(parent)) { "Local restore transaction is not committed" }
                val registeredKey = config.prefix + V1Json.commitRelativeKey(registered.sequence)
                check(registered.kind == "takeover" && registered.writerDeviceID == writer &&
                    registered.sequence == parent.sequence + 1 && registered.parentHash == parent.commitHash &&
                    registered.manifestHash == parent.manifestHash) { "Invalid restored writer registration" }
                if (registrationHead?.commitHash != registeredHash) {
                    val head = registrationHead ?: throw BackupException(BackupFailure.ReceiptMismatch)
                    if (head.commitHash != parent.commitHash || head.commit.manifestHash != parent.manifestHash)
                        throw BackupException(BackupFailure.ReceiptMismatch)
                    V1Validator.validateCommit(registered, registeredKey, config.prefix, head.commit, head.commitHash)
                    // Restoration completed before this intent existed. Still refuse to register a
                    // writer whose local records have since disappeared without user tombstones.
                    val local = V1Mapper.map(snapshot, config.prefix, anniversaries)
                    ensureNoRecordLoss(head.manifest, local)
                    retry {
                        try { objects.put(registeredKey, registeredBytes, "application/json") }
                        catch (failure: CosException) {
                            if (failure.failure != CosFailure.Conflict) throw failure
                        }
                        if (!objects.get(registeredKey).contentEquals(registeredBytes))
                            throw BackupException(BackupFailure.ExistingMismatch, registeredKey)
                    }
                    registrationHead = V1Receipt(registered, registeredHash, head.manifest)
                }
                // A lost PUT/readback/save leaves the intent intact for exact reconciliation.
                save(state.copy(takeover = null, receipt = parent.copy(sequence = registered.sequence,
                    commitHash = registeredHash, publishedAt = registered.createdAt)))
            }
            val latest = registrationHead
            if (latest != null && latest.commit.writerDeviceID != writer) throw BackupException(BackupFailure.OtherWriter)
            val frozen = state.pending
            val frozenCommit = frozen?.let { V1Json.decodeCommit(decodeBytes(it.commitBytes)) }
            val cloudIsFrozen = frozenCommit != null && latest?.commitHash == V1Json.sha256(decodeBytes(frozen.commitBytes))
            val receiptMatches = if (state.receipt == null) latest == null else latest != null &&
                state.receipt!!.sequence == latest.commit.sequence && state.receipt!!.commitHash == latest.commitHash &&
                state.receipt!!.manifestHash == latest.commit.manifestHash
            if (!receiptMatches && !cloudIsFrozen) throw BackupException(BackupFailure.ReceiptMismatch)

            val manifest = frozen?.let { V1Json.decodeManifest(decodeBytes(it.manifestBytes)) }
                ?: V1Mapper.map(snapshot, config.prefix, anniversaries)
            V1Validator.validate(manifest, config.prefix)
            latest?.let { ensureNoRecordLoss(it.manifest, manifest) }
            val manifestBytes = frozen?.let { decodeBytes(it.manifestBytes) } ?: V1Json.encodeManifest(manifest)
            if (manifestBytes.size > METADATA_LIMIT) throw BackupException(BackupFailure.MetadataLimit)
            val hash = V1Json.sha256(manifestBytes)
            if (frozenCommit != null) {
                val parent = state.receipt
                if (frozenCommit.writerDeviceID != writer || frozenCommit.sequence != (parent?.sequence ?: 0L) + 1 ||
                    frozenCommit.parentHash != parent?.commitHash || frozenCommit.manifestHash != hash ||
                    frozenCommit.kind != "snapshot") throw BackupException(BackupFailure.ReceiptMismatch)
                if (!cloudIsFrozen) V1Validator.validateCommit(frozenCommit,
                    config.prefix + V1Json.commitRelativeKey(frozenCommit.sequence), config.prefix, latest?.commit, latest?.commitHash)
            }
            val sourcePaths = frozen?.sourcePaths ?: snapshot.resources.associate {
                V1Ids.map("resource", it.id) to it.objectKey
            }.let { paths -> manifest.resources.associate { it.objectKey to checkNotNull(paths[it.id]) } }
            val resources = manifest.resources.distinctBy { it.objectKey }.sortedBy { it.objectKey }
            total = resources.size
            completed = resources.count { state.objects[it.objectKey]?.status == BackupObjectStatus.verified }
            // Enqueue all objects first so cancellation still leaves a complete, durable queue.
            save(state.copy(objects = state.objects + resources.filter { it.objectKey !in state.objects }.associate {
                it.objectKey to BackupObjectState(firstQueuedAt = now)
            }))
            for (resource in resources) {
                objectBoundary()
                checkpoint()
                val key = resource.objectKey
                currentKey = key
                val source = sourceFile(mediaRoot, sourcePaths[key], key)
                if (source.length() != resource.byteCount) throw BackupException(BackupFailure.ChangedOriginal, key)
                val alreadyVerified = state.objects[key]?.status == BackupObjectStatus.verified
                if (!alreadyVerified) mark(key, BackupObjectStatus.pending)
                // Reject changed local bytes before writing an immutable content-addressed object.
                val local = try { hashFile(source, cancellation) } catch (_: IOException) {
                    throw BackupException(if (source.isFile) BackupFailure.OriginalRead else BackupFailure.MissingOriginal, key)
                }
                if (local.byteCount != resource.byteCount || local.sha256 != resource.sha256) {
                    throw BackupException(BackupFailure.ChangedOriginal, key)
                }
                // A saved remote verification does not prove that the local original stayed unchanged.
                if (alreadyVerified) continue
                try {
                    var acceptedExisting = false
                    retry {
                        mark(key, BackupObjectStatus.uploading, attempted = true)
                        try {
                            if (resource.byteCount <= METADATA_LIMIT) {
                                objects.putFile(key, source, resource.contentType)
                            } else {
                                // Every attempt starts a new file transfer at byte zero. Never reuse a
                                // failed multipart session or server parts from an earlier attempt.
                                uploadMultipart(objects, key, source, resource.contentType, resource.sha256,
                                    checkpoint = ::checkpoint)
                            }
                        } catch (error: CosException) {
                            if (error.failure != CosFailure.Conflict) throw error
                            verifyExisting(objects, key, resource.byteCount, resource.sha256)
                            acceptedExisting = true
                        }
                    }
                    mark(key, BackupObjectStatus.verifying)
                    if (!acceptedExisting) {
                        val downloaded = try { retry { objects.download(key, DISCARD) } }
                        catch (error: CosException) {
                            if (error.failure in setOf(CosFailure.NotFound, CosFailure.InvalidResponse)) throw BackupException(BackupFailure.ArchivedFile, key)
                            throw error
                        }
                        if (downloaded.byteCount != resource.byteCount || downloaded.sha256 != resource.sha256) {
                            throw BackupException(BackupFailure.ArchivedFile, key)
                        }
                    }
                    completed++
                    save(state.copy(multipart = state.multipart - key))
                    mark(key, BackupObjectStatus.verified)
                } catch (failure: Exception) {
                    if (isDeferred(failure)) mark(key, BackupObjectStatus.pending)
                    else mark(key, BackupObjectStatus.failed, safeError(failure))
                    throw failure
                }
            }
            currentKey = null
            objectBoundary()
            val packedThrough = manifest.moments.maxOfOrNull { it.updatedAt }
            if (frozen == null && state.receipt?.manifestHash == hash && state.receipt?.packedThrough == packedThrough) {
                save(state.copy(lastSuccessfulBackupAt = now))
                report("complete")
                return@exclusive checkNotNull(state.receipt)
            }
            val pending = frozen ?: run {
                val parent = state.receipt
                val commit = V1Commit(sequence = (parent?.sequence ?: 0L) + 1L, parentHash = parent?.commitHash,
                    writerDeviceID = writer, kind = "snapshot", manifestHash = hash,
                    manifestKey = config.prefix + "snapshots/$hash.json", createdAt = now,
                    requestID = requestId().toString().uppercase(Locale.ROOT))
                val commitBytes = V1Json.encodeCommit(commit)
                BackupPending(encodeBytes(manifestBytes), encodeBytes(commitBytes), sourcePaths).also {
                    // No metadata PUT until this exact document has been fsynced.
                    save(state.copy(pending = it))
                }
            }
            val commitBytes = decodeBytes(pending.commitBytes)
            val commit = V1Json.decodeCommit(commitBytes)
            fun putVerified(key: String, bytes: ByteArray) {
                retry {
                    try { objects.put(key, bytes, "application/json") }
                    catch (error: CosException) {
                        if (error.failure != CosFailure.Conflict) throw error
                        verifyExisting(objects, key, bytes.size.toLong(), V1Json.sha256(bytes))
                        return@retry
                    }
                    val actual = try { objects.get(key) } catch (error: CosException) {
                        if (error.failure in setOf(CosFailure.NotFound, CosFailure.InvalidResponse)) throw BackupException(BackupFailure.ArchivedFile, key)
                        throw error
                    }
                    if (!actual.contentEquals(bytes)) throw BackupException(BackupFailure.ArchivedFile, key)
                }
            }
            objectBoundary()
            report("publishingManifest", commit.manifestKey)
            putVerified(commit.manifestKey, manifestBytes)
            val commitKey = config.prefix + V1Json.commitRelativeKey(commit.sequence)
            objectBoundary()
            report("publishingCommit", commitKey)
            putVerified(commitKey, commitBytes)
            val receipt = BackupReceipt(commit.sequence, V1Json.sha256(commitBytes), hash, now,
                resources.map { it.objectKey }.toSet(), momentHashes(manifest), packedThrough)
            save(state.copy(pending = null, receipt = receipt, lastSuccessfulBackupAt = now))
            report("complete")
            receipt
        } catch (failure: Exception) {
            val message = if (isDeferred(failure)) null else safeError(failure)
            val key = (failure as? BackupException)?.objectKey ?: currentKey
            if (failure is BackupException && failure.failure in setOf(BackupFailure.MissingOriginal, BackupFailure.ChangedOriginal, BackupFailure.OriginalRead)) {
                key?.let { mark(it, BackupObjectStatus.failed, message) }
            }
            report(if (failure is CancellationException) "cancelled" else if (isDeferred(failure)) "waiting" else "failed", key, message)
            throw failure
        }
    }

    /** Compatibility helper; all coverage and age rules live in the UI's shared query. */
    fun overdueRecordIds(snapshot: ArchiveSnapshot, config: StorageConfiguration, now: Long): Set<String> {
        val state = states.load()?.takeIf { it.bucket == config.bucket && it.prefix == config.prefix }
        return DefaultBackupStatusQuery().query(snapshot, state, now,
            BackupCoordinatorState(state = state, configuration = config, paused = state?.paused ?: true,
                blockReason = null)).overdueRecordIds
    }

    /** Object ETags are deliberately ignored: COS multipart ETags are not file hashes. */
    private fun verifyExisting(objects: CosObjectStore, key: String, size: Long, hash: String) {
        val remote = objects.head(key)
        if (remote == null || remote.byteCount != size || remote.sha256 != hash) {
            throw BackupException(BackupFailure.ExistingMismatch, key)
        }
    }

    private fun uploadMultipart(objects: CosObjectStore, key: String, source: File, contentType: String,
                                sha256: String, checkpoint: () -> Unit) {
        checkpoint()
        val uploadId = objects.initiateMultipart(key, contentType, sha256)
        val count = ((source.length() + PART_SIZE - 1) / PART_SIZE).toInt()
        val parts = mutableListOf<CosPart>()
        for (number in 1..count) {
            checkpoint()
            val offset = (number - 1L) * PART_SIZE
            val length = minOf(PART_SIZE, source.length() - offset)
            val etag = objects.uploadPart(key, uploadId, number, source, offset, length)
            parts += CosPart(number, etag, length)
        }
        checkpoint()
        objects.completeMultipart(key, uploadId, parts)
    }

    companion object {
        const val METADATA_LIMIT = 32 * 1024 * 1024
        const val PART_SIZE = 8L * 1024 * 1024
        const val DAY_MILLIS = 86_400_000L
        private val DISCARD = object : OutputStream() {
            override fun write(b: Int) = Unit
            override fun write(b: ByteArray, off: Int, len: Int) = Unit
        }
        private fun encodeBytes(bytes: ByteArray) = Base64.getEncoder().encodeToString(bytes)
        private fun decodeBytes(value: String): ByteArray = Base64.getDecoder().decode(value)
        internal fun isDeferred(error: Exception): Boolean = error is CancellationException ||
            (error is BackupException && error.failure in setOf(BackupFailure.Connection, BackupFailure.Credentials,
                BackupFailure.Wifi, BackupFailure.Offline, BackupFailure.Paused, BackupFailure.ReadOnly))
        internal fun safeError(error: Exception): String {
            java.util.logging.Logger.getLogger("JinbaoBackup").log(java.util.logging.Level.WARNING,
                "Backup operation failed", error)
            return when (error) {
                is BackupException -> error.failure.text
                else -> BackupPolicy.RETRY_MESSAGE
            }
        }
        private fun sourceFile(root: File, relative: String?, key: String): File {
            if (relative.isNullOrEmpty() || File(relative).isAbsolute) throw BackupException(BackupFailure.MissingOriginal, key)
            val base = root.canonicalFile
            val file = File(base, relative).canonicalFile
            if (!file.toPath().startsWith(base.toPath()) || file == base || !file.isFile) {
                throw BackupException(BackupFailure.MissingOriginal, key)
            }
            return file
        }
        private fun hashFile(file: File, cancellation: BackupCancellation): CosDownload {
            val sha = MessageDigest.getInstance("SHA-256")
            var size = 0L
            file.inputStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    cancellation.check()
                    val n = input.read(buffer)
                    if (n < 0) break
                    sha.update(buffer, 0, n); size += n
                }
            }
            return CosDownload(size, sha.digest().joinToString("") { "%02x".format(it.toInt() and 255) })
        }
        private fun ensureNoRecordLoss(head: V1Manifest, next: V1Manifest) {
            val presentIds = next.moments.map { it.id.uppercase(Locale.ROOT) }.toSet()
            if (head.moments.any { it.trashedAt == null && it.id.uppercase(Locale.ROOT) !in presentIds })
                throw BackupException(BackupFailure.RecordLoss)
            val anniversaryIds = next.anniversaries.map { it.id.uppercase(Locale.ROOT) }.toSet()
            if (head.anniversaries.any { it.id.uppercase(Locale.ROOT) !in anniversaryIds })
                throw BackupException(BackupFailure.RecordLoss)
        }

        internal fun momentHashes(manifest: V1Manifest): Map<String, String> = manifest.moments.associate { moment ->
            val used = moment.assetIDs.toSet()
            moment.id to V1Json.sha256(V1Json.encodeManifest(manifest.copy(moments = listOf(moment), anniversaries = emptyList(),
                assets = manifest.assets.filter { it.id in used }, resources = manifest.resources.filter { it.assetID in used })))
        }

    }
}

/** Recheck the host's gate inside paginated chain reads and multipart operations as well. */
private class CheckedCosStore(private val store: CosObjectStore, private val checkpoint: () -> Unit) : CosObjectStore by store {
    private fun <T> checked(block: () -> T): T { checkpoint(); return block() }
    override fun list(prefix: String) = checked { store.list(prefix) }
    override fun head(key: String) = checked { store.head(key) }
    override fun get(key: String) = checked { store.get(key) }
    override fun download(key: String, output: OutputStream) = checked { store.download(key, output) }
    override fun put(key: String, bytes: ByteArray, contentType: String) = checked { store.put(key, bytes, contentType) }
    override fun putFile(key: String, file: File, contentType: String) = checked { store.putFile(key, file, contentType) }
    override fun initiateMultipart(key: String, contentType: String, sha256: String) = checked { store.initiateMultipart(key, contentType, sha256) }
    override fun uploadPart(key: String, uploadId: String, partNumber: Int, file: File, offset: Long, length: Long) =
        checked { store.uploadPart(key, uploadId, partNumber, file, offset, length) }
    override fun listParts(key: String, uploadId: String) = checked { store.listParts(key, uploadId) }
    override fun completeMultipart(key: String, uploadId: String, parts: List<CosPart>) = checked { store.completeMultipart(key, uploadId, parts) }
}
