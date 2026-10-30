package com.henrypann.jinbao365.ui

import android.Manifest
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.provider.MediaStore
import androidx.activity.ComponentActivity
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.core.app.ActivityOptionsCompat
import androidx.test.core.app.ApplicationProvider
import com.henrypann.jinbao365.JinbaoApplication
import com.henrypann.jinbao365.media.ImportOrigin
import com.henrypann.jinbao365.media.MediaSelection
import com.henrypann.jinbao365.ui.theme.JinbaoTheme
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowContentResolver
import java.util.concurrent.atomic.AtomicInteger

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "zh-rCN-w320dp-h800dp-xhdpi", application = JinbaoApplication::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class GalleryScreenTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private lateinit var provider: FailingLibrary
    private val a = Uri.parse("content://gallery-fixture/media/1")
    private val b = Uri.parse("content://gallery-fixture/media/2")
    private val c = Uri.parse("content://gallery-fixture/media/3")

    @Before fun permissionsAndFailureFixture() {
        val app = ApplicationProvider.getApplicationContext<JinbaoApplication>()
        shadowOf(app).grantPermissions(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO,
            Manifest.permission.ACCESS_MEDIA_LOCATION)
        provider = FailingLibrary()
        provider.attachInfo(app, ProviderInfo().apply { authority = "media" })
        ShadowContentResolver.registerProviderInternal("media", provider)
    }

    @Test fun fallbackEntrypointsAccumulateMixedSourcesAndCancellationRenumbers() {
        val registry = Registry(compose.activity)
        var completed: List<MediaSelection>? = null
        compose.setContent {
            CompositionLocalProvider(LocalActivityResultRegistryOwner provides registry) {
                JinbaoTheme { InAppGalleryScreen(30, { completed = it }, {}) }
            }
        }
        compose.onNodeWithTag("galleryComplete").assertIsNotEnabled()
        pick(registry, "系统选图器", MediaStore.ACTION_PICK_IMAGES, listOf(a, b))
        compose.onNodeWithText("完成（2）").assertIsEnabled()
        compose.runOnIdle { assertNull("A picker callback must not complete the gallery", completed) }
        pick(registry, "从文件里选", Intent.ACTION_OPEN_DOCUMENT, listOf(b, c))
        compose.onNodeWithText("完成（3）").assertIsEnabled()
        compose.waitUntil(10_000) { compose.onAllNodesWithTag("gallerySelect-3").fetchSemanticsNodes().size == 1 }
        compose.onNodeWithTag("gallerySelect-2").performClick()
        compose.onNodeWithText("完成（2）").assertIsEnabled()
        compose.onNodeWithTag("gallerySelect-3").assertDoesNotExist()
        compose.onNodeWithTag("gallerySelect-2").assertExists()
        // The library and every fixture URI are unreadable; the draft importer owns per-item failures.
        compose.waitUntil(10_000) { provider.calls.get() > 0 }
        compose.onNodeWithTag("galleryComplete").performClick()
        compose.runOnIdle {
            assertEquals(listOf(a, c), completed!!.map { it.uri })
            assertEquals(listOf(ImportOrigin.PhotoPicker, ImportOrigin.Document), completed!!.map { it.origin })
        }
    }

    @Test fun restoredUnreadableSelectionsAreRetainedForDraftRetry() {
        val registry = Registry(compose.activity)
        var completed: List<MediaSelection>? = null
        val restoration = StateRestorationTester(compose)
        restoration.setContent {
            CompositionLocalProvider(LocalActivityResultRegistryOwner provides registry) {
                JinbaoTheme { InAppGalleryScreen(30, { completed = it }, {}) }
            }
        }
        pick(registry, "系统选图器", MediaStore.ACTION_PICK_IMAGES, listOf(a, b))
        restoration.emulateSavedInstanceStateRestore()
        compose.onNodeWithText("完成（2）").assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals(listOf(a, b), completed!!.map { it.uri }) }
    }

    @Test fun completionAt150PercentFontsRemainsReachable() = fontCompletion(1.5f)
    @Test fun completionAt200PercentFontsRemainsReachable() = fontCompletion(2f)

    private fun fontCompletion(fontScale: Float) {
        val registry = Registry(compose.activity)
        var completed: List<MediaSelection>? = null
        compose.setContent {
            CompositionLocalProvider(LocalActivityResultRegistryOwner provides registry,
                LocalDensity provides Density(LocalDensity.current.density, fontScale)) {
                JinbaoTheme { InAppGalleryScreen(30, { completed = it }, {}) }
            }
        }
        compose.onNodeWithTag("galleryComplete").assertIsDisplayed().assertIsNotEnabled()
        pick(registry, "从文件里选", Intent.ACTION_OPEN_DOCUMENT, listOf(a))
        compose.onNodeWithTag("galleryComplete").assertIsDisplayed().assertHeightIsAtLeast(48.dp).assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals(listOf(MediaSelection(a, ImportOrigin.Document)), completed) }
    }

    private fun pick(registry: Registry, label: String, expectedAction: String, result: List<Uri>) {
        compose.onNodeWithTag("galleryMore").performClick()
        compose.onNodeWithText(label).performClick()
        compose.runOnIdle {
            assertEquals(expectedAction, registry.launched!!.action)
            registry.dispatchResult(registry.code!!, result)
        }
    }

    private class Registry(private val context: Context) : ActivityResultRegistry(), ActivityResultRegistryOwner {
        override val activityResultRegistry: ActivityResultRegistry get() = this
        var launched: Intent? = null
        var code: Int? = null
        override fun <I, O> onLaunch(requestCode: Int, contract: ActivityResultContract<I, O>, input: I, options: ActivityOptionsCompat?) {
            launched = contract.createIntent(context, input)
            code = requestCode
        }
    }

    private class FailingLibrary : ContentProvider() {
        val calls = AtomicInteger()
        override fun onCreate() = true
        override fun query(uri: Uri, projection: Array<out String>?, queryArgs: Bundle?, cancellationSignal: CancellationSignal?): Cursor? {
            calls.incrementAndGet()
            throw SecurityException("Library grant was withdrawn in this fixture")
        }
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? =
            throw SecurityException("Library grant was withdrawn in this fixture")
        override fun getType(uri: Uri) = "image/jpeg"
        override fun insert(uri: Uri, values: ContentValues?): Uri? = error("Read only")
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = error("Read only")
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = error("Read only")
    }
}
