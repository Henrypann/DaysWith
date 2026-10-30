package com.henrypann.jinbao365.media

import com.henrypann.jinbao365.archive.ArchiveRecord
import com.henrypann.jinbao365.archive.MediaResource
import com.henrypann.jinbao365.data.ArchiveRepository
import com.henrypann.jinbao365.data.StoredDraft
import com.henrypann.jinbao365.editing.MediaRemoval

/** Blocking business API. Use the process import executor, never the Activity's lifecycle scope. */
class MediaImportService(
    private val repository: ArchiveRepository,
    private val deviceId: String,
    private val importer: MediaImporter,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    /** Compatibility path: one image is saved immediately and a live duplicate creates no record. */
    fun importSingle(request: ImportRequest): SingleImportResult = importer.withImportLock {
        val prepared = importer.import(request, retainedObjectKeys = repository::retainedObjectKeys)
        val group = PreparedImports(listOf(prepared))
        val record: ArchiveRecord
        val desired: ArchiveRecord
        try {
            val now = nowMillis()
            desired = group.record(deviceId, now)
            record = repository.importRecord(desired, group.media(deviceId, now), deduplicateSingleRecord = true)
        } catch (error: Exception) {
            rollbackPreservingError(error) { group.discardNewFiles(repository.retainedObjectKeys()) }
            throw error
        }
        cleanupCommitted(group)
        SingleImportResult(prepared, record, record.id == desired.id)
    }

    /** Adds one selection to an existing or restored local draft. Only commitDraft creates a record. */
    fun importToDraft(
        draftId: String,
        requests: List<ImportRequest>,
        onProgress: (completedItems: Int, totalItems: Int) -> Unit = { _, _ -> },
        isCancelled: () -> Boolean = { false },
    ): StoredDraft = importer.withImportLock {
        val prepared = importer.importMultiple(requests, repository::retainedObjectKeys, onProgress, isCancelled)
        val draft = try {
            checkImportCancellation(isCancelled)
            repository.appendDraftMedia(draftId, prepared.media(deviceId, nowMillis()))
        } catch (error: Exception) {
            rollbackPreservingError(error) { prepared.discardNewFiles(repository.retainedObjectKeys()) }
            throw error
        }
        cleanupCommitted(prepared)
        draft
    }

    /** Each item has its own atomic receipt, so later failures never undo successful files. */
    fun importPendingItem(taskId: String, itemId: String, request: ImportRequest,
        isCancelled: () -> Boolean = { false }): StoredDraft = importer.withImportLock {
        val prepared = importer.import(request, retainedObjectKeys = repository::retainedObjectKeys, isCancelled = isCancelled)
        val group = PreparedImports(listOf(prepared))
        val draft = try {
            checkImportCancellation(isCancelled)
            repository.completePendingMediaItem(taskId, itemId, prepared.media(deviceId, nowMillis()), prepared.wasDowngraded)
        } catch (error: Exception) {
            rollbackPreservingError(error) { group.discardNewFiles(repository.retainedObjectKeys()) }
            throw error
        }
        cleanupCommitted(group)
        draft
    }

    /** Task completion and draft attachment share one transaction and durable receipt. */
    fun importPendingTask(taskId: String, requests: List<ImportRequest>,
        onProgress: (Int, Int) -> Unit = { _, _ -> }, isCancelled: () -> Boolean = { false }): StoredDraft = importer.withImportLock {
        val prepared = importer.importMultiple(requests, repository::retainedObjectKeys, onProgress, isCancelled)
        val draft = try {
            checkImportCancellation(isCancelled)
            repository.completePendingMediaTask(taskId, prepared.media(deviceId, nowMillis()))
        } catch (error: Exception) {
            rollbackPreservingError(error) { prepared.discardNewFiles(repository.retainedObjectKeys()) }
            throw error
        }
        cleanupCommitted(prepared)
        draft
    }

    /** Appends a selection to a saved record without changing its occurrence time. */
    fun importToRecord(
        recordId: String,
        requests: List<ImportRequest>,
        expectedRecord: ArchiveRecord? = null,
        onProgress: (completedItems: Int, totalItems: Int) -> Unit = { _, _ -> },
        isCancelled: () -> Boolean = { false },
    ): ArchiveRecord = importer.withImportLock {
        val prepared = importer.importMultiple(requests, repository::retainedObjectKeys, onProgress, isCancelled)
        val record = try {
            checkImportCancellation(isCancelled)
            val now = nowMillis()
            repository.appendRecordMedia(recordId, prepared.media(deviceId, now), expectedRecord, deviceId, now)
        } catch (error: Exception) {
            rollbackPreservingError(error) { prepared.discardNewFiles(repository.retainedObjectKeys()) }
            throw error
        }
        cleanupCommitted(prepared)
        record
    }

    /** Releases only this draft's objects that no record, cover, or other draft retains. */
    fun discardDraft(draftId: String) = importer.withImportLock {
        val candidates = repository.loadDraft(draftId)?.resources.orEmpty()
        repository.discardDraft(draftId)
        cleanupReleased(candidates)
    }

    /** A last-media removal needs explicit confirmation before an empty draft is discarded. */
    fun removeDraftMedia(draftId: String, assetId: String, confirmDiscard: Boolean = false): MediaRemoval =
        importer.withImportLock {
            val candidates = repository.loadDraft(draftId)?.resources.orEmpty()
            val result = repository.removeDraftMedia(draftId, assetId, deviceId, nowMillis(), confirmDiscard)
            if (result == MediaRemoval.Updated || result == MediaRemoval.DraftDiscarded) cleanupReleased(candidates)
            result
        }

    private fun cleanupReleased(candidates: List<MediaResource>) {
        val retained = try { repository.retainedObjectKeys() } catch (_: Exception) { return }
        importer.discardUnreferencedObjects(candidates, retained)
    }

    private fun cleanupCommitted(prepared: PreparedImports) {
        // The transaction already succeeded. A failed protection read must neither delete
        // shared files nor report the committed operation as if it had rolled back.
        val retained = try { repository.retainedObjectKeys() } catch (_: Exception) { return }
        prepared.discardNewFiles(retained)
    }
}

data class SingleImportResult(val imported: PreparedImport, val record: ArchiveRecord, val inserted: Boolean)
