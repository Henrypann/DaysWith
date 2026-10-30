package com.henrypann.jinbao365.archive

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class MergeFixtureTest {
    @Test
    fun everyAuxiliaryFixtureExecutesItsProtocolOperation() {
        for (id in AUXILIARY_IDS) {
            val root = fixtureRoot(id)
            when (root.getValue("kind").jsonPrimitive.content) {
                "fail-closed" -> {
                    val base = ArchiveJson.parseSnapshot(root.getValue("base").jsonObject)
                    val local = ArchiveJson.parseSnapshot(root.getValue("local").jsonObject)
                    val remote = ArchiveJson.parseSnapshot(root.getValue("remote").jsonObject)
                    assertFailsClosed { ArchiveMerge.merge(base, local, remote) }
                    assertFailsClosed { ArchiveMerge.merge(base, remote, local) }
                }
                "parse-error" -> assertFailsClosed { ArchiveJson.parseSnapshot(root.getValue("document").jsonObject) }
                "purge" -> {
                    val published = ArchiveJson.parseSnapshot(root.getValue("published").jsonObject)
                    var pending = ArchiveJson.parseSnapshot(root.getValue("snapshot").jsonObject)
                    root["stampAt"]?.let {
                        pending = ArchiveEdits.stampFirstPublish(pending, published, it.jsonPrimitive.content.toLong())
                    }
                    val actual = ArchiveEdits.purgeExpired(pending, root.getValue("now").jsonPrimitive.content.toLong(), published)
                    assertCanonicalEqual(id, ArchiveJson.encodeSnapshot(actual), root.getValue("expected").jsonObject)
                }
                else -> error("unknown fixture kind: $id")
            }
        }
    }

    @Test
    fun everySharedFixtureMatchesInBothOrders() {
        val fixtures = loadFixtures()
        assertEquals(REQUIRED_IDS, fixtures.map { it.id }.toSet())
        for (fixture in fixtures) {
            assertTrue(fixture.id, fixture.requireSymmetry)
            val forward = ArchiveMerge.merge(fixture.base, fixture.local, fixture.remote)
            val swapped = ArchiveMerge.merge(fixture.base, fixture.remote, fixture.local)
            assertCanonicalEqual(fixture.id, ArchiveJson.encodeSnapshot(forward), fixture.expected)
            assertCanonicalEqual("${fixture.id} swapped", ArchiveJson.encodeSnapshot(swapped), fixture.expected)
            assertEquals(fixture.expectedOrder.records, ArchiveOrder.of(forward).records)
            assertEquals(fixture.expectedOrder.assets, ArchiveOrder.of(forward).assets)
            assertEquals(fixture.expectedOrder.records, ArchiveOrder.of(swapped).records)
            assertEquals(fixture.expectedOrder.assets, ArchiveOrder.of(swapped).assets)
        }
    }

    @Test
    fun fixtureCatalogMatchesTheIosChecks() {
        val fixtures = loadFixtures().associateBy { it.id }
        val overflow = fixtures.getValue("media-overflow")
        val overflowRecord = overflow.expectedRecord()
        assertEquals(31, overflowRecord.getValue("assetIDs").jsonObject.getValue("value").jsonArray.size)
        assertEquals(true, overflowRecord.getValue("mediaOverflow").jsonPrimitive.boolean)

        val trashed = fixtures.getValue("trashed-record-keeps-media")
        val trashedRecord = trashed.expectedRecord()
        assertEquals(
            listOf("asset-kept"),
            trashedRecord.getValue("assetIDs").jsonObject.getValue("value").jsonArray.map { it.jsonPrimitive.content },
        )
        assertEquals(listOf("res-kept", "res-kept-preview"), trashed.resourceIdsFor("asset-kept"))

        val conflict = fixtures.getValue("single-conflict")
        assertFalse(canonicalJson(conflict.expected).contains("first-loser-dropped"))

        val purged = fixtures.getValue("expired-purge-vs-old-base")
        assertEquals(listOf("rec-stays"), purged.recordIds())
        val purgedCanon = canonicalJson(purged.expected)
        assertFalse(purgedCanon.contains("rec-expired"))
        assertFalse(purgedCanon.contains("asset-expired"))

        val restored = fixtures.getValue("expired-purge-vs-offline-restore")
        assertEquals(listOf("rec-expired"), restored.recordIds())
        val restoredRecord = restored.expectedRecord()
        assertEquals("Restored offline", restoredRecord.getValue("title").jsonObject.getValue("value").jsonPrimitive.content)
        assertTrue(restoredRecord.getValue("tombstone").jsonObject.getValue("value").toString() == "null")
        assertEquals(listOf("res-expired"), restored.resourceIdsFor("asset-expired"))
    }

    @Test
    fun failClosedFixturesHaltInBothOrders() {
        val root = fixtureRoot("tied-addition-stamps")
        assertEquals("fail-closed", root.getValue("kind").jsonPrimitive.content)
        val base = ArchiveJson.parseSnapshot(root.getValue("base").jsonObject)
        val local = ArchiveJson.parseSnapshot(root.getValue("local").jsonObject)
        val remote = ArchiveJson.parseSnapshot(root.getValue("remote").jsonObject)
        assertFailsClosed { ArchiveMerge.merge(base, local, remote) }
        assertFailsClosed { ArchiveMerge.merge(base, remote, local) }
    }

    @Test
    fun aWrongSequenceOrParentDoesNotAdvanceTheCursor() {
        val chain = recordChain()
        val cursor = VerifiedCursor(4, "hash-4")
        val wrongSequence = ArchiveSync.advanceOne(
            chain.alive,
            chain.alive,
            cursor,
            CommitFetch.Found(7, chain.trashed, "hash-7", parentHash = "hash-4"),
        ) as WalkStep.Halted
        assertEquals(4L, wrongSequence.verifiedThrough.sequence)
        assertEquals("hash-4", wrongSequence.verifiedThrough.commitHash)
        assertTrue(wrongSequence.message.contains("does not follow"))
        assertEquals(ArchiveJson.canonical(chain.alive), ArchiveJson.canonical(wrongSequence.pending))

        val wrongParent = ArchiveSync.advanceOne(
            chain.alive,
            chain.alive,
            cursor,
            CommitFetch.Found(5, chain.trashed, "hash-5", parentHash = "hash-other"),
        ) as WalkStep.Halted
        assertEquals(4L, wrongParent.verifiedThrough.sequence)
        assertEquals("hash-4", wrongParent.verifiedThrough.commitHash)
        assertTrue(wrongParent.message.contains("parent"))
        assertEquals(ArchiveJson.canonical(chain.alive), ArchiveJson.canonical(wrongParent.pending))
    }

    @Test
    fun theCursorStaysWhenMergeThrows() {
        val chain = recordChain()
        val cursor = VerifiedCursor(4, "hash-4")
        val halted = ArchiveSync.advanceOne(
            chain.alive,
            chain.alive,
            cursor,
            CommitFetch.Found(5, chain.purged, "hash-5", parentHash = "hash-4"),
        ) as WalkStep.Halted
        assertEquals(cursor, halted.verifiedThrough)
        assertTrue(halted.message.contains("Merge failed"))
        assertTrue(halted.message.contains("change"))
        assertEquals(ArchiveJson.canonical(chain.alive), ArchiveJson.canonical(halted.pending))
        assertEquals(1, halted.pending.records.size)
    }

    @Test
    fun twoFieldEditsOnOneRecordCountAsOneChange() {
        val chain = recordChain()
        val record = chain.alive.records.single()
        val stamp = EditStamp(4, 1700000004000, "device-iphone")
        val pending = chain.alive.copy(
            records = listOf(
                record.copy(
                    title = requireNotNull(record.title).copy(value = JsonPrimitive("Renamed"), edit = stamp),
                    note = record.note.copy(value = JsonPrimitive("Also edited"), edit = stamp),
                ),
            ),
        )
        val halted = ArchiveSync.advanceOne(
            chain.alive,
            pending,
            VerifiedCursor(4, "hash-4"),
            CommitFetch.NotFound,
        ) as WalkStep.Halted
        assertEquals(1, halted.unsyncedEdits)
        assertEquals("1 change not yet synced. commit 5 is missing from the chain.", halted.message)
    }

    @Test
    fun nonIntegerNumbersAreRejectedAtParse() {
        val root = fixtureRoot("non-integer-rejected")
        assertEquals("parse-error", root.getValue("kind").jsonPrimitive.content)
        assertFailsClosed { ArchiveJson.parseSnapshot(root.getValue("document").jsonObject) }
    }

    @Test
    fun anOffsetIsNotStoredAsAnIanaTimeZone() {
        val root = fixtureRoot("capture-offset-rejected")
        assertEquals("parse-error", root.getValue("kind").jsonPrimitive.content)
        assertFailsClosed { ArchiveJson.parseSnapshot(root.getValue("document").jsonObject) }
    }

    @Test
    fun purgeWindowIsThirtyDaysOfMilliseconds() {
        assertEquals(2_592_000_000L, PURGE_WINDOW_MILLIS)
        assertEquals(86_400_000L * 30, PURGE_WINDOW_MILLIS)
        val tappedAt = 1_700_000_003_000L
        val envelope = ArchiveEdits.tombstone(tappedAt, EditStamp(2, tappedAt, "device-iphone"))
        val value = envelope.value.jsonObject
        assertEquals(tappedAt, value.getValue("deletedAt").jsonPrimitive.content.toLong())
        assertFalse(value.containsKey("purgeAfter"))
        assertFalse(value.containsKey("firstPublishedAt"))
        val publishedAt = tappedAt + 40L * 86_400_000L
        val stamped = applyPublishClock(envelope, publishedAt).value.jsonObject
        assertEquals(publishedAt, stamped.getValue("firstPublishedAt").jsonPrimitive.content.toLong())
        assertEquals(publishedAt + PURGE_WINDOW_MILLIS, stamped.getValue("purgeAfter").jsonPrimitive.content.toLong())
        assertEquals(tappedAt, stamped.getValue("deletedAt").jsonPrimitive.content.toLong())
    }
}

