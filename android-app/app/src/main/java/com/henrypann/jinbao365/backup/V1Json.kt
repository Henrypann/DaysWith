package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.archive.ImportProvenance
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.Locale
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import com.henrypann.jinbao365.data.Anniversary
import com.henrypann.jinbao365.data.ParentIdentity
import java.time.LocalDate

/** Independent of v3 canonical JSON. Preserves the original version-1 encoding when reading legacy archives. */
object V1Json {
    const val METADATA_LIMIT = 32 * 1024 * 1024

    fun encodeManifest(manifest: V1Manifest): ByteArray = encode(obj(
        "version" to JsonPrimitive(manifest.version),
        "moments" to JsonArray(manifest.moments.map { moment -> obj(
            "id" to uuid(moment.id, "moments.id"),
            "title" to JsonPrimitive(moment.title), "note" to JsonPrimitive(moment.note),
            "occurredAt" to JsonPrimitive(moment.occurredAt), "createdAt" to JsonPrimitive(moment.createdAt),
            "updatedAt" to JsonPrimitive(moment.updatedAt), "revision" to JsonPrimitive(moment.revision),
            "assetIDs" to uuids(moment.assetIDs, "moments.assetIDs"),
            "trashedAt" to moment.trashedAt?.let(::JsonPrimitive),
            "deviceManufacturer" to moment.deviceManufacturer?.let(::JsonPrimitive),
            "deviceModel" to moment.deviceModel?.let(::JsonPrimitive),
        ) }),
        "assets" to JsonArray(manifest.assets.map { asset -> obj(
            "id" to uuid(asset.id, "assets.id"), "kind" to JsonPrimitive(asset.kind),
            "capturedAt" to JsonPrimitive(asset.capturedAt), "revision" to JsonPrimitive(asset.revision),
            "resourceIDs" to uuids(asset.resourceIDs, "assets.resourceIDs"),
            "importProvenance" to knownProvenance(asset.importProvenance)?.let(::JsonPrimitive),
        ) }),
        "anniversaries" to if (manifest.version >= 2) JsonArray(manifest.anniversaries.map { anniversary -> obj(
            "id" to uuid(anniversary.id, "anniversaries.id"),
            "owner" to JsonPrimitive(anniversary.owner.folder), "title" to JsonPrimitive(anniversary.title),
            "date" to JsonPrimitive(anniversary.date.toString()),
            "deletedAt" to anniversary.deletedAt?.let(::JsonPrimitive),
        ) }) else null,
        "resources" to JsonArray(manifest.resources.map { resource -> obj(
            "id" to uuid(resource.id, "resources.id"), "assetID" to uuid(resource.assetID, "resources.assetID"),
            "role" to JsonPrimitive(resource.role), "contentType" to JsonPrimitive(resource.contentType),
            "originalFilename" to JsonPrimitive(resource.originalFilename),
            "byteCount" to JsonPrimitive(resource.byteCount), "sha256" to JsonPrimitive(resource.sha256),
            "objectKey" to JsonPrimitive(resource.objectKey),
        ) }),
    ))

    fun encodeCommit(commit: V1Commit): ByteArray = encode(obj(
        "version" to JsonPrimitive(commit.version), "sequence" to JsonPrimitive(commit.sequence),
        "parentHash" to commit.parentHash?.let(::JsonPrimitive),
        "writerDeviceID" to uuid(commit.writerDeviceID, "commit.writerDeviceID"),
        "kind" to JsonPrimitive(commit.kind), "manifestHash" to JsonPrimitive(commit.manifestHash),
        "manifestKey" to JsonPrimitive(commit.manifestKey), "createdAt" to JsonPrimitive(commit.createdAt),
        "requestID" to uuid(commit.requestID, "commit.requestID"),
    ))

    fun decodeManifest(bytes: ByteArray): V1Manifest {
        val root = parse(bytes, "manifest")
        val manifest = V1Manifest(
            version = root.int("version", "manifest"),
            moments = root.array("moments", "manifest").mapIndexed { index, raw ->
                val path = "moments[$index]"
                val o = raw.objectValue(path)
                V1Moment(
                    id = o.id("id", path), title = o.text("title", path), note = o.text("note", path),
                    occurredAt = o.long("occurredAt", path), createdAt = o.long("createdAt", path),
                    updatedAt = o.long("updatedAt", path), assetIDs = o.ids("assetIDs", path),
                    trashedAt = o.optional("trashedAt")?.integer("$path.trashedAt"),
                    revision = o.long("revision", path),
                    deviceManufacturer = o.optional("deviceManufacturer")?.textValue("$path.deviceManufacturer"),
                    deviceModel = o.optional("deviceModel")?.textValue("$path.deviceModel"),
                )
            },
            anniversaries = if (root.int("version", "manifest") >= 2)
                root.array("anniversaries", "manifest").mapIndexed { index, raw ->
                    val path = "anniversaries[$index]"
                    val o = raw.objectValue(path)
                    Anniversary(o.id("id", path),
                        ParentIdentity.entries.firstOrNull { it.folder == o.text("owner", path) }
                            ?: invalid(path, "Invalid parent identity."),
                        o.text("title", path),
                        try { LocalDate.parse(o.text("date", path)) }
                        catch (_: Exception) { invalid(path, "Invalid anniversary date.") },
                        o.optional("deletedAt")?.integer("$path.deletedAt"))
                } else emptyList(),
            assets = root.array("assets", "manifest").mapIndexed { index, raw ->
                val path = "assets[$index]"
                val o = raw.objectValue(path)
                V1Asset(
                    id = o.id("id", path), kind = o.text("kind", path), capturedAt = o.long("capturedAt", path),
                    resourceIDs = o.ids("resourceIDs", path), revision = o.long("revision", path),
                    importProvenance = knownProvenance((o.optional("importProvenance") as? JsonPrimitive)
                        ?.takeIf { it.isString }?.content),
                )
            },
            resources = root.array("resources", "manifest").mapIndexed { index, raw ->
                val path = "resources[$index]"
                val o = raw.objectValue(path)
                V1Resource(
                    id = o.id("id", path), assetID = o.id("assetID", path), role = o.text("role", path),
                    contentType = o.text("contentType", path), originalFilename = o.text("originalFilename", path),
                    byteCount = o.long("byteCount", path), sha256 = o.text("sha256", path), objectKey = o.text("objectKey", path),
                )
            },
        )
        // Older snapshots may contain media owned only by a retired collection.
        // The wire hash is verified before decoding; retain every original referenced by a record.
        if ("items" !in root) return manifest
        val referenced = manifest.moments.flatMap { it.assetIDs }.toSet()
        return manifest.copy(
            assets = manifest.assets.filter { it.id in referenced },
            resources = manifest.resources.filter { it.assetID in referenced },
        )
    }

