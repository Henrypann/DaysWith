package com.henrypann.jinbao365.ui

import android.os.Handler
import android.os.Looper
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.outlined.AddPhotoAlternate
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.henrypann.jinbao365.JinbaoApplication
import com.henrypann.jinbao365.archive.ArchiveRecord
import com.henrypann.jinbao365.archive.ArchiveJson
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.archive.ArchiveValidationException
import com.henrypann.jinbao365.data.StoredDraft
import com.henrypann.jinbao365.editing.MediaRemoval
import com.henrypann.jinbao365.editing.MomentDraft
import com.henrypann.jinbao365.editing.momentDraft
import com.henrypann.jinbao365.media.AndroidImportRequests
import com.henrypann.jinbao365.media.LocationPolicy
import com.henrypann.jinbao365.media.ImportRejected
import com.henrypann.jinbao365.ui.theme.DesignTokens
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.serialization.json.*
import com.henrypann.jinbao365.media.MediaSelection
import com.henrypann.jinbao365.media.ImportOrigin
import com.henrypann.jinbao365.media.PendingMediaStatus
import com.henrypann.jinbao365.media.PendingMediaItemStatus
import com.henrypann.jinbao365.media.PendingMediaTask
import com.henrypann.jinbao365.archive.ImportProvenance
import com.henrypann.jinbao365.archive.importProvenance
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset

@Suppress("UNCHECKED_CAST")
private val MomentFormSaver = listSaver<MomentDraft, Any>(
    save = { listOf(it.title, it.note, it.occurredAtMillis, ArrayList(it.assetIds)) },
    restore = { MomentDraft(it[0] as String, it[1] as String, it[2] as Long,
        it[3] as List<String>) },
)

