package com.henrypann.jinbao365.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Videocam
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import com.henrypann.jinbao365.gallery.*
import com.henrypann.jinbao365.media.ImportOrigin
import com.henrypann.jinbao365.media.MediaSelection
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

private val GallerySelectionSaver = Saver<List<MediaSelection>, ArrayList<String>>(
    save = { ArrayList(it.flatMap { item -> listOf(item.uri.toString(), item.origin.name) }) },
    restore = { it.chunked(2).mapNotNull { pair ->
        if (pair.size != 2) null else runCatching { MediaSelection(Uri.parse(pair[0]), ImportOrigin.valueOf(pair[1])) }.getOrNull()
    } },
)

/** Only this screen owns browsing; import starts after the explicit completion callback. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun InAppGalleryScreen(
    maxSelection: Int,
    onComplete: (List<MediaSelection>) -> Unit,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val repository = remember(context) { GalleryRepository(context) }
    val snackbar = remember { SnackbarHostState() }
    val grid = rememberLazyGridState()
    val limit = maxSelection.coerceIn(0, 30)
    var selected by rememberSaveable(stateSaver = GallerySelectionSaver) { mutableStateOf(emptyList<MediaSelection>()) }
    var extras by rememberSaveable(stateSaver = GallerySelectionSaver) { mutableStateOf(emptyList<MediaSelection>()) }
    var externalMedia by remember { mutableStateOf(emptyList<GalleryMedia>()) }
    var previewUri by rememberSaveable { mutableStateOf<String?>(null) }
    var permissionRevision by remember { mutableIntStateOf(0) }
    val permissionPreferences = remember(context) { context.getSharedPreferences("gallery-permissions", Context.MODE_PRIVATE) }
    var asked by rememberSaveable { mutableStateOf(permissionPreferences.getBoolean("asked", false)) }
    var more by remember { mutableStateOf(false) }
    var unreadableSelections by remember { mutableStateOf(emptySet<Uri>()) }
    var loading by remember { mutableStateOf(false) }
    var queryFailed by remember { mutableStateOf(false) }
    var items by remember { mutableStateOf(emptyList<GalleryMedia>()) }
    var next by remember { mutableStateOf<GalleryPageKey?>(GalleryPageKey()) }
    var queryJob by remember { mutableStateOf<Job?>(null) }
    var generation by remember { mutableIntStateOf(0) }
    val permission = remember(permissionRevision) {
        galleryPermissions(Build.VERSION.SDK_INT) { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED }
    }
    fun message(text: String) { scope.launch { snackbar.showSnackbar(text) } }
    fun choose(item: MediaSelection) {
        val update = toggleGallerySelection(selected, item, limit)
        selected = update.selected
        if (update.overflow > 0) message("本次最多还能选择 $limit 项照片或视频。")
    }
    fun receive(uris: List<Uri>, origin: ImportOrigin) {
        val additions = uris.distinct().map { MediaSelection(it, origin) }
        if (additions.isEmpty()) return
        additions.forEach { selection ->
            runCatching { context.contentResolver.takePersistableUriPermission(selection.uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        }
        extras = (extras + additions).distinctBy { it.uri.toString() }
        val update = appendGallerySelection(selected, additions, limit)
        selected = update.selected
        if (update.overflow > 0) message("已加入可选的项目；超过 $limit 项的 ${update.overflow} 项未勾选。")
    }
    val systemPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(30)) {
        receive(it, ImportOrigin.PhotoPicker)
    }
    val documentPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) {
        receive(it, ImportOrigin.Document)
    }
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        permissionRevision++
    }
    fun requestPermissions() {
        asked = true
        permissionPreferences.edit().putBoolean("asked", true).apply()
        runCatching { permissionLauncher.launch(galleryPermissionRequest(Build.VERSION.SDK_INT).toTypedArray()) }
            .onFailure { message("暂时无法申请权限，请通过系统设置开启。") }
    }
    fun openSettings() {
        runCatching {
            context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", context.packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.onFailure { message("无法打开设置，请在手机设置中找到DaysWith。") }
    }
    DisposableEffect(context) {
        val owner = context.galleryActivity() as? LifecycleOwner
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) permissionRevision++ }
        owner?.lifecycle?.addObserver(observer)
        onDispose { owner?.lifecycle?.removeObserver(observer) }
    }
    LaunchedEffect(Unit) {
        if (!asked && (!permission.full || !permission.mediaLocation)) requestPermissions()
    }
    LaunchedEffect(extras) {
        externalMedia = extras.mapNotNull { source ->
            try { repository.external(source.uri) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { GalleryMedia(source.uri, "所选媒体", false, null, 0) }
        }
    }
    // A restored grant may have expired. Retain the selection so the per-item draft
    // importer can expose a retry/reselect result without discarding successful siblings.
    LaunchedEffect(permissionRevision) {
        repository.clearThumbnails()
        val invalid = selected.filterNot { repository.readable(it.uri) }.map { it.uri }.toSet()
        if (invalid.isNotEmpty() && invalid != unreadableSelections) {
            message("${invalid.size} 项已无法访问；可补充授权，或完成后在草稿中重新选择。")
        }
        unreadableSelections = invalid
    }
    LaunchedEffect(limit) {
        if (selected.size > limit) {
            selected = selected.take(limit)
            message("可选数量已变化，保留前 $limit 项。")
        }
    }
    fun loadPage() {
        val key = next ?: return
        if (loading || queryFailed || !permission.readable) return
        loading = true
        val requestedGeneration = generation
        queryJob = scope.launch {
            try {
                val page = repository.page(key, permission)
                if (requestedGeneration == generation) {
                    items = (items + page.items).distinctBy { it.uri.toString() }
                    next = page.next
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) {
                if (requestedGeneration == generation) { queryFailed = true; message("暂时无法读取相册，请重试或使用右上角的其他入口。") }
            } finally { if (requestedGeneration == generation) loading = false }
        }
    }
    LaunchedEffect(permissionRevision) {
        queryJob?.cancel()
        generation++
        items = emptyList()
        next = GalleryPageKey()
        loading = false
        queryFailed = false
        loadPage()
    }
    LaunchedEffect(items.size, loading, next, permissionRevision) {
        snapshotFlow { (grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0) to grid.layoutInfo.totalItemsCount }
            .collect { (last, total) -> if (last >= total - 28 && !loading) loadPage() }
    }
    BackHandler(onBack = onBack)
    val allMedia = remember(items, externalMedia) { (externalMedia + items).distinctBy { it.uri.toString() } }
    val previewIndex = allMedia.indexOfFirst { it.uri.toString() == previewUri }
    Scaffold(
        topBar = {
            TopAppBar(title = { Text("选照片", maxLines = 1, overflow = TextOverflow.Ellipsis) }, navigationIcon = {
                IconButton(onClick = onBack, modifier = Modifier.testTag("galleryBack")) {
                    Icon(Icons.AutoMirrored.Rounded.ArrowBack, "返回")
                }
            }, actions = {
                Box {
                    IconButton(onClick = { more = true }, modifier = Modifier.testTag("galleryMore")) {
                        Icon(Icons.Rounded.MoreVert, "更多")
                    }
                    DropdownMenu(expanded = more, onDismissRequest = { more = false }) {
                        DropdownMenuItem(text = { Text("系统选图器") }, onClick = {
                            more = false
                            runCatching { systemPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)) }
                                .onFailure { message("无法打开系统选图器，请尝试从文件里选。") }
                        }, modifier = Modifier.testTag("gallerySystemPicker"))
                        DropdownMenuItem(text = { Text("从文件里选") }, onClick = {
                            more = false
                            runCatching { documentPicker.launch(arrayOf("image/*", "video/*")) }
                                .onFailure { message("无法打开文件选择器，请稍后再试。") }
                        }, modifier = Modifier.testTag("galleryDocumentPicker"))
                    }
                }
            })
        },
        bottomBar = {
            Surface(shadowElevation = 4.dp) {
                Row(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("最多 $limit 项", style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
                    Button(enabled = selected.isNotEmpty(), modifier = Modifier.testTag("galleryComplete"),
                        onClick = { onComplete(selected.toList()) }) { Text("完成（${selected.size}）") }
                }
            }
        }, snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        val zone = remember { ZoneId.systemDefault() }
        val dateFormat = remember { DateTimeFormatter.ofPattern("yyyy年M月d日") }
        val dateGroups = remember(items, zone) { items.groupBy { it.date(zone) } }
        LazyVerticalGrid(columns = GridCells.Fixed(4), state = grid, modifier = Modifier.fillMaxSize().padding(padding).testTag("galleryGrid"),
            horizontalArrangement = Arrangement.spacedBy(2.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            if (!permission.full || !permission.mediaLocation) item(span = { GridItemSpan(maxLineSpan) }, key = "permissions") {
                GalleryPermissionBanner(permission, ::requestPermissions, ::openSettings)
            }
            if (!permission.readable) item(span = { GridItemSpan(maxLineSpan) }, key = "noPermission") {
                Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("允许访问照片后，就能在这里挑选。", style = MaterialTheme.typography.bodyMedium)
                    Text("也可从右上角“更多”使用系统选图器或文件。", style = MaterialTheme.typography.bodySmall)
                }
            }
            if (externalMedia.isNotEmpty()) {
                item(span = { GridItemSpan(maxLineSpan) }, key = "externalHeader") { GalleryDateHeader("其他来源") }
                items(externalMedia, key = { "external-${it.uri}" }) { item ->
                    val source = extras.first { it.uri == item.uri }
                    GalleryCell(item, selected.indexOfFirst { it.uri == item.uri } + 1, repository,
                        onOpen = { previewUri = item.uri.toString() }, onToggle = { choose(source) })
                }
            }
            dateGroups.forEach { (date, group) ->
                item(span = { GridItemSpan(maxLineSpan) }, key = "date-$date") { GalleryDateHeader(date.format(dateFormat)) }
                items(group, key = { "media-${it.uri}" }) { item ->
                    GalleryCell(item, selected.indexOfFirst { it.uri == item.uri } + 1, repository,
                        onOpen = { previewUri = item.uri.toString() },
                        onToggle = { choose(MediaSelection(item.uri, ImportOrigin.MediaStoreGallery)) })
                }
            }
            if (queryFailed) item(span = { GridItemSpan(maxLineSpan) }, key = "retry") {
                TextButton(onClick = { queryFailed = false; loadPage() }, modifier = Modifier.fillMaxWidth()) { Text("相册读取失败，点此重试") }
            }
            if (loading) item(span = { GridItemSpan(maxLineSpan) }, key = "loading") {
                Box(Modifier.fillMaxWidth().padding(20.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.size(24.dp)) }
            }
            if (!loading && !queryFailed && next == null && items.isEmpty() && permission.readable) {
                item(span = { GridItemSpan(maxLineSpan) }, key = "empty") {
                    Text("当前没有可访问的照片或视频。", modifier = Modifier.fillMaxWidth().padding(24.dp))
                }
            }
        }
    }
    if (previewUri != null && previewIndex >= 0) {
        GalleryPreview(allMedia, previewIndex, selected, repository,
            onToggle = { item -> choose(extras.firstOrNull { it.uri == item.uri } ?: MediaSelection(item.uri, ImportOrigin.MediaStoreGallery)) },
            onBack = { previewUri = null }, onPage = { previewUri = it.uri.toString() }, onLoadMore = { loadPage() })
    }
}

@Composable
private fun GalleryPermissionBanner(state: GalleryPermissionState, request: () -> Unit, settings: () -> Unit) {
    Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceVariant).padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(when {
            state.partial && state.images -> "可访问全部照片及你允许的视频。"
            state.partial && state.videos -> "可访问全部视频及你允许的照片。"
            state.partial -> "当前仅显示你允许访问的照片和视频。"
            !state.readable -> "照片访问尚未开启。"
            !state.images -> "当前可浏览视频；照片尚未授权。"
            !state.videos -> "当前可浏览照片；视频尚未授权。"
            else -> "照片位置信息尚未授权，仍可继续选择。"
        }, style = MaterialTheme.typography.bodySmall)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(onClick = request, modifier = Modifier.testTag("galleryGrantMore")) {
                Text(if (state.partial) "增加可访问照片" else if (state.full) "补充照片位置信息" else "允许访问")
            }
            TextButton(onClick = settings, modifier = Modifier.testTag("gallerySettings")) { Text("去设置") }
        }
    }
}

@Composable
private fun GalleryDateHeader(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 12.dp))
}

@Composable
private fun GalleryCell(item: GalleryMedia, ordinal: Int, repository: GalleryRepository, onOpen: () -> Unit, onToggle: () -> Unit) {
    val pixels = with(LocalDensity.current) { 120.dp.roundToPx() }
    val bitmap by produceState<android.graphics.Bitmap?>(null, item.uri, pixels) {
        value = try { repository.thumbnail(item.uri, pixels) }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { null }
    }
    Box(Modifier.fillMaxWidth().aspectRatio(1f).background(MaterialTheme.colorScheme.surfaceVariant)
        .clickable(onClick = onOpen).testTag("galleryCell-${item.uri.lastPathSegment}")
        .semantics { contentDescription = "${if (item.video) "视频" else "照片"} ${item.name}${if (ordinal > 0) "，已选第${ordinal}项" else ""}${if (item.capturedAtMillis == null) "，拍摄时间未知，按加入时间排列" else ""}" }) {
        bitmap?.let { Image(it.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
        GallerySelectionCircle(ordinal, onToggle, Modifier.align(Alignment.TopEnd))
        if (item.video || item.capturedAtMillis == null && item.addedAtMillis > 0) Row(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(Color.Black.copy(alpha = .55f)).padding(3.dp),
            verticalAlignment = Alignment.CenterVertically) {
            if (item.capturedAtMillis == null && item.addedAtMillis > 0) Text("加入时间",
                style = MaterialTheme.typography.labelSmall, color = Color.White,
                modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            else Spacer(Modifier.weight(1f))
            if (item.video) {
                Icon(Icons.Rounded.Videocam, null, Modifier.size(14.dp), tint = Color.White)
                Text(galleryDuration(item.durationMillis), color = Color.White, style = MaterialTheme.typography.labelSmall, maxLines = 1)
            }
        }
    }
}

@Composable
internal fun GallerySelectionCircle(ordinal: Int, onToggle: () -> Unit, modifier: Modifier = Modifier) {
    IconButton(onClick = onToggle, modifier = modifier.size(48.dp).testTag("gallerySelect-$ordinal").semantics { contentDescription = if (ordinal > 0) "取消选择，第${ordinal}项" else "选择" }) {
        Box(Modifier.size(32.dp).clip(CircleShape).background(if (ordinal > 0) MaterialTheme.colorScheme.primaryContainer else Color.Black.copy(alpha = .45f)),
            contentAlignment = Alignment.Center) {
            if (ordinal > 0) Text(ordinal.toString(), color = MaterialTheme.colorScheme.onPrimaryContainer, style = MaterialTheme.typography.labelMedium.copy(fontSize = 12.sp), maxLines = 1)
            else Icon(Icons.Rounded.RadioButtonUnchecked, null, Modifier.size(22.dp), tint = Color.White.copy(alpha = .8f))
        }
    }
}

internal fun galleryDuration(millis: Long): String {
    val seconds = millis.coerceAtLeast(0) / 1000
    return if (seconds >= 3600) "%d:%02d:%02d".format(seconds / 3600, seconds / 60 % 60, seconds % 60)
    else "%d:%02d".format(seconds / 60, seconds % 60)
}

internal tailrec fun Context.galleryActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.galleryActivity()
    else -> null
}