class MergeEdgeTest {
    @Test
    fun equalEditTupleWithDifferentValuesFailsClosed() {
        val fixture = loadFixtures().first { it.id == "different-fields" }
        val local = fixture.base.withTitle("Blue", counter = 2, at = 50, deviceId = "device-iphone")
        val remote = fixture.base.withTitle("Green", counter = 2, at = 50, deviceId = "device-iphone")
        assertFailsClosed { ArchiveMerge.merge(fixture.base, local, remote) }
        assertFailsClosed { ArchiveMerge.merge(fixture.base, remote, local) }
    }

    @Test
    fun removingAnUnknownFieldWhileTheOtherSideEditsItKeepsDeletedConflict() {
        val fixture = loadFixtures().first { it.id == "different-fields" }
        val stamp = EditStamp(1, 10, "device-iphone")
        val base = fixture.base.withUnknown("futureScore", FieldEnvelope(kotlinx.serialization.json.JsonPrimitive("base"), stamp))
        val local = fixture.base.withUnknown(
            "futureScore",
            FieldEnvelope(kotlinx.serialization.json.JsonPrimitive("changed"), EditStamp(2, 20, "device-iphone")),
        )
        val remote = fixture.base
        val merged = ArchiveMerge.merge(base, local, remote)
        val swapped = ArchiveMerge.merge(base, remote, local)
        assertEquals(ArchiveJson.canonical(merged), ArchiveJson.canonical(swapped))
        val conflict = merged.records.single().unknownFields.getValue("futureScore").conflict
        assertEquals("""{"deleted":true}""", conflict?.let { canonicalJson(it) })
    }

