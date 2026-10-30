package com.henrypann.jinbao365.ui

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalConfiguration
import android.content.res.Configuration
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.espresso.Espresso
import com.henrypann.jinbao365.JinbaoApplication
import com.henrypann.jinbao365.ui.theme.JinbaoTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "zh-rCN-w320dp-h800dp-xhdpi", application = JinbaoApplication::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class AddMomentMenuTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun narrowScreenHasExactlyThreeFullWidthActions() = menu(1f)
    @Test fun narrowScreenAt150PercentHasReachableActions() = menu(1.5f)
    @Test fun narrowScreenAt200PercentHasReachableActions() = menu(2f)
    @Test @Config(qualifiers = "zh-rCN-w411dp-h1000dp-xhdpi")
    fun longScreenUsesAvailableWidth() = menu(2f, 411)

    @Test fun popupWidthUsesWindowConstraintsInsteadOfAStaleConfiguration() = menu(1f, configurationWidth = 900)
    @Test @Config(qualifiers = "zh-rCN-w320dp-h300dp-xhdpi")
    fun shortWindowAt200PercentCanScrollToEveryAction() = menu(2f, scroll = true)

    private fun menu(scale: Float, width: Int = 320, scroll: Boolean = false, configurationWidth: Int = width) {
        var selected = ""
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, scale),
                LocalConfiguration provides Configuration(LocalConfiguration.current).apply { screenWidthDp = configurationWidth }) {
                JinbaoTheme { Surface {
                    Box(Modifier.fillMaxSize()) {
                        MainBottomBar(MainTab.Timeline, {}, Modifier.align(androidx.compose.ui.Alignment.BottomCenter)) {
                            AddMomentButton(true, { selected = "camera" }, { selected = "photos" }, { selected = "note" }, Modifier, size = 56.dp)
                        }
                    }
                } }
            }
        }
        compose.onNodeWithTag("addMoment").performClick()
        compose.onNodeWithTag("addMomentMenu").assertWidthIsEqualTo((width - 32).dp)
        val tags = listOf("addCameraMenuAction", "addPhotosMenuAction", "addNoteMenuAction")
        tags.forEach {
            val node = compose.onNodeWithTag(it)
            if (scroll) node.performScrollTo()
            node.assertIsDisplayed().assertHeightIsAtLeast(56.dp).assertWidthIsEqualTo((width - 32).dp)
        }
        listOf("拍照", "选照片", "写文字").forEach {
            if (scroll) compose.onNodeWithText(it).performScrollTo()
            compose.onNodeWithText(it).assertIsDisplayed()
        }
        compose.onNodeWithTag("addDocumentsMenuAction").assertDoesNotExist()
        compose.onNodeWithTag("addAnniversaryMenuAction").assertDoesNotExist()
        // Popup's window position must end before the navigation capsule starts.
        val menuBottom = compose.onNodeWithTag("addMomentMenu").fetchSemanticsNode().boundsInWindow.bottom
        val barTop = compose.onNodeWithTag("bottomBar").fetchSemanticsNode().boundsInWindow.top
        assertTrue("Menu overlaps navigation: $menuBottom > $barTop", menuBottom <= barTop)
        if (scroll) compose.onNodeWithTag(tags[0]).performScrollTo()
        compose.onNodeWithTag(tags[0]).performClick()
        assertEquals("camera", selected)
        compose.onNodeWithTag("addMomentMenu").assertDoesNotExist()
        compose.onNodeWithTag("addMoment").performClick()
        if (scroll) compose.onNodeWithTag(tags[1]).performScrollTo()
        compose.onNodeWithTag(tags[1]).performClick()
        assertEquals("photos", selected)
        compose.onNodeWithTag("addMoment").performClick()
        if (scroll) compose.onNodeWithTag(tags[2]).performScrollTo()
        compose.onNodeWithTag(tags[2]).performClick()
        assertEquals("note", selected)
        compose.onNodeWithTag("addMoment").performClick()
        compose.onNodeWithTag("addMomentMenu").assertIsDisplayed()
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.onNodeWithTag("addMomentMenu").assertDoesNotExist()
        compose.onNodeWithTag("addMoment").performClick()
        compose.onNodeWithTag("addMomentMenu").assertIsDisplayed()
        compose.onNode(isPopup()).performTouchInput { click(Offset(1f, center.y)) }
        compose.onNodeWithTag("addMomentMenu").assertDoesNotExist()
    }
}
