package com.henrypann.jinbao365.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AutoStories
import androidx.compose.material.icons.outlined.Celebration
import androidx.compose.material.icons.outlined.EditNote
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material.icons.outlined.PersonOutline
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.AutoStories as RoundedAutoStories
import androidx.compose.material.icons.rounded.Celebration as RoundedCelebration
import androidx.compose.material.icons.rounded.PersonOutline as RoundedPersonOutline
import androidx.compose.material.icons.rounded.PhotoLibrary as RoundedPhotoLibrary
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import com.henrypann.jinbao365.JinbaoApplication
import com.henrypann.jinbao365.editing.momentDraft
import com.henrypann.jinbao365.media.LocationPolicy
import com.henrypann.jinbao365.storage.StorageConnectionController
import com.henrypann.jinbao365.ui.theme.DesignTokens
import com.henrypann.jinbao365.viewing.DevicePartnerOriginals
import java.io.File
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import kotlin.math.roundToInt
import com.henrypann.jinbao365.media.MediaSelection
import com.henrypann.jinbao365.media.ImportOrigin

/** Four destinations with the independent add action in the center. Keep names for saved-state compatibility. */
internal enum class MainTab(val label: String, val tag: String) {
    Timeline("时光", "tabTimeline"), Countdown("纪念", "tabCountdown"),
    Review("回顾", "tabReview"), Settings("我的", "tabSettings")
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun AppShell(controller: StorageConnectionController, tab: MainTab, onSelectTab: (MainTab) -> Unit,
    localPreview: Boolean = false) {
    val context = LocalContext.current
    val app = context.applicationContext as JinbaoApplication
    val archive = app.archiveUi
    val snapshot = archive.snapshot
    val ownSnapshot = archive.ownSnapshot
    val backup = app.backup
    val runtime by backup.coordinator.observableState.collectAsState()
    val nowMillis by produceState(System.currentTimeMillis()) {
        while (true) { delay(30_000); value = System.currentTimeMillis() }
    }
    val backupSummary = remember(ownSnapshot, archive.ownAnniversaries, runtime, nowMillis) {
        ownSnapshot?.let { backup.statusQuery.query(it, runtime.state, nowMillis, runtime,
            anniversaries = archive.ownAnniversaries) }
    }
    val mediaRoot = remember(app) { File(app.filesDir, "media") }
    val originals = remember(mediaRoot) { DevicePartnerOriginals(context, mediaRoot) }
    var allowCellularOriginals by remember { mutableStateOf(originals.preference.allow()) }
    val originalDownloader = remember(originals) { originals.downloader() }
    var detailId by rememberSaveable { mutableStateOf<String?>(null) }
    var editorRecordId by rememberSaveable { mutableStateOf<String?>(null) }
    var editorDraftId by rememberSaveable { mutableStateOf<String?>(null) }
    var focusNote by rememberSaveable { mutableStateOf(false) }
    var settingsOpen by rememberSaveable { mutableStateOf(false) }
    var trashOpen by rememberSaveable { mutableStateOf(false) }
    var openBackup by rememberSaveable { mutableStateOf(false) }
    var anniversaryEditing by remember { mutableStateOf(false) }
    var selectingMedia by remember { mutableStateOf(false) }
    var galleryOpen by rememberSaveable { mutableStateOf(false) }
    var importStarting by remember { mutableStateOf(false) }
    val importScope = rememberCoroutineScope()
    val pendingRevision by app.pendingMedia.revision.collectAsState()
    LaunchedEffect(pendingRevision) { archive.refresh() }
    val tabState = rememberSaveableStateHolder()
    val editing = editorDraftId != null || editorRecordId != null
    val keyboardVisible = WindowInsets.isImeVisible
    val canAdd = !archive.readOnly && !archive.busy && !archive.loading && snapshot != null && !importStarting
    fun openDraft(id: String) { editorDraftId = id; editorRecordId = null; focusNote = false; archive.refresh() }
    fun editRecordAsDraft(id: String) {
        if (!archive.canEdit(id) || importStarting) return
        importStarting = true
        importScope.launch {
            try {
                val draft = withContext(Dispatchers.IO) { app.archive.createEditDraft(id) }
                openDraft(draft.record.id)
            } catch (_: Exception) { archive.showError("暂时无法打开编辑，请稍后再试。") }
            finally { importStarting = false }
        }
    }
    fun importSelection(selections: List<MediaSelection>) {
        importStarting = true
        importScope.launch {
            try {
                val task = withContext(Dispatchers.IO) { app.pendingMedia.enqueueSelections(selections) }
                openDraft(task.draftId)
            } catch (_: Exception) { archive.showError("暂时无法准备这些照片和视频，请稍后再试。") }
            finally { importStarting = false }
        }
    }
    val launchCamera = rememberMomentCamera(app, canAdd, onDraftReady = ::openDraft,
        onError = archive::showError, onActiveChanged = { selectingMedia = it })
    val launchPhotos: () -> Unit = { if (canAdd) galleryOpen = true }
    val launchDocuments = rememberMomentDocumentPicker(enabled = canAdd,
        onPicked = { importSelection(it.map { uri -> MediaSelection(uri, ImportOrigin.Document) }) }, onError = archive::showError,
        onActiveChanged = { selectingMedia = it })

    DisposableEffect(context, archive) {
        val owner = context as? LifecycleOwner
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) archive.refresh() }
        owner?.lifecycle?.addObserver(observer)
        onDispose { owner?.lifecycle?.removeObserver(observer) }
    }
    LaunchedEffect(archive.readyDraftId) {
        archive.readyDraftId?.let {
            editorDraftId = it; editorRecordId = null; focusNote = archive.focusNote; archive.consumeDraft()
        }
    }
    fun closeEditor() { editorDraftId = null; editorRecordId = null; archive.refresh() }
    BackHandler(!galleryOpen && !editing && (detailId != null || tab != MainTab.Timeline)) {
        if (detailId != null) detailId = null
        else if (trashOpen) trashOpen = false
        else if (settingsOpen) settingsOpen = false
        else onSelectTab(MainTab.Timeline)
    }
    val showBottomBar = !galleryOpen && !keyboardVisible && !editing && detailId == null && !settingsOpen && !anniversaryEditing
    val bottomBarHeight = brandBottomBarHeight()
    Scaffold(containerColor = DesignTokens.Colors.bg, contentWindowInsets = WindowInsets(0, 0, 0, 0)) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).statusBarsPadding().navigationBarsPadding().imePadding()) {
            Column(Modifier.fillMaxSize().padding(bottom = if (showBottomBar) bottomBarHeight else 0.dp)) {
                if (backupSummary?.inProgress == true) {
                    BrandStatusBanner(backupProgressText(backupSummary), modifier = Modifier.testTag("backupProgressBanner"))
                }
                if (backupSummary?.hasFailure == true) {
                    TextButton(onClick = backup.coordinator::backUpNow,
                        modifier = Modifier.fillMaxWidth().testTag("backupRetryBanner"),
                        colors = ButtonDefaults.textButtonColors(contentColor = DesignTokens.Colors.problem)) {
                        Text(BACKUP_RETRY_MESSAGE, fontSize = DesignTokens.Typography.metaSize)
                    }
                }
                if (archive.readOnly) BrandStatusBanner("正在同步，这会儿先看看记录吧", modifier = Modifier.testTag("readOnlyBanner"))
                archive.remoteError?.let { message ->
                    TextButton(onClick = {
                        archive.refreshRemote()
                        if (message == BACKUP_RETRY_MESSAGE) backup.coordinator.backUpNow()
                    }, colors = neutralTextButtonColors(),
                        modifier = Modifier.fillMaxWidth().testTag("remoteRefreshNotice")) {
                        Text(if (message == BACKUP_RETRY_MESSAGE) message else "$message 轻点重试",
                            fontSize = DesignTokens.Typography.metaSize)
                    }
                }
                if (archive.busy) LinearProgressIndicator(Modifier.fillMaxWidth(), color = DesignTokens.Colors.blue)
                when {
                    galleryOpen -> InAppGalleryScreen(maxSelection = 30,
                        onComplete = { selections -> galleryOpen = false; importSelection(selections) },
                        onBack = { galleryOpen = false })
                    snapshot == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        if (archive.loading) CircularProgressIndicator(color = DesignTokens.Colors.accent)
                        else Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            BrandEmptyState("暂时没能打开本地记录", "轻点重试，继续收藏美好。", BrandIllustration.Quiet)
                            BrandPrimaryButton(onClick = archive::refresh) { Text("再试一次") }
                        }
                    }
                    editing -> MomentEditorScreen(
                        app = app, snapshot = snapshot, recordId = editorRecordId, draftId = editorDraftId,
                        focusNote = focusNote, readOnly = archive.readOnly || (editorRecordId?.let { !archive.canEdit(it) } == true),
                        onClose = ::closeEditor, onSaved = { id -> closeEditor(); detailId = id }, onChanged = archive::refresh)
                    detailId != null -> MomentDetailScreen(
                        snapshot = snapshot, recordId = detailId!!, mediaRoot = mediaRoot,
                        readOnly = archive.readOnly || !archive.canEdit(detailId!!), busy = archive.busy,
                        backupSummary = backupSummary.takeIf { archive.canEdit(detailId!!) },
                        onBack = { detailId = null }, onEdit = ::editRecordAsDraft,
                        onTrash = { id -> archive.setTrashed(id, restore = false) { detailId = null } },
                        onRestore = { id -> archive.setTrashed(id, restore = true) {} }, parent = archive.parentOf(detailId!!),
                        onRetryBackup = backup.coordinator::backUpNow,
                        originals = originalDownloader, allowCellularOriginals = allowCellularOriginals)
                    settingsOpen && trashOpen -> TrashScreen(ownSnapshot ?: snapshot, busy = archive.busy || archive.readOnly,
                        canRestore = archive::canEdit, onOpen = { detailId = it },
                        onRestore = { id -> archive.setTrashed(id, restore = true) {} }, onBack = { trashOpen = false })
                    settingsOpen -> SettingsScreen(
                        controller, app.deviceId, mediaRoot, ownSnapshot ?: snapshot, archive.syncState,
                        onOpenTrash = { trashOpen = true }, backupSummary = requireNotNull(backupSummary), backupConfiguration = runtime.configuration,
                        onBackUpNow = backup.coordinator::backUpNow, onPauseBackup = backup.coordinator::pause,
                        onRetryFailed = backup.coordinator::retryFailed,
                        parent = app.parentIdentity, backupError = runtime.lastError, onBack = { settingsOpen = false }, showBack = true,
                        openCloudStorage = openBackup, onCloudStorageOpened = { openBackup = false },
                        onImportFiles = launchDocuments, canImportFiles = canAdd && !selectingMedia,
                    )
                    else -> tabState.SaveableStateProvider(tab.name) {
                        when (tab) {
                            MainTab.Countdown -> AnniversariesScreen(archive.anniversaries, app.parentIdentity,
                                busy = archive.busy || archive.readOnly,
                                onSave = archive::saveAnniversary, onDelete = archive::deleteAnniversary,
                                onBack = { onSelectTab(MainTab.Timeline) },
                                onEditingChanged = { anniversaryEditing = it })
                            MainTab.Review -> ReviewScreen(snapshot, mediaRoot, { detailId = it }, archive::parentOf,
                                onOpenTimeline = { onSelectTab(MainTab.Timeline) })
                            MainTab.Settings -> MyScreen(snapshot, app.parentIdentity,
                                if (localPreview) "测试版 · 仅本机保存" else backupSummary?.let(::backupStatusText) ?: "正在读取备份状态",
                                archive.drafts.size, onOpenArchive = { onSelectTab(MainTab.Timeline) },
                                onOpenBackup = { settingsOpen = true; openBackup = true },
                                onOpenSettings = { settingsOpen = true; openBackup = false }, backupSummary = backupSummary,
                                allowCellularOriginals = allowCellularOriginals,
                                onAllowCellularOriginals = { enabled ->
                                    allowCellularOriginals = enabled
                                    originals.preference.setAllow(enabled)
                                })
                            MainTab.Timeline -> Column {
                                if (archive.drafts.isNotEmpty()) LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    items(archive.drafts, key = { it.record.id }) { draft ->
                                        TextButton(onClick = { editorDraftId = draft.record.id; focusNote = false }, enabled = canAdd,
                                            colors = neutralTextButtonColors()) {
                                            Text("继续草稿 · ${momentDraft(draft.record).title.ifBlank { "未命名记录" }}", maxLines = 1)
                                        }
                                    }
                                }
                                TimelineScreen(snapshot, archive.readOnly, mediaRoot, { detailId = it }, launchPhotos,
                                    busy = archive.busy || selectingMedia, backupSummary = backupSummary.takeUnless { localPreview },
                                    onOpenBackup = backup.coordinator::backUpNow,
                                    parentOf = archive::parentOf, anniversaries = archive.anniversaries,
                                    onOpenAnniversaries = { onSelectTab(MainTab.Countdown) })
                            }
                        }
                    }
                }
            }
            if (showBottomBar) {
                MainBottomBar(tab, onSelectTab, Modifier.align(Alignment.BottomCenter)) {
                    AddMomentButton(canAdd && !selectingMedia, launchCamera, launchPhotos,
                        { archive.createMoment() }, Modifier, size = 56.dp)
                }
            }
        }
    }
    archive.error?.let { message ->
        AlertDialog(onDismissRequest = archive::dismissError, shape = RoundedCornerShape(DesignTokens.Radius.l), title = { Text("这次没有完成") }, text = { Text(message) },
            confirmButton = { TextButton(onClick = archive::dismissError, colors = neutralTextButtonColors()) { Text("知道了") } },
            dismissButton = {
                if (message in LocationPolicy.SETTINGS_FIXABLE) TextButton(modifier = Modifier.testTag("errorOpenSettings"),
                    onClick = { archive.dismissError(); runCatching { openAppSettings(context) } }) { Text("去设置开启") }
            })
    }
}

