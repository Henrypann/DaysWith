package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.archive.ArchiveJson
import com.henrypann.jinbao365.archive.ArchiveRecord
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.archive.EditStamp
import com.henrypann.jinbao365.archive.FieldEnvelope
import com.henrypann.jinbao365.archive.ImportProvenance
import com.henrypann.jinbao365.archive.MediaAsset
import com.henrypann.jinbao365.archive.MediaResource
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class V1MapperTest {
    private val prefix = "life/v1/android/"
    private val stamp = EditStamp(1, 100, "local-device")

    @Test fun mapsOnlyKnownAssetProvenanceWithoutChangingResourcesOrLocalEnvelopes() {
        val original = snapshot()
        val baseline = V1Mapper.map(original, prefix)
        val sources = ImportProvenance.entries.map { it.wireValue } + "futureSource"
        for (source in sources) {
            val local = original.copy(assets = original.assets.map { asset -> asset.copy(
                extensions = mapOf(ImportProvenance.EXTENSION_KEY to field(JsonPrimitive(source)))) })
            val before = ArchiveJson.canonical(local)
            val mapped = V1Mapper.map(local, prefix)
            val known = ImportProvenance.fromWire(source).takeUnless { it == ImportProvenance.Unknown }
            assertEquals(known?.wireValue, mapped.assets.single().importProvenance)
            assertEquals(baseline.resources, mapped.resources)
            assertEquals(baseline.moments, mapped.moments)
            assertEquals(before, ArchiveJson.canonical(local))
        }
        assertNull(baseline.assets.single().importProvenance)
    }

    @Test fun canonicalStoredUuidsAreUploadedDirectlyForEveryEntityAndReference() {
        val recordID = "643c9bae-c2f8-42f7-be24-119076330069"
        val assetID = "643c9bae-C2f8-42F7-bE24-11907633006b"
        val resourceIDs = listOf("643c9bae-c2f8-42f7-be24-11907633006c", "643C9BAE-C2F8-42F7-BE24-11907633006D")
        val local = snapshot().let { base -> base.copy(
            records = listOf(record(recordID).copy(assetIds = field(strings(assetID)),
)),

            assets = base.assets.map { it.copy(id = assetID, resourceIds = resourceIDs) },
            resources = base.resources.mapIndexed { index, resource ->
                resource.copy(id = resourceIDs[index], assetID = assetID)
            },
        ) }
        val before = ArchiveJson.canonical(local)
        val manifest = V1Mapper.map(local, prefix)
        assertEquals(recordID.uppercase(), manifest.moments.single().id)
        assertEquals(assetID.uppercase(), manifest.assets.single().id)
        assertEquals(resourceIDs.map { it.uppercase() }.toSet(), manifest.resources.map { it.id }.toSet())
        assertEquals(listOf(assetID.uppercase()), manifest.moments.single().assetIDs)
        assertEquals(resourceIDs.map { it.uppercase() }, manifest.assets.single().resourceIDs)
        assertTrue(manifest.resources.all { it.assetID == assetID.uppercase() })
        assertEquals(before, ArchiveJson.canonical(local))
    }

    @Test fun zeroMediaRecordsKeepTitleOrNoteAndRejectWhitespaceOnlyText() {
        val whitespace = " \t\n\u0085\u00A0\u200B\u3000"
        for ((title, note) in listOf("A day" to whitespace, whitespace to "A note", "" to "👕")) {
            val local = ArchiveSnapshot.empty().copy(records = listOf(record().copy(
                title = field(JsonPrimitive(title)), note = field(JsonPrimitive(note)),
                assetIds = field(strings()),
            )))
            val before = ArchiveJson.canonical(local)
            val result = V1Mapper.map(local, prefix)
            assertEquals(title, result.moments.single().title)
            assertEquals(note, result.moments.single().note)
            assertTrue(result.moments.single().assetIDs.isEmpty())
            assertTrue(result.assets.isEmpty())
            assertTrue(result.resources.isEmpty())
            assertEquals(before, ArchiveJson.canonical(local))
        }
        for (title in listOf(null, field(JsonNull), field(JsonPrimitive(whitespace)))) {
            val local = ArchiveSnapshot.empty().copy(records = listOf(record().copy(
                title = title, note = field(JsonPrimitive(whitespace)), assetIds = field(strings()),
            )))
            assertThrows(V1ValidationException::class.java) { V1Mapper.map(local, prefix) }
        }
    }

    @Test fun updatedAtCanBeReadWithoutMappingInvalidMediaAndIncludesEveryEditKind() {
        val local = record().copy(assetIds = field(strings("missing")),

            unknownFields = mapOf("future" to field(JsonNull).copy(edit = stamp.copy(at = 700))))
        assertEquals(700L, V1Mapper.updatedAt(local))
    }

    @Test fun mapsTrashAbsentTitleUnknownCaptureAndEveryEditWithoutChangingLocalSnapshot() {
        val original = snapshot().copy(records = listOf(record().copy(
            title = null,
            tombstone = field(JsonObject(mapOf("deletedAt" to JsonPrimitive(500L)))).copy(edit = stamp.copy(counter = 8, at = 600)),
            extensions = mapOf("future" to field(JsonPrimitive("kept")).copy(edit = stamp.copy(counter = 20, at = 700))),
            unknownFields = mapOf("futureField" to field(JsonPrimitive("kept")).copy(edit = stamp.copy(counter = 30, at = 800))),

        )))
        val before = ArchiveJson.canonical(original)
        val manifest = V1Mapper.map(original, prefix)
        val moment = manifest.moments.single()
        assertEquals("", moment.title)
        assertEquals("note", moment.note)
        assertEquals(500L, moment.trashedAt)
        assertEquals(100L, moment.createdAt)
        assertEquals(111L, moment.occurredAt)
        assertEquals(800L, moment.updatedAt)
        assertEquals(30L, moment.revision)
        assertEquals(0L, manifest.assets.single().capturedAt)
        assertEquals(0L, manifest.assets.single().revision)
        assertEquals(before, ArchiveJson.canonical(original))
    }

    @Test fun arraySortsUseMappedUuidWhileMediaOrderIsPreserved() {
        val local = snapshot(listOf("moment-asset", "second-asset")).copy(
            records = listOf(record("record-z"), record("record-a").copy(assetIds = field(strings("second-asset", "moment-asset")))),

        )
        val mapped = V1Mapper.map(local, prefix)
        assertEquals(mapped.moments.map { it.id }.sorted(), mapped.moments.map { it.id })
        assertEquals(mapped.assets.map { it.id }.sorted(), mapped.assets.map { it.id })
        assertEquals(mapped.resources.map { it.id }.sorted(), mapped.resources.map { it.id })
        assertEquals(listOf("second-asset", "moment-asset").map { V1Ids.map("asset", it) }, mapped.moments.single { it.id == V1Ids.map("record", "record-a") }.assetIDs)
    }

    @Test fun filenamesAreRepairedWithoutTouchingLocalsAndCaptureIsPreservedWhenKnown() {
        val originals = listOf("bad/\\\u0000\n.jpg", "", "a".repeat(254) + "👕" + "rest", "衣服.jpg")
        for ((index, name) in originals.withIndex()) {
            val local = snapshot().let { base -> base.copy(
                resources = base.resources.map { it.copy(originalFilename = name) },
                assets = base.assets.map { it.copy(capturedAt = field(JsonObject(mapOf(
                    "timeUnknown" to JsonPrimitive(false), "utc" to JsonPrimitive(321L), "zoneUnknown" to JsonPrimitive(true),
                )))) },
            ) }
            val result = V1Mapper.map(local, prefix)
            val expected = listOf("bad____.jpg", "import", "a".repeat(254), "衣服.jpg")[index]
            assertTrue(result.resources.all { it.originalFilename == expected })
            assertTrue(local.resources.all { it.originalFilename == name })
            assertEquals(321L, result.assets.single().capturedAt)
        }
    }

    @Test fun missingReferencesFailWithSpecificFields() {
        val missing = snapshot().copy(records = listOf(record().copy(assetIds = field(strings("missing")))))
        val failure = assertThrows(V1ValidationException::class.java) { V1Mapper.map(missing, prefix) }
        assertTrue(failure.message.orEmpty().contains("asset"))
    }

    private fun snapshot(ids: List<String> = listOf("moment-asset")): ArchiveSnapshot {
        val resources = ids.flatMap { id -> listOf(resource("$id-original", id, "photo"), resource("$id-preview", id, "preview")) }
        return ArchiveSnapshot.empty().copy(records = listOf(record()), assets = ids.map { id ->
            MediaAsset(id, "photo", field(JsonObject(mapOf("timeUnknown" to JsonPrimitive(true)))),
                resources.filter { it.assetID == id }.map { it.id }, emptyMap())
        }, resources = resources)
    }

    private fun record(id: String = "record") = ArchiveRecord(
        id = id, title = field(JsonPrimitive("title")), note = field(JsonPrimitive("note")),
        occurredAt = field(JsonObject(mapOf("utc" to JsonPrimitive(111L), "zoneUnknown" to JsonPrimitive(true), "estimated" to JsonPrimitive(true)))),
        createdAt = field(JsonPrimitive(100L)), assetIds = field(strings("moment-asset")),
 tombstone = field(JsonNull), extensions = emptyMap(),
    )
    private fun resource(id: String, asset: String, role: String) = MediaResource(
        id, asset, role, "image/jpeg", "photo.jpg", 10L, V1Json.sha256(id.toByteArray()), "local/unused-key", emptyMap(),
    )
    private fun field(value: JsonElement) = FieldEnvelope(value, stamp)
    private fun strings(vararg values: String) = JsonArray(values.map(::JsonPrimitive))
}
