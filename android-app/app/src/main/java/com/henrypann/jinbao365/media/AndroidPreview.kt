package com.henrypann.jinbao365.media

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import androidx.exifinterface.media.ExifInterface
import java.io.ByteArrayOutputStream
import java.io.File

/** Still preview. Image decode is sampled and turned upright. Video asks for a scaled frame. */
object AndroidPreview : PreviewEncoder {
    private const val MAX_EDGE = 1080

    override fun jpegPreview(original: File, kind: String): ByteArray {
        val bitmap = if (kind == "video") videoFrame(original) else imageFrame(original)
        return try {
            val out = ByteArrayOutputStream()
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 80, out)) {
                throw ImportRejected("预览图生成失败，请重试。")
            }
            out.toByteArray()
        } finally {
            bitmap.recycle()
        }
    }

    private fun imageFrame(file: File): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw ImportRejected("无法读取这张照片的预览，请换一张重试。")
        }
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight)
        }
        val decoded = BitmapFactory.decodeFile(file.absolutePath, options)
            ?: throw ImportRejected("无法读取这张照片的预览，请换一张重试。")
        val orientation = try { ExifInterface(file.absolutePath).getAttributeInt(
            ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } catch (_: Exception) { ExifInterface.ORIENTATION_NORMAL }
        return upright(decoded, orientation)
    }

    private fun upright(bitmap: Bitmap, orientation: Int): Bitmap {
        val transform = ExifOrientation.transform(orientation)
        if (transform.degrees == 0 && !transform.flipHorizontal) return bitmap
        val matrix = Matrix()
        if (transform.flipHorizontal) matrix.preScale(-1f, 1f)
        if (transform.degrees != 0) matrix.postRotate(transform.degrees.toFloat())
        val turned = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        if (turned !== bitmap) bitmap.recycle()
        return turned
    }

    private fun videoFrame(file: File): Bitmap {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(file.absolutePath)
            return retriever.getScaledFrameAtTime(
                0,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                MAX_EDGE,
                MAX_EDGE,
            ) ?: throw ImportRejected("无法读取这个视频的预览，请换一个重试。")
        } finally {
            retriever.release()
        }
    }

    private fun sampleSize(width: Int, height: Int): Int {
        var sample = 1
        while (width / sample > MAX_EDGE * 2 || height / sample > MAX_EDGE * 2) {
            sample *= 2
        }
        return sample
    }
}
