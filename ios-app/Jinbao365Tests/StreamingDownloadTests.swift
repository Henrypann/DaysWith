import XCTest
import Foundation
import CryptoKit
@testable import Jinbao365

/// URLProtocol intercepts every request in this suite. No COS or public network is contacted.
final class StreamingDownloadTests: XCTestCase {
    private var folder: URL!
    private var host: String!
    private var configuration: URLSessionConfiguration!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("stream-download-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        host = "fixture-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") + "-12345.cos.ap-shanghai.myqcloud.com"
        configuration = .ephemeral
        configuration.protocolClasses = [DownloadFixtureProtocol.self]
    }

    override func tearDownWithError() throws {
        DownloadFixtureProtocol.remove(host: host)
        try? FileManager.default.removeItem(at: folder)
    }

    func test33MiBOriginalStreamsToFileAndVerifiesExactHashAndLength() throws {
        let chunk = Data(repeating: 0x5A, count: 1024 * 1024)
        let byteCount = Int64(chunk.count * 33)
        var digest = SHA256()
        for _ in 0..<33 { digest.update(data: chunk) }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let seen = RequestObservations()
        DownloadFixtureProtocol.install(host: host) { fixture in
            seen.append(fixture.request)
            if fixture.request.httpMethod == "HEAD" {
                fixture.respond(headers: ["Content-Length": String(byteCount), "x-cos-meta-sha256": hash])
            } else {
                fixture.respond(headers: ["Content-Length": String(byteCount)], chunks: Array(repeating: chunk, count: 33))
            }
        }
        let target = folder.appendingPathComponent("cache/original.mov")
        try makeClient().getFile(key: "life/v1/test/objects/" + hash, destination: target, byteCount: byteCount, sha256: hash)
        let actual = try Digest.sha256File(target)
        XCTAssertEqual(actual.hash, hash)
        XCTAssertEqual(actual.byteCount, byteCount)
        XCTAssertEqual(seen.requests.map(\.httpMethod), ["HEAD", "GET"])
        XCTAssertEqual(seen.requests.last?.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertNil(seen.requests.last?.httpBody)
        XCTAssertNotNil(seen.requests.last?.value(forHTTPHeaderField: "Authorization"))
        assertNoPartialFiles(in: target.deletingLastPathComponent())
    }

    func testIncorrectHashNeverPublishesCache() throws {
        let expected = Data("expected media".utf8)
        let delivered = Data("tampered media".utf8)
        XCTAssertEqual(expected.count, delivered.count)
        let hash = Digest.sha256Hex(expected)
        DownloadFixtureProtocol.install(host: host) { fixture in
            let headers = ["Content-Length": String(expected.count), "x-cos-meta-sha256": hash]
            fixture.respond(headers: headers, chunks: fixture.request.httpMethod == "HEAD" ? [] : [delivered])
        }
        let target = folder.appendingPathComponent("original.jpg")
        XCTAssertThrowsError(try makeClient().getFile(key: "life/v1/test/objects/" + hash, destination: target, byteCount: Int64(expected.count), sha256: hash))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        assertNoPartialFiles(in: folder)
    }

    func testShortBodyAndAdvertisedOversizeCannotPublishCache() throws {
        let expected = Data(repeating: 0x21, count: 1024)
        let hash = Digest.sha256Hex(expected)
        for mode in ["short", "oversize"] {
            DownloadFixtureProtocol.install(host: host) { fixture in
                if fixture.request.httpMethod == "HEAD" {
                    fixture.respond(headers: ["Content-Length": "1024", "x-cos-meta-sha256": hash])
                } else if mode == "short" {
                    fixture.respond(headers: ["Content-Length": "1024"], chunks: [Data(expected.prefix(512))])
                } else {
                    fixture.respond(headers: ["Content-Length": "1025"], chunks: [expected, Data([0x21])])
                }
            }
            let target = folder.appendingPathComponent(mode + ".jpg")
            XCTAssertThrowsError(try makeClient().getFile(key: "life/v1/test/objects/" + hash, destination: target, byteCount: 1024, sha256: hash))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            assertNoPartialFiles(in: folder)
        }
    }

    func testChunkedOversizeIsBoundedWithoutContentLength() throws {
        let expected = Data(repeating: 0x31, count: 1024)
        let hash = Digest.sha256Hex(expected)
        DownloadFixtureProtocol.install(host: host) { fixture in
            if fixture.request.httpMethod == "HEAD" {
                fixture.respond(headers: ["Content-Length": "1024", "x-cos-meta-sha256": hash])
            } else {
                fixture.respond(headers: [:], chunks: [expected, Data([0x31])])
            }
        }
        let target = folder.appendingPathComponent("oversize.jpg")
        XCTAssertThrowsError(try makeClient().getFile(key: "life/v1/test/objects/" + hash, destination: target, byteCount: 1024, sha256: hash))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        assertNoPartialFiles(in: folder)
    }

    func testMalformedHeadStopsBeforeDownloadAndPreservesExistingCache() throws {
        let bytes = Data("unchanged cache".utf8)
        let target = folder.appendingPathComponent("existing.jpg")
        try bytes.write(to: target)
        let hash = Digest.sha256Hex(bytes)
        let seen = RequestObservations()
        DownloadFixtureProtocol.install(host: host) { fixture in
            seen.append(fixture.request)
            fixture.respond(headers: ["Content-Length": "malformed", "x-cos-meta-sha256": hash])
        }
        XCTAssertThrowsError(try makeClient().getFile(key: "life/v1/test/objects/" + hash, destination: target, byteCount: Int64(bytes.count), sha256: hash))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(seen.requests.map(\.httpMethod), ["HEAD"])
        assertNoPartialFiles(in: folder)
    }

    func testRedirectNeverForwardsAuthorizationToAnotherHost() throws {
        let seen = RequestObservations()
        DownloadFixtureProtocol.install(host: host) { fixture in
            seen.append(fixture.request)
            let redirected = URLRequest(url: URL(string: "https://untrusted.invalid/stolen")!)
            let response = HTTPURLResponse(url: fixture.request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": redirected.url!.absoluteString])!
            fixture.client?.urlProtocol(fixture, wasRedirectedTo: redirected, redirectResponse: response)
            fixture.client?.urlProtocolDidFinishLoading(fixture)
        }
        let transport = URLSessionTransport(configuration: configuration)
        let response = try? transport.execute(ObjectRequest(method: "GET", path: "/fixture", headers: ["Host": host, "Authorization": "synthetic-signed-token"], responseLimit: 1024))
        XCTAssertNotEqual(response?.status, 200)
        XCTAssertEqual(seen.requests.count, 1)
        XCTAssertEqual(seen.requests.first?.url?.host, host)
        XCTAssertFalse(DownloadFixtureProtocol.unhandledHosts.contains("untrusted.invalid"))
    }

    private func makeClient() throws -> CosClient {
        let suffix = ".cos.ap-shanghai.myqcloud.com"
        let bucket = String(host.dropLast(suffix.count))
        return try CosClient(configuration: StorageConfiguration(bucket: bucket, region: "ap-shanghai", prefix: "life/v1/test/"),
                             credentials: StorageCredentials(secretID: "FIXTURE_ID", secretKey: "FIXTURE_SECRET"),
                             transport: URLSessionTransport(configuration: configuration), now: { 1_800_000_000 })
    }

    private func assertNoPartialFiles(in directory: URL, file: StaticString = #filePath, line: UInt = #line) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(names.contains(where: { $0.hasPrefix(".download-") }), "A failed download left a partial cache file", file: file, line: line)
    }
}

private final class RequestObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ request: URLRequest) { lock.lock(); storage.append(request); lock.unlock() }
}

private final class DownloadFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handlers: [String: (DownloadFixtureProtocol) -> Void] = [:]
    private static var missedHosts: [String] = []
    static var unhandledHosts: [String] { lock.lock(); defer { lock.unlock() }; return missedHosts }
    static func install(host: String, handler: @escaping (DownloadFixtureProtocol) -> Void) {
        lock.lock(); handlers[host] = handler; lock.unlock()
    }
    static func remove(host: String) { lock.lock(); handlers.removeValue(forKey: host); lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let host = request.url?.host ?? ""
        let handler = Self.handlers[host]
        if handler == nil { Self.missedHosts.append(host) }
        Self.lock.unlock()
        guard let handler else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        handler(self)
    }
    override func stopLoading() {}
    func respond(status: Int = 200, headers: [String: String], chunks: [Data] = []) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
