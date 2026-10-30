package com.henrypann.jinbao365.debug

import android.content.Context
import android.util.AtomicFile
import com.henrypann.jinbao365.backup.*
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.storage.AndroidCredentialCipher
import com.henrypann.jinbao365.storage.StorageConfiguration
import com.henrypann.jinbao365.storage.StorageCredentials
import com.henrypann.jinbao365.viewing.*
import org.json.JSONObject
import java.io.File
import java.io.OutputStream
import javax.net.ssl.HttpsURLConnection

/** No credential/configuration toString, logs, exceptions or URLs leave this boundary. */
internal class PhotoPreviewSmokeConnection private constructor(
    val configuration: StorageConfiguration,
    val credentials: StorageCredentials,
    private val token: String?,
) {
    fun client(parent: ParentIdentity, cancellation: BackupCancellation): CosObjectClient {
        val physical = configuration.copy(prefix = configuration.prefix + parent.folder + "/")
        return CosObjectClient(physical, credentials, cancellation, { url ->
            // This additional guard is independent of the logical-key adapter and COS validator.
            val listedPrefix = url.query.orEmpty().split('&').firstOrNull { it.startsWith("prefix=") }
                ?.substringAfter('=')?.let { java.net.URLDecoder.decode(it, "UTF-8") }
            check(url.protocol == "https" && url.host == physical.host &&
                (url.path.startsWith("/" + physical.prefix) ||
                    (url.path == "/" && listedPrefix?.startsWith(physical.prefix) == true)))
            (url.openConnection() as HttpsURLConnection).apply {
                token?.let { setRequestProperty("x-cos-security-token", it) }
            }
        }, { System.currentTimeMillis() / 1000 })
    }
    override fun toString() = "SmokeConnection(redacted)"
    companion object {
        @Synchronized fun read(context: Context): PhotoPreviewSmokeConnection {
            val incoming = File(context.noBackupFilesDir, "pr8-smoke-connection.json")
            val sealed = AtomicFile(File(context.noBackupFilesDir, "pr8-smoke-connection.enc"))
            val cipher = AndroidCredentialCipher()
            if (incoming.exists()) {
                var plaintext: ByteArray? = null
                try {
                    check(incoming.length() in 1..16_384)
                    val bytes = incoming.readBytes()
                    plaintext = bytes
                    decode(bytes) // Validate prefix before persisting anything.
                    val encrypted = cipher.encrypt(bytes)
                    val stream = sealed.startWrite()
                    try { stream.write(encrypted); sealed.finishWrite(stream) }
                    catch (failure: Exception) { sealed.failWrite(stream); throw failure }
                } finally {
                    plaintext?.fill(0)
                    check(!incoming.exists() || incoming.delete())
                }
            }
            val bytes = cipher.decrypt(sealed.readFully())
            return try { decode(bytes) } finally { bytes.fill(0) }
        }
        private fun decode(bytes: ByteArray): PhotoPreviewSmokeConnection {
            val json = JSONObject(bytes.toString(Charsets.UTF_8))
            val configuration = StorageConfiguration(json.getString("bucket"), json.getString("region"), json.getString("prefix"))
            configuration.validate()
            check(configuration.prefix.startsWith("tests/pr8-redmi-") && configuration.prefix.endsWith('/'))
            val credentials = StorageCredentials(json.getString("secretID"), json.getString("secretKey"))
            check(credentials.valid())
            // This debug entry accepts short-lived STS triples only; never a permanent-key fallback.
            val token = json.get("token")
            check(token is String && token.length in 1..8192 && token.all { it.code in 32..126 })
            return PhotoPreviewSmokeConnection(configuration, credentials, token)
        }
    }
}

/** Persisted numeric observations survive activity reopens. Contains synthetic hashes only. */
internal class PhotoPreviewSmokeObservations(private val context: Context, private val fixtures: PhotoPreviewSmokeFixtures) {
    private val file = File(context.filesDir, "pr8-smoke-observations.json")
    @Synchronized fun event(name: String) {
        val json = if (file.isFile) JSONObject(file.readText()) else JSONObject()
        json.put(name, json.optLong(name) + 1).put("network", AndroidOriginalNetwork.current(context).name)
        val cache = JSONObject()
        for (resource in fixtures.snapshot.resources.filter { it.role == "photo" && it.objectKey.startsWith("remote/") }) {
            cache.put(resource.sha256, fileMatches(File(fixtures.root, resource.objectKey), resource.byteCount, resource.sha256))
        }
        json.put("verifiedCache", cache)
        val atomic = AtomicFile(file)
        val stream = atomic.startWrite()
        try { stream.write(json.toString(2).toByteArray()); atomic.finishWrite(stream) }
        catch (failure: Exception) { atomic.failWrite(stream); throw failure }
    }
}

/** Every request is mapped into the test prefix, including list query and response keys. */
internal class PhotoPreviewSmokeStore(
    private val delegate: CosObjectClient,
    parent: ParentIdentity,
    private val observations: PhotoPreviewSmokeObservations,
) : CosObjectStore {
    override val configuration = delegate.configuration.copy(prefix = parent.prefix)
    private fun physical(key: String): String {
        check(key.startsWith(configuration.prefix))
        val suffix = key.removePrefix(configuration.prefix)
        check(suffix.split('/').filter { it.isNotEmpty() }.all { it != "." && it != ".." })
        check('\\' !in suffix && '%' !in suffix && !suffix.startsWith('/'))
        return delegate.configuration.prefix + suffix
    }
    override fun list(prefix: String) = delegate.list(physical(prefix)).map {
        check(it.startsWith(delegate.configuration.prefix))
        configuration.prefix + it.removePrefix(delegate.configuration.prefix)
    }
    override fun head(key: String): CosObjectInfo? { observations.event("head"); return delegate.head(physical(key)) }
    override fun get(key: String): ByteArray { observations.event("get"); return delegate.get(physical(key)) }
    override fun download(key: String, output: OutputStream): CosDownload {
        observations.event("download"); return delegate.download(physical(key), output)
    }
    override fun put(key: String, bytes: ByteArray, contentType: String) {
        observations.event("put"); delegate.put(physical(key), bytes, contentType)
    }
    override fun putFile(key: String, file: File, contentType: String) {
        observations.event("putFile"); delegate.putFile(physical(key), file, contentType)
    }
    override fun initiateMultipart(key: String, contentType: String, sha256: String) = delegate.initiateMultipart(physical(key), contentType, sha256)
    override fun uploadPart(key: String, uploadId: String, partNumber: Int, file: File, offset: Long, length: Long) =
        delegate.uploadPart(physical(key), uploadId, partNumber, file, offset, length)
    override fun listParts(key: String, uploadId: String) = delegate.listParts(physical(key), uploadId)
    override fun completeMultipart(key: String, uploadId: String, parts: List<CosPart>) = delegate.completeMultipart(physical(key), uploadId, parts)
}
