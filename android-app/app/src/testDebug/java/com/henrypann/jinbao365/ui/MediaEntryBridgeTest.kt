package com.henrypann.jinbao365.ui

import android.content.Context
import android.content.Intent
import android.content.ActivityNotFoundException
import android.graphics.Bitmap
import android.net.Uri
import android.provider.MediaStore
import androidx.activity.ComponentActivity
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.core.app.ActivityOptionsCompat
import androidx.test.core.app.ApplicationProvider
import com.henrypann.jinbao365.JinbaoApplication
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.media.PendingMediaStatus
import com.henrypann.jinbao365.ui.theme.JinbaoTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.util.concurrent.Executors
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = JinbaoApplication::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class MediaEntryBridgeTest {
    @org.junit.Before fun resetProviderPathCache() {
        // Each Robolectric case gets a new filesDir; FileProvider retains a process-static cache.
        val cache = androidx.core.content.FileProvider::class.java.getDeclaredField("sCache").apply { isAccessible = true }
        (cache.get(null) as MutableMap<*, *>).clear()
    }
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private class Registry(private val context: Context, private val cameraUnavailable: Boolean = false) : ActivityResultRegistry(), ActivityResultRegistryOwner {
        override val activityResultRegistry: ActivityResultRegistry get() = this
        var code: Int? = null
        var launched: Intent? = null
        override fun <I, O> onLaunch(requestCode: Int, contract: ActivityResultContract<I, O>, input: I, options: ActivityOptionsCompat?) {
            code = requestCode
            launched = contract.createIntent(context, input)
            if (cameraUnavailable && launched?.action == MediaStore.ACTION_IMAGE_CAPTURE) {
                throw ActivityNotFoundException("No system camera is installed in this fixture")
            }
        }
    }

    @Test fun pickerLaunchesWithoutAnyRuntimePermissionGateAndCancellationIsSilent() {
        val registry = Registry(compose.activity)
        var picked = false
        var error: String? = null
        compose.setContent {
            CompositionLocalProvider(LocalActivityResultRegistryOwner provides registry) {
                val launch = rememberMomentPhotoPicker(true, { _, _ -> picked = true }, { error = it })
                JinbaoTheme { Button(onClick = launch) { Text("选择") } }
            }
        }
        compose.onNodeWithText("选择").performClick()
        compose.runOnIdle {
            assertNotNull(registry.launched)
            assertNotEquals("android.content.pm.action.REQUEST_PERMISSIONS", registry.launched!!.action)
            registry.dispatchResult(registry.code!!, emptyList<Uri>())
        }
        compose.runOnIdle { assertFalse(picked); assertNull(error) }
        compose.onNodeWithText("添加照片前还差一步").assertDoesNotExist()
    }

    @Test fun cameraUsesPrivateFullSizeOutputAndCancellationCreatesNoEmptyDraft() {
        cameraFlow(success = false, recreate = false)
    }
    @Test fun cameraResultSurvivesComposeRecreationAndOpensTheSameDraft() {
        cameraFlow(success = true, recreate = true)
    }

    @Test fun unavailableSystemCameraExplainsRecoveryAndCleansTheOwnedCapture() {
        val app = ApplicationProvider.getApplicationContext<JinbaoApplication>()
        app.parentIdentityStore.confirm(ParentIdentity.Dad)
        val io = Executors.newSingleThreadExecutor()
        try {
            val draftsBefore = io.submit<List<String>> { app.archive.loadDrafts().map { it.record.id } }.get()
            val recordsBefore = io.submit<List<String>> { app.archive.loadSnapshot().records.map { it.id } }.get()
            val registry = Registry(compose.activity, cameraUnavailable = true)
            val failure = mutableStateOf<String?>(null)
            var opened: String? = null
            var active = false
            compose.setContent {
                CompositionLocalProvider(LocalActivityResultRegistryOwner provides registry) {
                    val launch = rememberMomentCamera(app, true, onDraftReady = { opened = it },
                        onError = { failure.value = it }, onActiveChanged = { active = it })
                    JinbaoTheme { Column {
                        Button(onClick = launch) { Text("拍照") }
                        failure.value?.let { Text(it) }
                    } }
                }
            }
            compose.onNodeWithText("拍照").performClick()
            compose.waitUntil(10_000) { failure.value != null }
            compose.onNodeWithText("这台手机暂时无法打开相机，请从相册选择照片。").assertIsDisplayed()
            compose.runOnIdle { assertNull(opened); assertFalse(active) }
            assertEquals(MediaStore.ACTION_IMAGE_CAPTURE, registry.launched!!.action)
            val task = io.submit<List<com.henrypann.jinbao365.data.PendingMediaTaskEntity>> {
                app.archive.pendingMediaTasks()
            }.get().single()
            assertEquals(PendingMediaStatus.Cancelled.name, task.status)
            assertTrue(task.ownsDraft)
            assertNull(io.submit<com.henrypann.jinbao365.media.PendingCapture?> { app.pendingMedia.pendingCapture() }.get())
            assertEquals(draftsBefore, io.submit<List<String>> { app.archive.loadDrafts().map { it.record.id } }.get())
            assertEquals(recordsBefore, io.submit<List<String>> { app.archive.loadSnapshot().records.map { it.id } }.get())
            assertFalse("Unavailable camera must leave no private capture file", File(app.filesDir, "pending-media/${task.id}/capture.jpg").exists())
            assertFalse("Unavailable camera must clean its private task directory", File(app.filesDir, "pending-media/${task.id}").exists())
        } finally { io.shutdown() }
    }

    private fun cameraFlow(success: Boolean, recreate: Boolean) {
        val app = ApplicationProvider.getApplicationContext<JinbaoApplication>()
        app.parentIdentityStore.confirm(ParentIdentity.Dad)
        val io = Executors.newSingleThreadExecutor()
        val before = io.submit<List<String>> { app.archive.loadDrafts().map { it.record.id } }.get()
        val registry = Registry(compose.activity)
        var opened: String? = null
        var failure: String? = null
        val restoration = StateRestorationTester(compose)
        restoration.setContent {
            CompositionLocalProvider(LocalActivityResultRegistryOwner provides registry) {
                val launch = rememberMomentCamera(app, true, onDraftReady = { opened = it }, onError = { failure = it })
                JinbaoTheme { Button(onClick = launch) { Text("拍照") } }
            }
        }
        compose.onNodeWithText("拍照").performClick()
        compose.waitUntil(10_000) { registry.launched != null }
        val intent = registry.launched!!
        assertEquals(MediaStore.ACTION_IMAGE_CAPTURE, intent.action)
        @Suppress("DEPRECATION") val output = intent.getParcelableExtra<Uri>(MediaStore.EXTRA_OUTPUT)!!
        assertEquals("content", output.scheme)
        assertEquals("${app.packageName}.capture", output.authority)
        assertFalse("Capture must not insert a public gallery item", output.toString().contains("media/external"))
        val capture = io.submit<com.henrypann.jinbao365.media.PendingCapture?> { app.pendingMedia.pendingCapture() }.get()!!
        assertEquals(output, capture.outputUri)
        if (success) {
            app.contentResolver.openOutputStream(output)!!.use {
                val bitmap = Bitmap.createBitmap(16, 16, Bitmap.Config.ARGB_8888)
                assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it))
                bitmap.recycle()
            }
        }
        if (recreate) restoration.emulateSavedInstanceStateRestore()
        compose.runOnIdle { registry.dispatchResult(registry.code!!, success) }
        if (success) {
            compose.waitUntil(10_000) { opened != null }
            assertEquals(capture.draftId, opened)
            io.submit { app.importExecutor.submit {}.get() }.get()
            val tasks = io.submit<List<com.henrypann.jinbao365.media.PendingMediaTask>> {
                app.pendingMedia.tasksForDraft(capture.draftId)
            }.get()
            assertEquals(PendingMediaStatus.Ready, tasks.single().status)
            val draft = io.submit<com.henrypann.jinbao365.data.StoredDraft?> { app.archive.loadDraft(capture.draftId) }.get()!!
            assertEquals(1, draft.assets.size)
        } else {
            compose.waitUntil(10_000) {
                io.submit<Boolean> { app.pendingMedia.pendingCapture() == null }.get()
            }
            compose.runOnIdle { assertNull(opened); assertNull(failure) }
            assertEquals(before, io.submit<List<String>> { app.archive.loadDrafts().map { it.record.id } }.get())
        }
        io.shutdown()
    }
}
