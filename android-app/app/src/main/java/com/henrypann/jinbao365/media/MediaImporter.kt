package com.henrypann.jinbao365.media

import com.henrypann.jinbao365.archive.ImportProvenance
import com.henrypann.jinbao365.archive.ArchiveRecord
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.archive.EditStamp
import com.henrypann.jinbao365.archive.FieldEnvelope
import com.henrypann.jinbao365.archive.MediaAsset
import com.henrypann.jinbao365.archive.MediaResource
import com.henrypann.jinbao365.archive.utf8Compare
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.File
import java.io.InputStream
import java.io.FilterInputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

fun interface PreviewEncoder {
    /** A still JPEG. Must not be the original bytes. */
    fun jpegPreview(original: File, kind: String): ByteArray
}

/**
 * Streams selected media without recompression, writes separate still previews, and builds v3 assets.
 * Available original reads are preferred; selected URI fallback records its actual provenance.
 */
class MediaImporter(
    private val root: File,
    private val previewEncoder: PreviewEncoder,
    private val hasLocation: (File, String) -> Boolean,
    private val captureOf: (File, String) -> JsonObject,
) {
    private val importLock = MediaImportLocks.forRoot(root)

    init {
        withImportLock { cleanStaleTemps(root) }
    }

    /** Covers preparation, the database transaction, and rollback across importer instances. */
    internal fun <T> withImportLock(block: () -> T): T = synchronized(importLock, block)

    fun import(
        request: ImportRequest,
        retainedSnapshot: ArchiveSnapshot = ArchiveSnapshot.empty(),
        retainedObjectKeys: () -> Set<String> = { retainedSnapshot.resources.map { it.objectKey }.toSet() },
        isCancelled: () -> Boolean = { false },
    ): PreparedImport = withImportLock {
        prepare(request, retainedObjectKeys, isCancelled)
    }

    /** Streams each selected original in order; duplicate bytes keep their first position. */
    fun importMultiple(
        requests: List<ImportRequest>,
        retainedObjectKeys: () -> Set<String> = { emptySet() },
        onProgress: (completedItems: Int, totalItems: Int) -> Unit = { _, _ -> },
        isCancelled: () -> Boolean = { false },
    ): PreparedImports = withImportLock {
        requireSelectionSize(requests.size)
        val prepared = mutableListOf<PreparedImport>()
        try {
            checkImportCancellation(isCancelled)
            onProgress(0, requests.size)
            requests.forEach { request ->
                prepared += prepare(request, retainedObjectKeys, isCancelled, prepared)
                onProgress(prepared.size, requests.size)
            }
            checkImportCancellation(isCancelled)
            PreparedImports(prepared)
        } catch (error: Exception) {
            rollbackPreservingError(error) {
                discardUnreferencedFiles(prepared.flatMap { it.createdFiles }, retainedObjectKeys())
            }
            throw error
        }
    }

    private fun prepare(
        request: ImportRequest,
        retainedObjectKeys: () -> Set<String>,
        isCancelled: () -> Boolean,
        previous: List<PreparedImport> = emptyList(),
    ): PreparedImport {
        checkImportCancellation(isCancelled)
        var source = ByteSource.GivenFile
        val chosen = if (request.permissionGranted && request.openOriginal != null) {
            try {
                copyToTemp(request.openOriginal, isCancelled, classifySourceFailure = true).also {
                    source = ByteSource.MediaStoreOriginal
                }
            } catch (_: OriginalSourceUnavailable) {
                checkImportCancellation(isCancelled)
                copyToTemp(request.openGiven, isCancelled)
            }
        } else copyToTemp(request.openGiven, isCancelled)
        val provenance = when {
            request.origin == ImportOrigin.Camera -> ImportProvenance.Camera
            source == ByteSource.MediaStoreOriginal -> ImportProvenance.VerifiedOriginal
            request.origin == ImportOrigin.Document -> ImportProvenance.FileSelected
            else -> ImportProvenance.SystemProvided
        }
        val createdFiles = mutableListOf<File>()
        try {
            checkImportCancellation(isCancelled)
            val kind = mediaKind(request.mimeType, chosen.copied.motionPhoto && request.mimeType.startsWith("image/"))
            previous.firstOrNull { it.original.sha256 == chosen.copied.sha256 }?.let {
                if (it.kind != kind) throw ImportRejected("同一份原文件的媒体类型不一致，未能保存。")
                return it.copy(displayName = request.displayName, createdFiles = emptyList())
            }
            val previewBytes = previewEncoder.jpegPreview(chosen.file, kind)
            checkImportCancellation(isCancelled)
            val previewDigest = ContentHash.sha256(previewBytes)
            if (previewDigest.hex == chosen.copied.sha256) {
                throw ImportRejected("预览图生成失败，请重试。")
            }
            val originalPlaced = place(chosen.copied.sha256, chosen.file)
            if (originalPlaced.created) createdFiles += originalPlaced.file
            val previewPlaced = placeBytes(previewDigest.hex, previewBytes)
            if (previewPlaced.created) createdFiles += previewPlaced.file
            val capture = optionalFacts(CaptureTime.unknown()) { captureOf(originalPlaced.file, kind) }
            val located = optionalFacts(false) { hasLocation(originalPlaced.file, kind) }
            val assetId = "asset-${chosen.copied.sha256.take(12)}"
            val original = resource(
                id = "res-${originalRole(kind)}-${chosen.copied.sha256.take(12)}",
                assetId = assetId,
                role = originalRole(kind),
                contentType = request.mimeType.ifBlank { defaultMime(kind) },
                filename = request.displayName,
                digest = chosen.copied,
            )
            val preview = resource(
                // The object is shared by hash, but each resource belongs to one asset.
                id = "res-preview-$assetId-${previewDigest.hex.take(12)}",
                assetId = assetId,
                role = "preview",
                contentType = "image/jpeg",
                filename = "preview.jpg",
                digest = CopiedOriginal(previewDigest.hex, previewDigest.byteCount, false),
            )
            checkImportCancellation(isCancelled)
            return PreparedImport(
                kind = kind,
                provenance = provenance,
                wasDowngraded = provenance == ImportProvenance.SystemProvided || (request.openOriginal != null && source != ByteSource.MediaStoreOriginal),
                assetId = assetId,
                original = original,
                preview = preview,
                capturedAt = capture,
                byteSource = source,
                locationInOriginal = located,
                displayName = request.displayName,
                previewFile = previewPlaced.file,
                createdFiles = createdFiles.toList(),
            )
        } catch (error: Exception) {
            rollbackPreservingError(error) { discardUnreferencedFiles(createdFiles, retainedObjectKeys()) }
            throw error
        } finally {
            chosen.file.delete()
        }
    }

    private fun <T> optionalFacts(unknown: T, read: () -> T): T = try { read() }
        catch (error: java.util.concurrent.CancellationException) { throw error }
        catch (_: Exception) { unknown }

    /** Only opener/read failures may fall back. Target writes, fsync and integrity never do. */
    private fun copyToTemp(open: () -> InputStream, isCancelled: () -> Boolean,
        classifySourceFailure: Boolean = false): TempCopy {
        val temp = safeFile("tmp-${UUID.randomUUID()}")
        temp.parentFile?.mkdirs()
        fun <T> readSource(block: () -> T): T = try {
            checkImportCancellation(isCancelled)
            block()
        } catch (error: java.util.concurrent.CancellationException) { throw error }
          catch (error: Exception) {
            checkImportCancellation(isCancelled)
            if (classifySourceFailure) throw OriginalSourceUnavailable(error)
            throw error
        }
        try {
            val copied = readSource(open).use { input ->
                val cancellable = object : FilterInputStream(input) {
                    override fun read(): Int = readSource { input.read() }
                    override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
                        readSource { input.read(buffer, offset, length) }
                }
                MotionPhotoScanner.copyHashAndScan(cancellable, temp)
            }
            checkImportCancellation(isCancelled)
            if (copied.byteCount <= 0) throw ImportRejected("照片文件为空，未能保存。")
            if (streamHash(temp) != copied.sha256) throw ImportRejected("照片文件校验失败，请重试。")
            return TempCopy(temp, copied)
        } catch (error: Exception) {
            temp.delete()
            throw error
        }
    }

    private fun place(sha256: String, source: File): Placed {
        val dest = safeFile(ContentHash.objectKey(sha256))
        val parent = dest.parentFile ?: root
        parent.mkdirs()
        val existed = dest.isFile
        if (existed && streamHash(dest) == sha256) {
            source.delete()
            return Placed(dest, created = false)
        }
        val staging = safeFile("${ContentHash.objectKey(sha256).substringBeforeLast('/')}/tmp-place-${UUID.randomUUID()}")
        try {
            copyFsync(source, staging)
            if (streamHash(staging) != sha256) {
                throw ImportRejected("原文件复制校验失败，请重试。")
            }
            moveReplacing(staging, dest)
            source.delete()
        } catch (error: Exception) {
            staging.delete()
            source.delete()
            throw error
        }
        return Placed(dest, created = !existed)
    }

    private fun placeBytes(sha256: String, bytes: ByteArray): Placed {
        val dest = safeFile(ContentHash.objectKey(sha256))
        val parent = dest.parentFile ?: root
        parent.mkdirs()
        val existed = dest.isFile
        if (existed && streamHash(dest) == sha256) return Placed(dest, created = false)
        val staging = safeFile("${ContentHash.objectKey(sha256).substringBeforeLast('/')}/tmp-place-${UUID.randomUUID()}")
        try {
            staging.outputStream().use { output ->
                output.write(bytes)
                output.fd.sync()
            }
            if (streamHash(staging) != sha256) {
                throw ImportRejected("预览图校验失败，请重试。")
            }
            moveReplacing(staging, dest)
        } catch (error: Exception) {
            staging.delete()
            throw error
        }
        return Placed(dest, created = !existed)
    }

    /** Candidate keys originate in stored draft metadata; never trust them as arbitrary paths. */
    internal fun discardUnreferencedObjects(candidates: List<MediaResource>, retainedObjectKeys: Set<String>) = withImportLock {
        candidates.distinctBy { it.objectKey }.forEach { resource ->
            if (!Regex("[0-9a-f]{64}").matches(resource.sha256) ||
                resource.objectKey != ContentHash.objectKey(resource.sha256) ||
                resource.objectKey in retainedObjectKeys
            ) return@forEach
            val file = try { safeFile(resource.objectKey) } catch (_: Exception) { return@forEach }
            val matches = try { file.isFile && streamHash(file) == resource.sha256 } catch (_: Exception) { false }
            if (matches) file.delete()
        }
    }

    private fun safeFile(key: String): File {
        val base = root.canonicalFile.toPath()
        val file = File(root, key)
        if (!file.canonicalFile.toPath().startsWith(base) || file.canonicalFile.toPath() == base) {
            throw ImportRejected("照片保存路径异常，请重试。")
        }
        // Even an in-root symlink can alias another object and invalidate rollback ownership.
        var cursor: File? = file
        while (cursor != null && cursor.toPath() != root.toPath()) {
            if (Files.isSymbolicLink(cursor.toPath())) throw ImportRejected("照片保存路径异常，请重试。")
            cursor = cursor.parentFile
        }
        return file
    }

    companion object {
        /** Drops tmp- and tmp-place- files left when a copy was killed. */
        fun cleanStaleTemps(root: File) = synchronized(MediaImportLocks.forRoot(root)) {
            if (!root.isDirectory) return@synchronized
            val base = root.canonicalFile.toPath()
            root.walkTopDown().onEnter { dir ->
                !Files.isSymbolicLink(dir.toPath()) && dir.canonicalFile.toPath().startsWith(base)
            }.forEach { file ->
                if (!Files.isSymbolicLink(file.toPath()) && file.isFile && file.name.startsWith("tmp-")) file.delete()
            }
        }
    }
}

