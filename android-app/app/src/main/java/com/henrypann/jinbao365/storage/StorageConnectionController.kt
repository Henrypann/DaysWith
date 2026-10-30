package com.henrypann.jinbao365.storage

import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.concurrent.CancellationException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future

/** UI dispatcher serializes publication/commit with lifecycle revocation. */
class StorageConnectionController internal constructor(
    private val store: StorageConnectionStore,
    private val verifier: StorageVerifier = COSConnectionVerifier(),
    private val executor: ExecutorService = Executors.newSingleThreadExecutor(),
    private val dispatch: ((() -> Unit) -> Unit) = { Handler(Looper.getMainLooper()).post(it) },
) {
    var connection: SavedConnection? by mutableStateOf(null)
        private set
    var busy by mutableStateOf(false)
        private set
    var message: String? by mutableStateOf(null)
        private set
    private var generation = 0L
    private var cancellation: VerificationCancellation? = null
    private var pending: Future<*>? = null
    init { retryLoad() }
    fun retryLoad() {
        cancelTransient()
        val token = generation
        busy = true
        pending = executor.submit {
            val loaded = store.load()
            dispatch { if (token == generation) { connection = loaded; busy = false } }
        }
    }
    fun verify(configuration: StorageConfiguration, credentials: StorageCredentials) {
        cancelTransient()
        val token = generation
        val cancel = VerificationCancellation()
        cancellation = cancel
        busy = true
        message = null
        pending = executor.submit {
            val failure = try {
                verifier.verify(configuration, credentials, cancel)
                cancel.check()
                null
            } catch (_: CancellationException) { return@submit }
            catch (error: VerificationException) { error.category }
            catch (_: Exception) { ConnectionFailure.Network }
            dispatch {
                if (token != generation) return@dispatch
                if (failure == null) {
                    try {
                        cancel.check()
                        store.saveVerified(configuration, credentials)
                        connection = SavedConnection.Verified(configuration)
                        message = "云存储已连接"
                    } catch (_: CancellationException) { }
                    catch (_: Exception) { message = ConnectionFailure.SecureStorage.message }
                } else message = failure.message
                busy = false
                cancellation = null
                pending = null
            }
        }
    }
    fun disconnect() {
        cancelTransient()
        try { store.disconnect(); connection = store.load(); message = null }
        catch (_: Exception) { message = ConnectionFailure.SecureStorage.message }
    }
    fun cancelTransient() {
        generation++
        cancellation?.cancel()
        cancellation = null
        pending?.cancel(true)
        pending = null
        busy = false
        message = null
    }
    fun close() { cancelTransient(); executor.shutdownNow() }
}
