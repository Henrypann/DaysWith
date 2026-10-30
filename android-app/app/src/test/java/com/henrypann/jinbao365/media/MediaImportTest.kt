package com.henrypann.jinbao365.media

import com.henrypann.jinbao365.archive.ArchiveJson
import com.henrypann.jinbao365.archive.ArchiveRecord
import com.henrypann.jinbao365.archive.ArchiveSnapshot
import com.henrypann.jinbao365.archive.FieldEnvelope
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.nio.file.Files
import java.time.Instant

class MediaImportTest {
    @Test
    fun hashingReadsAFixedBufferAndNeverTheWholeStream() {
        val total = ContentHash.BUFFER_SIZE * 3 + 100
        val stream = ChunkLimitedStream(total) { 'a'.code.toByte() }
        val digest = ContentHash.sha256(stream)
        assertEquals(total.toLong(), digest.byteCount)
        assertTrue(stream.maxRequested <= ContentHash.BUFFER_SIZE)
        assertFalse(stream.singleByteRead)
        assertEquals(sha256(ByteArray(total) { 'a'.code.toByte() }), digest.hex)
    }

    @Test
    fun aMotionMarkerSplitAcrossChunksIsAMotionPhotoOnlyWithARealVideo() {
        val video = ftyp(32)
        val packet = xmpMotion(video.size)
        val splitAt = ContentHash.BUFFER_SIZE - 6
        val head = ByteArray(splitAt) { 'J'.code.toByte() }
        val bytes = head + packet.toByteArray(Charsets.ISO_8859_1) + video
        val stream = ChunkLimitedStream(bytes.size) { index -> bytes[index] }
        val file = File.createTempFile("motion", ".bin")
        try {
            val copied = MotionPhotoScanner.copyHashAndScan(stream, file)
            assertTrue(copied.motionPhoto)
            assertEquals(bytes.size.toLong(), copied.byteCount)
            assertEquals(sha256(bytes), copied.sha256)
            assertArrayEquals(bytes, file.readBytes())
            assertTrue(stream.maxRequested <= ContentHash.BUFFER_SIZE)
        } finally {
            file.delete()
        }
    }

    @Test
    fun aMotionMarkerWithoutAVideoContainerIsNotAMotionPhoto() {
        val packet = "<x:xmpmeta MotionPhoto=\"1\"></x:xmpmeta>".toByteArray(Charsets.ISO_8859_1)
        val trailer = "not-a-video".toByteArray(Charsets.ISO_8859_1)
        val bytes = packet + trailer
        val file = File.createTempFile("marker", ".bin")
        try {
            val copied = MotionPhotoScanner.copyHashAndScan(ByteArrayInputStream(bytes), file)
            assertFalse(copied.motionPhoto)
        } finally {
            file.delete()
        }
    }

    @Test
    fun legacyMicroVideoOffsetCountsFromTheEndAndMustBeAVideo() {
        val video = ftyp(24)
        val packet = "<x:xmpmeta GCamera:MicroVideo=\"1\" GCamera:MicroVideoOffset=\"${video.size}\"/>"
        val bytes = packet.toByteArray(Charsets.ISO_8859_1) + video
        val file = File.createTempFile("micro", ".bin")
        try {
            assertTrue(MotionPhotoScanner.copyHashAndScan(ByteArrayInputStream(bytes), file).motionPhoto)
        } finally {
            file.delete()
        }
        val lying = "<x:xmpmeta MicroVideo=\"1\" MicroVideoOffset=\"8\"/>notvideo".toByteArray()
        val bad = File.createTempFile("micro-bad", ".bin")
        try {
            assertFalse(MotionPhotoScanner.copyHashAndScan(ByteArrayInputStream(lying), bad).motionPhoto)
        } finally {
            bad.delete()
        }
    }

    @Test
    fun locationPolicyPrefersAvailableOriginalAndOtherwiseUsesSelectedBytes() {
        assertEquals(ByteSource.GivenFile, LocationPolicy.select(ImportChoice(true, false, false)))
        assertEquals(ByteSource.MediaStoreOriginal, LocationPolicy.select(ImportChoice(true, true, true)))
        assertEquals(ByteSource.GivenFile, LocationPolicy.select(ImportChoice(false, true, true)))
        assertEquals(ByteSource.GivenFile, LocationPolicy.select(ImportChoice(true, true, false)))
    }

