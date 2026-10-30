package com.henrypann.jinbao365.backup

import android.content.Context
import android.system.Os
import android.system.OsConstants
import com.henrypann.jinbao365.storage.StorageConfiguration
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable enum class BackupObjectStatus { pending, uploading, verifying, verified, failed }
@Serializable data class BackupObjectState(
    val status: BackupObjectStatus = BackupObjectStatus.pending,
    val lastError: String? = null,
    val attempts: Int = 0,
    val firstQueuedAt: Long,
)
@Serializable data class BackupMultipart(val uploadId: String, val parts: List<CosPart> = emptyList())
/** Base64 stores the exact frozen bytes, including their original requestID. */
@Serializable data class BackupPending(val manifestBytes: String, val commitBytes: String, val sourcePaths: Map<String, String>)
/** Exact immutable writer registration, published by backup only after local restoration commits. */
@Serializable data class BackupTakeover(val writerDeviceId: String, val commitBytes: String)
@Serializable data class BackupReceipt(
    val sequence: Long, val commitHash: String, val manifestHash: String, val publishedAt: Long,
    val coveredObjectKeys: Set<String>,
    val coveredMomentHashes: Map<String, String>,
    /** Newest edit in the exact read-back-verified commit; absent legacy receipts prove no coverage. */
    val packedThrough: Long? = null,
)
@Serializable data class BackupState(
    val version: Int = 1,
    val bucket: String,
    val prefix: String,
    val objects: Map<String, BackupObjectState> = emptyMap(),
    val multipart: Map<String, BackupMultipart> = emptyMap(),
    val pending: BackupPending? = null,
    val receipt: BackupReceipt? = null,
    val takeover: BackupTakeover? = null,
    val lastSuccessfulBackupAt: Long? = null,
    /** Last resource upload accepted only after full byte-count and SHA-256 read-back verification. */
    val lastUploadAtMillis: Long? = null,
    val stage: String = "idle",
    val lastError: String? = null,
    val paused: Boolean = true,
)

interface BackupStatePersistence {
    fun load(): BackupState?
    fun save(state: BackupState)
    /** Roll back an uncommitted takeover, including a previously absent receipt. */
    fun restore(previous: BackupState?) { if (previous != null) save(previous) else error("State removal is unsupported") }
    /** Holds the lease for the entire run, including remote I/O. */
    fun <T> exclusive(block: () -> T): T = synchronized(this) { block() }
}

/** Separate from Room and Android backup; only non-secret transfer bookkeeping is stored. */
class BackupStateStore(
    private val directory: File,
    private val syncDirectory: (File) -> Unit = { folder ->
        FileChannel.open(folder.toPath(), StandardOpenOption.READ).use { it.force(true) }
    },
) : BackupStatePersistence {
    constructor(context: Context) : this(File(context.noBackupFilesDir, "backup"), { folder ->
        val fd = Os.open(folder.path, OsConstants.O_RDONLY, 0)
        try { Os.fsync(fd) } finally { Os.close(fd) }
    })

    private val file get() = File(directory, "state.json")
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }

    private fun ensureDirectory() {
        if (!directory.isDirectory) {
            if (!directory.mkdirs() && !directory.isDirectory) throw IOException("Backup state could not be saved.")
            directory.parentFile?.let(syncDirectory)
        }
    }

    @Synchronized override fun load(): BackupState? {
        if (!file.exists()) return null
        // Corruption is fail-closed. Never turn an unreadable receipt into a fresh archive.
        try {
            require(file.length() <= 128L * 1024 * 1024)
            return json.decodeFromString<BackupState>(file.readText(Charsets.UTF_8)).also {
                require(it.version == 1)
                StorageConfiguration(bucket = it.bucket, prefix = it.prefix).validate()
            }
        } catch (_: Exception) { throw IOException("无法读取备份进度，请保留本机原件后重试。") }
    }

    @Synchronized override fun save(state: BackupState) {
        ensureDirectory()
        val bytes = json.encodeToString(state).toByteArray(Charsets.UTF_8)
        require(bytes.size <= 128 * 1024 * 1024)
        val temporary = File(directory, "state.json.new")
        try {
            FileOutputStream(temporary).use { stream -> stream.write(bytes); stream.fd.sync() }
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            check(file.isFile && file.length() == bytes.size.toLong() && file.readBytes().contentEquals(bytes))
            syncDirectory(directory)
        } finally { temporary.delete() }
    }

    @Synchronized override fun restore(previous: BackupState?) {
        if (previous != null) save(previous) else if (file.exists()) {
            if (!file.delete()) throw IOException("Cannot roll back backup state")
            syncDirectory(directory)
        }
    }

    override fun <T> exclusive(block: () -> T): T = synchronized(this) {
        ensureDirectory()
        FileChannel.open(File(directory, "run.lock").toPath(), StandardOpenOption.CREATE, StandardOpenOption.WRITE).use { channel ->
            val lock = try { channel.tryLock() } catch (_: java.nio.channels.OverlappingFileLockException) { null }
            if (lock == null) throw IllegalStateException("A backup is already running.")
            lock.use { block() }
        }
    }
}
