package com.henrypann.jinbao365.data

import androidx.room.Entity
import java.time.LocalDate

data class Anniversary(
    val id: String,
    val owner: ParentIdentity,
    val title: String,
    val date: LocalDate,
    val deletedAt: Long? = null,
)

data class AnniversarySource(val bucket: String, val region: String)

/** The creator is part of the key: colliding remote IDs cannot replace a local anniversary. */
@Entity(tableName = "anniversaries", primaryKeys = ["owner", "id"])
data class AnniversaryEntity(
    val id: String,
    val owner: String,
    val title: String,
    val date: String,
    val deletedAt: Long?,
    val sourceBucket: String? = null,
    val sourceRegion: String? = null,
)

internal fun Anniversary.entity() = AnniversaryEntity(id, owner.folder, title, date.toString(), deletedAt)
internal fun AnniversaryEntity.model() = Anniversary(id,
    ParentIdentity.entries.single { it.folder == owner }, title, LocalDate.parse(date), deletedAt)
