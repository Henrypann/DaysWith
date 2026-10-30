import XCTest
@testable import JinbaoCore

final class UploadEligibilityTests: XCTestCase {
    private let deviceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let now: Int64 = 1_700_000_000_000
    private let verified = CloudLink.verified(bucket: "example-1234567890", region: "ap-shanghai")
    private let placeholder = CloudLink.placeholder(bucket: "example-1234567890", region: "ap-shanghai")

    func testDirectConstructionDefaultsToLocalOnly() {
        let draft = ComposerDraft(note: "Draft", occurredAt: now)
        let moment = LocalMoment(id: "local", title: "Title", note: "Note", occurredAt: now,
                                 createdAt: now, updatedAt: now, parent: .dad, assets: [])
        XCTAssertEqual(draft.uploadEligibility, .localOnly)
        XCTAssertEqual(moment.uploadEligibility, .localOnly)
    }

    func testPlaceholderTextAndPhotoStayLocalAfterVerification() throws {
        var session = makeSession(link: placeholder)
        session.beginDraft(now: now)
        session.updateDraft(title: "Private title", note: "Private text")
        let text = try session.commitDraft(now: now)
        session.beginDraft(now: now)
        try session.addAsset(photoAsset("private"))
        let photo = try session.commitDraft(now: now)
        XCTAssertEqual(text.uploadEligibility, .localOnly)
        XCTAssertEqual(photo.uploadEligibility, .localOnly)

        try verify(&session)
        XCTAssertEqual(session.moments.map(\.uploadEligibility), [.localOnly, .localOnly])
        XCTAssertEqual(session.timelineEntries().count, 2)
        XCTAssertEqual(session.moments[1].assets, photo.assets)
        assertNoBackup(session)
    }

    func testDraftCreatedWithoutVerifiedLinkCannotBeUpgradedByVerification() throws {
        for initialLink in [CloudLink.missing, placeholder] {
            var session = makeSession(link: initialLink)
            session.beginDraft(now: now)
            session.updateDraft(title: "Private draft", note: "Created before verification")
            try session.addAsset(photoAsset("draft-private"))
            XCTAssertEqual(session.draft?.uploadEligibility, .localOnly)
            try verify(&session)
            let saved = try session.commitDraft(now: now)
            XCTAssertEqual(saved.uploadEligibility, .localOnly)
            assertNoBackup(session)
        }
    }

    func testVerifiedDraftInheritsEligibilityWhenConnectionLaterChanges() throws {
        var session = makeSession(link: verified)
        session.beginDraft(now: now)
        session.updateDraft(title: "Backup title", note: "Backup note")
        try session.addAsset(photoAsset("eligible"))
        XCTAssertEqual(session.draft?.uploadEligibility, .testOnly)
        session.disconnectCloud()
        let saved = try session.commitDraft(now: now)
        XCTAssertEqual(saved.uploadEligibility, .testOnly)
        try verify(&session)
        let planned = try BackupPlan.manifest(session: session, now: now)
        XCTAssertEqual(planned.manifest.moments.map(\.id), [saved.id])
        XCTAssertEqual(planned.manifest.assets.count, 1)
        XCTAssertEqual(planned.manifest.resources.count, 2)
        XCTAssertEqual(try BackupPlan.uploads(session: session).count, 2)
        let memory = MemoryCOS()
        let commit = try BackupPublisher.publish(client: client(session: session, memory: memory), session: session,
                                                 files: files(for: saved.assets), now: now, requestID: uuid(1))
        XCTAssertEqual(commit.sequence, 1)
        XCTAssertEqual(memory.requests.filter { $0.method == "PUT" }.count, 4)
    }

