package com.henrypann.jinbao365.ui

import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.henrypann.jinbao365.JinbaoApplication
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.archive.ArchiveProtocolException
import com.henrypann.jinbao365.archive.ArchiveValidationException
import com.henrypann.jinbao365.backup.V1ValidationException
import com.henrypann.jinbao365.backup.BackupCancellation
import com.henrypann.jinbao365.backup.ParentArchiveReader
import com.henrypann.jinbao365.data.LocalSyncState
import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.data.Anniversary
import com.henrypann.jinbao365.data.AnniversarySource
import com.henrypann.jinbao365.data.DefaultAnniversaries
import java.time.LocalDate
import com.henrypann.jinbao365.data.StoredDraft
import com.henrypann.jinbao365.media.AndroidImportRequests
import com.henrypann.jinbao365.media.ImportRejected
import com.henrypann.jinbao365.storage.SavedConnection
import com.henrypann.jinbao365.storage.StorageConnectionStore
import java.io.File
import java.util.concurrent.CancellationException
import java.util.concurrent.Executors

/** Own records live in Room; the other parent's verified cache is merged only for presentation. */
class ArchiveUiController(private val app: JinbaoApplication) {
    var snapshot by mutableStateOf<ArchiveSnapshot?>(null)
        private set
    var ownSnapshot by mutableStateOf<ArchiveSnapshot?>(null)
        private set
    private var remoteSnapshot = ArchiveSnapshot.empty()
    var syncState by mutableStateOf<LocalSyncState?>(null)
        private set
    var drafts by mutableStateOf<List<StoredDraft>>(emptyList())
        private set
    var anniversaries by mutableStateOf<List<Anniversary>>(emptyList())
        private set
    var ownAnniversaries by mutableStateOf<List<Anniversary>>(emptyList())
        private set
    var busy by mutableStateOf(false)
        private set
    var loading by mutableStateOf(true)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    var remoteError by mutableStateOf<String?>(null)
        private set
    var readyDraftId by mutableStateOf<String?>(null)
        private set
    var focusNote by mutableStateOf(false)
        private set
    val readOnly: Boolean get() = syncState?.resyncFromStart == true
    private val main = Handler(Looper.getMainLooper())
    private val committedChanges = CommittedArchiveObserver { app.backup.onArchiveChanged() }
    private val remoteWorker = Executors.newSingleThreadExecutor { task -> Thread(task, "jinbao365-family-read") }
    private val remoteReader = ParentArchiveReader(File(app.filesDir, "media"),
        cacheAnniversaries = app.archive::cacheOtherAnniversaries)
    @Volatile private var foreground = false
    private var remoteBusy = false
    @Volatile private var generation = 0L
    private var remoteCancellation: BackupCancellation? = null

    init { refresh() }

    fun canEdit(recordId: String): Boolean = !readOnly && app.parentIdentity != null &&
        ownSnapshot?.records?.any { it.id == recordId } == true

    fun parentOf(recordId: String): ParentIdentity? = when {
        ownSnapshot?.records?.any { it.id == recordId } == true -> app.parentIdentity
        remoteSnapshot.records.any { it.id == recordId } -> app.parentIdentity?.other
        else -> null
    }

    fun dismissError() { error = null }
    fun showError(message: String) { error = message }
    fun consumeDraft() { readyDraftId = null }

    private fun mergeForDisplay() {
        snapshot = ownSnapshot?.let { own -> own.copy(
            records = own.records + remoteSnapshot.records,
            assets = own.assets + remoteSnapshot.assets,
            resources = own.resources + remoteSnapshot.resources,
        ) }
    }

    fun setForegroundActive(active: Boolean) {
        foreground = active
        if (active) refreshRemote() else {
            generation++
            remoteCancellation?.cancel()
            remoteBusy = false
        }
    }

    fun onConnectionChanged() {
        generation++
        remoteCancellation?.cancel()
        remoteBusy = false
        remoteSnapshot = ArchiveSnapshot.empty()
        anniversaries = DefaultAnniversaries.merge(ownAnniversaries, app.parentIdentity).filter { it.deletedAt == null }
        remoteError = null
        mergeForDisplay()
        refresh()
        refreshRemote()
    }

    fun refreshRemote() {
        if (!foreground || remoteBusy) return
        val owner = app.parentIdentity ?: return
        remoteBusy = true
        val token = ++generation
        val cancellation = BackupCancellation().also { remoteCancellation = it }
        remoteWorker.execute {
            try {
                val store = StorageConnectionStore(app)
                val connection = store.load() as? SavedConnection.Verified
                if (connection != null) {
                    val cached = remoteReader.loadCached(owner, connection.configuration)
                    val source = AnniversarySource(connection.configuration.bucket, connection.configuration.region)
                    val cachedAnniversaries = app.archive.loadVisibleAnniversaries(owner, source)
                    main.post { if (generation == token && foreground) {
                        remoteSnapshot = cached; acceptAnniversaries(cachedAnniversaries); mergeForDisplay()
                    } }
                    val credentials = store.credentialsForVerified(connection.configuration)
                        ?: error("credentials unavailable")
                    val next = remoteReader.read(connection.configuration, credentials, owner,
                        isActive = { foreground && generation == token }, cancellation = cancellation,
                        selfDeviceId = com.henrypann.jinbao365.archive.DeviceIdentity.fromContext(app).getOrCreate())
                    val nextAnniversaries = app.archive.loadVisibleAnniversaries(owner, source)
                    main.post { if (generation == token && foreground) {
                        remoteSnapshot = next; acceptAnniversaries(nextAnniversaries); remoteError = null; mergeForDisplay()
                    } }
                }
            } catch (_: CancellationException) {
                // The last completely verified cache remains visible when leaving the app.
            } catch (failure: Exception) {
                logArchiveFailure("Could not read the other parent's archive", failure)
                main.post { if (generation == token && foreground) {
                    remoteError = if (failure is V1ValidationException || failure is ArchiveProtocolException ||
                        failure is ArchiveValidationException) BACKUP_RETRY_MESSAGE
                    else "暂时没有读到${owner.other.label}的新记录，已保存的记录仍可查看。"
                } }
            } finally { main.post { if (generation == token) remoteBusy = false } }
        }
    }

