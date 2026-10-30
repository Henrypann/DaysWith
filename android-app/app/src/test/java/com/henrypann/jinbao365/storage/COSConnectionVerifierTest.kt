package com.henrypann.jinbao365.storage

import org.junit.Assert.*
import org.junit.Test
import java.net.SocketTimeoutException
import java.util.concurrent.CancellationException

class COSConnectionVerifierTest {
    private val configuration = StorageConfiguration(bucket = "example-1234567890")
    @Test fun connectionReadsBothParentFoldersWithoutWritingBeforeIdentitySelection() {
        val requests = mutableListOf<ProbeRequest>()
        COSConnectionVerifier().verify(configuration, VerificationCancellation()) { request, _ ->
            requests += request
            ProbeResponse(200, body = "<ListBucketResult/>".toByteArray())
        }
        assertEquals(listOf("GET", "GET"), requests.map { it.method })
        assertEquals(listOf("life/v1/dad/", "life/v1/mom/"), requests.map { it.query["prefix"] })
        assertTrue(requests.all { it.path == "/" && it.body.isEmpty() })
    }
    @Test fun missingOtherParentReadPermissionDoesNotVerify() {
        val error = assertThrows(VerificationException::class.java) {
            COSConnectionVerifier().verify(configuration, VerificationCancellation()) { request, _ ->
                if (request.query["prefix"] == "life/v1/mom/") ProbeResponse(403)
                else ProbeResponse(200, body = "<ListBucketResult/>".toByteArray())
            }
        }
        assertEquals(ConnectionFailure.Permission, error.category)
    }
    @Test fun redirectStopsBeforeAnyWrite() {
        var calls = 0
        val error = assertThrows(VerificationException::class.java) {
            COSConnectionVerifier().verify(configuration, VerificationCancellation()) { _, _ -> calls++; ProbeResponse(302, mapOf("Location" to "https://example.invalid")) }
        }
        assertEquals(ConnectionFailure.Network, error.category)
        assertEquals(1, calls)
    }
    @Test fun permissionSignatureAndTimeoutRemainRedacted() {
        listOf(ProbeResponse(403), ProbeResponse(403, body = "<Code>SignatureDoesNotMatch</Code>".toByteArray())).forEachIndexed { i, response ->
            val error = assertThrows(VerificationException::class.java) { COSConnectionVerifier().verify(configuration, VerificationCancellation()) { _, _ -> response } }
            assertEquals(if (i == 0) ConnectionFailure.Permission else ConnectionFailure.Signature, error.category)
        }
        val error = assertThrows(VerificationException::class.java) { COSConnectionVerifier().verify(configuration, VerificationCancellation()) { _, _ -> throw SocketTimeoutException("secret remote text") } }
        assertEquals(ConnectionFailure.Timeout, error.category)
        assertFalse(error.toString().contains("secret remote text"))
    }
    @Test fun unrecognizedIDAndExpiredCredentialsHaveDistinctRedactedMessages() {
        mapOf("InvalidAccessKeyId" to ConnectionFailure.InvalidSecretID, "AccessKeyIdNotExist" to ConnectionFailure.InvalidSecretID,
            "ExpiredToken" to ConnectionFailure.ExpiredCredentials).forEach { (code, category) ->
            val error = assertThrows(VerificationException::class.java) {
                COSConnectionVerifier().verify(configuration, VerificationCancellation()) { _, _ ->
                    ProbeResponse(403, body = "<Error><Code>$code</Code><Message>synthetic private server detail</Message></Error>".toByteArray())
                }
            }
            assertEquals(category, error.category)
            assertNotEquals(ConnectionFailure.Permission.message, error.category.message)
            assertFalse(error.toString().contains("synthetic private server detail"))
        }
    }
    @Test fun malformedListingCannotVerify() {
        val error = assertThrows(VerificationException::class.java) {
            COSConnectionVerifier().verify(configuration, VerificationCancellation()) { _, _ ->
                ProbeResponse(200, body = "<Unexpected/>".toByteArray())
            }
        }
        assertEquals(ConnectionFailure.ContentMismatch, error.category)
    }
    @Test fun listingCannotResolveExternalEntities() {
        val xml = """<!DOCTYPE x [<!ENTITY secret SYSTEM "file:///not-a-real-secret">]><ListBucketResult>&secret;</ListBucketResult>"""
        val error = assertThrows(VerificationException::class.java) {
            COSConnectionVerifier().verify(configuration, VerificationCancellation()) { _, _ ->
                ProbeResponse(200, body = xml.toByteArray())
            }
        }
        assertEquals(ConnectionFailure.ContentMismatch, error.category)
    }
    @Test fun cancelledRequestCannotContinue() {
        val cancellation = VerificationCancellation()
        var calls = 0
        assertThrows(CancellationException::class.java) {
            COSConnectionVerifier().verify(configuration, cancellation) { _, _ -> calls++; cancellation.cancel(); ProbeResponse(200) }
        }
        assertEquals(1, calls)
    }
}
