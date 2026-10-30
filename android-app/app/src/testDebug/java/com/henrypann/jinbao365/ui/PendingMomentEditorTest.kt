package com.henrypann.jinbao365.ui

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.test.core.app.ApplicationProvider
import com.henrypann.jinbao365.JinbaoApplication
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.editing.momentDraft
import com.henrypann.jinbao365.ui.theme.JinbaoTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.util.concurrent.Executors
import android.os.Looper
import org.robolectric.Shadows.shadowOf

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "zh-rCN-w360dp-h900dp-xhdpi", application = JinbaoApplication::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class PendingMomentEditorTest {
    @org.junit.Before fun resetProviderPathCache() {
        // Each Robolectric case gets a new filesDir; FileProvider retains a process-static cache.
        val cache = androidx.core.content.FileProvider::class.java.getDeclaredField("sCache").apply { isAccessible = true }
        (cache.get(null) as MutableMap<*, *>).clear()
    }
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun pendingCaptureAllowsWritingButBlocksSaveAndRestoresTheText() {
        val app = ApplicationProvider.getApplicationContext<JinbaoApplication>()
        app.parentIdentityStore.confirm(ParentIdentity.Dad)
        val io = Executors.newSingleThreadExecutor()
        val draft = io.submit<com.henrypann.jinbao365.data.StoredDraft> {
            app.archive.createDraft(app.deviceId, System.currentTimeMillis())
        }.get()
        val capture = io.submit<com.henrypann.jinbao365.media.PendingCapture> {
            app.pendingMedia.prepareCamera(draft.record.id)
        }.get()
        val snapshot = io.submit<com.henrypann.jinbao365.archive.ArchiveSnapshot> { app.archive.loadSnapshot() }.get()
        var saved: String? = null
        val restoration = StateRestorationTester(compose)
        restoration.setContent {
            JinbaoTheme { MomentEditorScreen(app, snapshot, null, draft.record.id, false, false,
                onClose = {}, onSaved = { saved = it }, onChanged = {}) }
        }
        awaitState { compose.onAllNodesWithTag("momentTitle").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("momentTitle").performScrollTo().performTextInput("正在写的标题")
        compose.onNodeWithTag("momentNote").performScrollTo().performTextInput("照片还没准备好，也能先写。")
        compose.onNodeWithTag("saveMoment").assertIsNotEnabled()
        restoration.emulateSavedInstanceStateRestore()
        awaitState { compose.onAllNodesWithTag("momentTitle").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("momentTitle").performScrollTo().assertTextContains("正在写的标题")
        compose.onNodeWithTag("momentNote").performScrollTo().assertTextContains("照片还没准备好，也能先写。")
        compose.onNodeWithTag("saveMoment").assertIsNotEnabled()
        io.submit { app.pendingMedia.cancel(capture.taskId) }.get()
        awaitState { compose.onAllNodesWithText("继续拍照").fetchSemanticsNodes().isEmpty() }
        compose.onNodeWithTag("saveMoment").assertIsEnabled().performClick()
        awaitState { saved != null }
        val record = io.submit<com.henrypann.jinbao365.archive.ArchiveRecord> {
            app.archive.loadSnapshot().records.single { it.id == saved }
        }.get()
        assertEquals("正在写的标题", momentDraft(record).title)
        assertEquals("照片还没准备好，也能先写。", momentDraft(record).note)
        assertTrue(momentDraft(record).assetIds.isEmpty())
        io.shutdown()
    }
    @Test fun immediateRemovePersistsTypedTitleBeforeAnOwnedEmptyDraftCanBeCancelled() {
        val app = ApplicationProvider.getApplicationContext<JinbaoApplication>()
        app.parentIdentityStore.confirm(ParentIdentity.Dad)
        val io = Executors.newSingleThreadExecutor()
        val capture = io.submit<com.henrypann.jinbao365.media.PendingCapture> { app.pendingMedia.prepareCamera() }.get()
        val snapshot = io.submit<com.henrypann.jinbao365.archive.ArchiveSnapshot> { app.archive.loadSnapshot() }.get()
        compose.setContent {
            JinbaoTheme { MomentEditorScreen(app, snapshot, null, capture.draftId, false, false,
                onClose = {}, onSaved = {}, onChanged = {}) }
        }
        awaitState { compose.onAllNodesWithTag("momentTitle").fetchSemanticsNodes().isNotEmpty() }
        val remove = compose.onNodeWithText("移除").fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsActions.OnClick].action!!
        compose.mainClock.autoAdvance = false
        compose.onNodeWithTag("momentTitle").performTextInput("立刻移除也要保留")
        // Invoke the visible action without advancing the 400ms autosave timer.
        compose.runOnIdle { remove() }
        compose.mainClock.autoAdvance = true
        awaitState { compose.onAllNodesWithText("继续拍照").fetchSemanticsNodes().isEmpty() }
        compose.onNodeWithTag("saveMoment").assertIsEnabled()
        val retained = io.submit<com.henrypann.jinbao365.data.StoredDraft?> { app.archive.loadDraft(capture.draftId) }.get()
        assertNotNull(retained)
        assertEquals("立刻移除也要保留", momentDraft(retained!!.record).title)
        io.shutdown()
    }
    @Test fun changedOriginalOffersDiscardingOnlyTheEditDraft() {
        val app = ApplicationProvider.getApplicationContext<JinbaoApplication>()
        app.parentIdentityStore.confirm(ParentIdentity.Dad)
        val io = Executors.newSingleThreadExecutor()
        val original = io.submit<com.henrypann.jinbao365.archive.ArchiveRecord> {
            val draft = app.archive.createDraft(app.deviceId, System.currentTimeMillis())
            app.archive.updateDraft(draft.record.id, app.deviceId, System.currentTimeMillis()) { it.copy(title = "原来的记录") }
            app.archive.commitDraft(draft.record.id)
        }.get()
        val draft = io.submit<com.henrypann.jinbao365.data.StoredDraft> { app.archive.createEditDraft(original.id) }.get()
        val snapshot = io.submit<com.henrypann.jinbao365.archive.ArchiveSnapshot> { app.archive.loadSnapshot() }.get()
        var closed = false
        var saved = false
        compose.setContent { JinbaoTheme {
            MomentEditorScreen(app, snapshot, null, draft.record.id, false, false,
                onClose = { closed = true }, onSaved = { saved = true }, onChanged = {})
        } }
        awaitState { compose.onAllNodesWithTag("momentTitle").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("momentTitle").performScrollTo().performTextReplacement("本次编辑")
        val changed = io.submit<com.henrypann.jinbao365.archive.ArchiveRecord> {
            app.archive.editRecord(original.id, app.deviceId, System.currentTimeMillis()) { it.copy(title = "另一处更新") }
        }.get()
        compose.onNodeWithTag("saveMoment").performClick()
        awaitState { compose.onAllNodesWithTag("momentEditorError").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("原记录已有更新，编辑草稿已保留。请处理这份编辑草稿：保留并返回，或丢弃后重新编辑原记录。").assertIsDisplayed()
        assertFalse(saved)
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.onNodeWithText("编辑草稿仍已保留。丢弃后可以重新编辑原记录；原记录不会被删除。").assertIsDisplayed()
        compose.onNodeWithText("丢弃草稿").performClick()
        awaitState { closed }
        assertEquals(changed, io.submit<com.henrypann.jinbao365.archive.ArchiveRecord> { app.archive.loadSnapshot().records.single() }.get())
        assertNull(io.submit<com.henrypann.jinbao365.data.StoredDraft?> { app.archive.loadDraft(draft.record.id) }.get())
        io.shutdown()
    }
    private fun awaitState(condition: () -> Boolean) {
        compose.waitUntil(10_000) {
            // Editor commands intentionally post completion through the real Android main Handler.
            shadowOf(Looper.getMainLooper()).idle()
            condition()
        }
    }
}
