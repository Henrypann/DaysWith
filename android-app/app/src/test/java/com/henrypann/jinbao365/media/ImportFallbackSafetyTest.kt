package com.henrypann.jinbao365.media

import com.henrypann.jinbao365.archive.ImportProvenance
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.CancellationException

class ImportFallbackSafetyTest {
    @get:Rule val temp = TemporaryFolder()
    private fun importer(root: File, preview: PreviewEncoder = PreviewEncoder { _, _ -> "preview".toByteArray() }) =
        MediaImporter(root, preview, { _, _ -> false }, { _, _ -> CaptureTime.unknown() })
    private fun request(original: () -> InputStream, selected: () -> InputStream) =
        ImportRequest("photo.jpg", "image/jpeg", true, true, selected, original, origin = ImportOrigin.PhotoPicker)

    @Test fun partialOriginalSourceReadFailureRestartsFromSelectedUriAndHashesOnlySelectedBytes() {
        val root = temp.newFolder()
        var givenOpens = 0
        val prepared = importer(root).import(request({ object : InputStream() {
            var read = 0
            override fun read(): Int = if (read++ < 3) 'x'.code else throw IOException("provider disconnected")
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                if (read++ > 0) throw IOException("provider disconnected")
                buffer[offset] = 'x'.code.toByte()
                return 1
            }
        } }, { givenOpens++; ByteArrayInputStream("selected-bytes".toByteArray()) }))
        assertEquals(1, givenOpens)
        assertEquals(ImportProvenance.SystemProvided, prepared.provenance)
        assertEquals(ContentHash.sha256("selected-bytes".toByteArray()).hex, prepared.original.sha256)
        assertEquals("selected-bytes", File(root, prepared.original.objectKey).readText())
        assertTrue(root.walkTopDown().none { it.isFile && it.name.startsWith("tmp-") })
    }

    @Test fun availableOriginalIsOpenedOnceAndRetainsVerifiedProvenance() {
        var originalOpens = 0
        val prepared = importer(temp.newFolder()).import(request({ originalOpens++; ByteArrayInputStream("original".toByteArray()) },
            { error("must not open selected stream") }))
        assertEquals(1, originalOpens)
        assertEquals(ImportProvenance.VerifiedOriginal, prepared.provenance)
    }

    @Test fun cancellationNeverFallsBack() {
        var fallback = false
        assertThrows(CancellationException::class.java) {
            importer(temp.newFolder()).import(request({ throw CancellationException("cancelled") },
                { fallback = true; ByteArrayInputStream("selected".toByteArray()) }))
        }
        assertFalse(fallback)
    }

    @Test fun targetStorageFailureNeverFallsBack() {
        val root = temp.newFolder()
        var fallback = false
        try {
            assertThrows(IOException::class.java) {
                importer(root).import(request({
                    assertTrue(root.delete())
                    root.writeText("storage unavailable")
                    ByteArrayInputStream("original".toByteArray())
                }, { fallback = true; ByteArrayInputStream("selected".toByteArray()) }))
            }
            assertFalse(fallback)
        } finally { root.delete(); root.mkdirs() }
    }

    @Test fun emptyOrCorruptOriginalNeverFallsBackAndLeavesNoObjects() {
        val root = temp.newFolder()
        var fallback = false
        assertThrows(ImportRejected::class.java) {
            importer(root).import(request({ ByteArrayInputStream(byteArrayOf()) },
                { fallback = true; ByteArrayInputStream("selected".toByteArray()) }))
        }
        assertFalse(fallback)
        assertTrue(root.walkTopDown().none { it.isFile })
    }

    @Test fun destinationIntegrityFailureNeverFallsBack() {
        val root = temp.newFolder()
        var fallback = false
        assertThrows(ImportRejected::class.java) {
            importer(root, PreviewEncoder { file, _ -> file.writeText("corrupted while preparing"); "preview".toByteArray() })
                .import(request({ ByteArrayInputStream("original".toByteArray()) },
                    { fallback = true; ByteArrayInputStream("selected".toByteArray()) }))
        }
        assertFalse(fallback)
        assertTrue(root.walkTopDown().none { it.isFile })
    }
}
