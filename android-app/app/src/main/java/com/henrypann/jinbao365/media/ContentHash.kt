package com.henrypann.jinbao365.media

import java.io.InputStream
import java.security.MessageDigest

/** SHA-256 of a stream. The buffer is fixed; the whole file is never held as one array. */
object ContentHash {
    const val BUFFER_SIZE = 64 * 1024

    fun sha256(input: InputStream): StreamDigest {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(BUFFER_SIZE)
        var total = 0L
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            digest.update(buffer, 0, read)
            total += read
        }
        return StreamDigest(hex = hex(digest.digest()), byteCount = total)
    }

    fun sha256(bytes: ByteArray): StreamDigest = sha256(bytes.inputStream())

    fun objectKey(sha256: String): String = "objects/${sha256.take(2)}/$sha256"

    private fun hex(bytes: ByteArray): String {
        val out = StringBuilder(bytes.size * 2)
        for (byte in bytes) {
            out.append(HEX[(byte.toInt() ushr 4) and 0x0f])
            out.append(HEX[byte.toInt() and 0x0f])
        }
        return out.toString()
    }

    private val HEX = "0123456789abcdef".toCharArray()
}

data class StreamDigest(val hex: String, val byteCount: Long)
