package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.storage.COSSigner
import com.henrypann.jinbao365.storage.StorageConfiguration
import com.henrypann.jinbao365.storage.StorageCredentials
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.SocketTimeoutException
import java.net.URL
import java.security.cert.Certificate
import java.util.concurrent.CancellationException
import javax.net.ssl.HttpsURLConnection
import org.junit.Assert.*
import org.junit.Test

class CosObjectClientTest {
    private val configuration = StorageConfiguration(bucket = "example-1234567890", prefix = "life/v1/android/")
    private val credentials = StorageCredentials("fixtureID", "fixtureKey")
    private val key = configuration.prefix + "objects/aa/asset"

    private class Response(
        val status: Int = 200,
        val bytes: ByteArray = byteArrayOf(),
        val headers: Map<String, String> = emptyMap(),
        val stream: (() -> InputStream)? = null,
        val failure: IOException? = null,
    ) {
        constructor(text: String, status: Int = 200, headers: Map<String, String> = emptyMap()) :
            this(status, text.toByteArray(Charsets.UTF_8), headers)
    }

    private class Connection(url: URL, private val response: Response) : HttpsURLConnection(url) {
        val sent = ByteArrayOutputStream()
        var disconnected = false
        var inputReads = 0
        val streamedLength get() = fixedContentLengthLong
        override fun connect() = Unit
        override fun disconnect() { disconnected = true }
        override fun usingProxy() = false
        override fun getCipherSuite() = "fixture"
        override fun getLocalCertificates(): Array<Certificate>? = null
        override fun getServerCertificates(): Array<Certificate> = emptyArray()
        override fun getResponseCode(): Int { response.failure?.let { throw it }; return response.status }
        override fun getOutputStream(): OutputStream = sent
        override fun setRequestMethod(method: String) {
            assertNotEquals("No request may delete a COS object or abort a multipart upload", "DELETE", method)
            assertTrue(method in setOf("GET", "HEAD", "PUT", "POST"))
            super.setRequestMethod(method)
        }
        override fun getInputStream(): InputStream {
            inputReads++
            return response.stream?.invoke() ?: ByteArrayInputStream(response.bytes)
        }
        override fun getErrorStream(): InputStream = ByteArrayInputStream(response.bytes)
        override fun getHeaderField(name: String): String? = response.headers.entries.firstOrNull { it.key.equals(name, true) }?.value
    }

    private class Fixture(
        configuration: StorageConfiguration,
        credentials: StorageCredentials,
        responses: List<Response>,
        val cancellation: BackupCancellation = BackupCancellation(),
    ) {
        private var next = 0
        val requests = mutableListOf<Connection>()
        val client = CosObjectClient(configuration, credentials, cancellation, { url ->
            check(next < responses.size) { "Unexpected HTTP request" }
            Connection(url, responses[next++]).also { requests.add(it) }
        }, { 1_800_000_000L })
    }

    private fun fixture(vararg responses: Response, cancellation: BackupCancellation = BackupCancellation()) =
        Fixture(configuration, credentials, responses.toList(), cancellation)

    @Test fun immutablePutUsesScopedHttpsSignatureFixedLengthAndTimeouts() {
        val f = fixture(Response())
        val bytes = "中文/photo".toByteArray()
        val specialKey = configuration.prefix + "objects/中文 photo"
        f.client.put(specialKey, bytes, "image/jpeg")
        val request = f.requests.single()
        assertEquals("https", request.url.protocol)
        assertEquals(configuration.host, request.url.host)
        assertEquals("/life/v1/android/objects/%E4%B8%AD%E6%96%87%20photo", request.url.path)
        assertEquals("PUT", request.requestMethod)
        assertEquals("true", request.getRequestProperty("x-cos-forbid-overwrite"))
        assertEquals("AES256", request.getRequestProperty("x-cos-server-side-encryption"))
        assertEquals(V1Json.sha256(bytes), request.getRequestProperty("x-cos-meta-sha256"))
        assertEquals("identity", request.getRequestProperty("Accept-Encoding"))
        assertEquals(bytes.size.toLong(), request.streamedLength)
        assertArrayEquals(bytes, request.sent.toByteArray())
        assertFalse(request.instanceFollowRedirects)
        assertFalse(request.useCaches)
        assertEquals(15_000, request.connectTimeout)
        assertEquals(60_000, request.readTimeout)
        val signedHeaders = mapOf("Content-Type" to "image/jpeg", "x-cos-forbid-overwrite" to "true",
            "x-cos-server-side-encryption" to "AES256", "x-cos-meta-sha256" to V1Json.sha256(bytes), "Host" to configuration.host, "Accept-Encoding" to "identity")
        assertEquals(COSSigner(credentials).authorization("PUT", "/$specialKey", headers = signedHeaders, now = 1_800_000_000L),
            request.getRequestProperty("Authorization"))
        assertTrue(request.disconnected)
    }

