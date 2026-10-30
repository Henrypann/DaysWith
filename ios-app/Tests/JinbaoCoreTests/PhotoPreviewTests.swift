import XCTest
@testable import JinbaoCore

final class PhotoPreviewTests: XCTestCase {
    private let device = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    func testAllLocalPhotosRemainInOrderAfterArchiveRecovery() throws {
        var session = AppSession(deviceID: device, testBuild: true, identity: .dad,
                                 link: .placeholder(bucket: "example-1234567890", region: "ap-shanghai"))
        session.beginDraft(now: 1)
        for index in 1...3 {
            try session.addAsset(LocalAsset(id: "asset-\(index)", kind: "photo", capturedAt: 0, provenance: "verifiedOriginal", resources: [
                LocalResource(id: "original-\(index)", role: "photo", contentType: "image/jpeg", originalFilename: "original.jpg",
                              byteCount: 1, sha256: String(repeating: "a", count: 64), relativePath: "media/\(index)/original.jpg"),
                LocalResource(id: "preview-\(index)", role: "preview", contentType: "image/jpeg", originalFilename: "preview.jpg",
                              byteCount: 1, sha256: String(repeating: "b", count: 64), relativePath: "media/\(index)/preview.jpg"),
            ]))
        }
        _ = try session.commitDraft(now: 2)
        let recovered = try JSONDecoder().decode(PersistedArchive.self, from: JSONEncoder().encode(PersistedArchive(session: session))).session()
        let photos = try XCTUnwrap(recovered.timelineEntries().first).photos
        XCTAssertEqual(photos.map(\.id), ["asset-1", "asset-2", "asset-3"])
        XCTAssertEqual(photos.map(\.localPath), ["media/1/preview.jpg", "media/2/preview.jpg", "media/3/preview.jpg"])
        XCTAssertEqual(photos.map(\.fullSizePath), ["media/1/original.jpg", "media/2/original.jpg", "media/3/original.jpg"])
    }

    func testLegacyAndDeviceManifestsProduceEveryOwnedPreview() throws {
        for parent in ParentIdentity.allCases {
            for prefix in [parent.prefix, parent.prefix + device + "/"] {
                let bytes = Data("synthetic preview".utf8)
                let digest = Digest.sha256Hex(bytes)
                let key = V1Layout.objectKey(prefix: prefix, sha256: digest)
                let manifest = V1Manifest(
                    moments: [V1Moment(id: "record", note: "two photos", occurredAt: 1, createdAt: 1, updatedAt: 1, assetIDs: ["second", "first"])],
                    assets: ["first", "second"].map { V1Asset(id: $0, kind: "photo", capturedAt: 0, resourceIDs: [$0 + "-preview"]) },
                    resources: ["first", "second"].map {
                        V1Resource(id: $0 + "-preview", assetID: $0, role: "preview", contentType: "image/jpeg",
                                   originalFilename: "preview.jpg", byteCount: Int64(bytes.count), sha256: digest, objectKey: key)
                    })
                let remote = try XCTUnwrap(ArchiveMerge.merge([ChainSnapshot(parent: parent, prefix: prefix, writer: device, createdAt: 1, manifest: manifest)]).first)
                XCTAssertEqual(remote.previews.map(\.assetID), ["second", "first"])
                XCTAssertTrue(remote.previews.allSatisfy { $0.parent == parent && $0.chainPrefix == prefix })
                for preview in remote.previews { XCTAssertNoThrow(try preview.validate(data: bytes)) }
                var session = AppSession(deviceID: device, testBuild: true)
                session.remote = [remote]
                XCTAssertEqual(session.timelineEntries().first?.photos.map(\.id), ["second", "first"])
            }
        }
    }

    func testPreviewRejectsForeignObjectsAndUnboundedOrChangedBytes() throws {
        let bytes = Data("preview".utf8)
        let hash = Digest.sha256Hex(bytes)
        let valid = RemotePreview(assetID: "asset", parent: .mom, chainPrefix: "life/v1/mom/",
                                  objectKey: V1Layout.objectKey(prefix: "life/v1/mom/", sha256: hash), sha256: hash,
                                  byteCount: Int64(bytes.count), contentType: "image/jpeg")
        XCTAssertNoThrow(try valid.validate(data: bytes))
        var bad = valid
        bad.objectKey = V1Layout.objectKey(prefix: "life/v1/dad/", sha256: hash)
        XCTAssertThrowsError(try bad.validate())
        bad = valid; bad.chainPrefix = "life/v1/mom/../../"
        XCTAssertThrowsError(try bad.validate())
        bad = valid; bad.chainPrefix = "life/v1/test/"
        XCTAssertThrowsError(try bad.validate())
        bad = valid; bad.objectKey = "https://example.com/photo.jpg"
        XCTAssertThrowsError(try bad.validate())
        bad = valid; bad.byteCount = RemotePreview.maximumBytes + 1
        XCTAssertThrowsError(try bad.validate())
        bad = valid; bad.contentType = "text/html"
        XCTAssertThrowsError(try bad.validate())
        XCTAssertThrowsError(try valid.validate(data: Data("changed".utf8)))
        XCTAssertThrowsError(try valid.validate(data: Data()))
    }

    func testOlderPersistedRemoteDoesNotTrustBareObjectKeys() throws {
        let legacy = #"{"id":"remote:mom:record:1","parent":"mom","title":"old","note":"","occurredAt":1,"readOnly":false,"mediaCount":2,"previewObjectKey":"https://example.com/private.jpg","future":true}"#
        let old = try JSONDecoder().decode(RemoteMoment.self, from: Data(legacy.utf8))
        XCTAssertTrue(old.readOnly)
        XCTAssertEqual(old.mediaCount, 2)
        XCTAssertTrue(old.previews.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(RemoteMoment.self, from: JSONEncoder().encode(old)), old)
    }
}
