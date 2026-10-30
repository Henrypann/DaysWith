package com.henrypann.jinbao365.media

/** ISO 6709 location from MediaMetadataRetriever.METADATA_KEY_LOCATION. */
object VideoLocation {
    private val PAIR = Regex("""[+-]\d+(?:\.\d+)?[+-]\d+(?:\.\d+)?""")

    fun present(metadata: String?): Boolean {
        if (metadata.isNullOrBlank()) return false
        return PAIR.containsMatchIn(metadata)
    }
}
