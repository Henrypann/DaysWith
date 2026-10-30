package com.henrypann.jinbao365.storage

import android.util.AtomicFile
import androidx.test.core.app.ApplicationProvider
import android.content.Context
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.util.concurrent.AbstractExecutorService
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31])
class StorageConnectionStateTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val config = StorageConfiguration(bucket = "example-1234567890", prefix = "custom/v1/")
    private val credentials = StorageCredentials("SyntheticID", "SyntheticKey")
    private fun setup(): Triple<StorageConnectionStore, File, TestCipher> {
        val file = File(context.noBackupFilesDir, "test-${java.util.UUID.randomUUID()}.enc")
        val cipher = TestCipher()
        return Triple(StorageConnectionStore(AtomicFile(file), cipher) { }, file, cipher)
    }
    @Test fun atomicEncryptedBindingSurvivesRestartAndDisconnectKeepsConfiguration() {
        val (store, file, cipher) = setup()
        assertEquals(SavedConnection.Missing, store.load())
        store.saveVerified(config, credentials)
        assertFalse(file.readText(Charsets.ISO_8859_1).contains("SyntheticKey"))
        assertEquals(SavedConnection.Verified(config), StorageConnectionStore(AtomicFile(file), cipher) { }.load())
        val old = file.readBytes()
        store.saveVerified(config, credentials)
        assertFalse(old.contentEquals(file.readBytes()))
        store.disconnect()
        assertEquals(SavedConnection.Configured(config), store.load())
    }
    @Test fun backupCredentialsRequireMatchingVerifiedBindingAndNeverRewriteCiphertext() {
        val (store, file, cipher) = setup()
        assertNull(store.credentialsForVerified(config))
        store.saveVerified(config, credentials)
        val bytes = file.readBytes()
        val loaded = store.credentialsForVerified(config)!!
        assertEquals(credentials.secretID, loaded.secretID)
        assertEquals(credentials.secretKey, loaded.secretKey)
        assertArrayEquals(bytes, file.readBytes())
        assertNull(store.credentialsForVerified(config.copy(prefix = "other/folder/")))
        cipher.unavailable = true
        assertNull(store.credentialsForVerified(config))
        assertArrayEquals(bytes, file.readBytes())
        cipher.unavailable = false
        store.disconnect()
        assertNull(store.credentialsForVerified(config))
    }

    @Test fun silentAtomicFileRenameFailureNeverAcknowledgesNewBinding() {
        val (store, file, cipher) = setup()
        store.saveVerified(config, credentials)
        val old = file.readBytes()
        val faultyFile = object : AtomicFile(file) {
            override fun finishWrite(stream: java.io.FileOutputStream?) { stream?.close() }
        }
        val failedStore = StorageConnectionStore(faultyFile, cipher) { }
        assertThrows(IllegalStateException::class.java) { failedStore.saveVerified(StorageConfiguration(bucket = "example-1234567890"), StorageCredentials("NewID", "NewKey")) }
        assertArrayEquals(old, file.readBytes())
        assertEquals(SavedConnection.Verified(config), store.load())
    }
    @Test fun directorySyncFailureAfterRenameRecoversPreviousConnectionOnColdLaunch() {
        for (failureAt in listOf(2, 3)) {
            val (store, file, cipher) = setup()
            store.saveVerified(config, credentials)
            var syncs = 0
            val faulty = StorageConnectionStore(AtomicFile(file), cipher) { _ ->
                syncs++
                if (syncs == failureAt) throw java.io.IOException("synthetic fsync failure")
            }
            assertThrows(java.io.IOException::class.java) { faulty.saveVerified(StorageConfiguration(bucket = "example-1234567890"), StorageCredentials("NewID", "NewKey")) }
            assertEquals(SavedConnection.Verified(config), StorageConnectionStore(AtomicFile(file), cipher) { }.load())
            store.saveVerified(config, credentials) // A later successful retry commits and removes journal.
            assertFalse(File(file.path + ".rollback").exists())
        }
    }
    @Test fun firstSetupPostRenameFailureDoesNotOpenGate() {
        val (store, file, cipher) = setup()
        var syncs = 0
        val faulty = StorageConnectionStore(AtomicFile(file), cipher) { _ -> if (++syncs == 2) throw java.io.IOException("synthetic fsync failure") }
        assertThrows(java.io.IOException::class.java) { faulty.saveVerified(config, credentials) }
        assertEquals(SavedConnection.Missing, store.load())
    }
    @Test fun corruptOrUnavailableKeystorePreservesCiphertextAndNeverOpensGate() {
        val (store, file, cipher) = setup()
        store.saveVerified(config, credentials)
        val old = file.readBytes()
        cipher.unavailable = true
        assertEquals(SavedConnection.Locked, store.load())
        assertArrayEquals(old, file.readBytes())
        assertThrows(IllegalStateException::class.java) { store.saveVerified(StorageConfiguration(bucket = "example-1234567890"), credentials) }
        assertArrayEquals(old, file.readBytes())
        cipher.unavailable = false
        assertEquals(SavedConnection.Verified(config), store.load())
        file.writeBytes(old.also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() })
        assertEquals(SavedConnection.Locked, store.load())
        assertTrue(file.exists())
    }
    @Test fun networkFailureReplacingCredentialsKeepsPreviousConnection() {
        val (store, _, _) = setup()
        store.saveVerified(config, credentials)
        val executor = ManualExecutor()
        val callbacks = ArrayDeque<() -> Unit>()
        val controller = StorageConnectionController(store, StorageVerifier { _, _, _ -> throw VerificationException(ConnectionFailure.Permission) }, executor) { callbacks.add(it) }
        executor.runNext(); callbacks.removeFirst()()
        controller.verify(StorageConfiguration(bucket = "example-1234567890"), StorageCredentials("ReplacementID", "ReplacementKey"))
        executor.runNext(); callbacks.removeFirst()()
        assertEquals(SavedConnection.Verified(config), controller.connection)
        assertEquals(SavedConnection.Verified(config), store.load())
        assertEquals(ConnectionFailure.Permission.message, controller.message)
        controller.close()
    }
    @Test fun backgroundCloseOrDisconnectRevokesAlreadyQueuedSuccess() {
        for (action in listOf("background", "close", "disconnect")) {
            val (store, _, _) = setup()
            store.saveVerified(config, credentials)
            val executor = ManualExecutor()
            val callbacks = ArrayDeque<() -> Unit>()
            val controller = StorageConnectionController(store, StorageVerifier { _, _, _ -> }, executor) { callbacks.add(it) }
            executor.runNext(); callbacks.removeFirst()()
            controller.verify(StorageConfiguration(bucket = "example-1234567890"), StorageCredentials("ReplacementID", "ReplacementKey"))
            executor.runNext() // success is queued, but has not committed
            when (action) { "background" -> controller.cancelTransient(); "close" -> controller.close(); else -> controller.disconnect() }
            callbacks.removeFirst()()
            assertEquals(if (action == "disconnect") SavedConnection.Configured(config) else SavedConnection.Verified(config), store.load())
            controller.close()
        }
    }
    @Test fun cancellationClearsFailureMessageAndAllowsFreshVerification() {
        val (store, _, _) = setup()
        val executor = ManualExecutor()
        val callbacks = ArrayDeque<() -> Unit>()
        var attempts = 0
        val controller = StorageConnectionController(store, StorageVerifier { _, _, _ ->
            if (++attempts == 1) throw VerificationException(ConnectionFailure.Signature)
        }, executor) { callbacks.add(it) }
        executor.runNext(); callbacks.removeFirst()()
        controller.verify(config, credentials)
        executor.runNext(); callbacks.removeFirst()()
        assertEquals(ConnectionFailure.Signature.message, controller.message)
        controller.cancelTransient()
        assertNull(controller.message)
        assertFalse(controller.busy)
        assertEquals(SavedConnection.Missing, controller.connection)
        controller.verify(config, credentials)
        executor.runNext(); callbacks.removeFirst()()
        assertEquals(SavedConnection.Verified(config), store.load())
        assertEquals(2, attempts)
        controller.close()
    }
    @Test fun persistenceFailureAfterVerificationRetainsPreviousBinding() {
        val (store, _, cipher) = setup()
        store.saveVerified(config, credentials)
        val executor = ManualExecutor()
        val callbacks = ArrayDeque<() -> Unit>()
        val controller = StorageConnectionController(store, StorageVerifier { _, _, _ -> }, executor) { callbacks.add(it) }
        executor.runNext(); callbacks.removeFirst()()
        controller.verify(StorageConfiguration(bucket = "example-1234567890"), credentials)
        executor.runNext()
        cipher.unavailable = true
        callbacks.removeFirst()()
        assertEquals(SavedConnection.Verified(config), controller.connection)
        assertEquals(ConnectionFailure.SecureStorage.message, controller.message)
        cipher.unavailable = false
        assertEquals(SavedConnection.Verified(config), store.load())
        controller.close()
    }
    @Test fun verifiedOfflineLaunchDoesNotCallNetwork() {
        val (store, _, _) = setup()
        store.saveVerified(config, credentials)
        val executor = ManualExecutor()
        val callbacks = ArrayDeque<() -> Unit>()
        var networkCalls = 0
        val controller = StorageConnectionController(store, StorageVerifier { _, _, _ -> networkCalls++ }, executor) { callbacks.add(it) }
        assertNull(controller.connection)
        executor.runNext(); callbacks.removeFirst()()
        assertEquals(SavedConnection.Verified(config), controller.connection)
        assertEquals(0, networkCalls)
        controller.close()
    }
}
private class TestCipher : CredentialCipher {
    var unavailable = false
    private val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    override fun encrypt(plaintext: ByteArray): ByteArray {
        check(!unavailable)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key) }
        return cipher.iv + cipher.doFinal(plaintext)
    }
    override fun decrypt(ciphertext: ByteArray): ByteArray {
        check(!unavailable)
        return Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, ciphertext.copyOfRange(0, 12))) }.doFinal(ciphertext.copyOfRange(12, ciphertext.size))
    }
}
private class ManualExecutor : AbstractExecutorService() {
    private val tasks = ArrayDeque<Runnable>()
    private var stopped = false
    override fun execute(command: Runnable) { check(!stopped); tasks.add(command) }
    fun runNext() = tasks.removeFirst().run()
    override fun shutdown() { stopped = true }
    override fun shutdownNow(): MutableList<Runnable> { stopped = true; return tasks.toMutableList().also { tasks.clear() } }
    override fun isShutdown() = stopped
    override fun isTerminated() = stopped
    override fun awaitTermination(timeout: Long, unit: TimeUnit) = stopped
}
