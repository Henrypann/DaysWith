package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.data.Anniversary
import com.henrypann.jinbao365.archive.MediaResource
import com.henrypann.jinbao365.storage.StorageConfiguration
import java.util.Base64
import java.util.Collections
import java.util.Locale
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.longOrNull

enum class BackupRecordStatus { BackedUp, Pending, Failed, LocalOnly }

/** Immutable result shared by Timeline, record detail and Cloud storage. */
class BackupSummary(
    val unbackedOriginalCount: Int = 0,
    val unbackedRecordCount: Int = 0,
    val overdueOriginalCount: Int = 0,
    val hasOverdue: Boolean = false,
    val lastUploadAtMillis: Long? = null,
    val lastCommitAtMillis: Long? = null,
    val packedThroughMillis: Long? = null,
    val paused: Boolean = true,
    val blockReason: BackupBlockReason? = BackupBlockReason.Connection,
    val failedCount: Int = 0,
    val inProgress: Boolean = false,
    val progress: BackupProgress? = null,
    val allCovered: Boolean = false,
    val canBackUpNow: Boolean = false,
    val canPause: Boolean = false,
    val canRetryFailed: Boolean = false,
    recordStatuses: Map<String, BackupRecordStatus> = emptyMap(),
    recordPresentations: Map<String, RecordBackupPresentation> = emptyMap(),
    overdueRecordIds: Set<String> = emptySet(),
    queue: List<BackupQueueEntry> = emptyList(),
) {
    private val statuses = Collections.unmodifiableMap(recordStatuses.toMap())
    internal val records: Map<String, RecordBackupPresentation> = Collections.unmodifiableMap(recordPresentations.toMap())
    internal val queue: List<BackupQueueEntry> = Collections.unmodifiableList(queue.toList())
    val overdueRecordIds: Set<String> = Collections.unmodifiableSet(overdueRecordIds.toSet())

    fun recordStatus(recordId: String): BackupRecordStatus = statuses[recordId] ?: BackupRecordStatus.LocalOnly

    val hasFailure: Boolean = failedCount > 0 || blockReason in setOf(BackupBlockReason.Failed, BackupBlockReason.State)
    val statusLine: String = when {
        inProgress -> "正在备份…"
        blockReason == BackupBlockReason.Loading -> BackupBlockReason.Loading.text
        blockReason == BackupBlockReason.State -> BackupPolicy.RETRY_MESSAGE
        blockReason == BackupBlockReason.Connection -> "尚未连接"
        blockReason == BackupBlockReason.ReadOnly -> "仅可查看"
        blockReason == BackupBlockReason.Credentials -> "请检查云存储凭据"
        blockReason == BackupBlockReason.Metered -> BackupPolicy.WIFI_WAITING
        blockReason == BackupBlockReason.Offline -> "等待网络"
        paused || blockReason == BackupBlockReason.Paused -> if (lastCommitAtMillis == null)
            "已暂停，点击立即备份开始" else "已暂停"
        hasFailure -> BackupPolicy.RETRY_MESSAGE
        allCovered -> "已备份"
        blockReason == BackupBlockReason.Background -> BackupBlockReason.Background.text
        else -> "尚未备份"
    }
}

/**
 * The sole archive-coverage query for UI. No I/O, clock reads or mutation occur here.
 * With no coordinator, the persisted state's destination supplies the connection binding.
 * Supply a coordinator snapshot to include its current destination, Wi-Fi and execution gates.
 */
interface BackupStatusQuery {
    fun query(
        snapshot: ArchiveSnapshot,
        state: BackupState?,
        now: Long,
        coordinator: BackupCoordinatorState? = null,
        anniversaries: List<Anniversary> = emptyList(),
    ): BackupSummary
}