    @Test
    fun captureTimeStoresAnOffsetAndKeepsSubseconds() {
        val known = CaptureTime.fromExif("2024:06:01 12:00:00", "+0800", "12")
        assertEquals(false, known.getValue("timeUnknown").jsonPrimitive.boolean)
        assertFalse("timeZone" in known)
        assertEquals("+08:00", known.getValue("utcOffset").jsonPrimitive.content)
        assertEquals(1717214400120L, known.getValue("utc").jsonPrimitive.long)
        assertEquals(1717214400100L, CaptureTime.fromExif("2024:06:01 12:00:00", "+08:00", "1").getValue("utc").jsonPrimitive.long)
        assertEquals(1717214400123L, CaptureTime.fromExif("2024:06:01 12:00:00", "+08:00", "1234").getValue("utc").jsonPrimitive.long)
        assertTrue(CaptureTime.fromExif("2024:06:01 12:00:00", null).getValue("timeUnknown").jsonPrimitive.boolean)
        assertFalse("utc" in CaptureTime.fromExif(null, "+08:00"))
    }

    @Test
    fun zeroWallClocksAreUnknownEvenWhenAnOffsetIsPresent() {
        assertTrue(CaptureTime.fromExif("1904:01:01 00:00:00", "+08:00").getValue("timeUnknown").jsonPrimitive.boolean)
        assertTrue(CaptureTime.fromExif("1970:01:01 00:00:00", "Z").getValue("timeUnknown").jsonPrimitive.boolean)
        assertFalse("utc" in CaptureTime.fromExif("1904:01:01 00:00:00", "+08:00"))
        assertTrue(CaptureTime.fromVideoMetadata("19040101T000000.000Z").getValue("timeUnknown").jsonPrimitive.boolean)
        assertTrue(CaptureTime.fromVideoMetadata("19700101T000000Z").getValue("timeUnknown").jsonPrimitive.boolean)
    }

    @Test
    fun aVideoDateEndingInZDoesNotClaimTheZoneIsZ() {
        val zulu = CaptureTime.fromVideoMetadata("20240601T120000.500Z")
        assertEquals(false, zulu.getValue("timeUnknown").jsonPrimitive.boolean)
        assertEquals(true, zulu.getValue("zoneUnknown").jsonPrimitive.boolean)
        assertFalse("timeZone" in zulu)
        assertFalse("utcOffset" in zulu)
        assertEquals(1717243200500L, zulu.getValue("utc").jsonPrimitive.long)
        val offset = CaptureTime.fromVideoMetadata("20240601T120000.000+0800")
        assertEquals("+08:00", offset.getValue("utcOffset").jsonPrimitive.content)
        assertEquals(1717214400000L, offset.getValue("utc").jsonPrimitive.long)
        assertTrue(CaptureTime.fromVideoMetadata("20240601T120000").getValue("timeUnknown").jsonPrimitive.boolean)
    }

    @Test
    fun anUnknownCaptureIsAnEstimateInTheRecordAndAKnownOffsetIsCopied() {
        val unknown = CaptureTime.occurredAt(CaptureTime.unknown(), 1_700_000_000_000L)
        assertEquals(1_700_000_000_000L, unknown.getValue("utc").jsonPrimitive.long)
        assertEquals(true, unknown.getValue("zoneUnknown").jsonPrimitive.boolean)
        assertEquals(true, unknown.getValue("estimated").jsonPrimitive.boolean)
        assertFalse("timeZone" in unknown)
        val known = CaptureTime.fromExif("2024:06:01 12:00:00", "+08:00")
        val occurred = CaptureTime.occurredAt(known, known.getValue("utc").jsonPrimitive.long)
        assertEquals(known.getValue("utc").jsonPrimitive.long, occurred.getValue("utc").jsonPrimitive.long)
        assertEquals("+08:00", occurred.getValue("utcOffset").jsonPrimitive.content)
        assertFalse("estimated" in occurred)
    }

