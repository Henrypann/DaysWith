package com.henrypann.jinbao365.ui

import com.henrypann.jinbao365.archive.*
import com.henrypann.jinbao365.editing.*
import com.henrypann.jinbao365.media.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.time.ZoneOffset

class GalleryImportFormTest {
    @Test fun retryRestoresSelectionOrderWithoutUndoingManualOrder() {
        assertEquals(listOf("a", "b", "c", "e"), mergeImportedAssetOrder(listOf("a", "b", "e"), listOf("a", "b", "c", "e")))
        assertEquals(listOf("b", "a", "c", "e"), mergeImportedAssetOrder(listOf("b", "a", "e"), listOf("a", "b", "c", "e")))
        assertEquals(listOf("a", "b"), mergeImportedAssetOrder(listOf("a"), listOf("a", "b")))
    }
    @Test fun progressOrCancelledItemCannotAuthorizeDraftChange() {
        val before = newDraftRecord("draft", "test", 1_700_000_000_000L, ZoneOffset.UTC)
        val after = before.copy(assetIds = editedField(before.assetIds, JsonArray(listOf(JsonPrimitive("asset"))), "test", 1_700_000_000_001L))
        fun fingerprint(record: ArchiveRecord) = ArchiveJson.canonical(ArchiveSnapshot.empty().copy(records = listOf(record)))
        val item = PendingMediaItem("item", 0, ImportOrigin.MediaStoreGallery, PendingMediaItemStatus.Success, "asset", null, ImportProvenance.VerifiedOriginal)
        fun task(i: PendingMediaItem) = PendingMediaTask("task", "draft", ImportOrigin.MediaStoreGallery, PendingMediaStatus.Importing, 1, 2, null, listOf(i))
        assertTrue(isReceiptedDraftAdvance(fingerprint(before), fingerprint(after), listOf(task(item))))
        assertFalse(isReceiptedDraftAdvance(fingerprint(before), fingerprint(after), listOf(task(item.copy(status = PendingMediaItemStatus.Cancelled)))))
        assertFalse(isReceiptedDraftAdvance(fingerprint(before), fingerprint(after), listOf(task(item.copy(assetId = "other")))))
        assertFalse(isReceiptedDraftAdvance(fingerprint(before), fingerprint(before), listOf(task(item))))
    }
    @Test fun captureTimeUsesShootingOffsetAndShowsUnknownHonestly() {
        val capture = CaptureTime.fromExif("2026:10:16 16:30:40", "+08:00", "456")
        val asset = MediaAsset("a", "photo", FieldEnvelope(capture, EditStamp(1, 0, "test")), emptyList(), emptyMap())
        assertEquals("拍摄时间：2026年10月16日 16:30:40.456 UTC+08:00", captureTimeLabel(asset))
        assertEquals("拍摄时间未知", captureTimeLabel(asset.copy(capturedAt = asset.capturedAt.copy(value = CaptureTime.unknown()))))
        assertEquals("拍摄时间未知", captureTimeLabel(null))
        assertTrue(captureTimeLabel(asset.copy(capturedAt = asset.capturedAt.copy(value = CaptureTime.zoneUnknown(1792139440456L)))).endsWith("UTC · 拍摄时区未知"))
    }
}
