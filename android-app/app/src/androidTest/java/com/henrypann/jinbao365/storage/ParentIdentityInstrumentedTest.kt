package com.henrypann.jinbao365.storage

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.data.ParentIdentityStore
import com.henrypann.jinbao365.ui.ParentIdentityScreen
import com.henrypann.jinbao365.ui.theme.JinbaoTheme
import java.io.File
import java.util.UUID
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ParentIdentityInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val directories = mutableListOf<File>()
    private fun store(): ParentIdentityStore {
        val directory = File(compose.activity.noBackupFilesDir, "identity-test-${UUID.randomUUID()}")
        directories += directory
        return ParentIdentityStore(directory)
    }

    @After fun cleanSyntheticIdentity() { directories.forEach { it.deleteRecursively() } }

    @Test fun bothLargeChoicesRequireExplicitConfirmationAndReselectionDoesNotSave() {
        val store = store()
        compose.setContent { JinbaoTheme { ParentIdentityScreen(store::confirm) } }
        compose.onNodeWithText("这台手机是谁").assertIsDisplayed()
        compose.onNodeWithTag("chooseDad").assertIsDisplayed()
        compose.onNodeWithTag("chooseMom").assertIsDisplayed().performClick()
        compose.onNodeWithTag("parentConfirmation").assertExists()
        compose.onNodeWithText("这台手机记的内容会署名『妈妈』，之后不能修改。").assertExists()
        assertNull(store.parent)
        compose.onNodeWithTag("reselectParent").performClick()
        compose.onNodeWithTag("parentConfirmation").assertDoesNotExist()
        assertNull(store.parent)
        compose.onNodeWithTag("chooseDad").performClick()
        compose.onNodeWithTag("confirmParent").performClick()
        compose.onNodeWithTag("parentConfirmation").assertDoesNotExist()
        assertEquals(ParentIdentity.Dad, store.parent)
    }

    @Test fun confirmedMomIdentitySurvivesReopenAndRejectsLaterDadSelection() {
        val store = store()
        compose.setContent { JinbaoTheme { ParentIdentityScreen(store::confirm) } }
        compose.onNodeWithTag("chooseMom").performClick()
        compose.onNodeWithTag("confirmParent").performClick()
        val reopened = ParentIdentityStore(directories.single())
        assertEquals(ParentIdentity.Mom, reopened.parent)
        assertThrows(IllegalStateException::class.java) { reopened.confirm(ParentIdentity.Dad) }
        assertEquals(ParentIdentity.Mom, reopened.parent)
    }
}
