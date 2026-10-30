package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.archive.hasRecordText
import java.util.Locale

/** Validation errors carry the offending wire entity and field, never server response text. */
class V1ValidationException(message: String) : IllegalArgumentException(message)

data class V1Receipt(val commit: V1Commit, val commitHash: String, val manifest: V1Manifest) {
    /** Newest edit frozen into this manifest; publication time is not evidence of coverage. */
    val packedThrough: Long?
        get() = manifest.moments.maxOfOrNull { it.updatedAt }
}

/** The portable v1 boundary, matching ArchiveManifest, LifeValidation and latest() on iOS. */
object V1Validator {
    const val MAX_TIMESTAMP = 8_640_000_000_000_000L
    const val MAX_REVISION = 9_007_199_254_740_991L
    const val MAX_RESOURCE_BYTES = 2_147_483_648L
    private val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    private val hash = Regex("[a-f0-9]{64}")

    fun validate(manifest: V1Manifest, prefix: String) {
        validatePrefix(prefix)
        requireField(manifest.version in 1..2, "manifest", "version", "This archive needs a newer app version.")
        requireField(manifest.version == 2 || manifest.anniversaries.isEmpty(), "manifest", "anniversaries", "Anniversaries require version 2.")
        identities("anniversaries", manifest.anniversaries.map { it.id })
        manifest.anniversaries.forEach {
            val entity = "anniversaries[${it.id}]"
            requireField(V1Layout.owns(it.owner, prefix), entity, "owner", "Anniversary belongs to another parent.")
            requireField(it.title.isNotBlank() && it.title.length <= 100, entity, "title", "Invalid anniversary title.")
            requireField(it.date.year in 1..9999, entity, "date", "Invalid anniversary date.")
            requireField(it.deletedAt == null || it.deletedAt in 0..MAX_TIMESTAMP, entity, "deletedAt", "Invalid deletion time.")
        }
        identities("moments", manifest.moments.map { it.id })
        identities("assets", manifest.assets.map { it.id })
        identities("resources", manifest.resources.map { it.id })
        manifest.moments.forEach { validateMoment(it) }
        val assets = manifest.assets.associateBy { normalized(it.id) }
        val used = mutableSetOf<String>()
        for (moment in manifest.moments) {
            val entity = "moments[${moment.id}]"
            moment.assetIDs.forEach { id ->
                checkUUID(id, entity, "assetIDs")
                requireField(normalized(id) in assets, entity, "assetIDs", "A selected media item is missing: $id.")
                used += normalized(id)
            }
        }
        assets.keys.firstOrNull { it !in used }?.let { id ->
            invalid("assets[$id]", "id", "Archive contains unreferenced media.")
        }
        for (resource in manifest.resources) {
            val entity = "resources[${resource.id}]"
            checkUUID(resource.assetID, entity, "assetID")
            requireField(normalized(resource.assetID) in used, entity, "assetID", "Archive contains missing or unreferenced media.")
        }
        val byAsset = manifest.resources.groupBy { normalized(it.assetID) }
        for (asset in manifest.assets) validateAsset(asset, byAsset[normalized(asset.id)].orEmpty())
        val objectIdentities = mutableMapOf<String, V1Resource>()
        for (resource in manifest.resources) {
            val entity = "resources[${resource.id}]"
            requireField(resource.objectKey == V1Layout.objectKey(prefix, resource.sha256),
                entity, "objectKey", "Archive contains an invalid object reference.")
            val first = objectIdentities.putIfAbsent(resource.objectKey, resource)
            requireField(first == null || first.byteCount == resource.byteCount && first.sha256 == resource.sha256,
                entity, "objectKey", "The file does not match its saved hash or byteCount (also referenced by ${first?.id}).")
        }
    }