data class ImportRequest(
    val displayName: String,
    val mimeType: String,
    val permissionGranted: Boolean,
    /** Compatibility hint; ImportOrigin identifies the actual entry point. */
    val fromPhotoPicker: Boolean,
    /** May be opened more than once. Each call must return a fresh stream. */
    val openGiven: () -> InputStream,
    /**
     * Photo-picker original, opened with MediaStore.setRequireOriginal.
     * Source read/open failure may fall back to openGiven; target and integrity failures may not.
     */
    val openOriginal: (() -> InputStream)?,
    val locationPermissionGranted: Boolean = true,
    val origin: ImportOrigin = if (fromPhotoPicker) ImportOrigin.PhotoPicker else ImportOrigin.Document,
)

data class PreparedImport(
    val kind: String,
    val assetId: String,
    val original: MediaResource,
    val preview: MediaResource,
    val capturedAt: JsonObject,
    val byteSource: ByteSource,
    val locationInOriginal: Boolean,
    val displayName: String,
    val previewFile: File,
    /** Files this import created. An existing object whose hash matched is not listed. */
    val createdFiles: List<File>,
    val provenance: ImportProvenance = ImportProvenance.Unknown,
    val wasDowngraded: Boolean = false,
) {
    /** Removes only this import's new objects that the retained snapshot does not name. */
    fun discardNewFiles(retainedSnapshot: ArchiveSnapshot = ArchiveSnapshot.empty()) {
        discardUnreferencedFiles(createdFiles, retainedSnapshot)
    }

    /** A duplicate, successful save, or failed save retains a different set of objects. */
    fun saveToArchive(
        snapshot: ArchiveSnapshot,
        deviceId: String,
        nowMillis: Long,
        saveSnapshot: (ArchiveSnapshot) -> Unit,
    ): ArchiveSnapshot {
        val updated = try {
            snapshotWithImport(snapshot, deviceId, nowMillis, this).also {
                if (it !== snapshot) saveSnapshot(it)
            }
        } catch (error: Exception) {
            discardNewFiles(snapshot)
            throw error
        }
        discardNewFiles(updated)
        return updated
    }
}

