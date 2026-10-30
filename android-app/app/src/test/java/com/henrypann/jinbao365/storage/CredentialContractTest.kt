package com.henrypann.jinbao365.storage

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class CredentialContractTest {
    @Test fun sharedSigningVector() {
        Json.parseToJsonElement(fixture("signing.json").readText()).jsonObject.getValue("cases").jsonArray.forEach {
            val v = it.jsonObject
            fun field(name: String) = v.getValue(name).jsonPrimitive.content
            fun map(name: String) = v.getValue(name).jsonObject.mapValues { (_, value) -> value.jsonPrimitive.content }
            val actual = COSSigner(StorageCredentials(field("secretID"), field("secretKey"))).authorization(
                field("method"), field("path"), map("query"), map("headers"), field("now").toLong(), field("validFor").toLong())
            assertEquals(field("authorization"), actual)
        }
    }
    @Test fun canonicalAmbiguity() {
        assertThrows(IllegalArgumentException::class.java) {
            COSSigner(StorageCredentials("ID", "Key")).authorization("GET", "/", headers = mapOf("Host" to "x", "host" to "y"))
        }
    }
    @Test fun separateCredentialValuesAreBoundedAndNeverLogSecrets() {
        listOf("", " ", " ID", "ID ", "ID\tKey", "ID\nKey", "ID\rKey", "ID\u0000Key", "ID\u007fKey",
            "SecretId:value", "ID&Injected=value", "ID?Injected=value", "ID%26", "ID\\Key", "中", "a".repeat(1025)).forEach {
            assertFalse(StorageCredentials.validID(it))
            assertFalse(StorageCredentials.validKey(it))
            assertFalse(StorageCredentials(it, "SyntheticKey").valid())
            assertFalse(StorageCredentials("SyntheticID", it).valid())
        }
        assertTrue(StorageCredentials("a".repeat(1024), "Z09_-/+=".repeat(128)).valid())
        assertTrue(StorageCredentials("SyntheticID_-", "SyntheticKey_-/+=").valid())
        listOf("SyntheticID+", "SyntheticID/", "SyntheticID=").forEach {
            assertFalse(StorageCredentials.validID(it))
            assertFalse(StorageCredentials(it, "SyntheticKey").valid())
            assertTrue(StorageCredentials.validKey(it))
        }
        assertEquals("StorageCredentials(redacted)", StorageCredentials("SyntheticID", "SyntheticKey").toString())
    }
    @Test fun temporaryCredentialTextIsSignedWithoutDecodingOrChangingItsIdentifier() {
        val urlSafeId = "AKID" + "Aa0_-".repeat(12) + "AbcD"
        // Base64 of fixed synthetic bytes, including characters absent from URL-safe Base64.
        val base64Key = "+/8AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0="
        assertEquals(68, urlSafeId.length)
        assertEquals(44, base64Key.length)
        listOf(urlSafeId, "AKIDSynthetic_-").forEach { id ->
            val credentials = StorageCredentials(id, base64Key)
            assertTrue(credentials.valid())
            val authorization = COSSigner(credentials).authorization(
                "GET", "/life/v1/mom/objects/synthetic",
                headers = mapOf("Host" to "example.cos.ap-shanghai.myqcloud.com"), now = 1_700_000_000,
            )
            assertEquals(
                "q-sign-algorithm=sha1&q-ak=$id&q-sign-time=1699999940;1700000900&q-key-time=1699999940;1700000900" +
                    "&q-header-list=host&q-url-param-list=&q-signature=e319acc461e2e3cb1a321fdd6e6a608147d8fb2f",
                authorization,
            )
        }
    }
    @Test fun configurationNeverAcceptsExternalEndpoints() {
        listOf("example.com", "bucket-12345@evil", "bucket-12345/evil", "BUCKET-12345", "-bucket-12345").forEach { bucket ->
            assertThrows(IllegalArgumentException::class.java) { StorageConfiguration(bucket).validate() }
        }
        listOf("/life/", "life/../", "life//", "life/%2e%2e/", "life/./").forEach { prefix ->
            assertThrows(IllegalArgumentException::class.java) { StorageConfiguration(bucket = "example-1234567890", prefix = prefix).validate() }
        }
        assertThrows(IllegalArgumentException::class.java) { StorageConfiguration(bucket = "example-1234567890", region = "external").validate() }
        assertEquals("example-1234567890.cos.ap-shanghai.myqcloud.com", StorageConfiguration(bucket = "example-1234567890").host)
    }
}
private fun fixture(name: String): File {
    var directory = File(checkNotNull(System.getProperty("user.dir")))
    repeat(8) {
        val file = File(directory, "spec/fixtures/credentials/$name")
        if (file.isFile) return file
        directory = directory.parentFile ?: directory
    }
    error("shared credential fixture not found")
}
