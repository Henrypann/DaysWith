import XCTest
@testable import JinbaoCore

final class MigrationWireBoundsTests: XCTestCase {
    private let device = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let now: Int64 = 1_792_382_400_000
    private var session: AppSession {
        AppSession(deviceID: device, testBuild: true, identity: .dad,
                   link: .verified(bucket: "example-1234567890", region: "ap-shanghai"))
    }

    private func manifest(kind: String = "photo", roles: [String] = ["photo", "preview"], filename: String = "image.jpg") throws -> (String, V1Manifest) {
        var state = session
        state.beginDraft(now: now)
        let resources = roles.enumerated().map { index, role -> LocalResource in
            let bytes = Data("synthetic-\(index)".utf8)
            return LocalResource(id: "resource-\(index)", role: role,
                                 contentType: ["video", "livePhotoVideo"].contains(role) ? "video/quicktime" : "image/jpeg",
                                 originalFilename: filename, byteCount: Int64(bytes.count), sha256: Digest.sha256Hex(bytes),
                                 relativePath: "media/\(index)")
        }
        try state.addAssets([LocalAsset(id: "asset", kind: kind, capturedAt: now, provenance: "systemProvided", resources: resources)])
        _ = try state.commitDraft(now: now)
        let result = try BackupPlan.manifest(session: state, now: now)
        return (result.prefix, result.manifest)
    }

    func testFilenameTruncationUsesUTF16AndDoesNotSplitEmojiOrCombinedCharacters() {
        let exact = String(repeating: "😀", count: 127) + "a"
        XCTAssertEqual(exact.utf16.count, 255)
        XCTAssertEqual(BackupPlan.safeFilename(exact), exact)
        let overflow = String(repeating: "😀", count: 128) + ".jpg"
        let result = BackupPlan.safeFilename(overflow)
        XCTAssertEqual(result, String(repeating: "😀", count: 127))
        XCTAssertEqual(result.utf16.count, 254)
        let family = "👨‍👩‍👧‍👦"
        let prefix = String(repeating: "a", count: 250)
        XCTAssertEqual(BackupPlan.safeFilename(prefix + family), prefix)
        let combined = "e\u{0301}"
        XCTAssertEqual(BackupPlan.safeFilename(String(repeating: "a", count: 254) + combined), String(repeating: "a", count: 254))
        let hugeCluster = "a" + String(repeating: "\u{0301}", count: 300)
        XCTAssertEqual(BackupPlan.safeFilename(hugeCluster), "import")
        XCTAssertEqual(BackupPlan.safeFilename(""), "import")
    }

    func testPublishedLongEmojiFilenameIsReadableByAndroidUTF16Contract() throws {
        let (prefix, value) = try manifest(filename: String(repeating: "😀", count: 200) + ".jpg")
        XCTAssertTrue(value.resources.allSatisfy { (1...255).contains($0.originalFilename.utf16.count) })
        XCTAssertNoThrow(try V1Validator.validate(manifest: value, prefix: prefix))
        XCTAssertEqual(try V1Json.decodeManifest(V1Json.encodeManifest(value)), value)
    }

    func testIncomingFilenameRejectsOneUTF16UnitOverAndroidLimit() throws {
        let (prefix, good) = try manifest()
        var value = good
        value.resources[0].originalFilename = String(repeating: "😀", count: 127) + "a"
        XCTAssertNoThrow(try V1Validator.validate(manifest: value, prefix: prefix))
        value.resources[0].originalFilename += "b"
        XCTAssertEqual(value.resources[0].originalFilename.count, 129)
        XCTAssertThrowsError(try V1Validator.validate(manifest: value, prefix: prefix))
    }

    func testAnniversaryTitleUTF16BoundaryAppliesToLocalSaveAndWire() throws {
        var state = session
        let goodTitle = String(repeating: "😀", count: 50)
        let item = try state.saveAnniversary(title: goodTitle, date: "--10-19", now: now)
        let good = try BackupPlan.manifest(session: state, now: now)
        XCTAssertEqual(good.manifest.anniversaries.first?.title.utf16.count, 100)
        XCTAssertThrowsError(try state.saveAnniversary(id: item.id, title: goodTitle + "a", date: "--10-19", now: now))
        XCTAssertEqual(state.anniversaries.first?.title, goodTitle)
        var invalid = good.manifest
        invalid.anniversaries[0].title += "a"
        XCTAssertThrowsError(try V1Validator.validate(manifest: invalid, prefix: good.prefix))
        XCTAssertNoThrow(try V1Validator.validate(manifest: good.manifest, prefix: good.prefix))
    }

