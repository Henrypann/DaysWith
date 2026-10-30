package com.henrypann.jinbao365.data

import com.henrypann.jinbao365.editing.*
import com.henrypann.jinbao365.archive.importProvenance
import com.henrypann.jinbao365.archive.ImportProvenance
import com.henrypann.jinbao365.archive.MediaAsset
import com.henrypann.jinbao365.archive.MediaResource
import com.henrypann.jinbao365.archive.MAX_RECORD_MEDIA
import com.henrypann.jinbao365.archive.hasRecordText
import com.henrypann.jinbao365.archive.ArchiveEdits
import com.henrypann.jinbao365.archive.ArchiveJson
import com.henrypann.jinbao365.archive.ArchiveRecord
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.archive.ArchiveValidationException
import com.henrypann.jinbao365.archive.canonicalJson
import com.henrypann.jinbao365.archive.sortedObject
import com.henrypann.jinbao365.archive.utf8Compare
import com.henrypann.jinbao365.media.isAfterCaptureFloor
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * Local v3 archive plus local-only drafts. Commands read, check the resync gate,
 * calculate changes and write under one Room transaction. Call off the main thread.
 * UI editors use [editRecord], [updateDraft] passing their loaded
 * expected record or draft revision when submitting a previously displayed form.
 */
class ArchiveRepository(
    private val database: ArchiveDatabase,
    private val deviceMetadata: () -> Pair<String, String>? = { null },
    private val parentIdentity: (() -> ParentIdentity?)? = null,
) {
    private fun <T> transaction(block: () -> T): T = database.runInTransaction(java.util.concurrent.Callable { block() })

    fun loadSnapshot(): ArchiveSnapshot = transaction { readSnapshot() }

    fun loadAnniversaries(): List<Anniversary> = transaction { database.archiveDao().anniversaries().map { it.model() } }

    /** A cache from another account/destination must never appear as this connection's family data. */
    fun loadVisibleAnniversaries(owner: ParentIdentity, source: AnniversarySource?): List<Anniversary> = transaction {
        database.archiveDao().anniversaries().filter {
            it.owner == owner.folder || source != null && it.sourceBucket == source.bucket && it.sourceRegion == source.region
        }.map { it.model() }
    }

    fun saveAnniversary(owner: ParentIdentity, id: String?, title: String, date: java.time.LocalDate): Anniversary = transaction {
        rejectEditsDuringResync()
        requireLocalParent(owner)
        require(title.trim().isNotEmpty() && title.trim().length <= 100) { "请输入不超过100字的纪念日标题。" }
        require(date.year in 1..9999) { "请选择有效日期。" }
        if (id != null) {
            val existing = database.archiveDao().anniversary(owner.folder, id)?.model()
            require(existing != null && existing.deletedAt == null ||
                existing == null && DefaultAnniversaries.isDefault(id)) { "只能编辑自己添加的纪念日。" }
        }
        Anniversary(id ?: java.util.UUID.randomUUID().toString().uppercase(java.util.Locale.ROOT), owner, title.trim(), date)
            .also { database.archiveDao().insertAnniversaries(listOf(it.entity())) }
    }

    fun deleteAnniversary(owner: ParentIdentity, id: String, now: Long) = transaction {
        rejectEditsDuringResync()
        requireLocalParent(owner)
        require(now >= 0)
        val existing = database.archiveDao().anniversary(owner.folder, id)?.model()
            ?: DefaultAnniversaries.all.firstOrNull { it.id.equals(id, ignoreCase = true) }
                ?.let { Anniversary(it.id, owner, it.title, it.date) }
            ?: throw ArchiveValidationException("只能删除自己添加的纪念日。")
        database.archiveDao().insertAnniversaries(listOf(existing.copy(deletedAt = existing.deletedAt ?: now).entity()))
    }

    /** Called only after a complete validated read; failure leaves the previous cache intact. */
    fun cacheOtherAnniversaries(localOwner: ParentIdentity, values: List<Anniversary>, source: AnniversarySource? = null) = transaction {
        requireLocalParent(localOwner)
        require(values.all { it.owner == localOwner.other }) { "纪念日来源与文件夹不一致。" }
        database.archiveDao().deleteAnniversariesByOwner(localOwner.other.folder)
        database.archiveDao().insertAnniversaries(values.map { it.entity().copy(sourceBucket = source?.bucket, sourceRegion = source?.region) })
    }

    private fun readSnapshot(): ArchiveSnapshot {
        val dao = database.archiveDao()
        val meta = dao.meta() ?: return ArchiveSnapshot.empty()
        return ArchiveJson.parseSnapshot(encodeStored(meta, dao))
    }

    /** Internal whole-snapshot replacement for fixtures/merge. Interactive edits use transactional commands below. */
    internal fun saveSnapshot(snapshot: ArchiveSnapshot) = transaction {
        rejectEditsDuringResync()
        writeSnapshot(snapshot)
    }

    internal fun replaceWithChainTip(snapshot: ArchiveSnapshot) = transaction {
        val current = localSyncState()
        if (current?.resyncFromStart != true) throw ArchiveValidationException("Chain replacement runs only during a resync from commit 1.")
        writeSnapshot(snapshot)
        writeSyncState(current.copy(resyncFromStart = false))
    }

    /** Restores a verified cloud snapshot; any publication failure rolls the database back. */
    fun <T> restoreForTakeover(
        snapshot: ArchiveSnapshot, deviceId: String, sequence: Long, commitHash: String,
        expectedSnapshot: ArchiveSnapshot? = null,
        anniversaries: List<Anniversary> = emptyList(),
        expectedAnniversaries: List<Anniversary>? = null,
        publish: () -> T,
    ): T = transaction {
        if (expectedSnapshot != null && readSnapshot() != expectedSnapshot) {
            throw ArchiveValidationException("Local records changed while restoring the backup.")
        }
        if (expectedAnniversaries != null && loadAnniversaries() != expectedAnniversaries) {
            throw ArchiveValidationException("恢复期间纪念日发生变化，请重试。")
        }
        database.archiveDao().insertAnniversaries(anniversaries.map { it.entity() })
        writeSnapshot(snapshot)
        writeSyncState(LocalSyncState(deviceId, sequence, commitHash, false))
        publish()
    }

    private fun writeSnapshot(snapshot: ArchiveSnapshot) {
        val encoded = ArchiveJson.encodeSnapshot(snapshot)
        // Parse before deleting anything: protocol errors roll back the entire transaction.
        ArchiveJson.parseSnapshot(encoded)
        val dao = database.archiveDao()
        dao.deleteRecords()
        dao.deleteAssets()
        dao.deleteResources()
        dao.deleteMeta()
        val records = encoded.array("records").map { recordEntity(it.jsonObject) }
        val assets = encoded.array("assets").map { assetEntity(it.jsonObject) }
        val resources = encoded.array("resources").map { resourceEntity(it.jsonObject) }
        if (records.isNotEmpty()) dao.insertRecords(records)
        if (assets.isNotEmpty()) dao.insertAssets(assets)
        if (resources.isNotEmpty()) dao.insertResources(resources)
        dao.insertMeta(SnapshotMetaEntity(version = snapshot.version,
            extensionsJson = canonicalJson(encoded.getValue("extensions")),
            unknownFieldsJson = canonicalJson(unknownObject(encoded, SNAPSHOT_KNOWN))))
    }

    /** Legacy low-level upsert. Does not detect stale fields in a supplied whole record; UI must use [editRecord]. */
    fun saveManualRecord(record: ArchiveRecord) = transaction {
        rejectEditsDuringResync()
        requireEditableRecord(record)
        writeSnapshot(ArchiveEdits.upsertManualRecord(readSnapshot(), record))
    }

    private fun rejectEditsDuringResync() {
        if (parentIdentity != null && parentIdentity.invoke() == null) {
            throw ArchiveValidationException("请先确认这台手机是谁。")
        }
        if (database.archiveDao().syncState()?.resyncFromStart == true) {
            throw ArchiveValidationException("Records are read-only until resync from commit 1 finishes.")
        }
    }


    fun localSyncState(): LocalSyncState? = transaction { database.archiveDao().syncState()?.toLocal() }

    internal fun saveLocalSyncState(state: LocalSyncState) = transaction {
        val current = database.archiveDao().syncState()?.toLocal()
        if (current?.resyncFromStart == true && !state.resyncFromStart) {
            throw ArchiveValidationException("Records are read-only until resync from commit 1 finishes.")
        }
        writeSyncState(state)
    }

    private fun writeSyncState(state: LocalSyncState) { database.archiveDao().insertSyncState(state.toEntity()) }

    fun reconcileOwner(deviceId: String) = transaction {
        require(deviceId.isNotBlank()) { "A device identity is required." }
        val current = database.archiveDao().syncState()
        if (current == null) writeSyncState(LocalSyncState(deviceId, null, null, false))
        else if (current.ownerDeviceId != deviceId) writeSyncState(LocalSyncState(deviceId, null, null, true))
    }

    fun createDraft(
        deviceId: String, nowMillis: Long, id: String = java.util.UUID.randomUUID().toString(),
        zoneId: java.time.ZoneId = java.time.ZoneId.systemDefault(),
    ): StoredDraft = transaction {
        rejectEditsDuringResync()
        if (database.archiveDao().draft(id) != null || database.archiveDao().draftCommit(id) != null || readSnapshot().records.any { it.id == id }) {
            throw ArchiveValidationException("This draft identity already exists.")
        }
        storeDraft(StoredDraft(withDeviceMetadata(newDraftRecord(id, deviceId, nowMillis, zoneId)), emptyList(), emptyList(), 0))
    }

    /** A saved local moment is edited in isolation, including new attachments. */
    fun createEditDraft(recordId: String): StoredDraft = transaction {
        rejectEditsDuringResync()
        val snapshot = readSnapshot()
        val original = requireRecord(snapshot, recordId)
        if (original.tombstone.value !is kotlinx.serialization.json.JsonNull) {
            throw ArchiveValidationException("请先从回收站恢复这条记录，再进行编辑。")
        }
        readDrafts().firstOrNull { it.originalRecordId == recordId }?.let { return@transaction it }
        val id = "edit-${java.util.UUID.randomUUID()}"
        val selected = assetIds(original).toSet()
        val assets = snapshot.assets.filter { it.id in selected }
        val resources = snapshot.resources.filter { it.assetID in selected }
        storeDraft(StoredDraft(original.copy(id = id), assets, resources, 0, original))
    }

    fun loadDraft(id: String): StoredDraft? = transaction { database.archiveDao().draft(id)?.decodeDraft() }
    fun loadDrafts(): List<StoredDraft> = transaction { readDrafts() }
    private fun readDrafts() = database.archiveDao().drafts().map { it.decodeDraft() }
    private fun requireDraft(id: String) = database.archiveDao().draft(id)?.decodeDraft()
        ?: throw ArchiveValidationException("Draft no longer exists.")

    /** The transform reads the current draft under the writer lock, including media just imported. */
    fun updateDraft(
        id: String, deviceId: String, nowMillis: Long, zoneId: java.time.ZoneId = java.time.ZoneId.systemDefault(),
        expectedRevision: Long? = null,
        transform: (MomentDraft) -> MomentDraft,
    ): StoredDraft = transaction {
        rejectEditsDuringResync()
        val before = requireDraft(id)
        if (expectedRevision != null && before.revision != expectedRevision) throw ArchiveValidationException("This draft changed. Reload before saving.")
        val snapshot = withDraftMedia(readSnapshot(), before)
        val record = editRecord(snapshot, before.record, transform(momentDraft(before.record)), deviceId, nowMillis, zoneId, allowEmpty = true)
        storeDraft(before.copy(record = record, revision = before.revision + 1))
    }

    fun discardDraft(id: String) = transaction {
        rejectEditsDuringResync()
        database.archiveDao().cancelPendingMediaItemsForDraft(id)
        database.archiveDao().cancelPendingMediaForDraft(id)
        database.archiveDao().deleteDraft(id)
    }

    fun commitDraft(id: String): ArchiveRecord = transaction {
        rejectEditsDuringResync()
        val snapshot = readSnapshot()
        database.archiveDao().draftCommit(id)?.let { return@transaction requireRecord(snapshot, it.recordId) }
        val draft = requireDraft(id)
        if (database.archiveDao().pendingMediaTasksForDraft(id).any { it.status in setOf("AwaitingCapture", "Queued", "Importing") })
            throw ArchiveValidationException("照片还在准备中，请稍后保存。")
        val target = draft.originalRecord?.let { baseline ->
            val current = requireRecord(snapshot, baseline.id)
            if (current != baseline || current.tombstone.value !is kotlinx.serialization.json.JsonNull) {
                throw ArchiveValidationException("这条记录已发生变化，草稿仍已保留。请重新打开记录后再编辑。")
            }
            draft.record.copy(id = baseline.id)
        } ?: draft.record.also {
            if (snapshot.records.any { it.id == id }) throw ArchiveValidationException("A record already uses this draft identity.")
        }
        val withMedia = withDraftMedia(snapshot, draft)
        requireRecordReferences(withMedia, target)
        val updated = ArchiveEdits.upsertManualRecord(withMedia, target)
        writeSnapshot(updated)
        database.archiveDao().cancelPendingMediaItemsForDraft(id)
        database.archiveDao().cancelPendingMediaForDraft(id)
        database.archiveDao().insertDraftCommit(DraftCommitEntity(id, target.id))
        database.archiveDao().deleteDraft(id)
        updated.records.first { it.id == target.id }
    }

    fun editRecord(
        id: String, deviceId: String, nowMillis: Long, zoneId: java.time.ZoneId = java.time.ZoneId.systemDefault(),
        expectedRecord: ArchiveRecord? = null,
        transform: (MomentDraft) -> MomentDraft,
    ): ArchiveRecord = transaction {
        rejectEditsDuringResync()
        val snapshot = readSnapshot()
        val before = requireRecord(snapshot, id)
        if (expectedRecord != null && expectedRecord != before) throw ArchiveValidationException("This record changed. Reload before saving.")
        val updated = editRecord(snapshot, before, transform(momentDraft(before)), deviceId, nowMillis, zoneId)
        writeSnapshot(ArchiveEdits.upsertManualRecord(snapshot, updated))
        updated
    }

    fun removeDraftMedia(id: String, assetId: String, deviceId: String, nowMillis: Long, confirmDiscard: Boolean = false): MediaRemoval = transaction {
        rejectEditsDuringResync()
        val draft = requireDraft(id)
        val values = momentDraft(draft.record)
        if (assetId !in values.assetIds) throw ArchiveValidationException("Media no longer exists.")
        val remaining = values.assetIds.filterNot { it == assetId }
        val next = values.copy(assetIds = remaining)
        if (next.assetIds.isEmpty() && !hasRecordText(next.title, next.note)) {
            if (!confirmDiscard) return@transaction MediaRemoval.NeedsDiscardConfirmation
            database.archiveDao().cancelPendingMediaItemsForDraft(id)
            database.archiveDao().cancelPendingMediaForDraft(id)
            database.archiveDao().deleteDraft(id)
            return@transaction MediaRemoval.DraftDiscarded
        }
        val updated = updateDraft(id, deviceId, nowMillis) { next }
        val remainingAssets = updated.assets.filter { it.id in remaining }
        val remainingResources = remainingAssets.flatMap { it.resourceIds }.toSet()
        storeDraft(updated.copy(assets = remainingAssets, resources = updated.resources.filter { it.id in remainingResources }))
        MediaRemoval.Updated
    }

    fun removeRecordMedia(id: String, assetId: String, deviceId: String, nowMillis: Long): MediaRemoval = transaction {
        rejectEditsDuringResync()
        val snapshot = readSnapshot()
        val before = requireRecord(snapshot, id)
        if (!before.tombstone.isNullValue()) throw ArchiveValidationException("Restore this record before editing it.")
        val values = momentDraft(before)
        if (assetId !in values.assetIds) throw ArchiveValidationException("Media no longer exists.")
        val remaining = values.assetIds.filterNot { it == assetId }
        val next = values.copy(assetIds = remaining)
        if (next.assetIds.isEmpty() && !hasRecordText(next.title, next.note)) {
            // Keep the last media in the recycled record so restore remains valid.
            writeSnapshot(ArchiveEdits.upsertManualRecord(snapshot, changeRecordTrash(before, false, deviceId, nowMillis)))
            MediaRemoval.MovedToTrash
        } else {
            val record = editRecord(snapshot, before, next, deviceId, nowMillis, java.time.ZoneId.systemDefault())
            writeSnapshot(ArchiveEdits.upsertManualRecord(snapshot, record))
            MediaRemoval.Updated
        }
    }

    fun trashRecord(id: String, deviceId: String, nowMillis: Long): ArchiveRecord = setRecordTrash(id, false, deviceId, nowMillis)
    fun restoreRecord(id: String, deviceId: String, nowMillis: Long): ArchiveRecord = setRecordTrash(id, true, deviceId, nowMillis)
    private fun setRecordTrash(id: String, restore: Boolean, device: String, now: Long): ArchiveRecord = transaction {
        rejectEditsDuringResync()
        val snapshot = readSnapshot()
        val record = changeRecordTrash(requireRecord(snapshot, id), restore, device, now)
        writeSnapshot(ArchiveEdits.upsertManualRecord(snapshot, record))
        record
    }

    /** Atomically adds prepared media and a record, reusing original-content identities. */
    fun importRecord(record: ArchiveRecord, media: List<ImportedMedia>, deduplicateSingleRecord: Boolean = false): ArchiveRecord = transaction {
        rejectEditsDuringResync()
        val snapshot = readSnapshot()
        val resolved = resolveMedia(snapshot, media)
        val ids = assetIds(record).map { resolved.ids[it] ?: it }.distinct()
        if (deduplicateSingleRecord && ids.size == 1) {
            snapshot.records.firstOrNull { it.tombstone.isNullValue() && ids.single() in assetIds(it) }?.let { return@transaction it }
        }
        val id = if (snapshot.records.any { it.id == record.id }) java.util.UUID.randomUUID().toString() else record.id
        val updated = withDeviceMetadata(record.copy(id = id, assetIds = record.assetIds.copy(value = JsonArray(ids.map(::JsonPrimitive)))))
        val withMedia = addMedia(snapshot, resolved.media)
        requireRecordReferences(withMedia, updated)
        val saved = ArchiveEdits.upsertManualRecord(withMedia, updated)
        writeSnapshot(saved)
        saved.records.first { it.id == id }
    }

    fun appendRecordMedia(
        id: String, media: List<ImportedMedia>, expectedRecord: ArchiveRecord?, deviceId: String, nowMillis: Long,
    ): ArchiveRecord = transaction {
        rejectEditsDuringResync()
        val snapshot = readSnapshot()
        val before = requireRecord(snapshot, id)
        if (!before.tombstone.isNullValue()) throw ArchiveValidationException("Restore this record before editing it.")
        if (expectedRecord != null && expectedRecord != before) throw ArchiveValidationException("This record changed. Reload before saving.")
        if (media.isEmpty()) throw ArchiveValidationException("Choose at least one media item to import.")
        val resolved = resolveMedia(snapshot, media)
        val ids = (assetIds(before) + media.map { resolved.ids.getValue(it.asset.id) }).distinct()
        if (ids.size > MAX_RECORD_MEDIA) throw ArchiveValidationException("Choose 0–30 distinct media items.")
        val withMedia = addMedia(snapshot, resolved.media)
        val updated = before.copy(assetIds = editedField(before.assetIds, JsonArray(ids.map(::JsonPrimitive)), deviceId, nowMillis))
        requireRecordReferences(withMedia, updated)
        val saved = ArchiveEdits.upsertManualRecord(withMedia, updated)
        writeSnapshot(saved)
        saved.records.first { it.id == id }
    }

    fun appendDraftMedia(draftId: String, media: List<ImportedMedia>): StoredDraft = transaction {
        rejectEditsDuringResync()
        val draft = requireDraft(draftId)
        if (media.isEmpty()) throw ArchiveValidationException("Choose at least one media item to import.")
        val resolved = resolveMedia(readSnapshot(), media)
        val ids = (assetIds(draft.record) + media.map { resolved.ids.getValue(it.asset.id) }).distinct()
        if (ids.size > MAX_RECORD_MEDIA) throw ArchiveValidationException("Choose 0–30 distinct media items.")
        val combined = addMedia(draft.snapshot(), resolved.media)
        val before = draft.record.assetIds
        val assetStamp = media.firstOrNull()?.asset?.capturedAt?.edit
        val updated = if (ids == assetIds(draft.record)) draft.record else draft.record.copy(assetIds = editedField(
            before, JsonArray(ids.map(::JsonPrimitive)), assetStamp?.deviceID ?: before.edit.deviceID, assetStamp?.at ?: before.edit.at))
        val timed = if (draft.originalRecord == null && assetIds(draft.record).isEmpty() && media.isNotEmpty() && draft.record.occurredAt.edit.counter == 1L) {
            val nowMillis = assetStamp?.at ?: timeMillis(draft.record)
            val capture = resolved.media.mapNotNull { it.asset.capturedAt.value as? JsonObject }
                .filter { (it["timeUnknown"] as? JsonPrimitive)?.booleanOrNull == false }
                // Deduplication can select stored assets; their capture time must not depend on today's clock.
                .filter { (it["utc"] as? JsonPrimitive)?.longOrNull?.let(::isAfterCaptureFloor) == true }
                .minByOrNull { (it["utc"] as? JsonPrimitive)?.longOrNull ?: Long.MAX_VALUE }
            val occurred = capture?.let { JsonObject(it.filterKeys { key -> key != "timeUnknown" }) }
                ?: JsonObject(mapOf("utc" to JsonPrimitive(nowMillis),
                    "zoneUnknown" to JsonPrimitive(true), "estimated" to JsonPrimitive(true)))
            updated.copy(occurredAt = editedField(updated.occurredAt, occurred,
                assetStamp?.deviceID ?: updated.occurredAt.edit.deviceID, assetStamp?.at ?: updated.occurredAt.edit.at))
        } else updated
        storeDraft(draft.copy(record = timed, assets = combined.assets, resources = combined.resources, revision = draft.revision + 1))
    }

    /** A task and its new draft appear together, or neither appears. */
    fun createPendingMediaTask(task: PendingMediaTaskEntity, deviceId: String, nowMillis: Long): PendingMediaTaskEntity = transaction {
        rejectEditsDuringResync()
        check(database.archiveDao().pendingMediaTask(task.id) == null) { "Media task already exists." }
        if (task.ownsDraft) createDraft(deviceId, nowMillis, task.draftId) else requireDraft(task.draftId)
        database.archiveDao().insertPendingMediaTask(task)
        ensurePendingMediaItems(task)
        task
    }

    fun pendingMediaTasks(): List<PendingMediaTaskEntity> = transaction { database.archiveDao().pendingMediaTasks() }
    fun pendingMediaTask(id: String): PendingMediaTaskEntity? = transaction { database.archiveDao().pendingMediaTask(id) }
    fun pendingMediaTasksForDraft(id: String): List<PendingMediaTaskEntity> = transaction { database.archiveDao().pendingMediaTasksForDraft(id) }

    /** Expands version 6 URI arrays without replaying already completed attachments. */
    private fun ensurePendingMediaItems(task: PendingMediaTaskEntity): List<PendingMediaItemEntity> {
        val dao = database.archiveDao()
        dao.pendingMediaItems(task.id).takeIf { it.isNotEmpty() }?.let { return it }
        val selections = kotlinx.serialization.json.Json.parseToJsonElement(task.payloadJson).jsonArray
        return selections.mapIndexed { index, value ->
            val objectValue = value as? JsonObject
            val uri = objectValue?.get("uri")?.jsonPrimitive?.content ?: value.jsonPrimitive.content
            val origin = objectValue?.get("origin")?.jsonPrimitive?.content ?: task.origin
            val status = when (task.status) {
                "Ready" -> "Success"
                "Cancelled" -> "Cancelled"
                "Failed" -> "Failed"
                else -> "Queued"
            }
            PendingMediaItemEntity("${task.id}:$index", task.id, index, uri, origin, status,
                null, false, null, task.errorMessage).also(dao::insertPendingMediaItem)
        }
    }

    fun pendingMediaItems(taskId: String): List<PendingMediaItemEntity> = transaction {
        database.archiveDao().pendingMediaTask(taskId)?.let(::ensurePendingMediaItems).orEmpty()
    }

    fun startPendingMediaItem(taskId: String, itemId: String): PendingMediaItemEntity? = transaction {
        val dao = database.archiveDao()
        val task = dao.pendingMediaTask(taskId) ?: return@transaction null
        if (task.status != "Importing" || dao.draft(task.draftId) == null) return@transaction null
        ensurePendingMediaItems(task)
        val item = dao.pendingMediaItem(itemId) ?: return@transaction null
        if (item.taskId != taskId || item.status != "Queued") return@transaction null
        item.copy(status = "Importing", errorMessage = null).also(dao::insertPendingMediaItem)
    }

    /** One file is attached exactly once; retrying its neighbours cannot roll it back. */
    fun completePendingMediaItem(taskId: String, itemId: String, media: ImportedMedia,
        degraded: Boolean): StoredDraft = transaction {
        val dao = database.archiveDao()
        val task = checkNotNull(dao.pendingMediaTask(taskId))
        val item = checkNotNull(dao.pendingMediaItem(itemId))
        if (item.taskId != taskId) throw ArchiveValidationException("Media task changed.")
        if (item.status in setOf("Success", "Degraded")) return@transaction requireDraft(task.draftId)
        if (task.status != "Importing" || item.status != "Importing" || dao.draft(task.draftId) == null)
            throw java.util.concurrent.CancellationException("已取消导入。")
        val beforeIds = assetIds(requireDraft(task.draftId).record)
        val draft = appendDraftMedia(task.draftId, listOf(media))
        val hashes = media.resources.filter { it.role != "preview" }.map { it.sha256 }.toSet()
        val actual = draft.assets.first { asset ->
            draft.resources.filter { it.assetID == asset.id && it.role != "preview" }.map { it.sha256 }.toSet() == hashes
        }
        val provenance = actual.importProvenance
        dao.insertPendingMediaItem(item.copy(status = if (degraded || provenance == ImportProvenance.SystemProvided) "Degraded" else "Success",
            assetId = actual.id, ownsPosition = actual.id !in beforeIds,
            provenance = provenance.wireValue, errorMessage = null))
        // A retried earlier item returns to its selection position, after pre-existing draft media.
        val owned = dao.pendingMediaItems(taskId).filter { it.ownsPosition && it.status in setOf("Success", "Degraded") }
            .mapNotNull { it.assetId }.distinct()
        val ids = assetIds(draft.record)
        val first = ids.indexOfFirst { it in owned }.coerceAtLeast(0)
        val remaining = ids.filterNot { it in owned }
        val ordered = remaining.take(first) + owned + remaining.drop(first)
        val result = if (ids == ordered) draft else storeDraft(draft.copy(record = draft.record.copy(
            assetIds = draft.record.assetIds.copy(value = JsonArray(ordered.map(::JsonPrimitive))))))
        val completed = dao.pendingMediaItems(taskId).count { it.status in setOf("Success", "Degraded", "Cancelled") }
        dao.insertPendingMediaTask(task.copy(completedItems = completed))
        result
    }

    fun failPendingMediaItem(taskId: String, itemId: String, message: String) = transaction {
        val dao = database.archiveDao()
        val task = dao.pendingMediaTask(taskId) ?: return@transaction
        val item = dao.pendingMediaItem(itemId) ?: return@transaction
        if (task.status == "Importing" && item.taskId == taskId && item.status == "Importing")
            dao.insertPendingMediaItem(item.copy(status = "Failed", errorMessage = message))
    }

    fun finishPendingMediaTask(taskId: String): PendingMediaTaskEntity? = transaction {
        val dao = database.archiveDao()
        val task = dao.pendingMediaTask(taskId) ?: return@transaction null
        if (task.status !in setOf("Importing", "Failed")) return@transaction task
        val items = ensurePendingMediaItems(task)
        if (items.any { it.status in setOf("Queued", "Importing") }) return@transaction task
        val failures = items.count { it.status == "Failed" }
        task.copy(status = if (failures > 0) "Failed" else "Ready",
            completedItems = items.count { it.status in setOf("Success", "Degraded", "Cancelled") },
            errorMessage = if (failures == 1) items.first { it.status == "Failed" }.errorMessage
                else if (failures > 1) "$failures 个项目未能导入，可单独重试或移除。" else null)
            .also(dao::insertPendingMediaTask)
    }

    fun retryPendingMediaItems(taskId: String, itemId: String? = null): PendingMediaTaskEntity? = transaction {
        val dao = database.archiveDao()
        val task = dao.pendingMediaTask(taskId) ?: return@transaction null
        if (task.status != "Failed" || dao.draft(task.draftId) == null) return@transaction null
        val failed = ensurePendingMediaItems(task).filter { it.status == "Failed" && (itemId == null || itemId == it.id) }
        if (failed.isEmpty()) return@transaction null
        failed.forEach { dao.insertPendingMediaItem(it.copy(status = "Queued", errorMessage = null)) }
        task.copy(status = "Queued", errorMessage = null).also(dao::insertPendingMediaTask)
    }

    fun removePendingMediaItem(taskId: String, itemId: String): PendingMediaTaskEntity? = transaction {
        val dao = database.archiveDao()
        val task = dao.pendingMediaTask(taskId) ?: return@transaction null
        if (task.status != "Failed") return@transaction null
        ensurePendingMediaItems(task)
        val item = dao.pendingMediaItem(itemId) ?: return@transaction null
        if (item.taskId != taskId || item.status != "Failed") return@transaction null
        dao.insertPendingMediaItem(item.copy(status = "Cancelled", errorMessage = null))
        finishPendingMediaTask(taskId)
    }

    fun recoverPendingMediaItems(taskId: String) = transaction {
        val dao = database.archiveDao()
        val task = dao.pendingMediaTask(taskId) ?: return@transaction
        ensurePendingMediaItems(task).filter { it.status == "Importing" }.forEach {
            dao.insertPendingMediaItem(it.copy(status = "Queued"))
        }
    }

    fun transitionPendingMediaTask(id: String, expected: Set<String>, status: String,
        completed: Int? = null, error: String? = null): PendingMediaTaskEntity? = transaction {
        val before = database.archiveDao().pendingMediaTask(id) ?: return@transaction null
        if (before.status !in expected) return@transaction null
        val next = before.copy(status = status, completedItems = completed ?: before.completedItems, errorMessage = error)
        database.archiveDao().insertPendingMediaTask(next)
        next
    }

    /** Atomic append plus receipt: a crash cannot append the same task twice. */
    fun completePendingMediaTask(id: String, media: List<ImportedMedia>): StoredDraft = transaction {
        val task = checkNotNull(database.archiveDao().pendingMediaTask(id)) { "Media task no longer exists." }
        if (task.status == "Ready") return@transaction requireDraft(task.draftId)
        if (task.status != "Importing") throw java.util.concurrent.CancellationException("已取消导入。")
        val draft = appendDraftMedia(task.draftId, media)
        database.archiveDao().insertPendingMediaTask(task.copy(status = "Ready", completedItems = task.totalItems, errorMessage = null))
        draft
    }

    /** Cancellation never discards an existing draft or user-entered text. */
    fun cancelPendingMediaTask(id: String): PendingMediaTaskEntity? = transaction {
        val before = database.archiveDao().pendingMediaTask(id) ?: return@transaction null
        if (before.status in setOf("Ready", "Cancelled")) return@transaction before
        database.archiveDao().cancelPendingMediaItems(id)
        val next = before.copy(status = "Cancelled", errorMessage = null)
        database.archiveDao().insertPendingMediaTask(next)
        val draft = database.archiveDao().draft(before.draftId)?.decodeDraft()
        val others = database.archiveDao().pendingMediaTasksForDraft(before.draftId).any {
            it.id != id && it.status !in setOf("Ready", "Cancelled")
        }
        if (before.ownsDraft && draft != null && !others && draft.assets.isEmpty() &&
            !hasRecordText(momentDraft(draft.record).title, momentDraft(draft.record).note) && draft.revision == 0L) database.archiveDao().deleteDraft(before.draftId)
        next
    }

    /** Throws on read failure: callers must retain files if reference verification fails. */
    fun retainedObjectKeys(): Set<String> = transaction {
        (readSnapshot().resources + readDrafts().flatMap { it.resources }).map { it.objectKey }.toSet()
    }

    private fun storeDraft(draft: StoredDraft): StoredDraft {
        val payload = ArchiveJson.canonical(draft.snapshot())
        ArchiveJson.parseSnapshot(kotlinx.serialization.json.Json.parseToJsonElement(payload).jsonObject)
        val baseline = draft.originalRecord?.let { ArchiveJson.canonical(ArchiveSnapshot.empty().copy(records = listOf(it))) }
        database.archiveDao().insertDraft(DraftEntity(draft.record.id, payload, draft.revision, baseline))
        return draft
    }

    private fun withDraftMedia(snapshot: ArchiveSnapshot, draft: StoredDraft): ArchiveSnapshot =
        addMedia(snapshot, draft.assets.filter { candidate -> snapshot.assets.none { it.id == candidate.id } }
            .map { asset -> ImportedMedia(asset, draft.resources.filter { it.assetID == asset.id }) })

    private fun requireRecord(snapshot: ArchiveSnapshot, id: String): ArchiveRecord =
        (snapshot.records.firstOrNull { it.id == id } ?: throw ArchiveValidationException("Record no longer exists."))
            .also(::requireEditableRecord)

    private fun requireLocalParent(owner: ParentIdentity) {
        if (parentIdentity != null && parentIdentity.invoke() != owner) {
            throw ArchiveValidationException("只能修改自己添加的纪念日。")
        }
    }

    private fun requireEditableRecord(record: ArchiveRecord) {
        val declaredOwner = (record.extensions["parent"]?.value as? JsonPrimitive)?.content
        val current = parentIdentity?.invoke()
        if ((record.extensions["readOnly"]?.value as? JsonPrimitive)?.booleanOrNull == true ||
            current != null && declaredOwner != null && declaredOwner != current.folder) {
            throw ArchiveValidationException("只能修改自己的记录。")
        }
    }

    private fun withDeviceMetadata(record: ArchiveRecord): ArchiveRecord {
        requireEditableRecord(record)
        val info = deviceMetadata()
        val stamp = record.createdAt.edit
        val additions = mutableMapOf<String, com.henrypann.jinbao365.archive.FieldEnvelope>()
        if (info != null) {
            additions["deviceManufacturer"] = com.henrypann.jinbao365.archive.FieldEnvelope(JsonPrimitive(info.first), stamp)
            additions["deviceModel"] = com.henrypann.jinbao365.archive.FieldEnvelope(JsonPrimitive(info.second), stamp)
        }
        parentIdentity?.invoke()?.let {
            additions["parent"] = com.henrypann.jinbao365.archive.FieldEnvelope(JsonPrimitive(it.folder), stamp)
        }
        return record.copy(extensions = record.extensions + additions)
    }

    private fun requireRecordReferences(snapshot: ArchiveSnapshot, record: ArchiveRecord) {
        if (assetIds(record).any { id -> snapshot.assets.none { it.id == id } }) throw ArchiveValidationException("A selected media item is missing.")

    }

    private fun resolveMedia(snapshot: ArchiveSnapshot, incoming: List<ImportedMedia>): ResolvedMedia {
        var known = readDrafts().fold(snapshot) { current, draft -> withDraftMedia(current, draft) }
        val ids = linkedMapOf<String, String>()
        val media = mutableListOf<ImportedMedia>()
        for (candidate in incoming) {
            validateMedia(candidate)
            val originals = candidate.resources.filter { it.role != "preview" }
            val hashes = originals.map { it.sha256 }.toSet()
            val existing = known.assets.firstOrNull { asset ->
                val existingHashes = known.resources.filter { it.assetID == asset.id && it.role != "preview" }.map { it.sha256 }.toSet()
                hashes.isNotEmpty() && hashes == existingHashes
            }
            if (existing != null && existing.kind != candidate.asset.kind) {
                throw ArchiveValidationException("The same original bytes have conflicting media kinds.")
            }
            val selected = existing?.let { asset -> ImportedMedia(asset, known.resources.filter { it.assetID == asset.id }) } ?: candidate
            val prior = ids.put(candidate.asset.id, selected.asset.id)
            if (prior != null && prior != selected.asset.id) throw ArchiveValidationException("Conflicting imported media identity.")
            known = addMedia(known, listOf(selected))
            media += selected
        }
        return ResolvedMedia(ids, media.distinctBy { it.asset.id })
    }

    fun columnNames(table: String): List<String> {
        val names = mutableListOf<String>()
        database.openHelper.readableDatabase.query("PRAGMA table_info($table)").use { cursor ->
            val nameIndex = cursor.getColumnIndex("name")
            while (cursor.moveToNext()) names += cursor.getString(nameIndex)
        }
        return names
    }

    private fun encodeStored(meta: SnapshotMetaEntity, dao: ArchiveDao): JsonObject {
        val map = linkedMapOf<String, kotlinx.serialization.json.JsonElement>(
            "version" to JsonPrimitive(meta.version),
            "records" to JsonArray(dao.records().sortedWith { left, right -> utf8Compare(left.id, right.id) }.map { recordObject(it) }),
            "assets" to JsonArray(dao.assets().sortedWith { left, right -> utf8Compare(left.id, right.id) }.map { assetObject(it) }),
            "resources" to JsonArray(dao.resources().sortedWith { left, right -> utf8Compare(left.id, right.id) }.map { resourceObject(it) }),
            "extensions" to decodeObject(meta.extensionsJson),
        )
        decodeObject(meta.unknownFieldsJson).forEach { (key, value) -> map[key] = value }
        return sortedObject(map)
    }
}

