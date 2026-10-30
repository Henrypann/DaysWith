package com.henrypann.jinbao365.media

import android.media.MediaMetadataRetriever
import androidx.exifinterface.media.ExifInterface
import kotlinx.serialization.json.JsonObject
import java.io.File

object AndroidMediaFacts {
    fun hasLocation(file: File, kind: String): Boolean = try {
        if (kind == "video") videoHasLocation(file) else {
            val exif = ExifInterface(file.absolutePath)
            ExifLocation.present(
                exif.getAttribute(ExifInterface.TAG_GPS_LATITUDE),
                exif.getAttribute(ExifInterface.TAG_GPS_LATITUDE_REF),
                exif.getAttribute(ExifInterface.TAG_GPS_LONGITUDE),
                exif.getAttribute(ExifInterface.TAG_GPS_LONGITUDE_REF),
            )
        }
    } catch (_: Exception) {
        false
    }

    /**
     * DateTimeOriginal plus OffsetTimeOriginal only. DateTime is the file's
     * modification time and can carry a different offset, so it is not a fallback.
     */
    fun capture(file: File, kind: String): JsonObject = try {
        if (kind == "video") videoCapture(file) else {
            val exif = ExifInterface(file.absolutePath)
            CaptureTime.fromExif(exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL),
                exif.getAttribute(ExifInterface.TAG_OFFSET_TIME_ORIGINAL),
                exif.getAttribute(ExifInterface.TAG_SUBSEC_TIME_ORIGINAL))
        }
    } catch (error: java.util.concurrent.CancellationException) { throw error }
      catch (_: Exception) { CaptureTime.unknown() }

    private fun videoHasLocation(file: File): Boolean {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(file.absolutePath)
            return VideoLocation.present(
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION),
            )
        } finally {
            retriever.release()
        }
    }

    private fun videoCapture(file: File): JsonObject {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(file.absolutePath)
            return CaptureTime.fromVideoMetadata(
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DATE),
            )
        } finally {
            retriever.release()
        }
    }
}
