package com.henrypann.jinbao365.ui

import com.henrypann.jinbao365.backup.BackupBlockReason
import com.henrypann.jinbao365.backup.BackupRecordStatus
import com.henrypann.jinbao365.backup.BackupSummary
import java.time.Instant
import java.time.ZoneId
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

class BackupUiTextTest {
    @Test fun failuresAlwaysOfferTheSameRetryCopy() {
        val summary = BackupSummary(paused = false, failedCount = 1,
            recordStatuses = mapOf("record" to BackupRecordStatus.Failed))
        assertEquals("有一项备份没成功，点这里重试", backupStatusText(summary))
        assertEquals("有一项备份没成功，点这里重试", recordBackupStatusText(summary, "record"))
    }

    @Test fun wifiRestrictionExplainsAutomaticResume() {
        assertEquals("连上 Wi‑Fi 后会自动备份", backupStatusText(
            BackupSummary(paused = false, blockReason = BackupBlockReason.Metered)))
    }

    @Test fun datesStayChineseAndUseTwentyFourHourTimeOnEnglishDevices() {
        val previous = Locale.getDefault()
        try {
            Locale.setDefault(Locale.US)
            assertEquals("10月16日 14:30", momentDateTimeLabel(
                Instant.parse("2026-10-16T06:30:00Z").toEpochMilli(), ZoneId.of("Asia/Shanghai")))
            assertEquals("暂无", displayBackupTime(null))
            assertEquals("1.5兆字节", localMediaSizeText(1_500_000))
        } finally { Locale.setDefault(previous) }
    }
}
