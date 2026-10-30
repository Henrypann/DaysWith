package com.henrypann.jinbao365.archive

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The 30-day window starts at firstPublishedAt, the first commit that stored the tombstone. */
class FirstPublishTest {
    @Test
    fun offlineDeletePublishedLateCountsFromPublishTime() {
        val root = readFixture("purge-offline-delete-counts-from-publish")
        val stampAt = root.getValue("stampAt").jsonPrimitive.content.toLong()
        val purged = runPurge(root)
        val record = purged.records.single()
        val tombstone = record.tombstone.value.jsonObject
        val deletedAt = tombstone.getValue("deletedAt").jsonPrimitive.content.toLong()
        assertTrue(stampAt > deletedAt + PURGE_WINDOW_MILLIS)
        assertEquals(stampAt, tombstone.getValue("firstPublishedAt").jsonPrimitive.content.toLong())
        assertEquals(stampAt + PURGE_WINDOW_MILLIS, tombstone.getValue("purgeAfter").jsonPrimitive.content.toLong())
        assertEquals(2L, record.tombstone.edit.counter)
        assertCanonical(root, purged)
    }

    @Test
    fun aLaterMergeKeepsTheOriginalFirstPublishTime() {
        val root = readFixture("first-publish-kept-across-merge")
        val merged = ArchiveMerge.merge(
            ArchiveJson.parseSnapshot(root.getValue("base").jsonObject),
            ArchiveJson.parseSnapshot(root.getValue("local").jsonObject),
            ArchiveJson.parseSnapshot(root.getValue("remote").jsonObject),
        )
        val swapped = ArchiveMerge.merge(
            ArchiveJson.parseSnapshot(root.getValue("base").jsonObject),
            ArchiveJson.parseSnapshot(root.getValue("remote").jsonObject),
            ArchiveJson.parseSnapshot(root.getValue("local").jsonObject),
        )
        val tombstone = merged.records.single().tombstone
        assertEquals(EARLY, tombstone.value.jsonObject.getValue("firstPublishedAt").jsonPrimitive.content.toLong())
        assertEquals(EARLY + PURGE_WINDOW_MILLIS, tombstone.value.jsonObject.getValue("purgeAfter").jsonPrimitive.content.toLong())
        assertEquals(TAP + 1, tombstone.value.jsonObject.getValue("deletedAt").jsonPrimitive.content.toLong())
        assertEquals(4L, tombstone.edit.counter)
        assertEquals("Renamed", requireNotNull(merged.records.single().title).value.jsonPrimitive.content)
        assertEquals(ArchiveJson.canonical(merged), ArchiveJson.canonical(swapped))
        assertEquals(ArchiveJson.canonical(merged), canonicalJson(root.getValue("expected").jsonObject))
    }

    @Test
    fun concurrentPublishesKeepTheEarliestFirstPublishTime() {
        val root = readFixture("concurrent-first-publish-earliest")
        val merged = ArchiveMerge.merge(
            ArchiveJson.parseSnapshot(root.getValue("base").jsonObject),
            ArchiveJson.parseSnapshot(root.getValue("local").jsonObject),
            ArchiveJson.parseSnapshot(root.getValue("remote").jsonObject),
        )
        val tombstone = merged.records.single().tombstone.value.jsonObject
        assertEquals(EARLY, tombstone.getValue("firstPublishedAt").jsonPrimitive.content.toLong())
        assertEquals(EARLY + PURGE_WINDOW_MILLIS, tombstone.getValue("purgeAfter").jsonPrimitive.content.toLong())
        assertEquals(TAP, tombstone.getValue("deletedAt").jsonPrimitive.content.toLong())
        assertEquals(5L, merged.records.single().tombstone.edit.counter)
        assertEquals(ArchiveJson.canonical(merged), canonicalJson(root.getValue("expected").jsonObject))
    }

    @Test
    fun purgeAtTheBoundaryOmitsAndOneMillisecondBeforeKeeps() {
        val at = runPurge(readFixture("purge-at-first-publish-boundary"))
        assertTrue(at.records.isEmpty())
        assertTrue(at.assets.isEmpty())
        assertTrue(at.resources.isEmpty())
        val before = runPurge(readFixture("purge-before-first-publish-boundary"))
        val tombstone = before.records.single().tombstone.value.jsonObject
        assertEquals(EARLY, tombstone.getValue("firstPublishedAt").jsonPrimitive.content.toLong())
        assertEquals(EARLY + PURGE_WINDOW_MILLIS, tombstone.getValue("purgeAfter").jsonPrimitive.content.toLong())
        assertCanonical(readFixture("purge-at-first-publish-boundary"), at)
        assertCanonical(readFixture("purge-before-first-publish-boundary"), before)
    }

