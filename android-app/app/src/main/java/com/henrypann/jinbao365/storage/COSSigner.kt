package com.henrypann.jinbao365.storage

import java.security.MessageDigest
import java.util.Locale
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** COS XML v5; SHA1 is required by the protocol, SHA256 verifies file contents. */
class COSSigner(private val credentials: StorageCredentials) {
    override fun toString() = "COSSigner(redacted)"
    fun authorization(method: String, path: String, query: Map<String, String> = emptyMap(),
                      headers: Map<String, String>, now: Long = System.currentTimeMillis() / 1000, validFor: Long = 900): String {
        require(credentials.valid() && method.uppercase(Locale.ROOT) in listOf("GET", "HEAD", "PUT", "POST"))
        require(path.startsWith('/') && !controls(path) && now >= 60 && now < Long.MAX_VALUE - 3601 && validFor in 1..3600)
        val (queryList, parameters) = canonical(query)
        val (headerList, httpHeaders) = canonical(headers)
        val keyTime = "${now - 60};${now + validFor}"
        val signKey = hmac(credentials.secretKey, keyTime)
        val httpString = "${method.lowercase(Locale.ROOT)}\n$path\n$parameters\n$httpHeaders\n"
        val digest = hex(MessageDigest.getInstance("SHA-1").digest(httpString.toByteArray(Charsets.UTF_8)))
        val signature = hmac(signKey, "sha1\n$keyTime\n$digest\n")
        return "q-sign-algorithm=sha1&q-ak=${credentials.secretID}&q-sign-time=$keyTime&q-key-time=$keyTime" +
            "&q-header-list=$headerList&q-url-param-list=$queryList&q-signature=$signature"
    }
    companion object {
        fun encode(value: String, preserveSlash: Boolean = false): String = buildString {
            value.toByteArray(Charsets.UTF_8).forEach { byte ->
                val n = byte.toInt() and 255
                if (n in 65..90 || n in 97..122 || n in 48..57 || n in listOf(45, 95, 46, 126) || preserveSlash && n == 47) append(n.toChar())
                else append("%%%02X".format(Locale.ROOT, n))
            }
        }
        private fun controls(s: String) = s.any { Character.isISOControl(it) }
        private fun canonical(fields: Map<String, String>): Pair<String, String> {
            val normalized = sortedMapOf<String, String>()
            fields.forEach { (key, value) ->
                require(key.isNotEmpty() && !controls(key) && !controls(value))
                val name = encode(key).lowercase(Locale.ROOT)
                require(!normalized.containsKey(name))
                normalized[name] = encode(value)
            }
            return normalized.keys.joinToString(";") to normalized.entries.joinToString("&") { "${it.key}=${it.value}" }
        }
        private fun hmac(key: String, message: String): String {
            val mac = Mac.getInstance("HmacSHA1")
            mac.init(SecretKeySpec(key.toByteArray(Charsets.UTF_8), "HmacSHA1"))
            return hex(mac.doFinal(message.toByteArray(Charsets.UTF_8)))
        }
        internal fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(Locale.ROOT, it.toInt() and 255) }
    }
}