data class LocalSyncState(
    val ownerDeviceId: String?,
    val verifiedThroughSequence: Long?,
    val verifiedThroughHash: String?,
    val resyncFromStart: Boolean,
)

private fun SyncStateEntity.toLocal() = LocalSyncState(
    ownerDeviceId = ownerDeviceId,
    verifiedThroughSequence = verifiedThroughSequence,
    verifiedThroughHash = verifiedThroughHash,
    resyncFromStart = resyncFromStart,
)

private fun LocalSyncState.toEntity() = SyncStateEntity(
    ownerDeviceId = ownerDeviceId,
    verifiedThroughSequence = verifiedThroughSequence,
    verifiedThroughHash = verifiedThroughHash,
    resyncFromStart = resyncFromStart,
)

private fun recordEntity(objectValue: JsonObject) = RecordEntity(
    id = objectValue.string("id"),
    titleJson = objectValue["title"]?.let(::canonicalJson) ?: "null",
    noteJson = canonicalJson(objectValue.getValue("note")),
    occurredAtJson = canonicalJson(objectValue.getValue("occurredAt")),
    createdAtJson = canonicalJson(objectValue.getValue("createdAt")),
    assetIdsJson = canonicalJson(objectValue.getValue("assetIDs")),
    tombstoneJson = canonicalJson(objectValue.getValue("tombstone")),
    extensionsJson = canonicalJson(objectValue.getValue("extensions")),
    unknownFieldsJson = canonicalJson(unknownObject(objectValue, RECORD_KNOWN)),
    mediaOverflow = objectValue.optionalBoolean("mediaOverflow"),
)