/** Capsule plus the 12dp bottom margin and room for the center button to rise above it. */
@Composable
private fun brandBottomBarHeight() = 88.dp + (32f * (LocalDensity.current.fontScale - 1f).coerceAtLeast(0f)).dp

private val BottomBarCapsuleShape = RoundedCornerShape(32.dp)
private val BottomBarItemShape = RoundedCornerShape(24.dp)
private val BottomBarWhite = DesignTokens.Colors.surface
/** #0000000F read as RRGGBBAA: black at 15/255 alpha. */
private val BottomBarStroke = Color(0x0F000000)
private val BottomBarShadowAmbient = Color.Black.copy(alpha = 0.06f)
private val BottomBarShadowSpot = Color.Black.copy(alpha = 0.10f)
private val BottomBarSelectedFill = DesignTokens.Colors.accentSoft
private val BottomBarSelectedContent = DesignTokens.Colors.ink
private val BottomBarUnselectedIcon = DesignTokens.Colors.outline
private val BottomBarUnselectedLabel = DesignTokens.Colors.inkSecondary
private val BottomBarAddGold = DesignTokens.Colors.accent
private const val BottomBarIconOnlyFontScale = 1.6f

private fun Modifier.bottomBarShadow(shape: Shape) = shadow(
    12.dp,
    shape,
    ambientColor = BottomBarShadowAmbient,
    spotColor = BottomBarShadowSpot,
)

