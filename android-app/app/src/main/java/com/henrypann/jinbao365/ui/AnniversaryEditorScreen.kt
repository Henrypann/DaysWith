package com.henrypann.jinbao365.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.activity.compose.BackHandler
import com.henrypann.jinbao365.data.Anniversary
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.ui.theme.DesignTokens
import java.time.LocalDate

/** Shared by the central add action and the anniversary list; no row exists until Save succeeds. */
@Composable
internal fun AnniversaryEditorScreen(initial: Anniversary?, parent: ParentIdentity?, busy: Boolean,
    onSave: (String?, String, LocalDate, () -> Unit) -> Unit, onDismiss: () -> Unit,
    onDelete: (() -> Unit)? = null) {
    var title by rememberSaveable(initial?.id) { mutableStateOf(initial?.title.orEmpty()) }
    var dateText by rememberSaveable(initial?.id) { mutableStateOf(initial?.date?.let(::countdownDateInput).orEmpty()) }
    var confirmDiscard by rememberSaveable { mutableStateOf(false) }
    var submitted by remember { mutableStateOf(false) }
    // A validation/write failure may start and finish between frames. Keep that retry editable.
    LaunchedEffect(busy, submitted) { if (!busy) submitted = false }
    val locked = busy || submitted
    val date = parseCountdownDate(dateText)
    val valid = title.isNotBlank() && title.trim().length <= 100 && date != null
    fun close() {
        if (busy || submitted) return
        if (title != initial?.title.orEmpty() || dateText != initial?.date?.let(::countdownDateInput).orEmpty()) confirmDiscard = true
        else onDismiss()
    }
    BackHandler(onBack = ::close)
    Surface(shape = RoundedCornerShape(20.dp), color = DesignTokens.Colors.cream,
        contentColor = DesignTokens.Colors.navy, modifier = Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(if (initial == null) "添加纪念日" else "编辑纪念日", style = MaterialTheme.typography.titleLarge)
                OutlinedTextField(title, { title = it }, singleLine = true, label = { Text("标题") },
                    placeholder = { Text("例如：示例生日") }, enabled = !locked,
                    isError = title.trim().length > 100,
                    supportingText = if (title.trim().length > 100) { { Text("标题请控制在 100 字以内") } } else null,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next), colors = brandFieldColors(),
                    shape = RoundedCornerShape(12.dp), modifier = Modifier.fillMaxWidth().testTag("anniversaryTitle"))
                OutlinedTextField(dateText, { dateText = it }, singleLine = true, label = { Text("日期") },
                    placeholder = { Text("例如：2020-06-01 或 06-01") }, enabled = !locked,
                    isError = dateText.isNotBlank() && date == null,
                    supportingText = { Text(if (dateText.isNotBlank() && date == null) "请输入有效日期，例如 2020-06-01 或 06-01" else "年份可不填；填了会显示第几年") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, imeAction = ImeAction.Done),
                    colors = brandFieldColors(), shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth().testTag("anniversaryDate"))
            }
            FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                if (onDelete != null) TextButton(onClick = onDelete, enabled = !locked,
                    colors = ButtonDefaults.textButtonColors(contentColor = DesignTokens.Colors.destructive),
                    modifier = Modifier.testTag("deleteAnniversary-${initial?.id}")) { Text("删除") }
                TextButton(onClick = ::close, enabled = !locked) { Text("取消") }
                TextButton(onClick = {
                    if (valid && parent != null && !busy && !submitted) {
                        submitted = true
                        onSave(initial?.id, title.trim(), requireNotNull(date)) { submitted = false; onDismiss() }
                    }
                }, enabled = valid && !locked && parent != null, modifier = Modifier.testTag("saveAnniversary")) {
                    Text(if (locked) "保存中…" else "保存")
                }
            }
        }
    }
    if (confirmDiscard) AlertDialog(onDismissRequest = { confirmDiscard = false },
        title = { Text("放弃这次填写吗？") }, text = { Text("这条纪念日尚未保存，可以返回继续填写。") },
        confirmButton = { TextButton(onClick = { confirmDiscard = false; onDismiss() },
            modifier = Modifier.testTag("discardAnniversary")) { Text("放弃填写") } },
        dismissButton = { TextButton(onClick = { confirmDiscard = false }) { Text("继续填写") } })
}
