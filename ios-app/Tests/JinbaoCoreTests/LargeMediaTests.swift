import XCTest
@testable import JinbaoCore

final class LargeMediaTests: XCTestCase {
    private let prefix = "life/v1/test/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/"
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("jinbao-media-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    func testFileLargerThanMetadataLimitUploadsWithoutDataBodyAndCleansSnapshot() throws {
        let source = try fixture(mebibytes: 33)
        let digest = try Digest.sha256File(source)
        let transport = FileCOS()
        let writer = try client(transport)
        let key = V1Layout.objectKey(prefix: prefix, sha256: digest.hash)
        try writer.putImmutableFile(key: key, fileURL: source, byteCount: digest.byteCount, sha256: digest.hash, contentType: "video/mp4")
        let put = try XCTUnwrap(transport.requests.first { $0.method == "PUT" })
        XCTAssertTrue(put.body.isEmpty)
        XCTAssertNotNil(put.bodyFileURL)
        XCTAssertEqual(put.headers["Content-Length"], String(33 * 1024 * 1024))
        XCTAssertEqual(put.headers["x-cos-meta-sha256"], digest.hash)
        XCTAssertEqual(put.headers["x-cos-forbid-overwrite"], "true")
        XCTAssertEqual(put.headers["x-cos-server-side-encryption"], "AES256")
        XCTAssertTrue(put.headers["Authorization"]?.contains("content-length") == true)
        XCTAssertEqual(transport.fileHeads[key], ObjectHead(byteCount: digest.byteCount, sha256: digest.hash))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        assertStagingRemoved(transport)
        // Identical content is a HEAD hit; no second PUT, regardless of multipart ETag.
        try writer.putImmutableFile(key: key, fileURL: source, byteCount: digest.byteCount, sha256: digest.hash, contentType: "video/mp4")
        XCTAssertEqual(transport.requests.filter { $0.method == "PUT" }.count, 1)
    }

