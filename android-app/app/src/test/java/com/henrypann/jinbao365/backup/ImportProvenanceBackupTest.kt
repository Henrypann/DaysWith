package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.archive.ImportProvenance
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.*
import org.junit.Test

class ImportProvenanceBackupTest {
    private val v1Hash = "d895075cf2b0b57ab9ccbdf73cdc1494fcfc262fbd3baef95bcdec364dea2ce7"
    private val v2Hash = "a1ae9390d608ecbe2f8436e6a24a8312541b24a9bce30877ab00b5ddd2cc80c1"
    private fun fixture(version: Int, hash: String) = checkNotNull(javaClass.getResourceAsStream(
        "/backup-v$version/snapshots/$hash.json")).use { it.readBytes() }

    @Test fun legacyVersionOneAndTwoSnapshotsKeepTheirExactBytesAndHashes() {
        for ((version, hash) in listOf(1 to v1Hash, 2 to v2Hash)) {
            val bytes = fixture(version, hash)
            val decoded = V1Json.decodeManifest(bytes)
            assertTrue(decoded.assets.all { it.importProvenance == null })
            assertArrayEquals(bytes, V1Json.encodeManifest(decoded))
            assertEquals(hash, V1Json.sha256(V1Json.encodeManifest(decoded)))
        }
    }

    @Test fun everyKnownSourceRoundTripsAndTheFrozen223ReaderStillReadsTheWholeArchive() {
        val legacyBytes = fixture(2, v2Hash)
        val legacy = Legacy223V1JsonFixture.decodeManifest(legacyBytes)
        for (source in ImportProvenance.entries.filter { it != ImportProvenance.Unknown }) {
            val enriched = legacy.copy(assets = legacy.assets.map { it.copy(importProvenance = source.wireValue) })
            val bytes = V1Json.encodeManifest(enriched)
            assertEquals(2, V1Json.decodeManifest(bytes).version)
            assertEquals(enriched, V1Json.decodeManifest(bytes))
            // This is the actual 2.2.3 parser, frozen before this optional field existed.
            val oldRead = Legacy223V1JsonFixture.decodeManifest(bytes)
            assertEquals(legacy, oldRead)
            assertArrayEquals(legacyBytes, Legacy223V1JsonFixture.encodeManifest(oldRead))
            assertEquals(legacy.resources, enriched.resources)
        }
    }

    @Test fun absentUnknownAndMalformedOptionalSourcesDoNotDiscardRecordsOrMedia() {
        val baseBytes = fixture(2, v2Hash)
        val base = V1Json.decodeManifest(baseBytes)
        val root = Json.parseToJsonElement(baseBytes.toString(Charsets.UTF_8)).jsonObject
        val sources = listOf(JsonNull, JsonPrimitive("unknown"), JsonPrimitive("futureSource"),
            JsonPrimitive(1), JsonPrimitive(true), JsonObject(emptyMap()), JsonArray(emptyList()))
        for (raw in sources) {
            val assets = root.getValue("assets").jsonArray.map { asset ->
                JsonObject(asset.jsonObject + ("importProvenance" to raw))
            }
            val bytes = JsonObject(root + ("assets" to JsonArray(assets))).toString().toByteArray()
            val decoded = V1Json.decodeManifest(bytes)
            assertEquals(base, decoded)
            assertArrayEquals(baseBytes, V1Json.encodeManifest(decoded))
        }
        for (source in listOf(null, "unknown", "futureSource")) {
            assertArrayEquals(baseBytes, V1Json.encodeManifest(base.copy(
                assets = base.assets.map { it.copy(importProvenance = source) })))
        }
    }

    @Test fun sourceOnlyChangeUpdatesManifestAndCoveredRecordHashesWithoutChangingMediaIdentity() {
        val base = V1Json.decodeManifest(fixture(2, v2Hash))
        val enriched = base.copy(assets = base.assets.map { it.copy(importProvenance = "systemProvided") })
        assertNotEquals(V1Json.sha256(V1Json.encodeManifest(base)), V1Json.sha256(V1Json.encodeManifest(enriched)))
        assertNotEquals(BackupEngine.momentHashes(base), BackupEngine.momentHashes(enriched))
        assertEquals(base.moments, enriched.moments)
        // byteCount, SHA-256 and objectKey belong to the saved bytes, not their provenance.
        assertEquals(base.resources, enriched.resources)
        assertEquals(base.resources.map { it.objectKey }, enriched.resources.map { it.objectKey })
    }
}