    @Test fun listUsesConfiguredPrefixAndEveryContinuationPage() {
        val prefix = configuration.prefix + "commits/"
        val first = prefix + "00000000000000000001.json"
        val last = prefix + "00000000000000000002.json"
        val f = fixture(Response("<ListBucketResult><Contents><Key>$first</Key></Contents><IsTruncated>true</IsTruncated><NextMarker>$first</NextMarker></ListBucketResult>"),
            Response("<ListBucketResult><Contents><Key>$last</Key></Contents><IsTruncated>false</IsTruncated></ListBucketResult>"))
        assertEquals(listOf(first, last), f.client.list(prefix))
        assertEquals("max-keys=1000&prefix=life%2Fv1%2Fandroid%2Fcommits%2F", f.requests[0].url.query)
        assertTrue(f.requests[1].url.query.startsWith("marker=${COSSigner.encode(first)}&max-keys=1000&"))
        assertTrue(f.requests.all { it.disconnected })
    }

    @Test fun listRejectsOutsidePrefixMissingTruncationAndLoopingMarkers() {
        listOf(
            "<ListBucketResult><Contents><Key>outside/key</Key></Contents><IsTruncated>false</IsTruncated></ListBucketResult>",
            "<ListBucketResult/>",
            "<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>",
        ).forEach { xml ->
            assertFailure(CosFailure.InvalidResponse) { fixture(Response(xml)).client.list(configuration.prefix) }
        }
        val looping = Response("<ListBucketResult><IsTruncated>true</IsTruncated><NextMarker>same</NextMarker></ListBucketResult>")
        assertFailure(CosFailure.InvalidResponse) { fixture(looping, looping).client.list(configuration.prefix) }
    }

    @Test fun keyAndConfigurationValidationRunBeforeOpeningAConnection() {
        val f = fixture()
        listOf("other/key", configuration.prefix, key + "/../file", key + "%2Ffile", key + "\\file", key + "\n").forEach { bad ->
            assertFailure(CosFailure.Configuration) { f.client.get(bad) }
        }
        assertTrue(f.requests.isEmpty())
        assertFailure(CosFailure.Configuration) { CosObjectClient(configuration.copy(region = "other"), credentials) }
        assertFailure(CosFailure.Configuration) { CosObjectClient(configuration, StorageCredentials("bad secret", "key")) }
    }

    @Test fun redirectsNeverFollowAndResponsesRemainRedacted() {
        val f = fixture(Response("private response", 302, mapOf("Location" to "https://untrusted.invalid/secret")))
        val failure = assertFailure(CosFailure.InvalidResponse) { f.client.get(key) }
        assertFalse(failure.toString().contains("private"))
        assertFalse(failure.toString().contains("untrusted"))
        assertEquals(1, f.requests.size)
        assertFalse(f.requests.single().instanceFollowRedirects)
    }

    @Test fun headRequiresAnExactNonNegativeSizeAndHandlesMissingObjects() {
        val f = fixture(Response(headers = mapOf("Content-Length" to "4294967296", "ETag" to "opaque", "x-cos-meta-sha256" to "a".repeat(64))), Response(status = 404))
        assertEquals(CosObjectInfo(4_294_967_296L, "a".repeat(64)), f.client.head(key))
        assertNull(f.client.head(key))
        for (headers in listOf(emptyMap(), mapOf("Content-Length" to "-1"), mapOf("Content-Length" to "abc"))) {
            assertFailure(CosFailure.InvalidResponse) { fixture(Response(headers = headers)).client.head(key) }
        }
    }

    @Test fun headNeverUsesOpaqueEtagAsAnIntegrityHash() {
        val f = fixture(Response(headers = mapOf("Content-Length" to "3", "ETag" to "a".repeat(64))),
            Response(headers = mapOf("Content-Length" to "3", "x-cos-meta-sha256" to "invalid")))
        assertNull(f.client.head(key)!!.sha256)
        assertNull(f.client.head(key)!!.sha256)
    }

