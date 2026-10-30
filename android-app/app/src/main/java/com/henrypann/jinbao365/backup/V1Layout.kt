package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.data.ParentIdentity
import java.util.Locale

/**
 * Multi-device layout (v1.1):
 *  - each installation owns its own chain at `life/v1/<dad|mom>/<deviceId>/` (commits/, snapshots/);
 *  - content-addressed originals stay shared at `life/v1/<dad|mom>/objects/` (same hash = same bytes);
 *  - debug/test builds use `life/v1/test/<deviceId>/` and never touch dad/ or mom/;
 *  - legacy single-writer chains at `life/v1/<dad|mom>/` remain readable, never rewritten or deleted.
 */
object V1Layout {
    const val TEST_ROOT = "life/v1/test/"
    private val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    fun identityRoot(parent: ParentIdentity, test: Boolean): String = if (test) TEST_ROOT else parent.prefix

    fun chainPrefix(parent: ParentIdentity, deviceId: String, test: Boolean): String {
        require(uuid.matches(deviceId)) { "Invalid device id" }
        return identityRoot(parent, test) + deviceId.lowercase(Locale.ROOT) + "/"
    }

    fun isDeviceSegment(value: String) = uuid.matches(value)

    /** Device chains share their identity root's objects/; legacy and other prefixes keep their own. */
    fun objectRoot(prefix: String): String {
        val parts = prefix.removeSuffix("/").split('/')
        return if (parts.size >= 2 && isDeviceSegment(parts.last())) parts.dropLast(1).joinToString("/") + "/" else prefix
    }

    fun objectKey(prefix: String, sha256: String) = objectRoot(prefix) + "objects/${sha256.take(2)}/$sha256"

    /** An anniversary owner's folder must contain the chain (legacy root, its device chain, or test). */
    fun owns(owner: ParentIdentity, prefix: String): Boolean =
        prefix == owner.prefix || objectRoot(prefix) == owner.prefix || objectRoot(prefix) == TEST_ROOT

    /** Chain prefixes found under an identity root: the legacy root (if it has commits) and device subfolders. */
    fun chainsUnder(root: String, keys: List<String>): List<String> = keys.mapNotNull { key ->
        val rest = key.removePrefix(root)
        if (rest == key) return@mapNotNull null
        val parts = rest.split('/')
        when {
            parts.firstOrNull() == "commits" -> root
            parts.size >= 3 && isDeviceSegment(parts[0]) && parts[1] == "commits" -> root + parts[0] + "/"
            else -> null
        }
    }.distinct().sorted()
}
