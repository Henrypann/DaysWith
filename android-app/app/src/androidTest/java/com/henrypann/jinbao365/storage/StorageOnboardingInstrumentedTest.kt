package com.henrypann.jinbao365.storage

import android.os.SystemClock
import android.content.ClipData
import android.content.ClipboardManager
import android.os.ParcelFileDescriptor
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.util.AtomicFile
import android.view.WindowManager
import android.view.inspector.WindowInspector
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.activity.ComponentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.autofill.ContentDataType
import androidx.compose.ui.test.*
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.henrypann.jinbao365.ui.StorageConnectionScreen
import com.henrypann.jinbao365.ui.theme.JinbaoTheme
import org.junit.Assert.*
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Exercises only the cloud step with synthetic inputs and an injected verifier; no network calls.
 * This isolated host deliberately avoids invoking the app-wide permission and identity gates. */
@RunWith(AndroidJUnit4::class)
class StorageOnboardingInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val calls = AtomicInteger()
    private val controllers = mutableListOf<StorageConnectionController>()
    private val lifecycleObservers = mutableListOf<LifecycleEventObserver>()
    private val password = SemanticsMatcher.keyIsDefined(SemanticsProperties.Password)
    private val emptyInput = SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString(""))
    private val notAutofillable = SemanticsMatcher.expectValue(SemanticsProperties.ContentDataType, ContentDataType.None)
    private fun store() = StorageConnectionStore(AtomicFile(File(compose.activity.noBackupFilesDir, "test-${UUID.randomUUID()}.enc")), AndroidCredentialCipher())
    private fun controller(store: StorageConnectionStore, verifier: StorageVerifier): StorageConnectionController {
        lateinit var controller: StorageConnectionController
        compose.runOnUiThread { controller = StorageConnectionController(store, verifier) }
        controllers += controller
        return controller
    }
    private fun show(store: StorageConnectionStore = store(), verifier: StorageVerifier = StorageVerifier { _, _, cancellation -> cancellation.check(); calls.incrementAndGet() }): StorageConnectionController {
        val controller = controller(store, verifier)
        compose.setContent { JinbaoTheme { StorageConnectionScreen(controller, mandatory = controller.connection !is SavedConnection.Verified) } }
        compose.waitUntil(5000) { controller.connection != null }
        if (controller.connection !is SavedConnection.Verified) waitForDialogFocus()
        return controller
    }
    private fun waitForDialogFocus() {
        compose.waitUntil(5000) {
            var focused = false
            compose.runOnUiThread {
                focused = WindowInspector.getGlobalWindowViews().any {
                    val params = it.layoutParams as? WindowManager.LayoutParams
                    // OEMs may host dialogs in application subwindows rather than type 2.
                    // Wait for the focused, protected credential window itself.
                    it.hasWindowFocus() && params != null &&
                        params.flags and WindowManager.LayoutParams.FLAG_SECURE != 0
                }
            }
            focused
        }
    }
    private fun enterID(value: String = "SyntheticID") {
        waitForDialogFocus()
        if (editableValue("storageBucket").isBlank()) compose.onNodeWithTag("storageBucket").performScrollTo().performTextInput(StorageConfiguration(bucket = "example-1234567890").bucket)
        if (editableValue("storageRegion").isBlank()) compose.onNodeWithTag("storageRegion").performScrollTo().performTextInput("ap-shanghai")
        compose.onNodeWithTag("secretID").performScrollTo().performTextInput(value)
        compose.onNodeWithTag("secretKey").assertExists().assert(password)
    }
    private fun assertIDRendering(visible: Boolean, value: String = "SyntheticID") {
        val layouts = mutableListOf<TextLayoutResult>()
        compose.onNodeWithTag("secretID").performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        assertEquals(if (visible) value else "\u2022".repeat(value.length), layouts.single().layoutInput.text.text)
    }
    private fun systemBack() {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        ParcelFileDescriptor.AutoCloseInputStream(automation.executeShellCommand("input keyevent KEYCODE_BACK")).use { it.readBytes() }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        compose.waitForIdle()
    }
    private fun shell(command: String) {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        ParcelFileDescriptor.AutoCloseInputStream(automation.executeShellCommand(command)).use { it.readBytes() }
    }
    private fun backgroundApp() {
        val stopped = CountDownLatch(1)
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) stopped.countDown() }
        compose.runOnUiThread { compose.activity.lifecycle.addObserver(observer) }
        try {
            shell("input keyevent KEYCODE_HOME")
            assertTrue("Home must stop the activity", stopped.await(5, TimeUnit.SECONDS))
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            assertEquals(Lifecycle.State.CREATED, compose.activityRule.scenario.state)
        } finally {
            compose.runOnUiThread { compose.activity.lifecycle.removeObserver(observer) }
        }
    }
    private fun returnToApp() {
        val resumed = CountDownLatch(1)
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) resumed.countDown() }
        compose.runOnUiThread { compose.activity.lifecycle.addObserver(observer) }
        try {
            val component = "${compose.activity.packageName}/${compose.activity.javaClass.name}"
            // REORDER_TO_FRONT resumes this same test activity without recreating its in-memory draft.
            shell("am start -n $component -f 0x00020000")
            assertTrue("Returning to the app must resume the activity", resumed.await(5, TimeUnit.SECONDS))
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        } finally {
            compose.runOnUiThread { compose.activity.lifecycle.removeObserver(observer) }
        }
        waitForDialogFocus()
        compose.waitForIdle()
    }
    private fun keyboardVisible(): Boolean {
        var visible = false
        compose.runOnUiThread {
            visible = WindowInspector.getGlobalWindowViews().any {
                ViewCompat.getRootWindowInsets(it)?.isVisible(WindowInsetsCompat.Type.ime()) == true
            }
        }
        return visible
    }
    private fun lifecycleTrace(): List<String> {
        val events = java.util.Collections.synchronizedList(mutableListOf<String>())
        val observer = LifecycleEventObserver { _, event -> events += "${event.name}@${SystemClock.uptimeMillis()}" }
        compose.runOnUiThread { compose.activity.lifecycle.addObserver(observer) }
        lifecycleObservers += observer
        return events
    }
    private fun editableValue(tag: String): String =
        compose.onNodeWithTag(tag).fetchSemanticsNode().config.let {
            // EditableText can contain password bullets; InputText is the untransformed value.
            it.getOrNull(SemanticsProperties.InputText)?.text ?: it.getOrNull(SemanticsProperties.EditableText)?.text.orEmpty()
        }
    private fun enterKeyAndVerify(pasteFromClipboard: Boolean = false, onInputFailure: (() -> String)? = null) {
        compose.onNodeWithTag("secretKey").performScrollTo()
        if (pasteFromClipboard) {
            val clipboard = compose.activity.getSystemService(ClipboardManager::class.java)
            compose.runOnUiThread { clipboard.setPrimaryClip(ClipData.newPlainText("Synthetic fixture", "SyntheticKey")) }
            try {
                compose.onNodeWithTag("secretKey").performTouchInput { longClick() }
                val menuVisible = try {
                    compose.waitUntil(3000) {
                        compose.onAllNodesWithText("Paste", ignoreCase = true, useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()
                    }
                    true
                } catch (_: ComposeTimeoutException) { false }
                val pastePath = if (menuVisible) {
                    compose.onNodeWithText("Paste", ignoreCase = true, useUnmergedTree = true).performClick()
                    "visible-menu"
                } else {
                    shell("input keyevent KEYCODE_PASTE")
                    "system-paste-key"
                }
                InstrumentationRegistry.getInstrumentation().addResults(android.os.Bundle().apply { putString("syntheticPastePath", pastePath) })
                compose.waitUntil(5000) { editableValue("secretKey") == "SyntheticKey" }
            } finally { compose.runOnUiThread { clipboard.clearPrimaryClip() } }
        } else compose.onNodeWithTag("secretKey").performScrollTo().performClick().performTextInput("SyntheticKey")
        val key = editableValue("secretKey")
        val keyFocused = compose.onNodeWithTag("secretKey").fetchSemanticsNode().config.getOrNull(SemanticsProperties.Focused)
        val inputCompletedAt = SystemClock.uptimeMillis()
        try {
            assertTrue("Key input must have the expected synthetic value; length=${key.length}", key == "SyntheticKey")
            compose.onNodeWithTag("verifyContinue").assertIsDisplayed().assertIsEnabled().performClick()
        } catch (error: AssertionError) {
            if (onInputFailure == null) throw error
            // Only lengths and comparison results from synthetic inputs are included in failure evidence.
            throw AssertionError("Key input failed at $inputCompletedAt; keyLength=${key.length}; keyMatchesExpected=${key == "SyntheticKey"}; keyFocused=$keyFocused; ${onInputFailure()}", error)
        }
    }
    @After fun closeControllers() { compose.runOnUiThread {
        lifecycleObservers.forEach { compose.activity.lifecycle.removeObserver(it) }
        controllers.forEach { it.close() }
    } }

    @Test fun credentialDialogExcludesAutofillThroughVerificationWithoutChangingTheSummaryView() {
        val store = store()
        store.saveVerified(StorageConfiguration(bucket = "example-1234567890"), StorageCredentials("SyntheticID", "SyntheticKey"))
        val controller = controller(store, StorageVerifier { _, _, cancellation -> cancellation.check() })
        lateinit var summaryView: View
        compose.setContent {
            val view = LocalView.current
            SideEffect { summaryView = view }
            JinbaoTheme { StorageConnectionScreen(controller, mandatory = false) }
        }
        compose.waitUntil(5000) { controller.connection is SavedConnection.Verified }
        var summaryAutofill = View.IMPORTANT_FOR_AUTOFILL_AUTO
        compose.runOnUiThread { summaryAutofill = summaryView.importantForAutofill }
        assertNotEquals(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS, summaryAutofill)

        fun descendants(view: View): List<View> = listOf(view) +
            if (view is ViewGroup) (0 until view.childCount).flatMap { descendants(view.getChildAt(it)) }
            else emptyList()
        fun protectedAutofillContainers(): List<View> {
            val views = WindowInspector.getGlobalWindowViews().filter {
                ((it.layoutParams as? WindowManager.LayoutParams)?.flags ?: 0) and WindowManager.LayoutParams.FLAG_SECURE != 0
            }.flatMap(::descendants)
            val excluded = views.filter {
                it.importantForAutofill == View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
            }
            assertTrue("The protected credential window must exclude its input subtree", excluded.isNotEmpty())
            val composeViews = views.filter { it.javaClass.simpleName == "AndroidComposeView" }
            assertTrue("The protected credential dialog must own a Compose view", composeViews.isNotEmpty())
            composeViews.forEach { view ->
                assertNotSame(summaryView, view)
                // LocalView can be the DialogLayout container. Its exclusion covers the child
                // AndroidComposeView even when that child initializes its own raw flag to YES.
                assertTrue("Each credential Compose subtree must have an excluded ancestor",
                    generateSequence(view) { it.parent as? View }.any { it in excluded })
                assertFalse("Credential descendants must be effectively excluded from autofill", view.isImportantForAutofill)
            }
            return excluded
        }

        compose.onNodeWithTag("changeCredentials").performClick()
        waitForDialogFocus()
        for (tag in listOf("storageBucket", "storageRegion", "secretID", "secretKey")) {
            compose.onNodeWithTag(tag).assert(notAutofillable)
        }
        compose.onNodeWithTag("secretID").assert(password)
        compose.onNodeWithTag("secretKey").assert(password)
        enterID()
        compose.onNodeWithTag("toggleSecretIDVisibility").performClick()
        assertIDRendering(visible = true)
        compose.onNodeWithTag("secretID").assert(notAutofillable)
        var dialogViews = emptyList<View>()
        compose.runOnUiThread {
            dialogViews = protectedAutofillContainers()
            dialogViews.forEach {
                assertNotSame(summaryView, it)
                assertEquals(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS, it.importantForAutofill)
            }
            assertEquals(summaryAutofill, summaryView.importantForAutofill)
        }
        enterKeyAndVerify()
        compose.waitUntil(5000) { !controller.busy && controller.connection is SavedConnection.Verified }
        compose.onNodeWithTag("storageVerified").assertExists()
        compose.onNodeWithTag("credentialDialog").assertDoesNotExist()
        compose.runOnUiThread {
            // The detached view must stay excluded while its final frame leaves the screen.
            dialogViews.forEach { assertEquals(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS, it.importantForAutofill) }
            assertEquals(summaryAutofill, summaryView.importantForAutofill)
        }
        compose.onNodeWithTag("changeCredentials").performClick()
        waitForDialogFocus()
        compose.onNodeWithTag("secretID").assert(password).assert(emptyInput).assert(notAutofillable)
        compose.onNodeWithTag("secretKey").assert(password).assert(emptyInput).assert(notAutofillable)
        compose.runOnUiThread {
            val reopened = protectedAutofillContainers()
            reopened.forEach { assertEquals(View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS, it.importantForAutofill) }
            assertEquals(summaryAutofill, summaryView.importantForAutofill)
        }
    }

    @Test fun mandatorySingleFormVerifyOfflineRelaunchAndDisconnect() {
        val store = store()
        val controller = show(store)
        compose.onNode(isDialog()).assertExists()
        compose.onNodeWithTag("timeline").assertDoesNotExist()
        compose.onNodeWithTag("secretID").assert(password).assert(emptyInput)
        compose.onNodeWithTag("secretKey").assert(password).assert(emptyInput)
        compose.onNodeWithTag("storageBucket").assertTextContains("example-1234567890")
        compose.onNodeWithTag("storageRegion").assertTextContains("ap-shanghai")
        compose.onNodeWithTag("verifyContinue").assertIsNotEnabled()
        compose.onNodeWithTag("pasteCredentials").assertDoesNotExist()
        systemBack()
        compose.onNodeWithTag("credentialDialog").assertExists()
        compose.onNodeWithTag("timeline").assertDoesNotExist()
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val now = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(now, SystemClock.uptimeMillis(), action, 1f, 320f, 0)
            try { automation.injectInputEvent(event, true) } finally { event.recycle() }
        }
        compose.waitForIdle()
        compose.onNodeWithTag("credentialDialog").assertExists()
        compose.onNodeWithTag("timeline").assertDoesNotExist()
        var secureDialog = false
        compose.runOnUiThread {
            secureDialog = WindowInspector.getGlobalWindowViews().any {
                ((it.layoutParams as? WindowManager.LayoutParams)?.flags ?: 0) and WindowManager.LayoutParams.FLAG_SECURE != 0
            }
        }
        assertTrue(secureDialog)
        enterID(); enterKeyAndVerify()
        compose.waitUntil(5000) { controller.connection is SavedConnection.Verified }
        compose.onNodeWithTag("storageVerified").assertExists()
        compose.onNodeWithTag("credentialDialog").assertDoesNotExist()
        assertEquals(1, calls.get())
        assertEquals(SavedConnection.Verified(StorageConfiguration(bucket = "example-1234567890")), store.load())
        compose.runOnUiThread { controller.retryLoad() }
        compose.waitUntil(5000) { !controller.busy }
        assertEquals(1, calls.get())
        compose.onNodeWithTag("disconnectStorage").performClick()
        compose.onNodeWithText("连接云存储").assertExists()
        compose.onNodeWithTag("timeline").assertDoesNotExist()
        assertEquals(SavedConnection.Configured(StorageConfiguration(bucket = "example-1234567890")), store.load())
    }

    @Test fun verifyRequiresLocallyValidLocationAndBothCredentialValues() {
        show()
        compose.onNodeWithTag("secretID").performScrollTo().performTextInput("ID with spaces")
        compose.onNodeWithTag("verifyContinue").assertIsNotEnabled()
        compose.onNodeWithTag("secretID").performTextReplacement("x".repeat(257))
        compose.onNodeWithTag("verifyContinue").assertIsNotEnabled()
        compose.onNodeWithTag("secretID").performTextReplacement("SyntheticID")
        compose.onNodeWithTag("storageBucket").performScrollTo().performTextReplacement("invalid.example")
        compose.onNodeWithTag("verifyContinue").assertIsNotEnabled()
        compose.onNodeWithTag("storageBucket").performTextReplacement(StorageConfiguration(bucket = "example-1234567890").bucket)
        compose.onNodeWithTag("storageRegion").performScrollTo().performTextReplacement("invalid.example")
        compose.onNodeWithTag("verifyContinue").assertIsNotEnabled()
        compose.onNodeWithTag("storageRegion").performTextReplacement("ap-beijing")
        compose.onNodeWithTag("verifyContinue").assertIsNotEnabled()
        compose.onNodeWithTag("secretKey").performScrollTo().performTextInput("Key with spaces")
        compose.onNodeWithTag("verifyContinue").assertIsNotEnabled()
        compose.onNodeWithTag("secretKey").performTextReplacement("k".repeat(257))
        compose.onNodeWithTag("verifyContinue").assertIsNotEnabled()
        compose.onNodeWithTag("secretKey").performTextReplacement("SyntheticKey")
        compose.onNodeWithTag("verifyContinue").assertIsEnabled()
        assertEquals(0, calls.get())
    }

    @Test fun idToggleAndMandatoryBackPreserveSingleFormAndCannotExposeHome() {
        show()
        compose.onNodeWithTag("storageRegion").performScrollTo().performTextReplacement("ap-beijing")
        compose.onNodeWithTag("secretID").performScrollTo().performTextInput("SyntheticID")
        compose.onNodeWithTag("secretID").assert(password)
        compose.onNodeWithContentDescription("显示密钥编号").performClick()
        assertIDRendering(visible = true)
        compose.onNodeWithContentDescription("隐藏密钥编号").performClick()
        assertIDRendering(visible = false)
        compose.onNodeWithTag("secretID").assert(password)
        compose.onNodeWithTag("secretKey").performScrollTo().performTextInput("SyntheticKey")
        compose.waitUntil(5000) { keyboardVisible() }
        systemBack()
        compose.waitUntil(5000) { !keyboardVisible() }
        systemBack()
        compose.onNodeWithTag("credentialDialog").assertExists()
        compose.onNodeWithTag("storageRegion").assertTextContains("ap-beijing")
        compose.onNodeWithTag("secretKey").assert(password)
        compose.onNodeWithTag("verifyContinue").assertIsEnabled()
        compose.onNodeWithTag("timeline").assertDoesNotExist()
    }

    @Test fun actualBackgroundRetainsMaskedIDButClearsKeyInSingleForm() {
        val store = store()
        val seen = mutableListOf<StorageCredentials>()
        val controller = show(store, StorageVerifier { _, credentials, _ -> seen += credentials })
        val events = lifecycleTrace()
        compose.onNodeWithTag("storageRegion").performScrollTo().performTextReplacement("ap-beijing")
        compose.onNodeWithTag("storageBucket").performScrollTo().performTextReplacement(StorageConfiguration(bucket = "example-1234567890").bucket)
        compose.onNodeWithTag("secretID").performScrollTo().performTextInput("SyntheticID")
        compose.onNodeWithTag("toggleSecretIDVisibility").performClick()
        assertIDRendering(visible = true)
        backgroundApp()
        returnToApp()
        compose.onNodeWithTag("secretID").assert(password)
        assertIDRendering(visible = false)
        compose.onNodeWithTag("storageRegion").assertTextContains("ap-beijing")
        compose.onNodeWithTag("secretKey").performScrollTo().performTextInput("SyntheticKey")
        backgroundApp()
        returnToApp()
        compose.onNodeWithTag("secretID").assert(password)
        assertIDRendering(visible = false)
        compose.onNodeWithTag("secretKey").assert(emptyInput)
        compose.onNodeWithTag("verifyContinue").assertIsNotEnabled()
        assertEquals(SavedConnection.Missing, store.load())
        enterKeyAndVerify(pasteFromClipboard = true, onInputFailure = {
            val busy = controller.busy
            val trace = synchronized(events) { events.toList() }
            val id = editableValue("secretID")
            val region = editableValue("storageRegion")
            val bucket = editableValue("storageBucket")
            "busy=$busy; idLength=${id.length}; idMatchesExpected=${id == "SyntheticID"}; " +
                "regionMatchesExpected=${region == "ap-beijing"}; bucketMatchesExpected=${bucket == StorageConfiguration(bucket = "example-1234567890").bucket}; lifecycle=$trace"
        })
        compose.waitUntil(5000) { controller.connection is SavedConnection.Verified }
        assertEquals("SyntheticID", seen.single().secretID)
        assertEquals("SyntheticKey", seen.single().secretKey)
        assertEquals(SavedConnection.Verified(StorageConfiguration(bucket = "example-1234567890", region = "ap-beijing")), store.load())
    }

    @Test fun actualBackgroundClearsVerificationErrorAndAllowsKeyRetry() {
        val attempts = AtomicInteger()
        val controller = show(verifier = StorageVerifier { _, credentials, _ ->
            assertEquals("SyntheticID", credentials.secretID)
            if (attempts.incrementAndGet() == 1) throw VerificationException(ConnectionFailure.Signature)
        })
        enterID(); enterKeyAndVerify()
        compose.waitUntil(5000) { !controller.busy }
        compose.onNodeWithTag("connectionMessage").assertExists()
        backgroundApp()
        returnToApp()
        assertNull(controller.message)
        compose.onNodeWithTag("connectionMessage").assertDoesNotExist()
        compose.onNodeWithTag("secretID").assert(password)
        compose.onNodeWithTag("secretKey").assert(emptyInput)
        enterKeyAndVerify()
        compose.waitUntil(5000) { controller.connection is SavedConnection.Verified }
        assertEquals(2, attempts.get())
    }

    @Test fun stateRestorationCannotRestoreEitherCredential() {
        val controller = controller(store(), StorageVerifier { _, _, _ -> calls.incrementAndGet() })
        val restoration = StateRestorationTester(compose)
        restoration.setContent { JinbaoTheme { StorageConnectionScreen(controller, mandatory = controller.connection !is SavedConnection.Verified) } }
        compose.waitUntil(5000) { controller.connection != null }
        enterID()
        compose.onNodeWithTag("secretKey").performScrollTo().performTextInput("SyntheticKey")
        restoration.emulateSavedInstanceStateRestore()
        compose.onNodeWithTag("secretID").assert(password).assert(emptyInput)
        compose.onNodeWithTag("secretKey").assert(password).assert(emptyInput)
        compose.onNodeWithTag("storageBucket").assertTextContains("example-1234567890")
        compose.onNodeWithTag("storageRegion").assertTextContains("ap-shanghai")
        compose.onNodeWithTag("verifyContinue").assertIsNotEnabled()
        assertEquals(0, calls.get())
    }

    @Test fun settingsFailureKeepsOldBindingAndDismissalClearsInputs() {
        val store = store()
        val original = StorageConfiguration(bucket = "example-1234567890", region = "ap-shanghai")
        store.saveVerified(original, StorageCredentials("PreviousID", "PreviousKey"))
        val controller = show(store, StorageVerifier { _, _, _ -> throw VerificationException(ConnectionFailure.InvalidSecretID) })
        compose.onNodeWithTag("changeCredentials").performClick()
        compose.onNodeWithTag("storageRegion").assertTextContains(original.region)
        compose.onNodeWithTag("storageRegion").performTextReplacement("ap-guangzhou")
        enterID(); enterKeyAndVerify()
        compose.waitUntil(5000) { !controller.busy }
        compose.onNodeWithTag("connectionMessage").assertTextContains(ConnectionFailure.InvalidSecretID.message)
        compose.onNodeWithTag("secretKey").assert(emptyInput)
        assertEquals(SavedConnection.Verified(original), store.load())
        compose.onNodeWithTag("cancelCredentials").performClick()
        compose.onNodeWithTag("credentialDialog").assertDoesNotExist()
        compose.onNodeWithTag("changeCredentials").performClick()
        compose.onNodeWithTag("storageRegion").assertTextContains(original.region)
        compose.onNodeWithTag("secretID").assert(emptyInput).assert(password)
        compose.onNodeWithTag("cancelCredentials").performClick()
        compose.onNodeWithTag("changeCredentials").performClick()
        compose.onNodeWithTag("secretID").assert(emptyInput).assert(password)
    }

    @Test fun backgroundDuringVerificationCannotSaveLateSuccessOrOpenGate() {
        val store = store()
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val returned = CountDownLatch(1)
        val controller = show(store, StorageVerifier { _, _, _ ->
            started.countDown()
            try { release.await(5, TimeUnit.SECONDS) } catch (_: InterruptedException) { }
            returned.countDown()
        })
        enterID(); enterKeyAndVerify()
        assertTrue(started.await(5, TimeUnit.SECONDS))
        backgroundApp()
        release.countDown()
        assertTrue(returned.await(5, TimeUnit.SECONDS))
        returnToApp()
        assertEquals(SavedConnection.Missing, store.load())
        assertEquals(SavedConnection.Missing, controller.connection)
        compose.onNodeWithTag("secretID").assert(password)
        compose.onNodeWithTag("secretKey").assert(emptyInput)
        compose.onNodeWithTag("verifyContinue").assertIsNotEnabled()
        assertIDRendering(visible = false)
        compose.onNodeWithTag("timeline").assertDoesNotExist()
    }

    @Test fun settingsSuccessTrimsBoundaryWhitespaceAndKeepsFooterVisibleWithKeyboard() {
        val file = File(compose.activity.noBackupFilesDir, "test-${UUID.randomUUID()}.enc")
        val cipher = AndroidCredentialCipher()
        val store = StorageConnectionStore(AtomicFile(file), cipher)
        store.saveVerified(StorageConfiguration(bucket = "example-1234567890", region = "ap-shanghai"), StorageCredentials("PreviousID", "PreviousKey"))
        val seen = mutableListOf<StorageCredentials>()
        val controller = show(store, StorageVerifier { _, credentials, _ -> seen += credentials })
        compose.onNodeWithTag("changeCredentials").performClick()
        compose.onNodeWithTag("storageRegion").performTextReplacement("ap-beijing")
        enterID("  SyntheticID  ")
        compose.onNodeWithText("验证并保存").assertIsDisplayed()
        compose.onNodeWithTag("secretKey").performScrollTo().performClick().performTextInput("  SyntheticKey  ")
        compose.onNodeWithTag("verifyContinue").assertIsDisplayed()
        compose.onNodeWithTag("connectionFields").performTouchInput { swipeUp() }
        compose.onNodeWithTag("verifyContinue").assertIsDisplayed().performClick()
        compose.waitUntil(5000) { !controller.busy }
        compose.onNodeWithTag("credentialDialog").assertDoesNotExist()
        assertEquals("SyntheticID", seen.single().secretID)
        assertEquals("SyntheticKey", seen.single().secretKey)
        val plaintext = cipher.decrypt(file.readBytes())
        try {
            val record = JSONObject(plaintext.toString(Charsets.UTF_8))
            assertEquals("SyntheticID", record.getString("secretID"))
            assertEquals("SyntheticKey", record.getString("secretKey"))
        } finally { plaintext.fill(0) }
        assertEquals(SavedConnection.Verified(StorageConfiguration(bucket = "example-1234567890", region = "ap-beijing")), store.load())
        compose.onNodeWithTag("changeCredentials").performClick()
        compose.onNodeWithTag("storageRegion").assertTextContains("ap-beijing")
        compose.onNodeWithTag("secretID").assert(emptyInput).assert(password)
    }

    @Test fun secureSaveFailureCannotOpenMandatoryGate() {
        val realCipher = AndroidCredentialCipher()
        val failingCipher = object : CredentialCipher {
            override fun encrypt(plaintext: ByteArray): ByteArray = throw IllegalStateException("synthetic storage failure")
            override fun decrypt(ciphertext: ByteArray): ByteArray = realCipher.decrypt(ciphertext)
        }
        val file = File(compose.activity.noBackupFilesDir, "test-${UUID.randomUUID()}.enc")
        val store = StorageConnectionStore(AtomicFile(file), failingCipher)
        val controller = show(store)
        enterID(); enterKeyAndVerify()
        compose.waitUntil(5000) { !controller.busy }
        compose.onNodeWithTag("connectionMessage").assertTextContains(ConnectionFailure.SecureStorage.message)
        compose.onNodeWithTag("timeline").assertDoesNotExist()
        compose.onNodeWithTag("credentialDialog").assertExists()
        assertEquals(SavedConnection.Missing, controller.connection)
        assertEquals(SavedConnection.Missing, store.load())
        assertFalse(file.exists())
    }

    @Test fun realKeystoreUsesRandomIvAndRejectsCorruptionWithoutErasure() {
        val cipher = AndroidCredentialCipher()
        val plaintext = "synthetic-secret-only".toByteArray()
        val first = cipher.encrypt(plaintext)
        val second = cipher.encrypt(plaintext)
        assertFalse(first.contentEquals(second))
        assertArrayEquals(plaintext, cipher.decrypt(first))
        assertThrows(Exception::class.java) { cipher.decrypt(first.also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() }) }
        val store = store()
        store.saveVerified(StorageConfiguration(bucket = "example-1234567890"), StorageCredentials("SyntheticID", "SyntheticKey"))
        assertEquals(SavedConnection.Verified(StorageConfiguration(bucket = "example-1234567890")), store.load())
    }
}
