package com.henrypann.jinbao365.ui

import android.app.Instrumentation
import android.content.Context
import android.content.ContextWrapper
import android.database.sqlite.SQLiteDatabase
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.util.AtomicFile
import android.view.WindowManager
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.inspector.WindowInspector
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogWindowProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.henrypann.jinbao365.JinbaoApplication
import com.henrypann.jinbao365.archive.*
import com.henrypann.jinbao365.backup.*
import com.henrypann.jinbao365.data.ArchiveDatabase
import com.henrypann.jinbao365.data.ArchiveRepository
import com.henrypann.jinbao365.data.Anniversary
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.storage.*
import com.henrypann.jinbao365.ui.theme.DesignTokens
import com.henrypann.jinbao365.ui.theme.JinbaoTheme
import kotlinx.serialization.json.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.MessageDigest
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

/** Actual production screens, synthetic media and UUID-isolated local storage; never starts backup. */
@RunWith(AndroidJUnit4::class)
class BrandVisualAcceptanceTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private enum class Scene { Timeline, Empty, Search, Review, Detail, ReadOnlyDetail, Identity, PhotosPermission,
        LocationPermission, Storage, Anniversaries, EmptyAnniversaries, Settings, CloudError, CloudProgress,
        Editor, ReadOnlyEditor, EditorError }
    private val scene = mutableStateOf(Scene.Timeline)
    private val viewport = mutableStateOf<Int?>(null)
    private val fontScale = mutableFloatStateOf(1f)
    private val today = LocalDate.of(2026, 10, 13)
    private lateinit var fixtureRoot: File
    private lateinit var mediaRoot: File
    private lateinit var snapshot: ArchiveSnapshot
    private lateinit var connection: StorageConnectionController
    private var editorApp: JinbaoApplication? = null
    private var savedRecord: String? = null
    private val anniversaries = listOf(
        Anniversary("mom-birthday", ParentIdentity.Mom, "示例生日", LocalDate.of(2000, 2, 3)),
        Anniversary("dad-sea", ParentIdentity.Dad, "第一次一起看海", LocalDate.of(2025, 8, 10)),
    )

    @After fun cleanFixtures() {
        if (::connection.isInitialized) compose.runOnUiThread { connection.close() }
        editorApp?.let { app ->
            // Close only this fixture's Room connection before deleting its UUID directory.
            val field = ArchiveRepository::class.java.getDeclaredField("database").apply { isAccessible = true }
            (field.get(app.archive) as ArchiveDatabase).close()
        }
        if (::fixtureRoot.isInitialized) fixtureRoot.deleteRecursively()
    }

    @Test fun captureProductionScreensAndCriticalStates() {
        prepare()
        installContent()
        compose.onNodeWithTag("momentCard-dad-garden").assertIsDisplayed()
        compose.onNodeWithTag("addMoment").assertWidthIsAtLeast(48.dp).assertHeightIsAtLeast(48.dp)
        compose.onNodeWithTag("tabTimeline").assertWidthIsAtLeast(48.dp).assertHeightIsAtLeast(48.dp)
        capture("01-timeline")
        compose.onNodeWithTag("addMoment").performClick()
        compose.onNodeWithTag("addPhotosMenuAction").assertIsDisplayed()
        capture("02-add-menu")

        show(Scene.Search)
        compose.onNodeWithTag("timelineSearchButton").performClick()
        compose.onNodeWithTag("timelineSearch").performTextInput("树叶")
        compose.onNodeWithTag("momentCard-dad-garden").assertIsDisplayed()
        compose.onNodeWithTag("momentCard-mom-song").assertDoesNotExist()
        dismissKeyboard()
        capture("03-timeline-search")
        show(Scene.Empty)
        compose.onNodeWithTag("timelineEmpty").assertIsDisplayed()
        capture("04-timeline-empty")

        show(Scene.Detail)
        compose.onNodeWithTag("momentGallery").assertIsDisplayed()
        compose.onNodeWithTag("editMoment").assertIsDisplayed()
        capture("05-detail")
        show(Scene.ReadOnlyDetail)
        compose.onNodeWithText("这条记录仅供查看。").assertIsDisplayed()
        compose.onNodeWithTag("editMoment").assertDoesNotExist()
        capture("06-detail-read-only")

        show(Scene.Identity)
        compose.onNodeWithTag("chooseDad").assertIsDisplayed()
        compose.onNodeWithTag("chooseMom").assertIsDisplayed()
        capture("07-first-launch")
        compose.onNodeWithTag("chooseMom").performClick()
        compose.onNodeWithTag("parentConfirmation").assertIsDisplayed()
        capture("08-parent-confirmation")
        compose.onNodeWithTag("confirmParent").performClick()
        compose.onNodeWithText("署名没有保存成功，请重试。").assertIsDisplayed()
        capture("09-parent-save-error")

        show(Scene.PhotosPermission)
        compose.onNodeWithText("允许照片和视频权限").assertIsDisplayed()
        capture("10-photo-permission")
        show(Scene.LocationPermission)
        compose.onAllNodesWithText("允许位置权限").onFirst().assertExists()
        capture("11-location-permission")
        show(Scene.Storage)
        useSyntheticConnectionMetadata()
        assertEmptyCredentials()
        capture("12-cloud-empty-credentials", emptyCredentialDialog = true)

        show(Scene.Timeline)
        compose.onNodeWithTag("tabCountdown").performClick()
        compose.onNodeWithTag("tabCountdown").assertIsSelected()
        compose.onNodeWithTag("anniversary-mom-mom-birthday").assertIsNotEnabled()
        compose.onNodeWithTag("anniversary-dad-dad-sea").assertIsEnabled()
        capture("13-countdown")
        compose.onNodeWithTag("anniversary-dad-dad-sea").performClick()
        compose.onNodeWithTag("anniversaryTitle").assertTextContains("第一次一起看海")
        capture("14-anniversary-edit")
        compose.onNodeWithTag("anniversaryDate").performTextReplacement("2026-02-29")
        compose.onNodeWithTag("saveAnniversary").assertIsNotEnabled()
        dismissKeyboard()
        capture("15-anniversary-invalid-date")
        compose.onNodeWithTag("deleteAnniversary-dad-sea").performClick()
        compose.onNodeWithTag("confirmDeleteAnniversary").assertIsDisplayed()
        capture("16-anniversary-delete-confirmation")
        show(Scene.EmptyAnniversaries)
        capture("17-countdown-empty")

        show(Scene.Timeline)
        compose.onNodeWithTag("tabSettings").performClick()
        compose.onNodeWithTag("tabSettings").assertIsSelected()
        compose.onNodeWithTag("phoneParent").assertTextEquals("这台手机：爸爸")
        capture("18-settings")
        compose.onNodeWithTag("appVersion").performScrollTo()
        capture("19-settings-about")
        show(Scene.CloudError)
        compose.onNodeWithTag("backupError").assertIsDisplayed()
        compose.onNodeWithTag("retryFailedBackups").assertIsEnabled()
        capture("20-cloud-backup-error")
        show(Scene.CloudProgress)
        compose.onNodeWithText("已备份 2/5 个文件").assertIsDisplayed()
        capture("21-cloud-backup-progress")

        show(Scene.Editor)
        compose.waitUntil(5_000) { compose.onAllNodesWithTag("momentTitle").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("momentTitle").assertTextContains("今天的小发现")
        compose.onNodeWithTag("saveMoment").assertIsEnabled()
        capture("22-record-editor")
        compose.onNodeWithTag("momentNote").performScrollTo().performClick().performTextReplacement("一起发现树叶上的小水滴。每一天都有值得珍藏的小美好。")
        capture("23-record-editor-keyboard")
        dismissKeyboard()
        compose.onNodeWithContentDescription("关闭编辑").performClick()
        compose.onNodeWithText("保留这个草稿吗？").assertIsDisplayed()
        capture("24-draft-exit-confirmation")
        compose.onNodeWithText("继续编辑").performClick()
        compose.onNodeWithTag("saveMoment").performClick()
        compose.waitUntil(5_000) { savedRecord != null }
        val record = editorApp!!.archive.loadSnapshot().records.single()
        assertEquals("今天的小发现", record.title!!.value.jsonPrimitive.content)
        assertEquals("一起发现树叶上的小水滴。每一天都有值得珍藏的小美好。", record.note.value.jsonPrimitive.content)
        assertNull(editorApp!!.archive.loadDraft("brand-draft"))

        show(Scene.ReadOnlyEditor)
        compose.waitUntil(5_000) { compose.onAllNodesWithTag("momentTitle").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("saveMoment").assertIsNotEnabled()
        compose.onNodeWithTag("momentTitle").assertIsNotEnabled()
        capture("25-editor-read-only")
        show(Scene.EditorError)
        compose.waitUntil(5_000) { compose.onAllNodesWithTag("momentEditorError").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("saveMoment").assertIsNotEnabled()
        capture("26-editor-missing-record")

        // A 320 dp content viewport and 150% text catch overflow without changing device/user settings.
        compose.runOnIdle { viewport.value = 320; fontScale.floatValue = 1.5f }
        show(Scene.Identity)
        compose.onNodeWithTag("chooseMom").performScrollTo().assertIsDisplayed()
        capture("27-first-launch-320dp-large-type")
        show(Scene.Anniversaries)
        compose.onNodeWithTag("addAnniversary").assertIsDisplayed()
        capture("28-countdown-320dp-large-type")
        show(Scene.Storage)
        useSyntheticConnectionMetadata()
        assertEmptyCredentials()
        constrainEmptyCredentialDialog(320)
        compose.onNodeWithTag("secretKey").performScrollTo()
        capture("29-cloud-320dp-large-type", emptyCredentialDialog = true)
    }

    private fun prepare() {
        fixtureRoot = File(compose.activity.noBackupFilesDir, "brand-fixture-${UUID.randomUUID()}").apply { mkdirs() }
        mediaRoot = File(fixtureRoot, "synthetic-media").apply { mkdirs() }
        snapshot = syntheticSnapshot()
        compose.runOnUiThread {
            connection = StorageConnectionController(
                StorageConnectionStore(AtomicFile(File(fixtureRoot, "connection.enc")), AndroidCredentialCipher()),
                StorageVerifier { _, _, _ -> error("Brand fixture must never contact COS") },
            )
        }
        compose.waitUntil(5_000) { connection.connection != null }
        val isolatedContext = FixtureContext(compose.activity, File(fixtureRoot, "editor").apply { mkdirs() })
        compose.runOnUiThread {
            editorApp = Instrumentation.newApplication(JinbaoApplication::class.java, isolatedContext) as JinbaoApplication
            val app = editorApp!!
            assertEquals(isolatedContext.filesDir.canonicalFile, app.filesDir.canonicalFile)
            assertEquals(isolatedContext.noBackupFilesDir.canonicalFile, app.noBackupFilesDir.canonicalFile)
            assertEquals(isolatedContext.getDatabasePath(ArchiveDatabase.NAME).canonicalFile,
                app.getDatabasePath(ArchiveDatabase.NAME).canonicalFile)
            assertNotEquals(compose.activity.getDatabasePath(ArchiveDatabase.NAME).canonicalFile,
                app.getDatabasePath(ArchiveDatabase.NAME).canonicalFile)
            editorApp!!.onCreate()
            editorApp!!.parentIdentityStore.confirm(ParentIdentity.Dad)
        }
        val app = editorApp!!
        app.archive.createDraft(app.deviceId, timestamp(11), id = "brand-draft")
        app.archive.updateDraft("brand-draft", app.deviceId, timestamp(11)) {
            it.copy(title = "今天的小发现", note = "一起发现树叶上的小水滴。")
        }
    }

    private fun installContent() = compose.setContent {
        JinbaoTheme {
            val density = LocalDensity.current.density
            CompositionLocalProvider(LocalDensity provides Density(density, fontScale.floatValue)) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
                    Surface(color = DesignTokens.Colors.bg,
                        modifier = (viewport.value?.let { Modifier.width(it.dp).fillMaxHeight() }
                            ?: Modifier.fillMaxSize()).systemBarsPadding()) {
                        key(scene.value) {
                            val hasNavigation = scene.value in setOf(Scene.Timeline, Scene.Search, Scene.Empty,
                                Scene.Anniversaries, Scene.EmptyAnniversaries, Scene.Settings, Scene.Review)
                            Column(Modifier.fillMaxSize()) {
                                Box(Modifier.weight(1f)) {
                                    when (scene.value) {
                                        Scene.Timeline, Scene.Search, Scene.Empty -> Box(Modifier.fillMaxSize()) {
                                            TimelineScreen(if (scene.value == Scene.Empty) ArchiveSnapshot.empty() else snapshot,
                                                false, mediaRoot, {}, {}, parentOf = { if (it.startsWith("dad-")) ParentIdentity.Dad else ParentIdentity.Mom },
                                                anniversaries = anniversaries, todayOverride = today)
                                        }
                                        Scene.Review -> ReviewScreen(snapshot, mediaRoot, {})
                                        Scene.Detail, Scene.ReadOnlyDetail -> MomentDetailScreen(snapshot,
                                            if (scene.value == Scene.Detail) "dad-garden" else "mom-song", mediaRoot,
                                            readOnly = scene.value == Scene.ReadOnlyDetail, onBack = {}, onEdit = {},
                                            onTrash = {}, onRestore = {}, parent = if (scene.value == Scene.Detail) ParentIdentity.Dad else ParentIdentity.Mom)
                                        Scene.Identity -> ParentIdentityScreen { throw IllegalStateException("Synthetic save failure") }
                                        Scene.PhotosPermission -> PermissionGateScreen(emptyList(), false, true, {}, {}, {})
                                        Scene.LocationPermission -> PermissionGateScreen(listOf(com.henrypann.jinbao365.media.PermissionGap.MediaLocation), true, false, {}, {}, {})
                                        Scene.Storage -> StorageConnectionScreen(connection, mandatory = true)
                                        Scene.Anniversaries, Scene.EmptyAnniversaries -> AnniversariesScreen(
                                            if (scene.value == Scene.Anniversaries) anniversaries else emptyList(), ParentIdentity.Dad, false,
                                            onSave = { _, _, _, _ -> }, onDelete = {}, onBack = {})
                                        Scene.Settings -> SettingsScreen(connection, "offline-brand-fixture", mediaRoot, snapshot,
                                            syncState = null, onOpenTrash = {}, backupSummary = BackupSummary(unbackedRecordCount = 4),
                                            backupConfiguration = null, onBackUpNow = {}, onPauseBackup = {}, onRetryFailed = {},
                                            parent = ParentIdentity.Dad)
                                        Scene.CloudError -> CloudStorageScreen(
                                            BackupSummary(unbackedOriginalCount = 3, unbackedRecordCount = 2, failedCount = 1,
                                                paused = false, blockReason = BackupBlockReason.Failed, canBackUpNow = true, canRetryFailed = true),
                                            "family-demo-1000000000", "ap-shanghai", "life/v1/dad/", {}, {}, {}, {}, {},
                                            deviceId = "offline-brand-fixture", backupError = "Synthetic offline failure")
                                        Scene.CloudProgress -> CloudStorageScreen(
                                            BackupSummary(unbackedOriginalCount = 3, unbackedRecordCount = 2,
                                                inProgress = true, paused = false, blockReason = null,
                                                progress = BackupProgress("upload", null, 2, 5), canPause = true),
                                            "family-demo-1000000000", "ap-shanghai", "life/v1/dad/", {}, {}, {}, {}, {})
                                        Scene.Editor, Scene.ReadOnlyEditor, Scene.EditorError -> MomentEditorScreen(
                                            app = editorApp!!, snapshot = ArchiveSnapshot.empty(),
                                            recordId = if (scene.value == Scene.ReadOnlyEditor) savedRecord else if (scene.value == Scene.EditorError) "missing-brand-record" else null,
                                            draftId = if (scene.value == Scene.Editor) "brand-draft" else null,
                                            focusNote = false, readOnly = scene.value == Scene.ReadOnlyEditor,
                                            onClose = {}, onSaved = { savedRecord = it }, onChanged = {})
                                    }
                                }
                                if (hasNavigation) MainBottomBar(
                                    tab = when (scene.value) {
                                        Scene.Anniversaries, Scene.EmptyAnniversaries -> MainTab.Countdown
                                        Scene.Settings -> MainTab.Settings
                                        Scene.Review -> MainTab.Review
                                        else -> MainTab.Timeline
                                    },
                                    onSelectTab = { scene.value = when (it) {
                                        MainTab.Timeline -> Scene.Timeline
                                        MainTab.Countdown -> Scene.Anniversaries
                                        MainTab.Review -> Scene.Review
                                        MainTab.Settings -> Scene.Settings
                                    } }, modifier = Modifier,
                                    add = { AddMomentButton(true, {}, {}, {}, Modifier) },
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private fun show(value: Scene) {
        compose.runOnIdle { scene.value = value }
        compose.waitForIdle()
    }

    private fun useSyntheticConnectionMetadata() {
        // The review artifact shows a fictional bucket, never the production account's metadata.
        compose.onNodeWithTag("storageBucket").performTextReplacement("family-demo-1000000000")
        compose.onNodeWithTag("storageRegion").performTextReplacement("ap-shanghai")
        dismissKeyboard()
    }

    private fun assertEmptyCredentials() {
        val empty = SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString(""))
        compose.onNodeWithTag("secretID").assert(empty)
        compose.onNodeWithTag("secretKey").assert(empty)
        compose.onNodeWithTag("verifyContinue").assertIsNotEnabled()
    }

    private fun dismissKeyboard() {
        compose.runOnUiThread {
            val manager = compose.activity.getSystemService(android.view.inputmethod.InputMethodManager::class.java)
            WindowInspector.getGlobalWindowViews().forEach { view ->
                manager.hideSoftInputFromWindow(view.windowToken, 0)
                view.clearFocus()
            }
        }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        compose.waitForIdle()
    }

    private fun fixtureDialogWindow(): Window {
        val windows = mutableListOf<Window>()
        fun visit(view: View) {
            (view as? DialogWindowProvider)?.window?.let { windows += it }
            if (view is ViewGroup) for (index in 0 until view.childCount) visit(view.getChildAt(index))
        }
        WindowInspector.getGlobalWindowViews().forEach(::visit)
        return windows.distinct().single()
    }

    private fun constrainEmptyCredentialDialog(widthDp: Int) {
        assertEmptyCredentials()
        // Dialogs have a separate window: constrain only this empty fixture's window.
        compose.runOnUiThread {
            val window = fixtureDialogWindow()
            window.setLayout((widthDp * window.decorView.resources.displayMetrics.density).toInt(), window.attributes.height)
        }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        compose.waitForIdle()
    }

    private fun capture(name: String, emptyCredentialDialog: Boolean = false) {
        compose.waitForIdle()
        // Finish field/IME/window transitions before the test-only empty-dialog override.
        android.os.SystemClock.sleep(400)
        var frame: Bitmap? = null
        for (attempt in 0 until 3) {
            if (emptyCredentialDialog) {
                assertEmptyCredentials()
                // Test-only override on one empty fixture dialog. Production SecureOn remains unchanged.
                compose.runOnUiThread {
                    val window = fixtureDialogWindow()
                    window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    window.decorView.invalidate()
                }
                InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            }
            // SurfaceFlinger may need another frame when a window's protected buffer is replaced.
            android.os.SystemClock.sleep(120)
            frame = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
            if (frame != null) break
        }
        val bitmap = requireNotNull(frame) { "No visible screenshot frame for $name after three window-frame attempts" }
        try {
            val visible = (1..9).sumOf { x -> (1..9).count { y ->
                val pixel = bitmap.getPixel(bitmap.width * x / 10, bitmap.height * y / 10)
                Color.red(pixel) + Color.green(pixel) + Color.blue(pixel) > 90
            } }
            assertTrue("Screenshot $name must contain a visible frame", visible > 40)
            val target = File(compose.activity.getExternalFilesDir(null), "brand-v1.0/$name.png")
            check(target.parentFile!!.mkdirs() || target.parentFile!!.isDirectory)
            target.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        } finally { bitmap.recycle() }
    }

    private fun syntheticSnapshot(): ArchiveSnapshot {
        val recordData = listOf(
            Triple("dad-garden", "一起发现树叶", "阳光照在叶子上，我们看见了一颗小水滴。"),
            Triple("mom-song", "一起听小星星", "听到熟悉的歌，孩子开始跟着摇小手。"),
            Triple("dad-sun", "午后的阳光", "安静的小日常，也值得好好收藏。"),
            Triple("mom-book", "今天读了一本书", "一起翻开新的故事，看见更大的世界。"),
        )
        val assets = mutableListOf<MediaAsset>()
        val resources = mutableListOf<MediaResource>()
        val records = recordData.mapIndexed { index, (id, title, note) ->
            val parent = if (id.startsWith("dad-")) ParentIdentity.Dad else ParentIdentity.Mom
            val stamp = EditStamp(1, timestamp(11 - index), "synthetic-${parent.folder}")
            fun field(value: JsonElement) = FieldEnvelope(value, stamp)
            val assetId = "art-$index"
            val resourceId = "resource-$index"
            val file = File(mediaRoot, "$index.png")
            createSyntheticArtwork(file, index)
            val sha = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
            assets += MediaAsset(assetId, "photo", field(JsonPrimitive(timestamp(11 - index))), listOf(resourceId), emptyMap())
            resources += MediaResource(resourceId, assetId, "photo", "image/png", "synthetic-art-$index.png", file.length(), sha, file.name, emptyMap())
            ArchiveRecord(id, field(JsonPrimitive(title)), field(JsonPrimitive(note)),
                field(JsonObject(mapOf("utc" to JsonPrimitive(timestamp(11 - index))))), field(JsonPrimitive(timestamp(11 - index))),
                field(JsonArray(listOf(JsonPrimitive(assetId)))), field(JsonNull), mapOf("parent" to field(JsonPrimitive(parent.folder))))
        }
        return ArchiveSnapshot.empty().copy(records = records, assets = assets, resources = resources)
    }

    private fun timestamp(hour: Int) = today.atTime(hour, 0).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()

    /** A generated landscape is visibly synthetic and contains no private photo or identifying person. */
    private fun createSyntheticArtwork(file: File, index: Int) {
        val width = 600
        val height = if (index % 2 == 0) 650 else 430
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        canvas.drawColor(Color.rgb(232 - index * 5, 239 - index * 3, 246))
        paint.color = Color.rgb(247, 201, 72)
        canvas.drawCircle(450f, 110f, 65f, paint)
        paint.color = Color.rgb(130, 162, 122)
        canvas.drawPath(Path().apply {
            moveTo(0f, height.toFloat()); lineTo(0f, height * .68f); quadTo(170f, height * .3f, 340f, height * .66f)
            quadTo(500f, height * .45f, 600f, height * .65f); lineTo(600f, height.toFloat()); close()
        }, paint)
        paint.color = Color.rgb(76, 127, 70)
        canvas.drawPath(Path().apply {
            moveTo(0f, height.toFloat()); lineTo(0f, height * .88f); quadTo(300f, height * .48f, 600f, height * .88f)
            lineTo(600f, height.toFloat()); close()
        }, paint)
        file.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
    }

    /** Redirects every application file/Room path into this fixture. Android resources remain real. */
    private class FixtureContext(base: Context, private val root: File) : ContextWrapper(base) {
        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): File = File(root, "files").apply { mkdirs() }
        override fun getNoBackupFilesDir(): File = File(root, "no-backup").apply { mkdirs() }
        override fun getCacheDir(): File = File(root, "cache").apply { mkdirs() }
        override fun getDatabasePath(name: String): File = File(File(root, "databases").apply { mkdirs() }, name)
        override fun openOrCreateDatabase(name: String, mode: Int, factory: SQLiteDatabase.CursorFactory?): SQLiteDatabase =
            SQLiteDatabase.openOrCreateDatabase(getDatabasePath(name), factory)
        override fun openOrCreateDatabase(name: String, mode: Int, factory: SQLiteDatabase.CursorFactory?,
            errorHandler: android.database.DatabaseErrorHandler?): SQLiteDatabase =
            SQLiteDatabase.openOrCreateDatabase(getDatabasePath(name).path, factory, errorHandler)
        override fun deleteDatabase(name: String): Boolean = SQLiteDatabase.deleteDatabase(getDatabasePath(name))
        override fun databaseList(): Array<String> = File(root, "databases").list() ?: emptyArray()
    }
}