    @Test
    fun manualSaveRejectsMediaOutsideOneToThirtyButMergeResultCanBeStoredInTheModel() {
        val overflow = loadFixtures().first { it.id == "media-overflow" }
        val merged = ArchiveMerge.merge(overflow.base, overflow.local, overflow.remote)
        val record = merged.records.single()
        assertEquals(31, jsonStringList(record.assetIds.value).size)
        assertTrue(record.mediaOverflow == true)
        assertFailsValidation { ArchiveEdits.upsertManualRecord(merged, record) }
    }

    @Test
    fun identicalMediaEnvelopesWithTheSameStampAreKept() {
        val fixture = loadFixtures().first { it.id == "different-fields" }
        val stamp = EditStamp(2, 50, "device-shared")
        val ids = kotlinx.serialization.json.JsonArray(
            listOf(
                kotlinx.serialization.json.JsonPrimitive("asset-a"),
                kotlinx.serialization.json.JsonPrimitive("asset-b"),
            ),
        )
        fun withAddition(snapshot: ArchiveSnapshot): ArchiveSnapshot {
            val asset = snapshot.assets.single()
            val resource = snapshot.resources.single()
            return snapshot.copy(
                records = listOf(snapshot.records.single().copy(assetIds = FieldEnvelope(ids, stamp))),
                assets = listOf(asset, asset.copy(id = "asset-b", resourceIds = listOf("res-b"))),
                resources = listOf(resource, resource.copy(id = "res-b", assetID = "asset-b")),
            )
        }
        val merged = ArchiveMerge.merge(fixture.base, withAddition(fixture.base), withAddition(fixture.base))
        assertEquals(listOf("asset-a", "asset-b"), jsonStringList(merged.records.single().assetIds.value))
        assertEquals(stamp, merged.records.single().assetIds.edit)
    }

