package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.storage.StorageConfiguration
import java.io.File
import java.io.OutputStream
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection
import kotlinx.serialization.Serializable

data class CosObjectInfo(val byteCount: Long, val sha256: String? = null)
data class CosDownload(val byteCount: Long, val sha256: String)

@Serializable
data class CosPart(val partNumber: Int, val etag: String, val byteCount: Long? = null)

/** Fixed public messages never contain a URL, response body, credential or transport exception. */
enum class CosFailure(val message: String) {
    Conflict("云端已有同名文件，没有覆盖。"),
    NotFound("云端文件不存在。"),
    NoSuchUpload("分片上传已失效，请重新备份。"),
    Network("云存储连接失败，请检查网络后重试。"),
    Timeout("云存储连接超时，请在网络稳定后重试。"),
    InvalidResponse("云存储返回了无法识别的数据。"),
    Permission("云存储拒绝了访问，请检查账号权限。"),
    Configuration("请检查存储桶、地域和存储路径。"),
}

class CosException(val failure: CosFailure) : Exception(failure.message)

/** Shared by an engine run and its client; cancellation interrupts an active HTTPS operation. */
class BackupCancellation {
    private val cancelled = AtomicBoolean(false)
    private val connections = mutableSetOf<HttpsURLConnection>()

    fun cancel() {
        cancelled.set(true)
        val active = synchronized(connections) { connections.toList() }
        active.forEach { it.disconnect() }
    }

    fun check() {
        if (cancelled.get() || Thread.currentThread().isInterrupted) throw CancellationException()
    }

    internal fun attach(connection: HttpsURLConnection) {
        synchronized(connections) { connections.add(connection) }
        if (cancelled.get()) connection.disconnect()
        check()
    }

    internal fun detach(connection: HttpsURLConnection) {
        synchronized(connections) { connections.remove(connection) }
    }
}

/** Scoped immutable storage only. No object deletion or multipart abort operation is exposed. */
interface CosObjectStore {
    val configuration: StorageConfiguration
    fun list(prefix: String): List<String>
    fun head(key: String): CosObjectInfo?
    /** Control documents only; implementations must reject anything larger than 32 MiB. */
    fun get(key: String): ByteArray
    /** Does not close the caller's stream. Hashes every byte written to it. */
    fun download(key: String, output: OutputStream): CosDownload
    fun download(key: String, file: File): CosDownload {
        if (!file.createNewFile()) throw CosException(CosFailure.InvalidResponse)
        return try { file.outputStream().use { download(key, it) } }
        catch (failure: Exception) { file.delete(); throw failure }
    }
    fun put(key: String, bytes: ByteArray, contentType: String)
    fun putFile(key: String, file: File, contentType: String)
    fun initiateMultipart(key: String, contentType: String, sha256: String): String
    fun uploadPart(key: String, uploadId: String, partNumber: Int, file: File, offset: Long, length: Long): String
    fun listParts(key: String, uploadId: String): List<CosPart>
    fun completeMultipart(key: String, uploadId: String, parts: List<CosPart>)
}
