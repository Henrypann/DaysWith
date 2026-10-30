package com.henrypann.jinbao365.data

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * Room rows for one v3 snapshot. Field envelopes, extensions and unknown
 * fields are canonical JSON so a value the app does not understand round-trips.
 * mediaOverflow is a derived flag that merge writes onto a record; it is nullable because an input snapshot
 * may not have them yet.
 */
@Entity(tableName = "records")
data class RecordEntity(
    @PrimaryKey val id: String,
    val titleJson: String,
    val noteJson: String,
    val occurredAtJson: String,
    val createdAtJson: String,
    val assetIdsJson: String,
    val tombstoneJson: String,
    val extensionsJson: String,
    val unknownFieldsJson: String,
    val mediaOverflow: Boolean?,
)

@Entity(tableName = "assets")
data class AssetEntity(
    @PrimaryKey val id: String,
    val kind: String,
    val capturedAtJson: String,
    val resourceIdsJson: String,
    val extensionsJson: String,
    val unknownFieldsJson: String,
)

@Entity(
    tableName = "resources",
    indices = [Index(value = ["assetId"])],
)
data class ResourceEntity(
    @PrimaryKey val id: String,
    val assetId: String,
    val role: String,
    val contentType: String,
    val originalFilename: String,
    val byteCount: Long,
    val sha256: String,
    val objectKey: String,
    val possibleDuplicateOfJson: String?,
    val extensionsJson: String,
    val unknownFieldsJson: String,
)

/**
 * Local sync cursor. Not part of the portable snapshot.
 * [ownerDeviceId] is the device id that last owned this database file.
 * A mismatch means the file was restored onto another phone: drop the cursor
 * and walk the commit chain from sequence 1. The snapshot rows stay.
 */
@Entity(tableName = "sync_state")
data class SyncStateEntity(
    @PrimaryKey val id: Int = SINGLETON_ID,
    val ownerDeviceId: String?,
    val verifiedThroughSequence: Long?,
    val verifiedThroughHash: String?,
    val resyncFromStart: Boolean,
) {
    companion object {
        const val SINGLETON_ID = 1
    }
}

@Entity(tableName = "snapshot_meta")
data class SnapshotMetaEntity(
    @PrimaryKey val id: Int = SINGLETON_ID,
    val version: Int,
    val extensionsJson: String,
    val unknownFieldsJson: String,
) {
    companion object {
        const val SINGLETON_ID = 1
    }
}

/** Local-only draft and owned media. Never exported through ArchiveSnapshot. */
@Entity(tableName = "drafts")
data class DraftEntity(
    @PrimaryKey val id: String,
    val payloadJson: String,
    val revision: Long,
    /** Local edit baseline; null for a new moment draft. */
    val originalRecordJson: String? = null,
)

/** Durable Save receipt: retrying a completed draft commit never creates a second record. */
@Entity(tableName = "draft_commits")
data class DraftCommitEntity(@PrimaryKey val id: String, val recordId: String)

/** Durable local work journal; never included in snapshots or backup manifests. */
@Entity(tableName = "pending_media_tasks", indices = [Index(value = ["draftId"])])
data class PendingMediaTaskEntity(
    @PrimaryKey val id: String,
    val draftId: String,
    val origin: String,
    val status: String,
    val payloadJson: String,
    val completedItems: Int,
    val totalItems: Int,
    val errorMessage: String?,
    val ownsDraft: Boolean,
)

/** Local-only, ordered per-file receipt. A successful append and this receipt commit together. */
@Entity(tableName = "pending_media_items", indices = [Index(value = ["taskId"])])
data class PendingMediaItemEntity(
    @PrimaryKey val id: String,
    val taskId: String,
    val position: Int,
    val uri: String,
    val origin: String,
    val status: String,
    val assetId: String?,
    val ownsPosition: Boolean,
    val provenance: String?,
    val errorMessage: String?,
)
