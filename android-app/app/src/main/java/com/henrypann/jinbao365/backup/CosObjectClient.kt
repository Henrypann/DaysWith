package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.storage.COSSigner
import com.henrypann.jinbao365.storage.StorageConfiguration
import com.henrypann.jinbao365.storage.StorageCredentials
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.StringReader
import java.net.SocketTimeoutException
import java.net.URL
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.concurrent.CancellationException
import javax.net.ssl.HttpsURLConnection
import javax.xml.parsers.SAXParserFactory
import org.xml.sax.InputSource
import org.xml.sax.SAXException
import org.xml.sax.SAXParseException
import org.xml.sax.helpers.DefaultHandler

/** Serial, file-streaming COS transport. No configurable endpoint or completed-object delete API. */
class CosObjectClient internal constructor(
    override val configuration: StorageConfiguration,
    credentials: StorageCredentials,
    private val cancellation: BackupCancellation,
    private val open: (URL) -> HttpsURLConnection,
    private val now: () -> Long,
) : CosObjectStore {
    constructor(configuration: StorageConfiguration, credentials: StorageCredentials,
        cancellation: BackupCancellation = BackupCancellation()) : this(
        configuration, credentials, cancellation, { it.openConnection() as HttpsURLConnection },
        { System.currentTimeMillis() / 1000 },
    )

    private val signer: COSSigner

    init {
        try { configuration.validate(); require(credentials.valid()) }
        catch (_: IllegalArgumentException) { throw CosException(CosFailure.Configuration) }
        signer = COSSigner(credentials)
    }

    override fun toString() = "CosObjectClient(redacted)"

    override fun list(prefix: String): List<String> {
        validateKey(prefix, allowPrefix = true)
        var marker = ""
        val seenMarkers = mutableSetOf<String>()
        val keys = mutableListOf<String>()
        repeat(10_000) {
            val query = mutableMapOf("prefix" to prefix, "max-keys" to "1000")
            if (marker.isNotEmpty()) query["marker"] = marker
            val xml = xmlRequest("GET", query = query, root = "ListBucketResult")
            val page = xml.children("Contents").map { node ->
                val key = node.value("Key") ?: invalid()
                if (!key.startsWith(prefix)) invalid()
                validateKey(key)
                key
            }
            if (keys.size + page.size > 100_000) invalid()
            keys.addAll(page)
            if (!xml.truncated()) return keys
            val next = xml.value("NextMarker") ?: page.lastOrNull() ?: invalid()
            if (next.isEmpty() || next == marker || !seenMarkers.add(next)) invalid()
            marker = next
        }
        invalid()
    }

    override fun head(key: String): CosObjectInfo? = try {
        request("HEAD", key) { connection ->
            val count = contentLength(connection) ?: invalid()
            CosObjectInfo(count, connection.getHeaderField(HASH_HEADER)?.takeIf { HASH_PATTERN.matches(it) })
        }
    } catch (failure: CosException) {
        if (failure.failure == CosFailure.NotFound) null else throw failure
    }

    override fun get(key: String): ByteArray = request("GET", key) { readMetadata(it) }

    override fun download(key: String, output: OutputStream): CosDownload = request("GET", key) { connection ->
        val expected = contentLength(connection)
        if (expected != null && expected > RESOURCE_LIMIT) invalid()
        val digest = MessageDigest.getInstance("SHA-256")
        val count = connection.inputStream.use { input -> copy(input, output, RESOURCE_LIMIT, digest) }
        if (expected != null && expected != count) invalid()
        CosDownload(count, COSSigner.hex(digest.digest()))
    }

    override fun put(key: String, bytes: ByteArray, contentType: String) {
        if (bytes.size > METADATA_LIMIT) invalid()
        request("PUT", key, headers = immutableHeaders(contentType, V1Json.sha256(bytes)), length = bytes.size.toLong(),
            body = { output -> cancellation.check(); output.write(bytes) }) { readMetadata(it) }
    }

    override fun putFile(key: String, file: File, contentType: String) {
        if (!file.isFile || file.length() !in 1..RESOURCE_LIMIT) invalid()
        val size = file.length()
        request("PUT", key, headers = immutableHeaders(contentType, fileSha256(file)), length = size,
            body = { output -> file.inputStream().use { writeExactly(it, output, size) } }) { readMetadata(it) }
    }

    override fun initiateMultipart(key: String, contentType: String, sha256: String): String {
        val xml = xmlRequest("POST", key, mapOf("uploads" to ""), immutableHeaders(contentType, sha256),
            root = "InitiateMultipartUploadResult")
        return (xml.value("UploadId") ?: invalid()).also { validateUploadId(it) }
    }

    override fun uploadPart(key: String, uploadId: String, partNumber: Int, file: File, offset: Long, length: Long): String {
        validateUploadId(uploadId)
        if (partNumber !in 1..10_000 || offset < 0 || length !in 1..METADATA_LIMIT.toLong() ||
            !file.isFile || offset > file.length() || length > file.length() - offset) invalid()
        return request("PUT", key, mapOf("uploadId" to uploadId, "partNumber" to partNumber.toString()),
            headers = mapOf("Content-Type" to "application/octet-stream", "x-cos-forbid-overwrite" to "true"),
            length = length, body = { output ->
                file.inputStream().use { input ->
                    input.channel.position(offset)
                    writeExactly(input, output, length)
                }
            }) { connection ->
            readMetadata(connection)
            connection.getHeaderField("ETag")?.takeIf { it.isNotBlank() && !controls(it) } ?: invalid()
        }
    }

    override fun listParts(key: String, uploadId: String): List<CosPart> {
        validateUploadId(uploadId)
        var marker = 0
        val seen = mutableSetOf<Int>()
        val parts = mutableListOf<CosPart>()
        repeat(10) {
            val xml = xmlRequest("GET", key, mapOf("uploadId" to uploadId,
                "part-number-marker" to marker.toString(), "max-parts" to "1000"), root = "ListPartsResult")
            val page = xml.children("Part").map { node ->
                val number = node.value("PartNumber")?.toIntOrNull() ?: invalid()
                val etag = node.value("ETag")?.takeIf { it.isNotBlank() && !controls(it) } ?: invalid()
                val sizeValue = node.value("Size")
                val size = sizeValue?.toLongOrNull()
                if (number !in 1..10_000 || number <= marker || !seen.add(number) ||
                    (sizeValue != null && (size == null || size !in 1..RESOURCE_LIMIT))) invalid()
                CosPart(number, etag, size)
            }
            parts.addAll(page)
            if (!xml.truncated()) return parts.sortedBy { it.partNumber }
            val next = xml.value("NextPartNumberMarker")?.toIntOrNull() ?: invalid()
            if (next <= marker || next > 10_000 || next != page.maxOfOrNull { it.partNumber }) invalid()
            marker = next
        }
        invalid()
    }

    override fun completeMultipart(key: String, uploadId: String, parts: List<CosPart>) {
        validateUploadId(uploadId)
        val sorted = parts.sortedBy { it.partNumber }
        if (sorted.isEmpty() || sorted.size > 10_000 || sorted.withIndex().any { (index, part) ->
                part.partNumber != index + 1 || part.etag.isBlank() || controls(part.etag)
            }) invalid()
        val body = ("<CompleteMultipartUpload>" + sorted.joinToString("") {
            "<Part><PartNumber>${it.partNumber}</PartNumber><ETag>${CosXml.escape(it.etag)}</ETag></Part>"
        } + "</CompleteMultipartUpload>").toByteArray(Charsets.UTF_8)
        if (body.size > METADATA_LIMIT) invalid()
        val xml = xmlRequest("POST", key, mapOf("uploadId" to uploadId), immutableHeaders("application/xml"),
            body, "CompleteMultipartUploadResult")
        if (xml.value("ETag").isNullOrBlank()) invalid()
    }

    private fun xmlRequest(method: String, key: String? = null, query: Map<String, String> = emptyMap(),
        headers: Map<String, String> = emptyMap(), bytes: ByteArray? = null, root: String): CosXml.Node =
        request(method, key, query, headers, bytes?.size?.toLong(), bytes?.let { data ->
            { output: OutputStream -> cancellation.check(); output.write(data) }
        }) { connection ->
            val data = readMetadata(connection)
            val xml = CosXml.parse(data)
            if (xml.name == "Error") throw CosException(errorFailure(xml.value("Code"), connection.responseCode, query))
            if (xml.name != root) invalid()
            xml
        }

    private fun <T> request(method: String, key: String? = null, query: Map<String, String> = emptyMap(),
        headers: Map<String, String> = emptyMap(), length: Long? = null,
        body: ((OutputStream) -> Unit)? = null, consume: (HttpsURLConnection) -> T): T {
        cancellation.check()
        // Abandoned multipart sessions are never resumed or deleted by the app.
        if (method !in setOf("GET", "HEAD", "PUT", "POST")) invalid()
        if (key != null) validateKey(key)
        val path = key?.let { "/$it" } ?: "/"
        val queryString = query.entries.sortedBy { it.key }.joinToString("&") {
            "${COSSigner.encode(it.key)}=${COSSigner.encode(it.value)}"
        }
        val host = configuration.host
        val url = URL("https://$host${COSSigner.encode(path, preserveSlash = true)}" +
            if (queryString.isEmpty()) "" else "?$queryString")
        if (url.protocol != "https" || url.host != host || url.port != -1 || url.userInfo != null) invalid()
        var connection: HttpsURLConnection? = null
        try {
            val active = open(url)
            connection = active
            if (active.url.toExternalForm() != url.toExternalForm()) invalid()
            cancellation.attach(active)
            active.instanceFollowRedirects = false
            active.connectTimeout = 15_000
            active.readTimeout = 60_000
            active.useCaches = false
            active.requestMethod = method
            val signingHeaders = headers + mapOf("Host" to host, "Accept-Encoding" to "identity")
            signingHeaders.forEach { (name, value) -> active.setRequestProperty(name, value) }
            active.setRequestProperty("Authorization", signer.authorization(method, path, query, signingHeaders, now()))
            if (body != null || method == "POST") {
                active.doOutput = true
                active.setFixedLengthStreamingMode(length ?: 0L)
                active.outputStream.use { output -> body?.invoke(output) }
            }
            cancellation.check()
            val status = active.responseCode
            cancellation.check()
            if (active.url.toExternalForm() != url.toExternalForm() || status in 300..399) invalid()
            // A failed/oversized error body must not hide an immutable-write conflict.
            if (status == 409 || status == 412) throw CosException(CosFailure.Conflict)
            if (status !in 200..299) {
                val data = active.errorStream?.use { bounded(it, METADATA_LIMIT) } ?: byteArrayOf()
                val xml = runCatching { CosXml.parse(data) }.getOrNull()
                val code = xml?.takeIf { it.name == "Error" }?.value("Code")
                throw CosException(errorFailure(code, status, query))
            }
            val encoding = active.getHeaderField("Content-Encoding")
            if (encoding != null && !encoding.equals("identity", ignoreCase = true)) invalid()
            val result = consume(active)
            cancellation.check()
            return result
        } catch (failure: CancellationException) { throw failure }
        catch (failure: CosException) { cancellation.check(); throw failure }
        catch (_: SocketTimeoutException) { cancellation.check(); throw CosException(CosFailure.Timeout) }
        catch (_: IOException) { cancellation.check(); throw CosException(CosFailure.Network) }
        catch (_: IllegalArgumentException) { cancellation.check(); throw CosException(CosFailure.Configuration) }
        finally {
            connection?.let { cancellation.detach(it); it.disconnect() }
        }
    }

    private fun immutableHeaders(contentType: String, sha256: String? = null): Map<String, String> {
        if (contentType.isBlank() || controls(contentType)) invalid()
        if (sha256 != null && !HASH_PATTERN.matches(sha256)) invalid()
        return mapOf("Content-Type" to contentType, "x-cos-forbid-overwrite" to "true",
            "x-cos-server-side-encryption" to "AES256") + (sha256?.let { mapOf(HASH_HEADER to it) } ?: emptyMap())
    }

    private fun fileSha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { copy(it, object : OutputStream() {
            override fun write(value: Int) = Unit
            override fun write(bytes: ByteArray, offset: Int, length: Int) = Unit
        }, RESOURCE_LIMIT, digest) }
        return COSSigner.hex(digest.digest())
    }

    private fun validateUploadId(uploadId: String) {
        if (uploadId.isEmpty() || uploadId.toByteArray(Charsets.UTF_8).size > 4096 || controls(uploadId)) invalid()
    }

    private fun validateKey(key: String, allowPrefix: Boolean = false) {
        val parts = key.split('/').let { if (allowPrefix && it.lastOrNull() == "") it.dropLast(1) else it }
        val sharedObjects = V1Layout.objectRoot(configuration.prefix) + "objects/"
        if (!(key.startsWith(configuration.prefix) || key.startsWith(sharedObjects)) || (!allowPrefix && key == configuration.prefix) ||
            key.toByteArray(Charsets.UTF_8).size > 1024 || key.startsWith('/') || '\\' in key || '%' in key ||
            controls(key) || parts.any { it.isEmpty() || it == "." || it == ".." }) {
            throw CosException(CosFailure.Configuration)
        }
    }

    private fun readMetadata(connection: HttpsURLConnection): ByteArray {
        val expected = contentLength(connection)
        if (expected != null && expected > METADATA_LIMIT) invalid()
        val data = connection.inputStream.use { bounded(it, METADATA_LIMIT) }
        if (expected != null && expected != data.size.toLong()) invalid()
        return data
    }

    private fun contentLength(connection: HttpsURLConnection): Long? {
        val value = connection.getHeaderField("Content-Length") ?: return null
        return value.toLongOrNull()?.takeIf { it >= 0 } ?: invalid()
    }

    private fun bounded(input: InputStream, maximum: Int): ByteArray {
        val output = ByteArrayOutputStream()
        copy(input, output, maximum.toLong())
        return output.toByteArray()
    }

    private fun copy(input: InputStream, output: OutputStream, maximum: Long, digest: MessageDigest? = null): Long {
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            cancellation.check()
            val count = input.read(buffer)
            if (count < 0) break
            if (total > maximum - count) invalid()
            output.write(buffer, 0, count)
            digest?.update(buffer, 0, count)
            total += count
        }
        return total
    }

    private fun writeExactly(input: InputStream, output: OutputStream, size: Long) {
        val buffer = ByteArray(64 * 1024)
        var remaining = size
        while (remaining > 0) {
            cancellation.check()
            val count = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
            if (count < 0) invalid()
            output.write(buffer, 0, count)
            remaining -= count
        }
    }

    private fun errorFailure(code: String?, status: Int, query: Map<String, String>): CosFailure = when {
        status == 409 || status == 412 || code in setOf("FileAlreadyExists", "ObjectAlreadyExists",
            "PreconditionFailed", "ConditionalRequestConflict") -> CosFailure.Conflict
        code == "NoSuchUpload" -> CosFailure.NoSuchUpload
        code == "NoSuchKey" -> CosFailure.NotFound
        status == 401 || status == 403 || code in setOf("AccessDenied", "SignatureDoesNotMatch",
            "RequestTimeTooSkewed", "InvalidAccessKeyId", "AccessKeyIdNotExist", "ExpiredToken") -> CosFailure.Permission
        status == 404 -> if (query.containsKey("uploadId")) CosFailure.NoSuchUpload else CosFailure.NotFound
        status >= 500 || status == 408 || status == 429 || code in setOf("InternalError", "SlowDown", "ServiceUnavailable") -> CosFailure.Network
        else -> CosFailure.InvalidResponse
    }

    companion object {
        const val HASH_HEADER = "x-cos-meta-sha256"
        private val HASH_PATTERN = Regex("[a-f0-9]{64}")
        const val METADATA_LIMIT = 32 * 1024 * 1024
        const val RESOURCE_LIMIT = 2_147_483_648L
        private fun controls(value: String) = value.any { Character.isISOControl(it) }
        private fun invalid(): Nothing = throw CosException(CosFailure.InvalidResponse)
    }
}

