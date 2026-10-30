// DaysWith 的东方亲子主题；与 android-app/design/tokens.json 一起维护。
package com.henrypann.jinbao365.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

object DesignTokens {
    object Colors {
        val bg = Color(0xFFF4F4F2)
        val surface = Color(0xFFFFFFFF)
        val ink = Color(0xFF0F2747)
        val inkSecondary = Color(0xFF6E6E73)
        val separator = Color(0xFFE5E5EA)
        val accent = Color(0xFFF7C948)
        val onAccent = Color(0xFF0F2747)
        val accentText = Color(0xFF0F2747)
        val accentSoft = Color(0xFFFEF4D6)
        val problem = Color(0xFFA33333)
        val destructive = Color(0xFFA33333)
        val onPhoto = Color(0x73000000)
        val navy = Color(0xFF0F2747)
        val gold = Color(0xFFF7C948)
        val green = Color(0xFF4C7F46)
        val blue = Color(0xFF3B6CB7)
        val purple = Color(0xFFB692D9)
        val cream = Color(0xFFF4F4F2)
        val outline = Color(0xFF8C8C91)
        val success = Color(0xFF365E32)
        val onNavy = Color(0xFFFDF6E9)
        val parentDadBg = Color(0xFFDEEDF8)
        val parentMomBg = Color(0xFFF9E1E8)
        val parentDadInk = Color(0xFF2F5A75)
        val parentMomInk = Color(0xFF86495D)
        val photoPlaceholder = Color(0xFFECECEA)
    }

    object Typography {
        val displaySize = 28.sp
        val displayLineHeight = 36.sp
        val displayWeight = FontWeight.Bold

        val titleSize = 20.sp
        val titleLineHeight = 25.sp
        val titleWeight = FontWeight.SemiBold

        val bodySize = 17.sp
        val bodyLineHeight = 22.sp
        val bodyWeight = FontWeight.Normal

        val headlineSize = 15.sp
        val headlineLineHeight = 20.sp
        val headlineWeight = FontWeight.SemiBold

        val captionSize = 13.sp
        val captionLineHeight = 18.sp
        val captionWeight = FontWeight.Normal

        val cardTitleSize = 13.sp
        val cardTitleLineHeight = 18.sp
        val cardTitleWeight = FontWeight.SemiBold

        val metaSize = 12.sp
        val metaLineHeight = 16.sp
        val metaWeight = FontWeight.Normal

        val largeTitleSize = 28.sp
        val largeTitleLineHeight = 34.sp
        val largeTitleWeight = FontWeight.Bold
    }

    object Spacing {
        val xs = 4.dp
        val s = 8.dp
        val m = 16.dp
        val l = 24.dp
    }

    object Radius {
        val m = 12.dp
        val l = 20.dp
        val full = 999.dp
    }

    val photoGutter = 4.dp
}
