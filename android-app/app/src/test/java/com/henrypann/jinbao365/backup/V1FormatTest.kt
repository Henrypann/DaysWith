package com.henrypann.jinbao365.backup

import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class V1FormatTest {
    private val id = "643C9BAE-C2F8-42F7-BE24-119076330069"

    @Test fun uuidV5MatchesRfcDnsVectorAndNamespaceBits() {
        val actual = V1Ids.uuidV5(UUID.fromString("6ba7b810-9dad-11d1-80b4-00c04fd430c8"), "python.org")
        assertEquals("886313e1-3b8a-5372-9b90-0c9aee199e5d", actual.toString())
        assertEquals(5, actual.version())
        assertEquals(2, actual.variant())
    }

    @Test fun projectNamespaceHasFixedKnownVectorsAndPreservesExistingUuids() {
        assertEquals("6F0F3B0E-6B2F-5C55-9E57-0D365A7D0001", V1IdNamespace)
        val expected = mapOf(
            "record" to "729821C3-92EC-547D-8423-E0A85BAA6A11",
            "asset" to "9ED6C522-4F56-55C6-99FE-D50CDA4FC5A7",
            "resource" to "D4551570-A072-5141-915E-C4D2662C4CC1",
        )
        expected.forEach { (kind, uuid) ->
            assertEquals(uuid, V1Ids.map(kind, "local-123"))
            assertEquals(uuid, V1Ids.map(kind, "local-123"))
            assertEquals(id, V1Ids.map(kind, id.lowercase()))
        }
        assertNotEquals(V1Ids.map("asset", "中文"), V1Ids.map("asset", "中文 "))
        assertThrows(IllegalArgumentException::class.java) { V1Ids.map("device", "id") }
    }

    @Test fun legacyCompatibilityPathListsEveryAffectedEntityKindAndRejectsCanonicalUuids() {
        // Current producers: PreparedImports / nextRecordId, MediaImporter assets/resources,
        val legacyIdsByEntityKind = linkedMapOf(
            "record" to listOf("rec-0123456789ab", "rec-0123456789ab-2"),
            "asset" to listOf("asset-0123456789ab"),
            "resource" to listOf("res-photo-0123456789ab", "res-preview-asset-0123456789ab-fedcba987654"),
        )
        for ((kind, localIds) in legacyIdsByEntityKind) {
            for (localId in localIds) {
                val compatibilityId = V1Ids.legacyIdToV1Uuid(kind, localId)
                assertEquals(compatibilityId, V1Ids.map(kind, localId))
                assertEquals(5, UUID.fromString(compatibilityId).version())
            }
            assertEquals(id, V1Ids.map(kind, id))
            assertEquals(id, V1Ids.map(kind, id.lowercase()))
            assertThrows(IllegalArgumentException::class.java) { V1Ids.legacyIdToV1Uuid(kind, id) }
            assertThrows(IllegalArgumentException::class.java) { V1Ids.legacyIdToV1Uuid(kind, id.lowercase()) }
        }
        // Multi-select imports store rec-<uuid>; that stored UUID is uploaded, not a derived one.
        assertEquals(id, V1Ids.map("record", "rec-$id"))
        // UUID.fromString tolerates short groups; only canonical stored UUIDs bypass compatibility.
        assertEquals(5, UUID.fromString(V1Ids.map("record", "1-2-3-4-5")).version())
        assertThrows(IllegalArgumentException::class.java) { V1Ids.legacyIdToV1Uuid("device", "legacy") }
    }

    @Test fun compactSortedUtf8JsonOmitsOnlyAbsentOptionalFields() {
        val manifest = manifest()
        val bytes = V1Json.encodeManifest(manifest)
        val text = bytes.toString(Charsets.UTF_8)
        assertEquals(manifest, V1Json.decodeManifest(bytes))
        assertArrayEquals(bytes, V1Json.encodeManifest(manifest))
        assertArrayEquals(bytes, V1Json.encodeManifest(V1Json.decodeManifest(bytes)))
        assertSortedKeys(Json.parseToJsonElement(text))
        assertTrue(text.contains("\"title\":\"\""))
        assertTrue(text.contains("中文 / café 👕"))
        assertTrue(text.contains("\\n\\t\\\"\\\\"))
        assertFalse(text.contains("\\/"))
        assertFalse(text.contains("\\u4e2d"))
        assertFalse(text.contains("trashedAt"))
        assertFalse(text.contains("coverAssetID"))
        assertFalse(text.contains("null"))
        assertFalse(text.contains(": "))
        assertFalse(text.contains(", "))
        assertFalse(text.contains('\n'))
    }

    @Test fun commitMatchesExactCodableKeysAndOmitsFirstParentHash() {
        val commit = V1Commit(
            sequence = 1, writerDeviceID = id, manifestHash = "a".repeat(64),
            manifestKey = "life/v1/android/snapshots/${"a".repeat(64)}.json", createdAt = 123, requestID = id,
        )
        val expected = """{"createdAt":123,"kind":"snapshot","manifestHash":"${"a".repeat(64)}","manifestKey":"life/v1/android/snapshots/${"a".repeat(64)}.json","requestID":"$id","sequence":1,"version":1,"writerDeviceID":"$id"}"""
        assertEquals(expected, V1Json.encodeCommit(commit).toString(Charsets.UTF_8))
        assertEquals(commit, V1Json.decodeCommit(expected.toByteArray()))
        val child = commit.copy(sequence = 2, parentHash = V1Json.sha256(expected.toByteArray()))
        assertEquals(child, V1Json.decodeCommit(V1Json.encodeCommit(child)))
        assertTrue(V1Json.encodeCommit(child).toString(Charsets.UTF_8).contains("\"parentHash\":"))
        assertEquals("commits/00000000000000000001.json", V1Json.commitRelativeKey(1))
        assertEquals("commits/09223372036854775807.json", V1Json.commitRelativeKey(Long.MAX_VALUE))
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", V1Json.sha256(byteArrayOf()))
    }

    @Test fun presentOptionalFieldsAndInt64RemainIntegers() {
        val source = manifest()
        val manifest = source.copy(
            moments = source.moments.map { it.copy(trashedAt = 8_640_000_000_000_000, revision = 9_007_199_254_740_991) },

        )
        val text = V1Json.encodeManifest(manifest).toString(Charsets.UTF_8)
        assertTrue(text.contains("\"trashedAt\":8640000000000000"))
        assertTrue(text.contains("\"revision\":9007199254740991"))
        assertEquals(manifest, V1Json.decodeManifest(text.toByteArray()))
    }

    @Test fun decoderMatchesCodableRequiredTypesAndIgnoresUnknownKeys() {
        val base = V1Json.encodeManifest(manifest()).toString(Charsets.UTF_8)
        val invalid = listOf(
            base.replace("\"version\":1", "\"version\":\"1\""),
            base.replace("\"version\":1", "\"version\":1.0"),
            base.replace("\"revision\":0", "\"revision\":9223372036854775808"),
            base.replace(id, "not-a-uuid"),
            base.replace("\"title\":\"\",", ""),
            base.replace("\"note\":", "\"renamedNote\":"),
        )
        invalid.forEach { text -> assertThrows(V1ValidationException::class.java) { V1Json.decodeManifest(text.toByteArray()) } }
        val extra = base.dropLast(1) + ",\"future\":{\"anything\":true}}"
        assertEquals(manifest(), V1Json.decodeManifest(extra.toByteArray()))
        assertEquals(manifest(), V1Json.decodeManifest(base.replace(id, id.lowercase()).toByteArray()))
        assertThrows(V1ValidationException::class.java) { V1Json.decodeManifest(byteArrayOf(0xc3.toByte(), 0x28)) }
        assertThrows(V1ValidationException::class.java) { V1Json.decodeManifest(ByteArray(V1Json.METADATA_LIMIT + 1)) }
    }

    private fun manifest() = V1Manifest(
        moments = listOf(V1Moment(id = id, occurredAt = 1, createdAt = 2, updatedAt = 3,
            assetIDs = listOf(id), note = "中文 / café 👕\n\t\"\\")),

        assets = listOf(V1Asset(id = id, kind = "photo", capturedAt = 0, resourceIDs = listOf(id))),
        resources = listOf(V1Resource(id, id, "photo", "image/jpeg", "IMG/中文.jpg", 8,
            "a".repeat(64), "life/v1/android/objects/aa/${"a".repeat(64)}")),
    )

    private fun assertSortedKeys(element: JsonElement) {
        when (element) {
            is JsonObject -> {
                assertEquals(element.keys.sorted(), element.keys.toList())
                element.values.forEach(::assertSortedKeys)
            }
            is JsonArray -> element.forEach(::assertSortedKeys)
            else -> Unit
        }
    }
}
