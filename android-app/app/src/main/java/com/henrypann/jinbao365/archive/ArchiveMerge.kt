package com.henrypann.jinbao365.archive

import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Three-way merge for archive protocol v3.
 *
 * `merge(base, local, remote)` and `merge(base, remote, local)` return the same snapshot.
 * [base] is this device's last synced snapshot. Edit stamps already on an input are kept;
 * the merge does not invent one, except that a deleted unknown field stores
 * `conflict: {deleted: true}` with no stamp, as the protocol specifies.
 */
object ArchiveMerge {
    fun merge(base: ArchiveSnapshot, local: ArchiveSnapshot, remote: ArchiveSnapshot): ArchiveSnapshot {
        if (base.version != PROTOCOL_VERSION || local.version != PROTOCOL_VERSION || remote.version != PROTOCOL_VERSION) {
            throw ArchiveProtocolException("unsupported snapshot version")
        }
        val records = mergeEntities(
            base.records, local.records, remote.records,
            idOf = { it.id },
            tombstoneOf = { it.tombstone },
            mergeBoth = ::mergeRecord,
        )
        val neededAssets = referencedAssetIds(records.values)
        val assets = mergeReferenced(
            base.assets, local.assets, remote.assets, neededAssets,
            idOf = { it.id },
            mergeBoth = ::mergeAsset,
            missing = "asset",
        )
        val neededResources = assets.values.flatMap { it.resourceIds }.toSet()
        val resources = mergeReferenced(
            base.resources, local.resources, remote.resources, neededResources,
            idOf = { it.id },
            mergeBoth = ::mergeResource,
            missing = "resource",
        )
        return ArchiveSnapshot(
            version = PROTOCOL_VERSION,
            records = records.values.map { it.copy(mediaOverflow = recordMediaOverflow(it.assetIds.value)) }.sortedWith { left, right -> utf8Compare(left.id, right.id) },
            assets = assets.values.sortedWith { left, right -> utf8Compare(left.id, right.id) },
            resources = resources.values.sortedWith { left, right -> utf8Compare(left.id, right.id) },
            extensions = mergeEnvelopeMap(base.extensions, local.extensions, remote.extensions),
            unknownFields = mergeEnvelopeMap(base.unknownFields, local.unknownFields, remote.unknownFields),
        )
    }
}

private fun <T> mergeEntities(
    base: List<T>,
    local: List<T>,
    remote: List<T>,
    idOf: (T) -> String,
    tombstoneOf: (T) -> FieldEnvelope,
    mergeBoth: (T?, T, T) -> T,
): Map<String, T> {
    fun live(entity: T) = tombstoneOf(entity).isNullValue()
    val baseById = base.associateBy(idOf)
    val localById = local.associateBy(idOf)
    val remoteById = remote.associateBy(idOf)
    val ids = baseById.keys + localById.keys + remoteById.keys
    val result = linkedMapOf<String, T>()
    for (id in ids) {
        val baseEntity = baseById[id]
        val localEntity = localById[id]
        val remoteEntity = remoteById[id]
        val baseTombstone = baseEntity?.let(tombstoneOf)
        localEntity?.let { requireGenerationPreserved(baseTombstone, tombstoneOf(it)) }
        remoteEntity?.let { requireGenerationPreserved(baseTombstone, tombstoneOf(it)) }
        if (baseEntity == null) {
            when {
                localEntity != null && remoteEntity == null -> result[id] = localEntity
                remoteEntity != null && localEntity == null -> result[id] = remoteEntity
                localEntity != null && remoteEntity != null -> result[id] = mergeBoth(null, localEntity, remoteEntity)
            }
            continue
        }
        if (localEntity == null && remoteEntity == null) {
            if (live(baseEntity)) throw ArchiveProtocolException("live id $id is missing from both sides")
            continue
        }
        if (localEntity == null || remoteEntity == null) {
            if (live(baseEntity)) throw ArchiveProtocolException("live id $id was omitted")
            val kept = localEntity ?: remoteEntity!!
            // Omission of an old generation cannot purge an offline restore/redelete.
            if (live(kept) || !sameDeletionGeneration(tombstoneOf(baseEntity), tombstoneOf(kept))) {
                result[id] = kept
            }
            continue
        }
        result[id] = mergeBoth(baseEntity, localEntity, remoteEntity)
    }
    return result
}

