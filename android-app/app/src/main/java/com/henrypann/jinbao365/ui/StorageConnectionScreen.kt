package com.henrypann.jinbao365.ui

import android.view.View
import android.view.autofill.AutofillManager
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentDataType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDataType
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.compose.ui.window.SecureFlagPolicy
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import com.henrypann.jinbao365.storage.*
import com.henrypann.jinbao365.ui.theme.DesignTokens

/** One modal shared by setup and settings. Secret inputs are never saveable state. */
@Composable
fun StorageConnectionScreen(
    controller: StorageConnectionController,
    mandatory: Boolean,
    deviceId: String? = null,
    settingsContent: (@Composable (onChangeCredentials: () -> Unit, onDisconnect: () -> Unit) -> Unit)? = null,
) {
    val context = LocalContext.current
    val autofillManager = remember(context) { context.getSystemService(AutofillManager::class.java) }
    val saved = controller.connection
    val current = when (saved) {
        is SavedConnection.Verified -> saved.configuration
        is SavedConnection.Configured -> saved.configuration
        else -> StorageConfiguration()
    }
    var open by remember { mutableStateOf(mandatory) }
    var bucket by remember(current) { mutableStateOf(current.bucket) }
    var region by remember(current) { mutableStateOf(current.region) }
    val prefix = "life/v1/"
    var secretID by remember { mutableStateOf("") }
    var secretKey by remember { mutableStateOf("") }
    var idVisible by remember { mutableStateOf(false) }
    var submitted by remember { mutableStateOf(false) }
    fun cancelCredentialAutofill() { if (open || mandatory) autofillManager?.cancel() }
    fun clearSecrets() {
        cancelCredentialAutofill()
        secretID = ""; secretKey = ""; idVisible = false; submitted = false
    }
    // A completed verification closes the draft even if this effect still holds the old
    // mandatory value. The render gate below keeps unverified onboarding visible.
    fun closeDialog() { clearSecrets(); controller.cancelTransient(); open = false }
    // Keep the masked ID only in this composition while the user copies the Key in another app.
    fun clearBackgroundSecrets() {
        cancelCredentialAutofill()
        secretKey = ""; idVisible = false; submitted = false; controller.cancelTransient()
    }
    DisposableEffect(controller, context) {
        val owner = context as? LifecycleOwner
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) clearBackgroundSecrets()
            if (event == Lifecycle.Event.ON_START && controller.connection == null && !controller.busy) controller.retryLoad()
        }
        owner?.lifecycle?.addObserver(observer)
        onDispose { owner?.lifecycle?.removeObserver(observer); clearSecrets(); controller.cancelTransient() }
    }
    LaunchedEffect(controller.busy, controller.message) {
        if (submitted && !controller.busy && controller.connection is SavedConnection.Verified && controller.message == "云存储已连接") closeDialog()
    }
    if (mandatory) BackHandler { }
    if (!mandatory) {
        val changeCredentials = { clearSecrets(); bucket = current.bucket; region = current.region; open = true }
        val disconnect = { closeDialog(); controller.disconnect() }
        if (settingsContent != null) {
            settingsContent(changeCredentials, disconnect)
        } else {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            BrandPageTitle("云存储设置")
            if (saved is SavedConnection.Verified) Text("云存储已连接", Modifier.testTag("storageVerified"))
            Text("存储桶：${current.bucket}\n地域：${current.region}")
            BrandPrimaryButton(onClick = changeCredentials, modifier = Modifier.testTag("changeCredentials")) { Text("修改连接信息") }
            if (saved is SavedConnection.Verified) {
                TextButton(onClick = disconnect, enabled = !controller.busy, modifier = Modifier.testTag("disconnectStorage")) { Text("断开云存储") }
            }
            if (deviceId != null) Text("设备编号\n$deviceId", style = MaterialTheme.typography.bodySmall)
        }
        }
    }
    if (open || mandatory) {
        Dialog(
            onDismissRequest = { if (!mandatory) closeDialog() },
            properties = DialogProperties(dismissOnBackPress = true, dismissOnClickOutside = false, securePolicy = SecureFlagPolicy.SecureOn),
        ) {
            val dialogView = LocalView.current
            fun excludeAttachedDialogFromAutofill() {
                if (!dialogView.isAttachedToWindow) return
                val window = generateSequence(dialogView) { it.parent as? View }
                    .filterIsInstance<DialogWindowProvider>().firstOrNull()?.window ?: return
                // The DecorView is outside Compose's autofill initialization, which sets its
                // internal AndroidComposeView back to YES. Keep this root excluded on dismissal.
                window.decorView.importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
            }
            DisposableEffect(dialogView) {
                autofillManager?.cancel()
                val listener = object : View.OnAttachStateChangeListener {
                    override fun onViewAttachedToWindow(view: View) { excludeAttachedDialogFromAutofill() }
                    override fun onViewDetachedFromWindow(view: View) { }
                }
                dialogView.addOnAttachStateChangeListener(listener)
                excludeAttachedDialogFromAutofill()
                onDispose {
                    dialogView.removeOnAttachStateChangeListener(listener)
                    autofillManager?.cancel()
                }
            }
            SideEffect { excludeAttachedDialogFromAutofill() }
            // Back cannot expose the local tabs or close mandatory onboarding.
            BackHandler { if (!mandatory) closeDialog() }
            Surface(shape = RoundedCornerShape(DesignTokens.Radius.l),
                color = DesignTokens.Colors.surface, contentColor = DesignTokens.Colors.navy,
                border = BorderStroke(1.dp, DesignTokens.Colors.outline),
                modifier = Modifier.fillMaxWidth().imePadding().testTag("credentialDialog")) {
                Column(Modifier.heightIn(max = 640.dp)) {
                    Column(
                        Modifier.weight(1f, fill = false).fillMaxWidth().verticalScroll(rememberScrollState()).testTag("connectionFields").padding(24.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Text(if (mandatory) "连接云存储" else "更新云存储", style = MaterialTheme.typography.titleLarge)
                        if (saved == null) {
                            CircularProgressIndicator(); Text("正在读取安全存储…")
                        } else {
                            Text("填写同一组腾讯云密钥。爸爸和妈妈共用这组密钥，密钥只会安全保存在这台手机上。",
                                color = DesignTokens.Colors.inkSecondary, style = MaterialTheme.typography.bodySmall)
                            if (saved == SavedConnection.Locked) {
                                BrandStatusBanner("暂时无法读取安全密钥，请解锁手机后重试，或重新填写。", isError = true)
                                TextButton(onClick = { clearSecrets(); controller.retryLoad() }, enabled = !controller.busy) { Text("重新读取密钥") }
                            }
                            OutlinedTextField(bucket, { bucket = it }, label = { Text("存储桶") }, colors = brandFieldColors(), shape = RoundedCornerShape(DesignTokens.Radius.m), modifier = Modifier.fillMaxWidth().excludeAutofill().testTag("storageBucket"), singleLine = true, enabled = !controller.busy)
                            OutlinedTextField(region, { region = it }, label = { Text("地域") }, placeholder = { Text("请填写存储桶的地域代码") }, colors = brandFieldColors(), shape = RoundedCornerShape(DesignTokens.Radius.m), modifier = Modifier.fillMaxWidth().excludeAutofill().testTag("storageRegion"), singleLine = true, enabled = !controller.busy)
                            Text("记录会按照这台手机已确认的署名，分别保存到爸爸或妈妈的文件夹。")
                            OutlinedTextField(secretID, { secretID = it }, label = { Text("密钥编号") }, colors = brandFieldColors(), shape = RoundedCornerShape(DesignTokens.Radius.m), modifier = Modifier.fillMaxWidth().excludeAutofill().testTag("secretID"), singleLine = true, enabled = !controller.busy,
                                visualTransformation = if (idVisible) VisualTransformation.None else PasswordVisualTransformation(),
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                                trailingIcon = {
                                    IconButton(onClick = { idVisible = !idVisible }, enabled = !controller.busy, modifier = Modifier.testTag("toggleSecretIDVisibility")) {
                                        Icon(if (idVisible) Icons.Filled.VisibilityOff else Icons.Filled.Visibility, contentDescription = if (idVisible) "隐藏密钥编号" else "显示密钥编号")
                                    }
                                })
                            Text("各为1至1024位。密钥编号支持字母、数字、_ 和 -；密钥还支持 + / =。请勿包含空格或换行。", style = MaterialTheme.typography.bodySmall)
                            OutlinedTextField(secretKey, { secretKey = it }, label = { Text("密钥") }, colors = brandFieldColors(), shape = RoundedCornerShape(DesignTokens.Radius.m), modifier = Modifier.fillMaxWidth().excludeAutofill().testTag("secretKey"), singleLine = true, enabled = !controller.busy,
                                visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                        }
                    }
                    if (saved != null) {
                        HorizontalDivider(color = DesignTokens.Colors.separator)
                        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            val config = StorageConfiguration(bucket.trim(), region = region.trim(), prefix = prefix)
                            val valid = runCatching { config.validate() }.isSuccess &&
                                StorageCredentials.validID(secretID.trim()) && StorageCredentials.validKey(secretKey.trim())
                            BrandPrimaryButton(onClick = {
                                cancelCredentialAutofill()
                                val credentials = StorageCredentials(secretID.trim(), secretKey.trim())
                                submitted = true
                                controller.verify(config, credentials)
                                secretKey = ""; idVisible = false
                            }, enabled = !controller.busy && valid, shape = RoundedCornerShape(DesignTokens.Radius.m),
                                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("verifyContinue")) {
                                Text(if (mandatory) "验证并继续" else "验证并保存")
                            }
                            if (!mandatory) TextButton(onClick = { closeDialog() }, modifier = Modifier.testTag("cancelCredentials")) { Text("取消") }
                            if (controller.busy) { CircularProgressIndicator(); Text("正在验证云存储…") }
                            if (submitted) controller.message?.let {
                                BrandStatusBanner(chineseStorageMessage(it), isError = it != "云存储已连接", modifier = Modifier.testTag("connectionMessage"))
                            }
                        }
                    }
                }
            }
        }
    }
}

// Password keyboards add autofill semantics by default; these are cloud keys, not saved logins.
private fun Modifier.excludeAutofill(): Modifier = semantics { contentDataType = ContentDataType.None }

private fun chineseStorageMessage(message: String): String = when {
    message == "云存储已连接" -> message
    ConnectionFailure.entries.any { it.message == message } -> message
    else -> "连接失败，请检查存储桶、地域、密钥和网络后重试。"
}
