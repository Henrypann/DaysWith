package com.henrypann.jinbao365.backup

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.data.Anniversary
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.storage.SavedConnection
import com.henrypann.jinbao365.storage.StorageConfiguration
import com.henrypann.jinbao365.storage.StorageCredentials
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit

/** Reasons are also useful when explaining why the manual action is unavailable. */
enum class BackupBlockReason(val text: String) {
    Loading("正在读取备份状态…"),
    Connection("请先连接云存储。"),
    Credentials(BackupFailure.Credentials.text),
    Offline("等待网络"),
    Metered(BackupPolicy.WIFI_WAITING),
    Paused("备份已暂停。"),
    ReadOnly(BackupFailure.ReadOnly.text),
    Background("联网并打开应用后继续备份。"),
    Running("正在备份…"),
    State(BackupFailure.StateRead.text),
    Failed("备份遇到问题，请重试。"),
}

data class BackupCoordinatorState(
    val state: BackupState? = null,
    val configuration: StorageConfiguration? = null,
    val running: Boolean = false,
    val paused: Boolean = true,
    val blockReason: BackupBlockReason? = BackupBlockReason.Loading,
    val progress: BackupProgress? = null,
    val lastError: String? = null,
    val canBackUpNow: Boolean = false,
    val lastReceipt: BackupReceipt? = state?.receipt,
    val takingOver: Boolean = false,
    val takeoverError: String? = null,
)

data class BackupNetwork(val connected: Boolean = false, val unmetered: Boolean = false)

/** All persisted state and Room work use this one worker. Injectable scheduling keeps tests deterministic. */
interface BackupScheduler : AutoCloseable {
    fun execute(action: () -> Unit)
    fun schedule(delayMillis: Long, action: () -> Unit): AutoCloseable
}

class SingleThreadBackupScheduler : BackupScheduler {
    private val executor = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "jinbao365-backup")
    }
    override fun execute(action: () -> Unit) {
        try { executor.execute(action) } catch (failure: RejectedExecutionException) {
            if (!executor.isShutdown) throw failure
        }
    }
    override fun schedule(delayMillis: Long, action: () -> Unit): AutoCloseable {
        return try {
            val future = executor.schedule(action, delayMillis, TimeUnit.MILLISECONDS)
            AutoCloseable { future.cancel(false) }
        } catch (failure: RejectedExecutionException) {
            if (!executor.isShutdown) throw failure
            AutoCloseable { }
        }
    }
    override fun close() { executor.shutdown() }
}

/** Credentials stay worker-local and are never included in the published UI model. */
data class BackupRunRequest(
    val snapshot: ArchiveSnapshot,
    val mediaRoot: File,
    val configuration: StorageConfiguration,
    val credentials: StorageCredentials,
    val deviceId: String,
    val now: Long,
    val conditions: () -> BackupConditions,
    val onProgress: (BackupProgress) -> Unit,
    val stopAfterObject: () -> Boolean,
    val anniversaries: List<Anniversary> = emptyList(),
    val parent: ParentIdentity? = null,
)

