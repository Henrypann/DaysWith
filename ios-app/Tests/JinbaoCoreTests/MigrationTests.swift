import XCTest
@testable import JinbaoCore

final class MigrationTests: XCTestCase {
    private let device = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let now: Int64 = 1_792_382_400_000
    private var verified: CloudLink { .verified(bucket: "example-1234567890", region: "ap-shanghai") }

    private func session(test: Bool = true) -> AppSession {
        AppSession(deviceID: device, testBuild: test, identity: .dad, link: verified)
    }
    private func asset(_ name: String, capturedAt: Int64 = 0, metadata: CaptureMetadata? = nil) -> LocalAsset {
        LocalAsset(id: name, kind: "photo", capturedAt: capturedAt, provenance: "systemProvided", resources: ["photo", "preview"].map { role in
            let bytes = Data((name + role).utf8)
            return LocalResource(id: name + role, role: role, contentType: "image/jpeg", originalFilename: name + role + ".jpg",
                                 byteCount: Int64(bytes.count), sha256: Digest.sha256Hex(bytes), relativePath: "media/" + name + role + ".jpg")
        }, captureMetadata: metadata)
    }
    private func save(_ session: inout AppSession, text: String = "Record", assets: [LocalAsset] = []) throws -> LocalMoment {
        session.beginDraft(now: now)
        session.updateDraft(title: text, note: "Synthetic")
        try session.addAssets(assets)
        return try session.commitDraft(now: now)
    }
    private func client(_ session: AppSession, memory: ObjectTransport) throws -> CosClient {
        try CosClient(configuration: StorageConfiguration(bucket: "example-1234567890", prefix: session.writerPrefix()),
                      credentials: StorageCredentials(secretID: "AKIDExample", secretKey: "ExampleSecretKey"), transport: memory)
    }
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("migration-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func writeMedia(_ assets: [LocalAsset], root: URL) throws {
        for asset in assets {
            for resource in asset.resources {
                let url = root.appendingPathComponent(resource.relativePath)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data((asset.id + resource.role).utf8).write(to: url)
            }
        }
    }

    func testInitialBatchEarliestManualAndAppendNeverOverwrite() throws {
        var state = session()
        state.beginDraft(now: now)
        try state.addAssets([asset("later", capturedAt: now - 1000), asset("earlier", capturedAt: now - 2000)])
        XCTAssertEqual(state.draft?.occurredAt, now - 2000)
        try state.addAssets([asset("muchOlder", capturedAt: now - 9999)])
        XCTAssertEqual(state.draft?.occurredAt, now - 2000)
        state.setDraftOccurredAt(now - 1234)
        XCTAssertFalse(try XCTUnwrap(state.draft).occurredAtIsEstimated)
        state.removeAsset(id: "earlier")
        try state.addAssets([asset("oldest", capturedAt: now - 99999)])
        XCTAssertEqual(state.draft?.occurredAt, now - 1234)
        state.discardDraft()
        state.beginDraft(now: now)
        state.setDraftOccurredAt(now + 111)
        try state.addAssets([asset("p", capturedAt: now - 222)])
        XCTAssertEqual(state.draft?.occurredAt, now + 111)
    }