    func testMetadataStillRejectsMoreThan32MiBBeforeNetwork() throws {
        let transport = FileCOS()
        XCTAssertThrowsError(try client(transport).putImmutable(key: prefix + "snapshots/large.json",
                            body: Data(count: JSONWire.metadataLimit + 1), contentType: "application/json"))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testMissingWrongLengthWrongHashAndOutsideObjectKeyMakeNoRequests() throws {
        let source = try fixture(bytes: Data("synthetic".utf8))
        let digest = try Digest.sha256File(source)
        let transport = FileCOS()
        let writer = try client(transport)
        let key = V1Layout.objectKey(prefix: prefix, sha256: digest.hash)
        XCTAssertThrowsError(try writer.putImmutableFile(key: key, fileURL: temporary.appendingPathComponent("missing"),
                            byteCount: digest.byteCount, sha256: digest.hash, contentType: "image/jpeg"))
        for count in [Int64(0), digest.byteCount + 1, V1Validator.maxResourceBytes + 1] {
            XCTAssertThrowsError(try writer.putImmutableFile(key: key, fileURL: source, byteCount: count, sha256: digest.hash, contentType: "image/jpeg"))
        }
        let wrongHash = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try writer.putImmutableFile(key: V1Layout.objectKey(prefix: prefix, sha256: wrongHash), fileURL: source,
                            byteCount: digest.byteCount, sha256: wrongHash, contentType: "image/jpeg"))
        XCTAssertThrowsError(try writer.putImmutableFile(key: "life/v1/dad/objects/" + digest.hash, fileURL: source,
                            byteCount: digest.byteCount, sha256: digest.hash, contentType: "image/jpeg"))
        XCTAssertThrowsError(try writer.putImmutableFile(key: prefix + "snapshots/x.json", fileURL: source,
                            byteCount: digest.byteCount, sha256: digest.hash, contentType: "image/jpeg"))
        let symlink = temporary.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        XCTAssertThrowsError(try writer.putImmutableFile(key: key, fileURL: symlink,
                            byteCount: digest.byteCount, sha256: digest.hash, contentType: "image/jpeg"))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testSourceReplacementAfterHashCannotChangeUpload() throws {
        let original = Data("original synthetic content".utf8)
        let source = try fixture(bytes: original)
        let digest = try Digest.sha256File(source)
        let transport = FileCOS()
        transport.beforeFileUpload = { staging in
            XCTAssertNotEqual(staging, source)
            let attributes = try FileManager.default.attributesOfItem(atPath: staging.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o400)
            try Data("replacement".utf8).write(to: source, options: .atomic)
        }
        let key = V1Layout.objectKey(prefix: prefix, sha256: digest.hash)
        try client(transport).putImmutableFile(key: key, fileURL: source, byteCount: digest.byteCount, sha256: digest.hash, contentType: "image/jpeg")
        XCTAssertEqual(transport.fileHeads[key]?.sha256, Digest.sha256Hex(original))
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
        assertStagingRemoved(transport)
    }

    func testFailedUploadCleansOnlyStagingAndDoesNotPublishSnapshot() throws {
        let source = try fixture(bytes: Data("photo".utf8))
        let preview = try fixture(bytes: Data("preview".utf8))
        let transport = FileCOS()
        transport.beforeFileUpload = { _ in throw CosFailure(.timeout) }
        let session = try session(photo: source, preview: preview)
        let urls = try fileMap(session: session, photo: source, preview: preview)
        XCTAssertThrowsError(try BackupPublisher.publish(client: client(transport), session: session, fileURLs: urls,
                            now: 1_700_000_000_000, requestID: UUID().uuidString))
        XCTAssertFalse(transport.requests.contains { $0.method == "PUT" && $0.path.contains("/snapshots/") })
        XCTAssertFalse(transport.requests.contains { $0.method == "DELETE" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path))
        assertStagingRemoved(transport)
    }

    func testExistingDifferentOrUnverifiableObjectNeverGetsPut() throws {
        let source = try fixture(bytes: Data("content".utf8))
        let digest = try Digest.sha256File(source)
        let key = V1Layout.objectKey(prefix: prefix, sha256: digest.hash)
        for head in [ObjectHead(byteCount: digest.byteCount, sha256: nil),
                     ObjectHead(byteCount: digest.byteCount + 1, sha256: digest.hash),
                     ObjectHead(byteCount: digest.byteCount, sha256: String(repeating: "a", count: 64))] {
            let transport = FileCOS()
            transport.fileHeads[key] = head
            XCTAssertThrowsError(try client(transport).putImmutableFile(key: key, fileURL: source, byteCount: digest.byteCount,
                                sha256: digest.hash, contentType: "image/jpeg")) { error in
                XCTAssertEqual(error as? CosFailure, CosFailure(.conflict))
            }
            XCTAssertFalse(transport.requests.contains { $0.method == "PUT" })
        }
    }

    func testHeadPutRaceAcceptsOnlyMatchingConflict() throws {
        let source = try fixture(bytes: Data("race synthetic".utf8))
        let digest = try Digest.sha256File(source)
        let key = V1Layout.objectKey(prefix: prefix, sha256: digest.hash)
        for status in [409, 412] {
            for matching in [true, false] {
                let transport = FileCOS()
                transport.raceStatus = status
                transport.raceHead = ObjectHead(byteCount: digest.byteCount, sha256: matching ? digest.hash : nil)
                let operation = {
                    try self.client(transport).putImmutableFile(key: key, fileURL: source, byteCount: digest.byteCount,
                                                               sha256: digest.hash, contentType: "image/jpeg")
                }
                if matching { XCTAssertNoThrow(try operation()) }
                else { XCTAssertThrowsError(try operation()) }
                XCTAssertEqual(transport.requests.filter { $0.method == "PUT" }.count, 1)
                XCTAssertEqual(transport.requests.filter { $0.method == "HEAD" }.count, 2)
                assertStagingRemoved(transport)
            }
        }
    }

    func testVersioningGateAcceptsOnlyStrictEmptyConfiguration() throws {
        let acceptable = ["<VersioningConfiguration/>",
                          "<?xml version=\"1.0\" encoding=\"UTF-8\"?><VersioningConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">\n </VersioningConfiguration>"]
        for xml in acceptable {
            let transport = FileCOS()
            transport.versioningBody = Data(xml.utf8)
            XCTAssertNoThrow(try client(transport).verifyImmutableWritesAllowed())
        }
        let rejected = ["", "<VersioningConfiguration>", "<VersioningConfiguration/><unexpected/>",
                        "<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>",
                        "<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>",
                        "<VersioningConfiguration><Status>Disabled</Status></VersioningConfiguration>",
                        "<VersioningConfiguration><Status/></VersioningConfiguration>",
                        "<VersioningConfiguration><Status></Status><Status/></VersioningConfiguration>",
                        "<VersioningConfiguration><Future/></VersioningConfiguration>",
                        "<VersioningConfiguration future=\"true\"/>",
                        "<VersioningConfiguration xmlns=\"https://unexpected.example\"/>",
                        "<VersioningConfiguration>Suspended</VersioningConfiguration>",
                        "<VersioningConfiguration><![CDATA[ ]]></VersioningConfiguration>",
                        "<!DOCTYPE VersioningConfiguration><VersioningConfiguration/>",
                        "<ListBucketResult/>"]
        for xml in rejected {
            let transport = FileCOS()
            transport.versioningBody = Data(xml.utf8)
            XCTAssertThrowsError(try client(transport).putImmutable(key: prefix + "snapshots/check.json", body: Data("{}".utf8), contentType: "application/json"), xml) { error in
                XCTAssertEqual(error as? CosFailure, CosFailure(.unsafeVersioning), xml)
            }
            XCTAssertFalse(transport.requests.contains { $0.method == "PUT" }, xml)
        }
    }

    func testDeniedVersioningStopsPublishBeforeAnyPutAndEveryPublishRechecks() throws {
        let session = textSession(eligibility: .testOnly)
        let transport = FileCOS()
        let writer = try client(transport)
        _ = try BackupPublisher.publish(client: writer, session: session, fileURLs: [:], now: 1_700_000_000_000, requestID: UUID().uuidString)
        let writes = transport.requests.filter { $0.method == "PUT" }.count
        transport.versioningStatus = 403
        XCTAssertThrowsError(try BackupPublisher.publish(client: writer, session: session, fileURLs: [:], now: 1_700_000_000_001, requestID: UUID().uuidString)) { error in
            XCTAssertEqual(error as? CosFailure, CosFailure(.permission))
        }
        XCTAssertEqual(transport.requests.filter { $0.method == "PUT" }.count, writes)
        XCTAssertEqual(transport.requests.last?.query, ["versioning": ""])
    }

    func testFilePublisherFiltersLocalOnlyAndPreservesObjectsSnapshotCommitOrder() throws {
        let source = try fixture(mebibytes: 33)
        let preview = try fixture(bytes: Data("synthetic preview".utf8))
        var session = try session(photo: source, preview: preview)
        session.moments.append(textSession(eligibility: .localOnly).moments[0])
        // A bogus local-only resource must not be opened or uploaded.
        var privateMoment = session.moments[0]
        let privateAsset = LocalAsset(id: "private-asset", kind: "photo", capturedAt: 0, provenance: nil, resources: [])
        privateMoment = LocalMoment(id: "private-photo", title: "private", note: "", occurredAt: 1_700_000_000_000,
                                    createdAt: 1_700_000_000_000, updatedAt: 1_700_000_000_000, parent: .dad, assets: [privateAsset])
        session.moments.append(privateMoment)
        let transport = FileCOS()
        let writer = try client(transport)
        let urls = try fileMap(session: session, photo: source, preview: preview)
        let first = try BackupPublisher.publish(client: writer, session: session, fileURLs: urls, now: 1_700_000_000_000, requestID: UUID().uuidString)
        XCTAssertEqual(first.sequence, 1)
        let puts = transport.requests.filter { $0.method == "PUT" }
        XCTAssertEqual(puts.count, 4)
        XCTAssertTrue(puts.prefix(2).allSatisfy { $0.path.hasPrefix("/life/v1/test/objects/") && $0.bodyFileURL != nil && $0.body.isEmpty })
        XCTAssertTrue(puts[2].path.contains("/snapshots/"))
        XCTAssertTrue(puts[3].path.contains("/commits/"))
        XCTAssertTrue(puts.allSatisfy { $0.path.hasPrefix("/life/v1/test/") })
        XCTAssertFalse(String(decoding: puts[2].body, as: UTF8.self).contains("private"))
        XCTAssertFalse(transport.requests.contains { $0.method == "DELETE" })
        let second = try BackupPublisher.publish(client: writer, session: session, fileURLs: urls, now: 1_700_000_000_001, requestID: UUID().uuidString)
        XCTAssertEqual(second.sequence, 2)
        XCTAssertEqual(transport.requests.filter { $0.method == "PUT" }.count, 5)
        assertStagingRemoved(transport)
    }

    func testFilePublisherLocalOnlyMakesZeroRequestsAndDoesNotOpenFiles() throws {
        let transport = FileCOS()
        XCTAssertThrowsError(try BackupPublisher.publish(client: client(transport), session: textSession(eligibility: .localOnly),
                            fileURLs: ["unused": temporary.appendingPathComponent("missing")], now: 1_700_000_000_000, requestID: UUID().uuidString))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testResponseLimitIsPassedToTransportAndEnforcedForAnyTransport() throws {
        let transport = FileCOS()
        transport.memory.objects[prefix + "preview"] = Data(count: 9)
        let writer = try client(transport)
        XCTAssertThrowsError(try writer.get(key: prefix + "preview", responseLimit: 8))
        XCTAssertEqual(transport.requests.last?.responseLimit, 8)
        XCTAssertEqual(try writer.get(key: prefix + "preview", responseLimit: 9).count, 9)
        XCTAssertThrowsError(try writer.get(key: prefix + "preview", responseLimit: JSONWire.metadataLimit + 1))
    }

    private func client(_ transport: ObjectTransport) throws -> CosClient {
        try CosClient(configuration: StorageConfiguration(bucket: "example-1234567890", prefix: prefix),
                      credentials: StorageCredentials(secretID: "AKIDExample", secretKey: "ExampleSecretKey"), transport: transport)
    }

    private func fixture(bytes: Data) throws -> URL {
        let url = temporary.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        return url
    }

    private func fixture(mebibytes: Int) throws -> URL {
        let url = try fixture(bytes: Data())
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let block = Data(repeating: 0x5a, count: 1024 * 1024)
        for _ in 0..<mebibytes { try handle.write(contentsOf: block) }
        return url
    }

    private func textSession(eligibility: UploadEligibility) -> AppSession {
        AppSession(deviceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", testBuild: true, identity: .dad,
                   link: .verified(bucket: "example-1234567890", region: "ap-shanghai"),
                   moments: [LocalMoment(id: "text", title: "synthetic", note: "", occurredAt: 1_700_000_000_000,
                                         createdAt: 1_700_000_000_000, updatedAt: 1_700_000_000_000, parent: .dad,
                                         assets: [], uploadEligibility: eligibility)])
    }

    private func session(photo: URL, preview: URL) throws -> AppSession {
        var result = textSession(eligibility: .testOnly)
        let resources = try [("photo", photo), ("preview", preview)].map { role, url -> LocalResource in
            let digest = try Digest.sha256File(url)
            return LocalResource(id: role, role: role, contentType: "image/jpeg", originalFilename: role + ".jpg",
                                 byteCount: digest.byteCount, sha256: digest.hash, relativePath: role)
        }
        result.moments[0].assets = [LocalAsset(id: "asset", kind: "photo", capturedAt: 0,
                                              provenance: ImportProvenance.verifiedOriginal.rawValue, resources: resources)]
        return result
    }

    private func fileMap(session: AppSession, photo: URL, preview: URL) throws -> [String: URL] {
        Dictionary(uniqueKeysWithValues: try BackupPlan.uploads(session: session).map { ($0.objectKey, $0.relativePath == "photo" ? photo : preview) })
    }

    private func assertStagingRemoved(_ transport: FileCOS, file: StaticString = #filePath, line: UInt = #line) {
        for url in transport.stagedURLs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), file: file, line: line)
        }
    }
}

