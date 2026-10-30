package com.henrypann.jinbao365.media

import com.henrypann.jinbao365.archive.ArchiveJson
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.archive.FieldEnvelope
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException

class MediaImportLifecycleTest {
    @get:Rule val temp = TemporaryFolder()

    @Test
    fun aLiveDuplicateDiscardsItsDifferentPreviewWithoutSaving() {
        val root = temp.newFolder()
        val first = prepare(root)
        val current = snapshotWithImport(ArchiveSnapshot.empty(), "android", 10L, first)
        val before = objectFiles(root)
        val again = prepare(root, preview = "different-preview", snapshot = current)
        assertTrue(again.previewFile.isFile)
        assertSame(current, again.saveToArchive(current, "android", 11L) { throw AssertionError("duplicate saved") })
        assertEquals(before, objectFiles(root))
        assertArrayEquals(SOURCE.toByteArray(), File(root, first.original.objectKey).readBytes())
        assertTrue(first.previewFile.isFile)
    }

    @Test
    fun reimportingATrashedAssetKeepsOldResourcesAndDiscardsTheNewPreview() {
        val root = temp.newFolder()
        val first = prepare(root)
        val current = trashed(snapshotWithImport(ArchiveSnapshot.empty(), "android", 10L, first))
        val before = objectFiles(root)
        val again = prepare(root, preview = "different-preview", snapshot = current)
        var saved: ArchiveSnapshot? = null
        val updated = again.saveToArchive(current, "android", 11L) { saved = it }
        assertSame(updated, saved)
        assertEquals(2, updated.records.size)
        assertEquals(current.assets, updated.assets)
        assertEquals(current.resources, updated.resources)
        assertEquals(before, objectFiles(root))
        ArchiveJson.parseSnapshot(ArchiveJson.canonical(updated))
    }

    @Test
    fun aDuplicatePreservesAPreviewSharedWithAnotherAsset() {
        val root = temp.newFolder()
        val first = prepare(root)
        val initial = snapshotWithImport(ArchiveSnapshot.empty(), "android", 10L, first)
        val second = prepare(root, source = "another-original", preview = "shared-preview", snapshot = initial)
        val current = second.saveToArchive(initial, "android", 11L) { }
        val before = objectFiles(root)
        val again = prepare(root, preview = "shared-preview", snapshot = current)
        assertTrue(again.createdFiles.isEmpty())
        again.saveToArchive(current, "android", 12L) { throw AssertionError("duplicate saved") }
        assertEquals(before, objectFiles(root))
        assertTrue(second.previewFile.isFile)
    }

    @Test
    fun aDuplicateKeepsTheMissingOriginalAndPreviewThatItRecreates() {
        val root = temp.newFolder()
        val first = prepare(root)
        val current = snapshotWithImport(ArchiveSnapshot.empty(), "android", 10L, first)
        first.createdFiles.forEach { assertTrue(it.delete()) }
        val again = prepare(root, snapshot = current)
        assertEquals(2, again.createdFiles.size)
        again.saveToArchive(current, "android", 11L) { throw AssertionError("duplicate saved") }
        assertTrue(again.createdFiles.all { it.isFile })
        assertEquals(2, objectFiles(root).size)
    }

    @Test
    fun aSuccessfulNewSaveKeepsBothNewObjects() {
        val root = temp.newFolder()
        val prepared = prepare(root)
        var saved: ArchiveSnapshot? = null
        val updated = prepared.saveToArchive(ArchiveSnapshot.empty(), "android", 10L) { saved = it }
        assertSame(updated, saved)
        assertTrue(prepared.createdFiles.all { it.isFile })
        assertEquals(2, objectFiles(root).size)
    }

    @Test
    fun aFailedSaveRemovesNewObjectsAndPreservesTheExistingSharedPreview() {
        val root = temp.newFolder()
        val first = prepare(root)
        val current = snapshotWithImport(ArchiveSnapshot.empty(), "android", 10L, first)
        val before = objectFiles(root)
        val prepared = prepare(root, source = "another-original", snapshot = current)
        val error = assertThrows(IOException::class.java) {
            prepared.saveToArchive(current, "android", 11L) { throw IOException("save failed") }
        }
        assertEquals("save failed", error.message)
        assertEquals(before, objectFiles(root))
        assertTrue(first.previewFile.isFile)
    }