@Composable
internal fun MainBottomBar(tab: MainTab, onSelectTab: (MainTab) -> Unit, modifier: Modifier, add: @Composable () -> Unit) {
    val iconOnly = LocalDensity.current.fontScale >= BottomBarIconOnlyFontScale
    Box(
        modifier
            .fillMaxWidth()
            .height(brandBottomBarHeight())
            .testTag("bottomBar")
            .padding(horizontal = 16.dp)
            .padding(bottom = 12.dp),
    ) {
        Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().heightIn(min = 64.dp)) {
            Box(
                Modifier
                    .matchParentSize()
                    .bottomBarShadow(BottomBarCapsuleShape)
                    .background(BottomBarWhite, BottomBarCapsuleShape)
                    .border(0.5.dp, BottomBarStroke, BottomBarCapsuleShape),
            )
            Row(
                Modifier.align(Alignment.Center).fillMaxWidth().padding(horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                MainTab.entries.forEachIndexed { index, item ->
                    if (index == 2) Spacer(Modifier.weight(1f))
                    BottomDestination(item, item == tab, iconOnly) { onSelectTab(item) }
                }
            }
            Box(Modifier.align(Alignment.Center).offset(y = (-8).dp)) { add() }
        }
    }
}

@Composable
private fun RowScope.BottomDestination(item: MainTab, selected: Boolean, iconOnly: Boolean, onSelect: () -> Unit) {
    val fill by animateColorAsState(
        if (selected) BottomBarSelectedFill else Color.Transparent,
        tween(150),
        label = "bottomTabFill",
    )
    val iconTint by animateColorAsState(
        if (selected) BottomBarSelectedContent else BottomBarUnselectedIcon,
        tween(150),
        label = "bottomTabIcon",
    )
    val labelColor by animateColorAsState(
        if (selected) BottomBarSelectedContent else BottomBarUnselectedLabel,
        tween(150),
        label = "bottomTabLabel",
    )
    Column(
        Modifier
            .weight(1f)
            .padding(horizontal = 2.dp)
            .heightIn(min = 48.dp)
            .clip(BottomBarItemShape)
            .background(fill)
            .clickable(role = Role.Tab, onClick = onSelect)
            .semantics { this.selected = selected }
            .testTag(item.tag),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            item.barIcon(selected),
            contentDescription = if (iconOnly) item.label else null,
            modifier = Modifier.size(24.dp),
            tint = iconTint,
        )
        if (!iconOnly) {
            Text(
                item.label,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                color = labelColor,
                maxLines = 1,
                softWrap = false,
            )
        }
    }
}

