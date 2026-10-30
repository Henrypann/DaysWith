package com.henrypann.jinbao365.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.media.AudioAttributes
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import com.henrypann.jinbao365.archive.ImportProvenance
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.archive.FieldEnvelope
import com.henrypann.jinbao365.archive.MediaResource
import com.henrypann.jinbao365.backup.BackupPolicy
import com.henrypann.jinbao365.backup.CosDownload
import com.henrypann.jinbao365.backup.CosException
import com.henrypann.jinbao365.backup.CosFailure
import com.henrypann.jinbao365.backup.CosObjectInfo
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.media.ContentHash
import com.henrypann.jinbao365.ui.theme.JinbaoTheme
import com.henrypann.jinbao365.viewing.OriginalNetwork
import com.henrypann.jinbao365.viewing.OriginalObjectSource
import com.henrypann.jinbao365.viewing.PartnerOriginalDownloader
import com.henrypann.jinbao365.viewing.PhotoPreviewCopy
import java.io.File
import java.io.OutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "zh-rCN-w411dp-h891dp-xhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class PhotoViewerScreenshotTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    @get:Rule val temp = TemporaryFolder()

    @Test fun localOriginalFillsTheViewer() {
        val photo = writePng(File(temp.root, "objects/local/original.png"), Color.parseColor("#F7C948"))
        compose.setContent {
            JinbaoTheme {
                PhotoViewer(listOf(photoMedia(photo, partner = false)), 0, temp.root, offline(), allowCellular = false) {}
            }
        }
        compose.waitUntil(10_000) { compose.onAllNodesWithContentDescription("原图").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithContentDescription("原图").assertIsDisplayed()
        compose.onNodeWithText(PhotoPreviewCopy.DOWNLOAD_FAILED).assertDoesNotExist()
        capture("viewer-local-original")
    }

    @Test fun partnerOriginalShowsThumbnailWhileDownloading() {
        val cover = writePng(File(temp.root, "remote/mom/thumbs/cover.png"), Color.parseColor("#C5CED6"))
        val release = CountDownLatch(1)
        val started = CountDownLatch(1)
        val downloader = PartnerOriginalDownloader(temp.root, { OriginalNetwork.Unmetered }) { _, _ ->
            object : OriginalObjectSource {
                override fun head(key: String): CosObjectInfo? {
                    started.countDown()
                    check(release.await(20, TimeUnit.SECONDS))
                    return null
                }
                override fun download(key: String, output: OutputStream) = error("原图还在下载")
            }
        }
        try {
            compose.setContent {
                JinbaoTheme {
                    PhotoViewer(listOf(photoMedia(cover, partner = true)), 0, temp.root, downloader, allowCellular = false) {}
                }
            }
            compose.waitUntil(10_000) { compose.onAllNodesWithContentDescription("缩略图").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithTag("photoViewerLoading").assertIsDisplayed()
            compose.onNodeWithText(PhotoPreviewCopy.DOWNLOADING).assertIsDisplayed()
            compose.onNodeWithContentDescription("缩略图").assertIsDisplayed()
            compose.onNodeWithText(PhotoPreviewCopy.DOWNLOAD_FAILED).assertDoesNotExist()
            capture("viewer-partner-loading")
            assertTrue(started.await(5, TimeUnit.SECONDS))
        } finally {
            release.countDown()
        }
    }

    @Test fun partnerOriginalKeepsThumbnailWhenDownloadFails() {
        val cover = writePng(File(temp.root, "remote/mom/thumbs/cover.png"), Color.parseColor("#C5CED6"))
        val downloader = PartnerOriginalDownloader(temp.root, { OriginalNetwork.Unmetered }) { _, _ ->
            object : OriginalObjectSource {
                override fun head(key: String): CosObjectInfo? = throw CosException(CosFailure.Network)
                override fun download(key: String, output: OutputStream): CosDownload = error("没有下载")
            }
        }
        compose.setContent {
            JinbaoTheme {
                PhotoViewer(listOf(photoMedia(cover, partner = true)), 0, temp.root, downloader, allowCellular = false) {}
            }
        }
        compose.waitUntil(10_000) { compose.onAllNodesWithText(PhotoPreviewCopy.DOWNLOAD_FAILED).fetchSemanticsNodes().isNotEmpty() }
        // Local thumbnail decoding can complete after the network failure banner.
        compose.waitUntil(10_000) {
            runCatching { compose.onNodeWithContentDescription("缩略图").assertIsDisplayed() }.isSuccess
        }
        compose.onNodeWithContentDescription("缩略图").assertIsDisplayed()
        compose.onNodeWithTag("photoViewerPhase-failed").assertIsDisplayed()
        capture("viewer-partner-failed")
    }

    @Test fun myScreenSwitchIsSeparateFromBackupCellular() {
        var enabled = false
        compose.setContent {
            JinbaoTheme {
                MyScreen(ArchiveSnapshot.empty(), ParentIdentity.Dad, "已保存在这台手机", 0, {}, {}, {},
                    allowCellularOriginals = enabled, onAllowCellularOriginals = { enabled = it })
            }
        }
        compose.onNodeWithText(PhotoPreviewCopy.CELLULAR_TITLE).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(PhotoPreviewCopy.CELLULAR_DETAIL).assertIsDisplayed()
        compose.onNodeWithTag("cellularOriginalSwitch").performScrollTo().performClick()
        compose.waitUntil(5_000) { enabled }
        assertTrue(BackupPolicy.ALLOW_CELLULAR)
        assertFalse(PhotoPreviewCopy.CELLULAR_TITLE == BackupPolicy.WIFI_WAITING)
    }

    @Test fun videoSourceLabelStaysInHeaderAboveTheVideoFooter() = videoSourceLayout(1f)

    @Test @Config(qualifiers = "zh-rCN-w320dp-h800dp-xhdpi")
    fun videoSourceLabelAndFooterRemainSeparateAt200PercentType() = videoSourceLayout(2f)

    private fun videoSourceLayout(fontScale: Float) {
        val cover = writePng(File(temp.root, "objects/video-cover.png"), Color.parseColor("#C5CED6"))
        val base = photoMedia(cover, partner = false)
        val video = base.copy(kind = "video", thumbnail = base.image,
            original = base.original!!.copy(role = "video", contentType = "video/mp4",
                originalFilename = "video.mp4", objectKey = "objects/video.mp4", byteCount = 4096),
            provenance = ImportProvenance.SystemProvided)
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, fontScale)) {
                JinbaoTheme { PhotoViewer(listOf(video), 0, temp.root, offline(), allowCellular = false) {} }
            }
        }
        val source = compose.onNodeWithTag("photoViewerProvenance").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        val header = compose.onNodeWithTag("photoViewerHeader").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        val footer = compose.onNodeWithTag("photoViewerVideoFooter").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        compose.onNodeWithText("系统提供版本").assertIsDisplayed()
        compose.onNodeWithText(PhotoPreviewCopy.VIDEO_MISSING).assertIsDisplayed()
        assertTrue("Source label must stay within the naturally sized top bar", source.top >= header.top && source.bottom <= header.bottom)
        assertTrue("Source label must not overlap duration, size or playback status", source.bottom <= footer.top)
        assertTrue("Top bar and video footer must stay separate at large type", header.bottom <= footer.top)
        capture("viewer-video-source-font${(fontScale * 100).toInt()}")
    }

    @Test fun localSavedVideoOpensThePlayerWithMediaAudio() {
        val cover = writePng(File(temp.root, "objects/video-cover.png"), Color.parseColor("#C5CED6"))
        File(temp.root, "objects/video.mp4").writeBytes(ByteArray(64) { it.toByte() })
        compose.setContent {
            JinbaoTheme { PhotoViewer(listOf(videoMedia(cover, partner = false)), 0, temp.root, offline(), allowCellular = false) {} }
        }
        compose.onNodeWithTag("photoViewerPhase-videoPlayback").assertIsDisplayed()
        compose.onNodeWithTag("recordVideo").assertExists()
        compose.onNodeWithTag("recordVideoPlay").assertExists()
        compose.onNodeWithTag("photoViewerVideoHint").assertDoesNotExist()
        assertEquals(AudioAttributes.USAGE_MEDIA, VIDEO_PLAYBACK_AUDIO.usage)
        assertEquals(AudioAttributes.CONTENT_TYPE_MOVIE, VIDEO_PLAYBACK_AUDIO.contentType)
    }

    @Test fun partnerVideoAsksBeforeCellularThenPlaysTheVerifiedOriginal() {
        val cover = writePng(File(temp.root, "remote/mom/thumbs/video-cover.png"), Color.parseColor("#C5CED6"))
        val bytes = ByteArray(96) { (it * 7).toByte() }
        val digest = ContentHash.sha256(bytes)
        val downloads = AtomicInteger()
        val downloader = PartnerOriginalDownloader(temp.root, { OriginalNetwork.Metered }) { _, _ ->
            object : OriginalObjectSource {
                override fun head(key: String) = CosObjectInfo(digest.byteCount, digest.hex)
                override fun download(key: String, output: OutputStream): CosDownload {
                    downloads.incrementAndGet()
                    output.write(bytes)
                    return CosDownload(digest.byteCount, digest.hex)
                }
            }
        }
        val video = videoMedia(cover, partner = true).let {
            it.copy(original = it.original!!.copy(sha256 = digest.hex, byteCount = digest.byteCount))
        }
        compose.setContent {
            JinbaoTheme { PhotoViewer(listOf(video), 0, temp.root, downloader, allowCellular = false) {} }
        }
        compose.waitUntil(10_000) { compose.onAllNodesWithTag("photoViewerCellularConfirm").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText(PhotoPreviewCopy.CELLULAR_DIALOG_VIDEO, substring = true).assertIsDisplayed()
        assertEquals(0, downloads.get())
        compose.onNodeWithTag("photoViewerCellularCancel").performClick()
        compose.onNodeWithTag("photoViewerAskCellular").assertIsDisplayed().assertTextEquals(PhotoPreviewCopy.USE_CELLULAR_VIDEO)
        compose.onNodeWithTag("photoViewerAskCellular").performClick()
        compose.onNodeWithTag("photoViewerCellularConfirm").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithTag("photoViewerPhase-videoPlayback").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("recordVideoPlay").assertExists()
        assertEquals(1, downloads.get())
    }

    @Test fun partnerVideoOfflineOffersRetryInsteadOfAComingSoonNotice() {
        val cover = writePng(File(temp.root, "remote/mom/thumbs/video-cover.png"), Color.parseColor("#C5CED6"))
        compose.setContent {
            JinbaoTheme { PhotoViewer(listOf(videoMedia(cover, partner = true)), 0, temp.root, offline(), allowCellular = false) {} }
        }
        compose.waitUntil(10_000) { compose.onAllNodesWithTag("photoViewerRetry").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("photoViewerRetry").assertTextEquals(PhotoPreviewCopy.DOWNLOAD_FAILED)
        compose.onNodeWithTag("photoViewerVideoFooter").assertIsDisplayed()
        compose.onNodeWithTag("recordVideo").assertDoesNotExist()
    }

    private fun videoMedia(cover: File, partner: Boolean): MomentMedia {
        val base = photoMedia(cover, partner)
        return base.copy(kind = "video", thumbnail = base.thumbnail ?: base.image,
            original = base.original!!.copy(role = "video", contentType = "video/mp4",
                originalFilename = "video.mp4", objectKey = "objects/video.mp4", byteCount = 64))
    }

    private fun photoMedia(file: File, partner: Boolean): MomentMedia {
        val relative = temp.root.toPath().relativize(file.toPath()).joinToString("/")
        val resource = MediaResource("res-$relative", "asset", if (partner) "photo" else "photo", "image/png", "photo.png",
            128, "ab".repeat(32), relative, emptyMap<String, FieldEnvelope>())
        val preview = resource.copy(id = "preview-$relative", role = "preview", objectKey = relative, sha256 = "cd".repeat(32))
        return MomentMedia(
            assetId = if (partner) "remote-photo" else "local-photo",
            kind = "photo",
            image = if (partner) preview else resource,
            thumbnail = if (partner) preview else null,
            original = resource.copy(sha256 = "ab".repeat(32), byteCount = 128),
            partner = if (partner) ParentIdentity.Mom else null,
        )
    }

    private fun offline() = PartnerOriginalDownloader(temp.root, { OriginalNetwork.Offline }, { _, _ -> null })

    private fun writePng(file: File, color: Int): File {
        file.parentFile!!.mkdirs()
        val bitmap = Bitmap.createBitmap(600, 800, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(color)
        canvas.drawCircle(300f, 340f, 150f, Paint().apply { this.color = Color.WHITE })
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
        return file
    }

    private fun capture(name: String) {
        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        val file = File("build/photo-preview-screenshots/$name.png")
        file.parentFile!!.mkdirs()
        file.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
    }
}