    func testMixedBackupFiltersLocalOnlyButIncludesTrashedTombstonesAndMedia() throws {
        let allowed = photoAsset("allowed")
        let privateAsset = photoAsset("private")
        var shadow = allowed
        shadow.id = "shadow-asset"
        shadow.resources = allowed.resources.map { resource in
            var copy = resource
            copy.id = "shadow-" + resource.id
            copy.originalFilename = "shadow-" + resource.originalFilename
            copy.relativePath = "private/" + resource.relativePath
            return copy
        }
        let localOnly = moment("private", assets: [privateAsset, shadow])
        let allowedMoment = moment("allowed", assets: [allowed], eligibility: .testOnly)
        let trashed = moment("trashed", assets: [photoAsset("trashed")], eligibility: .testOnly, trashedAt: now)
        let privateText = moment("private-text", assets: [])
        let session = makeSession(link: verified, moments: [localOnly, privateText, trashed, allowedMoment])
        let planned = try BackupPlan.manifest(session: session, now: now)
        XCTAssertEqual(Set(planned.manifest.moments.map(\.id)), Set(try [allowedMoment, trashed].map { try V1Ids.map(kind: "record", localID: $0.id) }))
        XCTAssertEqual(planned.manifest.moments.first(where: { $0.trashedAt != nil })?.trashedAt, now)
        let includedAssets = [allowed] + trashed.assets
        let includedResources = includedAssets.flatMap(\.resources)
        XCTAssertEqual(Set(planned.manifest.assets.map(\.id)), Set(try includedAssets.map { try V1Ids.map(kind: "asset", localID: $0.id) }))
        XCTAssertEqual(Set(planned.manifest.resources.map(\.id)),
                       Set(try includedResources.map { try V1Ids.map(kind: "resource", localID: $0.id) }))
        let uploads = try BackupPlan.uploads(session: session)
        XCTAssertEqual(Set(uploads.map(\.relativePath)), Set(includedResources.map(\.relativePath)))
        let manifestText = String(decoding: planned.bytes, as: UTF8.self)
        for excluded in ["private", "shadow"] {
            XCTAssertFalse(manifestText.contains(excluded), excluded)
        }

        let memory = MemoryCOS()
        let writer = try client(session: session, memory: memory)
        var allFiles = files(for: [allowed, privateAsset] + trashed.assets)
        allFiles["unused-private"] = Data("private data".utf8)
        let first = try BackupPublisher.publish(client: writer, session: session, files: allFiles,
                                                now: now, requestID: uuid(2))
        XCTAssertEqual(first.sequence, 1)
        let mediaKeys = Set(planned.manifest.resources.map(\.objectKey))
        let privateHashes = Set(privateAsset.resources.map(\.sha256))
        XCTAssertTrue(memory.objects.keys.allSatisfy { key in !privateHashes.contains(where: { key.contains($0) }) })
        XCTAssertEqual(Set(memory.objects.keys.filter { $0.contains("/objects/") }), mediaKeys)
        XCTAssertEqual(memory.objects[planned.prefix + "snapshots/\(first.manifestHash).json"], planned.bytes)
        for request in memory.requests where request.method == "PUT" {
            XCTAssertFalse(String(decoding: request.body, as: UTF8.self).contains("private"))
        }
        let mediaPuts = memory.requests.filter { $0.method == "PUT" && mediaKeys.contains(String($0.path.dropFirst())) }.count
        XCTAssertEqual(mediaPuts, 4)
        let mediaObjects = memory.objects.filter { mediaKeys.contains($0.key) }
        let second = try BackupPublisher.publish(client: writer, session: session, files: files(for: includedAssets),
                                                 now: now + 1, requestID: uuid(3))
        XCTAssertEqual(second.sequence, 2)
        XCTAssertEqual(memory.objects.filter { mediaKeys.contains($0.key) }, mediaObjects)
        XCTAssertTrue(memory.requests.contains { $0.method == "HEAD" && mediaKeys.contains(String($0.path.dropFirst())) })
    }

