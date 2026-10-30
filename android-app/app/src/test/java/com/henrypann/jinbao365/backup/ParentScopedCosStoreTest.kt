package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.data.ParentIdentity
import com.henrypann.jinbao365.storage.StorageConfiguration
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.OutputStream
import org.junit.Assert.*
import org.junit.Test

class ParentScopedCosStoreTest {
    private val file = File("unused-synthetic-file")
    private val momKey = ParentIdentity.Mom.prefix + "objects/aa/photo"

    @Test fun everyMomWriteAndMultipartOperationDelegatesOnlyWithinMomFolder() {
        val delegate = RecordingStore()
        val store = ParentScopedCosStore(delegate, ParentIdentity.Mom)
        operations(store).forEach { it(momKey) }
        assertEquals(6, delegate.calls.size)
        assertTrue(delegate.calls.all { it.second.startsWith("life/v1/mom/") })
        assertEquals(listOf("put", "putFile", "initiateMultipart", "uploadPart", "listParts", "completeMultipart"), delegate.calls.map { it.first })
    }

    @Test fun allMomWritesRejectOtherParentRootLookalikesAndNonCanonicalKeysBeforeDelegating() {
        val delegate = RecordingStore()
        val store = ParentScopedCosStore(delegate, ParentIdentity.Mom)
        badKeys().forEach { key ->
            operations(store).forEach { operation -> assertConfigurationFailure { operation(key) } }
        }
        assertTrue(delegate.calls.isEmpty())
    }

    @Test fun readsRemainWithinConfirmedParentPrefixAndListAllowsItsRoot() {
        val delegate = RecordingStore()
        val store = ParentScopedCosStore(delegate, ParentIdentity.Mom)
        store.list(ParentIdentity.Mom.prefix)
        store.list(ParentIdentity.Mom.prefix + "commits/")
        store.head(momKey)
        store.get(momKey)
        store.download(momKey, ByteArrayOutputStream())
        store.download(momKey, file)
        assertEquals(6, delegate.calls.size)
        delegate.calls.clear()
        badKeys().forEach { key ->
            assertConfigurationFailure { store.head(key) }
            assertConfigurationFailure { store.get(key) }
            assertConfigurationFailure { store.download(key, ByteArrayOutputStream()) }
            assertConfigurationFailure { store.download(key, file) }
            if (key != ParentIdentity.Mom.prefix && key != "life/v1/mom/objects/a/") assertConfigurationFailure { store.list(key) }
        }
        assertTrue(delegate.calls.isEmpty())
    }

    @Test fun constructionCannotBindMomToDadSharedRootOrSimilarFolder() {
        listOf("life/v1/", "life/v1/dad/", "life/v1/mom-other/", "life/v1/mom/../").forEach { prefix ->
            val delegate = RecordingStore(StorageConfiguration(bucket = "example-1234567890", prefix = prefix))
            assertConfigurationFailure { ParentScopedCosStore(delegate, ParentIdentity.Mom) }
            assertTrue(delegate.calls.isEmpty())
        }
        val dad = RecordingStore(StorageConfiguration(bucket = "example-1234567890", prefix = ParentIdentity.Dad.prefix))
        ParentScopedCosStore(dad, ParentIdentity.Dad).put("life/v1/dad/snapshots/hash.json", byteArrayOf(1), "application/json")
        assertEquals("life/v1/dad/snapshots/hash.json", dad.calls.single().second)
    }

    private fun operations(store: CosObjectStore): List<(String) -> Unit> = listOf(
        { store.put(it, byteArrayOf(1), "text/plain") },
        { store.putFile(it, file, "image/jpeg") },
        { store.initiateMultipart(it, "image/jpeg", "a".repeat(64)); Unit },
        { store.uploadPart(it, "synthetic-upload", 1, file, 0, 1); Unit },
        { store.listParts(it, "synthetic-upload"); Unit },
        { store.completeMultipart(it, "synthetic-upload", listOf(CosPart(1, "synthetic-etag", 1))) },
    )

    private fun badKeys() = listOf(
        "", "life/v1/objects/a", "life/v1/dad/objects/a", "life/v1/mommy/objects/a", "life/v1/mom-other/objects/a",
        "life/v1/mom/", "life/v1/mom/../dad/objects/a", "life/v1/mom/objects/../a", "life/v1/mom/objects/./a",
        "life/v1/mom//objects/a", "life/v1/mom/objects/a/", "life/v1/mom/objects\\a",
        "life/v1/mom/%2e%2e/dad/a", "life/v1/mom/objects/a%2fb", "life/v1/mom/objects/a%252fb",
        "/life/v1/mom/objects/a", "life/v1/mom/objects/a\n", "life/v1/mom/objects/a\u007f", "life/v1/mom/objects/a\u0085",
        "life/v1/mom/objects/" + "中".repeat(400),
    )
    private fun assertConfigurationFailure(action: () -> Unit) {
        assertEquals(CosFailure.Configuration, assertThrows(CosException::class.java) { action() }.failure)
    }

    private class RecordingStore(
        override val configuration: StorageConfiguration = StorageConfiguration(bucket = "example-1234567890", prefix = ParentIdentity.Mom.prefix),
    ) : CosObjectStore {
        val calls = mutableListOf<Pair<String, String>>()
        private fun record(method: String, key: String) { calls += method to key }
        override fun list(prefix: String): List<String> { record("list", prefix); return emptyList() }
        override fun head(key: String): CosObjectInfo? { record("head", key); return null }
        override fun get(key: String): ByteArray { record("get", key); return byteArrayOf() }
        override fun download(key: String, output: OutputStream): CosDownload { record("download", key); return CosDownload(0, "a".repeat(64)) }
        override fun download(key: String, file: File): CosDownload { record("downloadFile", key); return CosDownload(0, "a".repeat(64)) }
        override fun put(key: String, bytes: ByteArray, contentType: String) = record("put", key)
        override fun putFile(key: String, file: File, contentType: String) = record("putFile", key)
        override fun initiateMultipart(key: String, contentType: String, sha256: String): String { record("initiateMultipart", key); return "synthetic-upload" }
        override fun uploadPart(key: String, uploadId: String, partNumber: Int, file: File, offset: Long, length: Long): String { record("uploadPart", key); return "synthetic-etag" }
        override fun listParts(key: String, uploadId: String): List<CosPart> { record("listParts", key); return emptyList() }
        override fun completeMultipart(key: String, uploadId: String, parts: List<CosPart>) = record("completeMultipart", key)
    }
}
