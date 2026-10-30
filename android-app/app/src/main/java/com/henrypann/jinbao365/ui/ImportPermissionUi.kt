package com.henrypann.jinbao365.ui

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import com.henrypann.jinbao365.media.ImportPermissionCheck
import com.henrypann.jinbao365.media.PermissionGap

/** Live import-permission state: rechecked after each request and whenever the app resumes (e.g. from Settings). */
internal class ImportPermissionState(
    val gaps: List<PermissionGap>,
    /** False when the system will no longer show a dialog (denied permanently): only Settings can fix it. */
    val canRequest: Boolean,
    val request: () -> Unit,
    val openSettings: () -> Unit,
    /** Re-reads the system right now (grants can change without a resume, e.g. in tests or split screen). */
    val liveBlocking: () -> List<PermissionGap> = { ImportPermissionCheck.blocking(gaps) },
) {
    val blocking get() = ImportPermissionCheck.blocking(gaps)
}

private const val PREFS = "import-permissions"

/** Asked before and the system shows no rationale => the dialog will not appear again. */
internal fun canStillAsk(asked: Boolean, rationale: Boolean): Boolean = !asked || rationale

internal fun openAppSettings(context: Context) {
    context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

@Composable
internal fun rememberImportPermissions(onResult: (ImportPermissionState) -> Unit = {}): ImportPermissionState {
    val context = LocalContext.current
    val sdk = Build.VERSION.SDK_INT
    var revision by remember { mutableIntStateOf(0) }
    val prefs = remember(context) { context.getSharedPreferences(PREFS, Context.MODE_PRIVATE) }
    val currentOnResult by rememberUpdatedState(onResult)
    var pendingResult by remember { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        prefs.edit().putBoolean("asked", true).apply()
        revision++
        pendingResult = true
    }
    DisposableEffect(context) {
        val owner = context as? LifecycleOwner
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) revision++ }
        owner?.lifecycle?.addObserver(observer)
        onDispose { owner?.lifecycle?.removeObserver(observer) }
    }
    val state = remember(revision) {
        fun granted(p: String) = ContextCompat.checkSelfPermission(context, p) == PackageManager.PERMISSION_GRANTED
        val gaps = ImportPermissionCheck.gaps(sdk, ::granted)
        val activity = context as? Activity
        val missing = ImportPermissionCheck.allToRequest(sdk).filterNot(::granted)
        val rationale = activity != null && missing.any { ActivityCompat.shouldShowRequestPermissionRationale(activity, it) }
        ImportPermissionState(gaps, canStillAsk(prefs.getBoolean("asked", false), rationale),
            request = { runCatching { launcher.launch(ImportPermissionCheck.allToRequest(sdk).toTypedArray()) }
                .onFailure { openAppSettings(context) } },
            openSettings = { runCatching { openAppSettings(context) } },
            liveBlocking = { ImportPermissionCheck.blocking(ImportPermissionCheck.gaps(sdk, ::granted)) })
    }
    LaunchedEffect(state, pendingResult) {
        if (pendingResult) { pendingResult = false; currentOnResult(state) }
    }
    return state
}
