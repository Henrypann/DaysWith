package com.henrypann.jinbao365.backup

import java.io.File
import java.io.IOException
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class BackupStateStoreTest {
    @get:Rule val temporary = TemporaryFolder()
    private fun state() = BackupState(bucket = "example-1234567890", prefix = "life/v1/android/",
        objects = mapOf("object" to BackupObjectState(BackupObjectStatus.uploading, attempts = 2, firstQueuedAt = 123)),
        multipart = mapOf("object" to BackupMultipart("upload", listOf(CosPart(1, "etag", 8_388_608)))),
        pending = BackupPending("ZXhhY3Q=", "Ynl0ZXM=", mapOf("remote" to "local")),
        receipt = BackupReceipt(1, "hash", "manifest", 234, setOf("object"), mapOf("record" to "fingerprint"), packedThrough = 123),
        takeover = BackupTakeover("writer", "ZXhhY3Q="),
        lastSuccessfulBackupAt = 234, lastUploadAtMillis = 200)

    @Test fun durableStateRoundTripsWithoutSecretsAndReplacesAtomically() {
        val folder = temporary.newFolder()
        var syncs = 0
        val store = BackupStateStore(folder) { syncs++ }
        assertNull(store.load())
        store.save(state())
        assertEquals(state(), BackupStateStore(folder).load())
        assertEquals(1, syncs)
        assertFalse(File(folder, "state.json.new").exists())
        store.save(state().copy(stage = "complete"))
        assertEquals("complete", store.load()!!.stage)
        assertFalse(File(folder, "state.json").readText().contains("secret", ignoreCase = true))
    }

    @Test fun pauseSurvivesColdRestartAndOldDocumentsDefaultToPaused() {
        val folder = temporary.newFolder()
        val store = BackupStateStore(folder)
        store.save(state().copy(paused = true))
        assertTrue(BackupStateStore(folder).load()!!.paused)
        val file = File(folder, "state.json")
        file.writeText(file.readText().replace(",\"paused\":true", ""))
        assertTrue(BackupStateStore(folder).load()!!.paused)
    }

    @Test fun newStateStartsPausedAndExplicitUnpauseSurvivesRestart() {
        assertTrue(BackupState(bucket = "example-1234567890", prefix = "life/v1/android/").paused)
        val folder = temporary.newFolder()
        BackupStateStore(folder).save(state().copy(paused = false))
        assertFalse(BackupStateStore(folder).load()!!.paused)
    }

    @Test fun oldReceiptWithoutPackedThroughDoesNotAcquireCoverageOnLoad() {
        val folder = temporary.newFolder()
        BackupStateStore(folder).save(state())
        val file = File(folder, "state.json")
        file.writeText(file.readText().replace(",\"packedThrough\":123", ""))
        val receipt = BackupStateStore(folder).load()!!.receipt!!
        assertNull(receipt.packedThrough)
        assertEquals("hash", receipt.commitHash)
    }

    @Test fun oldStateDoesNotInventAnUploadTimestampFromACommit() {
        val folder = temporary.newFolder()
        BackupStateStore(folder).save(state())
        val file = File(folder, "state.json")
        file.writeText(file.readText().replace(",\"lastUploadAtMillis\":200", ""))
        val loaded = BackupStateStore(folder).load()!!
        assertNull(loaded.lastUploadAtMillis)
        assertEquals(234L, loaded.receipt!!.publishedAt)
    }

    @Test fun directoryFsyncFailureIsNeverAcknowledged() {
        val folder = temporary.newFolder()
        val store = BackupStateStore(folder) { throw IOException("injected fsync") }
        try { store.save(state()); fail() } catch (_: IOException) { }
        // A complete atomic document may have made it to disk; ambiguous persistence is safe to retry.
        assertEquals(state(), BackupStateStore(folder).load())
    }

    @Test fun interruptedTemporaryWriteCannotReplaceReceipt() {
        val folder = temporary.newFolder()
        val store = BackupStateStore(folder)
        store.save(state())
        File(folder, "state.json.new").writeText("partial")
        assertEquals(state(), BackupStateStore(folder).load())
    }

    @Test fun failedRestoreCanReturnToPreviouslyAbsentState() {
        val folder = temporary.newFolder()
        val store = BackupStateStore(folder)
        store.save(state())
        store.restore(null)
        assertNull(BackupStateStore(folder).load())
        assertFalse(File(folder, "state.json").exists())
    }

    @Test fun restoreRollbackKeepsOriginalReceiptAndPause() {
        val folder = temporary.newFolder()
        val store = BackupStateStore(folder)
        val original = state().copy(takeover = null, paused = true)
        store.save(original)
        store.save(state().copy(paused = false))
        store.restore(original)
        assertEquals(original, BackupStateStore(folder).load())
    }

    @Test fun corruptStateFailsClosedInsteadOfStartingFresh() {
        val folder = temporary.newFolder()
        File(folder, "state.json").writeText("{broken")
        try { BackupStateStore(folder).load(); fail() } catch (failure: IOException) {
            assertEquals("无法读取备份进度，请保留本机原件后重试。", failure.message)
        }
    }

    @Test fun secondStoreCannotRunDuringFirstStoresLease() {
        val folder = temporary.newFolder()
        val first = BackupStateStore(folder)
        val second = BackupStateStore(folder)
        first.exclusive {
            try { second.exclusive { fail("must not acquire") }; fail() }
            catch (failure: IllegalStateException) { assertEquals("A backup is already running.", failure.message) }
        }
        second.exclusive { second.save(state()) }
        assertEquals(state(), first.load())
    }
}
