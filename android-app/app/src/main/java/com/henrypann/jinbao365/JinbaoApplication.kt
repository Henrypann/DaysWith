package com.henrypann.jinbao365

import android.app.Application
import com.henrypann.jinbao365.backup.AndroidBackup
import com.henrypann.jinbao365.archive.DeviceIdentity
import com.henrypann.jinbao365.data.ArchiveDatabase
import com.henrypann.jinbao365.data.ArchiveRepository
import com.henrypann.jinbao365.media.MediaImporter
import com.henrypann.jinbao365.media.AndroidMediaFacts
import com.henrypann.jinbao365.media.AndroidPreview
import com.henrypann.jinbao365.media.ImportController
import com.henrypann.jinbao365.media.ImportScheduler
import com.henrypann.jinbao365.media.MediaImportService
import com.henrypann.jinbao365.ui.ArchiveUiController
import java.io.File
import java.util.concurrent.Executors

class JinbaoApplication : Application() {
    val parentIdentityStore by lazy { com.henrypann.jinbao365.data.ParentIdentityStore(this) }
    val parentIdentity get() = parentIdentityStore.parent
    lateinit var deviceId: String
        private set

    val archive: ArchiveRepository by lazy {
        ArchiveRepository(ArchiveDatabase.open(this),
            deviceMetadata = { android.os.Build.MANUFACTURER to android.os.Build.MODEL },
            parentIdentity = { parentIdentity })
    }

    private val mediaImporter: MediaImporter by lazy {
        MediaImporter(File(filesDir, "media"), AndroidPreview, AndroidMediaFacts::hasLocation, AndroidMediaFacts::capture)
    }
    val importExecutor get() = ImportScheduler.executor
    val mediaImports: MediaImportService by lazy { MediaImportService(archive, deviceId, mediaImporter) }
    val pendingMedia by lazy { com.henrypann.jinbao365.media.PendingMediaCoordinator(this, archive, deviceId, mediaImports, importExecutor) }
    val imports: ImportController by lazy { ImportController(archive, deviceId, mediaImporter, importExecutor) }
    private val backupOwner = lazy { AndroidBackup.create(this, archive) }
    val backup: AndroidBackup get() = backupOwner.value

    val archiveUi: ArchiveUiController by lazy { ArchiveUiController(this) }

    override fun onTerminate() {
        if (backupOwner.isInitialized()) backupOwner.value.close()
        super.onTerminate()
    }

    override fun onCreate() {
        super.onCreate()
        java.util.Locale.setDefault(java.util.Locale.SIMPLIFIED_CHINESE)
        MediaImporter.cleanStaleTemps(File(filesDir, "media"))
        deviceId = DeviceIdentity.fromContext(this).getOrCreate()
        // One row, finished before any screen or sync reads the cursor. Room rejects
        // the main thread, so the read waits on a background thread.
        val executor = Executors.newSingleThreadExecutor()
        try {
            executor.submit {
                archive.reconcileOwner(deviceId)
                pendingMedia.resumeInterrupted()
            }.get()
        } finally {
            executor.shutdown()
        }
    }
}