    @Test
    fun aPickerUriWithAMediaIdPointsAtTheExternalOriginal() {
        val picker = "content://media/picker/0/com.android.providers.media.photopicker/media/42"
        assertEquals("content://media/external/images/media/42", PickerOriginals.mediaStoreUri(picker, video = false))
        assertEquals("content://media/external/video/media/42", PickerOriginals.mediaStoreUri(picker, video = true))
        assertNull(PickerOriginals.mediaStoreUri("content://media/picker/item/not-a-number", video = false))
        assertNull(PickerOriginals.mediaStoreUri("content://example/42", video = false))
    }

    @Test
    fun anOriginalFileKeepsEveryByteAndADistinctStillPreview() {
        val root = tempRoot()
        val source = "plain-photo-without-gps".toByteArray()
        val prepared = importer(root, location = false, capture = CaptureTime.unknown()).import(
            request(source, fromPhotoPicker = false, mime = "image/jpeg"),
        )
        val stored = File(root, prepared.original.objectKey)
        assertArrayEquals(source, stored.readBytes())
        assertEquals(listOf(stored, prepared.previewFile).toSet(), prepared.createdFiles.toSet())
        val snapshot = snapshotWithImport(ArchiveSnapshot.empty(), "device-android", 1_700_000_000_000L, prepared)
        ArchiveJson.encodeSnapshot(snapshot)
        val occurred = snapshot.records.single().occurredAt.value.jsonObject
        assertEquals(1_700_000_000_000L, occurred.getValue("utc").jsonPrimitive.long)
        assertEquals(true, occurred.getValue("estimated").jsonPrimitive.boolean)
        assertEquals(true, occurred.getValue("zoneUnknown").jsonPrimitive.boolean)
        assertEquals(false, snapshot.assets.single().hasLocation)
        assertSame(snapshot, snapshotWithImport(snapshot, "device-android", 1_700_000_000_000L, prepared))
        val again = importer(root, location = false, capture = CaptureTime.unknown()).import(
            request(source, fromPhotoPicker = false, mime = "image/jpeg"),
        )
        assertTrue(again.createdFiles.isEmpty())
        assertArrayEquals(source, stored.readBytes())
        root.deleteRecursively()
    }

    @Test
    fun aMotionPhotoIsOneAssetWithTheOriginalAndAStillPreview() {
        val root = tempRoot()
        val video = ftyp(32)
        val source = (xmpMotion(video.size) + "\n").toByteArray(Charsets.ISO_8859_1) + video
        val capture = CaptureTime.fromExif("2024:06:01 12:00:00", "+08:00")
        val prepared = importer(root, location = true, capture = capture).import(
            request(source, fromPhotoPicker = false, mime = "image/jpeg", name = "motion.jpg"),
        )
        assertEquals("motionPhoto", prepared.kind)
        assertEquals("motionPhoto", prepared.original.role)
        assertEquals("preview", prepared.preview.role)
        assertArrayEquals(source, File(root, prepared.original.objectKey).readBytes())
        assertTrue(prepared.locationInOriginal)
        assertEquals("+08:00", prepared.capturedAt.getValue("utcOffset").jsonPrimitive.content)
        val snapshot = snapshotWithImport(ArchiveSnapshot.empty(), "device-android",
            capture.getValue("utc").jsonPrimitive.long, prepared)
        ArchiveJson.encodeSnapshot(snapshot)
        val occurred = snapshot.records.single().occurredAt.value.jsonObject
        assertEquals(capture.getValue("utc").jsonPrimitive.long, occurred.getValue("utc").jsonPrimitive.long)
        assertEquals("+08:00", occurred.getValue("utcOffset").jsonPrimitive.content)
        assertEquals(true, snapshot.assets.single().hasLocation)
        root.deleteRecursively()
    }

