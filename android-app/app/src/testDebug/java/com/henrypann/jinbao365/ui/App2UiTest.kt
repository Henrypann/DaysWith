package com.henrypann.jinbao365.ui

import android.graphics.Bitmap
import android.app.Activity
import android.content.Intent
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Density
import com.henrypann.jinbao365.JinbaoApplication
import com.henrypann.jinbao365.data.DefaultAnniversaries
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.debug.SeedScenes
import com.henrypann.jinbao365.media.MediaPermissions
import com.henrypann.jinbao365.storage.StorageConnectionController
import com.henrypann.jinbao365.storage.StorageConnectionStore
import com.henrypann.jinbao365.storage.StorageVerifier
import com.henrypann.jinbao365.ui.theme.DesignTokens
import com.henrypann.jinbao365.ui.theme.JinbaoTheme
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.Dispatchers
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import java.time.Instant

/** Actual AppShell in a fresh Robolectric app sandbox. No connection is stored and no COS is used. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "zh-rCN-w411dp-h891dp-xhdpi", application = JinbaoApplication::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class App2UiTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private var connection: StorageConnectionController? = null
    private val app get() = androidx.test.core.app.ApplicationProvider.getApplicationContext<JinbaoApplication>()

    @org.junit.Before fun limitIdleWait() { androidx.test.espresso.IdlingPolicies.setMasterPolicyTimeout(10, java.util.concurrent.TimeUnit.SECONDS) }

    @Test fun neutralLauncherDrawableRendersFromPackagedResources() {
        val bitmap = Bitmap.createBitmap(324, 324, Bitmap.Config.ARGB_8888)
        compose.runOnUiThread {
            val icon = requireNotNull(app.getDrawable(com.henrypann.jinbao365.R.mipmap.ic_launcher))
            icon.setBounds(0, 0, 324, 324)
            icon.draw(android.graphics.Canvas(bitmap))
        }
        val pixels = IntArray(324 * 324)
        bitmap.getPixels(pixels, 0, 324, 0, 0, 324, 324)
        assertTrue("The neutral frame geometry must be visible", pixels.count {
            android.graphics.Color.red(it) > 220 && android.graphics.Color.green(it) > 220 &&
                android.graphics.Color.blue(it) > 220 && android.graphics.Color.alpha(it) > 200
        } > 40)
        assertFalse("The launcher must not retain the previous illustrated palette", pixels.any {
            android.graphics.Color.red(it) > 180 && android.graphics.Color.green(it) > 130 &&
                android.graphics.Color.blue(it) < 140 && android.graphics.Color.alpha(it) > 200
        })
        val target = File("../../artifacts/app-2.0/screenshots/12-launcher-icon.png")
        target.parentFile!!.mkdirs()
        target.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
    }

    @After fun cleanup() {
        compose.runOnUiThread { connection?.close() }
        app.onTerminate()
        androidx.test.espresso.IdlingPolicies.setMasterPolicyTimeout(60, java.util.concurrent.TimeUnit.SECONDS)
    }

    private fun installShell(empty: Boolean = false, fontScale: Float = 1f) {
        app.parentIdentityStore.confirm(ParentIdentity.Dad)
        if (!empty) {
            val data = runBlocking { SeedScenes.seed(app, Instant.parse("2026-10-13T12:00:00Z").toEpochMilli()) }
            SeedScenes.mediaRoot(app).copyRecursively(File(app.filesDir, "media"), overwrite = true)
            database { app.archive.saveSnapshot(data) }
        }
        compose.runOnUiThread {
            connection = StorageConnectionController(StorageConnectionStore(app),
                StorageVerifier { _, _, _ -> error("No network is allowed in App 2.0 UI fixtures") })
            app.archiveUi.refresh()
        }
        awaitState { !app.archiveUi.loading && connection?.connection != null }
        compose.setContent {
            var tab by remember { mutableStateOf(MainTab.Timeline) }
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, fontScale)) {
                JinbaoTheme { AppShell(requireNotNull(connection), tab, { tab = it }) }
            }
        }
    }

    @Test fun fourTabsCentralAddAndRealMonthDrilldown() {
        installShell()
        awaitPhotoPreview()
        capture("01-time")
        compose.onNodeWithTag("timelineWaterfall").performScrollToIndex(4)
        capture("19-time-scrolled")
        val tags = listOf("tabTimeline", "tabCountdown", "addMoment", "tabReview", "tabSettings")
        val bounds = tags.map { compose.onNodeWithTag(it).assertWidthIsAtLeast(48.dp).assertHeightIsAtLeast(48.dp)
            .fetchSemanticsNode().boundsInRoot }
        assertTrue(bounds.zipWithNext().all { (a, b) -> a.center.x < b.center.x })
        compose.onNodeWithTag("tabCountdown").performClick().assertIsSelected()
        capture("02-anniversaries")
        compose.onNodeWithTag("tabReview").performClick().assertIsSelected()
        compose.onNodeWithTag("reviewMonth-2026-10").assertIsDisplayed()
        capture("03-review")
        compose.onNodeWithTag("reviewMonth-2026-10").performClick()
        compose.onNodeWithTag("monthTimeline-2026-10").assertIsDisplayed()
        awaitPhotoPreview()
        capture("04-month")
        val id = reviewMonths(app.archiveUi.snapshot!!).first().moments.first().id
        compose.onNodeWithTag("momentCard-$id").performClick()
        compose.onNodeWithTag("bottomBar").assertDoesNotExist()
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.onNodeWithTag("monthTimeline-2026-10").assertIsDisplayed()
        compose.onNodeWithTag("tabSettings").performClick()
        compose.onNodeWithTag("archiveSummary").assertTextEquals("6条记录 · 1个月的时光")
        capture("05-my")
        compose.onNodeWithTag("mySettings").performScrollTo().performClick()
        compose.onNodeWithTag("phoneParent").assertIsDisplayed()
        capture("15-settings")
        compose.onNodeWithTag("settingsBack").performClick()
        compose.onNodeWithTag("myScreen").assertIsDisplayed()
        compose.onNodeWithTag("myBackup").performScrollTo().performClick()
        compose.onNodeWithTag("cloudStorage").assertIsDisplayed()
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.onNodeWithTag("settingsBack").performClick()
        compose.onNodeWithTag("tabReview").performClick()
        compose.onNodeWithTag("monthTimeline-2026-10").assertIsDisplayed()
        compose.onNodeWithTag("reviewBack").performClick()
        compose.onNodeWithTag("reviewMonth-2026-10").assertIsDisplayed()
        compose.onNodeWithTag("tabTimeline").performClick()
        compose.onNodeWithTag("timelineSearchButton").performClick()
        compose.onNodeWithTag("timelineSearch").performTextInput("公园")
        compose.runOnUiThread {
            val activity = compose.activity
            activity.getSystemService(android.view.inputmethod.InputMethodManager::class.java)
                .hideSoftInputFromWindow(activity.window.decorView.windowToken, 0)
            activity.currentFocus?.clearFocus()
        }
        compose.onNodeWithTag("tabSettings").performClick()
        compose.onNodeWithTag("tabTimeline").performClick()
        compose.onNodeWithTag("timelineSearch").assertTextContains("公园")
    }

    @Test fun menuCancelAndAnniversaryDiscardPreserveTabAndDoNotWrite() {
        installShell()
        compose.onNodeWithTag("tabReview").performClick()
        compose.onNodeWithTag("addMoment").performClick()
        compose.onNodeWithTag("tabReview").assertIsSelected()
        capture("06-add-menu", popup = true)
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.onNodeWithTag("addPhotosMenuAction").assertDoesNotExist()
        assertTrue(database { app.archive.loadDrafts().isEmpty() })
        compose.onNodeWithTag("tabCountdown").performClick()
        compose.onNodeWithTag("addAnniversary").performClick()
        compose.onNodeWithTag("anniversaryTitle").performTextInput("一起看海")
        compose.onNodeWithText("取消").performClick()
        compose.onNodeWithText("继续填写").performClick()
        compose.onNodeWithTag("anniversaryTitle").assertTextContains("一起看海")
        compose.onNodeWithText("取消").performClick()
        compose.onNodeWithTag("discardAnniversary").performClick()
        compose.onNodeWithTag("tabCountdown").assertIsSelected()
        assertTrue(database { app.archive.loadDrafts().isEmpty() })
        assertEquals(6, database { app.archive.loadSnapshot().records.size })
    }

    @Test fun noteExitRetainsDraftAndSavingCommitsOnce() {
        installShell(empty = true)
        compose.onNodeWithTag("tabSettings").performClick()
        compose.onNodeWithTag("addMoment").performClick()
        compose.onNodeWithTag("addNoteMenuAction").performClick()
        awaitState { app.archiveUi.readyDraftId == null && app.archiveUi.drafts.size == 1 }
        awaitState { compose.onAllNodesWithTag("momentNote").fetchSemanticsNodes().size == 1 }
        compose.onNodeWithTag("momentNote").performTextInput("今天笑得很开心")
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.onNodeWithText("保留草稿").performClick()
        awaitState { app.archiveUi.drafts.size == 1 }
        compose.onNodeWithTag("tabSettings").assertIsSelected()
        compose.onNodeWithTag("tabTimeline").performClick()
        compose.onNodeWithText("继续草稿 · 未命名记录").performClick()
        awaitState {
            compose.onAllNodes(hasTestTag("momentNote") and isEnabled()).fetchSemanticsNodes().size == 1
        }
        compose.onNodeWithTag("momentNote").assertTextContains("今天笑得很开心")
        val save = compose.onNodeWithTag("saveMoment").fetchSemanticsNode().config[SemanticsActions.OnClick].action!!
        compose.runOnIdle { save(); save() }
        awaitState { app.archiveUi.snapshot?.records?.size == 1 }
        assertTrue(database { app.archive.loadDrafts().isEmpty() })
    }

    @Test fun existingRecordEditOffersBothAttachmentsAndDiscardLeavesOriginalUnchanged() {
        installShell()
        compose.onNodeWithTag("tabReview").performClick()
        compose.onNodeWithTag("reviewMonth-2026-10").performClick()
        val visibleId = reviewMonths(app.archiveUi.snapshot!!).first().moments.first {
            SeedScenes.parentOf(app.archiveUi.snapshot!!, it.id) == ParentIdentity.Dad && it.media.isNotEmpty()
        }.id
        val original = database { app.archive.loadSnapshot().records.single { it.id == visibleId } }
        val beforeCount = database { app.archive.loadSnapshot().records.size }
        compose.onNodeWithTag("momentCard-${original.id}").performScrollTo().performClick()
        compose.onNodeWithTag("editMoment").performClick()
        awaitState { compose.onAllNodesWithTag("momentAddPhotos").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("momentTakePhoto").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("momentAddPhotos").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("momentTitle").performScrollTo().performTextReplacement("编辑中还没保存")
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.onNodeWithText("丢弃草稿").performClick()
        awaitState { compose.onAllNodesWithTag("editMoment").fetchSemanticsNodes().isNotEmpty() }
        assertEquals(original, database { app.archive.loadSnapshot().records.single { it.id == original.id } })
        assertTrue(database { app.archive.loadDrafts().isEmpty() })
        compose.onNodeWithTag("editMoment").performClick()
        awaitState { compose.onAllNodesWithTag("momentTitle").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("momentTitle").performScrollTo().performTextReplacement("同一条记录的新标题")
        compose.onNodeWithTag("saveMoment").performClick()
        awaitState { app.archiveUi.snapshot?.records?.firstOrNull { it.id == original.id }?.let { momentFieldText(it.title?.value) } == "同一条记录的新标题" }
        assertEquals(beforeCount, database { app.archive.loadSnapshot().records.size })
        assertTrue(database { app.archive.loadDrafts().isEmpty() })
    }

    @Test fun emptyReviewHasNoFakeMonth() {
        installShell(empty = true)
        compose.onNodeWithTag("timelineEmpty").assertIsDisplayed()
        capture("20-time-empty")
        compose.onNodeWithTag("tabReview").performClick()
        compose.onNodeWithText("回顾，从第一条记录开始").assertIsDisplayed()
        compose.onNodeWithTag("reviewMonth-2026-10").assertDoesNotExist()
        capture("07-empty-review")
    }

    @Test fun unknownDateRecordsHaveTheirOwnSectionAndReviewRow() {
        installShell(empty = true)
        database {
            val draft = app.archive.createDraft(app.deviceId, 1_000L)
            app.archive.updateDraft(draft.record.id, app.deviceId, 2_000L) {
                it.copy(title = "旧相册里的一张", occurredAtMillis = 0L)
            }
            app.archive.commitDraft(draft.record.id)
        }
        compose.runOnUiThread { app.archiveUi.refresh() }
        awaitState { app.archiveUi.snapshot?.records?.size == 1 }
        compose.onNodeWithTag("timelineUnknownDate").assertIsDisplayed()
        compose.onNodeWithText("日期未知").assertIsDisplayed()
        compose.onNodeWithText("1条").assertIsDisplayed()
        compose.onNodeWithText("时间未知").assertIsDisplayed()
        compose.onNodeWithText("旧相册里的一张").assertIsDisplayed()
        compose.onNodeWithTag("tabReview").performClick()
        compose.onNodeWithTag("reviewUnknownDate").assertIsDisplayed()
        compose.onNodeWithText("1条记录的日期未知").assertIsDisplayed()
        compose.onNodeWithText("可在时光中查看").assertIsDisplayed()
        compose.onNodeWithTag("reviewMonth-1970-01").assertDoesNotExist()
        compose.onNodeWithTag("reviewUnknownDate").performClick()
        compose.onNodeWithTag("tabTimeline").assertIsSelected()
        compose.onNodeWithTag("timelineUnknownDate").assertIsDisplayed()
        capture("21-unknown-date")
    }

    @Test fun anniversaryRapidSaveCreatesOneRowAndKeepsOrigin() {
        installShell(empty = true)
        compose.onNodeWithTag("tabSettings").performClick()
        compose.onNodeWithTag("tabCountdown").performClick()
        compose.onNodeWithTag("addAnniversary").performClick()
        compose.onNodeWithTag("anniversaryTitle").performTextInput("一起看海")
        compose.onNodeWithTag("anniversaryDate").performTextInput("2026-08-10")
        capture("10-anniversary-editor")
        val save = compose.onNodeWithTag("saveAnniversary").fetchSemanticsNode().config[SemanticsActions.OnClick].action!!
        compose.runOnIdle { save(); save() }
        awaitState { app.archiveUi.anniversaries.any { it.title == "一起看海" } }
        compose.onNodeWithTag("tabCountdown").assertIsSelected()
        assertEquals(1, app.archiveUi.anniversaries.count { it.title == "一起看海" })
        assertTrue(database { app.archive.loadDrafts().isEmpty() })
    }

    @Test fun galleryCancellationAndRapidClickLeaveNoDraftAndKeepTab() {
        installShell(empty = true)
        shadowOf(app).grantPermissions(android.Manifest.permission.READ_MEDIA_IMAGES,
            android.Manifest.permission.READ_MEDIA_VIDEO, MediaPermissions.ACCESS_MEDIA_LOCATION)
        compose.onNodeWithTag("tabReview").performClick()
        compose.onNodeWithTag("addMoment").performClick()
        val choose = compose.onNodeWithTag("addPhotosMenuAction").fetchSemanticsNode().config[SemanticsActions.OnClick].action!!
        compose.runOnIdle { choose(); choose() }
        compose.onNodeWithTag("galleryGrid").assertIsDisplayed()
        compose.onNodeWithTag("galleryComplete").assertIsNotEnabled()
        assertNull(shadowOf(compose.activity).nextStartedActivityForResult)
        compose.onNodeWithTag("galleryBack").performClick()
        compose.onNodeWithTag("tabReview").assertIsSelected()
        compose.onNodeWithTag("addMoment").assertIsEnabled()
        assertTrue(database { app.archive.loadDrafts().isEmpty() })
    }

    @Test fun anniversaryFailureBeforeNextFrameRetainsInputAndAllowsRetry() {
        var calls = 0
        var dismissed = false
        compose.setContent { JinbaoTheme {
            AnniversaryEditorScreen(null, ParentIdentity.Dad, busy = false,
                onSave = { _, _, _, saved -> calls++; if (calls == 2) saved() },
                onDismiss = { dismissed = true })
        } }
        compose.onNodeWithTag("anniversaryTitle").performTextInput("一起看海")
        compose.onNodeWithTag("anniversaryDate").performTextInput("2026-08-10")
        val save = compose.onNodeWithTag("saveAnniversary").fetchSemanticsNode().config[SemanticsActions.OnClick].action!!
        compose.runOnIdle { save(); save(); assertEquals(1, calls) }
        compose.onNodeWithTag("anniversaryTitle").assertTextContains("一起看海")
        compose.onNodeWithTag("saveAnniversary").assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals(2, calls); assertTrue(dismissed) }
    }

    @Test
    @Config(qualifiers = "zh-rCN-w320dp-h800dp-xhdpi")
    fun narrowScreenAndLargeTypeKeepNavigationAndMyActionsUsable() {
        installShell(fontScale = 1.5f)
        compose.onNodeWithTag("tabSettings").performClick()
        compose.onNodeWithTag("addMoment").assertWidthIsAtLeast(48.dp)
        compose.onNodeWithTag("mySettings").performScrollTo().assertIsDisplayed()
        capture("08-my-320dp-large-type")
        compose.onNodeWithTag("tabReview").performClick()
        compose.onNodeWithTag("reviewMonth-2026-10").performScrollTo().assertIsDisplayed()
        capture("09-review-320dp-large-type")
    }

    @Test
    @Config(qualifiers = "zh-rCN-w411dp-h560dp-xhdpi")
    fun anniversaryListScrollsToLaterCards() {
        installShell()
        compose.onNodeWithTag("tabCountdown").performClick()
        val title = compose.onNodeWithText("国庆节", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        val days = compose.onNodeWithTag("countdownDays-${DefaultAnniversaries.NATIONAL_DAY_ID}", useUnmergedTree = true)
            .fetchSemanticsNode().boundsInRoot
        assertTrue(days.left >= title.right - 1f)

        compose.onNode(hasScrollAction()).performScrollToNode(hasText("儿童节"))
        compose.onNodeWithText("儿童节", useUnmergedTree = true).assertIsDisplayed()
        capture("17-anniversaries-scrolled")
    }

    @Test fun anniversaryCardsReflowBelowTitleAtLargeType() {
        installShell(fontScale = 1.5f)
        compose.onNodeWithTag("tabCountdown").performClick()
        val daysNode = compose.onNodeWithTag("countdownDays-${DefaultAnniversaries.NATIONAL_DAY_ID}", useUnmergedTree = true)
        daysNode.performScrollTo().assertIsDisplayed()
        val title = compose.onNodeWithText("国庆节", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        val days = daysNode.fetchSemanticsNode().boundsInRoot
        assertTrue(days.top >= title.bottom - 1f)
        assertTrue(compose.onAllNodesWithText("还有").fetchSemanticsNodes().isNotEmpty())
        capture("18-anniversaries-large-type")
    }

    @Test fun parentIdentityChoicesUseSeparateDadAndMomColors() {
        compose.setContent {
            JinbaoTheme {
                Surface(color = DesignTokens.Colors.bg, modifier = Modifier.fillMaxSize()) { ParentIdentityScreen {} }
            }
        }
        compose.onNodeWithTag("chooseDad").assertIsDisplayed()
        compose.onNodeWithTag("chooseMom").assertIsDisplayed()
        compose.onNodeWithText("这台手机是谁").assertIsDisplayed()
        capture("11-parent-identity")
    }

    @Test fun permissionGateKeepsIllustrationWithoutNavyBanner() {
        compose.setContent {
            JinbaoTheme {
                Surface(color = DesignTokens.Colors.bg, modifier = Modifier.fillMaxSize()) {
                    PermissionGateScreen(emptyList(), asked = false, canRequest = true, onRequest = {}, onOpenSettings = {}, onSkip = {})
                }
            }
        }
        compose.onNodeWithText("留住一起度过的日子").assertIsDisplayed()
        compose.onNodeWithText("平凡的日子，也是宝贵的时光。").assertIsDisplayed()
        compose.onNodeWithText("一次允许全部").assertIsDisplayed()
        capture("16-permission")
    }

    @Test fun deniedPermissionGateExplainsGapsOffersSettingsAndSkip() {
        var settings = 0; var skipped = 0; var requested = 0
        compose.setContent {
            JinbaoTheme {
                Surface(color = DesignTokens.Colors.bg, modifier = Modifier.fillMaxSize()) {
                    PermissionGateScreen(listOf(com.henrypann.jinbao365.media.PermissionGap.MediaLocation,
                        com.henrypann.jinbao365.media.PermissionGap.PhotosPartial), asked = true, canRequest = false,
                        onRequest = { requested++ }, onOpenSettings = { settings++ }, onSkip = { skipped++ })
                }
            }
        }
        compose.onNodeWithTag("requestAllPermissions").assertDoesNotExist()
        compose.onNodeWithTag("permissionGap-MediaLocation").assertExists()
        compose.onNodeWithTag("permissionGap-PhotosPartial").assertExists()
        compose.onNodeWithTag("openPermissionSettings").performScrollTo().performClick()
        compose.onNodeWithTag("skipPermissions").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(1, settings); assertEquals(1, skipped); assertEquals(0, requested) }
    }

    private fun awaitState(condition: () -> Boolean) {
        compose.waitUntil(10_000) {
            shadowOf(Looper.getMainLooper()).idle()
            condition()
        }
    }

    private fun <T> database(action: () -> T): T = runBlocking(Dispatchers.IO) { action() }

    private fun awaitPhotoPreview() {
        val id = requireNotNull(reviewMonths(app.archiveUi.snapshot!!).first().moments.first().media.first().preview).id
        awaitState {
            compose.onAllNodesWithTag("mediaPreview-$id", useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()
        }
    }

    private fun capture(name: String, popup: Boolean = false) {
        compose.waitForIdle()
        val bitmap = if (popup) requireNotNull(androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
            .uiAutomation.takeScreenshot()) else compose.onRoot().captureToImage().asAndroidBitmap()
        val target = File("../../artifacts/app-2.0/screenshots/$name.png")
        target.parentFile!!.mkdirs()
        target.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        assertTrue(bitmap.width > 100 && bitmap.height > 100)
    }
}
