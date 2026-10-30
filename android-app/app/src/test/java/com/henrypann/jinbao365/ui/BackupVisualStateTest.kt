package com.henrypann.jinbao365.ui

import com.henrypann.jinbao365.backup.BackupBlockReason
import com.henrypann.jinbao365.backup.BackupSummary
import org.junit.Assert.assertEquals
import org.junit.Test

class BackupVisualStateTest {
    @Test fun successRequiresCoverageAndConnection() {
        assertEquals(BackupVisualState.Disconnected, backupVisualState(BackupSummary(allCovered = true)))
        assertEquals(BackupVisualState.Complete, backupVisualState(BackupSummary(allCovered = true, blockReason = null)))
        assertEquals(BackupVisualState.Waiting, backupVisualState(BackupSummary(blockReason = null)))
        assertEquals(BackupVisualState.Waiting, backupVisualState(BackupSummary(allCovered = true, blockReason = BackupBlockReason.Offline)))
    }

    @Test fun activeAndFailureStatesNeverShowSuccess() {
        assertEquals(BackupVisualState.Progress, backupVisualState(BackupSummary(inProgress = true, allCovered = true)))
        assertEquals(BackupVisualState.Failed, backupVisualState(BackupSummary(failedCount = 1, allCovered = true)))
        assertEquals(BackupVisualState.Failed, backupVisualState(BackupSummary(blockReason = BackupBlockReason.Credentials)))
        assertEquals(BackupVisualState.Loading, backupVisualState(null))
    }
}