    @Test fun downloadsStreamAllBytesAndReturnSha256WithoutClosingCallerStream() {
        var closed = false
        val output = object : ByteArrayOutputStream() { override fun close() { closed = true; super.close() } }
        val f = fixture(Response("abc", headers = mapOf("Content-Length" to "3")))
        assertEquals(CosDownload(3, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), f.client.download(key, output))
        assertEquals("abc", output.toString("UTF-8"))
        assertFalse(closed)
        assertTrue(f.requests.single().disconnected)
    }

    @Test fun metadataAndMediaRejectOversizedDeclaredOrMismatchedBodies() {
        val hugeMetadata = fixture(Response(headers = mapOf("Content-Length" to "33554433")))
        assertFailure(CosFailure.InvalidResponse) { hugeMetadata.client.get(key) }
        assertEquals(0, hugeMetadata.requests.single().inputReads)
        val hugeResource = fixture(Response(headers = mapOf("Content-Length" to "2147483649")))
        assertFailure(CosFailure.InvalidResponse) { hugeResource.client.download(key, ByteArrayOutputStream()) }
        assertEquals(0, hugeResource.requests.single().inputReads)
        assertFailure(CosFailure.InvalidResponse) { fixture(Response("short", headers = mapOf("Content-Length" to "9"))).client.get(key) }
        assertFailure(CosFailure.InvalidResponse) { fixture(Response("short", headers = mapOf("Content-Length" to "9"))).client.download(key, ByteArrayOutputStream()) }
        assertFailure(CosFailure.InvalidResponse) { fixture(Response("abc", headers = mapOf("Content-Encoding" to "gzip"))).client.get(key) }
    }