    func testUnknownZoneUsesEstimatedFormTimeWithoutFabricatingAssetTimestamp() throws {
        var state = session()
        state.beginDraft(now: now)
        let unknown = asset("zone", metadata: CaptureMetadata(source: "exifLocalTime", localDateTime: "2026-10-18 12:34:56", isEstimated: true))
        try state.addAssets([unknown], timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
        let expected = ISO8601DateFormatter().date(from: "2026-10-18T04:34:56Z")!
        XCTAssertEqual(state.draft?.occurredAt, Int64(expected.timeIntervalSince1970 * 1000))
        XCTAssertEqual(state.draft?.assets.first?.capturedAt, 0)
        XCTAssertTrue(try XCTUnwrap(state.draft).occurredAtIsEstimated)
        let restored = try JSONDecoder().decode(PersistedArchive.self, from: JSONEncoder().encode(PersistedArchive(session: state))).session()
        XCTAssertEqual(restored.draft, state.draft)
    }

    func testMissingMetadataLeavesDefaultTimeAndMarksEstimatedOnlyOnImport() throws {
        var state = session()
        state.beginDraft(now: now)
        XCTAssertFalse(try XCTUnwrap(state.draft).occurredAtIsEstimated)
        try state.addAssets([asset("missing")])
        XCTAssertEqual(state.draft?.occurredAt, now)
        XCTAssertTrue(try XCTUnwrap(state.draft).occurredAtIsEstimated)
        try state.addAssets([asset("next", capturedAt: now - 999)])
        XCTAssertEqual(state.draft?.occurredAt, now)
    }

    func testDraftResumeEditStableIDBaselineAndIdempotentCommit() throws {
        var state = session()
        state.beginDraft(now: now)
        state.updateDraft(title: "Original", note: "Do not discard")
        let firstDraft = try XCTUnwrap(state.draft)
        state.beginDraft(now: now + 123)
        XCTAssertEqual(state.draft, firstDraft)
        let original = try state.commitDraft(now: now)
        state.draft = firstDraft // A repeated transaction after restoring a stale UI payload.
        XCTAssertEqual(try state.commitDraft(now: now + 99), original)
        XCTAssertEqual(state.moments.count, 1)
        try state.beginEdit(id: original.id, now: now + 1)
        state.updateDraft(title: "Edited", note: "Kept identity")
        let edited = try state.commitDraft(now: now + 1)
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.createdAt, original.createdAt)
        XCTAssertEqual(edited.revision, original.revision + 1)
        XCTAssertEqual(state.moments.count, 1)
        try state.beginEdit(id: original.id, now: now + 2)
        try state.trashMoment(id: original.id, now: now + 3)
        XCTAssertThrowsError(try state.commitDraft(now: now + 4))
        XCTAssertNotNil(state.draft)
    }

    func testEditingAnotherRecordDoesNotOverwriteDraftOrPromoteLocalOnly() throws {
        var state = session()
        state.link = .placeholder(bucket: "example-1234567890", region: "ap-shanghai")
        let privateMoment = try save(&state)
        state.link = verified
        let other = try save(&state, text: "Other")
        try state.beginEdit(id: privateMoment.id, now: now)
        let draft = state.draft
        XCTAssertThrowsError(try state.beginEdit(id: other.id, now: now))
        XCTAssertEqual(state.draft, draft)
        state.updateDraft(title: "Updated locally", note: "Private")
        XCTAssertEqual(try state.commitDraft(now: now + 1).uploadEligibility, .localOnly)
        XCTAssertThrowsError(try state.beginEdit(id: "remote:dad:record:example", now: now))
    }

    func testThirtyLogicalMediaLimitBatchAtomicityAndReorder() throws {
        var state = session()
        state.beginDraft(now: now)
        let assets = (0..<30).map { asset("p\($0)") }
        try state.addAssets(assets)
        XCTAssertThrowsError(try state.addAssets([asset("extra")]))
        XCTAssertEqual(state.draft?.assets.count, 30)
        try state.moveAsset(from: 0, to: 29)
        XCTAssertEqual(state.draft?.assets.last?.id, "p0")
        XCTAssertThrowsError(try state.moveAsset(from: 99, to: 0))
        state.removeAsset(id: "p0")
        let before = state.draft
        XCTAssertThrowsError(try state.addAssets([asset("p1")]))
        XCTAssertEqual(state.draft, before)
    }

    func testTrashBacksUpTombstoneAndOriginalRestorePublishesRevision() throws {
        var state = session()
        let original = try save(&state, assets: [asset("shared")])
        try state.trashMoment(id: original.id, now: now + 1)
        XCTAssertTrue(state.timelineEntries().isEmpty)
        let deleted = try BackupPlan.manifest(session: state, now: now + 1).manifest
        XCTAssertEqual(deleted.moments.first?.trashedAt, now + 1)
        XCTAssertEqual(deleted.resources.count, 2)
        XCTAssertEqual(try BackupPlan.uploads(session: state).count, 2)
        try state.restoreMoment(id: original.id, now: now + 2)
        let restored = try BackupPlan.manifest(session: state, now: now + 2).manifest
        XCTAssertNil(restored.moments.first?.trashedAt)
        XCTAssertEqual(restored.moments.first?.revision, original.revision + 2)
        XCTAssertEqual(restored.resources, deleted.resources)
    }

