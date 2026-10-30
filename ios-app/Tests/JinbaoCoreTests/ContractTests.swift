import XCTest
@testable import JinbaoCore

final class ContractTests: XCTestCase {
    private let id = "643C9BAE-C2F8-42F7-BE24-119076330069"
    private let deviceA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let deviceB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    func testDigestsAndUUIDVersion5() {
        XCTAssertEqual(Digest.sha256Hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Digest.hex(Digest.sha1([])), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(V1Ids.uuidV5(namespace: "6ba7b810-9dad-11d1-80b4-00c04fd430c8", name: "python.org"),
                       "886313e1-3b8a-5372-9b90-0c9aee199e5d")
        XCTAssertEqual(V1Ids.namespace, "6F0F3B0E-6B2F-5C55-9E57-0D365A7D0001")
        XCTAssertEqual(try V1Ids.map(kind: "record", localID: "local-123"), "729821C3-92EC-547D-8423-E0A85BAA6A11")
        XCTAssertEqual(try V1Ids.map(kind: "asset", localID: "local-123"), "9ED6C522-4F56-55C6-99FE-D50CDA4FC5A7")
        XCTAssertEqual(try V1Ids.map(kind: "resource", localID: "local-123"), "D4551570-A072-5141-915E-C4D2662C4CC1")
        XCTAssertEqual(try V1Ids.map(kind: "record", localID: id.lowercased()), id)
        XCTAssertEqual(try V1Ids.map(kind: "record", localID: "rec-\(id)"), id)
        XCTAssertThrowsError(try V1Ids.map(kind: "device", localID: "id"))
        XCTAssertThrowsError(try V1Ids.legacyID(kind: "record", localID: id))
    }

    func testCommitMatchesAndroidWireFormat() throws {
        let commit = V1Commit(
            sequence: 1, writerDeviceID: id, manifestHash: String(repeating: "a", count: 64),
            manifestKey: "life/v1/android/snapshots/\(String(repeating: "a", count: 64)).json",
            createdAt: 123, requestID: id
        )
        let expected = #"{"createdAt":123,"kind":"snapshot","manifestHash":"\#(String(repeating: "a", count: 64))","manifestKey":"life/v1/android/snapshots/\#(String(repeating: "a", count: 64)).json","requestID":"\#(id)","sequence":1,"version":1,"writerDeviceID":"\#(id)"}"#
        let bytes = V1Json.encodeCommit(commit)
        XCTAssertEqual(String(data: bytes, encoding: .utf8), expected)
        XCTAssertEqual(try V1Json.decodeCommit(bytes), commit)
        XCTAssertEqual(V1Json.commitRelativeKey(1), "commits/00000000000000000001.json")
        XCTAssertEqual(V1Json.commitRelativeKey(Int64.max), "commits/09223372036854775807.json")
    }

    func testManifestRoundTripIgnoresUnknownKeysAndSorts() throws {
        let manifest = sampleManifest()
        let bytes = V1Json.encodeManifest(manifest)
        let text = String(data: bytes, encoding: .utf8)!
        XCTAssertEqual(try V1Json.decodeManifest(bytes), manifest)
        XCTAssertEqual(V1Json.encodeManifest(try V1Json.decodeManifest(bytes)), bytes)
        XCTAssertTrue(text.contains("\"title\":\"\""))
        XCTAssertTrue(text.contains("中文 / café 👕"))
        XCTAssertTrue(text.contains("\\n\\t\\\"\\\\"))
        XCTAssertFalse(text.contains("\\/"))
        XCTAssertFalse(text.contains("\\u4e2d"))
        XCTAssertFalse(text.contains("trashedAt"))
        XCTAssertFalse(text.contains(": "))
        XCTAssertFalse(text.contains(", "))
        XCTAssertFalse(text.contains("\n"))
        assertSorted(try JSONWire.parse(bytes, path: "manifest"))
        let invalid = [
            text.replacingOccurrences(of: "\"version\":1", with: "\"version\":\"1\""),
            text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1.0"),
            text.replacingOccurrences(of: "\"revision\":0", with: "\"revision\":9223372036854775808"),
            text.replacingOccurrences(of: id, with: "not-a-uuid"),
            text.replacingOccurrences(of: "\"title\":\"\",", with: ""),
            text.replacingOccurrences(of: "\"note\":", with: "\"renamedNote\":"),
        ]
        for sample in invalid {
            XCTAssertThrowsError(try V1Json.decodeManifest(Data(sample.utf8)))
        }
        let extra = String(text.dropLast()) + ",\"future\":{\"anything\":true}}"
        XCTAssertEqual(try V1Json.decodeManifest(Data(extra.utf8)), manifest)
        XCTAssertEqual(try V1Json.decodeManifest(Data(text.replacingOccurrences(of: id, with: id.lowercased()).utf8)), manifest)
        XCTAssertThrowsError(try V1Json.decodeManifest(Data([0xc3, 0x28])))
        XCTAssertThrowsError(try V1Json.decodeManifest(Data(count: JSONWire.metadataLimit + 1)))
    }

    func testIgnoreListSkipsObjectsAndSnapshotOnlyPrefixes() throws {
        let chain = try V1Layout.chainPrefix(parent: .dad, deviceID: deviceA, test: false)
        XCTAssertEqual(V1Layout.objectRoot(prefix: chain), "life/v1/dad/")
        XCTAssertEqual(V1Layout.objectKey(prefix: chain, sha256: String(repeating: "ab", count: 32)),
                       "life/v1/dad/objects/ab/" + String(repeating: "ab", count: 32))
        XCTAssertEqual(V1Layout.objectRoot(prefix: try V1Layout.chainPrefix(parent: .mom, deviceID: deviceA, test: true)), "life/v1/test/")
        for parent in ParentIdentity.allCases {
            let testChain = try V1Layout.chainPrefix(parent: parent, deviceID: deviceA, test: true)
            XCTAssertEqual(testChain, "life/v1/test/\(deviceA)/")
            let keys = [
                testChain + "commits/00000000000000000001.json",
                testChain + "snapshots/gallery.json",
                V1Layout.objectKey(prefix: testChain, sha256: String(repeating: "ab", count: 32)),
            ]
            for key in keys {
                XCTAssertTrue(key.hasPrefix("life/v1/test/"))
                XCTAssertFalse(key.hasPrefix("life/v1/dad/") || key.hasPrefix("life/v1/mom/"))
            }
        }
        let listed = [
            "life/v1/dad/commits/00000000000000000001.json",
            "life/v1/dad/snapshots/x.json",
            "life/v1/dad/objects/ab/abc",
            "life/v1/dad/\(deviceA)/commits/00000000000000000001.json",
            "life/v1/dad/\(deviceA)/commits/00000000000000000002.json",
            "life/v1/dad/\(deviceB)/snapshots/only.json",
            "life/v1/mom/commits/00000000000000000001.json",
        ]
        XCTAssertEqual(V1Layout.chainsUnder(root: "life/v1/dad/", keys: listed), ["life/v1/dad/", "life/v1/dad/\(deviceA)/"])
        XCTAssertTrue(V1Layout.owns(owner: .dad, prefix: "life/v1/dad/"))
        XCTAssertTrue(V1Layout.owns(owner: .dad, prefix: "life/v1/test/\(deviceA)/"))
        XCTAssertFalse(V1Layout.owns(owner: .dad, prefix: "life/v1/mom/"))
    }

    func testSignerMatchesSharedVectorAndNeverPrintsTheKey() throws {
        let signer = COSSigner(credentials: StorageCredentials(secretID: "AKIDExample", secretKey: "ExampleSecretKey"))
        let authorization = try signer.authorization(
            method: "PUT",
            path: "/life/v1/photos/球衣(1).heic",
            query: ["uploadId": "a+/=", "partNumber": "2"],
            headers: [
                "Host": "ootd365-life-1234567890.cos.ap-shanghai.myqcloud.com",
                "Content-Type": "image/heic",
                "x-cos-forbid-overwrite": "true",
                "x-cos-server-side-encryption": "AES256",
            ],
            now: 1_700_000_000,
            validFor: 900
        )
        XCTAssertEqual(authorization, "q-sign-algorithm=sha1&q-ak=AKIDExample&q-sign-time=1699999940;1700000900&q-key-time=1699999940;1700000900&q-header-list=content-type;host;x-cos-forbid-overwrite;x-cos-server-side-encryption&q-url-param-list=partnumber;uploadid&q-signature=f0b1a7e8aab81b273bf8d8095731fbe39627adee")
        let temporary = StorageCredentials(secretID: "AKIDSynthetic_-", secretKey: "+/8AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0=")
        let signed = try COSSigner(credentials: temporary).authorization(
            method: "GET", path: "/life/v1/mom/objects/synthetic",
            headers: ["Host": "example.cos.ap-shanghai.myqcloud.com"], now: 1_700_000_000
        )
        XCTAssertEqual(signed, "q-sign-algorithm=sha1&q-ak=AKIDSynthetic_-&q-sign-time=1699999940;1700000900&q-key-time=1699999940;1700000900&q-header-list=host&q-url-param-list=&q-signature=e319acc461e2e3cb1a321fdd6e6a608147d8fb2f")
        XCTAssertEqual(temporary.description, "StorageCredentials(redacted)")
        XCTAssertFalse(temporary.description.contains(temporary.secretKey))
        XCTAssertFalse(signer.description.contains("ExampleSecretKey"))
        XCTAssertThrowsError(try COSSigner(credentials: temporary).authorization(
            method: "GET", path: "/", headers: ["Host": "x", "host": "y"], now: 1_700_000_000
        ))
        XCTAssertFalse(StorageCredentials.validID("AKID+"))
        XCTAssertTrue(StorageCredentials.validKey("AKID+"))
        XCTAssertEqual(StorageConfiguration(bucket: "example-1234567890").host, "example-1234567890.cos.ap-shanghai.myqcloud.com")
        XCTAssertThrowsError(try StorageConfiguration(bucket: "BUCKET-12345").validate())
        XCTAssertThrowsError(try StorageConfiguration(bucket: "example-1234567890", prefix: "life/../").validate())
    }

    func testTemporaryTokenTravelsWithEveryRequestAndIsCoveredBySignature() throws {
        let credentials = StorageCredentials(secretID: "AKIDSynthetic", secretKey: "SyntheticKey",
                                             sessionToken: "SyntheticToken+/=:", expiresAt: 1_700_000_120)
        let memory = MemoryCOS()
        let client = try CosClient(configuration: StorageConfiguration(bucket: "example-1234567890"), credentials: credentials,
                                   transport: memory, now: { 1_700_000_000 })
        let key = "life/v1/test/synthetic.json"
        try client.put(key: key, body: Data("synthetic".utf8), contentType: "application/json")
        _ = try client.list(prefix: "life/v1/test/")
        _ = try client.get(key: key)
        XCTAssertEqual(Set(memory.requests.map(\.method)), ["GET", "HEAD", "PUT"])
        for request in memory.requests {
            XCTAssertEqual(request.headers["x-cos-security-token"], credentials.sessionToken)
            let authorization = try XCTUnwrap(request.headers["Authorization"])
            XCTAssertTrue(authorization.contains("x-cos-security-token"))
            XCTAssertTrue(authorization.contains("q-sign-time=1699999940;1700000120&"))
            var headers = request.headers
            headers.removeValue(forKey: "Authorization")
            XCTAssertEqual(authorization, try COSSigner(credentials: credentials).authorization(
                method: request.method, path: request.path, query: request.query, headers: headers, now: 1_700_000_000))
            var changed = headers
            changed["x-cos-security-token"] = "ChangedSyntheticToken"
            let other = StorageCredentials(secretID: credentials.secretID, secretKey: credentials.secretKey,
                                           sessionToken: "ChangedSyntheticToken", expiresAt: credentials.expiresAt)
            XCTAssertNotEqual(authorization, try COSSigner(credentials: other).authorization(
                method: request.method, path: request.path, query: request.query, headers: changed, now: 1_700_000_000))
        }
        XCTAssertEqual(credentials.description, "StorageCredentials(redacted)")
    }

    func testExpiredTemporaryCredentialsNeverReachTransportIncludingAfterConstruction() throws {
        var clock: Int64 = 1_700_000_000
        let memory = MemoryCOS()
        let client = try CosClient(configuration: StorageConfiguration(bucket: "example-1234567890"),
                                   credentials: StorageCredentials(secretID: "AKIDSynthetic", secretKey: "SyntheticKey",
                                                                   sessionToken: "SyntheticToken", expiresAt: clock + 1),
                                   transport: memory, now: { clock })
        clock += 1
        XCTAssertThrowsError(try client.list(prefix: "life/v1/dad/")) {
            XCTAssertEqual(($0 as? CosFailure)?.failure, .expiredCredentials)
        }
        XCTAssertThrowsError(try client.put(key: "life/v1/test/synthetic", body: Data(), contentType: "text/plain")) {
            XCTAssertEqual(($0 as? CosFailure)?.failure, .expiredCredentials)
        }
        XCTAssertTrue(memory.requests.isEmpty)
    }

    func testLongTermCredentialsDoNotAddTokenAndTemporaryTokenValidationRejectsHeaderInjection() throws {
        let memory = MemoryCOS()
        let client = try CosClient(configuration: StorageConfiguration(bucket: "example-1234567890"),
                                   credentials: StorageCredentials(secretID: "AKIDSynthetic", secretKey: "SyntheticKey"),
                                   transport: memory, now: { 1_700_000_000 })
        _ = try client.list(prefix: "life/v1/mom/")
        XCTAssertNil(memory.requests.first?.headers["x-cos-security-token"])
        XCTAssertFalse(try XCTUnwrap(memory.requests.first?.headers["Authorization"]).contains("x-cos-security-token"))
        XCTAssertTrue(StorageCredentials.validSessionToken(String(repeating: "A", count: 16_384)))
        for token in ["", "synthetic\r\nInjected:header", "synthetic\n", "with space", "\u{7f}", String(repeating: "A", count: 16_385)] {
            XCTAssertFalse(StorageCredentials(secretID: "AKIDSynthetic", secretKey: "SyntheticKey", sessionToken: token).isValid)
        }
        XCTAssertFalse(StorageCredentials(secretID: "AKIDSynthetic", secretKey: "SyntheticKey", expiresAt: 0).isValid)
    }

    func testKeychainServiceIsNotSharedWithOOTD() throws {
        XCTAssertEqual(CredentialStoreContract.keychainService, "com.henrypann.jinbao365.credentials")
        XCTAssertEqual(CredentialStoreContract.bundleIdentifier, "com.henrypann.jinbao365")
        XCTAssertEqual(CredentialStoreContract.displayName, "DaysWith")
        XCTAssertFalse(CredentialStoreContract.keychainService.lowercased().contains("ootd"))
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Jinbao365.xcodeproj/project.pbxproj")
        let text = try String(contentsOf: project, encoding: .utf8)
        XCTAssertTrue(text.contains("PRODUCT_BUNDLE_IDENTIFIER = com.henrypann.jinbao365;"))
        XCTAssertFalse(text.lowercased().contains("ootd"))
    }

    func testMonthTitlesAlwaysIncludeTheYear() {
        let zone = TimeZone(secondsFromGMT: 0)!
        let entries = [
            entry("a", millis(2026, 10, 18), .dad),
            entry("b", millis(2026, 1, 2), .mom),
            entry("c", millis(2025, 12, 31), .dad),
        ]
        let months = JinbaoCalendar.months(entries: entries, timeZone: zone)
        XCTAssertEqual(months.map(\.title), ["2026年10月", "2026年1月", "2025年12月"])
        XCTAssertTrue(months.allSatisfy { $0.title.contains("年") && $0.title.hasSuffix("月") })
        XCTAssertEqual(TimelineMonth.title(year: 2026, month: 10), "2026年10月")
    }

    func testPlaceholderTimelineThenTextAndPhotoDraft() throws {
        var session = AppSession(deviceID: deviceA, testBuild: true)
        XCTAssertEqual(session.phase, .chooseIdentity)
        try session.confirmIdentity(.dad)
        XCTAssertEqual(session.phase, .connectCloud)
        XCTAssertThrowsError(try session.confirmIdentity(.mom))
        try session.confirmIdentity(.dad)
        try session.connectPlaceholder(bucket: "example-1234567890", region: "ap-shanghai")
        XCTAssertEqual(session.phase, .timeline)
        XCTAssertTrue(session.months(timeZone: TimeZone(secondsFromGMT: 0)!).isEmpty)
        let when = millis(2026, 10, 18)
        session.beginDraft(now: when)
        session.updateDraft(title: "", note: "今天会说谢谢")
        let saved = try session.commitDraft(now: when)
        XCTAssertEqual(saved.parent, .dad)
        XCTAssertEqual(saved.uploadEligibility, .localOnly)
        XCTAssertNil(session.draft)
        let months = session.months(timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(months.map(\.title), ["2026年10月"])
        XCTAssertEqual(months[0].days[0].moments[0].note, "今天会说谢谢")
        XCTAssertEqual(months[0].days[0].moments[0].parent, .dad)
        XCTAssertFalse(months[0].days[0].moments[0].readOnly)

        session.beginDraft(now: when)
        try session.addAsset(photoAsset())
        let photo = try session.commitDraft(now: when + 1)
        XCTAssertEqual(photo.assets.count, 1)
        XCTAssertEqual(photo.assets[0].provenance, ImportProvenance.verifiedOriginal.rawValue)
        XCTAssertEqual(session.timelineEntries().first { $0.id == photo.id }?.provenanceLabel, "已确认原件")
        XCTAssertEqual(try session.writerPrefix(), "life/v1/test/\(deviceA)/")
        XCTAssertEqual(try session.objectRoot(), "life/v1/test/")

        let persisted = String(data: try JSONEncoder().encode(PersistedArchive(session: session)), encoding: .utf8)!
        XCTAssertFalse(persisted.contains("secret"))
        XCTAssertFalse(persisted.contains("ExampleSecretKey"))
        XCTAssertThrowsError(try BackupPlan.manifest(session: session, now: when))
    }

    func testMergeKeepsNewestParentCopyAndHidesNewerDeletion() {
        let older = ChainSnapshot(parent: .mom, prefix: "life/v1/mom/", writer: uuid(70), createdAt: 10,
                                  manifest: textManifest(id: uuid(1), note: "旧版", updatedAt: 10))
        let newer = ChainSnapshot(parent: .mom, prefix: "life/v1/mom/\(deviceB)/", writer: uuid(71), createdAt: 15,
                                  manifest: textManifest(id: uuid(1), note: "新版", updatedAt: 15))
        let sibling = ChainSnapshot(parent: .dad, prefix: "life/v1/dad/\(deviceB)/", writer: uuid(74), createdAt: 10,
                                    manifest: textManifest(id: uuid(4), note: "爸爸另一台", updatedAt: 10))
        let merged = ArchiveMerge.merge([older, newer, sibling])
        XCTAssertEqual(Set(merged.map(\.note)), ["新版", "爸爸另一台"])
        XCTAssertEqual(merged.first { $0.note == "新版" }?.parent, .mom)
        XCTAssertEqual(merged.first { $0.note == "爸爸另一台" }?.parent, .dad)
        XCTAssertTrue(merged.allSatisfy(\.readOnly))

        let deleted = ChainSnapshot(parent: .mom, prefix: "life/v1/mom/\(deviceB)/", writer: uuid(71), createdAt: 20,
                                    manifest: textManifest(id: uuid(1), note: "旧版", updatedAt: 20, trashedAt: 20))
        XCTAssertTrue(ArchiveMerge.merge([older, deleted]).isEmpty)
    }

    func testFamilyReadSkipsThisDeviceAndTestBackupNeverTouchesParents() throws {
        let memory = MemoryCOS()
        let selfID = uuid(80)
        publish(memory, prefix: ParentIdentity.mom.prefix, writer: uuid(70), moment: 1, note: "旧版", updatedAt: 1_700_000_000_000)
        publish(memory, prefix: ParentIdentity.mom.prefix + uuid(71) + "/", writer: uuid(71), moment: 1, note: "新版", updatedAt: 1_700_000_000_005)
        publish(memory, prefix: ParentIdentity.dad.prefix + selfID + "/", writer: selfID, moment: 5, note: "本机", updatedAt: 1_700_000_000_000)
        publish(memory, prefix: ParentIdentity.dad.prefix, writer: uuid(73), moment: 3, note: "爸爸旧链", updatedAt: 1_700_000_000_000)
        let reader = try CosClient(
            configuration: StorageConfiguration(bucket: "example-1234567890"),
            credentials: StorageCredentials(secretID: "AKIDExample", secretKey: "ExampleSecretKey"),
            transport: memory,
            now: { 1_700_000_000 }
        )
        let remote = try FamilyReader.read(client: reader, owner: .dad, deviceID: selfID, testBuild: false)
        XCTAssertEqual(Set(remote.map(\.note)), ["新版", "爸爸旧链"])
        XCTAssertTrue(memory.requests.allSatisfy { $0.method != "DELETE" && $0.method != "PUT" })

        var session = AppSession(deviceID: deviceA, testBuild: true, identity: .dad,
                                 link: .verified(bucket: "example-1234567890", region: "ap-shanghai"))
        let when = millis(2026, 10, 18)
        session.beginDraft(now: when)
        session.updateDraft(title: "一句", note: "")
        let saved = try session.commitDraft(now: when)
        XCTAssertEqual(saved.uploadEligibility, .testOnly)
        let writer = MemoryCOS()
        let prefix = try session.writerPrefix()
        let client = try CosClient(
            configuration: StorageConfiguration(bucket: "example-1234567890", prefix: prefix),
            credentials: StorageCredentials(secretID: "AKIDExample", secretKey: "ExampleSecretKey"),
            transport: writer,
            now: { 1_700_000_000 }
        )
        let first = try BackupPublisher.publish(client: client, session: session, files: [:], now: when, requestID: uuid(90))
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(first.writerDeviceID, deviceA.uppercased())
        let puts = writer.requests.filter { $0.method == "PUT" }
        XCTAssertFalse(puts.isEmpty)
        for request in puts {
            XCTAssertEqual(request.headers["x-cos-forbid-overwrite"], "true")
            XCTAssertEqual(request.headers["x-cos-server-side-encryption"], "AES256")
            let key = String(request.path.dropFirst())
            XCTAssertTrue(key.hasPrefix("life/v1/test/\(deviceA)/"), key)
            XCTAssertFalse(key.hasPrefix("life/v1/dad/") || key.hasPrefix("life/v1/mom/"))
        }
        XCTAssertTrue(writer.requests.allSatisfy { $0.method != "DELETE" })
        let second = try BackupPublisher.publish(client: client, session: session, files: [:], now: when + 1, requestID: uuid(91))
        XCTAssertEqual(second.sequence, 2)
        XCTAssertTrue(writer.requests.contains { $0.method == "HEAD" })
    }

    private func sampleManifest() -> V1Manifest {
        V1Manifest(
            moments: [V1Moment(id: id, note: "中文 / café 👕\n\t\"\\", occurredAt: 1, createdAt: 2, updatedAt: 3, assetIDs: [id])],
            assets: [V1Asset(id: id, kind: "photo", capturedAt: 0, resourceIDs: [id])],
            resources: [V1Resource(id: id, assetID: id, role: "photo", contentType: "image/jpeg", originalFilename: "IMG/中文.jpg",
                                   byteCount: 8, sha256: String(repeating: "a", count: 64),
                                   objectKey: "life/v1/android/objects/aa/\(String(repeating: "a", count: 64))")]
        )
    }

    private func textManifest(id: String, note: String, updatedAt: Int64, trashedAt: Int64? = nil) -> V1Manifest {
        V1Manifest(moments: [V1Moment(id: id, note: note, occurredAt: updatedAt, createdAt: updatedAt, updatedAt: updatedAt,
                                      assetIDs: [], trashedAt: trashedAt, revision: 1)])
    }

    private func publish(_ memory: MemoryCOS, prefix: String, writer: String, moment: Int, note: String, updatedAt: Int64) {
        let manifest = textManifest(id: uuid(moment), note: note, updatedAt: updatedAt)
        let bytes = V1Json.encodeManifest(manifest)
        let hash = Digest.sha256Hex(bytes)
        memory.objects[prefix + "snapshots/\(hash).json"] = bytes
        let commit = V1Commit(sequence: 1, writerDeviceID: writer, manifestHash: hash,
                              manifestKey: prefix + "snapshots/\(hash).json", createdAt: updatedAt, requestID: uuid(99))
        memory.objects[prefix + V1Json.commitRelativeKey(1)] = V1Json.encodeCommit(commit)
    }

    private func photoAsset() -> LocalAsset {
        let hash = Digest.sha256Hex(Data("original".utf8))
        let preview = Digest.sha256Hex(Data("preview".utf8))
        return LocalAsset(
            id: uuid(40), kind: "photo", capturedAt: 0, provenance: ImportProvenance.verifiedOriginal.rawValue,
            resources: [
                LocalResource(id: uuid(41), role: "photo", contentType: "image/jpeg", originalFilename: "original.jpg",
                              byteCount: 8, sha256: hash, relativePath: "media/original.jpg"),
                LocalResource(id: uuid(42), role: "preview", contentType: "image/jpeg", originalFilename: "preview.jpg",
                              byteCount: 7, sha256: preview, relativePath: "media/preview.jpg"),
            ]
        )
    }

    private func entry(_ id: String, _ occurredAt: Int64, _ parent: ParentIdentity) -> TimelineEntry {
        TimelineEntry(id: id, title: "", note: id, occurredAt: occurredAt, parent: parent, readOnly: false,
                      mediaCount: 0, previewPath: nil, provenanceLabel: nil)
    }

    private func millis(_ year: Int, _ month: Int, _ day: Int) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func uuid(_ number: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", number)
    }

    private func assertSorted(_ value: JSONValue) {
        switch value {
        case .object(let fields):
            XCTAssertEqual(fields.keys.sorted(), Array(fields.keys).sorted())
            let encoded = JSONWire.encodeString(value)
            XCTAssertFalse(encoded.contains(": "))
            fields.values.forEach(assertSorted)
        case .array(let items):
            items.forEach(assertSorted)
        default:
            break
        }
    }
}

final class MemoryCOS: ObjectTransport {
    var objects: [String: Data] = [:]
    var requests: [ObjectRequest] = []

    func execute(_ request: ObjectRequest) throws -> ObjectResponse {
        requests.append(request)
        switch request.method {
        case "GET":
            if request.path == "/" {
                if request.query["versioning"] != nil {
                    return ObjectResponse(status: 200, body: Data("<VersioningConfiguration/>".utf8))
                }
                let prefix = request.query["prefix"] ?? ""
                let keys = objects.keys.filter { $0.hasPrefix(prefix) }.sorted()
                let body = "<ListBucketResult><Name>example-1234567890</Name>"
                    + keys.map { "<Contents><Key>\($0)</Key></Contents>" }.joined()
                    + "<IsTruncated>false</IsTruncated></ListBucketResult>"
                return ObjectResponse(status: 200, body: Data(body.utf8))
            }
            let key = String(request.path.dropFirst())
            guard let data = objects[key] else { return ObjectResponse(status: 404) }
            return ObjectResponse(status: 200, headers: ["Content-Length": String(data.count)], body: data)
        case "HEAD":
            let key = String(request.path.dropFirst())
            guard let data = objects[key] else { return ObjectResponse(status: 404) }
            return ObjectResponse(status: 200, headers: [
                "Content-Length": String(data.count),
                "x-cos-meta-sha256": Digest.sha256Hex(data),
                "ETag": "not-a-file-hash",
            ])
        case "PUT":
            let key = String(request.path.dropFirst())
            if objects[key] != nil { return ObjectResponse(status: 409, headers: ["ETag": "not-a-file-hash"]) }
            // Small fixtures only; production transport streams bodyFileURL with URLSession.
            objects[key] = try request.bodyFileURL.map { try Data(contentsOf: $0) } ?? request.body
            return ObjectResponse(status: 200)
        default:
            return ObjectResponse(status: 405)
        }
    }
}
