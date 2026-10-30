package com.henrypann.jinbao365.backup

import android.app.Activity
import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import com.henrypann.jinbao365.archive.DeviceIdentity
import com.henrypann.jinbao365.data.ArchiveRepository
import com.henrypann.jinbao365.data.ParentIdentityStore
import com.henrypann.jinbao365.storage.StorageConnectionStore
import java.io.File

/** Application lifetime wiring only: no service, background job, or wake lock. */
class AndroidBackup(
    private val application: Application,
    archive: ArchiveRepository,
    connection: StorageConnectionStore,
    deviceId: String = DeviceIdentity.fromContext(application).getOrCreate(),
) : AutoCloseable {
    private val main = Handler(Looper.getMainLooper())
    private val scheduler = SingleThreadBackupScheduler()
    /** Timeline, detail and Settings share this pure query over their latest archive/state snapshots. */
    val statusQuery: BackupStatusQuery = DefaultBackupStatusQuery()
    private val parentIdentity = ParentIdentityStore(application)
    /** Debuggable (test) builds write only life/v1/test/<device>/. */
    private val testBuild = (application.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
    private val states = BackupStateStore(application)
    val coordinator = BackupCoordinator(
        states = states,
        loadParent = { parentIdentity.parent },
        loadAnniversaries = { archive.loadAnniversaries().filter { it.owner == parentIdentity.parent } },
        // Never upload until this phone has a confirmed, immutable parent identity.
        loadConnection = { V1Destination.mapConnection(connection.load(), parentIdentity.parent, deviceId, testBuild) },
        loadCredentials = { destination ->
            val root = (connection.load() as? com.henrypann.jinbao365.storage.SavedConnection.Verified)?.configuration
            V1Destination.rootOf(destination, root, parentIdentity.parent, deviceId, testBuild)?.let(connection::credentialsForVerified)
        }, loadSnapshot = archive::loadSnapshot,
        isReadOnly = { archive.localSyncState()?.resyncFromStart == true }, mediaRoot = File(application.filesDir, "media"), deviceId = deviceId,
        scheduler = scheduler, publish = { action -> main.post { action() } },
        isTakeoverReady = { receipt ->
            archive.localSyncState()?.let { sync ->
                sync.ownerDeviceId == deviceId && !sync.resyncFromStart &&
                    sync.verifiedThroughSequence == receipt.sequence && sync.verifiedThroughHash == receipt.commitHash
            } == true
        },
        // Multi-device layout: each install writes its own empty chain, so no takeover is needed. The legacy
        // single-writer root (life/v1/<parent>/) stays read-only and is shown via ParentArchiveReader; a takeover
        // would append to that legacy chain, so it is retired here (FolderTakeover itself is kept for later use).
        runTakeover = { _, _, _ -> throw BackupException(BackupFailure.Connection) },
    )
    private var startedActivities = 0
    private var closed = false
    private val connectivity = application.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    @Volatile private var activeNetwork: Network? = connectivity.activeNetwork

    private fun status(capabilities: NetworkCapabilities?): BackupNetwork {
        val connected = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        val wifi = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        return BackupNetwork(connected, wifi)
    }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            activeNetwork = network
            coordinator.onNetworkChanged(status(connectivity.getNetworkCapabilities(network)))
        }
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            if (network == activeNetwork) coordinator.onNetworkChanged(status(capabilities))
        }
        override fun onLost(network: Network) {
            if (network == activeNetwork) {
                activeNetwork = null
                coordinator.onNetworkChanged(BackupNetwork())
            }
        }
    }

    private val lifecycle = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityStarted(activity: Activity) {
            startedActivities++
            if (startedActivities == 1) coordinator.setForegroundActive(true)
        }
        override fun onActivityStopped(activity: Activity) {
            startedActivities--
            if (startedActivities == 0 && !activity.isChangingConfigurations) coordinator.setForegroundActive(false)
        }
        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
        override fun onActivityResumed(activity: Activity) = Unit
        override fun onActivityPaused(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
        override fun onActivityDestroyed(activity: Activity) = Unit
    }

    init {
        coordinator.onNetworkChanged(status(activeNetwork?.let(connectivity::getNetworkCapabilities)))
        connectivity.registerDefaultNetworkCallback(networkCallback)
        application.registerActivityLifecycleCallbacks(lifecycle)
    }

    /** The host calls this after a committed local edit/import; no repository mutation is needed. */
    fun onArchiveChanged() = coordinator.onArchiveChanged()

    /** Call after connection verification, credential replacement or disconnect. */
    fun onConnectionChanged() = coordinator.onConnectionChanged()

    // Lazy construction during an already-started activity must explicitly mark that host active.
    fun setForegroundActive(active: Boolean) = coordinator.setForegroundActive(active)

    override fun close() {
        if (closed) return
        closed = true
        application.unregisterActivityLifecycleCallbacks(lifecycle)
        connectivity.unregisterNetworkCallback(networkCallback)
        coordinator.close()
    }

    companion object {
        /** Retain one instance in the host and close it when that owner is disposed. */
        fun create(context: Context, archive: ArchiveRepository): AndroidBackup = AndroidBackup(
            context.applicationContext as Application, archive, StorageConnectionStore(context.applicationContext),
        )
    }
}
