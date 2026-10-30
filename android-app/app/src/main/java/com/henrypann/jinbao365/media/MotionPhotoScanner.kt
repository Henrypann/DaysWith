package com.henrypann.jinbao365.media

import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.security.MessageDigest

/**
 * A motion photo is an image whose XMP names an embedded video and whose
 * bytes at that offset are a video container. A marker alone is not enough.
 */
object MotionPhotoScanner {
    private const val XMP_LIMIT = 512 * 1024

    fun copyHashAndScan(input: InputStream, dest: File): CopiedOriginal {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(ContentHash.BUFFER_SIZE)
        val xmp = XmpCapture()
        var total = 0L
        try {
            dest.outputStream().use { output ->
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    digest.update(buffer, 0, read)
                    output.write(buffer, 0, read)
                    total += read
                    xmp.accept(buffer, read)
                }
                output.fd.sync()
            }
        } catch (error: Exception) {
            dest.delete()
            throw error
        }
        val sha = hex(digest.digest())
        return CopiedOriginal(
            sha256 = sha,
            byteCount = total,
            motionPhoto = isMotionPhoto(xmp.text(), dest),
        )
    }

    fun isMotionPhoto(xmp: String, file: File): Boolean {
        if (!claimsMotion(xmp)) return false
        val start = videoStart(xmp, file.length()) ?: return false
        return looksLikeVideo(file, start)
    }

    private fun claimsMotion(xmp: String): Boolean {
        return flagIsOne(xmp, "MotionPhoto") || flagIsOne(xmp, "MicroVideo")
    }

    private fun flagIsOne(xmp: String, name: String): Boolean {
        return xmp.contains("$name=\"1\"") ||
            xmp.contains("$name>1<") ||
            xmp.contains("$name='1'")
    }

    private fun videoStart(xmp: String, fileLength: Long): Long? {
        if (flagIsOne(xmp, "MicroVideo")) {
            val offset = firstNumber(xmp, "MicroVideoOffset") ?: return null
            val start = fileLength - offset
            if (start >= 0) return start
        }
        val tag = Regex("<[^>]*video/(?:mp4|quicktime)[^>]*>", RegexOption.IGNORE_CASE).find(xmp)?.value
            ?: return null
        val length = firstNumber(tag, "Length") ?: return null
        val padding = firstNumber(tag, "Padding") ?: 0L
        val start = fileLength - length - padding
        return if (start >= 0) start else null
    }

    private fun firstNumber(text: String, name: String): Long? {
        val match = Regex("""$name\s*=\s*"(\d+)"""").find(text)
            ?: Regex("""$name>(\d+)<""").find(text)
            ?: return null
        return match.groupValues[1].toLongOrNull()
    }

    private fun looksLikeVideo(file: File, start: Long): Boolean {
        if (start < 0 || start + 8 > file.length()) return false
        RandomAccessFile(file, "r").use { raf ->
            raf.seek(start)
            val header = ByteArray(32)
            val read = raf.read(header)
            if (read < 8) return false
            return header.copyOf(read).toString(Charsets.ISO_8859_1).contains("ftyp")
        }
    }

    private fun hex(bytes: ByteArray): String {
        val chars = "0123456789abcdef".toCharArray()
        val out = StringBuilder(bytes.size * 2)
        for (byte in bytes) {
            out.append(chars[(byte.toInt() ushr 4) and 0x0f])
            out.append(chars[byte.toInt() and 0x0f])
        }
        return out.toString()
    }

    private class XmpCapture {
        private val pending = StringBuilder()
        private val packet = StringBuilder()
        private var started = false
        private var finished = false

        fun accept(buffer: ByteArray, read: Int) {
            if (finished || read <= 0) return
            pending.append(buffer.copyOf(read).toString(Charsets.ISO_8859_1))
            if (!started) {
                val meta = pending.indexOf("<x:xmpmeta")
                val packetStart = pending.indexOf("<?xpacket begin")
                val index = listOf(meta, packetStart).filter { it >= 0 }.minOrNull()
                if (index == null) {
                    if (pending.length > 64) pending.delete(0, pending.length - 64)
                    return
                }
                started = true
                pending.delete(0, index)
            }
            packet.append(pending)
            pending.clear()
            if (packet.length > XMP_LIMIT) {
                finished = true
                packet.clear()
                return
            }
            if (packet.contains("</x:xmpmeta>") || packet.contains("<?xpacket end")) finished = true
        }

        fun text(): String = packet.toString()
    }
}

data class CopiedOriginal(val sha256: String, val byteCount: Long, val motionPhoto: Boolean)