    @Test
    fun differentOriginalsWithIdenticalPreviewsHaveDistinctResourcesAndOnePreviewObject() {
        val root = temp.newFolder()
        val first = prepare(root)
        // Preserve a resource from the original app version while importing with the new ID scheme.
        val legacy = first.copy(preview = first.preview.copy(id = "res-preview-${first.preview.sha256.take(12)}"))
        val initial = legacy.saveToArchive(ArchiveSnapshot.empty(), "android", 10L) { }
        val second = prepare(root, source = "another-original", snapshot = initial)
        assertEquals(first.preview.objectKey, second.preview.objectKey)
        assertFalse(first.assetId == second.assetId)
        assertFalse(legacy.preview.id == second.preview.id)
        val updated = second.saveToArchive(initial, "android", 11L) { ArchiveJson.parseSnapshot(ArchiveJson.canonical(it)) }
        assertEquals(2, updated.records.size)
        assertEquals(2, updated.assets.size)
        assertEquals(4, updated.resources.size)
        assertEquals(4, updated.resources.map { it.id }.toSet().size)
        assertEquals(3, objectFiles(root).size)
        assertTrue(updated.resources.contains(legacy.preview))
        assertEquals(1, updated.resources.filter { it.role == "preview" }.map { it.objectKey }.toSet().size)
        val again = prepare(root, source = "another-original", snapshot = updated)
        assertEquals(second.preview.id, again.preview.id)
        assertSame(updated, again.saveToArchive(updated, "android", 12L) { throw AssertionError("duplicate saved") })
        assertEquals(3, objectFiles(root).size)
        val third = prepare(root, source = "third-original", snapshot = updated)
        assertThrows(IOException::class.java) {
            third.saveToArchive(updated, "android", 13L) { throw IOException("save failed") }
        }
        assertEquals(3, objectFiles(root).size)
        assertArrayEquals(PREVIEW.toByteArray(), first.previewFile.readBytes())
        assertArrayEquals(SOURCE.toByteArray(), File(root, first.original.objectKey).readBytes())
        assertArrayEquals("another-original".toByteArray(), File(root, second.original.objectKey).readBytes())
    }

    @Test
    fun aFailedTrashReimportKeepsTheOriginalItRecreatedButDiscardsItsNewPreview() {
        val root = temp.newFolder()
        val first = prepare(root)
        val current = trashed(snapshotWithImport(ArchiveSnapshot.empty(), "android", 10L, first))
        val original = File(root, first.original.objectKey)
        assertTrue(original.delete())
        val again = prepare(root, preview = "different-preview", snapshot = current)
        assertThrows(IOException::class.java) {
            again.saveToArchive(current, "android", 11L) { throw IOException("save failed") }
        }
        assertArrayEquals(SOURCE.toByteArray(), original.readBytes())
        assertTrue(first.previewFile.isFile)
        assertFalse(again.previewFile.exists())
        assertEquals(2, objectFiles(root).size)
    }

    @Test
    fun aMissingCaptureInstantSavesAsUnknownWithAnEstimatedRecordTime() {
        val root = temp.newFolder()
        val prepared = importer(root, capture = { JsonObject(mapOf("timeUnknown" to JsonPrimitive(false))) })
            .import(request(SOURCE))
        val snapshot = prepared.saveToArchive(ArchiveSnapshot.empty(), "android", 10L) {
            ArchiveJson.parseSnapshot(ArchiveJson.canonical(it))
        }
        assertEquals(CaptureTime.unknown(), snapshot.assets.single().capturedAt.value)
        assertEquals(CaptureTime.occurredAt(CaptureTime.unknown(), 10L), snapshot.records.single().occurredAt.value)
        assertEquals(prepared.createdFiles.toSet(), objectFiles(root))
    }

