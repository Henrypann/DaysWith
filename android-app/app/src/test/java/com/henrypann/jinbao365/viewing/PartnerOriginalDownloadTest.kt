package com.henrypann.jinbao365.viewing

import com.henrypann.jinbao365.backup.BackupPolicy
import com.henrypann.jinbao365.backup.CosDownload
import com.henrypann.jinbao365.backup.CosException
import com.henrypann.jinbao365.backup.CosFailure
import com.henrypann.jinbao365.backup.CosObjectInfo
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.media.ContentHash
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.OutputStream

class PartnerOriginalDownloadTest {
    @get:Rule val temp = TemporaryFolder()

    @Test fun checksumMustPassBeforeTheThumbnailIsReplaced() {
        val body = "original-bytes".toByteArray()
        val sha = ContentHash.sha256(body).hex
        val request = request(sha, body.size.toLong())
        val lyingTransport = FakeSource(body, CosObjectInfo(body.size.toLong(), sha), reportedSha = "b".repeat(64))
        val good = temp.newFolder()
        val ready = downloader(lyingTransport, good).fetch(request, allowCellular = false, confirmed = false)
        assertTrue(ready is PartnerOriginalResult.Ready && !ready.cacheHit)
        assertArrayEquals(body, visibleOriginal(ready)!!.readBytes())
        assertEquals(partnerObjectKey(ParentIdentity.Mom, sha), lyingTransport.keys.distinct().single())
        assertTrue(lyingTransport.keys.none { "://" in it || "?" in it || "secret" in it })

        val wrongBody = "not-the-original".toByteArray()
        val mismatched = FakeSource(wrongBody, CosObjectInfo(wrongBody.size.toLong(), sha), reportedSha = sha)
        val mismatchRoot = temp.newFolder()
        val rejected = downloader(mismatched, mismatchRoot).fetch(request, allowCellular = true, confirmed = false)
        assertTrue(rejected is PartnerOriginalResult.Failed)
        assertNull(visibleOriginal(rejected))
        assertFalse(cached(mismatchRoot, request).isFile)

        val other = "another-object".toByteArray()
        val otherSha = ContentHash.sha256(other).hex
        val swappedRoot = temp.newFolder()
        val swapped = FakeSource(other, CosObjectInfo(other.size.toLong(), otherSha), reportedSha = otherSha)
        assertTrue(downloader(swapped, swappedRoot).fetch(request, allowCellular = true, confirmed = false) is PartnerOriginalResult.Failed)
        assertFalse(cached(swappedRoot, request).isFile)

        val shortRoot = temp.newFolder()
        val shortHeader = FakeSource(body, CosObjectInfo(body.size.toLong() + 8, sha), reportedSha = sha)
        assertTrue(downloader(shortHeader, shortRoot).fetch(request, allowCellular = true, confirmed = false) is PartnerOriginalResult.Failed)
        assertFalse(cached(shortRoot, request).isFile)

        val missingRoot = temp.newFolder()
        val missingHeader = FakeSource(body, CosObjectInfo(body.size.toLong(), null), reportedSha = sha)
        assertTrue(downloader(missingHeader, missingRoot).fetch(request, allowCellular = true, confirmed = false) is PartnerOriginalResult.Failed)
        assertFalse(cached(missingRoot, request).isFile)
        assertTrue(temp.root.walk().none { it.name.contains(".partial") })
    }

    @Test fun failedDownloadKeepsTheThumbnailAndRetrySucceeds() {
        val body = "retry-original".toByteArray()
        val sha = ContentHash.sha256(body).hex
        val request = request(sha, body.size.toLong())
        val root = temp.newFolder()
        val thumb = File(root, "remote/mom/thumbs/cover.png")
        thumb.parentFile!!.mkdirs()
        thumb.writeBytes("thumbnail".toByteArray())
        val source = FakeSource(body, CosObjectInfo(body.size.toLong(), sha), reportedSha = sha, failures = 1)
        val loader = downloader(source, root)
        val failed = loader.fetch(request, allowCellular = false, confirmed = false)
        assertTrue(failed is PartnerOriginalResult.Failed)
        assertNull(visibleOriginal(failed))
        assertFalse(cached(root, request).isFile)
        assertArrayEquals("thumbnail".toByteArray(), thumb.readBytes())
        val ready = loader.fetch(request, allowCellular = false, confirmed = false)
        assertTrue(ready is PartnerOriginalResult.Ready && !ready.cacheHit)
        assertArrayEquals(body, visibleOriginal(ready)!!.readBytes())
        assertArrayEquals("thumbnail".toByteArray(), thumb.readBytes())
        assertEquals(1, source.downloads)
    }

