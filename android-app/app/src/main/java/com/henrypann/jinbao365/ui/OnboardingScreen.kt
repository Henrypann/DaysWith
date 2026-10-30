package com.henrypann.jinbao365.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.testTag
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.ui.theme.DesignTokens

@Composable
internal fun PermissionGateScreen(
    gaps: List<com.henrypann.jinbao365.media.PermissionGap>,
    asked: Boolean,
    canRequest: Boolean,
    onRequest: () -> Unit,
    onOpenSettings: () -> Unit,
    onSkip: () -> Unit,
) {
    Column(Modifier.fillMaxSize().systemBarsPadding().verticalScroll(rememberScrollState()).padding(28.dp),
        verticalArrangement = Arrangement.Center) {
        BrandHero("留住一起度过的日子", "平凡的日子，也是宝贵的时光。", BrandIllustration.Together, compact = true)
        Spacer(Modifier.height(16.dp))
        Text("2 / 3", color = DesignTokens.Colors.accentText)
        Spacer(Modifier.height(32.dp))
        Card(shape = RoundedCornerShape(DesignTokens.Radius.l), colors = CardDefaults.cardColors(containerColor = DesignTokens.Colors.surface)) {
            Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                Text("允许照片、视频和拍摄地点", style = MaterialTheme.typography.titleLarge)
                Text(PERMISSION_GATE_BODY)
                if (asked) gaps.forEach { gap ->
                    Text(com.henrypann.jinbao365.media.ImportPermissionCheck.message(gap), color = DesignTokens.Colors.destructive,
                        modifier = Modifier.testTag("permissionGap-${gap.name}"))
                }
                if (canRequest) {
                    BrandPrimaryButton(onClick = onRequest, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp).testTag("requestAllPermissions"),
                        shape = RoundedCornerShape(DesignTokens.Radius.m)) { Text("一次允许全部") }
                }
                if (asked || !canRequest) {
                    if (canRequest) OutlinedButton(onClick = onOpenSettings, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)
                        .testTag("openPermissionSettings")) { Text("去设置开启") }
                    else BrandPrimaryButton(onClick = onOpenSettings, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp)
                        .testTag("openPermissionSettings"), shape = RoundedCornerShape(DesignTokens.Radius.m)) { Text("去设置开启") }
                    Text(PERMISSION_SKIP_CAPTION, color = DesignTokens.Colors.inkSecondary)
                    TextButton(onClick = onSkip, modifier = Modifier.fillMaxWidth().testTag("skipPermissions")) { Text("先跳过") }
                }
            }
        }
        Spacer(Modifier.height(20.dp))
        Text("完成后，我们再连接家里的云存储，一起留下共同的生活记录。", color = DesignTokens.Colors.inkSecondary)
    }
}

internal const val PERMISSION_GATE_BODY =
    "DaysWith 只保存你亲手挑选的照片和视频原件，并保留里面的拍摄地点。需要一次允许三项：位置信息、照片和视频、访问照片位置信息。" +
        "OPPO、小米等手机把「访问照片位置信息」放在「照片和视频」里面，请一并打开。"
internal const val PERMISSION_SKIP_CAPTION =
    "可以先跳过、继续连接云存储；但没开全之前，添加照片和视频会被拦下，到时会再提醒你开启。"

@Composable
internal fun ParentIdentityScreen(onConfirm: (ParentIdentity) -> Unit) {
    var selected by remember { mutableStateOf<ParentIdentity?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize().systemBarsPadding().verticalScroll(rememberScrollState()).padding(24.dp).testTag("parentIdentity"),
        verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        BrandWordmark()
        Spacer(Modifier.height(24.dp))
        BrandHero("这台手机是谁", "每一条生活记录，都会留下你的署名。", BrandIllustration.Quiet, compact = true)
        Spacer(Modifier.height(16.dp))
        ParentIdentity.entries.forEach { parent ->
            BrandPrimaryButton(onClick = { selected = parent; error = null },
                modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp).heightIn(min = 72.dp).testTag(if (parent == ParentIdentity.Dad) "chooseDad" else "chooseMom"),
                shape = RoundedCornerShape(DesignTokens.Radius.l),
                border = BorderStroke(1.dp, if (parent == ParentIdentity.Dad) DesignTokens.Colors.parentDadInk else DesignTokens.Colors.parentMomInk),
                colors = ButtonDefaults.buttonColors(containerColor = DesignTokens.Colors.surface,
                    contentColor = DesignTokens.Colors.ink)) {
                Text(parent.label, style = MaterialTheme.typography.headlineMedium)
            }
        }
        error?.let { BrandStatusBanner(it, isError = true) }
    }
    selected?.let { parent ->
        AlertDialog(modifier = Modifier.testTag("parentConfirmation"), onDismissRequest = { selected = null }, title = { Text("确认这台手机的署名") },
            text = { Text("这台手机记的内容会署名『${parent.label}』，之后不能修改。") },
            confirmButton = { TextButton(modifier = Modifier.testTag("confirmParent"), onClick = {
                try { onConfirm(parent); selected = null }
                catch (_: Exception) { error = "署名没有保存成功，请重试。"; selected = null }
            }) { Text("确定") } },
            dismissButton = { TextButton(modifier = Modifier.testTag("reselectParent"), onClick = { selected = null }) { Text("重新选") } })
    }
}
