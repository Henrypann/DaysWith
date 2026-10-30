package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.archive.ArchiveRecord
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.archive.EditStamp
import com.henrypann.jinbao365.archive.ImportProvenance
import com.henrypann.jinbao365.archive.importProvenance
import com.henrypann.jinbao365.data.Anniversary
import java.util.Locale
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/** Read-only projection. Nothing here rewrites v3 records or their field envelopes. */
object V1Mapper {
    /** Uses every envelope/link edit, including unknown fields, without requiring valid media. */
    fun updatedAt(record: ArchiveRecord): Long = maxOf(
        integer(record.createdAt.value, "records[${record.id}].createdAt"),
        record.edits().maxOf { it.at },
    )

    fun map(snapshot: ArchiveSnapshot, prefix: String, anniversaries: List<Anniversary> = emptyList()): V1Manifest {
        val used = snapshot.records.flatMap { strings(it.assetIds.value, "records[${it.id}].assetIDs") }.toSet()
        val moments = snapshot.records.map { record ->
            val path = "records[${record.id}]"
            val createdAt = integer(record.createdAt.value, "$path.createdAt")
            val edits = record.edits()
            val title = record.title?.value?.takeUnless { it is JsonNull }?.let { string(it, "$path.title") } ?: ""
            V1Moment(
                id = V1Ids.map("record", record.id), title = title, note = string(record.note.value, "$path.note"),
                occurredAt = integer(objectValue(record.occurredAt.value, "$path.occurredAt")["utc"], "$path.occurredAt.utc"),
                createdAt = createdAt, updatedAt = updatedAt(record),
                assetIDs = strings(record.assetIds.value, "$path.assetIDs").map { V1Ids.map("asset", it) },
                trashedAt = record.tombstone.value.takeUnless { it is JsonNull }?.let {
                    integer(objectValue(it, "$path.tombstone")["deletedAt"], "$path.tombstone.deletedAt")
                },
                revision = edits.maxOf { it.counter },
                deviceManufacturer = record.extensions["deviceManufacturer"]?.value?.let { string(it, "$path.deviceManufacturer") },
                deviceModel = record.extensions["deviceModel"]?.value?.let { string(it, "$path.deviceModel") },
            )
        }.sortedBy { it.id }
        val assets = snapshot.assets.filter { it.id in used }.map { asset ->
            val path = "assets[${asset.id}].capturedAt"
            val capture = objectValue(asset.capturedAt.value, path)
            val unknown = boolean(capture["timeUnknown"], "$path.timeUnknown")
            V1Asset(
                id = V1Ids.map("asset", asset.id), kind = asset.kind,
                capturedAt = if (unknown) 0L else integer(capture["utc"], "$path.utc"),
                resourceIDs = asset.resourceIds.map { V1Ids.map("resource", it) }, revision = 0L,
                importProvenance = asset.importProvenance.takeUnless { it == ImportProvenance.Unknown }?.wireValue,
            )
        }.sortedBy { it.id }
        val resources = snapshot.resources.filter { it.assetID in used }.map { resource ->
            val hash = resource.sha256.lowercase(Locale.ROOT)
            V1Resource(
                id = V1Ids.map("resource", resource.id), assetID = V1Ids.map("asset", resource.assetID),
                role = resource.role, contentType = resource.contentType,
                originalFilename = safeFilename(resource.originalFilename), byteCount = resource.byteCount,
                sha256 = hash, objectKey = V1Layout.objectKey(prefix, hash),
            )
        }.sortedBy { it.id }
        return V1Manifest(version = 2, moments = moments, assets = assets, resources = resources,
            anniversaries = anniversaries.filter { V1Layout.owns(it.owner, prefix) }.sortedBy { it.id })
            .also { V1Validator.validate(it, prefix) }
    }

    private fun ArchiveRecord.edits(): List<EditStamp> =
        (listOfNotNull(title, note, occurredAt, createdAt, assetIds, tombstone) +
            extensions.values + unknownFields.values).map { it.edit }

    private fun safeFilename(filename: String): String {
        val replaced = filename.map { if (it == '/' || it == '\\' || Character.isISOControl(it)) '_' else it }.joinToString("")
        if (replaced.isEmpty()) return "import"
        if (replaced.length <= 255) return replaced
        // Swift's limit is in UTF-16 units. Do not cut an emoji in the middle of its surrogate pair.
        val end = if (Character.isHighSurrogate(replaced[254]) && Character.isLowSurrogate(replaced[255])) 254 else 255
        return replaced.substring(0, end)
    }

    private fun objectValue(value: JsonElement, path: String) = value as? JsonObject ?: invalid(path, "Expected an object.")
    private fun string(value: JsonElement, path: String): String = (value as? JsonPrimitive)
        ?.takeIf { it.isString }?.content ?: invalid(path, "Expected a string.")
    private fun strings(value: JsonElement, path: String): List<String> = (value as? JsonArray)
        ?.mapIndexed { index, item -> string(item, "$path[$index]") } ?: invalid(path, "Expected an array of strings.")
    private fun integer(value: JsonElement?, path: String): Long {
        val primitive = value as? JsonPrimitive ?: invalid(path, "Expected an integer.")
        if (primitive.isString || !Regex("-?(0|[1-9][0-9]*)").matches(primitive.content)) invalid(path, "Expected an integer.")
        return primitive.content.toLongOrNull() ?: invalid(path, "Expected an Int64 integer.")
    }
    private fun boolean(value: JsonElement?, path: String): Boolean {
        val primitive = value as? JsonPrimitive ?: invalid(path, "Expected a boolean.")
        return if (primitive.isString) invalid(path, "Expected a boolean.")
        else primitive.booleanOrNull ?: invalid(path, "Expected a boolean.")
    }
    private fun invalid(path: String, reason: String): Nothing = throw V1ValidationException("$path: $reason")
}