    @Test fun secondOpenReadsTheCacheWithoutDownloading() {
        val body = "cached-original".toByteArray()
        val sha = ContentHash.sha256(body).hex
        val request = request(sha, body.size.toLong())
        val root = temp.newFolder()
        val destination = cached(root, request)
        destination.parentFile!!.mkdirs()
        destination.writeBytes(body)
        val source = FakeSource(body, CosObjectInfo(body.size.toLong(), sha), reportedSha = sha)
        val ready = downloader(source, root, OriginalNetwork.Metered).fetch(request, allowCellular = false, confirmed = false)
        assertTrue(ready is PartnerOriginalResult.Ready && ready.cacheHit)
        assertEquals(destination.canonicalFile, visibleOriginal(ready))
        assertEquals(0, source.heads)
        assertEquals(0, source.downloads)
    }

    @Test fun meteredDownloadWaitsForConfirmationUnlessTheSeparateSwitchIsOn() {
        val body = "cellular-original".toByteArray()
        val sha = ContentHash.sha256(body).hex
        val request = request(sha, body.size.toLong())
        val blocked = CountingSource(body, sha)
        val waiting = downloader(blocked, temp.newFolder(), OriginalNetwork.Metered)
            .fetch(request, allowCellular = false, confirmed = false)
        assertTrue(waiting is PartnerOriginalResult.NeedsConfirmation)
        assertNull(visibleOriginal(waiting))
        assertEquals(0, blocked.opens)

        val confirmed = CountingSource(body, sha)
        val afterConfirm = downloader(confirmed, temp.newFolder(), OriginalNetwork.Metered)
            .fetch(request, allowCellular = false, confirmed = true)
        assertTrue(afterConfirm is PartnerOriginalResult.Ready)
        assertEquals(1, confirmed.opens)
        assertArrayEquals(body, visibleOriginal(afterConfirm)!!.readBytes())

        val switched = CountingSource(body, sha)
        val allowed = downloader(switched, temp.newFolder(), OriginalNetwork.Metered)
            .fetch(request, allowCellular = true, confirmed = false)
        assertTrue(allowed is PartnerOriginalResult.Ready)
        assertEquals(1, switched.opens)

        val wifi = CountingSource(body, sha)
        assertTrue(downloader(wifi, temp.newFolder(), OriginalNetwork.Unmetered)
            .fetch(request, allowCellular = false, confirmed = false) is PartnerOriginalResult.Ready)
        assertEquals(1, wifi.opens)

        val preferenceFile = File(temp.newFolder(), "prefs/cellular-original-preview")
        val preference = CellularOriginalPreference(preferenceFile)
        assertFalse(preference.allow())
        preference.setAllow(true)
        assertTrue(CellularOriginalPreference(preferenceFile).allow())
        preference.setAllow(false)
        assertFalse(CellularOriginalPreference(preferenceFile).allow())
        assertTrue(BackupPolicy.ALLOW_CELLULAR)
        assertEquals(PhotoPreviewCopy.DOWNLOAD_FAILED, "下载失败，点重试")
    }

    private fun request(sha: String, bytes: Long) = OriginalRequest(ParentIdentity.Mom, sha, bytes)

    private fun cached(root: File, request: OriginalRequest) =
        File(root, partnerCacheRelative(request.partner, request.sha256)!!)

    private fun downloader(source: OriginalObjectSource, root: File, network: OriginalNetwork = OriginalNetwork.Unmetered) =
        PartnerOriginalDownloader(root, { network }) { _, _ -> source }

    private class FakeSource(
        private val body: ByteArray,
        private val info: CosObjectInfo?,
        private val reportedSha: String,
        var failures: Int = 0,
    ) : OriginalObjectSource {
        val keys = mutableListOf<String>()
        var heads = 0
        var downloads = 0
        override fun head(key: String): CosObjectInfo? {
            heads++
            keys += key
            if (failures > 0) {
                failures--
                throw CosException(CosFailure.Network)
            }
            return info
        }
        override fun download(key: String, output: OutputStream): CosDownload {
            downloads++
            keys += key
            output.write(body)
            return CosDownload(body.size.toLong(), reportedSha)
        }
    }

    private class CountingSource(private val body: ByteArray, private val sha: String) : OriginalObjectSource {
        var opens = 0
        override fun head(key: String): CosObjectInfo? {
            opens++
            return CosObjectInfo(body.size.toLong(), sha)
        }
        override fun download(key: String, output: OutputStream): CosDownload {
            output.write(body)
            return CosDownload(body.size.toLong(), "f".repeat(64))
        }
    }
}