private fun discardUnreferencedFiles(files: List<File>, retainedSnapshot: ArchiveSnapshot) =
    discardUnreferencedFiles(files, retainedSnapshot.resources.map { it.objectKey }.toSet())

internal fun discardUnreferencedFiles(files: List<File>, retainedKeys: Set<String>) {
    files.forEach { file ->
        if (retainedKeys.none { file.toPath().endsWith(it) }) file.delete()
    }
}

private class OriginalSourceUnavailable(cause: Exception) : java.io.IOException(cause)

private data class TempCopy(val file: File, val copied: CopiedOriginal)

private data class Placed(val file: File, val created: Boolean)

private fun copyFsync(source: File, dest: File) {
    source.inputStream().use { input ->
        dest.outputStream().use { output ->
            input.copyTo(output, ContentHash.BUFFER_SIZE)
            output.fd.sync()
        }
    }
}

private fun moveReplacing(source: File, dest: File) {
    Files.move(
        source.toPath(),
        dest.toPath(),
        StandardCopyOption.ATOMIC_MOVE,
        StandardCopyOption.REPLACE_EXISTING,
    )
}

private fun streamHash(file: File): String = file.inputStream().use { ContentHash.sha256(it).hex }

fun mediaKind(mimeType: String, motionPhoto: Boolean): String = when {
    motionPhoto -> "motionPhoto"
    mimeType.startsWith("video/") -> "video"
    else -> "photo"
}