    @Test
    fun mergeDoesNotDropAnExpiredTombstone() {
        val fixture = loadFixtures().first { it.id == "different-fields" }
        val expired = ArchiveEdits.tombstone(1L, EditStamp(2, 1L, "device-iphone"))
        fun trashed(snapshot: ArchiveSnapshot) = snapshot.copy(
            records = listOf(snapshot.records.single().copy(tombstone = expired)),
        )
        val merged = ArchiveMerge.merge(trashed(fixture.base), trashed(fixture.local), trashed(fixture.remote))
        assertEquals(listOf("rec-1"), merged.records.map { it.id })
    }

    @Test
    fun rebuildKeepsUnknownEnvelopeKeysFromTheWinner() {
        val fixture = loadFixtures().first { it.id == "different-fields" }
        val extra = mapOf("hint" to kotlinx.serialization.json.JsonPrimitive("keep"))
        val local = fixture.base.withTitle("Blue", counter = 2, at = 20, deviceId = "device-iphone")
        val remote = fixture.base.withTitle("Green", counter = 2, at = 30, deviceId = "device-oppo", extra = extra)
        val merged = ArchiveMerge.merge(fixture.base, local, remote)
        val swapped = ArchiveMerge.merge(fixture.base, remote, local)
        assertEquals(ArchiveJson.canonical(merged), ArchiveJson.canonical(swapped))
        val title = requireNotNull(merged.records.single().title)
        assertEquals("Green", title.value.jsonPrimitive.content)
        assertEquals("keep", title.extra.getValue("hint").jsonPrimitive.content)
        assertEquals("Blue", title.conflict!!.getValue("value").jsonPrimitive.content)
    }

}

class ArchiveParseTest {
    @Test
    fun rejectsAStringWhereAnIntegerIsRequired() {
        val text = baseText().replaceFirst("\"counter\":1", "\"counter\":\"2\"")
        assertFailsClosed { ArchiveJson.parseSnapshot(text) }
    }

    @Test
    fun rejectsDuplicateRecordIds() {
        val root = Json.parseToJsonElement(baseText()).jsonObject
        val records = root.getValue("records").jsonArray
        val doubled = JsonObject(root.toMutableMap().apply {
            this["records"] = kotlinx.serialization.json.JsonArray(records + records)
        })
        assertFailsClosed { ArchiveJson.parseSnapshot(doubled) }
    }

    @Test
    fun rejectsUppercaseSha256() {
        val text = baseText().replace(
            "769b206a3f59eae2ed7455e4a9269121ce20f26534c06e32f9fa6085c7274a63",
            "769B206a3f59eae2ed7455e4a9269121ce20f26534c06e32f9fa6085c7274a63",
        )
        assertFailsClosed { ArchiveJson.parseSnapshot(text) }
    }