    fun validateCommit(
        commit: V1Commit,
        key: String,
        prefix: String,
        previous: V1Commit? = null,
        previousHash: String? = null,
    ) {
        validatePrefix(prefix)
        val entity = "commits[${commit.sequence}]"
        fun chain(condition: Boolean, field: String) = requireField(condition, entity, field,
            "The archive commit chain is incomplete or invalid. No local data was replaced.")
        chain(commit.version == 1, "version")
        chain(commit.sequence > 0 && (previous?.sequence ?: 0L) < Long.MAX_VALUE &&
            commit.sequence == (previous?.sequence ?: 0L) + 1L, "sequence")
        chain(key == prefix + V1Json.commitRelativeKey(commit.sequence), "key")
        chain((previous == null) == (previousHash == null) && commit.parentHash == previousHash, "parentHash")
        checkUUID(commit.writerDeviceID, entity, "writerDeviceID")
        checkUUID(commit.requestID, entity, "requestID")
        chain(commit.kind in setOf("snapshot", "takeover"), "kind")
        chain(previous != null || commit.kind == "snapshot", "kind")
        chain(previous == null || commit.kind == "takeover" ||
            normalized(commit.writerDeviceID) == normalized(previous.writerDeviceID), "writerDeviceID")
        chain(hash.matches(commit.manifestHash), "manifestHash")
        chain(commit.manifestKey == prefix + "snapshots/${commit.manifestHash}.json", "manifestKey")
        timestamp(commit.createdAt, entity, "createdAt")
        requireField(commit.kind != "takeover" || commit.manifestHash == previous?.manifestHash,
            entity, "manifestHash", "A device takeover changed archive content unexpectedly.")
    }

    /** Hash the original commit bytes: re-encoding would change the parent of noncanonical JSON. */
    fun latest(objects: CosObjectStore, cancellation: BackupCancellation): V1Receipt? {
        val prefix = objects.configuration.prefix
        validatePrefix(prefix)
        cancellation.check()
        val keys = objects.list(prefix + "commits/").sorted()
        var previous: V1Commit? = null
        var previousHash: String? = null
        for (key in keys) {
            cancellation.check()
            val bytes = readRequired(objects, key, "commits[$key]", "key")
            cancellation.check()
            val commit = try { V1Json.decodeCommit(bytes) } catch (failure: V1ValidationException) {
                throw V1ValidationException("commits[$key]: ${failure.message}")
            }
            validateCommit(commit, key, prefix, previous, previousHash)
            previous = commit
            previousHash = V1Json.sha256(bytes)
        }
        val commit = previous ?: return null
        cancellation.check()
        val bytes = readRequired(objects, commit.manifestKey, "commits[${commit.sequence}]", "manifestKey")
        cancellation.check()
        requireField(V1Json.sha256(bytes) == commit.manifestHash, "commits[${commit.sequence}]", "manifestHash",
            "The file does not match its saved hash.")
        val manifest = V1Json.decodeManifest(bytes)
        validate(manifest, prefix)
        return V1Receipt(commit, checkNotNull(previousHash), manifest)
    }

    private fun readRequired(objects: CosObjectStore, key: String, entity: String, field: String): ByteArray =
        try { objects.get(key) } catch (failure: CosException) {
            if (failure.failure != CosFailure.NotFound) throw failure
            invalid(entity, field, "The archive commit chain is incomplete or invalid. Missing archive document: $key.")
        }

    private fun validateMoment(moment: V1Moment) {
        val entity = "moments[${moment.id}]"
        requireField(moment.title.length <= 200, entity, "title", "Title is limited to 200 UTF-16 characters.")
        requireField(moment.note.length <= 10_000, entity, "note", "Note is limited to 10,000 UTF-16 characters.")
        timestamp(moment.occurredAt, entity, "occurredAt")
        timestamp(moment.createdAt, entity, "createdAt")
        timestamp(moment.updatedAt, entity, "updatedAt")
        moment.trashedAt?.let { timestamp(it, entity, "trashedAt") }
        revision(moment.revision, entity)
        requireField(moment.assetIDs.size in 0..30 && moment.assetIDs.map(::normalized).distinct().size == moment.assetIDs.size,
            entity, "assetIDs", "Choose 0–30 distinct media items.")
        requireField(moment.assetIDs.isNotEmpty() || hasRecordText(moment.title, moment.note),
            entity, "assetIDs", "Add a title, note, or media item.")

    }

