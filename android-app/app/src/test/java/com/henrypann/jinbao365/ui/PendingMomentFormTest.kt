package com.henrypann.jinbao365.ui

import com.henrypann.jinbao365.editing.MomentDraft
import com.henrypann.jinbao365.archive.ArchiveJson
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.editing.newDraftRecord
import com.henrypann.jinbao365.editing.editedField
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import java.time.ZoneOffset
import org.junit.Assert.*
import org.junit.Test

class PendingMomentFormTest {
    @Test fun preparedMediaKeepsTextAndTimeTypedDuringImport() {
        val previous = MomentDraft("", "", 100L, listOf("a"))
        val typed = previous.copy(title = "今天", note = "还在写", occurredAtMillis = 200L)
        val prepared = previous.copy(occurredAtMillis = 50L, assetIds = listOf("a", "b"))
        assertEquals(typed.copy(assetIds = listOf("a", "b")), mergePreparedMoment(typed, previous, prepared))
    }
    @Test fun untouchedFieldsAcceptCaptureMetadataAndNeverDuplicateAssets() {
        val previous = MomentDraft("", "", 100L, listOf("a"))
        val prepared = previous.copy(occurredAtMillis = 50L, assetIds = listOf("a", "b"))
        assertEquals(prepared, mergePreparedMoment(previous, previous, prepared))
        assertEquals(prepared, mergePreparedMoment(prepared, previous, prepared))
    }
    @Test fun restoredTextHasPriorityWithoutAnInMemoryBaseline() {
        val restored = MomentDraft("草稿", "写到一半", 200L, emptyList())
        val prepared = MomentDraft("", "", 50L, listOf("photo"))
        assertEquals(restored.copy(assetIds = listOf("photo")), mergePreparedMoment(restored, null, prepared))
    }
    @Test fun rebasingRequiresActualAssetAppendAndUnchangedText() {
        val original = newDraftRecord("draft", "test", 1_700_000_000_000L, ZoneOffset.UTC)
        fun fingerprint(record: com.henrypann.jinbao365.archive.ArchiveRecord) =
            ArchiveJson.canonical(ArchiveSnapshot.empty().copy(records = listOf(record)))
        val appended = original.copy(assetIds = editedField(original.assetIds,
            JsonArray(listOf(JsonPrimitive("asset"))), "test", 1_700_000_000_001L))
        assertTrue(isPreparedDraftAdvance(fingerprint(original), fingerprint(appended)))
        assertFalse(isPreparedDraftAdvance(fingerprint(original), fingerprint(original)))
        val changedText = appended.copy(note = editedField(appended.note, JsonPrimitive("external change"), "other", 1_700_000_000_002L))
        assertFalse(isPreparedDraftAdvance(fingerprint(original), fingerprint(changedText)))
        assertFalse(isPreparedDraftAdvance(fingerprint(appended), fingerprint(original)))
    }
}