    func testArchiveRoundTripKeepsLocalOnlyAndEligibleAcrossReleaseRestore() throws {
        var session = makeSession(link: placeholder, testBuild: false)
        session.beginDraft(now: now)
        session.updateDraft(title: "Private", note: "Saved privately")
        try session.addAsset(photoAsset("private"))
        let local = try session.commitDraft(now: now)
        session.beginDraft(now: now)
        session.updateDraft(title: "Private draft", note: "Still private after restore")
        try session.addAsset(photoAsset("draft-private"))
        try verify(&session)
        session.moments.append(moment("allowed", assets: [photoAsset("allowed")], eligibility: .eligible))
        let archive = PersistedArchive(session: session)
        let bytes = try JSONEncoder().encode(archive)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("\"uploadEligibility\":\"localOnly\""))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("\"uploadEligibility\":\"family\""))
        let decoded = try JSONDecoder().decode(PersistedArchive.self, from: bytes)
        XCTAssertEqual(decoded, archive)
        var restored = decoded.session()
        XCTAssertFalse(restored.testBuild)
        XCTAssertEqual(restored.moments[0], local)
        XCTAssertEqual(restored.draft, session.draft)
        let savedDraft = try restored.commitDraft(now: now + 1)
        XCTAssertEqual(savedDraft.uploadEligibility, .localOnly)
        let planned = try BackupPlan.manifest(session: restored, now: now)
        XCTAssertTrue(planned.prefix.hasPrefix("life/v1/dad/"))
        XCTAssertEqual(planned.manifest.moments.map(\.note), ["allowed note"])
        XCTAssertEqual(try BackupPlan.uploads(session: restored).map(\.relativePath).sorted(),
                       photoAsset("allowed").resources.map(\.relativePath).sorted())
    }

    func testLegacyAndUnknownEligibilityPreserveRecordsAndDraftButFailClosed() throws {
        var session = makeSession(link: verified, testBuild: false,
                                  moments: [moment("legacy", assets: [photoAsset("legacy")], eligibility: .eligible)])
        session.beginDraft(now: now)
        session.updateDraft(title: "Legacy draft", note: "Preserve draft text")
        try session.addAsset(photoAsset("legacy-draft"))
        let bytes = try JSONEncoder().encode(PersistedArchive(session: session))
        for value: Any? in [nil, "eligible", "futureEligibility", NSNull(), 123, ["state": "eligible"]] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            var moments = try XCTUnwrap(json["moments"] as? [[String: Any]])
            var draft = try XCTUnwrap(json["draft"] as? [String: Any])
            moments[0]["uploadEligibility"] = value
            draft["uploadEligibility"] = value
            json["moments"] = moments
            json["draft"] = draft
            let changedBytes = try JSONSerialization.data(withJSONObject: json)
            var restored = try JSONDecoder().decode(PersistedArchive.self, from: changedBytes).session()
            XCTAssertEqual(restored.moments[0].title, session.moments[0].title)
            XCTAssertEqual(restored.moments[0].note, session.moments[0].note)
            XCTAssertEqual(restored.moments[0].assets, session.moments[0].assets)
            XCTAssertEqual(restored.moments[0].uploadEligibility, .localOnly)
            XCTAssertEqual(restored.draft?.assets, session.draft?.assets)
            XCTAssertEqual(restored.draft?.note, session.draft?.note)
            XCTAssertEqual(restored.draft?.uploadEligibility, .localOnly)
            let saved = try restored.commitDraft(now: now + 1)
            XCTAssertEqual(saved.uploadEligibility, .localOnly)
            assertNoBackup(restored)
            let roundTrip = try JSONDecoder().decode(PersistedArchive.self, from: JSONEncoder().encode(PersistedArchive(session: restored)))
            XCTAssertEqual(roundTrip.session(), restored)
        }
    }

    func testOnlyLocalOnlyPublishMakesZeroTransportRequests() throws {
        let session = makeSession(link: verified, moments: [moment("private", assets: [photoAsset("private")])])
        let memory = MemoryCOS()
        let writer = try client(session: session, memory: memory)
        XCTAssertThrowsError(try BackupPublisher.publish(client: writer, session: session,
                                                        files: files(for: session.moments.flatMap(\.assets)),
                                                        now: now, requestID: uuid(4))) { error in
            XCTAssertEqual(error as? ContractError, ContractError(path: "backup", message: "没有可备份的记录。"))
        }
        XCTAssertTrue(memory.requests.isEmpty)
        XCTAssertTrue(memory.objects.isEmpty)
    }

    func testEmptyArchiveDoesNotPublishButTrashedEligibleArchivePublishesTombstone() throws {
        let empty = makeSession(link: verified)
        let memory = MemoryCOS()
        XCTAssertThrowsError(try BackupPublisher.publish(client: client(session: empty, memory: memory), session: empty,
                                                        files: [:], now: now, requestID: uuid(5)))
        XCTAssertTrue(memory.requests.isEmpty)
        let session = makeSession(link: verified, moments: [moment("trashed", assets: [], eligibility: .testOnly, trashedAt: now)])
        let commit = try BackupPublisher.publish(client: client(session: session, memory: memory), session: session,
                                                 files: [:], now: now, requestID: uuid(5))
        let bytes = try XCTUnwrap(memory.objects[commit.manifestKey])
        XCTAssertEqual(try V1Json.decodeManifest(bytes).moments.first?.trashedAt, now)
        XCTAssertTrue(memory.requests.allSatisfy { $0.method != "DELETE" })
    }

    private func assertNoBackup(_ session: AppSession, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try BackupPlan.manifest(session: session, now: now), file: file, line: line)
        XCTAssertThrowsError(try BackupPlan.uploads(session: session), file: file, line: line)
    }

    private func makeSession(link: CloudLink, testBuild: Bool = true, moments: [LocalMoment] = []) -> AppSession {
        AppSession(deviceID: deviceID, testBuild: testBuild, identity: .dad, link: link, moments: moments)
    }

    private func verify(_ session: inout AppSession) throws {
        try session.connectVerified(bucket: "example-1234567890", region: "ap-shanghai")
    }

    private func moment(_ name: String, assets: [LocalAsset], eligibility: UploadEligibility = .localOnly,
                        trashedAt: Int64? = nil) -> LocalMoment {
        LocalMoment(id: name, title: name + " title", note: name + " note", occurredAt: now,
                    createdAt: now, updatedAt: now, trashedAt: trashedAt, parent: .dad, assets: assets,
                    uploadEligibility: eligibility)
    }

    private func photoAsset(_ name: String) -> LocalAsset {
        LocalAsset(id: name + "-asset", kind: "photo", capturedAt: now,
                   provenance: ImportProvenance.verifiedOriginal.rawValue,
                   resources: ["photo", "preview"].map { role in
                       let filename = name + "-" + role + ".jpg"
                       let bytes = Data(filename.utf8)
                       return LocalResource(id: name + "-" + role, role: role, contentType: "image/jpeg",
                                            originalFilename: filename, byteCount: Int64(bytes.count),
                                            sha256: Digest.sha256Hex(bytes), relativePath: "media/" + filename)
                   })
    }

    private func files(for assets: [LocalAsset]) -> [String: Data] {
        Dictionary(assets.flatMap(\.resources).map { ($0.sha256, Data($0.originalFilename.utf8)) },
                   uniquingKeysWith: { first, _ in first })
    }

    private func client(session: AppSession, memory: MemoryCOS) throws -> CosClient {
        try CosClient(configuration: StorageConfiguration(bucket: "example-1234567890", prefix: session.writerPrefix()),
                      credentials: StorageCredentials(secretID: "AKIDExample", secretKey: "ExampleSecretKey"),
                      transport: memory, now: { 1_700_000_000 })
    }

    private func uuid(_ number: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", number)
    }
}
