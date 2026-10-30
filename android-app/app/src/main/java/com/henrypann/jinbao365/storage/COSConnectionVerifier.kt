package com.henrypann.jinbao365.storage

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.URL
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection

/** Public messages contain only fixed categories; URLs, response bodies and exceptions stay private. */
enum class ConnectionFailure(val message: String) {
    Permission("云存储权限不足，请检查两个家长文件夹的读取权限和本机文件夹的写入权限。"),
    InvalidSecretID("密钥编号无法识别，请核对后重试。"),
    ExpiredCredentials("密钥已过期，请重新填写。"),
    Signature("密钥或签名校验失败，请检查密钥和手机时间。"),
    Network("暂时无法连接云存储，请检查网络后重试。"),
    Timeout("连接超时，请检查网络后重试。"),
    ContentMismatch("云端内容校验失败，请检查存储设置。"),
    Configuration("请检查存储桶和地域代码。"),
    SecureStorage("暂时无法安全保存密钥，请解锁手机后重试。")
}
class VerificationException(val category: ConnectionFailure) : Exception(category.name)
class VerificationCancellation {
    private val cancelled = AtomicBoolean(false)
    private val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(60)
    @Volatile private var connection: HttpsURLConnection? = null
    fun cancel() { cancelled.set(true); connection?.disconnect() }
    fun check() {
        if (cancelled.get() || Thread.currentThread().isInterrupted) throw CancellationException()
        if (System.nanoTime() > deadline) throw VerificationException(ConnectionFailure.Timeout)
    }
    internal fun attach(value: HttpsURLConnection) { connection = value; check() }
    internal fun detach() { connection = null }
}
internal class ProbeRequest(val method: String, val path: String, val query: Map<String, String> = emptyMap(),
                            val headers: Map<String, String> = emptyMap(), val body: ByteArray = byteArrayOf()) {
    override fun toString() = "ProbeRequest(redacted)"
}
internal class ProbeResponse(val status: Int, val headers: Map<String, String> = emptyMap(), val body: ByteArray = byteArrayOf())
internal fun interface ProbeTransport { fun execute(request: ProbeRequest, cancellation: VerificationCancellation): ProbeResponse }
fun interface StorageVerifier { fun verify(configuration: StorageConfiguration, credentials: StorageCredentials, cancellation: VerificationCancellation) }

/** No endpoint parameter or arbitrary mutations are exposed to the application. */
class COSConnectionVerifier : StorageVerifier {
    override fun verify(configuration: StorageConfiguration, credentials: StorageCredentials, cancellation: VerificationCancellation) {
        try { configuration.validate(); require(credentials.valid()) }
        catch (_: IllegalArgumentException) { throw VerificationException(ConnectionFailure.Configuration) }
        verify(configuration, cancellation, HTTPSProbeTransport(configuration, credentials))
    }
    internal fun verify(configuration: StorageConfiguration, cancellation: VerificationCancellation, transport: ProbeTransport) {
        fun run(request: ProbeRequest): ProbeResponse {
            cancellation.check()
            val response = try { transport.execute(request, cancellation) }
            catch (failure: VerificationException) { throw failure }
            catch (_: SocketTimeoutException) { throw VerificationException(ConnectionFailure.Timeout) }
            catch (failure: IOException) { cancellation.check(); throw VerificationException(ConnectionFailure.Network) }
            cancellation.check()
            if (response.status !in 200..299) {
                // Parse only a bounded known error code, never display or propagate server text.
                val code = Regex("<Code>([A-Za-z]+)</Code>").find(response.body.toString(Charsets.UTF_8))?.groupValues?.get(1)
                val category = when {
                    code in listOf("InvalidAccessKeyId", "AccessKeyIdNotExist") -> ConnectionFailure.InvalidSecretID
                    code == "ExpiredToken" -> ConnectionFailure.ExpiredCredentials
                    code in listOf("SignatureDoesNotMatch", "RequestTimeTooSkewed") -> ConnectionFailure.Signature
                    response.status in listOf(401, 403) -> ConnectionFailure.Permission
                    else -> ConnectionFailure.Network // Includes every redirect: no credential forwarding.
                }
                throw VerificationException(category)
            }
            return response
        }
        // Identity is chosen AFTER connection. Do not write into an unowned folder.
        // Write permission is exercised by the first immutable backup after confirmation.
        for (parent in com.henrypann.jinbao365.data.ParentIdentity.entries) {
            val response = run(ProbeRequest("GET", "/", mapOf("prefix" to parent.prefix, "max-keys" to "1")))
            val valid = runCatching {
                com.henrypann.jinbao365.backup.CosXml.parse(response.body).name == "ListBucketResult"
            }.getOrDefault(false)
            if (!valid) throw VerificationException(ConnectionFailure.ContentMismatch)
        }
    }
}

internal class HTTPSProbeTransport(private val configuration: StorageConfiguration, private val credentials: StorageCredentials,
    private val open: (URL) -> HttpsURLConnection = { it.openConnection() as HttpsURLConnection }) : ProbeTransport {
    override fun execute(request: ProbeRequest, cancellation: VerificationCancellation): ProbeResponse {
        val host = configuration.host
        val query = request.query.entries.sortedBy { it.key }.joinToString("&") { "${COSSigner.encode(it.key)}=${COSSigner.encode(it.value)}" }
        val url = URL("https://$host${COSSigner.encode(request.path, true)}" + if (query.isEmpty()) "" else "?$query")
        check(url.protocol == "https" && url.host == host && url.port == -1 && url.userInfo == null)
        val connection = open(url)
        try {
            cancellation.attach(connection)
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 10_000
            connection.readTimeout = 10_000
            connection.requestMethod = request.method
            connection.useCaches = false
            val headers = request.headers + ("Host" to host)
            headers.forEach { (key, value) -> connection.setRequestProperty(key, value) }
            connection.setRequestProperty("Authorization", COSSigner(credentials).authorization(request.method, request.path, request.query, headers))
            if (request.method == "PUT") {
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(request.body.size)
                connection.outputStream.use { it.write(request.body) }
            }
            cancellation.check()
            val status = connection.responseCode
            val resultHeaders = connection.headerFields.entries.filter { it.key != null }.associate { it.key to it.value.joinToString(",") }
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val body = if (request.method == "HEAD" || stream == null) byteArrayOf() else stream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(4096)
                while (true) {
                    cancellation.check()
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > 65_536) throw VerificationException(ConnectionFailure.ContentMismatch)
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            return ProbeResponse(status, resultHeaders, body)
        } finally { cancellation.detach(); connection.disconnect() }
    }
}
