package com.henrypann.jinbao365.ui.theme

import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

class DesignTokensTest {
    private val tokens = Json.parseToJsonElement(tokensFile().readText()).jsonObject

    @Test
    fun colorsMatchSharedTokensIncludingRgbaAlpha() {
        val actual = with(DesignTokens.Colors) {
            mapOf(
                "navy" to navy,
                "gold" to gold,
                "green" to green,
                "blue" to blue,
                "purple" to purple,
                "cream" to cream,
                "outline" to outline,
                "success" to success,
                "onNavy" to onNavy,
                "parentDadBg" to parentDadBg,
                "parentMomBg" to parentMomBg,
                "parentDadInk" to parentDadInk,
                "parentMomInk" to parentMomInk,
                "photoPlaceholder" to photoPlaceholder,
                "bg" to bg,
                "surface" to surface,
                "ink" to ink,
                "inkSecondary" to inkSecondary,
                "separator" to separator,
                "accent" to accent,
                "onAccent" to onAccent,
                "accentText" to accentText,
                "accentSoft" to accentSoft,
                "problem" to problem,
                "destructive" to destructive,
                "onPhoto" to onPhoto,
            )
        }
        val expected = tokens.getValue("color").jsonObject
        assertEquals("color names", expected.keys, actual.keys)
        for ((name, color) in actual) {
            val rgba = expected.getValue(name).jsonPrimitive.content.removePrefix("#")
            // JSON is RRGGBB or RRGGBBAA; Compose exposes AARRGGBB.
            val alpha = if (rgba.length == 8) rgba.takeLast(2) else "FF"
            val expectedArgb = (alpha + rgba.take(6)).uppercase()
            val actualArgb = color.toArgb().toUInt().toString(16).padStart(8, '0').uppercase()
            assertEquals("color.$name", expectedArgb, actualArgb)
        }
    }

    @Test
    fun typographyMatchesSharedSizesLineHeightsAndWeights() {
        val actual = with(DesignTokens.Typography) {
            mapOf(
                "display" to Triple(displaySize, displayLineHeight, displayWeight),
                "title" to Triple(titleSize, titleLineHeight, titleWeight),
                "body" to Triple(bodySize, bodyLineHeight, bodyWeight),
                "headline" to Triple(headlineSize, headlineLineHeight, headlineWeight),
                "caption" to Triple(captionSize, captionLineHeight, captionWeight),
                "cardTitle" to Triple(cardTitleSize, cardTitleLineHeight, cardTitleWeight),
                "meta" to Triple(metaSize, metaLineHeight, metaWeight),
                "largeTitle" to Triple(largeTitleSize, largeTitleLineHeight, largeTitleWeight),
            )
        }
        val expected = tokens.getValue("type").jsonObject
        assertEquals("type names", expected.keys, actual.keys)
        for ((name, style) in actual) {
            val token = expected.getValue(name).jsonObject
            assertEquals("type.$name.size", token.number("size").sp, style.first)
            assertEquals("type.$name.lineHeight", token.number("lineHeight").sp, style.second)
            assertEquals("type.$name.weight", FontWeight(token.number("weight")), style.third)
        }
    }

    @Test
    fun spacingMatchesSharedTokens() {
        val actual = with(DesignTokens.Spacing) {
            mapOf("xs" to xs, "s" to s, "m" to m, "l" to l)
        }
        val expected = tokens.getValue("space").jsonObject
        assertEquals("space names", expected.keys, actual.keys)
        for ((name, spacing) in actual) {
            assertEquals("space.$name", expected.number(name).dp, spacing)
        }
        assertEquals("photoGutter", tokens.number("photoGutter").dp, DesignTokens.photoGutter)
    }

    @Test
    fun radiiMatchSharedTokens() {
        val actual = with(DesignTokens.Radius) {
            mapOf("m" to m, "l" to l, "full" to full)
        }
        val expected = tokens.getValue("radius").jsonObject
        assertEquals("radius names", expected.keys, actual.keys)
        for ((name, radius) in actual) {
            assertEquals("radius.$name", expected.number(name).dp, radius)
        }
    }
}

private fun JsonObject.number(name: String): Int = getValue(name).jsonPrimitive.int

private fun tokensFile(): File {
    // Gradle's unit-test working directory is android-app/app: the first match
    // is ../../design/tokens.json. Walking upward also supports IDE test runs.
    var directory = File(checkNotNull(System.getProperty("user.dir"))).absoluteFile
    while (true) {
        val candidate = File(directory, "design/tokens.json")
        if (candidate.isFile) return candidate
        directory = directory.parentFile ?: error("design/tokens.json not found from ${System.getProperty("user.dir")}")
    }
}