private fun <T> mergeReferenced(
    base: List<T>,
    local: List<T>,
    remote: List<T>,
    needed: Set<String>,
    idOf: (T) -> String,
    mergeBoth: (T?, T, T) -> T,
    missing: String,
): Map<String, T> {
    val baseById = base.associateBy(idOf)
    val localById = local.associateBy(idOf)
    val remoteById = remote.associateBy(idOf)
    val result = linkedMapOf<String, T>()
    for (id in needed) {
        val baseEntity = baseById[id]
        val localEntity = localById[id]
        val remoteEntity = remoteById[id]
        result[id] = when {
            localEntity == null && remoteEntity == null ->
                baseEntity ?: throw ArchiveProtocolException("missing $missing $id")
            localEntity == null -> remoteEntity!!
            remoteEntity == null -> localEntity
            else -> mergeBoth(baseEntity, localEntity, remoteEntity)
        }
    }
    return result
}

private fun mergeRecord(base: ArchiveRecord?, local: ArchiveRecord, remote: ArchiveRecord): ArchiveRecord {
    requireSameId(base?.id, local.id, remote.id)
    return ArchiveRecord(
        id = local.id,
        title = mergeOptionalEnvelope(base?.title, local.title, remote.title),
        note = mergeField(base?.note, local.note, remote.note),
        occurredAt = mergeField(base?.occurredAt, local.occurredAt, remote.occurredAt),
        createdAt = mergeField(base?.createdAt, local.createdAt, remote.createdAt),
        assetIds = mergeMedia(base?.assetIds, local.assetIds, remote.assetIds),
        tombstone = mergeTombstone(base?.tombstone, local.tombstone, remote.tombstone),
        extensions = mergeEnvelopeMap(
            base?.extensions ?: emptyMap(),
            local.extensions,
            remote.extensions,
        ),
        unknownFields = mergeEnvelopeMap(
            base?.unknownFields ?: emptyMap(),
            local.unknownFields,
            remote.unknownFields,
        ),
    )
}

private fun mergeAsset(base: MediaAsset?, local: MediaAsset, remote: MediaAsset): MediaAsset {
    requireSameId(base?.id, local.id, remote.id)
    val resourceIds = jsonStringList(
        mergeImmutable(
            base?.resourceIds?.let { stringArray(it) },
            stringArray(local.resourceIds),
            stringArray(remote.resourceIds),
            "resourceIDs",
        ),
    )
    return MediaAsset(
        id = local.id,
        kind = (mergeImmutable(
            base?.let { JsonPrimitive(it.kind) },
            JsonPrimitive(local.kind),
            JsonPrimitive(remote.kind),
            "kind",
        ) as JsonPrimitive).content,
        capturedAt = mergeField(base?.capturedAt, local.capturedAt, remote.capturedAt),
        resourceIds = resourceIds,
        hasLocation = booleanOrAbsent(
            mergeImmutable(
                base?.let { jsonBool(it.hasLocation) },
                jsonBool(local.hasLocation),
                jsonBool(remote.hasLocation),
                "hasLocation",
            ),
        ),
        extensions = mergeEnvelopeMap(base?.extensions ?: emptyMap(), local.extensions, remote.extensions),
        unknownFields = mergeEnvelopeMap(
            base?.unknownFields ?: emptyMap(),
            local.unknownFields,
            remote.unknownFields,
        ),
    )
}

