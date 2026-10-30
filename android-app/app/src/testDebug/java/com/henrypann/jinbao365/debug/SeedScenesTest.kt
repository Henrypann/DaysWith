package com.henrypann.jinbao365.debug

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import com.henrypann.jinbao365.archive.jsonStringList
import com.henrypann.jinbao365.data.ArchiveDatabase
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.data.ParentIdentityStore
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SeedScenesTest {
    private val context = ApplicationProvider.getApplicationContext<Application>()

    @After fun cleanup() {
        context.deleteDatabase(SeedScenes.DATABASE_NAME)
        File(context.filesDir, "debug-seed").deleteRecursively()
    }

    @Test fun timelinePersistsBothParentsWithPhotosAndNotesAndVerifiedLocalOriginals() = runBlocking {
        val snapshot = SeedScenes.seed(context, 1_792_130_400_000L)
        assertEquals(6, snapshot.records.size)
        for (parent in ParentIdentity.entries) {
            val records = snapshot.records.filter { SeedScenes.parentOf(snapshot, it.id) == parent }
            assertEquals(3, records.size)
            assertTrue(records.any { jsonStringList(it.assetIds.value).isEmpty() })
            assertTrue(records.any { jsonStringList(it.assetIds.value).isNotEmpty() })
        }
        assertEquals(3, snapshot.assets.size)
        for (resource in snapshot.resources) {
            val original = File(SeedScenes.mediaRoot(context), resource.objectKey)
            assertTrue(original.isFile)
            assertTrue(original.length() > 0)
            assertEquals(resource.byteCount, original.length())
            assertEquals(resource.sha256, SeedScenes.sha256(original))
        }
        assertTrue(context.getDatabasePath(SeedScenes.DATABASE_NAME).isFile)
        assertFalse(context.getDatabasePath(ArchiveDatabase.NAME).exists())
    }

    @Test fun repeatedSeedingIsIdempotentAndLeavesTheRealPhoneIdentityAndFilesUntouched() = runBlocking {
        ParentIdentityStore(context).confirm(ParentIdentity.Mom)
        val sentinel = File(context.filesDir, "media/keep-original").apply {
            parentFile!!.mkdirs()
            writeText("原来的照片")
        }
        val first = SeedScenes.seed(context, 1_792_130_400_000L)
        val second = SeedScenes.seed(context, 1_792_130_400_000L)
        assertEquals(first, second)
        assertEquals(ParentIdentity.Mom, ParentIdentityStore(context).parent)
        assertEquals("原来的照片", sentinel.readText())
        assertEquals(3, SeedScenes.mediaRoot(context).walkTopDown().count { it.isFile })
    }

    @Test fun adbSceneEntryRequiresTheShellPermission() {
        val manifest = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
            .newDocumentBuilder().parse(File(appDirectory(), "src/debug/AndroidManifest.xml"))
        val activity = manifest.getElementsByTagName("activity").item(0) as org.w3c.dom.Element
        val android = "http://schemas.android.com/apk/res/android"
        assertEquals(".debug.SeedActivity", activity.getAttributeNS(android, "name"))
        assertEquals("true", activity.getAttributeNS(android, "exported"))
        assertEquals("android.permission.DUMP", activity.getAttributeNS(android, "permission"))
    }

    @Test fun releaseSourcesCannotExposeOrIncludeSeeding() {
        for (sourceSet in listOf("main", "release")) {
            val directory = File(appDirectory(), "src/$sourceSet")
            val source = directory.walkTopDown().filter { it.isFile && it.extension in listOf("kt", "xml") }
                .joinToString("\n") { it.readText() }
            assertFalse(source.contains("SeedActivity"))
            assertFalse(source.contains("SeedScenes"))
        }
    }

    private fun appDirectory(): File {
        var current = File(checkNotNull(System.getProperty("user.dir")))
        while (true) {
            for (candidate in listOf(current, File(current, "app"), File(current, "android-app/app"))) {
                if (File(candidate, "src/debug/AndroidManifest.xml").isFile) return candidate
            }
            current = current.parentFile ?: error("Android app source directory was not found")
        }
    }
}