    @Test
    fun rejectsExponentNumberLiteralsAndIntegersPastTheSafeRange() {
        assertFailsClosed {
            ArchiveJson.parseSnapshot(baseText().replaceFirst("\"byteCount\":1007", "\"byteCount\":1e3"))
        }
        assertFailsClosed {
            ArchiveJson.parseSnapshot(
                baseText().replaceFirst("\"byteCount\":1007", "\"byteCount\":9007199254740992"),
            )
        }
        assertFailsClosed {
            ArchiveJson.parseSnapshot(baseText().replaceFirst("\"byteCount\":1007", "\"byteCount\":-0"))
        }
    }

    @Test
    fun rejectsCaptureTimeThatIsMissingUtc() {
        val text = baseText().replaceFirst("\"utc\":1700000000000", "\"notUtc\":1700000000000")
        assertFailsClosed { ArchiveJson.parseSnapshot(text) }
    }

    private fun baseText(): String = canonicalJson(fixtureRoot("different-fields").getValue("base"))
}

private data class FixtureFile(
    val id: String,
    val requireSymmetry: Boolean,
    val base: ArchiveSnapshot,
    val local: ArchiveSnapshot,
    val remote: ArchiveSnapshot,
    val expected: JsonObject,
    val expectedOrder: TimelineOrder,
) {
    fun expectedRecord(): JsonObject = expected.getValue("records").jsonArray.first().jsonObject

    fun recordIds(): List<String> =
        expected.getValue("records").jsonArray.map { it.jsonObject.getValue("id").jsonPrimitive.content }

    fun resourceIdsFor(assetId: String): List<String> {
        val asset = expected.getValue("assets").jsonArray
            .map { it.jsonObject }
            .first { it.getValue("id").jsonPrimitive.content == assetId }
        return asset.getValue("resourceIDs").jsonArray.map { it.jsonPrimitive.content }
    }
}

private val REQUIRED_IDS = setOf(
    "clock-skew",
    "different-fields",
    "expired-purge-vs-offline-restore",
    "expired-purge-vs-old-base",
    "media-add-delete-reorder",
    "media-overflow",
    "note-only-record",
    "motion-stills",
    "possible-duplicate",
    "same-field",
    "single-conflict",
    "time-zone-and-unknown-time",
    "tombstone-vs-edit",
    "trash-and-edit",
    "trashed-record-keeps-media",
    "unknown-fields",
    "conflict-marker-survives",
    "media-one-side-keeps-conflict",
    "own-commit-seen-as-remote",
    "conflict-added-same-stamp",
    "conflict-resolved-one-side",
    "unknown-key-named-at",
    "known-field-omitted-deleted",
    "capture-time-forms",
    "first-publish-kept-across-merge",
    "concurrent-first-publish-earliest",
    "redelete-keeps-new-generation",
    "redelete-keeps-new-published-clock",
    "old-purge-keeps-new-generation",
    "restore-keeps-generation-on-null",
    "concurrent-new-generation-earliest",
)

private val AUXILIARY_IDS = setOf(
    "tied-addition-stamps",
    "non-integer-rejected",
    "capture-offset-rejected",
    "purge-offline-delete-counts-from-publish",
    "purge-at-first-publish-boundary",
    "purge-before-first-publish-boundary",
    "lost-deletion-generation",
    "invalid-deletion-generation",
    "purge-redelete-counts-from-new-publish",
    "purge-old-generation-is-not-proof",
    "purge-new-generation-boundary",
)

private fun loadFixtures(): List<FixtureFile> {
    val directory = mergeFixtureDirectory()
    val files = directory.listFiles { file -> file.extension == "json" }?.sortedBy { it.name }
        ?: error("no fixtures in $directory")
    val fixtures = files.mapNotNull { file ->
        val root = Json.parseToJsonElement(file.readText()).jsonObject
        val id = root.getValue("id").jsonPrimitive.content
        check(id == file.nameWithoutExtension) { id }
        val kind = root["kind"]?.jsonPrimitive?.content ?: "merge"
        if (kind != "merge") {
            check(id in AUXILIARY_IDS) { id }
            return@mapNotNull null
        }
        FixtureFile(
            id = id,
            requireSymmetry = root.getValue("requireSymmetry").jsonPrimitive.boolean,
            base = ArchiveJson.parseSnapshot(root.getValue("base").jsonObject),
            local = ArchiveJson.parseSnapshot(root.getValue("local").jsonObject),
            remote = ArchiveJson.parseSnapshot(root.getValue("remote").jsonObject),
            expected = root.getValue("expected").jsonObject,
            expectedOrder = TimelineOrder(
                records = root.getValue("expectedOrder").jsonObject.getValue("records").jsonArray
                    .map { it.jsonPrimitive.content },
                assets = root.getValue("expectedOrder").jsonObject.getValue("assets").jsonArray
                    .map { it.jsonPrimitive.content },
            ),
        )
    }
    val ids = fixtures.map { it.id }.toSet()
    check(ids == REQUIRED_IDS) { "fixture catalog mismatch: ${ids.symmetricDifference(REQUIRED_IDS)}" }
    val auxiliary = files.map { it.nameWithoutExtension }.filter { it !in ids }.toSet()
    check(auxiliary == AUXILIARY_IDS) { "auxiliary fixture mismatch: ${auxiliary.symmetricDifference(AUXILIARY_IDS)}" }
    return fixtures
}