private fun mergeResource(base: MediaResource?, local: MediaResource, remote: MediaResource): MediaResource {
    requireSameId(base?.id, local.id, remote.id)
    fun immutable(label: String, select: (MediaResource) -> JsonElement): JsonElement {
        return mergeImmutable(base?.let(select), select(local), select(remote), label)
    }
    return MediaResource(
        id = local.id,
        assetID = primitiveText(immutable("assetID") { JsonPrimitive(it.assetID) }),
        role = primitiveText(immutable("role") { JsonPrimitive(it.role) }),
        contentType = primitiveText(immutable("contentType") { JsonPrimitive(it.contentType) }),
        originalFilename = primitiveText(immutable("originalFilename") { JsonPrimitive(it.originalFilename) }),
        byteCount = primitiveText(immutable("byteCount") { JsonPrimitive(it.byteCount) }).toLong(),
        sha256 = primitiveText(immutable("sha256") { JsonPrimitive(it.sha256) }),
        objectKey = primitiveText(immutable("objectKey") { JsonPrimitive(it.objectKey) }),
        extensions = mergeEnvelopeMap(base?.extensions ?: emptyMap(), local.extensions, remote.extensions),
        possibleDuplicateOf = mergeOptionalEnvelope(
            base?.possibleDuplicateOf,
            local.possibleDuplicateOf,
            remote.possibleDuplicateOf,
        ),
        unknownFields = mergeEnvelopeMap(
            base?.unknownFields ?: emptyMap(),
            local.unknownFields,
            remote.unknownFields,
        ),
    )
}

/**
 * The winning edit is chosen with the publish clock removed. The earliest
 * firstPublishedAt among sides in the winning deletion generation is written
 * back, and purgeAfter follows it. A restored null drops the clock but keeps its
 * generation. Merge does not invent a clock.
 */
private fun mergeTombstone(
    base: FieldEnvelope?,
    local: FieldEnvelope,
    remote: FieldEnvelope,
): FieldEnvelope {
    val merged = mergeField(
        base?.let(::withoutPublishClock),
        withoutPublishClock(local),
        withoutPublishClock(remote),
    )
    if (merged.isNullValue()) return merged
    val earliest = listOfNotNull(base, local, remote)
        .filter { sameDeletionGeneration(merged, it) }
        .mapNotNull(::readFirstPublishedAt).minOrNull()
        ?: return merged
    return applyPublishClock(merged, earliest)
}

private fun mergeField(base: FieldEnvelope?, local: FieldEnvelope, remote: FieldEnvelope): FieldEnvelope {
    if (base == null) return bothChanged(local, remote)
    return mergePresent(base, local, remote)
}

private fun mergePresent(base: FieldEnvelope, local: FieldEnvelope, remote: FieldEnvelope): FieldEnvelope {
    val localChanged = envelopeChanged(local, base)
    val remoteChanged = envelopeChanged(remote, base)
    if (!localChanged && !remoteChanged) return base
    if (localChanged && !remoteChanged) return local
    if (remoteChanged && !localChanged) return remote
    return bothChanged(local, remote)
}

/**
 * Body is every envelope key except `edit`. The edit stamp alone is not a change.
 * Unknown sibling keys in [FieldEnvelope.extra] are part of the body.
 */
private fun envelopeBody(envelope: FieldEnvelope): JsonObject {
    val map = linkedMapOf<String, JsonElement>("value" to envelope.value)
    envelope.conflict?.let { map["conflict"] = it }
    envelope.extra.forEach { (key, value) -> map[key] = value }
    return sortedObject(map)
}

private fun envelopeChanged(side: FieldEnvelope, base: FieldEnvelope): Boolean =
    !jsonEqual(envelopeBody(side), envelopeBody(base)) || !stampExtraEqual(side.edit, base.edit)

private fun bothChanged(local: FieldEnvelope, remote: FieldEnvelope): FieldEnvelope {
    if (jsonEqual(envelopeBody(local), envelopeBody(remote))) {
        if (stampCompare(local.edit, remote.edit) == 0 && !stampExtraEqual(local.edit, remote.edit)) {
            throw ArchiveProtocolException("equal edit tuple with different values")
        }
        return if (stampCompare(local.edit, remote.edit) >= 0) local else remote
    }
    if (stampCompare(local.edit, remote.edit) == 0) {
        throw ArchiveProtocolException("equal edit tuple with different values")
    }
    val localLater = stampCompare(local.edit, remote.edit) > 0
    val winner = if (localLater) local else remote
    val loser = if (localLater) remote else local
    if (jsonEqual(local.value, remote.value)) return winner
    return winnerWithConflict(winner, loser)
}