class DefaultBackupStatusQuery : BackupStatusQuery {
    override fun query(snapshot: ArchiveSnapshot, state: BackupState?, now: Long, coordinator: BackupCoordinatorState?, anniversaries: List<Anniversary>): BackupSummary {
        val configuration = if (coordinator != null) coordinator.configuration else state?.let {
            StorageConfiguration(bucket = it.bucket, prefix = it.prefix)
        }
        val current = state?.takeIf { configuration != null && it.bucket == configuration.bucket && it.prefix == configuration.prefix }
        val prefix = configuration?.prefix ?: StorageConfiguration().prefix
        val running = coordinator?.running == true
        val paused = coordinator?.paused ?: current?.paused ?: true
        val receipt = current?.receipt
        val mapped = runCatching { V1Mapper.map(snapshot, prefix, anniversaries) }
        val momentHashes = mapped.getOrNull()?.let { BackupEngine.momentHashes(it) }.orEmpty()
        val pending = current?.pending?.let {
            runCatching { V1Json.decodeManifest(Base64.getDecoder().decode(it.manifestBytes)) }.getOrNull()
        }
        val resourcesByAsset = snapshot.resources.groupBy { it.assetID }
        val liveRecords = snapshot.records.filter { it.tombstone.isNullValue() }
        val recordPresentations = mutableMapOf<String, RecordBackupPresentation>()
        val recordStatuses = mutableMapOf<String, BackupRecordStatus>()
        val overdueRecords = mutableSetOf<String>()
        val unbackedKeys = mutableSetOf<String>()
        val overdueKeys = mutableSetOf<String>()
        val error = (coordinator?.lastError ?: current?.lastError)?.takeUnless { it in EXPECTED_BACKUP_STOPS }
        val readOnly = coordinator?.blockReason == BackupBlockReason.ReadOnly ||
            error == BackupFailure.OtherWriter.text || current?.lastError == BackupFailure.ReadOnly.text
        val failedPublication = current?.stage == "failed" && error != null &&
            pending?.resources.orEmpty().none { current.objects[it.objectKey]?.status == BackupObjectStatus.failed }

        fun metadataCovered(updatedAt: Long?, id: String, hashes: Map<String, String>, coveredHashes: Map<String, String>?): Boolean =
            updatedAt != null && receipt?.packedThrough?.let { it >= updatedAt } == true &&
                hashes[id]?.let { it == coveredHashes?.get(id) } == true

        fun verified(resource: MediaResource): Boolean {
            val key = resource.backupKey(prefix)
            return current?.objects?.get(key)?.status == BackupObjectStatus.verified && key in receipt?.coveredObjectKeys.orEmpty()
        }

        fun countOriginals(resources: List<MediaResource>, metadataCovered: Boolean, createdAt: Long?) {
            resources.filter { it.role != "preview" }.forEach { resource ->
                if (!metadataCovered || !verified(resource)) {
                    val key = resource.backupKey(prefix)
                    unbackedKeys += key
                    if (isOverdue(createdAt, now)) overdueKeys += key
                }
            }
        }

        liveRecords.forEach { record ->
            val id = V1Ids.map("record", record.id)
            val updatedAt = runCatching { V1Mapper.updatedAt(record) }.getOrNull()
            val metadata = metadataCovered(updatedAt, id, momentHashes, receipt?.coveredMomentHashes)
            val assets = record.assetIds.value.stringValues()
            val originals = assets.flatMap { resourcesByAsset[it].orEmpty() }.filter { it.role != "preview" }
            val associatedResources = assets
                .distinct().flatMap { resourcesByAsset[it].orEmpty() }
            val backedUp = metadata && associatedResources.all(::verified)
            val oldOriginals = isOverdue(record.createdAt.value.timestamp(), now) && originals.any { !metadata || !verified(it) }
            val overdue = oldOriginals || (!metadata && isOverdue(updatedAt, now))
            countOriginals(originals, metadata, record.createdAt.value.timestamp())
            if (overdue) overdueRecords += record.id
            val objects = associatedResources.mapNotNull { current?.objects?.get(it.backupKey(prefix)) }
            val objectFailure = objects.firstOrNull { it.status == BackupObjectStatus.failed && it.lastError !in EXPECTED_BACKUP_STOPS }
            val publicationFailure = failedPublication && (mapped.isFailure || pending == null || pending.moments.any { it.id == id })
            val failure = when {
                backedUp -> null
                objectFailure != null -> "有一项备份没成功，点这里重试"
                publicationFailure -> "有一项备份没成功，点这里重试"
                else -> null
            }
            val badge = when {
                backedUp -> ArchiveBackupBadge.None
                failure != null -> ArchiveBackupBadge.Failed
                running && objects.any { it.status in ACTIVE_BACKUP_TRANSFERS } -> ArchiveBackupBadge.Uploading
                overdue -> ArchiveBackupBadge.Overdue
                else -> ArchiveBackupBadge.None
            }
            recordPresentations[record.id] = RecordBackupPresentation(badge, backedUp, failure)
            recordStatuses[record.id] = when {
                backedUp -> BackupRecordStatus.BackedUp
                configuration == null || readOnly -> BackupRecordStatus.LocalOnly
                failure != null -> BackupRecordStatus.Failed
                else -> BackupRecordStatus.Pending
            }
        }
        // Preserve frozen and historical queue entries so a failed publication remains retryable.
        val usedAssets = liveRecords.flatMap { it.assetIds.value.stringValues() }.toSet()
        val localByKey = snapshot.resources.filter { it.assetID in usedAssets }.associateBy { it.backupKey(prefix) }
        val frozenByKey = pending?.resources?.associateBy { it.objectKey }.orEmpty()
        val queue = (localByKey.keys + frozenByKey.keys + current?.objects.orEmpty().keys).map { key ->
            val objectState = current?.objects?.get(key)
            val status = objectState?.status ?: BackupObjectStatus.pending
            BackupQueueEntry(key,
                localByKey[key]?.originalFilename ?: frozenByKey[key]?.originalFilename ?: key.substringAfterLast('/'),
                localByKey[key]?.byteCount ?: frozenByKey[key]?.byteCount,
                if ((!running && status in ACTIVE_BACKUP_TRANSFERS) || objectState?.lastError in EXPECTED_BACKUP_STOPS)
                    BackupObjectStatus.pending else status,
                objectState?.lastError?.takeUnless { it in EXPECTED_BACKUP_STOPS }?.let { "有一项备份没成功，点这里重试" }, objectState?.attempts ?: 0)
        }.sortedWith(compareBy<BackupQueueEntry> { BACKUP_QUEUE_ORDER.getValue(it.status) }.thenBy { it.objectKey })
        val failedCount = queue.count { it.status == BackupObjectStatus.failed }.let {
            if (error != null && it == 0) 1 else it
        }
        val blockReason = when {
            readOnly -> BackupBlockReason.ReadOnly
            coordinator?.blockReason != null && coordinator.blockReason != BackupBlockReason.Running -> coordinator.blockReason
            configuration == null -> BackupBlockReason.Connection
            paused -> BackupBlockReason.Paused
            current?.lastError == BackupFailure.Wifi.text -> BackupBlockReason.Metered
            current?.lastError == BackupFailure.Offline.text -> BackupBlockReason.Offline
            current?.lastError == BackupFailure.Connection.text -> BackupBlockReason.Connection
            current?.lastError == BackupFailure.Credentials.text -> BackupBlockReason.Credentials
            failedCount > 0 -> BackupBlockReason.Failed
            else -> null
        }
        val unbackedRecords = recordStatuses.values.count { it != BackupRecordStatus.BackedUp }
        return BackupSummary(
            unbackedOriginalCount = unbackedKeys.size, unbackedRecordCount = unbackedRecords,
            overdueOriginalCount = overdueKeys.size,
            hasOverdue = overdueKeys.isNotEmpty() || overdueRecords.isNotEmpty(),
            lastUploadAtMillis = current?.lastUploadAtMillis, lastCommitAtMillis = receipt?.publishedAt,
            packedThroughMillis = receipt?.packedThrough, paused = paused, blockReason = blockReason,
            failedCount = failedCount, inProgress = running, progress = coordinator?.progress,
            allCovered = receipt != null && unbackedRecords == 0 && mapped.getOrNull()?.let {
                V1Json.sha256(V1Json.encodeManifest(it)) == receipt.manifestHash
            } == true,
            canBackUpNow = (coordinator?.canBackUpNow ?: (configuration != null)) && !running && blockReason !in MANUAL_BACKUP_BLOCKS,
            canPause = configuration != null && !paused,
            canRetryFailed = failedCount > 0 && !running && !paused && blockReason !in MANUAL_BACKUP_BLOCKS,
            recordStatuses = recordStatuses, recordPresentations = recordPresentations,
            overdueRecordIds = overdueRecords, queue = queue,
        )
    }
}

