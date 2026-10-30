package com.henrypann.jinbao365.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.pow

/** Brand identity and legibility obligations; shared JSON/Kotlin parity is tested by DesignTokensTest. */
class DesignTokenContractTest {
    @Test fun primaryBrandPaletteKeepsItsPublishedIdentity() = with(DesignTokens.Colors) {
        mapOf(
            "月夜蓝" to (navy to 0xFF0F2747.toInt()),
            "孩子金" to (gold to 0xFFF7C948.toInt()),
            "竹影绿" to (green to 0xFF4C7F46.toInt()),
            "青花蓝" to (blue to 0xFF3B6CB7.toInt()),
            "藤萝紫" to (purple to 0xFFB692D9.toInt()),
            "月白" to (cream to 0xFFF4F4F2.toInt()),
        ).forEach { (name, pair) -> assertEquals(name, pair.second, pair.first.toArgb()) }
        assertEquals("Primary button uses gold", gold, accent)
        assertEquals("Primary button text uses navy", navy, onAccent)
        assertEquals("Light pages use cream", cream, bg)
    }

    @Test fun bodySupportingAndStateTextMeetsNormalTextContrast() = with(DesignTokens.Colors) {
        listOf(bg, surface).forEach { background ->
            mapOf("正文" to ink, "辅助文字" to inkSecondary, "文字按钮" to accentText,
                "错误提示" to problem, "危险操作" to destructive, "成功提示" to success).forEach { (name, color) ->
                assertContrast(name, color, background, 4.5)
            }
        }
        assertContrast("金色按钮文字", onAccent, accent, 4.5)
        assertContrast("浅金提醒", ink, accentSoft, 4.5)
        assertContrast("月夜场景文字", onNavy, navy, 4.5)
        assertContrast("爸爸署名", parentDadInk, parentDadBg, 4.5)
        assertContrast("妈妈署名", parentMomInk, parentMomBg, 4.5)
    }

    @Test fun necessaryControlOutlinesMeetNonTextContrast() = with(DesignTokens.Colors) {
        assertContrast("表单边界／月白", outline, bg, 3.0)
        assertContrast("表单边界／白色", outline, surface, 3.0)
        // Gold is decorative; the navy action glyph/label provides the visible control contrast.
        assertContrast("添加图标", onAccent, accent, 3.0)
    }

    @Test fun publishedTypeAndLayoutScalesRemainUsable() {
        assertEquals(28.sp, DesignTokens.Typography.largeTitleSize)
        assertEquals(20.sp, DesignTokens.Typography.titleSize)
        assertEquals(17.sp, DesignTokens.Typography.bodySize)
        assertEquals(13.sp, DesignTokens.Typography.captionSize)
        with(DesignTokens.Spacing) {
            listOf(xs, s, m, l).forEach { assertEquals("4 dp grid", 0f, it.value % 4f, 0f) }
        }
        assertEquals(12.dp, DesignTokens.Radius.m)
        assertEquals(20.dp, DesignTokens.Radius.l)
    }

    private fun assertContrast(label: String, foreground: Color, background: Color, minimum: Double) {
        assertEquals("$label foreground must be opaque", 1f, foreground.alpha, 0f)
        assertEquals("$label background must be opaque", 1f, background.alpha, 0f)
        val first = luminance(foreground)
        val second = luminance(background)
        val ratio = (maxOf(first, second) + .05) / (minOf(first, second) + .05)
        assertTrue("$label contrast %.2f must be >= %.1f".format(ratio, minimum), ratio >= minimum)
    }

    private fun luminance(color: Color): Double {
        fun linear(component: Float): Double = component.toDouble().let {
            if (it <= .04045) it / 12.92 else ((it + .055) / 1.055).pow(2.4)
        }
        return .2126 * linear(color.red) + .7152 * linear(color.green) + .0722 * linear(color.blue)
    }
}