private fun winnerWithConflict(winner: FieldEnvelope, loser: FieldEnvelope): FieldEnvelope {
    return winner.copy(
        conflict = JsonObject(
            mapOf(
                "value" to loser.value,
                "edit" to encodeEditStamp(loser.edit),
            ),
        ),
    )
}

private fun mergeOptionalEnvelope(
    base: FieldEnvelope?,
    local: FieldEnvelope?,
    remote: FieldEnvelope?,
): FieldEnvelope? {
    if (base == null && local == null && remote == null) return null
    if (base == null) {
        if (local == null) return remote
        if (remote == null) return local
        return bothChanged(local, remote)
    }
    if (local == null && remote == null) return null
    if (local == null) return deletionVersus(remote!!, base)
    if (remote == null) return deletionVersus(local, base)
    return mergePresent(base, local, remote)
}

private fun deletionVersus(present: FieldEnvelope, base: FieldEnvelope): FieldEnvelope? {
    if (!envelopeChanged(present, base)) return null
    return present.copy(conflict = JsonObject(mapOf("deleted" to JsonPrimitive(true))))
}

private fun mergeEnvelopeMap(
    base: Map<String, FieldEnvelope>,
    local: Map<String, FieldEnvelope>,
    remote: Map<String, FieldEnvelope>,
): Map<String, FieldEnvelope> {
    val result = linkedMapOf<String, FieldEnvelope>()
    for (key in base.keys + local.keys + remote.keys) {
        val merged = mergeOptionalEnvelope(base[key], local[key], remote[key])
        if (merged != null) result[key] = merged
    }
    return result
}

private fun jsonBool(value: Boolean?): JsonElement = if (value == null) JsonNull else JsonPrimitive(value)

private fun booleanOrAbsent(value: JsonElement): Boolean? {
    val primitive = value as? JsonPrimitive ?: return null
    return primitive.booleanOrNull
}

private fun mergeImmutable(
    base: JsonElement?,
    local: JsonElement,
    remote: JsonElement,
    label: String,
): JsonElement {
    if (base == null) {
        if (!jsonEqual(local, remote)) throw ArchiveProtocolException("immutable $label diverged on create")
        return local
    }
    val localChanged = !jsonEqual(local, base)
    val remoteChanged = !jsonEqual(remote, base)
    if (!localChanged && !remoteChanged) return base
    if (localChanged && !remoteChanged) return local
    if (remoteChanged && !localChanged) return remote
    if (jsonEqual(local, remote)) return local
    throw ArchiveProtocolException("immutable $label diverged")
}

private fun mergeMedia(base: FieldEnvelope?, local: FieldEnvelope, remote: FieldEnvelope): FieldEnvelope {
    if (base != null) {
        val localChanged = envelopeChanged(local, base)
        val remoteChanged = envelopeChanged(remote, base)
        if (!localChanged && !remoteChanged) return base
        if (localChanged && !remoteChanged) return local
        if (!localChanged && remoteChanged) return remote
    }
    return mergeMediaBoth(base, local, remote)
}

