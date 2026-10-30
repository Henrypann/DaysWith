package com.henrypann.jinbao365.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface ArchiveDao {
    @Query("SELECT * FROM pending_media_items WHERE taskId = :taskId ORDER BY position")
    fun pendingMediaItems(taskId: String): List<PendingMediaItemEntity>

    @Query("SELECT * FROM pending_media_items WHERE id = :id")
    fun pendingMediaItem(id: String): PendingMediaItemEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun insertPendingMediaItem(row: PendingMediaItemEntity)

    @Query("UPDATE pending_media_items SET status = 'Cancelled', errorMessage = NULL WHERE taskId = :taskId AND status IN ('Queued', 'Importing', 'Failed')")
    fun cancelPendingMediaItems(taskId: String)

    @Query("UPDATE pending_media_items SET status = 'Cancelled', errorMessage = NULL WHERE taskId IN (SELECT id FROM pending_media_tasks WHERE draftId = :draftId) AND status IN ('Queued', 'Importing', 'Failed')")
    fun cancelPendingMediaItemsForDraft(draftId: String)

    @Query("SELECT * FROM pending_media_tasks ORDER BY id")
    fun pendingMediaTasks(): List<PendingMediaTaskEntity>

    @Query("SELECT * FROM pending_media_tasks WHERE id = :id")
    fun pendingMediaTask(id: String): PendingMediaTaskEntity?

    @Query("SELECT * FROM pending_media_tasks WHERE draftId = :draftId ORDER BY id")
    fun pendingMediaTasksForDraft(draftId: String): List<PendingMediaTaskEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun insertPendingMediaTask(row: PendingMediaTaskEntity)

    @Query("UPDATE pending_media_tasks SET status = 'Cancelled', errorMessage = NULL WHERE draftId = :draftId AND status NOT IN ('Ready', 'Cancelled')")
    fun cancelPendingMediaForDraft(draftId: String)

    @Query("SELECT * FROM anniversaries ORDER BY owner, id")
    fun anniversaries(): List<AnniversaryEntity>

    @Query("SELECT * FROM anniversaries WHERE owner = :owner AND id = :id")
    fun anniversary(owner: String, id: String): AnniversaryEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun insertAnniversaries(rows: List<AnniversaryEntity>)

    @Query("DELETE FROM anniversaries WHERE owner = :owner")
    fun deleteAnniversariesByOwner(owner: String)

    @Query("SELECT * FROM draft_commits WHERE id = :id")
    fun draftCommit(id: String): DraftCommitEntity?

    @Insert
    fun insertDraftCommit(row: DraftCommitEntity)

    @Query("SELECT * FROM drafts ORDER BY id")
    fun drafts(): List<DraftEntity>

    @Query("SELECT * FROM drafts WHERE id = :id")
    fun draft(id: String): DraftEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun insertDraft(row: DraftEntity)

    @Query("DELETE FROM drafts WHERE id = :id")
    fun deleteDraft(id: String)

    @Query("DELETE FROM records")
    fun deleteRecords()

    @Query("DELETE FROM assets")
    fun deleteAssets()

    @Query("DELETE FROM resources")
    fun deleteResources()

    @Query("DELETE FROM snapshot_meta")
    fun deleteMeta()

    @Insert
    fun insertRecords(rows: List<RecordEntity>)

    @Insert
    fun insertAssets(rows: List<AssetEntity>)

    @Insert
    fun insertResources(rows: List<ResourceEntity>)

    @Insert
    fun insertMeta(row: SnapshotMetaEntity)

    @Query("SELECT * FROM records")
    fun records(): List<RecordEntity>

    @Query("SELECT * FROM assets")
    fun assets(): List<AssetEntity>

    @Query("SELECT * FROM resources")
    fun resources(): List<ResourceEntity>

    @Query("SELECT * FROM snapshot_meta WHERE id = 1")
    fun meta(): SnapshotMetaEntity?

    @Query("SELECT * FROM sync_state WHERE id = 1")
    fun syncState(): SyncStateEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun insertSyncState(row: SyncStateEntity)
}
