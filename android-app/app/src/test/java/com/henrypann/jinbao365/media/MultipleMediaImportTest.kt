package com.henrypann.jinbao365.media

import com.henrypann.jinbao365.archive.ArchiveRecord
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.time.Instant
import java.util.concurrent.CancellationException

class MultipleMediaImportTest {
    @get:Rule val temp = TemporaryFolder()

    @Test
    fun selectionsOfOneAndThirtyKeepOrderAndOriginalMetadata() {
        listOf(1, 30).forEach { count ->
            val root = temp.newFolder()
            val progress = mutableListOf<Pair<Int, Int>>()
            val capture = CaptureTime.unknown()
            val importer = MediaImporter(root, PreviewEncoder { file, _ -> "preview-${file.readText()}".toByteArray() },
                { _, _ -> true }, { _, _ -> capture })
            val requests = (1..count).map { request("source-$it", if (it == count) "video/mp4" else "image/heic") }
            val prepared = importer.importMultiple(requests, onProgress = { done, total -> progress += done to total })
            val record = prepared.record("android", 100)
            assertEquals(prepared.imports.map { it.assetId }, assetIds(record))
            assertEquals(count, prepared.media("android", 100).size)
            assertEquals((0..count).map { it to count }, progress)
            prepared.imports.forEachIndexed { index, media ->
                assertEquals(capture, media.capturedAt)
                assertTrue(media.locationInOriginal)
                assertEquals(requests[index].mimeType, media.original.contentType)
                assertArrayEquals("source-${index + 1}".toByteArray(), File(root, media.original.objectKey).readBytes())
                assertEquals(ContentHash.sha256("source-${index + 1}".toByteArray()).hex, media.original.sha256)
            }
            assertEquals(count * 2, objects(root).size)
        }
    }

    @Test
    fun duplicatesRetainFirstSelectionPositionAndEncodeOnlyOnce() {
        val root = temp.newFolder()
        var encoded = 0
        val prepared = importer(root) { file ->
            encoded += 1
            "preview-${file.readText()}".toByteArray()
        }.importMultiple(listOf(request("third"), request("first"), request("third"), request("second")))
        assertEquals(3, encoded)
        assertEquals(listOf("third.jpg", "first.jpg", "third.jpg", "second.jpg"), prepared.imports.map { it.displayName })
        assertEquals(prepared.imports.filterIndexed { i, _ -> i != 2 }.map { it.assetId }, assetIds(prepared.record("android", 10)))
        assertEquals(3, prepared.media("android", 10).size)
        assertTrue(prepared.imports[2].createdFiles.isEmpty())
        assertEquals(6, objects(root).size)
    }

    @Test
    fun recordUsesEarliestPlausibleCaptureWithoutChangingSelectionOrderOrTitle() {
        val now = Instant.parse("2026-10-11T00:00:00Z").toEpochMilli()
        val earliest = Instant.parse("2026-10-01T00:00:00Z").toEpochMilli()
        val captures = mapOf(
            "later" to CaptureTime.zoneUnknown(earliest + 86_400_000L),
            "epoch" to CaptureTime.zoneUnknown(0),
            "normal" to CaptureTime.offsetKnown(earliest, "+08:00"),
        )
        val prepared = importer(temp.newFolder(), capture = { captures.getValue(it.readText()) })
            .importMultiple(captures.keys.map { request(it) })
        val record = prepared.record("android", now)
        val occurred = record.occurredAt.value.jsonObject
        assertEquals(earliest, occurred.getValue("utc").jsonPrimitive.long)
        assertEquals("+08:00", occurred.getValue("utcOffset").jsonPrimitive.content)
        assertFalse("estimated" in occurred)
        assertEquals("later.jpg", record.title!!.value.jsonPrimitive.content)
        assertEquals(prepared.imports.map { it.assetId }, assetIds(record))
        assertEquals(CaptureTime.unknown(), prepared.media("android", now)[1].asset.capturedAt.value)
    }

