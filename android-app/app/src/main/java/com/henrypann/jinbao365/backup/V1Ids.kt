package com.henrypann.jinbao365.backup

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID

/** Published legacy v1 identities depend on this namespace. Never change it after publication. */
const val V1IdNamespace = "6F0F3B0E-6B2F-5C55-9E57-0D365A7D0001"

object V1Ids {
    private const val RECORD_PREFIX = "rec-"
    private val namespace = UUID.fromString(V1IdNamespace)
    private val canonicalPattern = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    fun map(kind: String, localId: String): String {
        require(kind in setOf("record", "asset", "resource")) { "Unsupported v1 identity kind." }
        // Records store either a bare UUID (drafts) or `rec-<uuid>` (multi-select import).
        // Both upload that stored UUID verbatim; nothing is derived for them.
        val stored = if (kind == "record") localId.removePrefix(RECORD_PREFIX) else localId
        if (canonicalPattern.matches(stored)) return stored.uppercase(Locale.ROOT)
        return legacyIdToV1Uuid(kind, localId)
    }

    /**
     * Compatibility path pending Henry's decision on non-UUID stored identities.
     * Keeps the existing v5 mapping for legacy `rec-…` records, `asset-<hash>` assets,
     * `res-…` resources. Canonical UUIDs must never enter
     * this path; [map] uploads them directly. Neither this namespace nor the kind
     * prefix may change while previously published v1 identities depend on them.
     */
    internal fun legacyIdToV1Uuid(kind: String, localId: String): String {
        require(kind in setOf("record", "asset", "resource")) { "Unsupported v1 identity kind." }
        require(!canonicalPattern.matches(localId)) { "Canonical UUIDs must be uploaded directly." }
        return uuidV5(namespace, "$kind:$localId").toString().uppercase(Locale.ROOT)
    }

    /** RFC 4122, section 4.3: network-order namespace bytes followed by the UTF-8 name. */
    internal fun uuidV5(namespace: UUID, name: String): UUID {
        val digest = MessageDigest.getInstance("SHA-1")
        digest.update(ByteBuffer.allocate(16).putLong(namespace.mostSignificantBits)
            .putLong(namespace.leastSignificantBits).array())
        val bytes = digest.digest(name.toByteArray(Charsets.UTF_8))
        bytes[6] = ((bytes[6].toInt() and 0x0f) or 0x50).toByte()
        bytes[8] = ((bytes[8].toInt() and 0x3f) or 0x80).toByte()
        val buffer = ByteBuffer.wrap(bytes)
        return UUID(buffer.long, buffer.long)
    }

    internal fun canonical(value: String, field: String): String {
        if (!canonicalPattern.matches(value)) throw V1ValidationException("$field: Expected a UUID.")
        return UUID.fromString(value).toString().uppercase(Locale.ROOT)
    }
}