    @Test
    fun aMismatchedPurgeAfterFailsClosed() {
        val text = canonicalJson(ArchiveJson.encodeSnapshot(publishedRecord(clock(EARLY))))
            .replace(
                (EARLY + PURGE_WINDOW_MILLIS).toString(),
                (EARLY + PURGE_WINDOW_MILLIS - 1).toString(),
            )
        try {
            ArchiveJson.parseSnapshot(text)
            throw AssertionError("expected ArchiveProtocolException")
        } catch (error: ArchiveProtocolException) {
            assertTrue(error.message!!.contains("purgeAfter"))
        }
    }

    @Test
    fun stampingAgainDoesNotMoveTheClockForward() {
        val published = publishedRecord(clock(EARLY))
        val pending = publishedRecord(clock(LATE))
        val again = ArchiveEdits.stampFirstPublish(pending, published, LATE + 1)
        val tombstone = again.records.single().tombstone.value.jsonObject
        assertEquals(EARLY, tombstone.getValue("firstPublishedAt").jsonPrimitive.content.toLong())
        assertEquals(EARLY + PURGE_WINDOW_MILLIS, tombstone.getValue("purgeAfter").jsonPrimitive.content.toLong())
    }

    private fun publishedRecord(tombstone: JsonElement?): ArchiveSnapshot {
        val stamp = EditStamp(1, TAP, "device-iphone")
        fun text(value: String) = FieldEnvelope(JsonPrimitive(value), stamp)
        val tomb = if (tombstone == null) {
            FieldEnvelope(JsonNull, stamp)
        } else {
            FieldEnvelope(tombstone, stamp)
        }
        return ArchiveSnapshot(
            records = listOf(
                ArchiveRecord(
                    id = "rec-1",
                    title = text("Coat day"),
                    note = text("Base note"),
                    occurredAt = FieldEnvelope(
                        JsonObject(mapOf("utc" to JsonPrimitive(TAP), "timeZone" to JsonPrimitive("Asia/Shanghai"))),
                        stamp,
                    ),
                    createdAt = FieldEnvelope(JsonPrimitive(TAP), stamp),
                    assetIds = FieldEnvelope(JsonArray(listOf(JsonPrimitive("asset-a"))), stamp),


                    tombstone = tomb,
                    extensions = emptyMap(),
                ),
            ),

            assets = listOf(
                MediaAsset(
                    id = "asset-a",
                    kind = "photo",
                    capturedAt = FieldEnvelope(JsonObject(mapOf("timeUnknown" to JsonPrimitive(true))), stamp),
                    resourceIds = listOf("res-a"),
                    extensions = emptyMap(),
                ),
            ),
            resources = listOf(
                MediaResource(
                    id = "res-a",
                    assetID = "asset-a",
                    role = "photo",
                    contentType = "image/jpeg",
                    originalFilename = "a.jpg",
                    byteCount = 1,
                    sha256 = SHA,
                    objectKey = "objects/aa/$SHA",
                    extensions = emptyMap(),
                ),
            ),
            extensions = emptyMap(),
        )
    }

    private fun clock(publishedAt: Long, deletedAt: Long = TAP): JsonObject = JsonObject(
        mapOf(
            "deletedAt" to JsonPrimitive(deletedAt),
            "firstPublishedAt" to JsonPrimitive(publishedAt),
            "purgeAfter" to JsonPrimitive(publishedAt + PURGE_WINDOW_MILLIS),
        ),
    )

    private fun runPurge(root: JsonObject): ArchiveSnapshot {
        val published = ArchiveJson.parseSnapshot(root.getValue("published").jsonObject)
        var snapshot = ArchiveJson.parseSnapshot(root.getValue("snapshot").jsonObject)
        val stampAt = root["stampAt"]?.jsonPrimitive?.content?.toLong()
        if (stampAt != null) snapshot = ArchiveEdits.stampFirstPublish(snapshot, published, stampAt)
        return ArchiveEdits.purgeExpired(snapshot, root.getValue("now").jsonPrimitive.content.toLong(), published)
    }

    private fun assertCanonical(root: JsonObject, actual: ArchiveSnapshot) {
        assertEquals(canonicalJson(root.getValue("expected").jsonObject), ArchiveJson.canonical(actual))
    }

    private fun readFixture(id: String): JsonObject {
        return Json.parseToJsonElement(File(fixtureDirectory(), "$id.json").readText()).jsonObject
    }

    private fun fixtureDirectory(): File {
        var directory = File(checkNotNull(System.getProperty("user.dir")))
        repeat(8) {
            val candidate = File(directory, "android-app/app/src/test/resources/archive")
            if (candidate.isDirectory) return candidate
            directory = directory.parentFile ?: return@repeat
        }
        error("android-app/app/src/test/resources/archive not found")
    }

    private companion object {
        const val TAP = 1_700_000_000_000L
        val EARLY = TAP + 40L * 86_400_000L
        val LATE = EARLY + 5L * 86_400_000L
        val SHA = "a".repeat(64)
    }
}