    func testArchiveStoreCorruptLoadAndSaveNeverResetAndExplicitRecoveryPreservesBytes() throws {
        let root = try tempDirectory()
        let store = ArchiveStore(url: root.appendingPathComponent("archive.json"))
        XCTAssertNil(try store.load())
        var state = session()
        _ = try save(&state)
        try store.save(PersistedArchive(session: state))
        state.beginDraft(now: now)
        state.updateDraft(title: "New draft", note: "Recoverable")
        try store.save(PersistedArchive(session: state))
        let corrupt = Data("{corrupt".utf8)
        try corrupt.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(PersistedArchive(session: session())))
        XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
        let restored = try store.restoreRecovery()
        XCTAssertEqual(restored.moments.count, 1)
        XCTAssertNil(restored.draft) // Previous successful snapshot, not the corrupt current file.
        let quarantined = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains(".unreadable-") }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(quarantined)), corrupt)
        XCTAssertEqual(try store.load(), restored)
    }

    func testMissingPrimaryWithRecoveryNeverCreatesEmptyArchive() throws {
        let root = try tempDirectory()
        let store = ArchiveStore(url: root.appendingPathComponent("archive.json"))
        var state = session()
        _ = try save(&state)
        try store.save(PersistedArchive(session: state))
        try FileManager.default.removeItem(at: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(PersistedArchive(session: session())))
        XCTAssertEqual(try store.restoreRecovery().moments.count, 1)
        XCTAssertEqual(try store.load()?.moments.count, 1)
    }

    func testLegacyArchiveMigrationRetainsUnknownOriginsAndProtectsManualDraftTime() throws {
        var state = session()
        _ = try save(&state)
        state.beginDraft(now: now)
        state.updateDraft(title: "Legacy draft", note: "Keep")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(PersistedArchive(session: state))) as? [String: Any])
        for key in ["schemaVersion", "anniversaries", "remoteAnniversaries", "backupJob", "committedDrafts"] { json.removeValue(forKey: key) }
        var moments = try XCTUnwrap(json["moments"] as? [[String: Any]])
        moments[0].removeValue(forKey: "uploadEligibility")
        json["moments"] = moments
        var draft = try XCTUnwrap(json["draft"] as? [String: Any])
        for key in ["id", "uploadEligibility", "timeWasEdited", "hasImportedBatch", "occurredAtIsEstimated"] { draft.removeValue(forKey: key) }
        json["draft"] = draft
        var restored = try JSONDecoder().decode(PersistedArchive.self, from: JSONSerialization.data(withJSONObject: json)).session()
        XCTAssertEqual(restored.moments.first?.uploadEligibility, .localOnly)
        XCTAssertEqual(restored.draft?.uploadEligibility, .localOnly)
        try restored.addAssets([asset("old", capturedAt: now - 999)])
        XCTAssertEqual(restored.draft?.occurredAt, now)
        restored.testBuild = false
        XCTAssertThrowsError(try BackupPlan.manifest(session: restored, now: now))
    }

    func testFutureArchiveAndIdentityChangeAreRejectedWithoutReplacingPrimary() throws {
        let root = try tempDirectory()
        let store = ArchiveStore(url: root.appendingPathComponent("archive.json"))
        let state = session()
        try store.save(PersistedArchive(session: state))
        let original = try Data(contentsOf: store.url)
        var wrong = state
        wrong.identity = .mom
        XCTAssertThrowsError(try store.save(PersistedArchive(session: wrong)))
        XCTAssertEqual(try Data(contentsOf: store.url), original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        json["schemaVersion"] = 999
        let future = try JSONSerialization.data(withJSONObject: json)
        try future.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(PersistedArchive(session: state)))
        XCTAssertEqual(try Data(contentsOf: store.url), future)
    }

    func testAnniversaryDefaultsAreVirtualAndPlaceholderOverridesStayLocal() throws {
        var state = session()
        XCTAssertEqual(state.anniversaryEntries().count, 3)
        XCTAssertTrue(state.anniversaries.isEmpty)
        XCTAssertThrowsError(try BackupPlan.manifest(session: state, now: now))
        state.link = .placeholder(bucket: "example-1234567890", region: "ap-shanghai")
        let birthday = AnniversaryCalendar.defaults[1]
        try state.saveAnniversary(id: birthday.id, title: "示例纪念日", date: "--02-14", now: now)
        try state.deleteAnniversary(id: AnniversaryCalendar.defaults[2].id, now: now)
        state.link = verified
        XCTAssertEqual(state.anniversaryEntries().count, 2)
        XCTAssertEqual(state.anniversaryEntries().first(where: { $0.id == birthday.id })?.date, "0004-02-14")
        XCTAssertTrue(try state.backupAnniversaries().isEmpty)
        try state.saveAnniversary(id: birthday.id, title: "改过标题", date: "1988-02-14", now: now + 1)
        XCTAssertEqual(state.anniversaries.first?.uploadEligibility, .localOnly)
        XCTAssertTrue(try state.backupAnniversaries().isEmpty)
        let real = try state.saveAnniversary(title: "新纪念", date: "2026-10-19", now: now)
        XCTAssertEqual(try BackupPlan.manifest(session: state, now: now).manifest.anniversaries.map(\.id), [real.id])
        try state.deleteAnniversary(id: real.id, now: now + 5)
        XCTAssertEqual(try state.backupAnniversaries().first?.deletedAt, now + 5)
    }

    func testAnniversaryValidationCountdownLeapDayAndYearUnknown() throws {
        XCTAssertThrowsError(try AnniversaryCalendar.normalizedDate("2026-02-30"))
        XCTAssertThrowsError(try AnniversaryCalendar.normalizedDate("--13-01"))
        XCTAssertEqual(try AnniversaryCalendar.normalizedDate("--02-29"), "0004-02-29")
        let entry = AnniversaryEntry(id: "leap", title: "Leap", date: "0004-02-29", owner: .dad, readOnly: false)
        let date = ISO8601DateFormatter().date(from: "2027-02-27T12:00:00Z")!
        let upcoming = try XCTUnwrap(AnniversaryCalendar.upcoming([entry], now: Int64(date.timeIntervalSince1970 * 1000), timeZone: TimeZone(secondsFromGMT: 0)!).first)
        XCTAssertEqual(upcoming.daysUntil, 1)
        XCTAssertNil(upcoming.years)
        XCTAssertTrue(upcoming.shouldRemind)
    }

    func testFamilyMergeIncludesRemoteOriginalResourcesAndAnniversaryTombstones() throws {
        var state = session(test: false)
        let original = try save(&state, assets: [asset("family")])
        let anniversary = try state.saveAnniversary(title: "Family day", date: "--10-19", now: now)
        let first = try BackupPlan.manifest(session: state, now: now)
        try state.deleteAnniversary(id: anniversary.id, now: now + 1)
        let latest = try BackupPlan.manifest(session: state, now: now + 1)
        let sources = [ChainSnapshot(parent: .dad, prefix: first.prefix, writer: device, createdAt: now, manifest: first.manifest),
                       ChainSnapshot(parent: .dad, prefix: latest.prefix, writer: device, createdAt: now + 1, manifest: latest.manifest)]
        let merged = try XCTUnwrap(ArchiveMerge.merge(sources).first)
        XCTAssertEqual(merged.id, ArchiveMerge.remoteID(parent: .dad, momentID: original.id))
        XCTAssertTrue(merged.readOnly)
        XCTAssertEqual(merged.media.first?.resources.count, 2)
        XCTAssertNoThrow(try merged.media.first?.resources.first?.validate())
        XCTAssertEqual(ArchiveMerge.mergeAnniversaries(sources).first?.deletedAt, now + 1)
        let roundTrip = try JSONDecoder().decode(RemoteMoment.self, from: JSONEncoder().encode(merged))
        XCTAssertEqual(roundTrip, merged)
    }

    func testBackupQueuePauseRoundTripResumeAndDuplicateDoNotCreateExtraCommit() throws {
        var state = session()
        let media = [asset("first"), asset("second")]
        _ = try save(&state, assets: media)
        let root = try tempDirectory()
        try writeMedia(media, root: root)
        let memory = MemoryCOS()
        let writer = try client(state, memory: memory)
        var job = try BackupQueue.prepare(client: writer, session: state, now: now)
        let frozen = job.manifestBytes
        var persisted = job
        try BackupQueue.advance(client: writer, session: state, job: &job,
                                resolve: { root.appendingPathComponent($0) }, persist: { persisted = $0 },
                                shouldPause: { persisted.completedCount >= 1 })
        XCTAssertEqual(job.status, .paused)
        XCTAssertEqual(job.completedCount, 1)
        XCTAssertFalse(memory.objects.keys.contains { $0.contains("/commits/") })
        job = try JSONDecoder().decode(BackupJob.self, from: JSONEncoder().encode(persisted))
        job.resume()
        try BackupQueue.advance(client: writer, session: state, job: &job,
                                resolve: { root.appendingPathComponent($0) }, persist: { persisted = $0 })
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(job.manifestBytes, frozen)
        XCTAssertEqual(job.progress, 1)
        XCTAssertEqual(memory.requests.filter { $0.method == "PUT" && $0.path.contains("/objects/") }.count, 4)
        XCTAssertEqual(memory.requests.filter { $0.method == "PUT" && $0.path.contains("/commits/") }.count, 1)
        let unchanged = try BackupQueue.prepare(client: writer, session: state, now: now + 1)
        XCTAssertEqual(unchanged.status, .completed)
        XCTAssertTrue(memory.requests.allSatisfy { $0.method != "DELETE" })
        XCTAssertTrue(memory.requests.filter { $0.method == "PUT" }.allSatisfy { $0.path.hasPrefix("/life/v1/test/") })
    }

    func testBackupQueueLostCommitResponseResumesExactCommitAndValidatesScope() throws {
        var state = session()
        _ = try save(&state)
        let transport = LostCommitResponse()
        let writer = try client(state, memory: transport)
        var job = try BackupQueue.prepare(client: writer, session: state, now: now)
        var persisted = job
        XCTAssertThrowsError(try BackupQueue.advance(client: writer, session: state, job: &job,
                                                     resolve: { _ in throw CosFailure(.notFound) }, persist: { persisted = $0 }))
        XCTAssertEqual(job.status, .failed)
        XCTAssertEqual(transport.memory.objects.keys.filter { $0.contains("/commits/") }.count, 1)
        let frozen = job.commitBytes
        job = try JSONDecoder().decode(BackupJob.self, from: JSONEncoder().encode(persisted))
        job.resume()
        var release = state
        release.testBuild = false
        let before = transport.memory.requests.count
        XCTAssertThrowsError(try BackupQueue.advance(client: writer, session: release, job: &job,
                                                     resolve: { _ in throw CosFailure(.notFound) }, persist: { _ in }))
        XCTAssertEqual(transport.memory.requests.count, before)
        try BackupQueue.advance(client: writer, session: state, job: &job,
                                resolve: { _ in throw CosFailure(.notFound) }, persist: { persisted = $0 })
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(job.commitBytes, frozen)
        XCTAssertEqual(transport.memory.objects.keys.filter { $0.contains("/commits/") }.count, 1)
    }

    func testBackupQueueStopsBeforePublicationWhenPersistFails() throws {
        var state = session()
        _ = try save(&state)
        let memory = MemoryCOS()
        let writer = try client(state, memory: memory)
        var job = try BackupQueue.prepare(client: writer, session: state, now: now)
        XCTAssertThrowsError(try BackupQueue.advance(client: writer, session: state, job: &job,
                                                     resolve: { _ in throw CosFailure(.notFound) },
                                                     persist: { _ in throw CosFailure(.secureStorage) }))
        XCTAssertTrue(memory.requests.allSatisfy { $0.method != "PUT" })
        XCTAssertEqual(job.status, .failed)
    }
}

private final class LostCommitResponse: ObjectTransport {
    let memory = MemoryCOS()
    private var lost = false
    func execute(_ request: ObjectRequest) throws -> ObjectResponse {
        let result = try memory.execute(request)
        if !lost && request.method == "PUT" && request.path.contains("/commits/") {
            lost = true
            throw CosFailure(.timeout)
        }
        return result
    }
}
