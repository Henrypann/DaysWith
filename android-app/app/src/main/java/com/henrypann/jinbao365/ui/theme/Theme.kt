package com.henrypann.jinbao365.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.text.TextStyle

// PR1 only supports light appearance, including when the device uses dark mode.
private val ArchiveColors = with(DesignTokens.Colors) {
    val page = bg
    val white = surface
    lightColorScheme(
        primary = ink,
        onPrimary = page,
        primaryContainer = accent,
        onPrimaryContainer = ink,
        inversePrimary = accent,
        secondary = accentText,
        onSecondary = page,
        secondaryContainer = white,
        onSecondaryContainer = ink,
        tertiary = green,
        onTertiary = page,
        tertiaryContainer = white,
        onTertiaryContainer = ink,
        background = page,
        onBackground = ink,
        surface = page,
        onSurface = ink,
        surfaceVariant = white,
        onSurfaceVariant = inkSecondary,
        surfaceTint = page,
        inverseSurface = ink,
        inverseOnSurface = page,
        error = problem,
        onError = page,
        errorContainer = white,
        onErrorContainer = problem,
        outline = outline,
        outlineVariant = separator,
        scrim = onPhoto,
        surfaceBright = white,
        surfaceDim = white,
        surfaceContainer = white,
        surfaceContainerHigh = white,
        surfaceContainerHighest = white,
        surfaceContainerLow = white,
        surfaceContainerLowest = white,
        primaryFixed = accent,
        primaryFixedDim = accent,
        onPrimaryFixed = onAccent,
        onPrimaryFixedVariant = onAccent,
        secondaryFixed = white,
        secondaryFixedDim = white,
        onSecondaryFixed = ink,
        onSecondaryFixedVariant = inkSecondary,
        tertiaryFixed = white,
        tertiaryFixedDim = white,
        onTertiaryFixed = ink,
        onTertiaryFixedVariant = inkSecondary,
    )
}

private val ArchiveTypography = with(DesignTokens.Typography) {
    val display = TextStyle(fontSize = displaySize, lineHeight = displayLineHeight, fontWeight = displayWeight)
    val title = TextStyle(fontSize = titleSize, lineHeight = titleLineHeight, fontWeight = titleWeight)
    val body = TextStyle(fontSize = bodySize, lineHeight = bodyLineHeight, fontWeight = bodyWeight)
    val headline = TextStyle(fontSize = headlineSize, lineHeight = headlineLineHeight, fontWeight = headlineWeight)
    val caption = TextStyle(fontSize = captionSize, lineHeight = captionLineHeight, fontWeight = captionWeight)

    // Five shared levels: display -> display*, title -> headline*/titleLarge,
    // body -> bodyLarge/bodyMedium, headline -> titleMedium/titleSmall/labelLarge,
    // caption -> bodySmall/labelMedium/labelSmall.
    Typography(
        displayLarge = display,
        displayMedium = display,
        displaySmall = display,
        headlineLarge = title,
        headlineMedium = title,
        headlineSmall = title,
        titleLarge = title,
        titleMedium = headline,
        titleSmall = headline,
        bodyLarge = body,
        bodyMedium = body,
        bodySmall = caption,
        labelLarge = headline,
        labelMedium = caption,
        labelSmall = caption,
    )
}

private val ArchiveShapes = RoundedCornerShape(DesignTokens.Radius.m).let { shape ->
    Shapes(
        extraSmall = shape,
        small = shape,
        medium = shape,
        large = RoundedCornerShape(DesignTokens.Radius.l),
        extraLarge = RoundedCornerShape(DesignTokens.Radius.l),
    )
}

@Composable
fun JinbaoTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = ArchiveColors,
        typography = ArchiveTypography,
        shapes = ArchiveShapes,
        content = content,
    )
}
