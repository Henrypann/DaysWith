package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.storage.SavedConnection
import com.henrypann.jinbao365.storage.StorageConfiguration
import com.henrypann.jinbao365.storage.StorageCredentials
import java.io.File
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

class BackupCoordinatorTest {
    @Test fun independentAnniversaryChangeSchedulesCurrentOwnerAndRowsWithoutRecordMutation() {
        val parent = com.henrypann.jinbao365.data.ParentIdentity.Mom
        val destination = StorageConfiguration(bucket = "example-1234567890", prefix = parent.prefix)
        val persistence = MemoryBackupState().apply { value = BackupState(bucket = destination.bucket, prefix = destination.prefix, paused = false) }
        val scheduler = TestBackupScheduler()
        var values = emptyList<com.henrypann.jinbao365.data.Anniversary>()
        val requests = mutableListOf<BackupRunRequest>()
        val coordinator = BackupCoordinator(persistence, { SavedConnection.Verified(destination) }, { StorageCredentials("fake", "fake") },
            { ArchiveSnapshot.empty() }, { false }, File("unused"), "00000000-0000-4000-8000-000000000001",
            scheduler = scheduler, runEngine = { request -> requests += request; receipt },
            loadAnniversaries = { values }, loadParent = { parent })
        coordinator.onNetworkChanged(BackupNetwork(true, true))
        coordinator.setForegroundActive(true)
        scheduler.drain()
        val initial = requests.size
        values = listOf(com.henrypann.jinbao365.data.Anniversary("00000000-0000-4000-8000-000000000099", parent,
            "生日", java.time.LocalDate.of(2020, 2, 29)))
        coordinator.onArchiveChanged()
        scheduler.advance(BackupCoordinator.ARCHIVE_DEBOUNCE_MILLIS)
        assertEquals(initial + 1, requests.size)
        assertEquals(values, requests.last().anniversaries)
        assertEquals(parent, requests.last().parent)
        assertTrue(requests.last().snapshot.records.isEmpty())
        coordinator.close()
    }

    private val config = StorageConfiguration(bucket = "example-1234567890", prefix = "life/v1/android/")
    private val receipt = BackupReceipt(1, "commit", "manifest", 123, emptySet(), emptyMap())
    private val states = MemoryBackupState().apply { value = BackupState(bucket = config.bucket, prefix = config.prefix, paused = true) }
    private val worker = TestBackupScheduler()
    private var connection: SavedConnection = SavedConnection.Verified(config)
    private var secret: StorageCredentials? = StorageCredentials("test", "test")
    private var readOnly = false
    private var runs = 0
    private var work: (BackupRunRequest) -> Unit = {}
    private fun coordinator(persistence: BackupStatePersistence = states, scheduler: BackupScheduler = worker,
                            dispatch: ((() -> Unit) -> Unit) = { it() }, allowCellular: Boolean = false) = BackupCoordinator(
        persistence, { connection }, { secret }, { ArchiveSnapshot.empty() }, { readOnly }, File("unused"),
        "00000000-0000-4000-8000-000000000001", scheduler, dispatch, { worker.time }, { request ->
            runs++
            work(request)
            states.save((states.load() ?: BackupState(bucket = config.bucket, prefix = config.prefix))
                .copy(stage = "complete", lastError = null, pending = null, receipt = receipt))
            receipt
        }, allowCellular = allowCellular,
    )
    private fun ready(coordinator: BackupCoordinator, start: Boolean = true) {
        coordinator.onNetworkChanged(BackupNetwork(true, true))
        worker.drain()
        coordinator.setForegroundActive(true)
        worker.drain()
        if (start) { coordinator.backUpNow(); worker.drain() }
    }

    @Test fun firstVerifiedParentDestinationStartsAutomaticallyWhileForeground() {
        states.value = null
        connection = SavedConnection.Missing
        val coordinator = coordinator()
        ready(coordinator, start = false)
        assertEquals(0, runs)
        connection = SavedConnection.Verified(config)
        coordinator.onConnectionChanged(); worker.drain()
        assertEquals(1, runs)
        assertFalse(states.load()!!.paused)
        assertEquals(receipt, coordinator.uiState.lastReceipt)
    }