    @Test
    fun captureAndLocationExceptionsPreserveMediaWithUnknownFacts() {
        listOf(true, false).forEach { failCapture ->
            val root = temp.newFolder()
            val importer = importer(root,
                capture = { if (failCapture) throw IOException("metadata failed") else CaptureTime.unknown() },
                location = { if (!failCapture) throw IOException("metadata failed") else false })
            val result = importer.import(request(SOURCE))
            assertEquals(CaptureTime.unknown(), result.capturedAt)
            assertFalse(result.locationInOriginal)
            assertEquals(2, objectFiles(root).size)
        }
    }

    @Test
    fun aMetadataExceptionPreservesAnOriginalRecreatedForTheCurrentSnapshot() {
        val root = temp.newFolder()
        val first = prepare(root)
        val current = snapshotWithImport(ArchiveSnapshot.empty(), "android", 10L, first)
        val original = File(root, first.original.objectKey)
        assertTrue(original.delete())
        val prepared = importer(root, preview = "different-preview", capture = { throw IOException("metadata failed") })
            .import(request(SOURCE), current)
        prepared.discardNewFiles(current)
        assertArrayEquals(SOURCE.toByteArray(), original.readBytes())
        assertTrue(first.previewFile.isFile)
        assertEquals(2, objectFiles(root).size)
    }

    @Test
    fun aPreviewPlacementFailureRemovesOnlyUnreferencedOriginalsAndTemps() {
        listOf(false, true).forEach { retainOriginal ->
            val root = temp.newFolder()
            val first = prepare(root)
            val current = snapshotWithImport(ArchiveSnapshot.empty(), "android", 10L, first)
            first.createdFiles.forEach { assertTrue(it.delete()) }
            assertTrue(File(root, first.preview.objectKey).mkdirs())
            assertThrows(IOException::class.java) {
                importer(root).import(request(SOURCE), if (retainOriginal) current else ArchiveSnapshot.empty())
            }
            assertEquals(retainOriginal, File(root, first.original.objectKey).isFile)
            assertTrue(root.walkTopDown().none { it.isFile && it.name.startsWith("tmp-") })
        }
    }

    @Test
    fun aPreviewEncoderFailureLeavesNoTempOrObjects() {
        val root = temp.newFolder()
        val importer = MediaImporter(root, PreviewEncoder { _, _ -> throw IOException("encode failed") },
            { _, _ -> false }, { _, _ -> CaptureTime.unknown() })
        assertThrows(IOException::class.java) { importer.import(request(SOURCE)) }
        assertTrue(objectFiles(root).isEmpty())
    }

    private fun prepare(root: File, source: String = SOURCE, preview: String = PREVIEW,
        snapshot: ArchiveSnapshot = ArchiveSnapshot.empty()): PreparedImport =
        importer(root, preview).import(request(source), snapshot)

    private fun importer(root: File, preview: String = PREVIEW,
        capture: () -> JsonObject = { CaptureTime.unknown() }, location: () -> Boolean = { false }): MediaImporter =
        MediaImporter(root, PreviewEncoder { _, _ -> preview.toByteArray() },
            { _, _ -> location() }, { _, _ -> capture() })

    private fun request(source: String) = ImportRequest("photo.jpg", "image/jpeg", true, false,
        { ByteArrayInputStream(source.toByteArray()) }, null)

    private fun trashed(snapshot: ArchiveSnapshot): ArchiveSnapshot {
        val record = snapshot.records.single()
        return snapshot.copy(records = listOf(record.copy(tombstone = FieldEnvelope(
            JsonObject(mapOf("deletedAt" to JsonPrimitive(10L), "purgeAfter" to JsonPrimitive(20L))),
            record.tombstone.edit))))
    }

    private fun objectFiles(root: File): Set<File> = root.walkTopDown().filter { it.isFile }.toSet()

    companion object {
        private const val SOURCE = "original-photo"
        private const val PREVIEW = "still-preview"
    }
}