    @Test
    fun singleSnapshotImportAppliesTheFloorAndInclusiveFutureLimitToRecordAndAsset() {
        val now = Instant.parse("2026-10-11T00:00:00Z").toEpochMilli()
        listOf(0L, 315_619_199_999L, 315_619_200_000L, now + 86_400_000L, now + 86_400_001L).forEach { utc ->
            val root = tempRoot()
            try {
                val capture = CaptureTime.offsetKnown(utc, "+08:00")
                val prepared = importer(root, location = false, capture = capture).import(
                    request("photo".toByteArray(), fromPhotoPicker = false, mime = "image/jpeg"),
                )
                val snapshot = snapshotWithImport(ArchiveSnapshot.empty(), "android", now, prepared)
                ArchiveJson.encodeSnapshot(snapshot)
                val occurred = snapshot.records.single().occurredAt.value.jsonObject
                if (utc == 315_619_200_000L || utc == now + 86_400_000L) {
                    assertEquals(capture, snapshot.assets.single().capturedAt.value)
                    assertEquals(utc, occurred.getValue("utc").jsonPrimitive.long)
                    assertFalse("estimated" in occurred)
                } else {
                    assertEquals(CaptureTime.unknown(), snapshot.assets.single().capturedAt.value)
                    assertEquals(now, occurred.getValue("utc").jsonPrimitive.long)
                    assertTrue(occurred.getValue("estimated").jsonPrimitive.boolean)
                }
            } finally {
                root.deleteRecursively()
            }
        }
    }

    @Test
    fun aMarkerWithoutAVideoIsStoredAsAPhoto() {
        val root = tempRoot()
        val source = "<x:xmpmeta MotionPhoto=\"1\"></x:xmpmeta>no-video".toByteArray()
        val prepared = importer(root, location = false, capture = CaptureTime.unknown()).import(
            request(source, fromPhotoPicker = false, mime = "image/jpeg"),
        )
        assertEquals("photo", prepared.kind)
        assertEquals("photo", prepared.original.role)
        root.deleteRecursively()
    }

    @Test
    fun aPickerOriginalThatWillNotOpenFallsBackToSelectedBytes() {
        val root = tempRoot()
        val imported = importer(root, location = true, capture = CaptureTime.unknown()).import(
            request("selected-bytes".toByteArray(), fromPhotoPicker = true, mime = "image/jpeg", originalOpens = false))
        assertArrayEquals("selected-bytes".toByteArray(), File(root, imported.original.objectKey).readBytes())
        assertEquals(com.henrypann.jinbao365.archive.ImportProvenance.SystemProvided, imported.provenance)
        root.deleteRecursively()
    }

    @Test
    fun pickerBytesCarrySystemProvidedProvenance() {
        val root = tempRoot()
        val imported = importer(root, location = true, capture = CaptureTime.unknown()).import(
            request("selected-bytes".toByteArray(), fromPhotoPicker = true, mime = "image/jpeg"))
        assertArrayEquals("selected-bytes".toByteArray(), File(root, imported.original.objectKey).readBytes())
        assertEquals(com.henrypann.jinbao365.archive.ImportProvenance.SystemProvided, imported.provenance)
        root.deleteRecursively()
    }

    @Test
    fun missingLocationPermissionStillSavesSelectedBytes() {
        val root = tempRoot()
        val imported = importer(root, location = true, capture = CaptureTime.unknown()).import(
            request("selected-bytes".toByteArray(), fromPhotoPicker = true, mime = "image/jpeg", permission = false))
        assertArrayEquals("selected-bytes".toByteArray(), File(root, imported.original.objectKey).readBytes())
        assertEquals(com.henrypann.jinbao365.archive.ImportProvenance.SystemProvided, imported.provenance)
        root.deleteRecursively()
    }

    @Test
    fun thePhotoPickerUsesOnlyTheRequiredOriginal() {
        val root = tempRoot()
        val picker = "stripped-by-picker".toByteArray()
        val original = "GPS-original-bytes".toByteArray()
        val prepared = importer(root, location = true, capture = CaptureTime.unknown()).import(
            request(picker, fromPhotoPicker = true, mime = "image/jpeg", original = original),
        )
        assertEquals(ByteSource.MediaStoreOriginal, prepared.byteSource)
        assertArrayEquals(original, File(root, prepared.original.objectKey).readBytes())
        assertTrue(prepared.locationInOriginal)
        root.deleteRecursively()
    }

