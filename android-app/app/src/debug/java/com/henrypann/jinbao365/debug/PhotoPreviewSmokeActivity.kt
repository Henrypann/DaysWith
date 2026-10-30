package com.henrypann.jinbao365.debug

import android.content.Context
import android.content.res.Configuration
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp
import com.henrypann.jinbao365.backup.*
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.ui.MomentDetailScreen
import com.henrypann.jinbao365.ui.MyScreen
import com.henrypann.jinbao365.ui.theme.JinbaoTheme
import com.henrypann.jinbao365.viewing.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.OutputStream
import java.util.Locale

/** Shell-only debug device acceptance. Does not start the production backup coordinator. */
class PhotoPreviewSmokeActivity : ComponentActivity() {
    override fun attachBaseContext(newBase: Context) {
        val config = Configuration(newBase.resources.configuration).apply { setLocale(Locale.SIMPLIFIED_CHINESE) }
        super.attachBaseContext(newBase.createConfigurationContext(config))
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val initialScene = intent.getStringExtra("scene") ?: "menu"
        setContent {
            JinbaoTheme {
                Surface(Modifier.fillMaxSize().semantics { testTagsAsResourceId = true }) {
                    var fixtures by remember { mutableStateOf<PhotoPreviewSmokeFixtures?>(null) }
                    var failed by remember { mutableStateOf(false) }
                    LaunchedEffect(Unit) {
                        var stage = "seal"
                        try { fixtures = withContext(Dispatchers.IO) {
                            // Seal a newly supplied connection on first entry, even before a remote tap.
                            if (File(noBackupFilesDir, "pr8-smoke-connection.json").exists()) PhotoPreviewSmokeConnection.read(this@PhotoPreviewSmokeActivity)
                            stage = "fixtures"
                            PhotoPreviewSmokeFixtures(this@PhotoPreviewSmokeActivity)
                        } } catch (failure: Exception) {
                            withContext(Dispatchers.IO) { writeSafeError(stage, failure) }
                            failed = true
                        }
                    }
                    val ready = fixtures
                    if (ready != null) Scenes(ready, initialScene)
                    else Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        if (failed) Text("Test fixture unavailable") else CircularProgressIndicator()
                    }
                }
            }
        }
    }
    private fun writeSafeError(stage: String, failure: Exception) {
        // Intentionally exclude messages, causes, payloads, filenames, headers and URLs.
        val frames = org.json.JSONArray()
        failure.stackTrace.take(16).forEach { frame ->
            frames.put(JSONObject().put("class", frame.className).put("method", frame.methodName).put("line", frame.lineNumber))
        }
        val report = JSONObject().put("stage", stage).put("exception", failure.javaClass.simpleName).put("stack", frames)
        runCatching { File(filesDir, "pr8-smoke-error.json").writeText(report.toString(2)) }
    }
    @Composable private fun Scenes(fixtures: PhotoPreviewSmokeFixtures, initial: String) {
        var scene by remember { mutableStateOf(initial) }
        val scope = rememberCoroutineScope()
        val preference = remember { CellularOriginalPreference(File(filesDir, "prefs/cellular-original-preview")) }
        var allowCellular by remember { mutableStateOf(preference.allow()) }
        val observations = remember { PhotoPreviewSmokeObservations(this, fixtures) }
        val downloader = remember {
            PartnerOriginalDownloader(fixtures.root, { AndroidOriginalNetwork.current(this) }) { parent, cancellation ->
                check(parent == ParentIdentity.Mom)
                val connection = PhotoPreviewSmokeConnection.read(this)
                val store = PhotoPreviewSmokeStore(connection.client(parent, cancellation), parent, observations)
                val allowed = fixtures.snapshot.resources.filter { it.role == "photo" && it.objectKey.startsWith("remote/") }
                    .map { "${parent.prefix}objects/${it.sha256.take(2)}/${it.sha256}" }.toSet()
                object : OriginalObjectSource {
                    override fun head(key: String): CosObjectInfo? { check(key in allowed); return store.head(key) }
                    override fun download(key: String, output: OutputStream): CosDownload { check(key in allowed); return store.download(key, output) }
                    override fun toString() = "SmokeOriginalSource(redacted)"
                }
            }
        }
        var backupStatus by remember { mutableStateOf("Ready") }
        LaunchedEffect(scene) { withContext(Dispatchers.IO) { observations.event("sceneOpened") } }
        BackHandler(scene != "menu") { scene = "menu" }
        val record = fixtures.scenes[scene]
        when {
            record != null -> MomentDetailScreen(fixtures.snapshot, record, fixtures.root, true,
                onBack = { scene = "menu" }, onEdit = {}, onTrash = {}, onRestore = {},
                parent = if (scene.startsWith("remote")) ParentIdentity.Mom else ParentIdentity.Dad,
                originals = downloader, allowCellularOriginals = allowCellular)
            scene == "my" -> Box(Modifier.fillMaxSize().systemBarsPadding()) {
                MyScreen(fixtures.localSnapshot, ParentIdentity.Dad, backupStatus, 0,
                    onOpenArchive = { scene = "menu" }, onOpenBackup = { scene = "backup" }, onOpenSettings = { scene = "menu" },
                    allowCellularOriginals = allowCellular,
                    onAllowCellularOriginals = { preference.setAllow(it); allowCellular = preference.allow() })
            }
            else -> Column(Modifier.fillMaxSize().systemBarsPadding().padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Photo preview · device test", style = MaterialTheme.typography.titleLarge)
                for (name in listOf("local", "remote-a", "remote-b", "remote-c", "remote-d", "video", "my")) {
                    Button(onClick = { scene = name }) { Text(name) }
                }
                Button(enabled = backupStatus != "Running", onClick = {
                    backupStatus = "Running"
                    scope.launch { backupStatus = withContext(Dispatchers.IO) { runBackup(fixtures, observations, preference.allow()) } }
                }) { Text("Run isolated backup") }
                Text(backupStatus)
            }
        }
    }
    private fun runBackup(fixtures: PhotoPreviewSmokeFixtures, observations: PhotoPreviewSmokeObservations, previewCellular: Boolean): String {
        val report = JSONObject().put("previewCellular", previewCellular).put("backupAllowsCellular", BackupPolicy.ALLOW_CELLULAR)
            .put("network", AndroidOriginalNetwork.current(this).name)
        return try {
            val connection = PhotoPreviewSmokeConnection.read(this)
            val logical = connection.configuration.copy(prefix = ParentIdentity.Dad.prefix)
            // Separate physical test prefixes never reuse a writer receipt from another fixture run.
            val stateId = java.security.MessageDigest.getInstance("SHA-256").digest(connection.configuration.prefix.toByteArray())
                .joinToString("") { "%02x".format(it.toInt() and 255) }
            val states = BackupStateStore(File(noBackupFilesDir, "pr8-smoke-backup/$stateId"))
            states.save((states.load() ?: BackupState(bucket = logical.bucket, prefix = logical.prefix)).copy(paused = false))
            val engine = BackupEngine(states, conditions = {
                val network = AndroidOriginalNetwork.current(this)
                BackupConditions(logical, network == OriginalNetwork.Unmetered, paused = false, readOnly = false,
                    networkConnected = network != OriginalNetwork.Offline)
            }, objectStore = { _, _, cancellation ->
                PhotoPreviewSmokeStore(connection.client(ParentIdentity.Dad, cancellation), ParentIdentity.Dad, observations)
            }, parent = ParentIdentity.Dad)
            val receipt = engine.runOnce(fixtures.localSnapshot, fixtures.root, logical, connection.credentials,
                fixtures.manifest.getString("writer"), System.currentTimeMillis())
            report.put("passed", true).put("sequence", receipt.sequence).put("coveredObjects", receipt.coveredObjectKeys.size)
                .put("manifestHash", receipt.manifestHash).put("commitHash", receipt.commitHash)
            "Backup verified · ${receipt.coveredObjectKeys.size} objects"
        } catch (failure: Exception) {
            val kind = when (failure) { is CosException -> failure.failure.name; is BackupException -> failure.failure.name; else -> "FixtureFailure" }
            report.put("passed", false).put("failure", kind)
            "Backup failed · $kind"
        } finally {
            File(filesDir, "pr8-smoke-backup-result.json").writeText(report.toString(2))
            observations.event("backupFinished")
        }
    }
}