    @Test fun metadataLimitAlsoAppliesWithoutContentLength() {
        val f = fixture(Response(stream = { object : InputStream() {
            var remaining = CosObjectClient.METADATA_LIMIT + 1
            override fun read() = if (remaining-- > 0) 0 else -1
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                if (remaining == 0) return -1
                val count = minOf(length, remaining)
                java.util.Arrays.fill(buffer, offset, offset + count, 0.toByte())
                remaining -= count
                return count
            }
        } }))
        assertFailure(CosFailure.InvalidResponse) { f.client.get(key) }
    }

    @Test fun filePutsAndPartsSendOnlyTheirFixedRange() {
        val file = File.createTempFile("cos-upload", ".bin")
        try {
            file.writeBytes(byteArrayOf(10, 11, 12, 13, 14, 15))
            val f = fixture(Response(), Response(headers = mapOf("ETag" to "\"part\"")))
            f.client.putFile(key, file, "image/jpeg")
            assertArrayEquals(file.readBytes(), f.requests[0].sent.toByteArray())
            assertEquals(6L, f.requests[0].streamedLength)
            assertEquals(V1Json.sha256(file.readBytes()), f.requests[0].getRequestProperty("x-cos-meta-sha256"))
            assertEquals("\"part\"", f.client.uploadPart(key, "upload/+id", 1, file, 2, 3))
            assertArrayEquals(byteArrayOf(12, 13, 14), f.requests[1].sent.toByteArray())
            assertEquals(3L, f.requests[1].streamedLength)
            assertEquals("partNumber=1&uploadId=upload%2F%2Bid", f.requests[1].url.query)
            assertEquals("true", f.requests[1].getRequestProperty("x-cos-forbid-overwrite"))
            assertFailure(CosFailure.InvalidResponse) { f.client.uploadPart(key, "id", 1, file, 5, 2) }
        } finally { file.delete() }
    }

    @Test fun multipartCreationAndCompletionUseImmutableHeaders() {
        val f = fixture(Response("<InitiateMultipartUploadResult><UploadId>upload-id</UploadId></InitiateMultipartUploadResult>"),
            Response("<CompleteMultipartUploadResult><ETag>done</ETag></CompleteMultipartUploadResult>"))
        assertEquals("upload-id", f.client.initiateMultipart(key, "video/mp4", "b".repeat(64)))
        f.client.completeMultipart(key, "upload-id", listOf(CosPart(2, "two"), CosPart(1, "\"a&b\"")))
        assertEquals(listOf("POST", "POST"), f.requests.map { it.requestMethod })
        assertTrue(f.requests.all { it.getRequestProperty("x-cos-forbid-overwrite") == "true" })
        assertTrue(f.requests.take(2).all { it.getRequestProperty("x-cos-server-side-encryption") == "AES256" })
        assertEquals("uploads=", f.requests[0].url.query)
        assertEquals("b".repeat(64), f.requests[0].getRequestProperty("x-cos-meta-sha256"))
        assertEquals(0L, f.requests[0].streamedLength)
        assertEquals("<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>&quot;a&amp;b&quot;</ETag></Part>" +
            "<Part><PartNumber>2</PartNumber><ETag>two</ETag></Part></CompleteMultipartUpload>", f.requests[1].sent.toString("UTF-8"))
    }

    @Test fun noDeleteRequestIsEverIssuedByAnySupportedOperation() {
        val f = fixture(
            Response("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>"),
            Response(headers = mapOf("Content-Length" to "3")),
            Response("abc"), Response("abc"), Response(), Response(),
            Response("<InitiateMultipartUploadResult><UploadId>session</UploadId></InitiateMultipartUploadResult>"),
            Response(headers = mapOf("ETag" to "part")),
            Response("<ListPartsResult><Part><PartNumber>1</PartNumber><ETag>part</ETag><Size>3</Size></Part><IsTruncated>false</IsTruncated></ListPartsResult>"),
            Response("<CompleteMultipartUploadResult><ETag>done</ETag></CompleteMultipartUploadResult>"),
        )
        val file = File.createTempFile("cos-immutable", ".bin")
        try {
            file.writeText("abc")
            f.client.list(configuration.prefix)
            f.client.head(key)
            f.client.get(key)
            f.client.download(key, ByteArrayOutputStream())
            f.client.put(key, file.readBytes(), "application/octet-stream")
            f.client.putFile(key, file, "application/octet-stream")
            val session = f.client.initiateMultipart(key, "application/octet-stream", V1Json.sha256(file.readBytes()))
            f.client.uploadPart(key, session, 1, file, 0, 3)
            f.client.completeMultipart(key, session, f.client.listParts(key, session))
            assertEquals(listOf("GET", "HEAD", "GET", "GET", "PUT", "PUT", "POST", "PUT", "GET", "POST"),
                f.requests.map { it.requestMethod })
            assertFalse(f.requests.any { it.requestMethod == "DELETE" })
            assertTrue(f.requests.filter { it.requestMethod in setOf("PUT", "POST") }
                .all { it.getRequestProperty("x-cos-forbid-overwrite") == "true" })
        } finally { file.delete() }
    }

    @Test fun multipartConflictLeavesIncompleteUploadWithoutCleanupRequests() {
        val f = fixture(Response(status = 409))
        assertFailure(CosFailure.Conflict) {
            f.client.completeMultipart(key, "retained-session", listOf(CosPart(1, "part")))
        }
        assertEquals(listOf("POST"), f.requests.map { it.requestMethod })
        assertTrue(f.requests.single().disconnected)
    }

    @Test fun listPartsPaginatesAndIncludesByteCounts() {
        val f = fixture(Response("<ListPartsResult><Part><PartNumber>1</PartNumber><ETag>one</ETag><Size>8388608</Size></Part><IsTruncated>true</IsTruncated><NextPartNumberMarker>1</NextPartNumberMarker></ListPartsResult>"),
            Response("<ListPartsResult><Part><PartNumber>2</PartNumber><ETag>two</ETag><Size>5</Size></Part><IsTruncated>false</IsTruncated></ListPartsResult>"))
        assertEquals(listOf(CosPart(1, "one", 8_388_608), CosPart(2, "two", 5)), f.client.listParts(key, "id"))
        assertEquals("max-parts=1000&part-number-marker=0&uploadId=id", f.requests[0].url.query)
        assertEquals("max-parts=1000&part-number-marker=1&uploadId=id", f.requests[1].url.query)
    }

    @Test fun listPartsRejectsDuplicateOrInvalidPartsAndBadMarkers() {
        val part = "<Part><PartNumber>1</PartNumber><ETag>one</ETag><Size>2</Size></Part>"
        listOf("$part$part<IsTruncated>false</IsTruncated>",
            "$part<IsTruncated>true</IsTruncated><NextPartNumberMarker>2</NextPartNumberMarker>",
            "<Part><PartNumber>0</PartNumber><ETag>one</ETag></Part><IsTruncated>false</IsTruncated>",
            "<Part><PartNumber>1</PartNumber><ETag>one</ETag><Size>-1</Size></Part><IsTruncated>false</IsTruncated>").forEach { body ->
            assertFailure(CosFailure.InvalidResponse) { fixture(Response("<ListPartsResult>$body</ListPartsResult>")).client.listParts(key, "id") }
        }
    }

    @Test fun multipartErrorsIncludeHttp200ErrorAndMissingSession() {
        assertFailure(CosFailure.Conflict) {
            fixture(Response("<Error><Code>FileAlreadyExists</Code><Message>private</Message></Error>")).client.completeMultipart(key, "id", listOf(CosPart(1, "part")))
        }
        assertFailure(CosFailure.NoSuchUpload) { fixture(Response(status = 404)).client.listParts(key, "id") }
        val f = fixture()
        assertFailure(CosFailure.InvalidResponse) { f.client.completeMultipart(key, "id", listOf(CosPart(2, "part"))) }
        assertFailure(CosFailure.InvalidResponse) { f.client.listParts(key, "bad\nid") }
        assertTrue(f.requests.isEmpty())
    }

    @Test fun multipartHttp200TransientXmlErrorsRemainRetryable() {
        listOf("InternalError", "SlowDown", "ServiceUnavailable").forEach { code ->
            assertFailure(CosFailure.Network) {
                fixture(Response("<Error><Code>$code</Code><Message>private</Message></Error>"))
                    .client.completeMultipart(key, "id", listOf(CosPart(1, "part")))
            }
        }
    }

    @Test fun conflictsPermissionAndNetworkFailuresUseFixedCategories() {
        for (status in listOf(409, 412)) assertFailure(CosFailure.Conflict) { fixture(Response(status = status)).client.put(key, byteArrayOf(1), "image/jpeg") }
        assertFailure(CosFailure.Conflict) { fixture(Response("<Error><Code>FileAlreadyExists</Code></Error>", 400)).client.put(key, byteArrayOf(1), "image/jpeg") }
        assertFailure(CosFailure.Permission) { fixture(Response(status = 403)).client.get(key) }
        val network = assertFailure(CosFailure.Network) { fixture(Response(failure = IOException("private secret"))).client.get(key) }
        assertFalse(network.toString().contains("private"))
        assertNull(network.cause)
        assertFailure(CosFailure.Timeout) { fixture(Response(failure = SocketTimeoutException("private secret"))).client.get(key) }
    }

    @Test fun xmlRejectsEntitiesMalformedUtf8ExcessDepthAndDuplicateFields() {
        val documents = listOf(
            "<!DOCTYPE x [<!ENTITY steal SYSTEM 'file:///secret'>]><ListBucketResult><IsTruncated>&steal;</IsTruncated></ListBucketResult>".toByteArray(),
            "<ListBucketResult><IsTruncated>false</IsTruncated><IsTruncated>false</IsTruncated></ListBucketResult>".toByteArray(),
            ("<ListBucketResult>" + "<a>".repeat(20) + "</a>".repeat(20) + "</ListBucketResult>").toByteArray(),
            byteArrayOf(0xc3.toByte(), 0x28),
        )
        documents.forEach { bytes -> assertFailure(CosFailure.InvalidResponse) { fixture(Response(bytes = bytes)).client.list(configuration.prefix) } }
    }

    @Test fun xmlAcceptsOneLeadingUtf8Bom() {
        val xml = "\uFEFF<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>"
        assertTrue(fixture(Response(xml)).client.list(configuration.prefix).isEmpty())
        assertFailure(CosFailure.InvalidResponse) {
            fixture(Response("\uFEFF$xml")).client.list(configuration.prefix)
        }
    }

    @Test fun cancellingBeforeOrDuringDownloadStopsAndDisconnects() {
        val before = fixture()
        before.cancellation.cancel()
        assertThrows(CancellationException::class.java) { before.client.get(key) }
        assertTrue(before.requests.isEmpty())
        val cancellation = BackupCancellation()
        val during = fixture(Response(stream = { object : ByteArrayInputStream("abc".toByteArray()) {
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                cancellation.cancel()
                return super.read(bytes, offset, length)
            }
        } }), cancellation = cancellation)
        assertThrows(CancellationException::class.java) { during.client.download(key, ByteArrayOutputStream()) }
        assertTrue(during.requests.single().disconnected)
    }

    @Test fun fileDownloadDeletesOnlyItsOwnIncompleteDestination() {
        val directory = java.nio.file.Files.createTempDirectory("cos-download").toFile()
        try {
            val destination = File(directory, "download")
            assertFailure(CosFailure.InvalidResponse) { fixture(Response("abc", headers = mapOf("Content-Length" to "4"))).client.download(key, destination) }
            assertFalse(destination.exists())
            destination.writeText("keep")
            assertFailure(CosFailure.InvalidResponse) { fixture().client.download(key, destination) }
            assertEquals("keep", destination.readText())
        } finally { directory.deleteRecursively() }
    }

    private fun assertFailure(expected: CosFailure, action: () -> Unit): CosException {
        val exception = assertThrows(CosException::class.java, action)
        assertEquals(expected, exception.failure)
        return exception
    }
}