private fun MainTab.barIcon(selected: Boolean): ImageVector = when (this) {
    MainTab.Timeline -> if (selected) Icons.Rounded.RoundedPhotoLibrary else Icons.Outlined.PhotoLibrary
    MainTab.Countdown -> if (selected) Icons.Rounded.RoundedCelebration else Icons.Outlined.Celebration
    MainTab.Review -> if (selected) Icons.Rounded.RoundedAutoStories else Icons.Outlined.AutoStories
    MainTab.Settings -> if (selected) Icons.Rounded.RoundedPersonOutline else Icons.Outlined.PersonOutline
}

@Composable
internal fun neutralTextButtonColors() = ButtonDefaults.textButtonColors(contentColor = DesignTokens.Colors.ink)

/** Full-width popup is positioned above the raised add button and navigation capsule. */
@Composable
internal fun AddMomentButton(enabled: Boolean, onCamera: () -> Unit, onPhotos: () -> Unit, onNote: () -> Unit,
    modifier: Modifier, initiallyExpanded: Boolean = false, size: androidx.compose.ui.unit.Dp = 72.dp) {
    var menu by remember { mutableStateOf(initiallyExpanded) }
    LaunchedEffect(enabled) { if (!enabled) menu = false }
    BackHandler(menu) { menu = false }
    val density = LocalDensity.current
    val margin = with(density) { (16.dp + (32f * (fontScale - 1f).coerceAtLeast(0f)).dp).roundToPx() }
    val topMargin = with(density) { 16.dp.roundToPx() }
    var anchorTop by remember { mutableIntStateOf(0) }
    val menuHeight = with(density) { (anchorTop - margin - 16.dp.roundToPx()).coerceAtLeast(1).toDp() }
    val position = remember(margin, topMargin) { object : PopupPositionProvider {
        override fun calculatePosition(anchorBounds: IntRect, windowSize: IntSize, layoutDirection: LayoutDirection,
            popupContentSize: IntSize): IntOffset = IntOffset(
                (windowSize.width - popupContentSize.width) / 2,
                (anchorBounds.top - popupContentSize.height - margin).coerceAtLeast(topMargin))
    } }
    Box(modifier) {
        Box(Modifier.size(size).onGloballyPositioned { anchorTop = it.boundsInWindow().top.roundToInt() }.bottomBarShadow(CircleShape)
            .background(if (enabled) BottomBarAddGold else DesignTokens.Colors.separator, CircleShape)
            .clickable(enabled = enabled, role = Role.Button) { menu = !menu }
            .semantics { if (!enabled) disabled() }.testTag("addMoment"), contentAlignment = Alignment.Center) {
            Icon(Icons.Rounded.Add, "添加记录", modifier = Modifier.size(28.dp), tint = BottomBarSelectedContent)
        }
        if (menu && enabled) Popup(popupPositionProvider = position, onDismissRequest = { menu = false },
            properties = PopupProperties(focusable = true, dismissOnBackPress = true, dismissOnClickOutside = true)) {
            BoxWithConstraints(Modifier.fillMaxWidth().pointerInput(Unit) { detectTapGestures { menu = false } }) {
            Surface(modifier = Modifier.padding(horizontal = 16.dp).width((maxWidth - 32.dp).coerceAtLeast(0.dp)).heightIn(max = menuHeight).testTag("addMomentMenu"),
                shape = RoundedCornerShape(DesignTokens.Radius.l), color = DesignTokens.Colors.surface,
                shadowElevation = 8.dp) {
                Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(vertical = 8.dp)) {
                    AddMomentMenuRow("拍照", "addCameraMenuAction", Icons.Outlined.PhotoCamera) { if (menu && enabled) { menu = false; onCamera() } }
                    AddMomentMenuRow("选照片", "addPhotosMenuAction", Icons.Outlined.PhotoLibrary) { if (menu && enabled) { menu = false; onPhotos() } }
                    AddMomentMenuRow("写文字", "addNoteMenuAction", Icons.Outlined.EditNote) { if (menu && enabled) { menu = false; onNote() } }
                }
            }
            }
        }
    }
}

@Composable
private fun AddMomentMenuRow(label: String, tag: String, icon: ImageVector, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(role = Role.Button, onClick = onClick)
        .testTag(tag).padding(horizontal = 20.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Icon(icon, null, Modifier.size(24.dp), tint = DesignTokens.Colors.ink)
        Text(label, style = MaterialTheme.typography.bodyLarge, color = DesignTokens.Colors.ink)
    }
}
