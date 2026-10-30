package com.henrypann.jinbao365.media

import android.content.Context
import android.os.Looper
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.henrypann.jinbao365.archive.ArchiveJson
import com.henrypann.jinbao365.data.ArchiveDatabase
import com.henrypann.jinbao365.data.ArchiveRepository
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode
import java.io.ByteArrayInputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 35])
@LooperMode(LooperMode.Mode.PAUSED)
class ImportControllerTest {
    @get:Rule val temp = TemporaryFolder()

    @Test
    fun completedImportIsPublishedOnMainAndIsLoadedAfterDatabaseReopenWithoutDuplicating() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val databaseName = "import-restart-${UUID.randomUUID()}.db"
        val root = temp.newFolder()
        val executor = Executors.newSingleThreadExecutor()
        var database = database(context, databaseName)
        try {
            var repository = ArchiveRepository(database)
            val controller = ImportController(repository, "android", importer(root), executor)
            settle(executor)
            assertFalse(controller.state.busy)
            assertEquals(0, controller.state.recordCount)
            assertTrue(controller.submit {
                assertNotEquals(Looper.getMainLooper(), Looper.myLooper())
                request()
            })
            assertTrue(controller.state.busy)
            assertFalse(controller.submit { throw AssertionError("a second in-flight import was accepted") })
            executor.submit {}.get(10, TimeUnit.SECONDS)
            // Worker has finished; UI waits for the main-thread callback.
            assertTrue(controller.state.busy)
            shadowOf(Looper.getMainLooper()).idle()
            assertFalse(controller.state.busy)
            assertTrue(controller.state.status.startsWith("已保存。"))
            assertEquals(1, controller.state.recordCount)
            assertEquals(1, controller.state.assetCount)
            assertEquals(2, controller.state.resourceCount)
            val original = executor.submit<String> { ArchiveJson.canonical(repository.loadSnapshot()) }
                .get(10, TimeUnit.SECONDS)
            database.close()
            database = database(context, databaseName)
            repository = ArchiveRepository(database)
            val recreated = ImportController(repository, "android", importer(root), executor)
            settle(executor)
            assertEquals(1, recreated.state.recordCount)
            assertEquals(1, recreated.state.assetCount)
            assertEquals(2, recreated.state.resourceCount)
            assertTrue(recreated.submit(::request))
            settle(executor)
            assertTrue(recreated.state.status.startsWith("这张照片已经保存过了。"))
            assertEquals(1, recreated.state.recordCount)
            assertEquals(original, executor.submit<String> { ArchiveJson.canonical(repository.loadSnapshot()) }
                .get(10, TimeUnit.SECONDS))
            assertEquals(2, root.walkTopDown().count { it.isFile })
            executor.submit {
                repository.loadSnapshot().resources.forEach { resource ->
                    val file = File(root, resource.objectKey)
                    assertEquals(resource.sha256, file.inputStream().use { ContentHash.sha256(it).hex })
                    assertEquals(resource.byteCount, file.length())
                }
            }.get(10, TimeUnit.SECONDS)
        } finally {
            executor.shutdownNow()
            database.close()
            context.deleteDatabase(databaseName)
        }
    }

    @Test
    fun aRejectedImportLeavesPersistedCountsAndAllowsRetry() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val database = Room.inMemoryDatabaseBuilder(context, ArchiveDatabase::class.java).build()
        val executor = Executors.newSingleThreadExecutor()
        val root = temp.newFolder()
        try {
            val repository = ArchiveRepository(database)
            val controller = ImportController(repository, "android", importer(root), executor)
            settle(executor)
            controller.submit { request().copy(openGiven = { throw ImportRejected("照片文件不可读取。") }, openOriginal = null) }
            settle(executor)
            assertEquals("照片文件不可读取。", controller.state.status)
            assertFalse(controller.state.busy)
            assertEquals(0, controller.state.recordCount)
            assertEquals(0, root.walkTopDown().count { it.isFile })
            assertTrue(controller.submit(::request))
            settle(executor)
            assertEquals(1, controller.state.recordCount)
        } finally {
            executor.shutdownNow()
            database.close()
        }
    }

    @Test
    fun aNewOriginalWithAnIdenticalPreviewSavesBesideTheLegacyResourceInRoom() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val database = Room.inMemoryDatabaseBuilder(context, ArchiveDatabase::class.java).build()
        val executor = Executors.newSingleThreadExecutor()
        val root = temp.newFolder()
        try {
            val repository = ArchiveRepository(database)
            val mediaImporter = importer(root)
            val legacy = executor.submit<PreparedImport> {
                val first = mediaImporter.import(request())
                val old = first.copy(preview = first.preview.copy(id = "res-preview-${first.preview.sha256.take(12)}"))
                old.saveToArchive(com.henrypann.jinbao365.archive.ArchiveSnapshot.empty(), "android", 10L, repository::saveSnapshot)
                old
            }.get(10, TimeUnit.SECONDS)
            val controller = ImportController(repository, "android", mediaImporter, executor)
            settle(executor)
            assertTrue(controller.submit {
                request().copy(openGiven = { ByteArrayInputStream("different-original-photo".toByteArray()) })
            })
            settle(executor)
            assertTrue(controller.state.status.startsWith("已保存。"))
            assertEquals(2, controller.state.recordCount)
            assertEquals(2, controller.state.assetCount)
            assertEquals(4, controller.state.resourceCount)
            executor.submit {
                val saved = repository.loadSnapshot()
                assertEquals(4, saved.resources.map { it.id }.toSet().size)
                assertTrue(saved.resources.contains(legacy.preview))
                val previews = saved.resources.filter { it.role == "preview" }
                assertEquals(2, previews.map { it.assetID }.toSet().size)
                assertEquals(1, previews.map { it.objectKey }.toSet().size)
            }.get(10, TimeUnit.SECONDS)
            assertEquals(3, root.walkTopDown().count { it.isFile })
        } finally {
            executor.shutdownNow()
            database.close()
        }
    }

    private fun database(context: Context, name: String) =
        Room.databaseBuilder(context, ArchiveDatabase::class.java, name).build()

    private fun settle(executor: ExecutorService) {
        executor.submit {}.get(10, TimeUnit.SECONDS)
        shadowOf(Looper.getMainLooper()).idle()
    }

    private fun request() = ImportRequest("photo.jpg", "image/jpeg", true, false,
        { ByteArrayInputStream("original-photo".toByteArray()) }, null)

    private fun importer(root: File) = MediaImporter(root, PreviewEncoder { _, _ -> "preview".toByteArray() },
        { _, _ -> true }, { _, _ -> CaptureTime.unknown() })
}