    @Test fun firstBucketVerificationOnCellularUnpausesAndBacksUpWithoutManualTap() {
        states.value = null
        connection = SavedConnection.Configured(config)
        val coordinator = coordinator(allowCellular = BackupPolicy.ALLOW_CELLULAR)
        coordinator.onNetworkChanged(BackupNetwork(true, false))
        coordinator.setForegroundActive(true)
        worker.drain()
        assertEquals(0, runs)
        connection = SavedConnection.Verified(config)
        coordinator.onConnectionChanged()
        worker.drain()
        assertFalse(coordinator.uiState.paused)
        assertEquals(1, runs)
        assertEquals(receipt, coordinator.uiState.lastReceipt)
    }

    @Test fun wifiOnlyHasRequestedWaitingMessage() {
        val coordinator = coordinator(allowCellular = false)
        ready(coordinator)
        coordinator.onNetworkChanged(BackupNetwork(true, false)); worker.drain()
        assertEquals(BackupBlockReason.Metered, coordinator.uiState.blockReason)
        assertEquals("连上 Wi‑Fi 后会自动备份", coordinator.uiState.blockReason!!.text)
    }

    @Test fun replacingDestinationStartsWithAFreshAutomaticBackup() {
        val coordinator = coordinator()
        ready(coordinator)
        connection = SavedConnection.Verified(config.copy(prefix = "life/v1/mom/"))
        coordinator.onConnectionChanged(); worker.drain()
        assertEquals(2, runs)
        assertFalse(coordinator.uiState.paused)
        assertEquals("life/v1/mom/", coordinator.uiState.configuration!!.prefix)
    }

    @Test fun prematureBackupTapCannotUnpauseAnUnverifiedFirstConfiguration() {
        connection = SavedConnection.Configured(config)
        val coordinator = coordinator()
        ready(coordinator)
        assertEquals(0, runs)
        assertEquals(BackupBlockReason.Connection, coordinator.uiState.blockReason)
        assertTrue(coordinator.uiState.paused)
        connection = SavedConnection.Verified(config)
        coordinator.onConnectionChanged(); worker.drain()
        assertEquals(0, runs)
        assertTrue(states.load()!!.paused)
        coordinator.backUpNow(); worker.drain()
        assertEquals(1, runs)
        assertFalse(states.load()!!.paused)
    }

    @Test fun retryFailedRetainsPauseAndStartsAnUnpausedFailedRun() {
        val coordinator = coordinator()
        ready(coordinator, start = false)
        coordinator.retryFailed(); worker.drain()
        assertEquals(0, runs)
        work = { throw CosException(CosFailure.Network) }
        coordinator.backUpNow(); worker.drain()
        assertEquals(1, runs)
        work = {}
        coordinator.retryFailed(); worker.drain()
        assertEquals(2, runs)
        assertNull(coordinator.uiState.lastError)
    }

    @Test fun foregroundAndManualAndRecoveredNetworkTriggerRuns() {
        val coordinator = coordinator()
        ready(coordinator)
        assertEquals(1, runs)
        coordinator.backUpNow(); worker.drain()
        assertEquals(2, runs)
        coordinator.onNetworkChanged(BackupNetwork(true, false)); worker.drain()
        assertEquals(BackupBlockReason.Metered, coordinator.uiState.blockReason)
        coordinator.onNetworkChanged(BackupNetwork(true, true)); worker.drain()
        assertEquals(3, runs)
        coordinator.setForegroundActive(false); worker.drain()
        assertEquals(BackupBlockReason.Background, coordinator.uiState.blockReason)
        coordinator.setForegroundActive(true); worker.drain()
        assertEquals(4, runs)
    }

    @Test fun archiveNotificationsDebounceThreeSeconds() {
        val coordinator = coordinator()
        ready(coordinator)
        coordinator.onArchiveChanged()
        worker.advance(2_999)
        assertEquals(1, runs)
        coordinator.onArchiveChanged()
        worker.advance(2_999)
        assertEquals(1, runs)
        worker.advance(1)
        assertEquals(2, runs)
    }

