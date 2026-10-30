import XCTest
@testable import JinbaoCore

final class BuildScopeTests: XCTestCase {
    private let deviceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let now: Int64 = 1_700_000_000_000

    func testVerifiedRecordsUseTheirCreationBuildAndParentForBackup() throws {
        for testBuild in [true, false] {
            for parent in ParentIdentity.allCases {
                var session = try connectedSession(testBuild: testBuild, parent: parent)
                try beginPhotoDraft(&session, name: "native")
                let eligibility: UploadEligibility = testBuild ? .testOnly : .eligible
                XCTAssertEqual(session.draft?.uploadEligibility, eligibility)
                let saved = try session.commitDraft(now: now)
                XCTAssertEqual(saved.uploadEligibility, eligibility)
                session = try roundTrip(session)
                XCTAssertEqual(session.moments, [saved])
                let bytes = try JSONEncoder().encode(PersistedArchive(session: session))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                let records = try XCTUnwrap(json["moments"] as? [[String: Any]])
                XCTAssertEqual(records.first?["uploadEligibility"] as? String, testBuild ? "testOnly" : "family")
                try assertOnlyRecordPublished(saved, session: session)
            }
        }
    }

    func testDebugRecordsAndPendingDraftStayExcludedAfterReleaseRestore() throws {
        try assertCrossBuildRestore(sourceTestBuild: true)
    }

    func testReleaseRecordsAndPendingDraftStayExcludedAfterDebugRestore() throws {
        try assertCrossBuildRestore(sourceTestBuild: false)
    }

    func testLegacyEligibleRecordsAndDraftsRemainLocalInEitherBuild() throws {
        for testBuild in [true, false] {
            var session = try connectedSession(testBuild: testBuild, parent: .dad)
            try beginPhotoDraft(&session, name: "legacy-record")
            _ = try session.commitDraft(now: now)
            try beginPhotoDraft(&session, name: "legacy-draft")
            let bytes = try JSONEncoder().encode(PersistedArchive(session: session))
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            var records = try XCTUnwrap(json["moments"] as? [[String: Any]])
            var draft = try XCTUnwrap(json["draft"] as? [String: Any])
            records[0]["uploadEligibility"] = "eligible"
            draft["uploadEligibility"] = "eligible"
            json["moments"] = records
            json["draft"] = draft
            var restored = try JSONDecoder().decode(PersistedArchive.self, from: JSONSerialization.data(withJSONObject: json)).session()
            XCTAssertEqual(restored.moments[0].assets, session.moments[0].assets)
            XCTAssertEqual(restored.draft?.assets, session.draft?.assets)
            XCTAssertEqual(restored.moments[0].uploadEligibility, .localOnly)
            XCTAssertEqual(restored.draft?.uploadEligibility, .localOnly)
            XCTAssertEqual(try restored.commitDraft(now: now + 1).uploadEligibility, .localOnly)
            try assertNoPublishing(restored)
        }
    }

    func testUnverifiedCreationStaysLocalThroughRestoreBuildChangeAndVerification() throws {
        for testBuild in [true, false] {
            for placeholder in [true, false] {
                var session = AppSession(deviceID: deviceID, testBuild: testBuild)
                try session.confirmIdentity(.mom)
                if placeholder {
                    try session.connectPlaceholder(bucket: "example-1234567890", region: "ap-shanghai")
                }
                try beginPhotoDraft(&session, name: "local-record")
                let saved = try session.commitDraft(now: now)
                try beginPhotoDraft(&session, name: "local-draft")
                var restored = try roundTrip(session)
                restored.testBuild = !testBuild
                try restored.connectVerified(bucket: "example-1234567890", region: "ap-shanghai")
                XCTAssertEqual(restored.moments, [saved])
                XCTAssertEqual(restored.draft, session.draft)
                XCTAssertEqual(try restored.commitDraft(now: now + 1).uploadEligibility, .localOnly)
                XCTAssertEqual(restored.moments.map(\.uploadEligibility), [.localOnly, .localOnly])
                XCTAssertEqual(restored.timelineEntries().count, 2)
                try assertNoPublishing(restored)
            }
        }
    }

    private func assertCrossBuildRestore(sourceTestBuild: Bool) throws {
        for parent in ParentIdentity.allCases {
            var original = try connectedSession(testBuild: sourceTestBuild, parent: parent)
            try beginPhotoDraft(&original, name: "source-record")
            let saved = try original.commitDraft(now: now)
            try beginPhotoDraft(&original, name: "source-draft")
            var restored = try roundTrip(original)
            // AppModel replaces the persisted flag with the currently running build on launch.
            restored.testBuild = !sourceTestBuild
            restored = try roundTrip(restored)
            XCTAssertEqual(restored.moments, original.moments)
            XCTAssertEqual(restored.draft, original.draft)
            XCTAssertEqual(try restored.commitDraft(now: now + 1).uploadEligibility, saved.uploadEligibility)
            XCTAssertEqual(restored.timelineEntries().count, 2)
            try assertNoPublishing(restored)

            // A fresh verified draft in the destination build is the only uploadable record.
            try beginPhotoDraft(&restored, name: "destination-record")
            let destination = try restored.commitDraft(now: now + 2)
            XCTAssertEqual(destination.uploadEligibility, sourceTestBuild ? .eligible : .testOnly)
            XCTAssertEqual(restored.moments.count, 3)
            try assertOnlyRecordPublished(destination, session: restored)
        }
    }