/** Only UI state lives here. Stage A validates and persists every edit on its process executor. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun MomentEditorScreen(
    app: JinbaoApplication,
    snapshot: ArchiveSnapshot,
    recordId: String?,
    draftId: String?,
    focusNote: Boolean,
    readOnly: Boolean,
    onClose: () -> Unit,
    onSaved: (String) -> Unit,
    onChanged: () -> Unit,
) {
    val context = LocalContext.current
    val main = remember { Handler(Looper.getMainLooper()) }
    val mediaRoot = remember(app) { File(app.filesDir, "media") }
    var form by rememberSaveable(recordId, draftId, stateSaver = MomentFormSaver) {
        mutableStateOf(MomentDraft(occurredAtMillis = System.currentTimeMillis()))
    }
    var initialized by rememberSaveable(recordId, draftId) { mutableStateOf(false) }
    var baselineFingerprint by rememberSaveable(recordId, draftId) { mutableStateOf<String?>(null) }
    var expectedRevision by rememberSaveable(recordId, draftId) { mutableStateOf<Long?>(null) }
    var storedDraft by remember(recordId, draftId) { mutableStateOf<StoredDraft?>(null) }
    var baseline by remember(recordId, draftId) { mutableStateOf<ArchiveRecord?>(null) }
    var loading by remember(recordId, draftId) { mutableStateOf(true) }
    var busy by remember(recordId, draftId) { mutableStateOf(false) }
    var error by remember(recordId, draftId) { mutableStateOf<String?>(null) }
    var conflict by remember(recordId, draftId) { mutableStateOf(false) }
    var reloadAttempt by remember { mutableIntStateOf(0) }
    var confirmReload by remember { mutableStateOf(false) }
    var confirmClose by remember { mutableStateOf(false) }
    var confirmRemove by remember { mutableStateOf<String?>(null) }
    var showDatePicker by rememberSaveable { mutableStateOf(false) }
    var showTimePicker by rememberSaveable { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val pendingRevision by app.pendingMedia.revision.collectAsState()
    var pendingTasks by remember(draftId) { mutableStateOf<List<PendingMediaTask>>(emptyList()) }
    var queueing by remember(draftId) { mutableStateOf(false) }
    var galleryOpen by rememberSaveable(draftId) { mutableStateOf(false) }
    val mediaBlocking = queueing || pendingTasks.any { it.status in setOf(PendingMediaStatus.AwaitingCapture, PendingMediaStatus.Queued, PendingMediaStatus.Importing) }
    val mediaWorking = queueing || pendingTasks.any { it.status in setOf(PendingMediaStatus.Queued, PendingMediaStatus.Importing) }
    val writable = !readOnly && !loading && !busy && !conflict && baseline != null
    val noteFocus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    var focusedNote by rememberSaveable(recordId, draftId) { mutableStateOf(false) }

    fun fingerprint(record: ArchiveRecord) = ArchiveJson.canonical(ArchiveSnapshot.empty().copy(records = listOf(record)))

    LaunchedEffect(recordId, draftId, reloadAttempt) {
        loading = true
        try {
            val loaded = withContext(Dispatchers.IO) {
                if (draftId != null) {
                    val draft = app.archive.loadDraft(draftId)
                        ?: throw ArchiveValidationException("这个草稿已不存在。")
                    draft.record to draft
                } else {
                    val record = app.archive.loadSnapshot().records.firstOrNull { it.id == recordId }
                        ?: throw ArchiveValidationException("这条记录已不存在。")
                    record to null
                }
            }
            baseline = loaded.first
            storedDraft = loaded.second
            val currentFingerprint = fingerprint(loaded.first)
            val tasks = if (draftId != null) withContext(Dispatchers.IO) { app.pendingMedia.tasksForDraft(draftId) } else emptyList()
            pendingTasks = tasks
            val ownAdvance = isReceiptedDraftAdvance(baselineFingerprint, currentFingerprint, tasks)
            val ownPersisted = initialized && isPersistedMomentMatch(baselineFingerprint, currentFingerprint, form, momentDraft(loaded.first))
            conflict = initialized && baselineFingerprint != currentFingerprint && !ownAdvance && !ownPersisted
            if (initialized && ownAdvance) {
                form = mergePreparedMoment(form, null, momentDraft(loaded.first))
                baselineFingerprint = currentFingerprint
                expectedRevision = loaded.second?.revision
            }
            if (!initialized) {
                form = momentDraft(loaded.first)
                baselineFingerprint = currentFingerprint
                expectedRevision = loaded.second?.revision
            }
            if (!conflict) {
                expectedRevision = loaded.second?.revision
            }
            if (conflict) error = "这条记录已有更新，请重新加载后再编辑。"
            initialized = true
        } catch (failure: Exception) {
            error = chineseEditorError(failure, "暂时无法加载这条记录。")
        } finally {
            loading = false
        }
    }
    LaunchedEffect(pendingRevision, initialized, busy, draftId) {
        if (draftId != null && initialized && !busy) {
            val (tasks, refreshed) = withContext(Dispatchers.IO) {
                val refreshed = app.archive.loadDraft(draftId)
                app.pendingMedia.tasksForDraft(draftId) to refreshed
            }
            pendingTasks = tasks
            if (refreshed != null && (expectedRevision == null || refreshed.revision > expectedRevision!!)) {
                val fingerprint = fingerprint(refreshed.record)
                val ownAdvance = isReceiptedDraftAdvance(baselineFingerprint, fingerprint, tasks)
                val ownPersisted = isPersistedMomentMatch(baselineFingerprint, fingerprint, form, momentDraft(refreshed.record))
                if (fingerprint == baselineFingerprint || ownAdvance || ownPersisted) {
                    val previous = baseline?.let(::momentDraft)
                    form = mergePreparedMoment(form, previous, momentDraft(refreshed.record))
                    storedDraft = refreshed; baseline = refreshed.record
                    baselineFingerprint = fingerprint; expectedRevision = refreshed.revision
                } else {
                    conflict = true
                    error = "这条记录已有更新，请重新加载后再编辑。"
                }
            }
        }
    }
    LaunchedEffect(loading, focusNote) {
        if (!loading && initialized && focusNote && !focusedNote && !readOnly) {
            focusedNote = true
            runCatching { noteFocus.requestFocus(); keyboard?.show() }
        }
    }

    fun <T> runOperation(operation: () -> T, completed: (T) -> Unit) {
        if (!writable || busy) return
        busy = true
        error = null
        app.importExecutor.execute {
            try {
                val result = operation()
                main.post { busy = false; completed(result); onChanged() }
            } catch (failure: Exception) {
                main.post {
                    busy = false
                    if (failure.message?.contains("changed. Reload") == true || isOriginalRecordConflict(failure)) conflict = true
                    error = chineseEditorError(failure, "暂时无法更新这条记录。")
                    onChanged()
                }
            }
        }
    }

    fun updateCurrentDraft(values: MomentDraft, revision: Long?): StoredDraft {
        val id = requireNotNull(draftId)
        val previousValues = baseline?.let(::momentDraft)
        val previousFingerprint = baselineFingerprint
        val timeEdited = previousValues == null || values.occurredAtMillis != previousValues.occurredAtMillis
        var updated: StoredDraft? = null
        repeat(3) { attempt ->
            if (updated == null) {
                val latest = app.archive.loadDraft(id) ?: throw ArchiveValidationException("这个草稿已不存在。")
                val currentFingerprint = fingerprint(latest.record)
                val tasks = app.pendingMedia.tasksForDraft(id)
                val ownAdvance = isReceiptedDraftAdvance(previousFingerprint, currentFingerprint, tasks)
                val ownPersisted = isPersistedMomentMatch(previousFingerprint, currentFingerprint, values, momentDraft(latest.record))
                if (latest.revision != revision && currentFingerprint != previousFingerprint && !ownAdvance && !ownPersisted)
                    throw ArchiveValidationException("This draft changed. Reload before saving.")
                try {
                    updated = app.archive.updateDraft(id, app.deviceId, System.currentTimeMillis(), expectedRevision = latest.revision) { current ->
                        if (ownAdvance) values.copy(assetIds = mergeImportedAssetOrder(values.assetIds, current.assetIds),
                            occurredAtMillis = if (timeEdited) values.occurredAtMillis else current.occurredAtMillis) else values
                    }
                } catch (failure: ArchiveValidationException) {
                    if (attempt == 2 || failure.message?.contains("changed. Reload") != true) throw failure
                }
            }
        }
        val accepted = requireNotNull(updated)
        main.post {
            if (expectedRevision != null && expectedRevision!! > accepted.revision) return@post
            storedDraft = accepted
            baseline = accepted.record
            baselineFingerprint = fingerprint(accepted.record)
            expectedRevision = accepted.revision
            form = mergePreparedMoment(form, previousValues, momentDraft(accepted.record))
        }
        return accepted
    }

    // Text writes use the same revision guard as explicit save; asset-only task completion can rebase.
    LaunchedEffect(form.title, form.note, form.occurredAtMillis, initialized, draftId, mediaBlocking, busy) {
        if (draftId != null && initialized && mediaBlocking && !readOnly && !busy && !conflict) {
            delay(400)
            val values = form
            val revision = expectedRevision
            try { withContext(Dispatchers.IO) { updateCurrentDraft(values, revision) } }
            catch (_: Exception) { /* Explicit close/save reports unresolved write failures. */ }
        }
    }

    fun updateCurrentRecord(values: MomentDraft, previous: ArchiveRecord?): ArchiveRecord {
        val updated = app.archive.editRecord(requireNotNull(recordId), app.deviceId, System.currentTimeMillis(),
            expectedRecord = previous) { original -> original.copy(title = values.title, note = values.note, occurredAtMillis = values.occurredAtMillis) }
        main.post { baseline = updated; baselineFingerprint = fingerprint(updated) }
        return updated
    }

    fun acceptDraft(draft: StoredDraft) {
        storedDraft = draft
        baseline = draft.record
        baselineFingerprint = fingerprint(draft.record)
        expectedRevision = draft.revision
        form = momentDraft(draft.record)
    }

    fun close() {
        if (busy) return
        if (readOnly || baseline == null || (draftId == null && (conflict || form == momentDraft(baseline!!)))) onClose()
        else confirmClose = true
    }

    fun discardCurrentDraft() {
        if (draftId == null || busy || readOnly) return
        busy = true
        error = null
        scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    app.pendingMedia.tasksForDraft(draftId).filter { it.status !in setOf(PendingMediaStatus.Ready, PendingMediaStatus.Cancelled) }
                        .forEach { app.pendingMedia.cancel(it.id) }
                    app.mediaImports.discardDraft(draftId)
                }
                onChanged(); onClose()
            } catch (failure: Exception) { error = chineseEditorError(failure, "暂时无法丢弃这份草稿，请再试一次。") }
            finally { busy = false }
        }
    }

    fun save() {
        if (!canSaveMoment(form) || mediaBlocking) return
        val values = form
        val revision = expectedRevision
        val previous = baseline
        runOperation({
            if (draftId != null) {
                updateCurrentDraft(values, revision)
                app.archive.commitDraft(draftId).id
            } else {
                updateCurrentRecord(values, previous).id
            }
        }, onSaved)
    }

    fun removeMedia(assetId: String, confirmed: Boolean = false) {
        val values = form
        val remaining = values.copy(assetIds = values.assetIds.filterNot { it == assetId })
        if (!confirmed && !canSaveMoment(remaining)) {
            confirmRemove = assetId
            return
        }
        val revision = expectedRevision
        val previous = baseline
        runOperation({
            if (draftId != null) {
                updateCurrentDraft(values, revision)
                val result = app.mediaImports.removeDraftMedia(draftId, assetId, confirmDiscard = confirmed)
                Triple(result, app.archive.loadDraft(draftId), null as ArchiveRecord?)
            } else {
                val id = requireNotNull(recordId)
                updateCurrentRecord(values, previous)
                val result = app.archive.removeRecordMedia(id, assetId, app.deviceId, System.currentTimeMillis())
                Triple(result, null as StoredDraft?, app.archive.loadSnapshot().records.firstOrNull { it.id == id })
            }
        }) { (result, draft, record) ->
            when (result) {
                MediaRemoval.DraftDiscarded, MediaRemoval.MovedToTrash -> onClose()
                MediaRemoval.NeedsDiscardConfirmation -> confirmRemove = assetId
                MediaRemoval.Updated -> {
                    if (draft != null) acceptDraft(draft)
                    else if (record != null) {
                        baseline = record
                        baselineFingerprint = fingerprint(record)
                        form = momentDraft(record)
                    }
                }
            }
        }
    }

    fun importPhotos(selections: List<MediaSelection>) {
        if (form.assetIds.size + selections.size > 30) { error = "每条记录最多保存30张照片或视频。"; return }
        if (draftId == null || queueing || mediaBlocking) return
        queueing = true
        scope.launch {
            try {
                val values = form
                withContext(Dispatchers.IO) {
                    updateCurrentDraft(values, expectedRevision)
                    app.pendingMedia.enqueueSelections(selections, draftId)
                }
                pendingTasks = withContext(Dispatchers.IO) { app.pendingMedia.tasksForDraft(draftId) }
            } catch (failure: Exception) { error = chineseEditorError(failure, "暂时无法准备照片，请再试一次。") }
            finally { queueing = false }
        }
    }
    val attachmentEnabled = writable && draftId != null && form.assetIds.size < 30 && !mediaBlocking
    val addPhotos: () -> Unit = { if (attachmentEnabled) galleryOpen = true }
    val addCamera = rememberMomentCamera(app, writable && draftId != null && form.assetIds.size < 30 && !mediaWorking,
        draftId = draftId,
        beforePrepare = {
            val values = form
            withContext(Dispatchers.IO) { updateCurrentDraft(values, expectedRevision) }
        },
        onDraftReady = { onChanged() }, onError = { error = it })
    fun taskAction(task: PendingMediaTask, retry: Boolean, itemId: String? = null) {
        if (!writable) return
        val values = form
        val revision = expectedRevision
        busy = true
        scope.launch {
            try {
                val stillExists = withContext(Dispatchers.IO) {
                    if (canSaveMoment(values)) updateCurrentDraft(values, revision)
                    if (itemId != null) {
                        if (retry) app.pendingMedia.retryItem(task.id, itemId) else app.pendingMedia.removeItem(task.id, itemId)
                    } else if (retry) app.pendingMedia.retry(task.id) else app.pendingMedia.cancel(task.id)
                    app.archive.loadDraft(task.draftId) != null
                }
                onChanged()
                if (!stillExists) onClose()
            } catch (failure: Exception) { error = chineseEditorError(failure, "暂时无法更新照片准备状态，请再试一次。") }
            finally { busy = false }
        }
    }
    if (galleryOpen) {
        InAppGalleryScreen(maxSelection = (30 - form.assetIds.size).coerceAtLeast(0),
            onComplete = { selections -> galleryOpen = false; importPhotos(selections) },
            onBack = { galleryOpen = false })
        return
    }
    BackHandler(onBack = ::close)

    Scaffold(
        containerColor = DesignTokens.Colors.bg,
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        topBar = {
            TopAppBar(
                title = { Text(if (recordId != null || storedDraft?.originalRecordId != null) "编辑小日常" else "记录小日常", style = MaterialTheme.typography.titleLarge) },
                navigationIcon = {
                    IconButton(onClick = ::close, enabled = !busy) { Icon(Icons.Outlined.Close, "关闭编辑") }
                },
                actions = {
                    BrandPrimaryButton(onClick = ::save, enabled = writable && !mediaBlocking && canSaveMoment(form),
                        shape = RoundedCornerShape(DesignTokens.Radius.full),
                        colors = ButtonDefaults.buttonColors(containerColor = DesignTokens.Colors.accent,
                            contentColor = DesignTokens.Colors.onAccent),
                        modifier = Modifier.padding(end = DesignTokens.Spacing.m).heightIn(min = 48.dp).testTag("saveMoment")) { Text("保存") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = DesignTokens.Colors.bg),
            )
        },
    ) { padding ->
        if (loading) Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = DesignTokens.Colors.navy)
        } else LazyColumn(
            Modifier.fillMaxSize().padding(padding).testTag("momentEditor"),
            contentPadding = PaddingValues(DesignTokens.Spacing.m),
            verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.m),
        ) {
            if (busy) item { LinearProgressIndicator(Modifier.fillMaxWidth(), color = DesignTokens.Colors.blue) }
            if (error != null) item {
                BrandStatusBanner(error!!, isError = true, modifier = Modifier.testTag("momentEditorError"))
            }
            if (mediaWorking) item {
                Column(Modifier.testTag("mediaPreparing"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    LinearProgressIndicator(Modifier.fillMaxWidth(), color = DesignTokens.Colors.blue)
                    Text("照片和视频正在准备，可以先写下想记住的话。", color = DesignTokens.Colors.inkSecondary)
                }
            }
            if (pendingTasks.any { task -> task.items.any { it.status == PendingMediaItemStatus.Degraded } }) item {
                BrandStatusBanner("部分内容已使用系统提供版本，可能不含位置信息。", modifier = Modifier.testTag("importDegradedNotice"))
            }
            pendingTasks.forEach { task ->
                task.items.filter { it.status == PendingMediaItemStatus.Failed }.forEach { failed ->
                    item(key = "failed-${failed.id}") {
                        Column(Modifier.fillMaxWidth().testTag("failedMedia-${failed.id}")) {
                            Text("第${failed.index + 1}项：${failed.errorMessage ?: "暂时无法读取，请重试或重新选择。"}",
                                color = DesignTokens.Colors.inkSecondary)
                            Row {
                                TextButton(enabled = writable && !mediaWorking, onClick = { taskAction(task, true, failed.id) }) { Text("重试这一项") }
                                TextButton(enabled = writable && !mediaWorking, onClick = { taskAction(task, false, failed.id) }) { Text("移除") }
                                TextButton(enabled = attachmentEnabled, onClick = addPhotos) { Text("重新选择") }
                            }
                        }
                    }
                }
                if (task.status == PendingMediaStatus.AwaitingCapture ||
                    (task.status == PendingMediaStatus.Failed && task.items.none { it.status == PendingMediaItemStatus.Failed })) {
                    item(key = "pending-${task.id}") {
                        Column(Modifier.fillMaxWidth().testTag("pendingMedia-${task.id}")) {
                            Text(task.errorMessage ?: "拍照尚未完成，可以继续拍摄或取消。", color = DesignTokens.Colors.inkSecondary)
                            Row {
                                TextButton(enabled = writable, onClick = { if (task.status == PendingMediaStatus.AwaitingCapture) addCamera() else taskAction(task, true) }) {
                                    Text(if (task.status == PendingMediaStatus.AwaitingCapture) "继续拍照" else "重试")
                                }
                                TextButton(enabled = writable, onClick = { taskAction(task, false) }) { Text("移除") }
                            }
                        }
                    }
                }
            }
            if (conflict) item {
                TextButton(onClick = { if (storedDraft?.originalRecordId != null) confirmClose = true else confirmReload = true },
                    colors = neutralTextButtonColors()) { Text(if (storedDraft?.originalRecordId != null) "处理这份编辑草稿" else "重新加载记录") }
            }
            if (readOnly) item { BrandStatusBanner("正在同步，暂时只能查看") }
            if (baseline != null) {
                item(key = "editor-intro") {
                    Text("平凡的日子，也是宝贵的时光。", color = DesignTokens.Colors.inkSecondary,
                        style = MaterialTheme.typography.bodySmall)
                }
                if (form.assetIds.isNotEmpty()) item {
                    val assets = (snapshot.assets + storedDraft?.assets.orEmpty()).associateBy { it.id }
                    val resources = (snapshot.resources + storedDraft?.resources.orEmpty()).associateBy { it.id }
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.s)) {
                        items(form.assetIds, key = { it }) { assetId ->
                            val owned = assets[assetId]?.resourceIds.orEmpty().mapNotNull(resources::get)
                                .filter { it.assetID == assetId }
                            val image = owned.firstOrNull { it.role in setOf("photo", "motionPhoto", "livePhotoImage") }
                                ?: owned.firstOrNull { it.role == "preview" }
                            val index = form.assetIds.indexOf(assetId)
                            Column(Modifier.width(144.dp).clip(RoundedCornerShape(DesignTokens.Radius.l))
                                .background(DesignTokens.Colors.surface)) {
                                LocalMedia(image, mediaRoot, Modifier.fillMaxWidth().height(156.dp),
                                    contentDescription = "第${index + 1}张，共${form.assetIds.size}张")
                                if (assets[assetId]?.importProvenance == ImportProvenance.SystemProvided) {
                                    Text("系统提供版本", Modifier.padding(8.dp).testTag("systemProvided-$assetId"),
                                        style = MaterialTheme.typography.labelSmall, color = DesignTokens.Colors.inkSecondary)
                                }
                                if (draftId != null) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                    IconButton(onClick = { form = moveMomentMedia(form, assetId, -1) },
                                        enabled = writable && !mediaBlocking && index > 0) {
                                        Icon(Icons.AutoMirrored.Rounded.ArrowBack, "照片前移")
                                    }
                                    IconButton(onClick = { removeMedia(assetId) }, enabled = writable && !mediaBlocking) {
                                        Icon(Icons.Outlined.Delete, "移除第${index + 1}张照片", tint = DesignTokens.Colors.destructive)
                                    }
                                    IconButton(onClick = { form = moveMomentMedia(form, assetId, 1) },
                                        enabled = writable && !mediaBlocking && index < form.assetIds.lastIndex) {
                                        Icon(Icons.AutoMirrored.Rounded.ArrowForward, "照片后移")
                                    }
                                }
                            }
                        }
                    }
                }
                if (draftId != null) item {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = addCamera, enabled = attachmentEnabled,
                            shape = RoundedCornerShape(DesignTokens.Radius.m),
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = DesignTokens.Colors.ink),
                            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("momentTakePhoto")) {
                            Icon(Icons.Outlined.PhotoCamera, null); Spacer(Modifier.width(8.dp)); Text("拍照")
                        }
                        OutlinedButton(onClick = addPhotos, enabled = attachmentEnabled,
                            shape = RoundedCornerShape(DesignTokens.Radius.m),
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = DesignTokens.Colors.ink),
                            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("momentAddPhotos")) {
                            Icon(Icons.Outlined.AddPhotoAlternate, null); Spacer(Modifier.width(8.dp))
                            Text("选照片 · ${form.assetIds.size}/30")
                        }
                    }
                }
                item {
                    OutlinedTextField(value = form.title, onValueChange = { form = form.copy(title = it) },
                        label = { Text("标题") }, placeholder = { Text("给这一天起个名字") }, singleLine = true, enabled = writable,
                        colors = brandFieldColors(), shape = RoundedCornerShape(DesignTokens.Radius.m),
                        modifier = Modifier.fillMaxWidth().testTag("momentTitle"))
                }
                item {
                    Surface(color = DesignTokens.Colors.surface, shape = RoundedCornerShape(DesignTokens.Radius.l)) {
                        Column(Modifier.fillMaxWidth().padding(DesignTokens.Spacing.m)) {
                            Text("记录时间", fontSize = DesignTokens.Typography.metaSize, color = DesignTokens.Colors.inkSecondary)
                            Text(recordDateTimeLabel(form.occurredAtMillis), Modifier.testTag("momentTime"))
                            if (!isKnownRecordTime(form.occurredAtMillis)) Text("可以修改日期，补上这条记录发生的时间。",
                                fontSize = DesignTokens.Typography.captionSize, color = DesignTokens.Colors.inkSecondary)
                            Row {
                                TextButton(enabled = writable, colors = neutralTextButtonColors(),
                                    onClick = { showDatePicker = true }) { Text("修改日期") }
                                TextButton(enabled = writable, colors = neutralTextButtonColors(),
                                    onClick = { showTimePicker = true }) { Text("修改时间") }
                            }
                        }
                    }
                }
                item {
                    OutlinedTextField(value = form.note, onValueChange = { form = form.copy(note = it) },
                        label = { Text("想记住的话") }, placeholder = { Text("今天有哪些小小的美好？") },
                        minLines = 4, enabled = writable, colors = brandFieldColors(), shape = RoundedCornerShape(DesignTokens.Radius.l),
                        modifier = Modifier.fillMaxWidth().focusRequester(noteFocus).testTag("momentNote"))
                    if (!canSaveMoment(form)) Text("添加照片、标题或文字，就可以保存这条记录。",
                        Modifier.padding(top = DesignTokens.Spacing.s), color = DesignTokens.Colors.inkSecondary,
                        fontSize = DesignTokens.Typography.captionSize)
                }
            }
        }
    }

    if (confirmClose) AlertDialog(
        onDismissRequest = { confirmClose = false }, shape = RoundedCornerShape(DesignTokens.Radius.l),
        title = { Text(if (conflict && storedDraft?.originalRecordId != null) "原记录已有更新"
            else if (storedDraft?.originalRecordId != null) "保留这次编辑吗？"
            else if (draftId != null) "保留这个草稿吗？" else "放弃这次修改吗？") },
        text = { Text(if (storedDraft?.originalRecordId != null)
            if (conflict) "编辑草稿仍已保留。丢弃后可以重新编辑原记录；原记录不会被删除。"
            else "保留后可以继续编辑。丢弃只会移除这份草稿，原记录不会改变。"
            else if (draftId != null) "以后可以从时光继续填写。" else "已保存的记录不会改变。") },
        confirmButton = {
            TextButton(enabled = !busy, colors = neutralTextButtonColors(), onClick = {
                confirmClose = false
                if (draftId == null || conflict) onClose()
                else {
                    val values = form
                    val revision = expectedRevision
                    runOperation({ updateCurrentDraft(values, revision) }) { onClose() }
                }
            }) { Text(if (draftId != null) if (conflict) "保留草稿并返回" else "保留草稿" else "放弃修改") }
        },
        dismissButton = {
            Row {
                if (draftId != null) TextButton(enabled = !busy && !readOnly, onClick = {
                    confirmClose = false
                    discardCurrentDraft()
                }) { Text("丢弃草稿", color = DesignTokens.Colors.destructive) }
                TextButton(onClick = { confirmClose = false }, colors = neutralTextButtonColors()) { Text("继续编辑") }
            }
        },
    )
    if (confirmReload) AlertDialog(
        onDismissRequest = { confirmReload = false }, shape = RoundedCornerShape(DesignTokens.Radius.l),
        title = { Text("重新加载这条记录吗？") }, text = { Text("尚未保存的修改会被最新内容替换。") },
        confirmButton = { TextButton(onClick = {
            confirmReload = false
            initialized = false
            conflict = false
            error = null
            reloadAttempt++
        }, colors = neutralTextButtonColors()) { Text("重新加载") } },
        dismissButton = { TextButton(onClick = { confirmReload = false }, colors = neutralTextButtonColors()) { Text("取消") } },
    )
    if (showDatePicker) {
        val original = Instant.ofEpochMilli(form.occurredAtMillis).atZone(ZoneId.systemDefault())
        val pickerDate = original.toLocalDate().withYear(original.year.coerceIn(1980, 9999))
        val pickerState = rememberDatePickerState(initialSelectedDateMillis = pickerDate
            .atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(), yearRange = 1980..9999)
        DatePickerDialog(onDismissRequest = { showDatePicker = false }, shape = RoundedCornerShape(DesignTokens.Radius.l),
            confirmButton = { TextButton(enabled = writable && pickerState.selectedDateMillis != null, onClick = {
                pickerState.selectedDateMillis?.let {
                    val date = Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate()
                    val chosen = date.atTime(original.toLocalTime()).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
                    if (chosen < java.time.LocalDate.of(1980, 1, 2).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()) error = "请选择1980年1月2日或之后的日期。"
                    else form = form.copy(occurredAtMillis = chosen)
                }
                showDatePicker = false
            }, colors = neutralTextButtonColors()) { Text("完成") } },
            dismissButton = { TextButton(onClick = { showDatePicker = false }, colors = neutralTextButtonColors()) { Text("取消") } },
        ) { DatePicker(state = pickerState, colors = DatePickerDefaults.colors(todayContentColor = DesignTokens.Colors.accentText)) }
    }
    if (showTimePicker) {
        val original = Instant.ofEpochMilli(form.occurredAtMillis).atZone(ZoneId.systemDefault())
        val pickerState = rememberTimePickerState(initialHour = original.hour, initialMinute = original.minute,
            is24Hour = true)
        AlertDialog(onDismissRequest = { showTimePicker = false }, shape = RoundedCornerShape(DesignTokens.Radius.l),
            title = { Text("修改时间") }, text = { TimeInput(state = pickerState) },
            confirmButton = { TextButton(enabled = writable, onClick = {
                val chosen = original.withHour(pickerState.hour).withMinute(pickerState.minute)
                    .withSecond(0).withNano(0).toInstant().toEpochMilli()
                if (chosen < java.time.LocalDate.of(1980, 1, 2).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()) error = "请选择1980年1月2日或之后的日期。"
                else form = form.copy(occurredAtMillis = chosen)
                showTimePicker = false
            }, colors = neutralTextButtonColors()) { Text("完成") } },
            dismissButton = { TextButton(onClick = { showTimePicker = false }, colors = neutralTextButtonColors()) { Text("取消") } },
        )
    }
    confirmRemove?.let { assetId ->
        AlertDialog(onDismissRequest = { confirmRemove = null }, shape = RoundedCornerShape(DesignTokens.Radius.l),
            title = { Text(if (draftId != null) "丢弃这个空草稿吗？" else "移除这条空记录吗？") },
            text = { Text(if (draftId != null) "移除最后一张照片后，将没有可以保存的内容。"
                else "移除最后一张照片后，将没有可以保存的内容。") },
            confirmButton = { TextButton(enabled = writable, onClick = { confirmRemove = null; removeMedia(assetId, true) }) {
                Text(if (draftId != null) "丢弃草稿" else "移除记录", color = DesignTokens.Colors.destructive)
            } },
            dismissButton = { TextButton(onClick = { confirmRemove = null }, colors = neutralTextButtonColors()) { Text("取消") } })
    }
}

