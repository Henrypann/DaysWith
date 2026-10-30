package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.archive.ArchiveRecord
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.archive.EditStamp
import com.henrypann.jinbao365.archive.FieldEnvelope
import com.henrypann.jinbao365.archive.ImportProvenance
import com.henrypann.jinbao365.archive.MediaAsset
import com.henrypann.jinbao365.archive.MediaResource
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.data.Anniversary
import com.henrypann.jinbao365.data.AnniversarySource
import com.henrypann.jinbao365.media.CaptureTime
import com.henrypann.jinbao365.storage.StorageConfiguration
import com.henrypann.jinbao365.storage.StorageCredentials
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * Reads the OTHER parent's chains (legacy root + every device) and this parent's sibling devices. Records remain a read-only UI projection; anniversaries
 * have an owner-scoped local cache updated only after the complete archive validates.
 * Remote IDs and cache paths include their source parent so colliding wire UUIDs cannot become edits.
 */
class ParentArchiveReader(
    private val mediaRoot: File,
    private val cacheAnniversaries: (ParentIdentity, List<Anniversary>, AnniversarySource) -> Unit = { _, _, _ -> },
    private val objectStore: (StorageConfiguration, StorageCredentials, BackupCancellation) -> CosObjectStore =
        { config, credentials, cancellation -> CosObjectClient(config, credentials, cancellation) },
) {
    fun read(
        root: StorageConfiguration,
        credentials: StorageCredentials,
        owner: ParentIdentity,
        isActive: () -> Boolean = { true },
        cancellation: BackupCancellation = BackupCancellation(),
        selfDeviceId: String? = null,
    ): ArchiveSnapshot {
        fun checkpoint() {
            cancellation.check()
            if (!isActive()) { cancellation.cancel(); throw CancellationException() }
        }
        val other = owner.other
        // Other parent: every chain. Own parent: sibling devices only (never this device's chain).
        val parents = listOfNotNull(other, owner.takeIf { selfDeviceId != null })
        val sources = mutableListOf<Source>()
        val stores = mutableMapOf<String, CosObjectStore>()
        for (parent in parents) {
            checkpoint()
            val identity = V1Destination.forParent(root, parent)
            val rootStore = objectStore(identity, credentials, cancellation)
            if (rootStore.configuration != identity) throw CosException(CosFailure.Configuration)
            val own = selfDeviceId?.takeIf { parent == owner }?.let { V1Layout.chainPrefix(parent, it, false) }
            val chains = V1Layout.chainsUnder(parent.prefix, ReadOnlyCosStore(rootStore, ::checkpoint).list(parent.prefix))
                .ifEmpty { if (parent == other) listOf(parent.prefix) else emptyList() }
            for (chain in chains) {
                if (chain == own) continue
                val config = root.copy(prefix = chain)
                val raw = if (chain == parent.prefix) rootStore else objectStore(config, credentials, cancellation)
                if (raw.configuration != config) throw CosException(CosFailure.Configuration)
                // V1Validator only receives an explicitly read-only facade.
                val objects = ReadOnlyCosStore(raw, ::checkpoint)
                checkpoint()
                val receipt = V1Validator.latest(objects, cancellation)
                if (parent == owner && receipt != null && selfDeviceId != null &&
                    receipt.commit.writerDeviceID.equals(selfDeviceId, ignoreCase = true)) continue // already local
                if (receipt == null && chain != parent.prefix) continue
                val manifest = receipt?.manifest ?: V1Manifest()
                stores[chain] = objects
                sources += Source(parent, chain, receipt?.commit?.writerDeviceID ?: "remote-${parent.folder}", manifest,
                    receipt?.commit?.createdAt ?: 0L)
            }
        }
        // Select whole record copies before projecting media: wire asset/resource IDs can collide
        // across chains, and losing copies must never supply the winning record's media graph.
        val visible = visibleSources(sources)
        for (source in visible) download(stores.getValue(source.prefix), source.parent, source.manifest, ::checkpoint)
        checkpoint()
        // Cache the exact validated manifests only after ALL visible media are present and verified.
        val directory = File(mediaRoot, "remote").apply { mkdirs() }
        val temporary = File.createTempFile("sources-", ".partial", directory)
        try {
            val cache = buildJsonObject {
                put("bucket", root.bucket); put("region", root.region); put("owner", owner.folder)
                put("sources", JsonArray(sources.map { source -> buildJsonObject {
                    put("parent", source.parent.folder); put("prefix", source.prefix); put("writer", source.writer)
                    put("createdAt", source.createdAt)
                    put("manifest", V1Json.encodeManifest(source.manifest).toString(Charsets.UTF_8))
                } }))
            }.toString().toByteArray(Charsets.UTF_8)
            FileOutputStream(temporary).use { it.write(cache); it.fd.sync() }
            checkpoint()
            if (!temporary.renameTo(File(directory, CACHE_V2))) throw BackupException(BackupFailure.State)
        } finally { temporary.delete() }
        cacheAnniversaries(owner, mergedAnniversaries(sources, other), AnniversarySource(root.bucket, root.region))
        return merge(sources)
    }

    private fun download(objects: CosObjectStore, parent: ParentIdentity, manifest: V1Manifest, checkpoint: () -> Unit) {
        val used = manifest.moments.filter { it.trashedAt == null }.flatMap { it.assetIDs }.map(::normalized).toSet()
        val resources = manifest.resources.filter { normalized(it.assetID) in used }
        for (resource in resources.distinctBy { it.objectKey }) {
            checkpoint()
            val target = File(mediaRoot, cachePath(parent, resource))
            if (verifiedFile(target, resource, checkpoint)) continue
            target.parentFile!!.mkdirs()
            val temporary = File.createTempFile("download-", ".partial", target.parentFile)
            try {
                val downloaded = FileOutputStream(temporary).use { output ->
                    val checked = object : OutputStream() {
                        override fun write(value: Int) { checkpoint(); output.write(value) }
                        override fun write(bytes: ByteArray, offset: Int, length: Int) {
                            checkpoint(); output.write(bytes, offset, length)
                        }
                    }
                    val result = objects.download(resource.objectKey, checked)
                    output.fd.sync()
                    result
                }
                checkpoint()
                if (downloaded.byteCount != resource.byteCount || downloaded.sha256 != resource.sha256 ||
                    !verifiedFile(temporary, resource, checkpoint)) throw BackupException(BackupFailure.ArchivedFile)
                if (!temporary.renameTo(target)) throw BackupException(BackupFailure.State)
            } finally { temporary.delete() }
        }
    }

    /** Last complete local cache is available offline; its folder and account binding are checked. */
    fun loadCached(owner: ParentIdentity, root: StorageConfiguration? = null): ArchiveSnapshot {
        val other = owner.other
        val v2 = File(mediaRoot, "remote/$CACHE_V2")
        val legacy = File(mediaRoot, "remote/${other.folder}/snapshot.json")
        val file = if (v2.isFile) v2 else legacy
        if (!file.isFile || file.length() > 8L * BackupEngine.METADATA_LIMIT) return ArchiveSnapshot.empty()
        return runCatching {
            val cache = Json.parseToJsonElement(file.readText()).jsonObject
            if (root != null && (cache.getValue("bucket").jsonPrimitive.content != root.bucket ||
                    cache.getValue("region").jsonPrimitive.content != root.region)) return ArchiveSnapshot.empty()
            val entries = if (file == v2) {
                if (cache.getValue("owner").jsonPrimitive.content != owner.folder) return ArchiveSnapshot.empty()
                cache.getValue("sources").jsonArray.map { it.jsonObject }
            } else listOf(cache + mapOf("parent" to JsonPrimitive(other.folder)))
            val sources = entries.map { entry ->
                val parent = ParentIdentity.entries.first { it.folder == entry.getValue("parent").jsonPrimitive.content }
                val prefix = entry.getValue("prefix").jsonPrimitive.content
                val suffix = prefix.removePrefix(parent.prefix)
                check(prefix.startsWith(parent.prefix) && (suffix.isEmpty() ||
                    suffix.endsWith('/') && V1Layout.isDeviceSegment(suffix.dropLast(1))))
                // Legacy snapshot.json always represents the OTHER parent's root chain.
                check(file == v2 || parent == other && prefix == other.prefix)
                val manifest = V1Json.decodeManifest(entry.getValue("manifest").jsonPrimitive.content.toByteArray(Charsets.UTF_8))
                V1Validator.validate(manifest, prefix)
                Source(parent, prefix, entry.getValue("writer").jsonPrimitive.content, manifest,
                    entry["createdAt"]?.jsonPrimitive?.content?.toLongOrNull() ?: 0L)
            }
            check(sources.map { it.prefix }.distinct().size == sources.size)
            for (source in visibleSources(sources)) {
                val used = source.manifest.moments.flatMap { it.assetIDs }.map(::normalized).toSet()
                check(source.manifest.resources.filter { normalized(it.assetID) in used }.all { resource ->
                    verifiedFile(File(mediaRoot, cachePath(source.parent, resource)), resource) { }
                })
            }
            cacheAnniversaries(owner, mergedAnniversaries(sources, other), AnniversarySource(
                cache.getValue("bucket").jsonPrimitive.content, cache.getValue("region").jsonPrimitive.content))
            merge(sources)
        }.getOrDefault(ArchiveSnapshot.empty())
    }

    private data class Source(val parent: ParentIdentity, val prefix: String, val writer: String,
                              val manifest: V1Manifest, val createdAt: Long)
    private data class Copy(val source: Source, val moment: V1Moment)

    /** Publication time orders anniversary copies; a deletion wins an equal-time live copy. */
    private fun mergedAnniversaries(sources: List<Source>, other: ParentIdentity): List<Anniversary> =
        sources.filter { it.parent == other }.flatMap { source ->
            source.manifest.anniversaries.map { source to it }
        }.groupBy { normalized(it.second.id) }.toSortedMap().values.map { copies ->
            copies.maxWith(compareBy({ it.first.createdAt }, { it.second.deletedAt != null }, { it.first.prefix })).second
        }

    /** Keep the complete winning source graph, with deterministic ordering for identical edits. */
    private fun visibleSources(sources: List<Source>): List<Source> {
        val winners = sources.flatMap { source -> source.manifest.moments.map { Copy(source, it) } }
            .groupBy { "${it.source.parent.folder}:${normalized(it.moment.id)}" }.toSortedMap().values
            .map { copies -> copies.maxWith(compareBy({ it.moment.updatedAt }, { it.moment.revision },
                { it.moment.trashedAt != null }, { it.source.prefix })) }
            .filter { it.moment.trashedAt == null }
        return sources.sortedBy { it.prefix }.map { source ->
            source.copy(manifest = source.manifest.copy(moments = winners.filter { it.source === source }.map { it.moment }))
        }
    }

    private fun merge(sources: List<Source>): ArchiveSnapshot {
        val parts = visibleSources(sources).map { project(it) }
        return ArchiveSnapshot(records = parts.flatMap { it.records }.sortedBy { it.id },
            assets = parts.flatMap { it.assets }, resources = parts.flatMap { it.resources }, extensions = emptyMap())
    }

    private fun project(source: Source): ArchiveSnapshot {
        val (parent, prefix, writer, manifest) = source
        // Record IDs remain stable as the winning chain changes. Media are scoped to that chain,
        // so unrelated UUIDs (or revised media using the same UUID) cannot alias another graph.
        val chain = V1Json.sha256(prefix.toByteArray(Charsets.UTF_8))
        fun id(kind: String, value: String) = if (kind == "record") "remote:${parent.folder}:$kind:${normalized(value)}"
            else "remote:${parent.folder}:$kind:$chain:${normalized(value)}"
        fun field(value: JsonElement, at: Long, revision: Long = 0) = FieldEnvelope(value, EditStamp(revision, at, writer))
        val moments = manifest.moments.filter { it.trashedAt == null }
        val used = moments.flatMap { it.assetIDs }.map(::normalized).toSet()
        val records = moments.map { moment ->
            fun f(value: JsonElement) = field(value, moment.updatedAt, moment.revision)
            ArchiveRecord(
                id = id("record", moment.id), title = f(JsonPrimitive(moment.title)), note = f(JsonPrimitive(moment.note)),
                occurredAt = f(buildJsonObject { put("utc", moment.occurredAt); put("zoneUnknown", true) }),
                createdAt = f(JsonPrimitive(moment.createdAt)),
                assetIds = f(JsonArray(moment.assetIDs.map { JsonPrimitive(id("asset", it)) })),
                tombstone = f(JsonNull),
                extensions = mapOf("parent" to f(JsonPrimitive(parent.folder)), "readOnly" to f(JsonPrimitive(true))) +
                    listOfNotNull(moment.deviceManufacturer?.let { "deviceManufacturer" to f(JsonPrimitive(it)) },
                        moment.deviceModel?.let { "deviceModel" to f(JsonPrimitive(it)) }).toMap(),
            )
        }
        val assets = manifest.assets.filter { normalized(it.id) in used }.map { asset ->
            // v1 stores the instant only: do not invent the original shooting time zone.
            val capture = CaptureTime.atRead(CaptureTime.zoneUnknown(asset.capturedAt))
            val capturedAt = field(capture, maxOf(0L, asset.capturedAt), asset.revision)
            val provenance = ImportProvenance.fromWire(asset.importProvenance)
            MediaAsset(id("asset", asset.id), asset.kind, capturedAt,
                asset.resourceIDs.map { id("resource", it) },
                if (provenance == ImportProvenance.Unknown) emptyMap() else mapOf(
                    ImportProvenance.EXTENSION_KEY to FieldEnvelope(JsonPrimitive(provenance.wireValue), capturedAt.edit)))
        }
        val resources = manifest.resources.filter { normalized(it.assetID) in used }.map { resource ->
            MediaResource(id("resource", resource.id), id("asset", resource.assetID), resource.role,
                resource.contentType, resource.originalFilename, resource.byteCount, resource.sha256,
                cachePath(parent, resource), emptyMap())
        }
        return ArchiveSnapshot(records = records, assets = assets, resources = resources, extensions = emptyMap())
    }

    private fun verifiedFile(file: File, resource: V1Resource, checkpoint: () -> Unit): Boolean {
        if (!file.isFile || file.length() != resource.byteCount) return false
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                checkpoint()
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) } == resource.sha256
    }

    companion object {
        const val CACHE_V2 = "sources-v2.json"
        const val CAPTURE_FLOOR_MILLIS = 315619200000L // 1980-01-02T00:00:00Z
        private fun normalized(value: String) = value.uppercase(Locale.ROOT)
        private fun cachePath(parent: ParentIdentity, resource: V1Resource) =
            "remote/${parent.folder}/objects/${resource.sha256.take(2)}/${resource.sha256}"
    }
}

/** There is no route from a remote-read operation to a write on the other parent's folder. */
private class ReadOnlyCosStore(private val source: CosObjectStore, private val check: () -> Unit) : CosObjectStore {
    override val configuration get() = source.configuration
    override fun list(prefix: String): List<String> { check(); return source.list(prefix) }
    override fun head(key: String): CosObjectInfo? { check(); return source.head(key) }
    override fun get(key: String): ByteArray { check(); return source.get(key) }
    override fun download(key: String, output: OutputStream): CosDownload { check(); return source.download(key, output) }
    private fun denied(): Nothing = throw CosException(CosFailure.Permission)
    override fun put(key: String, bytes: ByteArray, contentType: String): Unit = denied()
    override fun putFile(key: String, file: File, contentType: String): Unit = denied()
    override fun initiateMultipart(key: String, contentType: String, sha256: String): String = denied()
    override fun uploadPart(key: String, uploadId: String, partNumber: Int, file: File, offset: Long, length: Long): String = denied()
    override fun listParts(key: String, uploadId: String): List<CosPart> = denied()
    override fun completeMultipart(key: String, uploadId: String, parts: List<CosPart>): Unit = denied()
}