    @Test
    fun futureCaptureIsIgnoredWhenOtherCaptureIsUnknown() {
        val now = Instant.parse("2026-10-11T00:00:00Z").toEpochMilli()
        val prepared = importer(temp.newFolder(), capture = {
            if (it.readText() == "future") CaptureTime.zoneUnknown(now + 86_400_001L) else CaptureTime.unknown()
        }).importMultiple(listOf(request("future"), request("unknown")))
        val occurred = prepared.record("android", now).occurredAt.value.jsonObject
        assertEquals(now, occurred.getValue("utc").jsonPrimitive.long)
        assertTrue(occurred.getValue("estimated").jsonPrimitive.boolean)
        assertTrue(occurred.getValue("zoneUnknown").jsonPrimitive.boolean)
        assertTrue(prepared.media("android", now).all { it.asset.capturedAt.value == CaptureTime.unknown() })
    }

    @Test
    fun captureExactlyOneDayAfterImportRemainsKnownForTheRecordAndAsset() {
        val now = Instant.parse("2026-10-11T00:00:00Z").toEpochMilli()
        val capture = CaptureTime.offsetKnown(now + 86_400_000L, "+08:00")
        val prepared = importer(temp.newFolder(), capture = { capture })
            .importMultiple(listOf(request("tomorrow")))
        val occurred = prepared.record("android", now).occurredAt.value.jsonObject
        assertEquals(now + 86_400_000L, occurred.getValue("utc").jsonPrimitive.long)
        assertEquals("+08:00", occurred.getValue("utcOffset").jsonPrimitive.content)
        assertFalse("estimated" in occurred)
        assertEquals(capture, prepared.media("android", now).single().asset.capturedAt.value)
    }

    @Test
    fun allImplausibleCapturesKeepTheEstimatedImportTime() {
        val now = Instant.parse("2026-10-11T00:00:00Z").toEpochMilli()
        val prepared = importer(temp.newFolder(), capture = {
            CaptureTime.offsetKnown(if (it.readText() == "epoch") 0 else now + 86_400_001L, "+08:00")
        }).importMultiple(listOf(request("epoch"), request("future")))
        val occurred = prepared.record("android", now).occurredAt.value.jsonObject
        assertEquals(now, occurred.getValue("utc").jsonPrimitive.long)
        assertTrue(occurred.getValue("estimated").jsonPrimitive.boolean)
        assertTrue(occurred.getValue("zoneUnknown").jsonPrimitive.boolean)
        assertFalse("utcOffset" in occurred)
    }

    @Test
    fun invalidCountsRejectBeforeOpeningAnySource() {
        val root = temp.newFolder()
        val unopened = request("unopened").copy(openGiven = { throw AssertionError("opened invalid selection") })
        assertThrows(ImportRejected::class.java) { importer(root).importMultiple(emptyList()) }
        assertThrows(ImportRejected::class.java) { importer(root).importMultiple(List(31) { unopened }) }
        assertTrue(objects(root).isEmpty())
    }