private fun chineseEditorError(failure: Exception, fallback: String): String {
    logArchiveFailure("Could not edit record", failure)
    return when {
        failure is ImportRejected -> failure.message ?: fallback
        isOriginalRecordConflict(failure) -> "原记录已有更新，编辑草稿已保留。请处理这份编辑草稿：保留并返回，或丢弃后重新编辑原记录。"
        else -> fallback
    }
}

/** Async asset completion updates media while preserving fields the person has already edited. */
internal fun mergePreparedMoment(current: MomentDraft, previous: MomentDraft?, prepared: MomentDraft): MomentDraft =
    current.copy(
        title = if (previous != null && current.title == previous.title) prepared.title else current.title,
        note = if (previous != null && current.note == previous.note) prepared.note else current.note,
        occurredAtMillis = if (previous != null && current.occurredAtMillis == previous.occurredAtMillis) prepared.occurredAtMillis else current.occurredAtMillis,
        assetIds = mergeImportedAssetOrder(current.assetIds, prepared.assetIds),
    )

/** Only a new media receipt can authorize rebasing asset IDs and the first automatic capture time. */
internal fun isPreparedDraftAdvance(beforeFingerprint: String?, afterFingerprint: String): Boolean = runCatching {
    if (beforeFingerprint == null) return@runCatching false
    val before = Json.parseToJsonElement(beforeFingerprint).jsonObject["records"]!!.jsonArray.single().jsonObject
    val after = Json.parseToJsonElement(afterFingerprint).jsonObject["records"]!!.jsonArray.single().jsonObject
    val oldIds = before["assetIDs"]!!.jsonObject["value"]!!.jsonArray.map { it.jsonPrimitive.content }
    val newIds = after["assetIDs"]!!.jsonObject["value"]!!.jsonArray.map { it.jsonPrimitive.content }
    if (newIds.size <= oldIds.size || !newIds.containsAll(oldIds)) return@runCatching false
    val automaticFirstTime = oldIds.isEmpty() &&
        before["occurredAt"]!!.jsonObject["edit"]!!.jsonObject["counter"]!!.jsonPrimitive.longOrNull == 1L
    val ignored = if (automaticFirstTime) setOf("assetIDs", "occurredAt", "mediaOverflow") else setOf("assetIDs", "mediaOverflow")
    before.filterKeys { it !in ignored } == after.filterKeys { it !in ignored }
}.getOrDefault(false)