private fun assetEntity(objectValue: JsonObject) = AssetEntity(
    id = objectValue.string("id"),
    kind = objectValue.string("kind"),
    capturedAtJson = canonicalJson(objectValue.getValue("capturedAt")),
    resourceIdsJson = canonicalJson(objectValue.getValue("resourceIDs")),
    extensionsJson = canonicalJson(objectValue.getValue("extensions")),
    unknownFieldsJson = canonicalJson(unknownObject(objectValue, ASSET_KNOWN)),
)

private fun resourceEntity(objectValue: JsonObject) = ResourceEntity(
    id = objectValue.string("id"),
    assetId = objectValue.string("assetID"),
    role = objectValue.string("role"),
    contentType = objectValue.string("contentType"),
    originalFilename = objectValue.string("originalFilename"),
    byteCount = objectValue.long("byteCount"),
    sha256 = objectValue.string("sha256"),
    objectKey = objectValue.string("objectKey"),
    possibleDuplicateOfJson = objectValue["possibleDuplicateOf"]?.let { canonicalJson(it) },
    extensionsJson = canonicalJson(objectValue.getValue("extensions")),
    unknownFieldsJson = canonicalJson(unknownObject(objectValue, RESOURCE_KNOWN)),
)

private fun recordObject(row: RecordEntity): JsonObject {
    val map = linkedMapOf(
        "id" to JsonPrimitive(row.id),
        "title" to decodeElement(row.titleJson),
        "note" to decodeObject(row.noteJson),
        "occurredAt" to decodeObject(row.occurredAtJson),
        "createdAt" to decodeObject(row.createdAtJson),
        "assetIDs" to decodeObject(row.assetIdsJson),
        "tombstone" to decodeObject(row.tombstoneJson),
        "extensions" to decodeObject(row.extensionsJson),
    )
    if (row.titleJson == "null") map.remove("title")
    row.mediaOverflow?.let { map["mediaOverflow"] = JsonPrimitive(it) }
    decodeObject(row.unknownFieldsJson).forEach { (key, value) -> map[key] = value }
    return sortedObject(map)
}