private fun mergeMediaBoth(base: FieldEnvelope?, local: FieldEnvelope, remote: FieldEnvelope): FieldEnvelope {
    if (jsonEqual(ArchiveJson.encodeEnvelope(local), ArchiveJson.encodeEnvelope(remote))) {
        return local
    }
    if (stampCompare(local.edit, remote.edit) == 0) {
        throw ArchiveProtocolException("equal edit tuple with different assetIDs")
    }
    val baseIds = if (base == null) emptyList() else jsonStringList(base.value)
    val localIds = jsonStringList(local.value)
    val remoteIds = jsonStringList(remote.value)
    val baseSet = baseIds.toSet()
    val localSet = localIds.toSet()
    val remoteSet = remoteIds.toSet()
    val deleted = baseSet.filter { it !in localSet || it !in remoteSet }.toSet()
    val added = (localSet + remoteSet) - baseSet
    val resultSet = (baseSet - deleted) + added
    val localReordered = reordered(localIds, baseIds)
    val remoteReordered = reordered(remoteIds, baseIds)

    fun additions(ids: List<String>) = ids.filter { it !in baseSet && it in resultSet }
    fun orderFrom(winnerIds: List<String>, otherIds: List<String>): List<String> {
        val merged = winnerIds.filter { it in resultSet }.toMutableList()
        val seen = merged.toMutableSet()
        for (id in additions(otherIds)) {
            if (seen.add(id)) merged += id
        }
        return merged
    }

    val localAdditions = additions(localIds)
    val remoteAdditions = additions(remoteIds)

    if (localReordered && remoteReordered) {
        val compared = stampCompare(local.edit, remote.edit)
        val winner = if (compared >= 0) local else remote
        val loser = if (compared >= 0) remote else local
        val winnerIds = if (compared >= 0) localIds else remoteIds
        val loserIds = if (compared >= 0) remoteIds else localIds
        val merged = orderFrom(winnerIds, loserIds)
        val filtered = loserIds.filter { it in resultSet }
        val conflict = if (filtered == merged) {
            null
        } else {
            JsonObject(
                mapOf(
                    "value" to stringArray(filtered),
                    "edit" to encodeEditStamp(loser.edit),
                ),
            )
        }
        return FieldEnvelope(stringArray(merged), winner.edit, conflict, winner.extra)
    }

    if (localReordered || remoteReordered) {
        val winner = if (localReordered) local else remote
        val winnerIds = if (localReordered) localIds else remoteIds
        val otherIds = if (localReordered) remoteIds else localIds
        return FieldEnvelope(stringArray(orderFrom(winnerIds, otherIds)), winner.edit, extra = winner.extra)
    }

    val localListChanged = localIds != baseIds
    val remoteListChanged = remoteIds != baseIds
    if (!localListChanged && !remoteListChanged) return bothChanged(local, remote)

    val survivors = baseIds.filter { it in resultSet }.toMutableList()
    val groups = mutableListOf<Pair<EditStamp, List<String>>>()
    if (localAdditions.isNotEmpty()) groups += local.edit to localAdditions
    if (remoteAdditions.isNotEmpty()) groups += remote.edit to remoteAdditions
    groups.sortWith { left, right -> stampCompare(left.first, right.first) }
    val seen = survivors.toMutableSet()
    for ((_, ids) in groups) {
        for (id in ids) {
            if (seen.add(id)) survivors += id
        }
    }
    val edit = listOfNotNull(
        local.edit.takeIf { localListChanged },
        remote.edit.takeIf { remoteListChanged },
    ).reduce(::laterStamp)
    val extraOwner = when {
        localListChanged && remoteListChanged -> if (stampCompare(local.edit, remote.edit) >= 0) local else remote
        localListChanged -> local
        else -> remote
    }
    return FieldEnvelope(stringArray(survivors), edit, extra = extraOwner.extra)
}

private fun reordered(side: List<String>, base: List<String>): Boolean {
    val baseSet = base.toSet()
    val sideSet = side.toSet()
    return side.filter { it in baseSet } != base.filter { it in sideSet }
}

private fun stampExtraEqual(left: EditStamp?, right: EditStamp?): Boolean =
    jsonEqual(sortedObject(left?.extra ?: emptyMap()), sortedObject(right?.extra ?: emptyMap()))

private fun referencedAssetIds(
    records: Collection<ArchiveRecord>,
): Set<String> {
    val ids = linkedSetOf<String>()
    for (record in records) ids += jsonStringList(record.assetIds.value)
    return ids
}

private fun stampCompare(left: EditStamp, right: EditStamp): Int {
    if (left.counter != right.counter) return left.counter.compareTo(right.counter)
    if (left.at != right.at) return left.at.compareTo(right.at)
    return utf8Compare(left.deviceID, right.deviceID)
}

private fun laterStamp(left: EditStamp, right: EditStamp): EditStamp =
    if (stampCompare(left, right) >= 0) left else right

private fun stringArray(ids: List<String>): JsonArray = JsonArray(ids.map { JsonPrimitive(it) })

private fun primitiveText(element: JsonElement): String {
    val primitive = element as? JsonPrimitive ?: throw ArchiveProtocolException("expected a primitive")
    if (primitive.isString) return primitive.content
    return primitive.content
}

private fun requireSameId(base: String?, local: String, remote: String) {
    if (local != remote || (base != null && base != local)) {
        throw ArchiveProtocolException("entity id mismatch")
    }
}