fun originalRole(kind: String): String = when (kind) {
    "motionPhoto" -> "motionPhoto"
    "video" -> "video"
    else -> "photo"
}

private fun defaultMime(kind: String): String = when (kind) {
    "video" -> "video/mp4"
    else -> "image/jpeg"
}

private fun resource(
    id: String,
    assetId: String,
    role: String,
    contentType: String,
    filename: String,
    digest: CopiedOriginal,
): MediaResource = MediaResource(
    id = id,
    assetID = assetId,
    role = role,
    contentType = contentType,
    originalFilename = filename.ifBlank { "import" },
    byteCount = digest.byteCount,
    sha256 = digest.sha256,
    objectKey = ContentHash.objectKey(digest.sha256),
    extensions = emptyMap(),
)

fun snapshotWithImport(
    snapshot: ArchiveSnapshot,
    deviceId: String,
    nowMillis: Long,
    imported: PreparedImport,
): ArchiveSnapshot {
    val sha = imported.original.sha256
    val existingAssetId = snapshot.resources.firstOrNull { it.sha256 == sha && it.role != "preview" }?.assetID
    if (existingAssetId != null) {
        val referenced = snapshot.records.filter { existingAssetId in assetIdsOf(it) }
        val live = referenced.any { it.tombstone.value is JsonNull }
        if (live) return snapshot
        val record = newRecord(
            id = nextRecordId(snapshot, sha, referenced.size),
            assetId = existingAssetId,
            imported = imported,
            deviceId = deviceId,
            nowMillis = nowMillis,
        )
        return snapshot.copy(
            records = (snapshot.records + record).sortedWith { left, right -> utf8Compare(left.id, right.id) },
        )
    }
    val stamp = EditStamp(counter = 1, at = nowMillis, deviceID = deviceId)
    val asset = MediaAsset(
        id = imported.assetId,
        kind = imported.kind,
        capturedAt = FieldEnvelope(CaptureTime.atImport(imported.capturedAt, nowMillis), stamp),
        resourceIds = listOf(imported.original.id, imported.preview.id),
        extensions = mapOf(ImportProvenance.EXTENSION_KEY to FieldEnvelope(JsonPrimitive(imported.provenance.wireValue), stamp)),
        hasLocation = imported.locationInOriginal,
    )
    val record = newRecord(nextRecordId(snapshot, sha, 0), imported.assetId, imported, deviceId, nowMillis)
    return snapshot.copy(
        records = (snapshot.records + record).sortedWith { left, right -> utf8Compare(left.id, right.id) },
        assets = (snapshot.assets + asset).sortedWith { left, right -> utf8Compare(left.id, right.id) },
        resources = (snapshot.resources + imported.original + imported.preview)
            .sortedWith { left, right -> utf8Compare(left.id, right.id) },
    )
}

