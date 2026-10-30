package com.henrypann.jinbao365.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.henrypann.jinbao365.R
import com.henrypann.jinbao365.ui.theme.DesignTokens

internal enum class BrandIllustration(val resource: Int) {
    Quiet(R.drawable.brand_mark), Happy(R.drawable.brand_mark),
    Explore(R.drawable.brand_mark), Together(R.drawable.brand_mark)
}

@Composable
internal fun BrandWordmark() {
    Text("DaysWith", fontSize = 36.sp, fontWeight = FontWeight.Bold)
}

@Composable
internal fun BrandPrimaryButton(onClick: () -> Unit, modifier: Modifier = Modifier,
    enabled: Boolean = true, shape: Shape = RoundedCornerShape(12.dp),
    colors: ButtonColors = ButtonDefaults.buttonColors(containerColor = DesignTokens.Colors.gold,
        contentColor = DesignTokens.Colors.navy), border: BorderStroke? = null,
    content: @Composable RowScope.() -> Unit) {
    Button(onClick, modifier.heightIn(min = 48.dp), enabled = enabled, shape = shape,
        colors = colors, border = border, content = content)
}

@Composable
internal fun brandFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedContainerColor = DesignTokens.Colors.surface,
    unfocusedContainerColor = DesignTokens.Colors.surface,
    disabledContainerColor = DesignTokens.Colors.surface,
    errorContainerColor = DesignTokens.Colors.surface,
    focusedBorderColor = DesignTokens.Colors.navy,
    unfocusedBorderColor = DesignTokens.Colors.outline,
    focusedLabelColor = DesignTokens.Colors.navy,
    unfocusedLabelColor = DesignTokens.Colors.inkSecondary,
    cursorColor = DesignTokens.Colors.navy,
)

@Composable
internal fun BrandPageTitle(title: String, modifier: Modifier = Modifier) {
    Text(title, modifier.semantics { heading() }, style = MaterialTheme.typography.displayLarge,
        color = DesignTokens.Colors.ink)
}

@Composable
internal fun BrandTimelineHeader(age: String, searchVisible: Boolean, onSearch: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Image(painterResource(R.drawable.brand_mark), null, Modifier.size(36.dp).clip(RoundedCornerShape(8.dp)))
                Text("DaysWith", style = MaterialTheme.typography.titleLarge, color = DesignTokens.Colors.ink)
            }
            Text(age, color = DesignTokens.Colors.inkSecondary, fontSize = DesignTokens.Typography.captionSize,
                lineHeight = DesignTokens.Typography.captionLineHeight,
                modifier = Modifier.testTag("jinbaoCurrentAge"))
        }
        IconButton(onClick = onSearch, modifier = Modifier.size(48.dp).testTag("timelineSearchButton")) {
            Icon(if (searchVisible) Icons.Filled.Close else Icons.Filled.Search,
                if (searchVisible) "收起搜索" else "搜索记录", tint = DesignTokens.Colors.inkSecondary)
        }
    }
}

/** Lightweight hero for identity and permission only. Page titles live outside it. */
@Composable
internal fun BrandHero(title: String, subtitle: String, illustration: BrandIllustration? = null, compact: Boolean = false) {
    Surface(color = DesignTokens.Colors.accentSoft, contentColor = DesignTokens.Colors.ink,
        shape = RoundedCornerShape(20.dp), modifier = Modifier.fillMaxWidth()) {
        BoxWithConstraints {
            val showIllustration = maxWidth >= 340.dp && LocalDensity.current.fontScale < 1.5f
            Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Image(painterResource(R.drawable.brand_mark), contentDescription = null,
                        modifier = Modifier.size(36.dp).clip(RoundedCornerShape(8.dp)))
                    Text(title, style = if (compact) MaterialTheme.typography.titleLarge else MaterialTheme.typography.displayLarge,
                        color = DesignTokens.Colors.ink, modifier = Modifier.semantics { heading() })
                    Text(subtitle, style = MaterialTheme.typography.bodySmall, color = DesignTokens.Colors.inkSecondary)
                }
                if (illustration != null && showIllustration) Image(painterResource(illustration.resource), null,
                    modifier = Modifier.padding(start = 8.dp).width(if (compact) 72.dp else 104.dp).height(if (compact) 88.dp else 144.dp))
            }
        }
    }
}

@Composable
internal fun BrandEmptyState(title: String, subtitle: String, illustration: BrandIllustration = BrandIllustration.Quiet) {
    Column(Modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Image(painterResource(illustration.resource), null, Modifier.size(160.dp))
        Text(title, style = MaterialTheme.typography.titleLarge, color = DesignTokens.Colors.ink)
        Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = DesignTokens.Colors.inkSecondary)
    }
}

@Composable
internal fun BrandStatusBanner(text: String, isError: Boolean = false, modifier: Modifier = Modifier) {
    Surface(modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, shape = RoundedCornerShape(12.dp),
        color = if (isError) Color(0xFFFCEAEA) else DesignTokens.Colors.accentSoft) {
        Text(text, Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall,
            color = if (isError) DesignTokens.Colors.problem else DesignTokens.Colors.ink)
    }
}