    @Test
    fun laterStreamFailureRemovesTheWholeSelectionButKeepsRetainedSharedObjects() {
        val root = temp.newFolder()
        val importer = importer(root) { "shared-preview".toByteArray() }
        val existing = importer.import(request("existing"))
        val retained = setOf(existing.original.objectKey, existing.preview.objectKey)
        val before = objects(root)
        val broken = request("broken").copy(openGiven = {
            object : InputStream() {
                var readOnce = false
                override fun read(): Int = throw AssertionError("single byte read")
                override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                    if (readOnce) throw IOException("source lost mid-copy")
                    readOnce = true
                    "partial".toByteArray().copyInto(buffer, offset)
                    return 7
                }
            }
        })
        val failure = assertThrows(IOException::class.java) {
            importer.importMultiple(listOf(request("new"), request("existing"), broken), retainedObjectKeys = { retained })
        }
        assertEquals("source lost mid-copy", failure.message)
        assertEquals(before, objects(root))
    }

    @Test
    fun cancellationDuringStreamingOrAfterProgressRollsBackAllNewObjects() {
        listOf(true, false).forEach { duringRead ->
            val root = temp.newFolder()
            var cancelled = false
            val second = request("second").copy(openGiven = {
                object : ByteArrayInputStream("second".toByteArray()) {
                    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                        val count = super.read(buffer, offset, length)
                        if (duringRead) cancelled = true
                        return count
                    }
                }
            })
            assertThrows(CancellationException::class.java) {
                importer(root).importMultiple(listOf(request("first"), second),
                    onProgress = { done, _ -> if (!duringRead && done == 2) cancelled = true },
                    isCancelled = { cancelled })
            }
            assertTrue(objects(root).isEmpty())
        }
    }

    @Test
    fun failedProtectionReadPreservesFilesAndOriginalFailure() {
        val root = temp.newFolder()
        val broken = request("broken").copy(openGiven = { throw IOException("source unavailable") })
        val error = assertThrows(IOException::class.java) {
            importer(root).importMultiple(listOf(request("first"), broken),
                retainedObjectKeys = { throw IOException("database unavailable") })
        }
        assertEquals("source unavailable", error.message)
        assertEquals("database unavailable", error.suppressed.single().message)
        assertEquals(2, objects(root).size)
        assertFalse(objects(root).any { it.contains("tmp-") })
    }

    @Test
    fun objectDirectorySymlinksAreRejectedAndTempCleanupDoesNotFollowThem() {
        val root = temp.newFolder()
        val outside = temp.newFolder()
        val sentinel = File(outside, "tmp-user-data").apply { writeText("keep") }
        Files.createSymbolicLink(File(root, "objects").toPath(), outside.toPath())
        assertThrows(ImportRejected::class.java) { importer(root).importMultiple(listOf(request("first"))) }
        assertEquals("keep", sentinel.readText())
        assertEquals(listOf(sentinel), outside.listFiles()!!.toList())
        assertFalse(root.listFiles()!!.any { it.name.startsWith("tmp-") })
    }

    @Test
    fun theSameOriginalWithConflictingKindsRejectsTheWholeSelection() {
        val root = temp.newFolder()
        val importer = importer(root)
        assertThrows(ImportRejected::class.java) {
            importer.importMultiple(listOf(request("same", "image/jpeg"), request("same", "video/mp4")))
        }
        assertTrue(objects(root).isEmpty())
    }

    @Test
    fun releasedObjectCleanupRejectsHashPathMismatchAndSymlinkTargets() {
        val root = temp.newFolder()
        val importer = importer(root)
        val prepared = importer.import(request("first"))
        val outside = temp.newFolder()
        val sentinel = File(outside, "user-data").apply { writeText("keep") }
        val forged = prepared.original.copy(objectKey = "../${outside.name}/user-data")
        importer.discardUnreferencedObjects(listOf(forged), emptySet())
        assertEquals("keep", sentinel.readText())
        val original = File(root, prepared.original.objectKey)
        original.writeText("foreign bytes at the candidate path")
        importer.discardUnreferencedObjects(listOf(prepared.original), emptySet())
        assertEquals("foreign bytes at the candidate path", original.readText())
        assertTrue(original.delete())
        Files.createSymbolicLink(original.toPath(), sentinel.toPath())
        importer.discardUnreferencedObjects(listOf(prepared.original), emptySet())
        assertEquals("keep", sentinel.readText())
        assertTrue(Files.isSymbolicLink(original.toPath()))
    }

    private fun importer(root: File, capture: (File) -> JsonObject = { CaptureTime.unknown() },
        preview: (File) -> ByteArray = { "preview-${it.readText()}".toByteArray() }) =
        MediaImporter(root, PreviewEncoder { file, _ -> preview(file) }, { _, _ -> false }, { file, _ -> capture(file) })

    private fun request(original: String, mimeType: String = "image/jpeg") = ImportRequest(
        "$original.jpg", mimeType, true, false, { ByteArrayInputStream(original.toByteArray()) }, null,
    )

    private fun assetIds(record: ArchiveRecord) = (record.assetIds.value as JsonArray).map { it.jsonPrimitive.content }
    private fun objects(root: File) = root.walkTopDown().filter { it.isFile }.map { it.relativeTo(root).path }.toSet()
}
