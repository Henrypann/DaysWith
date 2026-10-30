package com.henrypann.jinbao365.ui

import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.archive.EditStamp
import com.henrypann.jinbao365.archive.FieldEnvelope
import com.henrypann.jinbao365.archive.MediaAsset
import com.henrypann.jinbao365.archive.MediaResource
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.editing.newDraftRecord
import com.henrypann.jinbao365.viewing.downloadPlan
import com.henrypann.jinbao365.viewing.downloadsOriginal
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.*
import org.junit.Test
import java.time.ZoneOffset

class MomentDetailModelsTest {
    @Test fun textOnlyMomentHasNoGalleryAndKeepsTitleAndNote() {
        val record = newDraftRecord("note", "phone", 100, ZoneOffset.UTC).let {
            it.copy(title = it.title!!.copy(value = JsonPrimitive("Small memory")),
                note = it.note.copy(value = JsonPrimitive("The rain stopped.")))
        }
        val detail = momentDetailModel(ArchiveSnapshot.empty().copy(records = listOf(record)), "note")!!
        assertEquals("Small memory", detail.title)
        assertEquals("The rain stopped.", detail.note)
        assertTrue(detail.media.isEmpty())
        assertFalse(detail.trashed)
        assertNull(momentDetailModel(ArchiveSnapshot.empty(), "missing"))
    }

    @Test fun galleryKeepsRecordSelectionOrderAndUsesOnlyOwnedResources() {
        val record = newDraftRecord("photo", "phone", 100, ZoneOffset.UTC).let {
            it.copy(assetIds = it.assetIds.copy(value = JsonArray(listOf("b", "a").map(::JsonPrimitive))))
        }
        val resources = listOf(resource("original-a", "a", "photo"), resource("preview-b", "b", "preview"),
            resource("foreign", "other", "photo"))
        val snapshot = ArchiveSnapshot.empty().copy(records = listOf(record), resources = resources,
            assets = listOf(asset("a", listOf("original-a")), asset("b", listOf("foreign", "preview-b"))))
        val detail = momentDetailModel(snapshot, "photo")!!
        assertEquals(listOf("b", "a"), detail.media.map { it.assetId })
        assertEquals(listOf("preview-b", "original-a"), detail.media.map { it.image?.id })
    }

    @Test fun trashedMomentsRemainAvailableForRestoreWithTheirMedia() {
        val record = newDraftRecord("trash", "phone", 100, ZoneOffset.UTC).let {
            it.copy(assetIds = it.assetIds.copy(value = JsonArray(listOf(JsonPrimitive("a")))),
                tombstone = it.tombstone.copy(value = JsonPrimitive(200)))
        }
        val snapshot = ArchiveSnapshot.empty().copy(records = listOf(record), assets = listOf(asset("a", listOf("r"))),
            resources = listOf(resource("r", "a", "photo")))
        val detail = momentDetailModel(snapshot, "trash")!!
        assertTrue(detail.trashed)
        assertEquals("r", detail.media.single().image?.id)
        assertTrue(timelineModel(snapshot).days.isEmpty())
    }

    @Test fun partnerRecordKeepsThumbnailAndOriginalAndPrefetchesOnlyTheNextPhoto() {
        val record = newDraftRecord("remote:mom:record:DAY", "phone", 100, ZoneOffset.UTC).let {
            it.copy(assetIds = it.assetIds.copy(value = JsonArray(listOf("a", "b", "c", "clip").map(::JsonPrimitive))))
        }
        fun photo(id: String, sha: String) = listOf(
            resource("preview-$id", id, "preview"),
            resource("original-$id", id, "photo").copy(sha256 = sha, byteCount = 20),
        )
        val snapshot = ArchiveSnapshot.empty().copy(records = listOf(record),
            assets = listOf(
                asset("a", listOf("preview-a", "original-a")),
                asset("b", listOf("preview-b", "original-b")),
                asset("c", listOf("preview-c", "original-c")),
                asset("clip", listOf("video")).copy(kind = "video"),
            ),
            resources = photo("a", "a".repeat(64)) + photo("b", "b".repeat(64)) + photo("c", "c".repeat(64)) +
                resource("video", "clip", "video").copy(sha256 = "d".repeat(64), byteCount = 30))
        val detail = momentDetailModel(snapshot, record.id)!!
        assertEquals(ParentIdentity.Mom, detail.media.first().partner)
        assertEquals("preview-a", detail.media.first().thumbnail?.id)
        assertEquals("original-a", detail.media.first().original?.id)
        assertEquals("video", detail.media.last().kind)
        val entries = detail.media.map { it.toViewerEntry() }
        assertEquals(listOf(true, true, true, true), entries.map { it.downloadsOriginal })
        val first = downloadPlan(entries, 0)
        assertEquals("a", first.visibleId)
        assertEquals("b", first.prefetchId)
        assertEquals("c", downloadPlan(entries, 2).visibleId)
        assertNull(downloadPlan(entries, 2).prefetchId)
        assertEquals("clip", downloadPlan(entries, 3).visibleId)
        assertNull(downloadPlan(entries, 3).prefetchId)
    }

    private fun asset(id: String, resources: List<String>) = MediaAsset(id, "photo",
        FieldEnvelope(JsonNull, EditStamp(1, 100, "phone")), resources, emptyMap())

    private fun resource(id: String, owner: String, role: String) = MediaResource(
        id, owner, role, "image/jpeg", "$id.jpg", 1, "a".repeat(64), "media/$id.jpg", emptyMap(),
    )
}