    @Test fun everyUnavailableConditionBlocksManualBackupAndPublishesReason() {
        val coordinator = coordinator()
        ready(coordinator)
        val before = runs
        fun blocked(reason: BackupBlockReason) {
            coordinator.backUpNow(); worker.drain()
            assertEquals(reason, coordinator.uiState.blockReason)
            assertFalse(coordinator.uiState.canBackUpNow)
            assertEquals(before, runs)
        }
        connection = SavedConnection.Missing; blocked(BackupBlockReason.Connection)
        connection = SavedConnection.Configured(config); blocked(BackupBlockReason.Connection)
        connection = SavedConnection.Locked; blocked(BackupBlockReason.Credentials)
        connection = SavedConnection.Verified(config)
        secret = null; blocked(BackupBlockReason.Credentials)
        secret = StorageCredentials("test", "test")
        readOnly = true; blocked(BackupBlockReason.ReadOnly)
        readOnly = false
        coordinator.onNetworkChanged(BackupNetwork()); worker.drain(); blocked(BackupBlockReason.Offline)
        coordinator.onNetworkChanged(BackupNetwork(true, false)); worker.drain(); blocked(BackupBlockReason.Metered)
        coordinator.pause(); worker.drain()
        coordinator.retryFailed(); worker.drain()
        assertEquals(BackupBlockReason.Paused, coordinator.uiState.blockReason)
        assertEquals(before, runs)
    }

    @Test fun runningBlocksReentrantManualTapAndPublishesRunningState() {
        val coordinator = coordinator()
        work = {
            assertTrue(coordinator.uiState.running)
            assertEquals(BackupBlockReason.Running, coordinator.uiState.blockReason)
            assertFalse(coordinator.uiState.canBackUpNow)
            coordinator.backUpNow()
        }
        ready(coordinator)
        assertEquals(1, runs)
        assertFalse(coordinator.uiState.running)
        assertTrue(coordinator.uiState.canBackUpNow)
    }

    @Test fun activeRunSeesPauseNetworkAndConnectionChangesWithoutWaitingForWorker() {
        val coordinator = coordinator()
        work = { request ->
            assertEquals(config, request.conditions().verifiedConfiguration)
            connection = SavedConnection.Configured(config)
            coordinator.onConnectionChanged()
            assertNull(request.conditions().verifiedConfiguration)
            connection = SavedConnection.Verified(config)
            coordinator.onNetworkChanged(BackupNetwork(true, false))
            assertFalse(request.conditions().unmeteredWifi)
            coordinator.pause()
            assertTrue(request.conditions().paused)
            coordinator.setForegroundActive(false)
            assertTrue(request.stopAfterObject())
        }
        ready(coordinator)
        assertEquals(1, runs)
        assertTrue(states.load()!!.paused)
    }

    @Test fun failureRetriesAfterThirtySecondsThenSixtyAndManualRetryResetsBackoff() {
        val coordinator = coordinator()
        work = { throw CosException(CosFailure.Network) }
        ready(coordinator)
        assertNotNull(coordinator.uiState.lastError)
        worker.advance(29_999); assertEquals(1, runs)
        worker.advance(1); assertEquals(2, runs)
        worker.advance(59_999); assertEquals(2, runs)
        worker.advance(1); assertEquals(3, runs)
        coordinator.backUpNow(); worker.drain(); assertEquals(4, runs)
        worker.advance(30_000); assertEquals(5, runs)
        work = {}
        coordinator.backUpNow(); worker.drain(); assertEquals(6, runs)
        worker.advance(300_000); assertEquals(6, runs)
    }

    @Test fun successfulArchiveChangeCancelsPreviouslyScheduledFailureRetry() {
        val coordinator = coordinator()
        work = { throw CosException(CosFailure.Network) }
        ready(coordinator)
        work = {}
        coordinator.onArchiveChanged(); worker.advance(3_000)
        assertEquals(2, runs)
        worker.advance(30_000)
        assertEquals(2, runs)
    }

    @Test fun backgroundCancelsRetryAndForegroundResumesIt() {
        val coordinator = coordinator()
        work = { throw CosException(CosFailure.Network) }
        ready(coordinator)
        coordinator.setForegroundActive(false); worker.drain()
        worker.advance(300_000)
        assertEquals(1, runs)
        coordinator.setForegroundActive(true); worker.drain()
        assertEquals(2, runs)
    }