    @Test
    fun anExistingObjectIsTrustedOnlyWhenItsHashMatches() {
        val root = tempRoot()
        val source = "hello-photo".toByteArray()
        val prepared = importer(root, location = false, capture = CaptureTime.unknown()).import(
            request(source, fromPhotoPicker = false, mime = "image/jpeg"),
        )
        val stored = File(root, prepared.original.objectKey)
        stored.writeBytes("not-the-bytes".toByteArray())
        val again = importer(root, location = false, capture = CaptureTime.unknown()).import(
            request(source, fromPhotoPicker = false, mime = "image/jpeg"),
        )
        assertArrayEquals(source, stored.readBytes())
        assertEquals(prepared.original.sha256, again.original.sha256)
        assertTrue(again.createdFiles.none { it == stored })
        assertTrue(root.walkTopDown().none { it.name.startsWith("tmp-") })
        root.deleteRecursively()
    }

    @Test
    fun aCopyErrorDeletesTheTempFile() {
        val root = tempRoot()
        val broken = object : InputStream() {
            override fun read(): Int = throw IOException("disk")
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int = throw IOException("disk")
        }
        try {
            importer(root, location = false, capture = CaptureTime.unknown()).import(
                ImportRequest(
                    displayName = "broken.jpg",
                    mimeType = "image/jpeg",
                    permissionGranted = true,
                    fromPhotoPicker = false,
                    openGiven = { broken },
                    openOriginal = null,
                ),
            )
            throw AssertionError("expected rejection")
        } catch (error: IOException) {
            assertEquals("disk", error.message)
        }
        assertTrue(root.walkTopDown().none { it.isFile })
        root.deleteRecursively()
    }

    @Test
    fun startupDeletesStaleTempFilesAndLeavesRealObjects() {
        val root = tempRoot()
        File(root, "tmp-stale").writeText("partial")
        val nested = File(root, "objects/ab")
        nested.mkdirs()
        File(nested, "tmp-place-stale").writeText("partial")
        File(root, "keep.jpg").writeText("keep")
        importer(root, location = false, capture = CaptureTime.unknown())
        assertFalse(File(root, "tmp-stale").exists())
        assertFalse(File(nested, "tmp-place-stale").exists())
        assertTrue(File(root, "keep.jpg").exists())
        root.deleteRecursively()
    }

    @Test
    fun aTrashedRecordCanBeImportedAgainAndALiveOneCannot() {
        val root = tempRoot()
        val source = "same-photo".toByteArray()
        val prepared = importer(root, location = true, capture = CaptureTime.unknown()).import(
            request(source, fromPhotoPicker = false, mime = "image/jpeg"),
        )
        val first = snapshotWithImport(ArchiveSnapshot.empty(), "device-android", 10L, prepared)
        val trashedRecord = first.records.single().copy(
            tombstone = FieldEnvelope(
                JsonObject(
                    mapOf(
                        "deletedAt" to JsonPrimitive(11L),
                        "purgeAfter" to JsonPrimitive(12L),
                    ),
                ),
                first.records.single().tombstone.edit,
            ),
        )
        val trashed = first.copy(records = listOf(trashedRecord))
        val again = snapshotWithImport(trashed, "device-android", 13L, prepared)
        assertEquals(2, again.records.size)
        assertEquals(1, again.assets.size)
        assertEquals(first.resources.size, again.resources.size)
        val live = again.records.single { it.tombstone.value is kotlinx.serialization.json.JsonNull }
        assertEquals("rec-${prepared.original.sha256.take(12)}-2", live.id)
        assertEquals(listOf(first.assets.single().id), assetIdList(live))
        ArchiveJson.encodeSnapshot(again)
        assertSame(again, snapshotWithImport(again, "device-android", 14L, prepared))
        root.deleteRecursively()
    }

    @Test
    fun aRejectedSaveDeletesOnlyFilesThisImportCreated() {
        val root = tempRoot()
        val prepared = importer(root, location = false, capture = CaptureTime.unknown()).import(
            request("new-bytes".toByteArray(), fromPhotoPicker = false, mime = "image/jpeg"),
        )
        assertTrue(prepared.createdFiles.all { it.isFile })
        prepared.discardNewFiles()
        assertTrue(prepared.createdFiles.all { !it.exists() })
        root.deleteRecursively()
    }

