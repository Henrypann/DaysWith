package com.henrypann.jinbao365.media

import com.henrypann.jinbao365.archive.ImportProvenance
import com.henrypann.jinbao365.archive.ArchiveRecord
import com.henrypann.jinbao365.archive.EditStamp
import com.henrypann.jinbao365.archive.FieldEnvelope
import com.henrypann.jinbao365.archive.MAX_RECORD_MEDIA
import com.henrypann.jinbao365.archive.MediaAsset
import com.henrypann.jinbao365.data.ImportedMedia
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.longOrNull
import java.io.File
import java.util.UUID
import java.util.concurrent.CancellationException

/** Selection order survives deduplication: the first occurrence owns each asset's position. */
data class PreparedImports(val imports: List<PreparedImport>) {
    fun media(deviceId: String, nowMillis: Long): List<ImportedMedia> =
        uniqueImports().map { it.media(deviceId, nowMillis) }

    fun record(deviceId: String, nowMillis: Long): ArchiveRecord {
        requireSelectionSize(imports.size)
        val first = imports.first()
        val capture = imports.map { CaptureTime.atImport(it.capturedAt, nowMillis) }
            .filter { (it["utc"] as? JsonPrimitive)?.longOrNull != null }
            .minByOrNull { it.getValue("utc").jsonPrimitive.long } ?: CaptureTime.unknown()
        val stamp = EditStamp(1, nowMillis, deviceId)
        fun field(value: kotlinx.serialization.json.JsonElement) = FieldEnvelope(value, stamp)
        return ArchiveRecord(
            id = "rec-${UUID.randomUUID()}",
            title = field(JsonPrimitive(first.displayName.ifBlank { "照片" })),
            note = field(JsonPrimitive("")),
            occurredAt = field(CaptureTime.occurredAt(capture, nowMillis)),
            createdAt = field(JsonPrimitive(nowMillis)),
            assetIds = field(JsonArray(uniqueImports().map { JsonPrimitive(it.assetId) })),
            tombstone = field(JsonNull),
            extensions = emptyMap(),
            mediaOverflow = false,
        )
    }

    private fun uniqueImports(): List<PreparedImport> {
        requireSelectionSize(imports.size)
        val byHash = linkedMapOf<String, PreparedImport>()
        imports.forEach { media ->
            val before = byHash[media.original.sha256]
            if (before != null && before.kind != media.kind) {
                throw ImportRejected("同一份原文件的媒体类型不一致，未能保存。")
            }
            byHash.putIfAbsent(media.original.sha256, media)
        }
        return byHash.values.toList()
    }

    fun discardNewFiles(retainedObjectKeys: Set<String>) =
        discardUnreferencedFiles(imports.flatMap { it.createdFiles }.distinct(), retainedObjectKeys)
}

fun PreparedImport.media(deviceId: String, nowMillis: Long): ImportedMedia = ImportedMedia(
    asset = MediaAsset(
        id = assetId,
        kind = kind,
        capturedAt = FieldEnvelope(CaptureTime.atImport(capturedAt, nowMillis), EditStamp(1, nowMillis, deviceId)),
        resourceIds = listOf(original.id, preview.id),
        extensions = mapOf(ImportProvenance.EXTENSION_KEY to FieldEnvelope(JsonPrimitive(provenance.wireValue), EditStamp(1, nowMillis, deviceId))),
        hasLocation = locationInOriginal,
    ),
    resources = listOf(original, preview),
)

internal fun requireSelectionSize(size: Int) {
    if (size !in 1..MAX_RECORD_MEDIA) throw ImportRejected("请选择 1 至 $MAX_RECORD_MEDIA 张照片或视频。")
}

internal fun checkImportCancellation(isCancelled: () -> Boolean) {
    if (isCancelled() || Thread.currentThread().isInterrupted) throw CancellationException("已取消导入。")
}

/** A failed protection read leaves objects in place and does not mask the triggering failure. */
internal fun rollbackPreservingError(error: Exception, cleanup: () -> Unit) {
    try {
        cleanup()
    } catch (cleanupError: Exception) {
        if (cleanupError !== error) error.addSuppressed(cleanupError)
    }
}

internal object MediaImportLocks {
    private val locks = mutableMapOf<String, Any>()
    fun forRoot(root: File): Any = synchronized(locks) {
        locks.getOrPut(root.canonicalPath) { Any() }
    }
}
