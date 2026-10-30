package com.henrypann.jinbao365.viewing

import com.henrypann.jinbao365.backup.BackupCancellation
import com.henrypann.jinbao365.backup.CosDownload
import com.henrypann.jinbao365.backup.CosObjectInfo
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.media.ContentHash
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream
import java.util.concurrent.CancellationException
import java.util.concurrent.ConcurrentHashMap

internal enum class OriginalNetwork { Unmetered, Metered, Offline }

internal enum class DownloadPermission { Proceed, Ask, Fail }

/** Metered downloads wait for this session's confirmation unless the separate switch is on. */
internal fun downloadPermission(
    network: OriginalNetwork,
    allowCellular: Boolean,
    confirmed: Boolean,
): DownloadPermission = when (network) {
    OriginalNetwork.Unmetered -> DownloadPermission.Proceed
    OriginalNetwork.Offline -> DownloadPermission.Fail
    OriginalNetwork.Metered -> if (allowCellular || confirmed) DownloadPermission.Proceed else DownloadPermission.Ask
}

internal data class OriginalRequest(
    val partner: ParentIdentity,
    val sha256: String,
    val byteCount: Long,
)

internal sealed class PartnerOriginalResult {
    /** [file] is the verified original. Only this state may replace the thumbnail. */
    data class Ready(val file: File, val cacheHit: Boolean) : PartnerOriginalResult()
    data object NeedsConfirmation : PartnerOriginalResult()
    data object Failed : PartnerOriginalResult()
}

internal fun visibleOriginal(result: PartnerOriginalResult): File? =
    (result as? PartnerOriginalResult.Ready)?.file

/**
 * Read-only object bytes. Implementations must not mint a shareable URL or expose credentials.
 * The viewer receives a local file, never a transport address.
 */
internal interface OriginalObjectSource {
    fun head(key: String): CosObjectInfo?
    fun download(key: String, output: OutputStream): CosDownload
}

internal data class ViewerEntry(
    val assetId: String,
    val kind: String,
    val partner: ParentIdentity?,
    val sha256: String?,
    val byteCount: Long?,
    val thumbnailRelative: String?,
    val localRelative: String?,
)

internal val ViewerEntry.downloadsOriginal: Boolean
    get() = partner != null && sha256 != null && byteCount != null && byteCount > 0 &&
        sha256.matches(SHA256)

/** Visible partner original, plus at most the next partner photo. Videos are never prefetched. */
internal data class DownloadPlan(val visibleId: String?, val prefetchId: String?)

internal fun downloadPlan(entries: List<ViewerEntry>, index: Int): DownloadPlan {
    if (index !in entries.indices) return DownloadPlan(null, null)
    val visible = entries[index].takeIf { it.downloadsOriginal }?.assetId
    val prefetch = entries.getOrNull(index + 1)?.takeIf { it.downloadsOriginal && it.kind != "video" }?.assetId
    return DownloadPlan(visible, prefetch)
}

internal fun partnerIdentityOf(recordId: String): ParentIdentity? {
    val folder = recordId.removePrefix("remote:").substringBefore(':')
    if (folder.isEmpty() || folder == recordId) return null
    return ParentIdentity.entries.firstOrNull { it.folder == folder }
}

internal fun partnerObjectKey(partner: ParentIdentity, sha256: String): String? {
    if (!sha256.matches(SHA256)) return null
    return "${partner.prefix}objects/${sha256.take(2)}/$sha256"
}

internal fun partnerCacheRelative(partner: ParentIdentity, sha256: String): String? {
    if (!sha256.matches(SHA256)) return null
    return "remote/${partner.folder}/objects/${sha256.take(2)}/$sha256"
}

internal fun archiveFile(root: File, relative: String): File? = runCatching {
    if (relative.isBlank() || relative.startsWith("/") || "\\" in relative) return null
    val directory = root.canonicalFile
    val file = File(directory, relative).canonicalFile
    if (!file.path.startsWith(directory.path + File.separator)) null else file
}.getOrNull()

private val SHA256 = Regex("[a-f0-9]{64}")

internal fun fileMatches(file: File, byteCount: Long, sha256: String): Boolean {
    if (!file.isFile || byteCount <= 0 || !sha256.matches(SHA256) || file.length() != byteCount) return false
    val digest = runCatching { file.inputStream().use { ContentHash.sha256(it) } }.getOrNull() ?: return false
    return digest.byteCount == byteCount && digest.hex == sha256
}