/** A finishing autosave from the destroyed composition may already contain the restored form. */
internal fun isPersistedMomentMatch(beforeFingerprint: String?, afterFingerprint: String,
    current: MomentDraft, persisted: MomentDraft): Boolean = runCatching {
    if (beforeFingerprint == null || current != persisted) return@runCatching false
    val before = Json.parseToJsonElement(beforeFingerprint).jsonObject["records"]!!.jsonArray.single().jsonObject
    val after = Json.parseToJsonElement(afterFingerprint).jsonObject["records"]!!.jsonArray.single().jsonObject
    val formFields = setOf("title", "note", "occurredAt")
    before.filterKeys { it !in formFields } == after.filterKeys { it !in formFields }
}.getOrDefault(false)

private fun isOriginalRecordConflict(failure: Exception): Boolean = failure is ArchiveValidationException &&
    failure.message == "这条记录已发生变化，草稿仍已保留。请重新打开记录后再编辑。"

/** Keep deliberate ordering of existing media, inserting arriving items at their selected position. */
internal fun mergeImportedAssetOrder(current: List<String>, prepared: List<String>): List<String> {
    val result = current.filter { it in prepared }.distinct().toMutableList()
    prepared.forEachIndexed { index, id ->
        if (id !in result) {
            val next = prepared.drop(index + 1).firstOrNull { it in result }
            val previous = prepared.take(index).lastOrNull { it in result }
            val insertion = next?.let(result::indexOf) ?: previous?.let { result.indexOf(it) + 1 } ?: result.size
            result.add(insertion, id)
        }
    }
    return result
}

/** Successful per-item receipts authorize an asynchronous media addition, never a progress counter. */
internal fun isReceiptedDraftAdvance(before: String?, after: String, tasks: List<PendingMediaTask>): Boolean {
    if (!isPreparedDraftAdvance(before, after)) return false
    fun ids(fingerprint: String) = Json.parseToJsonElement(fingerprint).jsonObject["records"]!!
        .jsonArray.single().jsonObject["assetIDs"]!!.jsonObject["value"]!!.jsonArray.map { it.jsonPrimitive.content }.toSet()
    val added = ids(after) - ids(requireNotNull(before))
    val receipts = tasks.flatMap { it.items }.filter {
        it.status in setOf(PendingMediaItemStatus.Success, PendingMediaItemStatus.Degraded)
    }.mapNotNull { it.assetId }.toSet()
    return added.isNotEmpty() && receipts.containsAll(added)
}
