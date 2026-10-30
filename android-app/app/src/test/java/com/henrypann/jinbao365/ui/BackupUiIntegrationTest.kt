package com.henrypann.jinbao365.ui

import android.content.Context
import androidx.room.Room
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.test.core.app.ApplicationProvider
import com.henrypann.jinbao365.backup.*
import com.henrypann.jinbao365.data.ArchiveDatabase
import com.henrypann.jinbao365.data.ArchiveRepository
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.SQLiteMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@SQLiteMode(SQLiteMode.Mode.NATIVE)
class BackupUiIntegrationTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val database = Room.inMemoryDatabaseBuilder(context, ArchiveDatabase::class.java).allowMainThreadQueries().build()
    private val archive = ArchiveRepository(database)
    private var notifications = 0
    private val observer = CommittedArchiveObserver { notifications++ }
    private fun refresh() = observer.accept(archive.loadSnapshot())
    @After fun close() { database.close() }


    @Test fun lateHostBindingTracksBackgroundAndRestartAndDisposes() {
        val owner = object : LifecycleOwner {
            val registry = LifecycleRegistry.createUnsafe(this)
            override val lifecycle: Lifecycle get() = registry
        }
        owner.registry.currentState = Lifecycle.State.RESUMED
        val states = mutableListOf<Boolean>()
        val binding = BackupForegroundBinding(owner.lifecycle, states::add)
        assertEquals(true, states.last())
        owner.registry.currentState = Lifecycle.State.CREATED
        assertEquals(false, states.last())
        owner.registry.currentState = Lifecycle.State.RESUMED
        assertEquals(true, states.last())
        binding.close()
        assertEquals(false, states.last())
        val count = states.size
        owner.registry.currentState = Lifecycle.State.CREATED
        owner.registry.currentState = Lifecycle.State.RESUMED
        assertEquals(count, states.size)
    }

    @Test fun draftWritesDoNotNotifyButCommitAndSubsequentEditsDo() {
        refresh()
        archive.createDraft("phone", 100, "note")
        archive.updateDraft("note", "phone", 101) { it.copy(note = "Saved note") }
        refresh()
        assertEquals(0, notifications)
        archive.commitDraft("note")
        refresh()
        assertEquals(1, notifications)
        refresh()
        archive.commitDraft("note") // Idempotent save is not another committed edit.
        refresh()
        assertEquals(1, notifications)
        archive.editRecord("note", "phone", 102) { it.copy(note = "Edited note") }
        refresh()
        assertEquals(2, notifications)
        archive.trashRecord("note", "phone", 103)
        refresh()
        archive.restoreRecord("note", "phone", 104)
        refresh()
        assertEquals(4, notifications)
    }

    @Test fun detailUsesPerRecordCoverageEvenWhenOverallArchiveHasPendingChanges() {
        val summary = BackupSummary(unbackedRecordCount = 1, paused = false, blockReason = null,
            recordStatuses = mapOf("covered" to BackupRecordStatus.BackedUp, "edited" to BackupRecordStatus.Pending,
                "failed" to BackupRecordStatus.Failed))
        assertEquals("已备份", recordBackupStatusText(summary, "covered"))
        assertEquals("等待备份", recordBackupStatusText(summary, "edited"))
        assertEquals("有一项备份没成功，点这里重试", recordBackupStatusText(summary, "failed"))
        assertEquals("已保存在这台手机", recordBackupStatusText(summary, "unknown"))
    }

    @Test fun textOnlyOverdueReminderUsesQueryRatherThanOriginalCount() {
        archive.createDraft("phone", 100, "note")
        archive.updateDraft("note", "phone", 101) { it.copy(note = "Text only") }
        archive.commitDraft("note")
        val query = DefaultBackupStatusQuery()
        val atBoundary = query.query(archive.loadSnapshot(), null, 101 + BackupEngine.DAY_MILLIS)
        assertFalse(atBoundary.hasOverdue)
        val summary = query.query(archive.loadSnapshot(), null, 102 + BackupEngine.DAY_MILLIS)
        assertTrue(summary.hasOverdue)
        assertEquals(0, summary.overdueOriginalCount)
        assertEquals("有记录超过24小时未备份，轻点立即备份", backupReminderText(summary))
    }
}
