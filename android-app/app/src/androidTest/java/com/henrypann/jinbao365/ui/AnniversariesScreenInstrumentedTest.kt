package com.henrypann.jinbao365.ui

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.henrypann.jinbao365.data.Anniversary
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.ui.theme.JinbaoTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.time.LocalDate

@RunWith(AndroidJUnit4::class)
class AnniversariesScreenInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun invalidDateCannotSaveAndUnacknowledgedSaveKeepsTheDraft() {
        val busy = androidx.compose.runtime.mutableStateOf(false)
        var calls = 0
        var complete: (() -> Unit)? = null
        compose.setContent { JinbaoTheme {
            AnniversariesScreen(emptyList(), ParentIdentity.Mom, busy.value,
                onSave = { id, title, date, saved ->
                    assertNull(id)
                    assertEquals("示例生日", title)
                    assertEquals(LocalDate.of(2024, 2, 29), date)
                    calls++
                    busy.value = true
                    complete = saved
                }, onDelete = {}, onBack = {})
        } }
        compose.onNodeWithTag("addAnniversary").performClick()
        compose.onNodeWithTag("anniversaryTitle").performTextInput("示例生日")
        compose.onNodeWithTag("anniversaryDate").performTextInput("2026-02-29")
        compose.onNodeWithTag("saveAnniversary").assertIsNotEnabled()
        compose.onNodeWithTag("anniversaryDate").performTextReplacement("2024-02-29")
        compose.onNodeWithTag("saveAnniversary").performClick()
        compose.runOnIdle { assertEquals(1, calls) }
        compose.onNodeWithTag("saveAnniversary").assertIsNotEnabled()
        compose.runOnIdle { busy.value = false }
        // An asynchronous failure has not acknowledged success: the editable input is retained.
        compose.onNodeWithTag("anniversaryTitle").assertTextContains("示例生日")
        compose.onNodeWithTag("anniversaryDate").assertTextContains("2024-02-29")
        compose.onNodeWithTag("saveAnniversary").performClick()
        compose.runOnIdle { assertEquals(2, calls); requireNotNull(complete).invoke() }
        compose.onNodeWithTag("anniversaryTitle").assertDoesNotExist()
    }

    @Test fun onlyOwnAnniversariesCanBeEditedAndDeletionNeedsConfirmation() {
        val own = Anniversary("mom-owned", ParentIdentity.Mom, "第一次看海", LocalDate.of(2025, 8, 10))
        val other = Anniversary("dad-owned", ParentIdentity.Dad, "示例生日", LocalDate.of(1990, 1, 1))
        val deleted = mutableListOf<String>()
        compose.setContent { JinbaoTheme {
            AnniversariesScreen(listOf(own, other), ParentIdentity.Mom, false,
                onSave = { _, _, _, _ -> }, onDelete = deleted::add, onBack = {})
        } }
        compose.onNodeWithTag("anniversary-dad-dad-owned").assertIsNotEnabled()
        compose.onNodeWithTag("anniversary-mom-mom-owned").performScrollTo().performClick()
        compose.onNodeWithTag("anniversaryTitle").assertTextContains("第一次看海")
        compose.onNodeWithTag("anniversaryDate").assertTextContains("2025-08-10")
        compose.onNodeWithText("取消").performClick()
        compose.onNodeWithTag("anniversary-mom-mom-owned").performScrollTo().performClick()
        compose.onNodeWithTag("deleteAnniversary-mom-owned").performClick()
        compose.runOnIdle { assertTrue(deleted.isEmpty()) }
        compose.onNodeWithText("取消").performClick()
        compose.runOnIdle { assertTrue(deleted.isEmpty()) }
        compose.onNodeWithTag("anniversary-mom-mom-owned").performScrollTo().performClick()
        compose.onNodeWithTag("deleteAnniversary-mom-owned").performClick()
        compose.onNodeWithTag("confirmDeleteAnniversary").performClick()
        compose.runOnIdle { assertEquals(listOf("mom-owned"), deleted) }
    }
}