    private fun validateAsset(asset: V1Asset, resources: List<V1Resource>) {
        val entity = "assets[${asset.id}]"
        timestamp(asset.capturedAt, entity, "capturedAt")
        revision(asset.revision, entity)
        asset.resourceIDs.forEach { checkUUID(it, entity, "resourceIDs") }
        val ids = asset.resourceIDs.map(::normalized).toSet()
        requireField(ids.size == asset.resourceIDs.size && resources.size == asset.resourceIDs.size &&
            resources.all { normalized(it.id) in ids }, entity, "resourceIDs", "Invalid media resources.")
        val expected = when (asset.kind) {
            "photo" -> setOf("photo", "preview")
            "video" -> setOf("video", "preview")
            "motionPhoto" -> setOf("motionPhoto", "preview")
            "livePhoto" -> setOf("livePhotoImage", "livePhotoVideo", "preview")
            else -> invalid(entity, "kind", "Invalid media kind.")
        }
        requireField(resources.map { it.role }.toSet() == expected && resources.size == expected.size,
            entity, "resourceIDs.role", "A complete original and a preview are required.")
        for (resource in resources) {
            val resourceEntity = "resources[${resource.id}]"
            requireField(resource.byteCount in 1..MAX_RESOURCE_BYTES, resourceEntity, "byteCount", "Invalid media resource size.")
            requireField(hash.matches(resource.sha256), resourceEntity, "sha256", "Expected a lowercase SHA-256 hash.")
            val typePrefix = if (resource.role == "video" || resource.role == "livePhotoVideo") "video" else "image"
            requireField(resource.contentType.length <= 120 && Regex("$typePrefix/[a-zA-Z0-9.+-]+").matches(resource.contentType),
                resourceEntity, "contentType", "The media type is invalid for role ${resource.role}.")
            requireField(resource.originalFilename.length in 1..255 &&
                resource.originalFilename.none { it == '/' || it == '\\' || it.code < 32 },
                resourceEntity, "originalFilename", "The original filename is invalid.")
        }
    }

    private fun identities(kind: String, ids: List<String>) {
        val seen = mutableSetOf<String>()
        for (id in ids) {
            checkUUID(id, "$kind[$id]", "id")
            requireField(seen.add(normalized(id)), "$kind[$id]", "id", "Archive contains duplicate identities.")
        }
    }
    private fun timestamp(value: Long, entity: String, field: String) =
        requireField(value in 0..MAX_TIMESTAMP, entity, field, "Choose a valid record date.")
    private fun revision(value: Long, entity: String) =
        requireField(value in 0..MAX_REVISION, entity, "revision", "Invalid record version.")
    private fun checkUUID(value: String, entity: String, field: String) =
        requireField(uuid.matches(value), entity, field, "Expected a UUID: $value.")
    private fun normalized(value: String) = value.uppercase(Locale.ROOT)
    private fun validatePrefix(prefix: String) {
        requireField(prefix.length in 1..256 && prefix.endsWith('/') && !prefix.startsWith('/') &&
            prefix.split('/').dropLast(1).all { it.isNotEmpty() && it != "." && it != ".." && it.matches(Regex("[A-Za-z0-9_-]+")) },
            "configuration", "prefix", "The backup configuration is invalid.")
    }
    private fun requireField(condition: Boolean, entity: String, field: String, reason: String) {
        if (!condition) invalid(entity, field, reason)
    }
    private fun invalid(entity: String, field: String, reason: String): Nothing =
        throw V1ValidationException("$entity.$field: $reason")
}
