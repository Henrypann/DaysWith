package com.henrypann.jinbao365.archive

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.MessageDigest

/** The same files Swift reads under spec/fixtures/canonical/. */
class CanonicalFixtureTest {
    @Test
    fun encoderMatchesSharedCanonicalBytes() {
        val directory = canonicalFixtureDirectory()
        val files = directory.listFiles { file -> file.extension == "json" }?.sortedBy { it.name }
            ?: error("no canonical fixtures in $directory")
        assertTrue(files.size >= 2)
        for (file in files) {
            val root = Json.parseToJsonElement(file.readText()).jsonObject
            val actual = canonicalJson(root.getValue("input"))
            val expected = root.getValue("canonical").jsonPrimitive.content
            val sha = root.getValue("sha256").jsonPrimitive.content
            assertEquals(file.name, expected, actual)
            assertEquals(file.name, sha, sha256(actual))
        }
    }
}

private fun sha256(text: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
    return digest.joinToString("") { "%02x".format(it) }
}

private fun canonicalFixtureDirectory(): File {
    var directory = File(checkNotNull(System.getProperty("user.dir")))
    repeat(8) {
        val candidate = File(directory, "spec/fixtures/canonical")
        if (candidate.isDirectory) return candidate
        directory = directory.parentFile ?: return@repeat
    }
    error("spec/fixtures/canonical not found from ${System.getProperty("user.dir")}")
}
