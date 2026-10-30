package com.henrypann.jinbao365.data

import com.henrypann.jinbao365.archive.*
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject

data class ImportedMedia(val asset: MediaAsset, val resources: List<MediaResource>)

data class StoredDraft(
    val record: ArchiveRecord,
    val assets: List<MediaAsset>,
    val resources: List<MediaResource>,
    val revision: Long,
    /** Full immutable baseline; only commitDraft compares and writes back to its original ID. */
    val originalRecord: ArchiveRecord? = null,
) {
    val originalRecordId: String? get() = originalRecord?.id
    internal fun snapshot() = ArchiveSnapshot.empty().copy(records = listOf(record), assets = assets, resources = resources)
}

internal fun DraftEntity.decodeDraft(): StoredDraft {
    val snapshot = ArchiveJson.parseSnapshot(Json.parseToJsonElement(payloadJson).jsonObject)
    val record = snapshot.records.single()
    check(record.id == id) { "Draft identity does not match its stored payload." }
    val baseline = originalRecordJson?.let { ArchiveJson.parseSnapshot(it).records.single() }
    check(baseline == null || baseline.id != id) { "An edit draft must have its own identity." }
    return StoredDraft(record, snapshot.assets, snapshot.resources, revision, baseline)
}

internal data class ResolvedMedia(val ids: Map<String, String>, val media: List<ImportedMedia>)

internal fun validateMedia(media: ImportedMedia) {
    val asset = media.asset
    if (asset.id.isBlank() || media.resources.isEmpty() ||
        media.resources.any { it.assetID != asset.id } ||
        media.resources.map { it.id }.distinct().size != media.resources.size ||
        asset.resourceIds.distinct().size != asset.resourceIds.size ||
        asset.resourceIds.toSet() != media.resources.map { it.id }.toSet()) {
        throw ArchiveValidationException("Imported media resources do not match their asset.")
    }
}

internal fun addMedia(snapshot: ArchiveSnapshot, media: List<ImportedMedia>): ArchiveSnapshot {
    val assets = snapshot.assets.associateBy { it.id }.toMutableMap()
    val resources = snapshot.resources.associateBy { it.id }.toMutableMap()
    for (entry in media) {
        validateMedia(entry)
        val before = assets[entry.asset.id]
        if (before != null && before != entry.asset) throw ArchiveValidationException("Conflicting media identity.")
        assets[entry.asset.id] = entry.asset
        for (resource in entry.resources) {
            val prior = resources[resource.id]
            if (prior != null && prior != resource) throw ArchiveValidationException("Conflicting resource identity.")
            resources[resource.id] = resource
        }
    }
    return snapshot.copy(assets = assets.values.sortedWith { a, b -> utf8Compare(a.id, b.id) },
        resources = resources.values.sortedWith { a, b -> utf8Compare(a.id, b.id) })
}