    fun decodeCommit(bytes: ByteArray): V1Commit {
        val o = parse(bytes, "commit")
        return V1Commit(
            version = o.int("version", "commit"), sequence = o.long("sequence", "commit"),
            parentHash = o.optional("parentHash")?.textValue("commit.parentHash"),
            writerDeviceID = o.id("writerDeviceID", "commit"), kind = o.text("kind", "commit"),
            manifestHash = o.text("manifestHash", "commit"), manifestKey = o.text("manifestKey", "commit"),
            createdAt = o.long("createdAt", "commit"), requestID = o.id("requestID", "commit"),
        )
    }

    fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(Locale.ROOT, it.toInt() and 255) }

    fun commitRelativeKey(sequence: Long): String {
        // Match Swift's %020lld helper; validateCommit is the positive-sequence boundary.
        val number = if (sequence < 0) "-" + sequence.toString().drop(1).padStart(19, '0')
        else sequence.toString().padStart(20, '0')
        return "commits/$number.json"
    }

    private fun obj(vararg pairs: Pair<String, JsonElement?>): JsonObject =
        JsonObject(pairs.mapNotNull { (key, value) -> value?.let { key to it } }.toMap().toSortedMap())

    private fun knownProvenance(value: String?): String? = ImportProvenance.fromWire(value)
        .takeUnless { it == ImportProvenance.Unknown }?.wireValue

    private fun uuid(value: String, path: String) = JsonPrimitive(V1Ids.canonical(value, path))
    private fun uuids(values: List<String>, path: String) = JsonArray(values.mapIndexed { index, value -> uuid(value, "$path[$index]") })
    private fun encode(value: JsonObject) = value.toString().toByteArray(Charsets.UTF_8)

    private fun parse(bytes: ByteArray, path: String): JsonObject {
        if (bytes.size > METADATA_LIMIT) invalid(path, "Metadata exceeds 32 MiB.")
        val text = try {
            Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: Exception) { invalid(path, "Expected UTF-8 JSON.") }
        val value = try { Json.parseToJsonElement(text) }
        catch (_: Exception) { invalid(path, "Invalid JSON.") }
        return value.objectValue(path)
    }

    private fun JsonElement.objectValue(path: String) = this as? JsonObject ?: invalid(path, "Expected an object.")
    private fun JsonObject.required(key: String, path: String) = this[key] ?: invalid("$path.$key", "Required field is missing.")
    private fun JsonObject.optional(key: String) = this[key]?.takeUnless { it is JsonNull }
    private fun JsonElement.textValue(path: String): String = (this as? JsonPrimitive)
        ?.takeIf { it.isString }?.content ?: invalid(path, "Expected a string.")
    private fun JsonObject.text(key: String, path: String) = required(key, path).textValue("$path.$key")
    private fun JsonObject.id(key: String, path: String) = V1Ids.canonical(text(key, path), "$path.$key")
    private fun JsonObject.array(key: String, path: String) = required(key, path) as? JsonArray ?: invalid("$path.$key", "Expected an array.")
    private fun JsonObject.ids(key: String, path: String) = array(key, path).mapIndexed { index, value ->
        val field = "$path.$key[$index]"
        V1Ids.canonical(value.textValue(field), field)
    }
    private fun JsonElement.integer(path: String): Long {
        val value = this as? JsonPrimitive ?: invalid(path, "Expected an integer.")
        if (value.isString || !Regex("-?(0|[1-9][0-9]*)").matches(value.content)) invalid(path, "Expected an integer.")
        return value.content.toLongOrNull() ?: invalid(path, "Integer is outside Int64 range.")
    }
    private fun JsonObject.long(key: String, path: String) = required(key, path).integer("$path.$key")
    private fun JsonObject.int(key: String, path: String): Int = long(key, path).let {
        if (it !in Int.MIN_VALUE..Int.MAX_VALUE) invalid("$path.$key", "Integer is outside Int32 range.")
        it.toInt()
    }
    private fun JsonObject.boolean(key: String, path: String): Boolean {
        val value = required(key, path) as? JsonPrimitive ?: invalid("$path.$key", "Expected a boolean.")
        return if (value.isString) invalid("$path.$key", "Expected a boolean.")
        else value.booleanOrNull ?: invalid("$path.$key", "Expected a boolean.")
    }
    private fun invalid(path: String, reason: String): Nothing = throw V1ValidationException("$path: $reason")
}