/// Large files are checked incrementally and represented by HEAD metadata, never retained as Data.
private final class FileCOS: ObjectTransport {
    let memory = MemoryCOS()
    var requests: [ObjectRequest] = []
    var fileHeads: [String: ObjectHead] = [:]
    var stagedURLs: [URL] = []
    var versioningStatus = 200
    var versioningBody = Data("<VersioningConfiguration/>".utf8)
    var beforeFileUpload: ((URL) throws -> Void)?
    var raceStatus: Int?
    var raceHead: ObjectHead?

    func execute(_ request: ObjectRequest) throws -> ObjectResponse {
        requests.append(request)
        let key = String(request.path.dropFirst())
        if request.method == "GET", request.query["versioning"] != nil {
            return ObjectResponse(status: versioningStatus, body: versioningBody)
        }
        if request.method == "HEAD", let head = fileHeads[key] {
            var headers = ["Content-Length": String(head.byteCount), "ETag": "multipart-not-sha256-9"]
            headers["x-cos-meta-sha256"] = head.sha256
            return ObjectResponse(status: 200, headers: headers)
        }
        if request.method == "PUT", let url = request.bodyFileURL {
            stagedURLs.append(url)
            try beforeFileUpload?(url)
            if let raceStatus {
                fileHeads[key] = raceHead
                return ObjectResponse(status: raceStatus)
            }
            let digest = try Digest.sha256File(url)
            guard String(digest.byteCount) == request.headers["Content-Length"], digest.hash == request.headers["x-cos-meta-sha256"] else {
                throw CosFailure(.contentMismatch)
            }
            fileHeads[key] = ObjectHead(byteCount: digest.byteCount, sha256: digest.hash)
            return ObjectResponse(status: 200)
        }
        return try memory.execute(request)
    }
}
