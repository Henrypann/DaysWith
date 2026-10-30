package com.henrypann.jinbao365.ui

import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.henrypann.jinbao365.JinbaoApplication
import com.henrypann.jinbao365.backup.BackupSummary
import com.henrypann.jinbao365.data.Anniversary
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.debug.SeedScenes
import com.henrypann.jinbao365.ui.theme.JinbaoTheme
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonPrimitive
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.media.CaptureTime
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import java.time.Instant
import java.time.LocalDate

/** Actual Compose layout, including text measurement, at the requested viewport/font matrix. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "zh-rCN-w411dp-h891dp-xhdpi", application = JinbaoApplication::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ResponsiveUiTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test @Config(qualifiers = "zh-rCN-w320dp-h800dp-xhdpi") fun width320Font100() = matrix(320, 1f)
    @Test @Config(qualifiers = "zh-rCN-w320dp-h800dp-xhdpi") fun width320Font150() = matrix(320, 1.5f)
    @Test @Config(qualifiers = "zh-rCN-w320dp-h800dp-xhdpi") fun width320Font200() = matrix(320, 2f)
    @Test @Config(qualifiers = "zh-rCN-w360dp-h800dp-xhdpi") fun width360Font100() = matrix(360, 1f)
    @Test @Config(qualifiers = "zh-rCN-w360dp-h800dp-xhdpi") fun width360Font150() = matrix(360, 1.5f)
    @Test @Config(qualifiers = "zh-rCN-w360dp-h800dp-xhdpi") fun width360Font200() = matrix(360, 2f)
    @Test fun width411Font100() = matrix(411, 1f)
    @Test fun width411Font150() = matrix(411, 1.5f)
    @Test fun width411Font200() = matrix(411, 2f)

    @Test @Config(qualifiers = "zh-rCN-w320dp-h800dp-xhdpi")
    fun emptyReviewAt200HasOneScrollableInvitation() {
        val app = androidx.test.core.app.ApplicationProvider.getApplicationContext<JinbaoApplication>()
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, 2f)) {
                JinbaoTheme { ReviewScreen(ArchiveSnapshot.empty(), app.filesDir, {}) }
            }
        }
        compose.onAllNodesWithText("回顾，从第一条记录开始").assertCountEquals(1)
        compose.onNodeWithText("把日子，慢慢珍藏").assertDoesNotExist()
        compose.onNodeWithText("轻点下方＋，留住今天。已有记录会按月份出现在这里。").performScrollTo().assertIsDisplayed()
        capture("13-empty-review-200")
        app.onTerminate()
    }

    @Test @Config(qualifiers = "zh-rCN-w320dp-h800dp-xhdpi")
    fun multipleMonthsLongTitleAndMissingMediaAt200RemainNavigable() {
        val app = androidx.test.core.app.ApplicationProvider.getApplicationContext<JinbaoApplication>()
        val base = runBlocking { SeedScenes.seed(app, Instant.parse("2026-10-13T12:00:00Z").toEpochMilli()) }
        val title = "和家人一起度过特别漫长又值得珍藏的一天".repeat(4)
        val latestId = reviewMonths(base).first().moments.first().id
        val first = base.records.single { it.id == latestId }.let { it.copy(title = it.title!!.copy(value = JsonPrimitive(title))) }
        val earlier = base.records.last().copy(id = "previous-month", occurredAt = first.occurredAt.copy(
            value = CaptureTime.iana(Instant.parse("2025-12-31T10:00:00Z").toEpochMilli(), "UTC")))
        val snapshot = base.copy(records = listOf(first) + base.records.filter { it.id != first.id } + earlier)
        var opened: String? = null
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, 2f)) {
                JinbaoTheme { Surface { ReviewScreen(snapshot, File(app.filesDir, "missing-media"), { opened = it }) } }
            }
        }
        compose.onNodeWithTag("reviewMonth-2025-12").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("reviewMonth-2026-10").performScrollTo().assertIsDisplayed()
        val layout = mutableListOf<TextLayoutResult>()
        compose.onNodeWithText(title, useUnmergedTree = true).performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layout) }
        assertEquals(2, layout.single().lineCount)
        assertTrue(layout.single().isLineEllipsized(1))
        capture("14-review-long-title-200")
        compose.onNodeWithTag("reviewMonth-2026-10").performClick()
        compose.onNodeWithTag("momentCard-${first.id}").performClick()
        assertEquals(first.id, opened)
        compose.onNodeWithTag("reviewBack").performClick()
        compose.onNodeWithTag("reviewMonth-2025-12").performScrollTo().performClick()
        compose.onNodeWithTag("momentCard-${earlier.id}").performClick()
        assertEquals(earlier.id, opened)
        app.onTerminate()
    }

    private fun matrix(width: Int, scale: Float) {
        val app = androidx.test.core.app.ApplicationProvider.getApplicationContext<JinbaoApplication>()
        val snapshot = runBlocking { SeedScenes.seed(app, Instant.parse("2026-10-13T12:00:00Z").toEpochMilli()) }
        val today = LocalDate.of(2026, 10, 13)
        compose.setContent {
            var tab by remember { mutableStateOf(MainTab.Timeline) }
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, scale)) {
                JinbaoTheme { Surface {
                    Column(Modifier.fillMaxSize()) {
                        Box(Modifier.weight(1f)) {
                            if (tab == MainTab.Review) ReviewScreen(snapshot, SeedScenes.mediaRoot(app), {})
                            else TimelineScreen(snapshot, false, SeedScenes.mediaRoot(app), {}, {},
                                backupSummary = BackupSummary(hasOverdue = true), parentOf = { ParentIdentity.Dad },
                                anniversaries = listOf(Anniversary("test", ParentIdentity.Dad, "全家第一次一起去海边看日出", today)),
                                todayOverride = today)
                        }
                        MainBottomBar(tab, { tab = it }, Modifier) { AddMomentButton(true, {}, {}, {}, Modifier, size = 56.dp) }
                    }
                } }
            }
        }
        compose.onNodeWithTag("timelineSearchButton").performClick()
        compose.onNodeWithTag("timelineSearch").assertIsDisplayed()
        compose.onNodeWithTag("anniversaryReminder").assertIsDisplayed().assertHeightIsAtLeast(48.dp)
        compose.onNodeWithTag("backupReminderBanner").assertIsDisplayed().assertHeightIsAtLeast(48.dp)
        assertTextFits(jinbaoDateHeader(today))
        val normalHeight = compose.onNodeWithTag("timelineDay-$today").fetchSemanticsNode().size.height
        capture("matrix-${width}-${(scale * 100).toInt()}-timeline")
        // Close search to give the sticky row a realistic content viewport, then scroll the first section.
        compose.onNodeWithTag("timelineSearchButton").performClick()
        compose.onNodeWithTag("timelineWaterfall").performScrollToIndex(1)
        val sticky = compose.onNodeWithTag("timelineStickyDay", useUnmergedTree = true)
        sticky.assertExists()
        assertEquals("Sticky and normal day rows use the same measured height", normalHeight, sticky.fetchSemanticsNode().size.height)
        compose.onNodeWithTag("tabReview").performClick()
        compose.onNodeWithTag("reviewMonth-2026-10").performScrollTo().assertIsDisplayed()
        capture("matrix-${width}-${(scale * 100).toInt()}-review")
        listOf("6条记录", "3张照片", "0段视频").forEach { assertTextFits(it, oneLine = true) }
        app.onTerminate()
    }

    private fun assertTextFits(text: String, oneLine: Boolean = false) {
        val node = compose.onNodeWithText(text, useUnmergedTree = true)
        val results = mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(results) }
        assertTrue("No layout for $text", results.isNotEmpty())
        results.forEach {
            assertFalse("Clipped text height: $text", it.didOverflowHeight)
            // Text layout uses fractional glyph widths while its public size is integer pixels.
            // Permit only that subpixel rounding; a lost glyph or wrapped unit still fails.
            val right = (0 until it.lineCount).maxOf { line -> it.getLineRight(line) }
            assertTrue("Clipped text width: $text; right=$right; width=${it.size.width}", right <= it.size.width + 1f)
            if (oneLine) assertEquals("Summary unit must not split: $text", 1, it.lineCount)
        }
    }

    private fun capture(name: String) {
        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        val file = File("../../artifacts/app-2.0/screenshots/$name.png")
        file.parentFile!!.mkdirs()
        file.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
    }
}
