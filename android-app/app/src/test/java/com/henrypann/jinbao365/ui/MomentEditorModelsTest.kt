package com.henrypann.jinbao365.ui

import com.henrypann.jinbao365.editing.MomentDraft
import org.junit.Assert.*
import org.junit.Test

class MomentEditorModelsTest {
    @Test fun blankTextOnlyDraftCannotSaveIncludingArchiveUnicodeWhitespace() {
        val whitespace = " \t\r\n\u0085\u00a0\u1680\u2000\u2007\u200b\u2028\u2029\u202f\u205f\u3000"
        assertFalse(canSaveMoment(MomentDraft(occurredAtMillis = 1)))
        assertFalse(canSaveMoment(MomentDraft(title = whitespace, note = whitespace, occurredAtMillis = 1)))
    }

    @Test fun titleNoteOrMediaIndependentlyEnableSave() {
        val empty = MomentDraft(occurredAtMillis = 1)
        assertTrue(canSaveMoment(empty.copy(title = "A good day")))
        assertTrue(canSaveMoment(empty.copy(note = "\u200bRemember this\u00a0")))
        assertTrue(canSaveMoment(empty.copy(assetIds = listOf("photo"))))
    }

    @Test fun movingPhotosKeepsTheCoverOrderAndOtherFields() {
        val original = MomentDraft(title = "Three photos", note = "An afternoon", occurredAtMillis = 123,
            assetIds = listOf("a", "b", "c"))
        val reordered = moveMomentMedia(original, "b", -1)
        assertEquals(listOf("b", "a", "c"), reordered.assetIds)
        assertEquals(original.copy(assetIds = reordered.assetIds), reordered)
        assertEquals(original, moveMomentMedia(original, "a", -1))
        assertEquals(original, moveMomentMedia(original, "c", 1))
        assertEquals(original, moveMomentMedia(original, "missing", 1))
    }

}
