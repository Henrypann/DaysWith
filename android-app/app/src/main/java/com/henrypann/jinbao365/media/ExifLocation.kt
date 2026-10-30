package com.henrypann.jinbao365.media

/** Redacted EXIF can still have GPS tags containing NUL refs and 0/0 rationals. */
object ExifLocation {
    fun present(latitude: String?, latitudeRef: String?, longitude: String?, longitudeRef: String?): Boolean {
        if (latitudeRef !in setOf("N", "S") || longitudeRef !in setOf("E", "W")) return false
        return coordinate(latitude, 90.0) != null && coordinate(longitude, 180.0) != null
    }

    private fun coordinate(text: String?, maximum: Double): Double? {
        val parts = text?.split(',')?.takeIf { it.size == 3 } ?: return null
        val values = parts.map { part ->
            val fraction = part.trim().split('/')
            if (fraction.size != 2) return null
            val numerator = fraction[0].toDoubleOrNull() ?: return null
            val denominator = fraction[1].toDoubleOrNull() ?: return null
            if (!numerator.isFinite() || !denominator.isFinite() || numerator < 0 || denominator <= 0) return null
            (numerator / denominator).takeIf(Double::isFinite) ?: return null
        }
        if (values[1] >= 60 || values[2] >= 60) return null
        val degrees = values[0] + values[1] / 60 + values[2] / 3600
        return degrees.takeIf { it <= maximum }
    }
}
