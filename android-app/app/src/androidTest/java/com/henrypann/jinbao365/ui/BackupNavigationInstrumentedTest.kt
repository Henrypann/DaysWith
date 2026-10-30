package com.henrypann.jinbao365.ui

import android.util.AtomicFile
import androidx.activity.ComponentActivity
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.backup.BackupSummary
import com.henrypann.jinbao365.storage.*
import com.henrypann.jinbao365.ui.theme.JinbaoTheme
import java.io.File
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Uses an isolated encrypted connection store and synthetic values. Never contacts COS. */
@RunWith(AndroidJUnit4::class)
class BackupNavigationInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private var controller: StorageConnectionController? = null
    private var storeFile: File? = null
    @After fun close() {
        compose.runOnUiThread { controller?.close() }
        storeFile?.delete()
    }

    @Test fun settingsCloudNavigationActionsAndCredentialDialogKeepSharedSummary() {
        val file = File(compose.activity.noBackupFilesDir, "backup-navigation-${UUID.randomUUID()}.enc")
        storeFile = file
        val store = StorageConnectionStore(AtomicFile(file), AndroidCredentialCipher())
        val configuration = StorageConfiguration(bucket = "example-1234567890", prefix = "life/v1/android/")
        store.saveVerified(configuration, StorageCredentials("SyntheticID", "SyntheticKey"))
        lateinit var connection: StorageConnectionController
        compose.runOnUiThread {
            connection = StorageConnectionController(store, StorageVerifier { _, _, cancellation -> cancellation.check() })
            controller = connection
        }
        compose.waitUntil(5_000) { connection.connection != null }
        var starts = 0
        var pauses = 0
        var retries = 0
        val summary = mutableStateOf(BackupSummary(paused = true, canBackUpNow = true))
        compose.setContent {
            JinbaoTheme {
                SettingsScreen(connection, "test-phone", compose.activity.filesDir, ArchiveSnapshot.empty(), null,
                    onOpenTrash = {}, backupSummary = summary.value, backupConfiguration = configuration,
                    onBackUpNow = { starts++ }, onPauseBackup = { pauses++ }, onRetryFailed = { retries++ })
            }
        }
        compose.onNodeWithTag("openCloudStorage").performScrollTo().performClick()
        compose.onNodeWithTag("cloudStorage").assertIsDisplayed()
        compose.onNodeWithTag("backUpNow").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(1, starts) }
        compose.runOnIdle {
            summary.value = BackupSummary(paused = false, blockReason = null, failedCount = 1,
                canPause = true, canRetryFailed = true)
        }
        compose.onNodeWithTag("backupStatusLine").performScrollTo().assertTextEquals("有一项备份没成功，点这里重试")
        compose.onNodeWithTag("pauseBackup").performScrollTo().performClick()
        compose.onNodeWithTag("retryFailedBackups").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(1, pauses); assertEquals(1, retries) }
        compose.onNodeWithText("修改连接信息").performScrollTo().performClick()
        compose.onNodeWithTag("credentialDialog").assertIsDisplayed()
        compose.onNodeWithTag("cancelCredentials").performClick()
        compose.onNodeWithTag("cloudStorage").assertIsDisplayed()
        compose.onNodeWithContentDescription("返回").performScrollTo().performClick()
        compose.onNodeWithTag("settingsBackupStatus").performScrollTo().assertExists()
    }

}