    @Test fun pauseBeforeFirstBackupPersistsAndSurvivesNewCoordinator() {
        connection = SavedConnection.Missing
        val first = coordinator()
        first.pause(); worker.drain()
        assertTrue(states.load()!!.paused)
        first.close()
        connection = SavedConnection.Verified(config)
        val nextWorker = TestBackupScheduler()
        val next = coordinator(scheduler = nextWorker)
        next.onNetworkChanged(BackupNetwork(true, true))
        next.setForegroundActive(true); nextWorker.drain()
        assertEquals(0, runs)
        assertEquals(BackupBlockReason.Paused, next.uiState.blockReason)
        next.backUpNow(); nextWorker.drain()
        assertFalse(states.load()!!.paused)
        assertEquals(1, runs)
    }

    @Test fun failedResumeCannotRunOrLoseItsPersistenceErrorOnLaterTriggers() {
        states.value = BackupState(bucket = config.bucket, prefix = config.prefix, paused = true)
        val failing = object : BackupStatePersistence {
            override fun load() = states.load()
            override fun save(state: BackupState) = throw IOException("injected save failure")
        }
        val coordinator = coordinator(failing)
        ready(coordinator, start = false)
        coordinator.backUpNow(); worker.drain()
        assertEquals(BackupBlockReason.State, coordinator.uiState.blockReason)
        assertEquals(BackupFailure.State.text, coordinator.uiState.lastError)
        coordinator.backUpNow(); worker.drain()
        assertEquals(0, runs)
        assertTrue(coordinator.uiState.paused)
        assertEquals(BackupBlockReason.State, coordinator.uiState.blockReason)
    }

    @Test fun corruptStateFailsClosedWithoutStartingEngine() {
        val broken = object : BackupStatePersistence {
            override fun load(): BackupState? = throw IOException()
            override fun save(state: BackupState) = error("Must not overwrite corruption")
        }
        val coordinator = coordinator(broken)
        ready(coordinator)
        assertEquals(0, runs)
        assertEquals(BackupBlockReason.State, coordinator.uiState.blockReason)
    }

    @Test fun restoredFrozenPublicationSchedulesCurrentSnapshotAfterSuccess() {
        states.value = BackupState(bucket = config.bucket, prefix = config.prefix,
            pending = BackupPending("bytes", "bytes", emptyMap()))
        val coordinator = coordinator()
        ready(coordinator)
        assertEquals(2, runs)
    }

    @Test fun startupNormalizesInterruptedObjectsWithoutLosingAttemptsOrSessions() {
        states.value = BackupState(bucket = config.bucket, prefix = config.prefix, stage = "uploading",
            objects = mapOf("key" to BackupObjectState(BackupObjectStatus.uploading, attempts = 2, firstQueuedAt = 12)),
            multipart = mapOf("key" to BackupMultipart("upload")))
        val coordinator = coordinator(); worker.drain()
        assertEquals(BackupObjectStatus.pending, coordinator.uiState.state!!.objects.getValue("key").status)
        assertEquals(2, states.value!!.objects.getValue("key").attempts)
        assertEquals("upload", states.value!!.multipart.getValue("key").uploadId)
    }

    @Test fun uiPublicationUsesProvidedDispatcher() {
        val publications = mutableListOf<() -> Unit>()
        val coordinator = coordinator(dispatch = { publications += it })
        worker.drain()
        assertEquals(BackupBlockReason.Loading, coordinator.uiState.blockReason)
        publications.forEach { it() }
        assertEquals(BackupBlockReason.Paused, coordinator.uiState.blockReason)
    }
}

private class TestBackupScheduler : BackupScheduler {
    private data class Task(val at: Long, val action: () -> Unit, var cancelled: Boolean = false)
    private val tasks = mutableListOf<Task>()
    var time = 0L
    override fun execute(action: () -> Unit) { schedule(0, action) }
    override fun schedule(delayMillis: Long, action: () -> Unit): AutoCloseable {
        val task = Task(time + delayMillis, action)
        tasks += task
        return AutoCloseable { task.cancelled = true }
    }
    fun drain() {
        while (true) {
            val task = tasks.filter { !it.cancelled && it.at <= time }.minByOrNull { it.at } ?: return
            tasks.remove(task)
            task.action()
        }
    }
    fun advance(millis: Long) { time += millis; drain() }
    override fun close() { tasks.clear() }
}
