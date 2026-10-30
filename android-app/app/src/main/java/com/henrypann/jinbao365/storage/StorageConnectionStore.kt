package com.henrypann.jinbao365.storage

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.system.Os
import android.system.OsConstants
import java.security.MessageDigest
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

sealed interface SavedConnection {
    data object Missing : SavedConnection
    /** Includes unavailable/invalidated KeyStore, authentication or corrupt ciphertext. Never erase it. */
    data object Locked : SavedConnection
    data class Configured(val configuration: StorageConfiguration) : SavedConnection
    data class Verified(val configuration: StorageConfiguration) : SavedConnection
}

internal interface CredentialCipher {
    fun encrypt(plaintext: ByteArray): ByteArray
    fun decrypt(ciphertext: ByteArray): ByteArray
}
internal class AndroidCredentialCipher : CredentialCipher {
    private val alias = "jinbao365.storage.v1"
    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        check(create) // Never recreate a missing key when reading existing ciphertext.
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true).build())
        return generator.generateKey()
    }
    override fun encrypt(plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(true)) // Provider generates a new random IV every time.
        cipher.updateAAD("jinbao365.connection.v1".toByteArray())
        return byteArrayOf(1, cipher.iv.size.toByte()) + cipher.iv + cipher.doFinal(plaintext)
    }
    override fun decrypt(ciphertext: ByteArray): ByteArray {
        require(ciphertext.size >= 30 && ciphertext[0] == 1.toByte() && ciphertext[1] == 12.toByte())
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, ciphertext.copyOfRange(2, 14)))
        cipher.updateAAD("jinbao365.connection.v1".toByteArray())
        return cipher.doFinal(ciphertext, 14, ciphertext.size - 14)
    }
}

/** Configuration, verification binding and credentials are one authenticated atomic document. */
class StorageConnectionStore internal constructor(
    private val file: AtomicFile, private val cipher: CredentialCipher,
    private val syncDirectory: (File) -> Unit = { directory ->
        val descriptor = Os.open(directory.path, OsConstants.O_RDONLY, 0)
        try { Os.fsync(descriptor) } finally { Os.close(descriptor) }
    },
) {
    private val rollback = AtomicFile(File(file.baseFile.path + ".rollback"))
    constructor(context: Context) : this(AtomicFile(File(context.noBackupFilesDir, "storage-connection.enc")), AndroidCredentialCipher())

    @Synchronized fun load(): SavedConnection {
        return try {
            val encrypted = effectiveCiphertext() ?: return SavedConnection.Missing
            val record = decode(encrypted)
            val config = configuration(record)
            if (record.getBoolean("verified")) {
                check(credentials(record).valid())
                SavedConnection.Verified(config)
            } else SavedConnection.Configured(config)
        } catch (_: Exception) { SavedConnection.Locked }
    }
    /** Read only from the existing authenticated, verified document; never recreate or rewrite it. */
    @Synchronized fun credentialsForVerified(expected: StorageConfiguration): StorageCredentials? = try {
        val record = read()
        if (record.getBoolean("verified") && configuration(record) == expected) {
            credentials(record).takeIf { it.valid() }
        } else null
    } catch (_: Exception) { null }

    private fun configuration(record: JSONObject): StorageConfiguration {
        check(record.getInt("version") == 1)
        return StorageConfiguration(record.getString("bucket"), record.getString("region"), record.getString("prefix")).also { it.validate() }
    }
    private fun credentials(record: JSONObject) = StorageCredentials(record.getString("secretID"), record.getString("secretKey"))
    private fun exists(atomic: AtomicFile) = atomic.baseFile.exists() || File(atomic.baseFile.path + ".bak").exists()
    private fun boundedRead(atomic: AtomicFile): ByteArray = atomic.openRead().use { input ->
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            require(output.size() + count <= 16384)
            output.write(buffer, 0, count)
        }
        output.toByteArray()
    }
    // A retained encrypted journal is authoritative until the transaction has committed durably.
    private fun effectiveCiphertext(): ByteArray? = when {
        exists(rollback) -> boundedRead(rollback).takeIf { it.isNotEmpty() }
        exists(file) -> boundedRead(file)
        else -> null
    }
    private fun decode(ciphertext: ByteArray): JSONObject {
        val plaintext = cipher.decrypt(ciphertext)
        return try { JSONObject(plaintext.toString(Charsets.UTF_8)) } finally { plaintext.fill(0) }
    }
    private fun read(): JSONObject = decode(checkNotNull(effectiveCiphertext()))
    @Synchronized fun saveVerified(configuration: StorageConfiguration, credentials: StorageCredentials) {
        configuration.validate(); require(credentials.valid())
        write(configuration, credentials)
    }
    /** Keep settings and all archive data. Only revoke the saved credential binding. */
    @Synchronized fun disconnect() {
        val record = read()
        write(configuration(record), null)
    }
    private fun write(configuration: StorageConfiguration, credentials: StorageCredentials?) {
        val record = JSONObject().put("version", 1).put("bucket", configuration.bucket)
            .put("region", configuration.region).put("prefix", configuration.prefix)
            .put("verified", credentials != null)
        if (credentials != null) record.put("secretID", credentials.secretID).put("secretKey", credentials.secretKey)
        val plaintext = record.toString().toByteArray(Charsets.UTF_8)
        val encrypted = try { cipher.encrypt(plaintext) } finally { plaintext.fill(0) }
        // Encryption failure leaves the existing binding untouched. Journal stores only prior ciphertext.
        val prior = effectiveCiphertext() ?: byteArrayOf()
        durableReplace(rollback, prior)
        try {
            durableReplace(file, encrypted)
            check(rollback.baseFile.delete())
            syncDirectory(checkNotNull(file.baseFile.parentFile))
        } catch (failure: Exception) {
            // Post-rename readback/fsync failures must not become verified after a cold launch.
            // Keep/recreate the previous authenticated binding as the authoritative recovery journal.
            if (!exists(rollback)) {
                try { durableReplace(rollback, prior) } catch (_: Exception) {
                    // Best-effort restore if even the recovery journal cannot be written.
                    if (prior.isNotEmpty()) runCatching { durableReplace(file, prior) }
                    else runCatching { file.delete() }
                }
            }
            throw failure
        }
    }
    private fun durableReplace(target: AtomicFile, ciphertext: ByteArray) {
        val stream = target.startWrite()
        try {
            stream.write(ciphertext)
            stream.fd.sync()
            target.finishWrite(stream)
            // AtomicFile logs rename failures instead of throwing. Never acknowledge those writes.
            check(!File(target.baseFile.path + ".new").exists())
            check(target.baseFile.isFile && target.baseFile.length() == ciphertext.size.toLong())
            check(MessageDigest.isEqual(ciphertext, target.baseFile.readBytes()))
            syncDirectory(checkNotNull(target.baseFile.parentFile))
        } catch (failure: Exception) { target.failWrite(stream); throw failure }
    }
}