private fun fixtureRoot(id: String): JsonObject {
    val file = File(mergeFixtureDirectory(), "$id.json")
    return Json.parseToJsonElement(file.readText()).jsonObject
}

private fun mergeFixtureDirectory(): File {
    var directory = File(checkNotNull(System.getProperty("user.dir")))
    repeat(8) {
        val candidate = File(directory, "android-app/app/src/test/resources/archive")
        if (candidate.isDirectory) return candidate
        directory = directory.parentFile ?: return@repeat
    }
    error("android-app/app/src/test/resources/archive not found from ${System.getProperty("user.dir")}")
}

private fun Set<String>.symmetricDifference(other: Set<String>): Set<String> = (this - other) + (other - this)

private fun assertCanonicalEqual(label: String, actual: JsonObject, expected: JsonObject) {
    val actualText = canonicalJson(actual)
    val expectedText = canonicalJson(expected)
    if (actualText == expectedText) return
    val index = actualText.indices.firstOrNull { it >= expectedText.length || actualText[it] != expectedText[it] }
        ?: actualText.length
    val start = (index - 120).coerceAtLeast(0)
    val endActual = (index + 180).coerceAtMost(actualText.length)
    val endExpected = (index + 180).coerceAtMost(expectedText.length)
    throw AssertionError(
        "$label mismatch at $index\nactual  ${actualText.substring(start, endActual)}\nexpected ${expectedText.substring(start, endExpected)}",
    )
}

private fun ArchiveSnapshot.withTitle(
    value: String,
    counter: Long,
    at: Long,
    deviceId: String,
    extra: Map<String, kotlinx.serialization.json.JsonElement> = emptyMap(),
): ArchiveSnapshot {
    val record = records.single()
    return copy(
        records = listOf(
            record.copy(
                title = requireNotNull(record.title).copy(
                    value = kotlinx.serialization.json.JsonPrimitive(value),
                    edit = EditStamp(counter, at, deviceId),
                    conflict = null,
                    extra = extra,
                ),
            ),
        ),
    )
}

private fun ArchiveSnapshot.withUnknown(key: String, envelope: FieldEnvelope): ArchiveSnapshot {
    val record = records.single()
    return copy(records = listOf(record.copy(unknownFields = mapOf(key to envelope))))
}

private data class RecordChain(val alive: ArchiveSnapshot, val trashed: ArchiveSnapshot, val purged: ArchiveSnapshot)
private fun recordChain(): RecordChain {
    val fixture = loadFixtures().first { it.id == "unknown-fields" }
    val alive = fixture.base
    val record = alive.records.single()
    val trashed = alive.copy(records = listOf(record.copy(tombstone = ArchiveEdits.tombstone(100, EditStamp(2, 100, "phone")))))
    return RecordChain(alive, trashed, ArchiveSnapshot.empty())
}

private fun assertFailsClosed(block: () -> Unit) {
    try {
        block()
    } catch (error: ArchiveProtocolException) {
        return
    }
    throw AssertionError("expected ArchiveProtocolException")
}

private fun assertFailsValidation(block: () -> Unit) {
    try {
        block()
    } catch (error: ArchiveValidationException) {
        return
    }
    throw AssertionError("expected ArchiveValidationException")
}