/** UTF-8 only, bounded depth, no DTD/entity declarations or external resolution. */
internal object CosXml {
    class Node(val name: String) {
        val text = StringBuilder()
        val nodes = mutableListOf<Node>()
        fun children(name: String) = nodes.filter { it.name == name }
        fun value(name: String): String? {
            val matches = children(name)
            if (matches.size > 1) invalid()
            return matches.singleOrNull()?.text?.toString()?.trim()
        }
        fun truncated(): Boolean = when (value("IsTruncated")) {
            "true" -> true
            "false" -> false
            else -> invalid()
        }
    }

    fun parse(bytes: ByteArray): Node {
        if (bytes.isEmpty() || bytes.size > CosObjectClient.METADATA_LIMIT) invalid()
        try {
            val content = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString().removePrefix("\uFEFF")
            if (content.contains("<!DOCTYPE", ignoreCase = true) || content.contains("<!ENTITY", ignoreCase = true)) invalid()
            val stack = mutableListOf<Node>()
            var root: Node? = null
            var count = 0
            val handler = object : DefaultHandler() {
                override fun startElement(uri: String?, localName: String?, qName: String?, attributes: org.xml.sax.Attributes?) {
                    if (stack.size >= 16 || ++count > 300_000) invalid()
                    val name = localName?.takeIf { it.isNotEmpty() } ?: qName?.substringAfterLast(':') ?: invalid()
                    val node = Node(name)
                    if (stack.isNotEmpty()) stack.last().nodes.add(node)
                    else if (root == null) root = node else invalid()
                    stack.add(node)
                }
                override fun characters(ch: CharArray, start: Int, length: Int) { stack.lastOrNull()?.text?.append(ch, start, length) }
                override fun endElement(uri: String?, localName: String?, qName: String?) {
                    if (stack.isEmpty()) invalid()
                    stack.removeAt(stack.lastIndex)
                }
                override fun resolveEntity(publicId: String?, systemId: String?): InputSource = throw SAXException()
                override fun error(error: SAXParseException): Unit = throw error
                override fun fatalError(error: SAXParseException): Unit = throw error
            }
            val factory = SAXParserFactory.newInstance().apply { isNamespaceAware = true }
            // Android and the JVM support different feature subsets. The UTF-8 declaration rejection
            // and resolver above also enforce the boundary when an optional feature is unavailable.
            listOf("http://xml.org/sax/features/external-general-entities" to false,
                "http://xml.org/sax/features/external-parameter-entities" to false,
                "http://apache.org/xml/features/nonvalidating/load-external-dtd" to false,
                "http://apache.org/xml/features/disallow-doctype-decl" to true).forEach { (feature, enabled) ->
                runCatching { factory.setFeature(feature, enabled) }
            }
            factory.newSAXParser().parse(InputSource(StringReader(content)), handler)
            if (stack.isNotEmpty()) invalid()
            return root ?: invalid()
        } catch (failure: CosException) { throw failure }
        catch (_: Exception) { invalid() }
    }

    fun escape(value: String): String = value.replace("&", "&amp;").replace("<", "&lt;")
        .replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&apos;")
    private fun invalid(): Nothing = throw CosException(CosFailure.InvalidResponse)
}
