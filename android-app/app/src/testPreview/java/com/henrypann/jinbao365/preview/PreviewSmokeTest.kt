package com.henrypann.jinbao365.preview

import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Looper
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import com.henrypann.jinbao365.JinbaoApplication
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.ui.reviewMonths
import com.henrypann.jinbao365.storage.SavedConnection
import com.henrypann.jinbao365.storage.StorageConnectionStore
import org.junit.Assert.*
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "zh-rCN-w411dp-h891dp-xhdpi", application = JinbaoApplication::class)
@GraphicsMode(GraphicsMode.Mode.LEGACY)
class PreviewSmokeTest {
    // Native Graphics crashes inside Robolectric's JNI startup for this asynchronously seeded Activity.
    // Keep functional/manifest/restoration coverage here; visual evidence comes from Native AppShell tests.
    @get:Rule val compose = createAndroidComposeRule<PreviewActivity>()
    private val app get() = compose.activity.application as JinbaoApplication
    @After fun close() { app.onTerminate() }

    @Test fun freshInstallIsIsolatedAndLocalShellSurvivesRecreation() {
        compose.onNodeWithTag("parentIdentity").assertIsDisplayed()
        assertNull(app.parentIdentity)
        compose.onNodeWithTag("chooseDad").performClick()
        compose.onNodeWithTag("parentConfirmation").assertIsDisplayed()
        assertNull("Choosing a parent must wait for explicit confirmation", app.parentIdentity)
        compose.onNodeWithTag("confirmParent").performClick()
        awaitReady()
        assertEquals(ParentIdentity.Dad, app.parentIdentity)
        val info = app.packageManager.getPackageInfo(app.packageName, PackageManager.GET_PERMISSIONS or PackageManager.GET_PROVIDERS)
        assertEquals("com.henrypann.jinbao365.preview", app.packageName)
        assertEquals("DaysWith·测试", app.applicationInfo.loadLabel(app.packageManager).toString())
        assertFalse(info.requestedPermissions.orEmpty().contains("android.permission.INTERNET"))
        assertEquals(0, app.applicationInfo.flags and ApplicationInfo.FLAG_ALLOW_BACKUP)
        info.providers.orEmpty().forEach { assertTrue(it.authority.startsWith("${app.packageName}.")) }
        assertEquals(SavedConnection.Missing, StorageConnectionStore(app).load())
        assertEquals(6, app.archiveUi.snapshot!!.records.size)
        val resource = reviewMonths(app.archiveUi.snapshot!!).first().moments.first().media.first().preview!!
        assertTrue("Preview must copy the seeded original into its own media directory",
            File(app.filesDir, "media/${resource.objectKey}").isFile)
        compose.waitForIdle()
        val previewId = resource.id
        compose.waitUntil(10_000) {
            shadowOf(Looper.getMainLooper()).idle()
            compose.onAllNodesWithTag("mediaPreview-$previewId", useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag("tabSettings").performClick()
        compose.onNodeWithTag("mySettings").performScrollTo().performClick()
        compose.onNodeWithTag("phoneParent").assertTextEquals("这台手机：爸爸")
        compose.onNodeWithTag("localMediaUsage").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("appVersion").performScrollTo().assertTextContains("2.2.6-preview", substring = true)
        compose.onNodeWithTag("settingsBack").performScrollTo().performClick()
        compose.onNodeWithTag("addMoment").performClick()
        compose.onNodeWithTag("addCameraMenuAction").assertIsDisplayed()
        compose.onNodeWithTag("addPhotosMenuAction").assertIsDisplayed()
        compose.onNodeWithTag("addNoteMenuAction").assertIsDisplayed()
        compose.onNodeWithTag("addDocumentsMenuAction").assertDoesNotExist()
        compose.onNodeWithTag("addAnniversaryMenuAction").assertDoesNotExist()
        compose.onNodeWithTag("addNoteMenuAction").performClick()
        compose.waitUntil(10_000) { shadowOf(Looper.getMainLooper()).idle(); app.archiveUi.drafts.size == 1 }
        val draftId = app.archiveUi.drafts.single().record.id
        compose.activityRule.scenario.recreate()
        // Saved state correctly restores the open draft editor and its origin tab, not Timeline.
        compose.waitUntil(15_000) {
            shadowOf(Looper.getMainLooper()).idle()
            !app.archiveUi.loading && compose.onAllNodesWithTag("momentNote").fetchSemanticsNodes().isNotEmpty()
        }
        assertEquals(6, app.archiveUi.snapshot!!.records.size)
        assertEquals(draftId, app.archiveUi.drafts.single().record.id)
        assertEquals(ParentIdentity.Dad, app.parentIdentity)
        compose.onNodeWithTag("parentIdentity").assertDoesNotExist()
        assertEquals(SavedConnection.Missing, StorageConnectionStore(app).load())
    }

    private fun awaitReady() {
        compose.waitUntil(15_000) {
            shadowOf(Looper.getMainLooper()).idle()
            compose.onAllNodesWithTag("timeline").fetchSemanticsNodes().isNotEmpty() && !app.archiveUi.loading
        }
    }
}
