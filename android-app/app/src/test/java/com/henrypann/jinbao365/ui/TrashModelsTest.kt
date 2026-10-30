package com.henrypann.jinbao365.ui

import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.archive.EditStamp
import com.henrypann.jinbao365.editing.newDraftRecord
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.*
import org.junit.Test
import java.time.ZoneOffset

class TrashModelsTest {
    private fun record(id: String, deletedAt: Long?) = newDraftRecord(id, "phone", 100, ZoneOffset.UTC).let {
        val withText = it.copy(note = it.note.copy(value = JsonPrimitive("note $id")))
        if (deletedAt == null) withText
        else withText.copy(tombstone = withText.tombstone.copy(value = buildJsonObject { put("deletedAt", deletedAt) },
            edit = EditStamp(2, deletedAt, "phone")))
    }

    @Test fun trashListsOnlyDeletedRecordsNewestDeletionFirst() {
        val snapshot = ArchiveSnapshot.empty().copy(records = listOf(record("live", null), record("old", 200), record("new", 300)))
        val trashed = trashedMoments(snapshot)
        assertEquals(listOf("new", "old"), trashed.map { it.id })
        assertTrue(trashed.all { it.trashed })
        assertTrue(trashedMoments(ArchiveSnapshot.empty()).isEmpty())
    }
}
