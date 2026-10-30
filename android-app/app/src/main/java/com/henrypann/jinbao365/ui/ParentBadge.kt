package com.henrypann.jinbao365.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.ui.theme.DesignTokens

@Composable
internal fun ParentBadge(parent: ParentIdentity) {
    val dad = parent == ParentIdentity.Dad
    Surface(color = if (dad) DesignTokens.Colors.parentDadBg else DesignTokens.Colors.parentMomBg,
        shape = RoundedCornerShape(DesignTokens.Radius.full)) {
        Text(parent.label, Modifier.padding(horizontal = 9.dp, vertical = 3.dp),
            color = if (dad) DesignTokens.Colors.parentDadInk else DesignTokens.Colors.parentMomInk,
            fontSize = DesignTokens.Typography.metaSize, lineHeight = DesignTokens.Typography.metaLineHeight,
            fontWeight = DesignTokens.Typography.metaWeight)
    }
}

/** Timeline cards use a shorter capsule. Other pages keep ParentBadge. */
@Composable
internal fun TimelineParentBadge(parent: ParentIdentity) {
    val dad = parent == ParentIdentity.Dad
    Surface(color = if (dad) DesignTokens.Colors.parentDadBg else DesignTokens.Colors.parentMomBg,
        shape = RoundedCornerShape(DesignTokens.Radius.full)) {
        Box(Modifier.height(20.dp).padding(horizontal = 8.dp), contentAlignment = Alignment.Center) {
            Text(parent.label, color = if (dad) DesignTokens.Colors.parentDadInk else DesignTokens.Colors.parentMomInk,
                fontSize = 11.sp, lineHeight = 14.sp, fontWeight = FontWeight.Medium)
        }
    }
}