private fun assetObject(row: AssetEntity): JsonObject {
    val map = linkedMapOf(
        "id" to JsonPrimitive(row.id),
        "kind" to JsonPrimitive(row.kind),
        "capturedAt" to decodeObject(row.capturedAtJson),
        "resourceIDs" to decodeElement(row.resourceIdsJson),
        "extensions" to decodeObject(row.extensionsJson),
    )
    decodeObject(row.unknownFieldsJson).forEach { (key, value) -> map[key] = value }
    return sortedObject(map)
}

private fun resourceObject(row: ResourceEntity): JsonObject {
    val map = linkedMapOf(
        "id" to JsonPrimitive(row.id),
        "assetID" to JsonPrimitive(row.assetId),
        "role" to JsonPrimitive(row.role),
        "contentType" to JsonPrimitive(row.contentType),
        "originalFilename" to JsonPrimitive(row.originalFilename),
        "byteCount" to JsonPrimitive(row.byteCount),
        "sha256" to JsonPrimitive(row.sha256),
        "objectKey" to JsonPrimitive(row.objectKey),
        "extensions" to decodeObject(row.extensionsJson),
    )
    row.possibleDuplicateOfJson?.let { map["possibleDuplicateOf"] = decodeObject(it) }
    decodeObject(row.unknownFieldsJson).forEach { (key, value) -> map[key] = value }
    return sortedObject(map)
}

