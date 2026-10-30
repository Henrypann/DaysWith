package com.henrypann.jinbao365.ui

import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.Density
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.henrypann.jinbao365.ui.theme.JinbaoTheme
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "zh-rCN-w411dp-h891dp-xhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class StartupArtworkScreenTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun neutralLaunchFillsDefaultScreen() = captureBoth(1f, "default")

    @Test @Config(qualifiers = "zh-rCN-w360dp-h900dp-xhdpi")
    fun neutralLaunchFitsLongScreenAtLargeFont() = captureBoth(1.5f, "long-font150")

    @Test @Config(qualifiers = "zh-rCN-w320dp-h640dp-xhdpi")
    fun neutralLaunchFitsNarrowScreenAtDoubleFont() = captureBoth(2f, "narrow-font200")

    @Test fun autoEntryRestoresProtectionBeforeAppContentAndOnlyOnce() {
        compose.mainClock.autoAdvance = false
        var protected = false
        var protections = 0
        var entries = 0
        compose.setContent {
            JinbaoTheme {
                StartupArtworkEntry(0, onProtectWindow = { protected = true; protections++ }) {
                    check(protected) { "App content must never compose in an unprotected window" }
                    SideEffect { entries++ }
                    Box(Modifier.testTag("appContent"))
                }
            }
        }
        compose.mainClock.advanceTimeBy(800)
        compose.onNodeWithTag("startupArtwork-0").assertIsDisplayed()
        compose.onNodeWithTag("appContent").assertDoesNotExist()
        compose.mainClock.advanceTimeBy(200)
        compose.waitForIdle()
        compose.onNodeWithTag("appContent").assertExists()
        compose.mainClock.advanceTimeBy(2_000)
        assertEquals(1, protections)
        assertEquals(1, entries)
    }

    @Test fun backgroundFramesDoNotCountOrEnterUntilResumed() {
        compose.mainClock.autoAdvance = false
        val owner = TestLifecycleOwner()
        compose.runOnUiThread { owner.registry.currentState = Lifecycle.State.RESUMED }
        var protections = 0
        compose.setContent {
            CompositionLocalProvider(LocalLifecycleOwner provides owner) {
                JinbaoTheme {
                    StartupArtworkEntry(1, onProtectWindow = { protections++ }) { Box(Modifier.testTag("appContent")) }
                }
            }
        }
        compose.mainClock.advanceTimeBy(400)
        compose.runOnUiThread { owner.registry.currentState = Lifecycle.State.STARTED }
        compose.mainClock.advanceTimeBy(10_000)
        compose.onNodeWithTag("appContent").assertDoesNotExist()
        assertEquals(0, protections)
        compose.runOnUiThread { owner.registry.currentState = Lifecycle.State.RESUMED }
        compose.mainClock.advanceTimeBy(400)
        compose.onNodeWithTag("appContent").assertDoesNotExist()
        compose.mainClock.advanceTimeBy(200)
        compose.waitForIdle()
        compose.onNodeWithTag("appContent").assertExists()
        assertEquals(1, protections)
    }

    private fun captureBoth(fontScale: Float, name: String) {
        val index = mutableStateOf(0)
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale)) {
                JinbaoTheme { StartupArtworkScreen(index.value) }
            }
        }
        for (artwork in 0..1) {
            compose.runOnIdle { index.value = artwork }
            compose.onNodeWithTag("startupArtwork-$artwork").assertIsDisplayed()
            compose.onNodeWithText("DaysWith").assertIsDisplayed()
            compose.onNodeWithTag("chooseDad").assertDoesNotExist()
            compose.onNodeWithTag("requestAllPermissions").assertDoesNotExist()
            val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
            val target = File("build/startup-brand-screenshots/artwork-$artwork-$name.png")
            target.parentFile!!.mkdirs()
            target.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        }
    }

    private class TestLifecycleOwner : LifecycleOwner {
        val registry = LifecycleRegistry(this)
        override val lifecycle: Lifecycle get() = registry
    }
}