    fun refresh() { app.importExecutor.execute { reload() } }

    private fun reload() {
        try {
            val connectionGeneration = generation
            val nextSnapshot = app.archive.loadSnapshot()
            val nextSync = app.archive.localSyncState()
            val nextDrafts = app.archive.loadDrafts()
            val source = runCatching { (StorageConnectionStore(app).load() as? SavedConnection.Verified)?.configuration }.getOrNull()?.let {
                AnniversarySource(it.bucket, it.region)
            }
            val nextAnniversaries = app.parentIdentity?.let { app.archive.loadVisibleAnniversaries(it, source) }.orEmpty()
            committedChanges.accept(nextSnapshot)
            main.post {
                ownSnapshot = nextSnapshot
                syncState = nextSync
                drafts = nextDrafts
                acceptAnniversaries(if (connectionGeneration == generation) nextAnniversaries
                    else nextAnniversaries.filter { it.owner == app.parentIdentity })
                mergeForDisplay()
                loading = false
            }
        } catch (failure: Exception) {
            logArchiveFailure("Could not load local records", failure)
            main.post { loading = false; error = "暂时无法读取本机记录，请重试。" }
        }
    }

    private fun acceptAnniversaries(values: List<Anniversary>) {
        anniversaries = DefaultAnniversaries.merge(values, app.parentIdentity).filter { it.deletedAt == null }.sortedWith(compareBy({ it.date.monthValue }, { it.date.dayOfMonth }, { it.title }))
        ownAnniversaries = values.filter { it.owner == app.parentIdentity }
    }

    fun saveAnniversary(id: String?, title: String, date: LocalDate, onSaved: () -> Unit = {}) = editAnniversary(onSaved) {
        app.archive.saveAnniversary(it, id, title, date)
    }

    fun deleteAnniversary(id: String) = editAnniversary {
        app.archive.deleteAnniversary(it, id, System.currentTimeMillis())
    }

    private fun editAnniversary(onSaved: () -> Unit = {}, action: (ParentIdentity) -> Unit) {
        val owner = app.parentIdentity ?: return
        if (busy || loading || readOnly) return
        busy = true
        error = null
        app.importExecutor.execute {
            try {
                action(owner)
                // This independent table does not change the record snapshot observer.
                app.backup.onArchiveChanged()
                reload()
                main.post { busy = false; onSaved() }
            } catch (_: Exception) {
                main.post { busy = false; error = "纪念日没有保存成功，请检查标题和日期后重试。" }
            }
        }
    }

    fun createMoment(uris: List<Uri> = emptyList(), fromPhotoPicker: Boolean = true) {
        if (busy || loading || ownSnapshot == null || readOnly || app.parentIdentity == null) return
        busy = true
        error = null
        app.importExecutor.execute {
            var draftId: String? = null
            var failureMessage: String? = null
            try {
                draftId = app.archive.createDraft(app.deviceId, System.currentTimeMillis()).record.id
                if (uris.isNotEmpty()) {
                    val requests = uris.map { AndroidImportRequests.create(app, it, fromPhotoPicker) }
                    app.mediaImports.importToDraft(draftId, requests)
                }
            } catch (failure: Exception) {
                logArchiveFailure("Could not import selected media", failure)
                failureMessage = if (failure is ImportRejected) failure.message else "暂时无法导入这些照片或视频，请重试。"
                // A rejected selection must not open or leave behind an empty editor draft.
                draftId?.let { id -> runCatching { app.archive.discardDraft(id) } }
                draftId = null
            }
            reload()
            val openId = draftId
            val message = failureMessage
            main.post {
                busy = false
                error = message
                readyDraftId = openId
                focusNote = uris.isEmpty()
            }
        }
    }

    fun setTrashed(recordId: String, restore: Boolean, onDone: () -> Unit) {
        if (!canEdit(recordId) || busy) return
        busy = true
        app.importExecutor.execute {
            try {
                if (restore) app.archive.restoreRecord(recordId, app.deviceId, System.currentTimeMillis())
                else app.archive.trashRecord(recordId, app.deviceId, System.currentTimeMillis())
                reload()
                main.post { busy = false; onDone() }
            } catch (failure: Exception) {
                logArchiveFailure("Could not update record", failure)
                main.post { busy = false; error = "暂时无法更新这条记录，请重试。" }
            }
        }
    }
}

internal fun logArchiveFailure(operation: String, failure: Exception) {
    if (failure !is CancellationException) {
        java.util.logging.Logger.getLogger("JinbaoArchive").log(java.util.logging.Level.WARNING, operation, failure)
    }
}
