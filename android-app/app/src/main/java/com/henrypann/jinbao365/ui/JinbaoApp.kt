package com.henrypann.jinbao365.ui

import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import com.henrypann.jinbao365.JinbaoApplication
import com.henrypann.jinbao365.media.MediaPermissions
import com.henrypann.jinbao365.storage.SavedConnection
import com.henrypann.jinbao365.storage.StorageConnectionController
import com.henrypann.jinbao365.storage.StorageConnectionStore
import kotlinx.coroutines.delay

@Composable
fun JinbaoApp() {
    val context = LocalContext.current
    val app = context.applicationContext as JinbaoApplication
    val backup = app.backup
    val controller = remember { StorageConnectionController(StorageConnectionStore(context.applicationContext)) }
    val runtime by backup.coordinator.observableState.collectAsState()
    SideEffect {
        val window = (context as? Activity)?.window
        if (runtime.running) window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
    LaunchedEffect(controller.connection, controller.busy, controller.message) {
        if (!controller.busy) {
            backup.onConnectionChanged()
            app.archiveUi.onConnectionChanged()
        }
    }
    // Refresh the other parent's timeline while the app is visible; no background worker.
    LaunchedEffect(app) {
        while (true) { app.archiveUi.refreshRemote(); delay(60_000) }
    }
    DisposableEffect(controller, context, backup) {
        val owner = context as? LifecycleOwner
        val foreground = owner?.let { BackupForegroundBinding(it.lifecycle) { active ->
            backup.setForegroundActive(active)
            app.archiveUi.setForegroundActive(active)
        } }
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) controller.cancelTransient()
            if (event == Lifecycle.Event.ON_START && controller.connection == null && !controller.busy) controller.retryLoad()
        }
        owner?.lifecycle?.addObserver(observer)
        onDispose {
            owner?.lifecycle?.removeObserver(observer)
            foreground?.close()
            controller.close()
            (context as? Activity)?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }
    JinbaoContent(controller)
}

@Composable
internal fun JinbaoContent(controller: StorageConnectionController) {
    val context = LocalContext.current
    val app = context.applicationContext as JinbaoApplication
    var tabName by rememberSaveable { mutableStateOf(MainTab.Timeline.name) }
    var parent by remember { mutableStateOf(app.parentIdentity) }
    val step = nextOnboardingStep(false, true, controller.connection is SavedConnection.Verified, parent != null)
    val tab = MainTab.valueOf(tabName)
    SideEffect {
        val window = (context as? Activity)?.window
        // The settings summary has no secrets; credential dialogs enforce SecureOn themselves.
        if (step != OnboardingStep.Home) window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        else window?.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
    BackHandler(step != OnboardingStep.Home) { }
    when (step) {
        OnboardingStep.Permissions -> Unit // Kept only for saved enum compatibility; never selected.
        OnboardingStep.Cloud -> StorageConnectionScreen(controller, mandatory = true)
        OnboardingStep.Parent -> ParentIdentityScreen { chosen ->
            app.parentIdentityStore.confirm(chosen)
            parent = app.parentIdentity
            app.backup.onConnectionChanged()
            app.archiveUi.refresh()
            app.archiveUi.refreshRemote()
        }
        OnboardingStep.Home -> AppShell(controller, tab, onSelectTab = { tabName = it.name })
    }
}
