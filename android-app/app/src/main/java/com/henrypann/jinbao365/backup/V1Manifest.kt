package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.data.Anniversary

/** Version 1 stays readable; version 2 adds family metadata with optional backward-readable asset provenance. */
data class V1Manifest(
    val version: Int = 1,
    val moments: List<V1Moment> = emptyList(),
    val assets: List<V1Asset> = emptyList(),
    val resources: List<V1Resource> = emptyList(),
    val anniversaries: List<Anniversary> = emptyList(),
)

data class V1Moment(
    val id: String,
    val title: String = "",
    val note: String = "",
    val occurredAt: Long,
    val createdAt: Long,
    val updatedAt: Long,
    val assetIDs: List<String>,
    val trashedAt: Long? = null,
    val revision: Long = 0,
    val deviceManufacturer: String? = null,
    val deviceModel: String? = null,
)

data class V1Asset(
    val id: String,
    val kind: String,
    val capturedAt: Long,
    val resourceIDs: List<String>,
    val revision: Long = 0,
    /** Optional evidence about saved bytes; absent in legacy snapshots and unknown to older readers. */
    val importProvenance: String? = null,
)

data class V1Resource(
    val id: String,
    val assetID: String,
    val role: String,
    val contentType: String,
    val originalFilename: String,
    val byteCount: Long,
    val sha256: String,
    val objectKey: String,
)
