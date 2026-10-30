package com.henrypann.jinbao365.backup

import com.henrypann.jinbao365.storage.StorageConfiguration
import java.lang.reflect.Proxy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class V1ValidatorTest {
    private val prefix = "life/v1/android/"
    private val writer = id(900)
    private val momentID = id(1)
    private val assetID = id(3)

    @Test fun emptyArchiveAndFullyLinkedArchiveAreValid() {
        validate(V1Manifest(moments = emptyList(),  assets = emptyList(), resources = emptyList()))
        validate(valid())
    }

    @Test fun oldSnapshotsRetainEveryRecordOriginalWhileIgnoringRetiredCollectionMedia() {
        val original = valid()
        val extraAsset = original.assets.single().copy(id = id(700), resourceIDs = listOf(id(701), id(702)))
        val extraResources = original.resources.mapIndexed { index, resource ->
            resource.copy(id = extraAsset.resourceIDs[index], assetID = extraAsset.id)
        }
        val document = original.copy(assets = original.assets + extraAsset, resources = original.resources + extraResources)
        val bytes = V1Json.encodeManifest(document)
        rejects(V1Json.decodeManifest(bytes), "unreferenced")
        val legacy = bytes.toString(Charsets.UTF_8).dropLast(1) + ",\"items\":[]}"
        val restored = V1Json.decodeManifest(legacy.toByteArray())
        assertEquals(original, restored)
        validate(restored)
    }

    @Test fun unsupportedSchemaAndUnsafePrefixesAreRejected() {
        rejects(valid().copy(version = 3), "manifest.version")
        for (bad in listOf("", "/life/v1/", "life/v1", "life//v1/", "life/../", "life/./", "life/a b/", "a".repeat(256) + "/")) {
            val failure = assertThrows(V1ValidationException::class.java) { V1Validator.validate(valid(), bad) }
            assertTrue(failure.message.orEmpty().contains("configuration.prefix"))
        }
    }

    @Test fun duplicateIdentitiesAreRejectedInEveryCollectionIncludingDifferentUuidCase() {
        val m = valid()
        rejects(m.copy(moments = m.moments + m.moments[0]), "moments[$momentID].id")
        rejects(m.copy(assets = m.assets + m.assets[0]), "assets[$assetID].id")
        rejects(m.copy(resources = m.resources + m.resources[0]), "resources[${m.resources[0].id}].id")
        val uppercaseID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        rejects(m.copy(moments = listOf(m.moments[0].copy(id = uppercaseID), m.moments[0].copy(id = uppercaseID.lowercase()))), ".id")
    }

    @Test fun malformedUuidIdentitiesAndReferencesAreRejected() {
        val m = valid()
        rejects(m.copy(moments = listOf(m.moments[0].copy(id = "1-2-3-4-5"))), "moments[1-2-3-4-5].id")
        rejects(m.copy(assets = listOf(m.assets[0].copy(id = "asset"))), "assets[asset].id")
        rejects(m.copy(resources = listOf(m.resources[0].copy(id = "resource")) + m.resources.drop(1)), "resources[resource].id")
        rejects(moment(m) { it.copy(assetIDs = listOf("asset")) }, "assetIDs")
        rejects(asset(m) { it.copy(resourceIDs = listOf("resource")) }, "resourceIDs")
        rejects(resource(m) { it.copy(assetID = "asset") }, "assetID")
    }

    @Test fun referencedAndIncludedMediaSetsMustMatchExactly() {
        val m = valid()
        rejects(moment(m) { it.copy(assetIDs = listOf(id(999))) }, "moments[$momentID].assetIDs")
        rejects(m.copy(assets = m.assets + m.assets[0].copy(id = id(999))), "assets[${id(999)}].id")
        rejects(resource(m) { it.copy(assetID = id(999)) }, "resources[${m.resources[0].id}].assetID")
        rejects(m.copy(moments = emptyList()), "unreferenced")
    }

    @Test fun titlesAndNotesUseUtf16() {
        val m = valid()
        validate(moment(m) { it.copy(title = "😀".repeat(100), note = "😀".repeat(5_000)) })
        rejects(moment(m) { it.copy(title = "😀".repeat(100) + "x") }, "title")
        rejects(moment(m) { it.copy(note = "😀".repeat(5_000) + "x") }, "note")
    }

    @Test fun allTimestampFieldsAcceptTheIosEndpointsAndRejectOutsideValues() {
        val edits: List<Pair<String, (V1Manifest, Long) -> V1Manifest>> = listOf(
            "moments[$momentID].occurredAt" to { m, value -> moment(m) { it.copy(occurredAt = value) } },
            "moments[$momentID].createdAt" to { m, value -> moment(m) { it.copy(createdAt = value) } },
            "moments[$momentID].updatedAt" to { m, value -> moment(m) { it.copy(updatedAt = value) } },
            "moments[$momentID].trashedAt" to { m, value -> moment(m) { it.copy(trashedAt = value) } },
            "assets[$assetID].capturedAt" to { m, value -> asset(m) { it.copy(capturedAt = value) } },
        )
        for ((field, edit) in edits) {
            validate(edit(valid(), 0L))
            validate(edit(valid(), V1Validator.MAX_TIMESTAMP))
            rejects(edit(valid(), -1L), field)
            rejects(edit(valid(), V1Validator.MAX_TIMESTAMP + 1), field)
        }
        // iOS imposes no ordering between createdAt, updatedAt, occurredAt and trashedAt.
        validate(moment(valid()) { it.copy(createdAt = 100, updatedAt = 0, occurredAt = 1, trashedAt = 0) })
    }

    @Test fun allRevisionFieldsUseTheIosSafeIntegerRange() {
        val edits: List<(V1Manifest, Long) -> V1Manifest> = listOf(
            { m, value -> moment(m) { it.copy(revision = value) } },
            { m, value -> asset(m) { it.copy(revision = value) } },
        )
        for (edit in edits) {
            validate(edit(valid(), 0))
            validate(edit(valid(), V1Validator.MAX_REVISION))
            rejects(edit(valid(), -1), "revision")
            rejects(edit(valid(), V1Validator.MAX_REVISION + 1), "revision")
        }
    }

    @Test fun momentsRequireZeroToThirtyDistinctMediaItemsAndContent() {
        val m = valid()
        rejects(withAssets(0), "moments[$momentID].assetIDs")
        // An empty record is invalid even when its removed media remains in the archive.
        rejects(moment(m) { it.copy(assetIDs = emptyList()) }, "moments[$momentID].assetIDs")
        rejects(moment(m) { it.copy(assetIDs = listOf(assetID, assetID)) }, "moments[$momentID].assetIDs")
        for (count in listOf(30, 31)) {
            val many = withAssets(count)
            if (count == 30) validate(many) else rejects(many, "assetIDs")
        }
    }

    @Test fun zeroMediaNotesAndTitlesAreValidButFoundationWhitespaceOnlyIsNot() {
        val blank = "\t\n\r \u0085\u00A0\u1680\u2000\u200B\u2028\u2029\u202F\u205F\u3000"
        val base = V1Manifest(moments = listOf(V1Moment(
            id = momentID, occurredAt = 0, createdAt = 0, updatedAt = 1, assetIDs = emptyList(),
        )))
        for ((title, note) in listOf("A title" to "", "" to "A note", blank to "👕", "衣服" to blank)) {
            validate(moment(base) { it.copy(title = title, note = note) })
        }
        for ((title, note) in listOf("" to "", blank to "", "" to blank, blank to blank)) {
            rejects(moment(base) { it.copy(title = title, note = note) }, "assetIDs")
        }
    }

    @Test fun receiptPackedThroughUsesFrozenRecordEditsIncludingTrash() {
        val base = valid()
        val manifest = base.copy(
            moments = listOf(base.moments.single().copy(updatedAt = 200, trashedAt = 150)),

        )
        val receipt = V1Receipt(commit().copy(createdAt = 10_000), "a".repeat(64), manifest)
        assertEquals(200L, receipt.packedThrough)
        assertEquals(400L, receipt.copy(manifest = moment(manifest) { it.copy(updatedAt = 400) }).packedThrough)
        assertNull(receipt.copy(manifest = V1Manifest()).packedThrough)
    }

    @Test fun everyMediaKindRequiresItsExactRoleSetAndCount() {
        for ((kind, roles) in listOf("photo" to listOf("photo", "preview"), "video" to listOf("video", "preview"),
            "motionPhoto" to listOf("motionPhoto", "preview"), "livePhoto" to listOf("livePhotoImage", "livePhotoVideo", "preview"))) {
            val m = withRoles(kind, roles)
            validate(m)
            rejects(m.copy(resources = m.resources.dropLast(1)), "resourceIDs")
            rejects(resource(m) { it.copy(role = "preview") }, "resourceIDs.role")
            rejects(resource(m) { it.copy(role = "unknown") }, "resourceIDs.role")
        }
        rejects(asset(valid()) { it.copy(kind = "gif") }, "kind")
    }

    @Test fun resourceMembershipMustMatchAssetResourceIdsExactly() {
        val m = valid()
        rejects(asset(m) { it.copy(resourceIDs = listOf(it.resourceIDs[0], it.resourceIDs[0])) }, "resourceIDs")
        rejects(asset(m) { it.copy(resourceIDs = it.resourceIDs + id(999)) }, "resourceIDs")
        rejects(asset(m) { it.copy(resourceIDs = listOf(id(999), it.resourceIDs[1])) }, "resourceIDs")
        rejects(m.copy(resources = m.resources + m.resources[0].copy(id = id(999))), "resourceIDs")
        val two = withAssets(2)
        rejects(two.copy(assets = listOf(two.assets[0].copy(resourceIDs = two.assets[1].resourceIDs)) + two.assets.drop(1)), "resourceIDs")
    }

    @Test fun resourceSizesHashesAndObjectKeysAreChecked() {
        val m = valid()
        validate(resource(m) { it.copy(byteCount = 1) })
        validate(resource(m) { it.copy(byteCount = V1Validator.MAX_RESOURCE_BYTES) })
        rejects(resource(m) { it.copy(byteCount = 0) }, "byteCount")
        rejects(resource(m) { it.copy(byteCount = V1Validator.MAX_RESOURCE_BYTES + 1) }, "byteCount")
        for (bad in listOf("A".repeat(64), "a".repeat(63), "g".repeat(64), "a".repeat(64) + "\n")) {
            rejects(resource(m) { it.copy(sha256 = bad) }, "sha256")
        }
        rejects(resource(m) { it.copy(objectKey = it.objectKey.removePrefix(prefix)) }, "objectKey")
        rejects(resource(m) { it.copy(objectKey = prefix + "objects/aa/" + it.sha256) }, "objectKey")
        val same = m.resources[0]
        val shared = m.copy(resources = m.resources.map { it.copy(sha256 = same.sha256, objectKey = same.objectKey, byteCount = same.byteCount) })
        validate(shared)
        rejects(resource(shared) { it.copy(byteCount = it.byteCount + 1) }, "objectKey")
    }

    @Test fun mediaTypesMatchRolesSyntaxAndUtf16Length() {
        val m = valid()
        for (type in listOf("image/jpeg", "image/vnd.vendor+type-1.2", "image/" + "a".repeat(114))) {
            validate(resource(m) { it.copy(contentType = type) })
        }
        for (type in listOf("video/jpeg", "application/jpeg", "image/", "image/x;extra", "image/汉字", "image/x\n", "image/" + "a".repeat(115))) {
            rejects(resource(m) { it.copy(contentType = type) }, "contentType")
        }
        val video = withRoles("video", listOf("video", "preview"))
        rejects(resource(video) { it.copy(contentType = "image/jpeg") }, "contentType")
        val live = withRoles("livePhoto", listOf("livePhotoImage", "livePhotoVideo", "preview"))
        rejects(live.copy(resources = live.resources.map { if (it.role == "livePhotoVideo") it.copy(contentType = "image/jpeg") else it }), "contentType")
    }

    @Test fun filenamesUseIosUtf16LimitsAndForbiddenScalars() {
        val m = valid()
        for (name in listOf("x", "a".repeat(255), "😀".repeat(127) + "a", "非 ASCII.jpg", "\u007F.jpg")) {
            validate(resource(m) { it.copy(originalFilename = name) })
        }
        for (name in listOf("", "a".repeat(256), "😀".repeat(128), "a/b", "a\\b", "a\u0000b", "a\u001Fb", "a\nb")) {
            rejects(resource(m) { it.copy(originalFilename = name) }, "originalFilename")
        }
    }

    @Test fun validSnapshotsAndTakeoversPreserveChainRules() {
        val first = commit()
        V1Validator.validateCommit(first, key(1), prefix)
        val parentHash = V1Json.sha256(V1Json.encodeCommit(first))
        val second = first.copy(sequence = 2, parentHash = parentHash, requestID = id(902), createdAt = 0)
        V1Validator.validateCommit(second, key(2), prefix, first, parentHash)
        V1Validator.validateCommit(second.copy(kind = "takeover", writerDeviceID = id(903)), key(2), prefix, first, parentHash)
        V1Validator.validateCommit(first.copy(createdAt = V1Validator.MAX_TIMESTAMP), key(1), prefix)
    }

    @Test fun everyCommitChainConditionHasANegativeExample() {
        val first = commit()
        val firstCases = listOf(
            "version" to first.copy(version = 2), "sequence" to first.copy(sequence = 0),
            "sequence" to first.copy(sequence = 2), "parentHash" to first.copy(parentHash = "a".repeat(64)),
            "kind" to first.copy(kind = "takeover"), "kind" to first.copy(kind = "merge"),
            "manifestHash" to first.copy(manifestHash = "A".repeat(64)),
            "manifestKey" to first.copy(manifestKey = "snapshots/${first.manifestHash}.json"),
            "createdAt" to first.copy(createdAt = -1), "createdAt" to first.copy(createdAt = V1Validator.MAX_TIMESTAMP + 1),
            "writerDeviceID" to first.copy(writerDeviceID = "writer"), "requestID" to first.copy(requestID = "request"),
        )
        for ((field, c) in firstCases) commitRejects(c, field)
        commitRejects(first, "key", objectKey = prefix + "commits/1.json")
        val hash = V1Json.sha256(V1Json.encodeCommit(first))
        val second = first.copy(sequence = 2, parentHash = hash)
        commitRejects(second.copy(sequence = 3), "sequence", first, hash)
        commitRejects(second.copy(parentHash = "0".repeat(64)), "parentHash", first, hash)
        commitRejects(second.copy(writerDeviceID = id(903)), "writerDeviceID", first, hash)
        val changed = second.copy(kind = "takeover", manifestHash = "a".repeat(64), manifestKey = prefix + "snapshots/${"a".repeat(64)}.json")
        commitRejects(changed, "manifestHash", first, hash)
        commitRejects(second, "parentHash", first, null)
        commitRejects(second.copy(sequence = Long.MIN_VALUE), "sequence", first.copy(sequence = Long.MAX_VALUE), hash)
    }

    @Test fun latestAcceptsEmptyStoreAndVerifiesOriginalCommitBytes() {
        assertNull(V1Validator.latest(store(emptyMap()), BackupCancellation()))
        val manifestBytes = V1Json.encodeManifest(valid())
        val first = commit()
        // A chain written by another valid encoder may include whitespace. Its parent hashes those bytes.
        val firstBytes = (" \n" + V1Json.encodeCommit(first).toString(Charsets.UTF_8) + "\n").toByteArray()
        val firstHash = V1Json.sha256(firstBytes)
        val second = first.copy(sequence = 2, parentHash = firstHash, requestID = id(902))
        val secondBytes = V1Json.encodeCommit(second)
        val remote = linkedMapOf(key(2) to secondBytes, first.manifestKey to manifestBytes, key(1) to firstBytes)
        val receipt = V1Validator.latest(store(remote), BackupCancellation())!!
        assertEquals(second, receipt.commit)
        assertEquals(V1Json.sha256(secondBytes), receipt.commitHash)
        assertEquals(valid(), receipt.manifest)
    }

    @Test fun latestRejectsGapsInvalidKeysMalformedDataAndCorruptOrInvalidTipManifest() {
        val first = commit()
        val firstBytes = V1Json.encodeCommit(first)
        val third = first.copy(sequence = 3, parentHash = V1Json.sha256(firstBytes))
        val base = mapOf(key(1) to firstBytes, first.manifestKey to V1Json.encodeManifest(valid()))
        latestRejects(base + (key(3) to V1Json.encodeCommit(third)), "sequence")
        latestRejects(mapOf(prefix + "commits/invalid.json" to firstBytes), "key")
        latestRejects(mapOf(key(1) to "{}".toByteArray()), "commits[")
        latestRejects(base + (first.manifestKey to "{}".toByteArray()), "manifestHash")
        val bad = valid().copy(version = 3)
        val badBytes = V1Json.encodeManifest(bad)
        val badHash = V1Json.sha256(badBytes)
        val badCommit = first.copy(manifestHash = badHash, manifestKey = prefix + "snapshots/$badHash.json")
        latestRejects(mapOf(key(1) to V1Json.encodeCommit(badCommit), badCommit.manifestKey to badBytes), "manifest.version")
    }

    @Test fun missingListedCommitAndMissingTipManifestIdentifyTheExactDocument() {
        val c = commit()
        val missingCommit = assertThrows(V1ValidationException::class.java) {
            V1Validator.latest(store(emptyMap(), listOf(key(1))), BackupCancellation())
        }
        assertTrue(missingCommit.message.orEmpty().contains("commits[${key(1)}].key"))
        val missingManifest = assertThrows(V1ValidationException::class.java) {
            V1Validator.latest(store(mapOf(key(1) to V1Json.encodeCommit(c))), BackupCancellation())
        }
        assertTrue(missingManifest.message.orEmpty().contains("commits[1].manifestKey"))
        assertTrue(missingManifest.message.orEmpty().contains(c.manifestKey))
    }

    @Test fun cancelledChainReadDoesNotAccessCloudStorage() {
        val cancellation = BackupCancellation().apply { cancel() }
        assertThrows(java.util.concurrent.CancellationException::class.java) {
            V1Validator.latest(store(emptyMap()), cancellation)
        }
    }

    private fun validate(manifest: V1Manifest) = V1Validator.validate(manifest, prefix)
    private fun rejects(manifest: V1Manifest, field: String) {
        val failure = assertThrows(V1ValidationException::class.java) { validate(manifest) }
        assertTrue("Expected $field, got ${failure.message}", failure.message.orEmpty().contains(field))
    }
    private fun commitRejects(c: V1Commit, field: String, previous: V1Commit? = null, previousHash: String? = null, objectKey: String = key(c.sequence.coerceAtLeast(1))) {
        val failure = assertThrows(V1ValidationException::class.java) { V1Validator.validateCommit(c, objectKey, prefix, previous, previousHash) }
        assertTrue("Expected $field, got ${failure.message}", failure.message.orEmpty().contains(field))
    }
    private fun latestRejects(bytes: Map<String, ByteArray>, field: String) {
        val failure = assertThrows(V1ValidationException::class.java) { V1Validator.latest(store(bytes), BackupCancellation()) }
        assertTrue("Expected $field, got ${failure.message}", failure.message.orEmpty().contains(field))
    }
    private fun valid() = withRoles("photo", listOf("photo", "preview"))
    private fun withRoles(kind: String, roles: List<String>): V1Manifest {
        val resources = roles.mapIndexed { index, role ->
            val sha = V1Json.sha256("resource $index".toByteArray())
            V1Resource(id = id(10 + index), assetID = assetID, role = role,
                contentType = if (role == "video" || role == "livePhotoVideo") "video/mp4" else "image/jpeg",
                originalFilename = "file.jpg", byteCount = 1, sha256 = sha, objectKey = prefix + "objects/${sha.take(2)}/$sha")
        }
        return V1Manifest(
            moments = listOf(V1Moment(id = momentID, title = "", note = "", occurredAt = 0, createdAt = 0, updatedAt = 0,
                assetIDs = listOf(assetID),   trashedAt = null, revision = 0)),

            assets = listOf(V1Asset(id = assetID, kind = kind, capturedAt = 0, resourceIDs = resources.map { it.id }, revision = 0)),
            resources = resources,
        )
    }
    private fun withAssets(count: Int): V1Manifest {
        val m = valid()
        val assets = (1..count).map { index -> m.assets[0].copy(id = id(100 + index), resourceIDs = listOf(id(200 + index * 2), id(201 + index * 2))) }
        val resources = assets.flatMap { asset -> m.resources.mapIndexed { index, r -> r.copy(id = asset.resourceIDs[index], assetID = asset.id) } }
        return m.copy(moments = listOf(m.moments[0].copy(assetIDs = assets.map { it.id })),
            assets = assets, resources = resources)
    }
    private fun moment(m: V1Manifest, edit: (V1Moment) -> V1Moment) = m.copy(moments = listOf(edit(m.moments[0])))
    private fun asset(m: V1Manifest, edit: (V1Asset) -> V1Asset) = m.copy(assets = listOf(edit(m.assets[0])))
    private fun resource(m: V1Manifest, edit: (V1Resource) -> V1Resource) = m.copy(resources = listOf(edit(m.resources[0])) + m.resources.drop(1))
    private fun commit(): V1Commit {
        val hash = V1Json.sha256(V1Json.encodeManifest(valid()))
        return V1Commit(sequence = 1, parentHash = null, writerDeviceID = writer, kind = "snapshot",
            manifestHash = hash, manifestKey = prefix + "snapshots/$hash.json", createdAt = 0, requestID = id(901))
    }
    private fun key(sequence: Long) = prefix + V1Json.commitRelativeKey(sequence)
    private fun id(number: Int) = "00000000-0000-4000-8000-${number.toString().padStart(12, '0')}"

    /** These read-only chain tests fail if latest() ever attempts a mutation. */
    private fun store(bytes: Map<String, ByteArray>, listedKeys: List<String> = bytes.keys.toList()): CosObjectStore {
        val readOnly = Proxy.newProxyInstance(
            CosObjectStore::class.java.classLoader, arrayOf(CosObjectStore::class.java),
        ) { _, method, args ->
            when (method.name) {
                "getConfiguration" -> StorageConfiguration(bucket = "example-1234567890", prefix = prefix)
                "list" -> listedKeys.filter { it.startsWith(args!![0] as String) }
                else -> error("Unexpected store operation: ${method.name}")
            }
        } as CosObjectStore
        // Kotlin permits checked exceptions; a Java Proxy otherwise wraps them as undeclared.
        return object : CosObjectStore by readOnly {
            override fun get(key: String): ByteArray = bytes[key]?.copyOf() ?: throw CosException(CosFailure.NotFound)
        }
    }
}