    private func assertOnlyRecordPublished(_ record: LocalMoment, session: AppSession,
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        let planned = try BackupPlan.manifest(session: session, now: now)
        let root = session.testBuild ? V1Layout.testRoot : try XCTUnwrap(session.identity).prefix
        XCTAssertEqual(planned.prefix, root + deviceID + "/", file: file, line: line)
        XCTAssertEqual(planned.manifest.moments.map(\.id), [record.id], file: file, line: line)
        XCTAssertEqual(planned.manifest.assets.count, 1, file: file, line: line)
        XCTAssertEqual(planned.manifest.resources.count, 2, file: file, line: line)
        let uploads = try BackupPlan.uploads(session: session)
        XCTAssertEqual(Set(uploads.map(\.relativePath)), Set(record.assets.flatMap(\.resources).map(\.relativePath)), file: file, line: line)
        XCTAssertTrue(uploads.allSatisfy { $0.objectKey.hasPrefix(root + "objects/") }, file: file, line: line)
        let memory = MemoryCOS()
        let writer = try client(session: session, memory: memory)
        let commit = try BackupPublisher.publish(client: writer, session: session, files: files(session),
                                                 now: now, requestID: UUID().uuidString)
        XCTAssertEqual(commit.sequence, 1, file: file, line: line)
        let keys = Set(memory.objects.keys)
        XCTAssertEqual(keys, Set(uploads.map(\.objectKey) + [planned.prefix + "snapshots/\(commit.manifestHash).json",
                                                          planned.prefix + V1Json.commitRelativeKey(1)]), file: file, line: line)
        XCTAssertEqual(memory.requests.filter { $0.method == "PUT" }.count, 4, file: file, line: line)
    }

    private func assertNoPublishing(_ session: AppSession,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = ContractError(path: "backup", message: "没有可备份的记录。")
        XCTAssertThrowsError(try BackupPlan.manifest(session: session, now: now), file: file, line: line) {
            XCTAssertEqual($0 as? ContractError, expected, file: file, line: line)
        }
        XCTAssertThrowsError(try BackupPlan.uploads(session: session), file: file, line: line) {
            XCTAssertEqual($0 as? ContractError, expected, file: file, line: line)
        }
        let memory = MemoryCOS()
        let writer = try client(session: session, memory: memory)
        XCTAssertThrowsError(try BackupPublisher.publish(client: writer, session: session, files: files(session),
                                                        now: now, requestID: UUID().uuidString), file: file, line: line) {
            XCTAssertEqual($0 as? ContractError, expected, file: file, line: line)
        }
        XCTAssertThrowsError(try BackupPublisher.publish(client: writer, session: session, fileURLs: [:],
                                                        now: now, requestID: UUID().uuidString), file: file, line: line) {
            XCTAssertEqual($0 as? ContractError, expected, file: file, line: line)
        }
        XCTAssertTrue(memory.requests.isEmpty, file: file, line: line)
        XCTAssertTrue(memory.objects.isEmpty, file: file, line: line)
    }

    private func connectedSession(testBuild: Bool, parent: ParentIdentity) throws -> AppSession {
        var session = AppSession(deviceID: deviceID, testBuild: testBuild)
        try session.confirmIdentity(parent)
        try session.connectVerified(bucket: "example-1234567890", region: "ap-shanghai")
        return session
    }

    private func beginPhotoDraft(_ session: inout AppSession, name: String) throws {
        session.beginDraft(now: now)
        session.updateDraft(title: name, note: name + " note")
        let resources = ["photo", "preview"].map { role -> LocalResource in
            let filename = name + "-" + role + ".jpg"
            let bytes = Data(filename.utf8)
            return LocalResource(id: name + "-" + role, role: role, contentType: "image/jpeg",
                                 originalFilename: filename, byteCount: Int64(bytes.count),
                                 sha256: Digest.sha256Hex(bytes), relativePath: "media/" + filename)
        }
        try session.addAsset(LocalAsset(id: name + "-asset", kind: "photo", capturedAt: now,
                                        provenance: ImportProvenance.verifiedOriginal.rawValue, resources: resources))
    }

    private func roundTrip(_ session: AppSession) throws -> AppSession {
        try JSONDecoder().decode(PersistedArchive.self, from: JSONEncoder().encode(PersistedArchive(session: session))).session()
    }

    private func files(_ session: AppSession) -> [String: Data] {
        Dictionary(session.moments.flatMap(\.assets).flatMap(\.resources).map {
            ($0.sha256, Data($0.originalFilename.utf8))
        }, uniquingKeysWith: { first, _ in first })
    }

    private func client(session: AppSession, memory: MemoryCOS) throws -> CosClient {
        try CosClient(configuration: StorageConfiguration(bucket: "example-1234567890", prefix: session.writerPrefix()),
                      credentials: StorageCredentials(secretID: "AKIDExample", secretKey: "ExampleSecretKey"),
                      transport: memory, now: { 1_700_000_000 })
    }
}
