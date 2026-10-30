package com.henrypann.jinbao365.gallery

import android.content.ContentProvider
import android.content.ContentResolver
import android.content.Context
import android.content.ContentValues
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver

/** Synthetic JVM metadata benchmark; it neither decodes photos nor measures device frame pacing. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class GalleryLargeLibraryTest {
    @Test fun tenThousandMetadataRowsHaveBoundedPagesAndNoMissingOrDuplicateItems() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val provider = LargeLibrary(10_000)
        provider.attachInfo(context, ProviderInfo().apply { authority = "media" })
        ShadowContentResolver.registerProviderInternal("media", provider)
        val repository = GalleryRepository(context)
        val permission = GalleryPermissionState(images = true, videos = true, selectedOnly = false, mediaLocation = true)
        val beforeHeap = heapBytes()
        val begin = System.nanoTime()
        var key: GalleryPageKey? = GalleryPageKey()
        val seen = HashSet<String>(10_000)
        var previousTime = Long.MAX_VALUE
        var firstPageMillis = 0.0
        var pageCount = 0
        var maxRowsPerPage = 0
        var capturedCount = 0
        var addedCount = 0
        while (key != null) {
            assertTrue("Pagination must terminate after the bounded library", pageCount < 100)
            val queriedBefore = provider.returnedRows
            val queriesBefore = provider.queryCount
            val page = repository.page(key, permission)
            if (pageCount == 0) {
                firstPageMillis = (System.nanoTime() - begin) / 1_000_000.0
                assertEquals("First screen should have a full page", 120, page.items.size)
            }
            assertEquals("Each page queries exactly the two independent time streams", 2, provider.queryCount - queriesBefore)
            val rowsThisPage = provider.returnedRows - queriedBefore
            maxRowsPerPage = maxOf(maxRowsPerPage, rowsThisPage)
            assertTrue("Each query is bounded to 120 and each page to 240 candidate rows", rowsThisPage <= 240)
            assertEquals(rowsThisPage, page.queriedRows)
            assertTrue(page.items.size <= 120)
            page.items.forEach { item ->
                assertTrue("URI must occur once: ${item.uri}", seen.add(item.uri.toString()))
                assertTrue("Capture/add streams must stay in global chronological order", item.sortTimeMillis <= previousTime)
                previousTime = item.sortTimeMillis
                if (item.capturedAtMillis == null) addedCount++ else capturedCount++
                val id = item.uri.lastPathSegment!!.toLong()
                assertEquals("Metadata sort must not invent a capture time", id % 2L == 0L, item.capturedAtMillis == null)
                assertEquals(LargeLibrary.BASE - id * 1000, item.sortTimeMillis)
            }
            key = page.next
            pageCount++
        }
        val totalMillis = (System.nanoTime() - begin) / 1_000_000.0
        val heapDelta = heapBytes() - beforeHeap
        assertEquals(10_000, seen.size)
        assertEquals(5_000, capturedCount)
        assertEquals(5_000, addedCount)
        assertEquals((1L..10_000L).map { id ->
            val collection = if (id % 5L == 0L) "video" else "images"
            "content://media/external/$collection/media/$id"
        }.toSet(), seen)
        assertEquals(120, provider.maxRequestedRows)
        println("GalleryLargeLibrary synthetic JVM metadata only: rows=10000 captureRows=$capturedCount addedRows=$addedCount " +
            "pages=$pageCount firstPageMs=$firstPageMillis totalPagingMs=$totalMillis heapDeltaBytes=$heapDelta " +
            "maxCandidateRowsPerPage=$maxRowsPerPage; no device photos, thumbnail decoding or frame-rate claim")
    }

    private fun heapBytes(): Long = Runtime.getRuntime().let { it.totalMemory() - it.freeMemory() }

    private class LargeLibrary(size: Int) : ContentProvider() {
        companion object { const val BASE = 1_790_000_000_000L }
        // Store only an index fixture. Original/thumbnail bytes do not exist in this benchmark.
        private val captured = (1L..size.toLong()).filter { it % 2L != 0L }
        private val added = (1L..size.toLong()).filter { it % 2L == 0L }
        var returnedRows = 0
        var queryCount = 0
        var maxRequestedRows = 0
        override fun onCreate() = true
        override fun query(uri: Uri, projection: Array<out String>?, queryArgs: Bundle?, cancellationSignal: CancellationSignal?): Cursor {
            val args = requireNotNull(queryArgs)
            val selection = requireNotNull(args.getString(ContentResolver.QUERY_ARG_SQL_SELECTION))
            val known = "IS NULL" !in selection
            val limit = args.getInt(ContentResolver.QUERY_ARG_LIMIT)
            val offset = args.getInt(ContentResolver.QUERY_ARG_OFFSET)
            assertTrue(limit in 1..120)
            assertTrue(offset >= 0)
            maxRequestedRows = maxOf(maxRequestedRows, limit)
            queryCount++
            val source = if (known) captured else added
            return MatrixCursor(requireNotNull(projection), limit).apply {
                val end = minOf(offset + limit, source.size)
                for (index in offset until end) {
                    cancellationSignal?.throwIfCanceled()
                    val id = source[index]
                    val video = id % 5L == 0L
                    addRow(arrayOf<Any?>(id, if (video) 3 else 1, "$id.${if (video) "mp4" else "jpg"}",
                        if (known) BASE - id * 1000 else null, (BASE - id * 1000) / 1000, if (video) 5_000L else 0L))
                    returnedRows++
                }
            }
        }
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = error("Bundle query required")
        override fun getType(uri: Uri): String? = null
        override fun insert(uri: Uri, values: ContentValues?): Uri? = error("Read only")
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = error("Read only")
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = error("Read only")
    }
}
