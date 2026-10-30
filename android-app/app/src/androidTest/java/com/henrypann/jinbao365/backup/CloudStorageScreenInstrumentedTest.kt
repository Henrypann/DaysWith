package com.henrypann.jinbao365.backup

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.henrypann.jinbao365.ui.CloudStorageScreen
import com.henrypann.jinbao365.ui.theme.JinbaoTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.text.DateFormat
import java.util.Date

/** UI contract only: the backup query owns coverage and status decisions. No network calls. */
@RunWith(AndroidJUnit4::class)
class CloudStorageScreenInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private fun show(summary: BackupSummary, onAction: (String) -> Unit = {}, backupError: String? = null) {
        compose.setContent {
            JinbaoTheme {
                CloudStorageScreen(
                    summary = summary,
                    backupError = backupError,
                    bucket = "synthetic-bucket-123",
                    region = "ap-shanghai",
                    prefix = "life/v1/android/",
                    onBackUpNow = { onAction("backUpNow") },
                    onPause = { onAction("pause") },
                    onRetryFailed = { onAction("retry") },
                    onChangeCredentials = { onAction("credentials") },
                    onBack = { onAction("back") },
                )
            }
        }
    }

    @Test fun pausedSummaryStaysPausedUntilHostHandlesBackUpNow() {
        val calls = mutableListOf<String>()
        show(
            BackupSummary(
                blockReason = BackupBlockReason.Paused,
                unbackedOriginalCount = 2,
                unbackedRecordCount = 1,
                paused = true,
                canBackUpNow = true,
            ),
            calls::add,
        )
        compose.onNodeWithTag("cloudStorage").assertExists()
        compose.onNodeWithTag("backupStatusLine").assertTextEquals("备份已暂停，轻点立即备份")
        compose.onNodeWithTag("unbackedOriginals").assertTextEquals("2个原文件尚未备份")
        compose.onNodeWithTag("lastUpload").assertTextEquals("暂无")
        compose.onNodeWithTag("backUpNow").performScrollTo().assertIsEnabled().performClick()
        compose.onNodeWithTag("pauseBackup").assertIsNotEnabled()
        compose.onNodeWithTag("retryFailedBackups").assertIsNotEnabled()
        compose.onNodeWithTag("backupStatusLine").assertTextEquals("备份已暂停，轻点立即备份")
        assertEquals(listOf("backUpNow"), calls)
    }

    @Test fun waitingForWifiUsesQueryStatusAndActionAvailability() {
        show(
            BackupSummary(
                paused = false,
                blockReason = BackupBlockReason.Metered,
                canBackUpNow = false,
                canPause = true,
            ),
        )
        compose.onNodeWithTag("backupStatusLine").assertTextEquals("连上 Wi‑Fi 后会自动备份")
        compose.onNodeWithTag("backUpNow").assertIsNotEnabled()
        compose.onNodeWithTag("pauseBackup").assertIsEnabled()
        compose.onNodeWithText("已完成备份").assertDoesNotExist()
    }

    @Test fun zeroMediaNoteDoesNotAppearBackedUpFromOriginalCountAlone() {
        show(
            BackupSummary(
                blockReason = null,
                unbackedOriginalCount = 0,
                unbackedRecordCount = 1,
                paused = false,
            ),
        )
        compose.onNodeWithTag("unbackedOriginals").assertTextEquals("0个原文件尚未备份")
        compose.onNodeWithText("1条记录尚未备份").assertExists()
        compose.onNodeWithTag("backupStatusLine").assertTextEquals("等待备份")
        compose.onNodeWithText("已完成备份").assertDoesNotExist()
    }

    @Test fun verifiedSummaryDisplaysBackedUpAndLastVerifiedUploadTime() {
        val uploadedAt = 1_792_080_000_000L
        show(
            BackupSummary(
                blockReason = null,
                allCovered = true,
                lastUploadAtMillis = uploadedAt,
                lastCommitAtMillis = uploadedAt + 1_000,
                paused = false,
            ),
        )
        compose.onNodeWithTag("backupStatusLine").assertTextEquals("已完成备份")
        compose.onNodeWithTag("lastUpload").assertTextEquals(
            com.henrypann.jinbao365.ui.momentDateTimeLabel(uploadedAt),
        )
    }

    @Test fun callbacksAreForwardedWithoutChangingTheSummary() {
        val calls = mutableListOf<String>()
        show(
            BackupSummary(
                blockReason = BackupBlockReason.Failed,
                failedCount = 1,
                paused = false,
                canPause = true,
                canRetryFailed = true,
            ),
            calls::add,
        )
        compose.onNodeWithTag("pauseBackup").performScrollTo().performClick()
        compose.onNodeWithTag("retryFailedBackups").performScrollTo().performClick()
        compose.onNodeWithText("修改连接信息").performScrollTo().performClick()
        compose.onNodeWithContentDescription("返回").performScrollTo().performClick()
        compose.onNodeWithTag("backupStatusLine").assertTextEquals("有一项备份没成功，点这里重试")
        assertEquals(listOf("pause", "retry", "credentials", "back"), calls)
    }

    @Test fun rawValidatorErrorsNeverAppearAndTappingTheNoticeRetries() {
        val calls = mutableListOf<String>()
        val raw = "moments[record].title is too long."
        show(BackupSummary(paused = false, failedCount = 1, canRetryFailed = true), calls::add, raw)
        compose.onNodeWithText(raw).assertDoesNotExist()
        compose.onNodeWithTag("backupError").performScrollTo().performClick()
        compose.onNodeWithTag("backupStatusLine").performScrollTo()
            .assertTextEquals("有一项备份没成功，点这里重试").performClick()
        assertEquals(listOf("backUpNow", "backUpNow"), calls)
    }

    @Test fun progressAndOverdueCountsComeFromSummary() {
        show(
            BackupSummary(
                blockReason = null,
                unbackedOriginalCount = 3,
                overdueOriginalCount = 2,
                hasOverdue = true,
                inProgress = true,
                paused = false,
                progress = BackupProgress("uploading", null, completed = 1, total = 4),
            ),
        )
        compose.onNodeWithTag("backupStatusLine").assertTextEquals("正在备份")
        compose.onNodeWithText("已备份 1/4 个文件").assertExists()
        compose.onNodeWithText("2个原文件已等待超过24小时").assertExists()
    }

    @Test fun overdueTextOnlyNoteDoesNotDescribeZeroOverdueOriginals() {
        show(
            BackupSummary(
                blockReason = null,
                unbackedOriginalCount = 0,
                unbackedRecordCount = 1,
                overdueOriginalCount = 0,
                hasOverdue = true,
                paused = false,
            ),
        )
        compose.onNodeWithText("有记录超过24小时未备份").assertExists()
        compose.onNodeWithText("0个原文件已等待超过24小时").assertDoesNotExist()
        compose.onNodeWithText("已完成备份").assertDoesNotExist()
    }
}