private val SNAPSHOT_KNOWN = setOf("version", "records", "items", "assets", "resources", "extensions")
private val RECORD_KNOWN = setOf(
    "id", "title", "note", "occurredAt", "createdAt", "assetIDs", "isOutfit",
    "links", "tombstone", "extensions", "mediaOverflow", "outfitConstraintOverflow",
)
private val ASSET_KNOWN = setOf("id", "kind", "capturedAt", "resourceIDs", "extensions")
private val RESOURCE_KNOWN = setOf(
    "id", "assetID", "role", "contentType", "originalFilename", "byteCount",
    "sha256", "objectKey", "possibleDuplicateOf", "extensions",
)

private fun unknownObject(objectValue: JsonObject, known: Set<String>): JsonObject {
    return sortedObject(objectValue.filterKeys { it !in known })
}

private fun decodeObject(text: String): JsonObject = decodeElement(text).jsonObject

private fun decodeElement(text: String) = kotlinx.serialization.json.Json.parseToJsonElement(text)

private fun JsonObject.array(key: String) = getValue(key).jsonArray

private fun JsonObject.string(key: String): String {
    val primitive = getValue(key).jsonPrimitive
    if (!primitive.isString) error("$key must be a string")
    return primitive.content
}

private fun JsonObject.long(key: String): Long = getValue(key).jsonPrimitive.content.toLong()

private fun JsonObject.optionalBoolean(key: String): Boolean? = this[key]?.jsonPrimitive?.booleanOrNull