private fun newRecord(
    id: String,
    assetId: String,
    imported: PreparedImport,
    deviceId: String,
    nowMillis: Long,
): ArchiveRecord {
    val stamp = EditStamp(counter = 1, at = nowMillis, deviceID = deviceId)
    fun text(value: String) = FieldEnvelope(JsonPrimitive(value), stamp)
    return ArchiveRecord(
        id = id,
        title = text(imported.displayName.ifBlank { "照片" }),
        note = text(""),
        occurredAt = FieldEnvelope(CaptureTime.occurredAt(CaptureTime.atImport(imported.capturedAt, nowMillis), nowMillis), stamp),
        createdAt = FieldEnvelope(JsonPrimitive(nowMillis), stamp),
        assetIds = FieldEnvelope(JsonArray(listOf(JsonPrimitive(assetId))), stamp),
        tombstone = FieldEnvelope(JsonNull, stamp),
        extensions = emptyMap(),
        mediaOverflow = false,
    )
}

private fun nextRecordId(snapshot: ArchiveSnapshot, sha: String, referenced: Int): String {
    val base = "rec-${sha.take(12)}"
    if (snapshot.records.none { it.id == base }) return base
    return "$base-${referenced + 1}"
}

private fun assetIdsOf(record: ArchiveRecord): Set<String> {
    val array = record.assetIds.value as? JsonArray ?: return emptySet()
    return array.mapNotNull { element ->
        (element as? JsonPrimitive)?.takeIf { it.isString }?.content
    }.toSet()
}
