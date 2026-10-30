package com.henrypann.jinbao365.media

import android.net.Uri
import android.net.ConnectivityManager
import androidx.test.platform.app.InstrumentationRegistry
import androidx.exifinterface.media.ExifInterface
import com.henrypann.jinbao365.JinbaoApplication
import com.henrypann.jinbao365.archive.ArchiveJson
import com.henrypann.jinbao365.archive.ImportProvenance
import com.henrypann.jinbao365.archive.importProvenance
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import kotlinx.serialization.json.*

/** Explicit offline fixture-only acceptance; never commits a record or initializes cloud backup. */
class GalleryOriginalInstrumentedTest {
    @Test fun originalFixtureRetainsBytesAndCaptureMetadata() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val app = instrumentation.targetContext.applicationContext as JinbaoApplication
        val args = InstrumentationRegistry.getArguments()
        val originalExpected = args.getString("mode") != "fallback"
        val rawUri = requireNotNull(args.getString("fixtureUri")) { "fixtureUri is required" }
        val expectedHash = requireNotNull(args.getString("fixtureSha256")) { "fixtureSha256 is required" }
        require(expectedHash == "204e8cd97ed6baccaf6a5d6e1dc006643fc6a7d6c95e00fc176d2dc8278499d0") { "Only the synthetic regression fixture is permitted" }
        val uri = Uri.parse(rawUri)
        require(uri.authority == "media" && uri.path?.contains("/picker/") != true)
        val network = app.getSystemService(ConnectivityManager::class.java)
        check(network.activeNetwork == null) { "Acceptance requires offline device" }
        fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        val before = digest(ArchiveJson.canonical(app.archive.loadSnapshot()).toByteArray())
        val task = app.pendingMedia.enqueueSelections(listOf(MediaSelection(uri, ImportOrigin.MediaStoreGallery)))
        try {
            val deadline = System.currentTimeMillis() + 60_000
            var result = app.pendingMedia.tasksForDraft(task.draftId).single { it.id == task.id }
            while (result.status in setOf(PendingMediaStatus.Queued, PendingMediaStatus.Importing) && System.currentTimeMillis() < deadline) {
                Thread.sleep(100)
                result = app.pendingMedia.tasksForDraft(task.draftId).single { it.id == task.id }
            }
            assertEquals(PendingMediaStatus.Ready, result.status)
            val draft = requireNotNull(app.archive.loadDraft(task.draftId))
            val asset = draft.assets.single()
            val original = draft.resources.single { it.role != "preview" }
            val file = File(app.filesDir, "media/${original.objectKey}")
            val hash = digest(file.readBytes())
            val exif = ExifInterface(file)
            val gps = exif.latLong
            val output = buildJsonObject {
                put("package", app.packageName)
                put("sha256", hash)
                put("provenance", asset.importProvenance.wireValue)
                put("capture", asset.capturedAt.value)
                put("dateTimeOriginal", exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL))
                put("offsetTimeOriginal", exif.getAttribute(ExifInterface.TAG_OFFSET_TIME_ORIGINAL))
                put("subSecTimeOriginal", exif.getAttribute(ExifInterface.TAG_SUBSEC_TIME_ORIGINAL))
                put("latitude", gps?.get(0))
                put("longitude", gps?.get(1))
                put("altitude", exif.getAltitude(Double.NaN))
            }
            val directory = File(app.getExternalFilesDir(null), "gallery-226-evidence").apply { mkdirs() }
            File(directory, if (originalExpected) "original-result.json" else "system-result.json").writeText(output.toString())
            if (originalExpected) {
                assertEquals(expectedHash, hash)
                assertEquals(ImportProvenance.VerifiedOriginal, asset.importProvenance)
            } else {
                assertEquals(ImportProvenance.SystemProvided, asset.importProvenance)
                assertTrue(file.length() > 0)
            }
            assertEquals("2026:10:16 16:30:40", exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL))
            assertEquals("+08:00", exif.getAttribute(ExifInterface.TAG_OFFSET_TIME_ORIGINAL))
            assertEquals("456", exif.getAttribute(ExifInterface.TAG_SUBSEC_TIME_ORIGINAL))
            if (originalExpected) {
                assertNotNull(gps)
                assertEquals(31.2304, gps!![0], 0.000001)
                assertEquals(121.4737, gps[1], 0.000001)
                assertEquals(12.34, exif.getAltitude(Double.NaN), 0.001)
            }
        } finally {
            app.pendingMedia.cancel(task.id)
            if (app.archive.loadDraft(task.draftId) != null) app.mediaImports.discardDraft(task.draftId)
            assertEquals(before, digest(ArchiveJson.canonical(app.archive.loadSnapshot()).toByteArray()))
        }
    }
}