    func testMomentTitleAndNoteAlreadyMatchAndroidUTF16Bounds() throws {
        var state = session
        state.beginDraft(now: now)
        state.updateDraft(title: String(repeating: "😀", count: 100), note: String(repeating: "😀", count: 5000))
        let valid = try state.commitDraft(now: now)
        try state.beginEdit(id: valid.id, now: now)
        state.updateDraft(title: valid.title + "a", note: valid.note)
        XCTAssertThrowsError(try state.commitDraft(now: now))
        state.updateDraft(title: valid.title, note: valid.note + "a")
        XCTAssertThrowsError(try state.commitDraft(now: now))
        let plan = try BackupPlan.manifest(session: state, now: now)
        var invalid = plan.manifest
        invalid.moments[0].note += "a"
        XCTAssertThrowsError(try V1Validator.validate(manifest: invalid, prefix: plan.prefix))
    }

    func testDuplicateOriginalOrPreviewRolesRejectedForEveryMediaKind() throws {
        let cases: [(String, [String])] = [
            ("photo", ["photo", "preview"]),
            ("video", ["video", "preview"]),
            ("motionPhoto", ["motionPhoto", "preview"]),
            ("livePhoto", ["livePhotoImage", "livePhotoVideo", "preview"])
        ]
        for (kind, roles) in cases {
            XCTAssertNoThrow(try manifest(kind: kind, roles: roles), kind)
            XCTAssertThrowsError(try manifest(kind: kind, roles: roles + [roles[0]]), kind)
            XCTAssertThrowsError(try manifest(kind: kind, roles: roles + ["preview"]), kind)
        }
    }

    func testDefaultAnniversaryCrossDeviceCopiesResolveOnceAndLocalTombstoneWins() throws {
        var state = session
        let builtin = AnniversaryCalendar.defaults[0]
        let prefix = "life/v1/dad/" + device.lowercased() + "/"
        state.remoteAnniversaries = [
            RemoteAnniversary(recordID: builtin.id, owner: .mom, title: "妈妈版本", date: builtin.date,
                              sourcePrefix: "life/v1/mom/", updatedAt: now + 1),
            RemoteAnniversary(recordID: builtin.id, owner: .dad, title: "爸爸其他设备版本", date: builtin.date,
                              sourcePrefix: prefix, updatedAt: now)
        ]
        XCTAssertEqual(state.anniversaryEntries().count, 3)
        let resolved = try XCTUnwrap(state.anniversaryEntries().first { $0.isDefault && $0.title.contains("其他设备") })
        XCTAssertEqual(resolved.owner, .dad)
        XCTAssertTrue(resolved.readOnly)
        state.anniversaries.append(LocalAnniversary(id: builtin.id, owner: .dad, title: "本机版本", date: builtin.date,
                                                   updatedAt: now - 1, uploadEligibility: .localOnly))
        XCTAssertEqual(state.anniversaryEntries().count, 3)
        XCTAssertEqual(state.anniversaryEntries().first { $0.id == builtin.id }?.title, "本机版本")
        try state.deleteAnniversary(id: builtin.id, now: now + 2)
        XCTAssertEqual(state.anniversaryEntries().count, 2)
        XCTAssertFalse(state.anniversaryEntries().contains { $0.title.contains("版本") })
        XCTAssertTrue(try state.backupAnniversaries().isEmpty)
    }

    func testRemoteResourceUsesSameFilenameBoundsAsWire() throws {
        let bytes = Data("image".utf8)
        let hash = Digest.sha256Hex(bytes)
        var resource = RemoteResource(id: "resource", assetID: "asset", role: "photo", parent: .dad,
                                      chainPrefix: "life/v1/dad/", objectKey: V1Layout.objectKey(prefix: "life/v1/dad/", sha256: hash),
                                      sha256: hash, byteCount: Int64(bytes.count), contentType: "image/jpeg",
                                      originalFilename: String(repeating: "😀", count: 127) + "a")
        XCTAssertNoThrow(try resource.validate())
        resource.originalFilename += "b"
        XCTAssertThrowsError(try resource.validate())
    }
}
