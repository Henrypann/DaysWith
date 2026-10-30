package com.henrypann.jinbao365.gallery

import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.provider.MediaStore
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class GalleryRepositoryTest {
    private lateinit var provider: TestLibrary
    private lateinit var repository: GalleryRepository
    @Before fun setup() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        provider = TestLibrary()
        provider.attachInfo(context, ProviderInfo().apply { authority = "media" })
        ShadowContentResolver.registerProviderInternal("media", provider)
        repository = GalleryRepository(context)
    }

    @Test fun deniedAccessNeverQueriesTheLibrary() = runBlocking {
        val page = repository.page(GalleryPageKey(), GalleryPermissionState(false, false, false, false))
        assertTrue(page.items.isEmpty())
        assertNull(page.next)
        assertEquals(0, provider.calls)
    }

    @Test fun pagedQueryMergesActualCollectionUrisAndLimitsReads() = runBlocking {
        val page = repository.page(GalleryPageKey(), GalleryPermissionState(true, true, false, true), limit = 2)
        assertEquals(listOf("4", "1"), page.items.map { it.uri.lastPathSegment })
        assertEquals("content://media/external/video/media/4", page.items[0].uri.toString())
        assertEquals("content://media/external/images/media/1", page.items[1].uri.toString())
        assertNull(page.items[0].capturedAtMillis)
        assertEquals(GalleryPageKey(1, 1), page.next)
        val rest = repository.page(page.next!!, GalleryPermissionState(true, true, false, true), limit = 2)
        assertEquals(listOf("2", "3"), rest.items.map { it.uri.lastPathSegment })
        assertTrue(provider.limits.all { it == 2 })
    }

    @Test fun singleTypeGrantDoesNotRequestUnapprovedVideoRows() = runBlocking {
        val result = repository.page(GalleryPageKey(), GalleryPermissionState(true, false, false, false))
        assertTrue(result.items.all { !it.video })
        assertTrue(provider.selections.all { "IN (1)" in it })
    }

    @Test fun partialAccessAcceptsOnlyProviderVisibleRows() = runBlocking {
        provider.visibleIds = setOf(2L)
        val page = repository.page(GalleryPageKey(), GalleryPermissionState(false, false, true, false))
        assertEquals(listOf("2"), page.items.map { it.uri.lastPathSegment })
        assertNull(page.next)
        assertTrue(provider.selections.all { "IN (1,3)" in it })
    }

    private class TestLibrary : ContentProvider() {
        var calls = 0
        var visibleIds = setOf(1L, 2L, 3L, 4L)
        val limits = mutableListOf<Int>()
        val selections = mutableListOf<String>()
        val data = listOf(
            arrayOf<Any?>(1L, 1, "photo.jpg", 900L, 1L, 0L),
            arrayOf<Any?>(2L, 1, "photo2.jpg", 500L, 1L, 0L),
            arrayOf<Any?>(3L, 1, "unknown.jpg", null, 0L, 0L),
            arrayOf<Any?>(4L, 3, "video.mp4", null, 2L, 5000L),
        )
        override fun onCreate() = true
        override fun query(uri: Uri, projection: Array<out String>?, queryArgs: Bundle?, cancellationSignal: CancellationSignal?): Cursor {
            calls++
            val selection = queryArgs!!.getString(ContentResolver.QUERY_ARG_SQL_SELECTION)!!
            selections += selection
            val limit = queryArgs.getInt(ContentResolver.QUERY_ARG_LIMIT)
            limits += limit
            val offset = queryArgs.getInt(ContentResolver.QUERY_ARG_OFFSET)
            val known = "IS NULL" !in selection
            val imageOnly = "IN (1)" in selection
            val filtered = data.filter { row -> row[0] in visibleIds && (row[3] != null) == known && (!imageOnly || row[1] == 1) }
                .sortedByDescending { if (known) (it[3] as Long) else (it[4] as Long) }
            return MatrixCursor(projection!!).apply { filtered.drop(offset).take(limit).forEach(::addRow) }
        }
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = error("Bundle query required")
        override fun getType(uri: Uri) = "image/jpeg"
        override fun insert(uri: Uri, values: ContentValues?): Uri? = error("Read only")
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = error("Read only")
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = error("Read only")
    }
}