/**
 * Replace the thumbnail only when the file on disk, the object size, and x-cos-meta-sha256
 * all name the original this archive already recorded.
 */
internal fun acceptDownloadedOriginal(
    fileBytes: Long,
    fileSha256: String,
    reportedBytes: Long,
    headerSha256: String?,
    expectedBytes: Long,
    expectedSha256: String,
): Boolean {
    val header = headerSha256?.lowercase()
    if (header == null || !header.matches(SHA256)) return false
    if (!expectedSha256.matches(SHA256) || expectedBytes <= 0 || fileBytes <= 0) return false
    if (fileBytes != reportedBytes || fileBytes != expectedBytes) return false
    return fileSha256 == header && fileSha256 == expectedSha256
}

internal class PartnerOriginalDownloader(
    private val mediaRoot: File,
    private val network: () -> OriginalNetwork,
    private val open: (ParentIdentity, BackupCancellation) -> OriginalObjectSource?,
) {
    private val locks = ConcurrentHashMap<String, Any>()

    fun cacheFile(request: OriginalRequest): File? {
        val relative = partnerCacheRelative(request.partner, request.sha256) ?: return null
        return archiveFile(mediaRoot, relative)
    }

    fun fetch(
        request: OriginalRequest,
        allowCellular: Boolean,
        confirmed: Boolean,
        cancellation: BackupCancellation = BackupCancellation(),
    ): PartnerOriginalResult {
        val key = partnerObjectKey(request.partner, request.sha256) ?: return PartnerOriginalResult.Failed
        if (!key.startsWith(request.partner.prefix) || "://" in key) return PartnerOriginalResult.Failed
        val destination = cacheFile(request) ?: return PartnerOriginalResult.Failed
        val lock = locks.computeIfAbsent(key) { Any() }
        synchronized(lock) {
            cancellation.check()
            if (fileMatches(destination, request.byteCount, request.sha256)) {
                return PartnerOriginalResult.Ready(destination, cacheHit = true)
            }
            when (downloadPermission(network(), allowCellular, confirmed)) {
                DownloadPermission.Ask -> return PartnerOriginalResult.NeedsConfirmation
                DownloadPermission.Fail -> return PartnerOriginalResult.Failed
                DownloadPermission.Proceed -> Unit
            }
            val source = try {
                open(request.partner, cancellation)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                null
            } ?: return PartnerOriginalResult.Failed
            return writeVerified(source, key, destination, request, cancellation)
        }
    }

    private fun writeVerified(
        source: OriginalObjectSource,
        key: String,
        destination: File,
        request: OriginalRequest,
        cancellation: BackupCancellation,
    ): PartnerOriginalResult {
        val head = try {
            cancellation.check()
            source.head(key)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return PartnerOriginalResult.Failed
        } ?: return PartnerOriginalResult.Failed
        destination.parentFile?.mkdirs()
        val temporary = File.createTempFile("original-", ".partial", destination.parentFile)
        try {
            cancellation.check()
            FileOutputStream(temporary).use { output ->
                source.download(key, output)
                output.flush()
                runCatching { output.fd.sync() }
            }
            cancellation.check()
            val digest = temporary.inputStream().use { ContentHash.sha256(it) }
            // The hash reported by the transport is ignored. The file and object metadata decide.
            val accepted = acceptDownloadedOriginal(
                fileBytes = digest.byteCount,
                fileSha256 = digest.hex,
                reportedBytes = head.byteCount,
                headerSha256 = head.sha256,
                expectedBytes = request.byteCount,
                expectedSha256 = request.sha256,
            )
            if (!accepted) return PartnerOriginalResult.Failed
            if (destination.exists() && !destination.delete()) return PartnerOriginalResult.Failed
            if (!temporary.renameTo(destination)) return PartnerOriginalResult.Failed
            if (!fileMatches(destination, request.byteCount, request.sha256)) {
                destination.delete()
                return PartnerOriginalResult.Failed
            }
            return PartnerOriginalResult.Ready(destination, cacheHit = false)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return PartnerOriginalResult.Failed
        } finally {
            temporary.delete()
        }
    }
}