    @Test
    fun aVideoIsHashedAsAStreamAndIsNotTreatedAsAMotionPhoto() {
        val root = tempRoot()
        val marker = "MotionPhoto=\"1\"".toByteArray(Charsets.ISO_8859_1)
        val source = ByteArray(ContentHash.BUFFER_SIZE + 32) { index ->
            if (index < marker.size) marker[index] else 'v'.code.toByte()
        }
        val prepared = importer(root, location = false, capture = CaptureTime.unknown()).import(
            request(source, fromPhotoPicker = false, mime = "video/mp4"),
        )
        assertEquals("video", prepared.kind)
        assertEquals("video", prepared.original.role)
        assertEquals(sha256(source), prepared.original.sha256)
        assertEquals(source.size.toLong(), prepared.original.byteCount)
        root.deleteRecursively()
    }

    @Test
    fun requiredPhotoGateRequestsFullMediaAndOriginalAccess() {
        val sdk34 = MediaPermissions.toRequest(34)
        assertFalse(sdk34.contains(MediaPermissions.READ_MEDIA_VISUAL_USER_SELECTED))
        assertTrue(sdk34.contains(MediaPermissions.READ_MEDIA_IMAGES))
        assertTrue(sdk34.contains(MediaPermissions.ACCESS_MEDIA_LOCATION))
        assertFalse(MediaPermissions.toRequest(33).contains(MediaPermissions.READ_MEDIA_VISUAL_USER_SELECTED))
        assertEquals(listOf(MediaPermissions.ACCESS_MEDIA_LOCATION, MediaPermissions.READ_EXTERNAL_STORAGE), MediaPermissions.toRequest(32))
        val partial = setOf(MediaPermissions.ACCESS_MEDIA_LOCATION, MediaPermissions.READ_MEDIA_VISUAL_USER_SELECTED)
        assertFalse(MediaPermissions.canReadSelection(34) { it in partial })
        assertFalse(MediaPermissions.canReadSelection(34) { it == MediaPermissions.READ_MEDIA_IMAGES })
        assertTrue(
            MediaPermissions.canReadSelection(33) {
                it == MediaPermissions.READ_MEDIA_IMAGES || it == MediaPermissions.READ_MEDIA_VIDEO
            },
        )
    }

    @Test
    fun missingDeviceLocationDoesNotBlockPickerOrDocument() {
        listOf(true, false).forEach { fromPicker ->
            val root = Files.createTempDirectory("media-location").toFile()
            val source = request("photo".toByteArray(), fromPhotoPicker = fromPicker, mime = "image/jpeg")
                .copy(locationPermissionGranted = false)
            val result = importer(root, location = false, capture = CaptureTime.unknown()).import(source)
            assertArrayEquals("photo".toByteArray(), File(root, result.original.objectKey).readBytes())
            root.deleteRecursively()
        }
    }

    @Test
    fun requiredLocationGateAcceptsApproximateOrPrecisePermission() {
        assertFalse(MediaPermissions.canAccessLocation { false })
        assertTrue(MediaPermissions.canAccessLocation { it == MediaPermissions.ACCESS_COARSE_LOCATION })
        assertTrue(MediaPermissions.canAccessLocation { it == MediaPermissions.ACCESS_FINE_LOCATION })
        assertEquals(setOf(MediaPermissions.ACCESS_COARSE_LOCATION, MediaPermissions.ACCESS_FINE_LOCATION),
            MediaPermissions.locationToRequest().toSet())
        val fullMedia = MediaPermissions.toRequest(35).toSet()
        assertTrue(MediaPermissions.canReadOriginals(35) { it in fullMedia })
        assertFalse(MediaPermissions.canReadOriginals(35) { it in fullMedia && it != MediaPermissions.ACCESS_MEDIA_LOCATION })
    }