private fun MediaResource.backupKey(prefix: String): String {
    val hash = sha256.lowercase(Locale.ROOT)
    return V1Layout.objectKey(prefix, hash)
}
private fun JsonElement.stringValue(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
private fun JsonElement.stringValues(): List<String> = (this as? JsonArray).orEmpty().mapNotNull { it.stringValue() }
private fun JsonElement.timestamp(): Long? = (this as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull
private fun isOverdue(at: Long?, now: Long): Boolean = at != null && now > at && now - at > BackupEngine.DAY_MILLIS
private val ACTIVE_BACKUP_TRANSFERS = setOf(BackupObjectStatus.uploading, BackupObjectStatus.verifying)
private val EXPECTED_BACKUP_STOPS = setOf(
    BackupFailure.Connection.text, BackupFailure.Credentials.text, BackupFailure.Wifi.text, BackupFailure.Offline.text,
    BackupFailure.Paused.text, BackupFailure.ReadOnly.text, "联网并打开应用后继续备份。",
)
private val MANUAL_BACKUP_BLOCKS = setOf(
    BackupBlockReason.Connection, BackupBlockReason.Credentials, BackupBlockReason.ReadOnly,
    BackupBlockReason.Offline, BackupBlockReason.Metered, BackupBlockReason.State,
    BackupBlockReason.Loading, BackupBlockReason.Background,
)
private val BACKUP_QUEUE_ORDER = mapOf(
    BackupObjectStatus.uploading to 0, BackupObjectStatus.verifying to 1, BackupObjectStatus.failed to 2,
    BackupObjectStatus.pending to 3, BackupObjectStatus.verified to 4,
)
