package com.henrypann.jinbao365.storage

/** Never use a data class: generated toString/copy would expose secrets. */
class StorageCredentials(val secretID: String, val secretKey: String) {
    fun valid() = validID(secretID) && validKey(secretKey)
    companion object {
        // The identifier is embedded in q-ak; keys remain their original HMAC
        // input text. ASCII makes each STS field's 1024-byte bound exact.
        private val idFormat = Regex("[A-Za-z0-9_-]{1,1024}")
        private val keyFormat = Regex("[A-Za-z0-9_+/=-]{1,1024}")
        fun validID(value: String) = value.matches(idFormat)
        fun validKey(value: String) = value.matches(keyFormat)
    }
    override fun toString() = "StorageCredentials(redacted)"
}

data class StorageConfiguration(
    val bucket: String = "",
    val region: String = "ap-shanghai",
    val prefix: String = "life/v1/",
) {
    fun validate() {
        require(bucket.matches(Regex("[a-z0-9][a-z0-9-]{1,48}-[0-9]{5,20}")))
        require(region.matches(Regex("[a-z]{2}-[a-z][a-z0-9-]{1,40}")))
        require(prefix.length in 1..256 && prefix.endsWith('/') && !prefix.startsWith('/'))
        require(prefix.split('/').dropLast(1).all { it.isNotEmpty() && it != "." && it != ".." && it.matches(Regex("[A-Za-z0-9_-]+")) })
    }
    val host: String get() { validate(); return "$bucket.cos.$region.myqcloud.com" }
}
