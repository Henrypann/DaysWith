package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.storage.StorageConfiguration
import java.io.File
import java.io.OutputStream

/** Enforces the confirmed parent identity before any request reaches the shared-key client. */
class ParentScopedCosStore(
    private val delegate: CosObjectStore,
    parent: ParentIdentity,
) : CosObjectStore {
    override val configuration: StorageConfiguration = delegate.configuration
    private val prefix = configuration.prefix
    private val objects = V1Layout.objectRoot(prefix) + "objects/"

    init {
        // A device chain directly under the parent root (or the test root); the legacy root stays accepted.
        val root = V1Layout.objectRoot(prefix)
        if ((prefix != parent.prefix && root != parent.prefix && root != V1Layout.TEST_ROOT) || runCatching { configuration.validate() }.isFailure) invalid()
    }

    override fun list(prefix: String): List<String> {
        validateKey(prefix, allowPrefix = true)
        return delegate.list(prefix)
    }
    override fun head(key: String): CosObjectInfo? { validateKey(key); return delegate.head(key) }
    override fun get(key: String): ByteArray { validateKey(key); return delegate.get(key) }
    override fun download(key: String, output: OutputStream): CosDownload {
        validateKey(key); return delegate.download(key, output)
    }
    override fun download(key: String, file: File): CosDownload {
        validateKey(key); return delegate.download(key, file)
    }
    override fun put(key: String, bytes: ByteArray, contentType: String) {
        validateKey(key); delegate.put(key, bytes, contentType)
    }
    override fun putFile(key: String, file: File, contentType: String) {
        validateKey(key); delegate.putFile(key, file, contentType)
    }
    override fun initiateMultipart(key: String, contentType: String, sha256: String): String {
        validateKey(key); return delegate.initiateMultipart(key, contentType, sha256)
    }
    override fun uploadPart(key: String, uploadId: String, partNumber: Int, file: File, offset: Long, length: Long): String {
        validateKey(key); return delegate.uploadPart(key, uploadId, partNumber, file, offset, length)
    }
    override fun listParts(key: String, uploadId: String): List<CosPart> {
        validateKey(key); return delegate.listParts(key, uploadId)
    }
    override fun completeMultipart(key: String, uploadId: String, parts: List<CosPart>) {
        validateKey(key); delegate.completeMultipart(key, uploadId, parts)
    }

    private fun validateKey(key: String, allowPrefix: Boolean = false) {
        val parts = key.split('/').let { if (allowPrefix && it.lastOrNull() == "") it.dropLast(1) else it }
        if (!(key.startsWith(prefix) || key.startsWith(objects)) || (!allowPrefix && key == prefix) ||
            key.toByteArray(Charsets.UTF_8).size > 1024 || key.startsWith('/') ||
            '\\' in key || '%' in key || key.any { Character.isISOControl(it) } ||
            parts.any { it.isEmpty() || it == "." || it == ".." }) invalid()
    }
    private fun invalid(): Nothing = throw CosException(CosFailure.Configuration)
}
