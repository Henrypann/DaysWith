package com.henrypann.jinbao365.storage

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.URL
import java.security.Principal
import java.security.cert.Certificate
import javax.net.ssl.HttpsURLConnection

class HTTPSProbeTransportTest {
    @Test fun everyRedirectIsDisabledAndNoExternalRequestIsOpened() {
        for (status in listOf(301, 302, 303, 307, 308)) {
            val urls = mutableListOf<URL>()
            lateinit var connection: FakeHTTPS
            val config = StorageConfiguration(bucket = "example-1234567890")
            val transport = HTTPSProbeTransport(config, StorageCredentials("SyntheticID", "SyntheticKey")) { url ->
                urls += url
                FakeHTTPS(url, status).also { connection = it }
            }
            val failure = assertThrows(VerificationException::class.java) {
                COSConnectionVerifier().verify(config, VerificationCancellation(), transport)
            }
            assertEquals(ConnectionFailure.Network, failure.category)
            assertEquals(1, urls.size)
            assertEquals(config.host, urls.single().host)
            assertEquals("https", urls.single().protocol)
            assertFalse(connection.instanceFollowRedirects)
            assertEquals(10000, connection.connectTimeout)
            assertEquals(10000, connection.readTimeout)
            assertTrue(connection.disconnected)
            assertTrue(connection.getRequestProperty("Authorization").startsWith("q-sign-algorithm=sha1&"))
        }
    }
    @Test fun responsesAreBounded() {
        val connection = FakeHTTPS(URL("https://${StorageConfiguration(bucket = "example-1234567890").host}/"), 200, ByteArray(65537))
        val transport = HTTPSProbeTransport(StorageConfiguration(bucket = "example-1234567890"), StorageCredentials("ID", "Key")) { connection }
        assertThrows(VerificationException::class.java) { transport.execute(ProbeRequest("GET", "/"), VerificationCancellation()) }
        assertTrue(connection.disconnected)
    }
}
private class FakeHTTPS(url: URL, private val status: Int, private val bytes: ByteArray = byteArrayOf()) : HttpsURLConnection(url) {
    var disconnected = false
    override fun getResponseCode() = status
    override fun getInputStream() = ByteArrayInputStream(bytes)
    override fun getErrorStream() = ByteArrayInputStream(bytes)
    override fun getOutputStream() = ByteArrayOutputStream()
    override fun getHeaderFields(): MutableMap<String, MutableList<String>> = mutableMapOf("Location" to mutableListOf("https://external.invalid/"))
    override fun disconnect() { disconnected = true }
    override fun usingProxy() = false
    override fun connect() { }
    override fun getCipherSuite() = "TEST"
    override fun getLocalCertificates(): Array<Certificate>? = null
    override fun getServerCertificates(): Array<Certificate> = emptyArray()
    override fun getPeerPrincipal(): Principal? = null
    override fun getLocalPrincipal(): Principal? = null
}