class BackupCoordinator(
    private val states: BackupStatePersistence,
    private val loadConnection: () -> SavedConnection,
    private val loadCredentials: (StorageConfiguration) -> StorageCredentials?,
    private val loadSnapshot: () -> ArchiveSnapshot,
    private val isReadOnly: () -> Boolean,
    private val mediaRoot: File,
    private val deviceId: String,
    private val scheduler: BackupScheduler = SingleThreadBackupScheduler(),
    private val publish: ((() -> Unit) -> Unit) = { it() },
    private val now: () -> Long = System::currentTimeMillis,
    private val runEngine: ((BackupRunRequest) -> BackupReceipt)? = null,
    private val allowCellular: Boolean = BackupPolicy.ALLOW_CELLULAR,
    private val runTakeover: ((StorageConfiguration, StorageCredentials, BackupCancellation) -> Unit)? = null,
    private val isTakeoverReady: (BackupReceipt) -> Boolean = { false },
    private val loadAnniversaries: () -> List<Anniversary> = { emptyList() },
    private val loadParent: () -> ParentIdentity? = { null },
) : AutoCloseable {
    private val mutableState = MutableStateFlow(BackupCoordinatorState())
    val observableState: StateFlow<BackupCoordinatorState> = mutableState.asStateFlow()
    val uiState: BackupCoordinatorState get() = observableState.value

    @Volatile private var foreground = false
    @Volatile private var network = BackupNetwork()
    @Volatile private var running = false
    @Volatile private var activeCancellation: BackupCancellation? = null
    @Volatile private var requestedPause: Boolean? = null
    @Volatile private var closed = false
    private var state: BackupState? = null
    private var connection: SavedConnection = SavedConnection.Missing
    private var credentials: StorageCredentials? = null
    private var readOnly = true
    private var stateFailure: String? = null
    private var pausePersistenceError: String? = null
    private var progress: BackupProgress? = null
    @Volatile private var takingOver = false
    private var takeoverError: String? = null
    private var retryDelay = INITIAL_RETRY_MILLIS
    private var retry: AutoCloseable? = null
    private var debounce: AutoCloseable? = null
    private val eventLock = Any()

    init { scheduler.execute { refresh(); normalizeInterrupted(); emit() } }

    private fun normalizeInterrupted() {
        val previous = state ?: return
        if (stateFailure != null || running) return
        if (previous.objects.values.none { it.status in setOf(BackupObjectStatus.uploading, BackupObjectStatus.verifying) }) return
        try {
            state = previous.copy(stage = "idle", objects = previous.objects.mapValues { (_, value) ->
                if (value.status in setOf(BackupObjectStatus.uploading, BackupObjectStatus.verifying))
                    value.copy(status = BackupObjectStatus.pending) else value
            }).also(states::save)
        } catch (_: Exception) { stateFailure = BackupFailure.State.text }
    }

    fun setForegroundActive(active: Boolean) {
        if (closed) return
        val changed = foreground != active
        foreground = active
        if (!active) { cancelRetry(); activeCancellation?.cancel() }
        if (changed) scheduler.execute {
            if (active) attempt(resetRetry = true) else { refresh(); emit() }
        }
    }

    fun onNetworkChanged(value: BackupNetwork) {
        if (closed) return
        fun permitted(n: BackupNetwork) = n.connected && (allowCellular || n.unmetered)
        val recovered = permitted(value) && !permitted(network)
        network = value
        if (!permitted(value)) { cancelRetry(); activeCancellation?.cancel() }
        scheduler.execute { if (recovered) attempt(resetRetry = true) else { refresh(); emit() } }
    }

    fun onArchiveChanged() {
        if (closed) return
        synchronized(eventLock) {
            debounce?.close()
            debounce = scheduler.schedule(ARCHIVE_DEBOUNCE_MILLIS) { attempt() }
        }
    }

    fun onConnectionChanged() {
        if (closed) return
        cancelRetry()
        scheduler.execute { attempt(resetRetry = true) }
    }

    /** A tap while running cannot queue another run behind the active one. */
    fun backUpNow() {
        if (closed || running) return
        setPaused(false)
    }

    /** Retries keep an explicit pause in place. Use [backUpNow] to unpause. */
    fun retryFailed() {
        if (closed || running) return
        cancelRetry()
        scheduler.execute { attempt(resetRetry = true) }
    }

    /** Hidden recovery action; serialized with all ordinary backup work. */
    fun takeOverOwnFolder(onComplete: () -> Unit = {}) {
        if (closed || running || takingOver) return
        cancelRetry()
        synchronized(eventLock) { debounce?.close(); debounce = null }
        takingOver = true
        scheduler.execute {
            var succeeded = false
            takeoverError = null
            val cancellation = BackupCancellation()
            activeCancellation = cancellation
            try {
                refresh()
                val config = (connection as? SavedConnection.Verified)?.configuration
                    ?: throw BackupException(BackupFailure.Connection)
                val secret = credentials?.takeIf { it.valid() } ?: throw BackupException(BackupFailure.Credentials)
                check(foreground && network.connected && (allowCellular || network.unmetered))
                running = true
                emit()
                checkNotNull(runTakeover)(config, secret, cancellation)
                requestedPause = null
                succeeded = true
            } catch (failure: Exception) {
                java.util.logging.Logger.getLogger("JinbaoBackup").log(java.util.logging.Level.WARNING,
                    "Folder restore failed", failure)
                takeoverError = FolderTakeover.FAILURE_MESSAGE
            } finally {
                activeCancellation = null
                running = false
                takingOver = false
                refresh()
                emit()
            }
            if (succeeded) {
                publish { onComplete() }
                scheduler.execute { attempt(resetRetry = true) }
            }
        }
    }

    fun pause() = setPaused(true)

    private fun setPaused(value: Boolean) {
        if (closed) return
        // The active engine sees this immediately, even while its worker is doing network I/O.
        requestedPause = value
        if (value) cancelRetry()
        scheduler.execute {
            pausePersistenceError = null
            refresh()
            // A premature tap must not opt a future first configuration into automatic uploads.
            if (!value && (connection !is SavedConnection.Verified || credentials?.valid() != true || readOnly)) {
                requestedPause = null
                emit()
                return@execute
            }
            if (stateFailure == null) {
                val configuration = configuration() ?: state?.let { StorageConfiguration(bucket = it.bucket, prefix = it.prefix) }
                    ?: StorageConfiguration()
                val previous = state?.takeIf { it.bucket == configuration.bucket && it.prefix == configuration.prefix }
                    ?: BackupState(bucket = configuration.bucket, prefix = configuration.prefix)
                try {
                    state = previous.copy(paused = value).also(states::save)
                    if (requestedPause == value) requestedPause = null
                } catch (_: Exception) {
                    pausePersistenceError = BackupFailure.State.text
                    stateFailure = pausePersistenceError
                    // A failed resume must not bypass the last persisted pause on the next trigger.
                    if (!value) requestedPause = state?.paused ?: true
                }
            }
            if (value || stateFailure != null) emit() else attempt(resetRetry = true)
        }
    }

    private fun configuration(): StorageConfiguration? = when (val saved = connection) {
        is SavedConnection.Verified -> saved.configuration
        is SavedConnection.Configured -> saved.configuration
        else -> null
    }

    private fun refresh() {
        stateFailure = pausePersistenceError
        try { state = states.load() } catch (_: Exception) { stateFailure = BackupFailure.StateRead.text }
        connection = try { loadConnection() } catch (_: Exception) { SavedConnection.Locked }
        credentials = (connection as? SavedConnection.Verified)?.configuration?.let {
            try { loadCredentials(it) } catch (_: Exception) { null }
        }
        readOnly = try { isReadOnly() } catch (_: Exception) { true }
        // A confirmed parent destination backs up automatically while this app stays open.
        val configuration = (connection as? SavedConnection.Verified)?.configuration
        if (configuration != null && stateFailure == null &&
            (state == null || state?.bucket != configuration.bucket || state?.prefix != configuration.prefix)) {
            try {
                state = BackupState(bucket = configuration.bucket, prefix = configuration.prefix, paused = false).also(states::save)
            } catch (_: Exception) { stateFailure = BackupFailure.State.text }
        }
    }

    private fun paused() = requestedPause ?: state?.paused ?: true

    private fun blocked(ignorePause: Boolean = false): BackupBlockReason? = when {
        stateFailure != null -> BackupBlockReason.State
        connection is SavedConnection.Locked -> BackupBlockReason.Credentials
        connection !is SavedConnection.Verified -> BackupBlockReason.Connection
        credentials?.valid() != true -> BackupBlockReason.Credentials
        readOnly -> BackupBlockReason.ReadOnly
        !ignorePause && paused() -> BackupBlockReason.Paused
        !foreground -> BackupBlockReason.Background
        !network.connected -> BackupBlockReason.Offline
        !allowCellular && !network.unmetered -> BackupBlockReason.Metered
        running -> BackupBlockReason.Running
        else -> null
    }

    private fun emit() {
        if (closed) return
        val config = configuration()
        val bound = state?.takeIf { config != null && it.bucket == config.bucket && it.prefix == config.prefix }
        val reason = blocked()
        val value = BackupCoordinatorState(bound, config, running, paused(), reason, progress,
            stateFailure ?: bound?.lastError, blocked(ignorePause = true) == null,
            takingOver = takingOver, takeoverError = takeoverError)
        publish { if (!closed) mutableState.value = value }
    }

    private fun conditions(): BackupConditions {
        // Re-read the authenticated binding at each transfer boundary, including disconnect/reconfigure.
        val saved = try { loadConnection() } catch (_: Exception) { SavedConnection.Locked }
        val verified = (saved as? SavedConnection.Verified)?.configuration
        val unlocked = verified?.let { try { loadCredentials(it)?.valid() == true } catch (_: Exception) { false } } == true
        return BackupConditions(verified.takeIf { unlocked }, network.connected && network.unmetered,
            paused(), try { isReadOnly() } catch (_: Exception) { true }, networkConnected = network.connected)
    }

    private fun attempt(resetRetry: Boolean = false) {
        if (closed || running || takingOver) return
        if (resetRetry) { cancelRetry(); retryDelay = INITIAL_RETRY_MILLIS }
        refresh()
        normalizeInterrupted()
        progress = null
        if (blocked() != null) { emit(); return }
        val config = (connection as SavedConnection.Verified).configuration
        val secret = checkNotNull(credentials)
        running = true
        emit()
        var failed = false
        var succeeded = false
        var persistenceError: String? = null
        val wasFrozen = state?.pending != null
        try {
            val request = BackupRunRequest(loadSnapshot(), mediaRoot, config, secret, deviceId, now(),
                ::conditions, { value ->
                    progress = value
                    try { state = states.load() } catch (_: Exception) { stateFailure = BackupFailure.StateRead.text }
                    emit()
                }, { !foreground || closed }, loadAnniversaries(), loadParent())
            val cancellation = BackupCancellation()
            activeCancellation = cancellation
            if (!foreground || closed) cancellation.cancel()
            if (runEngine != null) runEngine.invoke(request) else BackupEngine(states, request.conditions,
                cancellation = cancellation, onProgress = request.onProgress, stopAfterObject = request.stopAfterObject,
                allowCellular = allowCellular, isTakeoverReady = isTakeoverReady, parent = request.parent)
                .runOnce(request.snapshot, request.mediaRoot, config, secret, deviceId, request.now, request.anniversaries)
            cancelRetry()
            retryDelay = INITIAL_RETRY_MILLIS
            succeeded = true
        } catch (failure: Exception) {
            failed = !BackupEngine.isDeferred(failure)
            if (failed) {
                // The engine normally persists its error. Also retain failures before it started (e.g. Room).
                val message = BackupEngine.safeError(failure)
                try {
                    val latest = states.load()?.takeIf { it.bucket == config.bucket && it.prefix == config.prefix }
                        ?: BackupState(bucket = config.bucket, prefix = config.prefix, paused = paused())
                    states.save(latest.copy(stage = "failed", lastError = message))
                } catch (_: Exception) { persistenceError = BackupFailure.State.text }
            }
        } finally {
            activeCancellation = null
            running = false
            refresh()
            if (persistenceError != null) stateFailure = persistenceError
            emit()
        }
        // A recovered publication uses its frozen snapshot. Immediately cover the current local snapshot too.
        if (!closed && succeeded && wasFrozen) scheduler.execute { attempt() }
        if (failed && blocked() == null) {
            synchronized(eventLock) {
                retry?.close()
                retry = scheduler.schedule(retryDelay) { attempt() }
                retryDelay = minOf(retryDelay * 2, MAX_RETRY_MILLIS)
            }
        }
    }

    private fun cancelRetry() = synchronized(eventLock) { retry?.close(); retry = null }

    override fun close() {
        closed = true
        foreground = false
        activeCancellation?.cancel()
        cancelRetry()
        synchronized(eventLock) { debounce?.close(); debounce = null }
        scheduler.close()
    }

    companion object {
        const val ARCHIVE_DEBOUNCE_MILLIS = 3_000L
        const val INITIAL_RETRY_MILLIS = 30_000L
        const val MAX_RETRY_MILLIS = 300_000L
    }
}