    @Test
    fun exifOrientationMapsToDegreesAndAFlip() {
        assertEquals(ExifOrientation.Transform(0, false), ExifOrientation.transform(ExifOrientation.NORMAL))
        assertEquals(ExifOrientation.Transform(0, true), ExifOrientation.transform(ExifOrientation.FLIP_HORIZONTAL))
        assertEquals(ExifOrientation.Transform(180, false), ExifOrientation.transform(ExifOrientation.ROTATE_180))
        assertEquals(ExifOrientation.Transform(180, true), ExifOrientation.transform(ExifOrientation.FLIP_VERTICAL))
        assertEquals(ExifOrientation.Transform(90, true), ExifOrientation.transform(ExifOrientation.TRANSPOSE))
        assertEquals(ExifOrientation.Transform(90, false), ExifOrientation.transform(ExifOrientation.ROTATE_90))
        assertEquals(ExifOrientation.Transform(270, true), ExifOrientation.transform(ExifOrientation.TRANSVERSE))
        assertEquals(ExifOrientation.Transform(270, false), ExifOrientation.transform(ExifOrientation.ROTATE_270))
    }

    @Test
    fun videoLocationUsesAnIso6709Pair() {
        assertTrue(VideoLocation.present("+31.2304+121.4737/"))
        assertTrue(VideoLocation.present("-33.8688+151.2093+25.000/"))
        assertFalse(VideoLocation.present(null))
        assertFalse(VideoLocation.present("   "))
        assertFalse(VideoLocation.present("no-gps"))
    }

    @Test
    fun theImportExecutorIsOneDaemonForTheProcess() {
        assertSame(ImportScheduler.executor, ImportScheduler.executor)
        assertFalse(ImportScheduler.executor.isShutdown)
    }

    private fun importer(root: File, location: Boolean, capture: JsonObject): MediaImporter {
        return MediaImporter(
            root = root,
            previewEncoder = PreviewEncoder { _, _ -> PREVIEW },
            hasLocation = { _, _ -> location },
            captureOf = { _, _ -> capture },
        )
    }

    private fun request(
        bytes: ByteArray,
        fromPhotoPicker: Boolean,
        mime: String,
        name: String = "import.jpg",
        permission: Boolean = true,
        original: ByteArray? = null,
        originalOpens: Boolean = true,
    ): ImportRequest {
        return ImportRequest(
            displayName = name,
            mimeType = mime,
            permissionGranted = permission,
            fromPhotoPicker = fromPhotoPicker,
            openGiven = { ByteArrayInputStream(bytes) },
            openOriginal = when {
                original != null -> {
                    { ByteArrayInputStream(original) }
                }
                !originalOpens -> {
                    { throw ImportRejected("The original file could not be opened.") }
                }
                else -> null
            },
        )
    }

    private fun assetIdList(record: ArchiveRecord): List<String> {
        val value = record.assetIds.value as kotlinx.serialization.json.JsonArray
        return value.map { it.jsonPrimitive.content }
    }

    private fun tempRoot(): File = File.createTempFile("media-import", "").apply {
        delete()
        mkdirs()
    }

    private fun assertRejected(message: String, body: () -> Unit) {
        try {
            body()
            throw AssertionError("expected rejection")
        } catch (error: ImportRejected) {
            assertEquals(message, error.message)
        }
    }

    private fun sha256(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return digest.joinToString("") { "%02x".format(it) }
    }

    private class ChunkLimitedStream(
        private val size: Int,
        private val byteAt: (Int) -> Byte,
    ) : InputStream() {
        private var index = 0
        var maxRequested = 0
        var singleByteRead = false

        override fun read(): Int {
            singleByteRead = true
            throw AssertionError("single-byte read")
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            if (index >= size) return -1
            if (length > ContentHash.BUFFER_SIZE) throw AssertionError("read of $length")
            maxRequested = maxOf(maxRequested, length)
            val count = minOf(length, size - index)
            for (i in 0 until count) buffer[offset + i] = byteAt(index + i)
            index += count
            return count
        }
    }

    private companion object {
        val PREVIEW = "JPEG-PREVIEW-NOT-THE-ORIGINAL".toByteArray()

        fun ftyp(size: Int): ByteArray {
            val bytes = ByteArray(size)
            bytes[3] = size.toByte()
            "ftypisom".toByteArray(Charsets.ISO_8859_1).copyInto(bytes, 4)
            return bytes
        }

        fun xmpMotion(videoLength: Int): String {
            return "<x:xmpmeta MotionPhoto=\"1\">" +
                "<Container:Item Mime=\"video/mp4\" Length=\"$videoLength\" Padding=\"0\"/>" +
                "</x:xmpmeta>"
        }
    }
}
