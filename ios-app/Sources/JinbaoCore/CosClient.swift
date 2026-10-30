import Foundation
import CryptoKit
import Darwin

public struct ObjectRequest: Equatable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data
    public var bodyFileURL: URL?
    public var responseLimit: Int
    public var responseFileURL: URL?

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data(),
                bodyFileURL: URL? = nil, responseLimit: Int = 32 * 1024 * 1024, responseFileURL: URL? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.bodyFileURL = bodyFileURL
        self.responseLimit = responseLimit
        self.responseFileURL = responseFileURL
    }
}

public struct ObjectResponse: Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol ObjectTransport {
    func execute(_ request: ObjectRequest) throws -> ObjectResponse
}

public enum ConnectionFailure: Equatable {
    case permission
    case invalidSecretID
    case expiredCredentials
    case signature
    case network
    case timeout
    case contentMismatch
    case configuration
    case secureStorage
    case conflict
    case notFound
    case unsafeVersioning

    public var message: String {
        switch self {
        case .permission: return "云存储权限不足，请检查两个家长文件夹的读取权限和本机文件夹的写入权限。"
        case .invalidSecretID: return "密钥编号无法识别，请核对后重试。"
        case .expiredCredentials: return "密钥已过期，请重新填写。"
        case .signature: return "密钥或签名校验失败，请检查密钥和手机时间。"
        case .network: return "暂时无法连接云存储，请检查网络后重试。"
        case .timeout: return "连接超时，请检查网络后重试。"
        case .contentMismatch: return "云端内容校验失败，请检查存储设置。"
        case .configuration: return "请检查存储桶和地域代码。"
        case .secureStorage: return "暂时无法安全保存密钥，请解锁手机后重试。"
        case .conflict: return "云端已有不同内容，DaysWith 不会覆盖它。"
        case .notFound: return "云端还没有这一份记录。"
        case .unsafeVersioning: return "无法确认云存储的防覆盖状态。请检查版本控制查询权限；已启用或暂停版本控制的存储桶不能备份。"
        }
    }
}

public struct CosFailure: Error, Equatable {
    public let failure: ConnectionFailure
    public init(_ failure: ConnectionFailure) { self.failure = failure }
}

enum COSEncoding {
    static func encode(_ value: String, preserveSlash: Bool = false) -> String {
        var out = ""
        for byte in value.utf8 {
            let unreserved = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
                || byte == 45 || byte == 95 || byte == 46 || byte == 126 || (preserveSlash && byte == 47)
            if unreserved {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}

public struct COSSigner: CustomStringConvertible {
    private let credentials: StorageCredentials
    public init(credentials: StorageCredentials) { self.credentials = credentials }
    public var description: String { "COSSigner(redacted)" }

    public func authorization(method: String, path: String, query: [String: String] = [:],
                              headers: [String: String], now: Int64, validFor: Int64 = 900) throws -> String {
        let verb = method.uppercased()
        guard credentials.isValid, ["GET", "HEAD", "PUT", "POST"].contains(verb) else {
            throw CosFailure(.configuration)
        }
        guard path.hasPrefix("/"), now >= 60, validFor >= 1, validFor <= 3600 else {
            throw CosFailure(.configuration)
        }
        var signingHeaders = headers
        if let token = credentials.sessionToken {
            let existing = signingHeaders.filter { $0.key.caseInsensitiveCompare("x-cos-security-token") == .orderedSame }
            guard existing.count <= 1, existing.values.allSatisfy({ $0 == token }) else { throw CosFailure(.configuration) }
            if existing.isEmpty { signingHeaders["x-cos-security-token"] = token }
        }
        let lifetime: Int64
        if let expiry = credentials.expiresAt {
            guard expiry > now else { throw CosFailure(.expiredCredentials) }
            lifetime = min(validFor, expiry - now)
        } else { lifetime = validFor }
        let (end, overflow) = now.addingReportingOverflow(lifetime)
        guard !overflow else { throw CosFailure(.configuration) }
        let (queryList, parameters) = try canonical(query)
        let (headerList, httpHeaders) = try canonical(signingHeaders)
        let keyTime = "\(now - 60);\(end)"
        let signKey = hmacHex(key: Data(credentials.secretKey.utf8), message: Data(keyTime.utf8))
        let httpString = "\(verb.lowercased())\n\(path)\n\(parameters)\n\(httpHeaders)\n"
        let digest = Digest.hex(Digest.sha1(Array(httpString.utf8)))
        let signature = hmacHex(key: Data(signKey.utf8), message: Data("sha1\n\(keyTime)\n\(digest)\n".utf8))
        return "q-sign-algorithm=sha1&q-ak=\(credentials.secretID)&q-sign-time=\(keyTime)&q-key-time=\(keyTime)"
            + "&q-header-list=\(headerList)&q-url-param-list=\(queryList)&q-signature=\(signature)"
    }

    private func canonical(_ fields: [String: String]) throws -> (String, String) {
        var normalized: [String: String] = [:]
        for (key, value) in fields {
            if key.isEmpty || key.unicodeScalars.contains(where: { $0.value < 32 })
                || value.unicodeScalars.contains(where: { $0.value < 32 }) {
                throw CosFailure(.configuration)
            }
            let name = COSEncoding.encode(key).lowercased()
            if normalized[name] != nil { throw CosFailure(.configuration) }
            normalized[name] = COSEncoding.encode(value)
        }
        let keys = normalized.keys.sorted()
        let pairs = keys.map { "\($0)=\(normalized[$0]!)" }.joined(separator: "&")
        return (keys.joined(separator: ";"), pairs)
    }

    private func hmacHex(key: Data, message: Data) -> String {
        Digest.hex(Digest.hmacSHA1(key: [UInt8](key), message: [UInt8](message)))
    }
}

/// Immutable COS writes. There is no delete method: cloud objects are never removed by this app.
public final class CosClient: CustomStringConvertible {
    public let configuration: StorageConfiguration
    private let signer: COSSigner
    private let sessionToken: String?
    private let transport: ObjectTransport
    private let now: () -> Int64
    public var description: String { "CosClient(redacted)" }

    public init(configuration: StorageConfiguration, credentials: StorageCredentials, transport: ObjectTransport, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }) throws {
        try configuration.validate()
        guard credentials.isValid else { throw CosFailure(.configuration) }
        self.configuration = configuration
        self.signer = COSSigner(credentials: credentials)
        self.sessionToken = credentials.sessionToken
        self.transport = transport
        self.now = now
    }

    public func list(prefix: String) throws -> [String] {
        try validateKey(prefix, allowPrefix: true)
        var marker = ""
        var seen = Set<String>()
        var keys: [String] = []
        for _ in 0..<10_000 {
            var query = ["prefix": prefix, "max-keys": "1000"]
            if !marker.isEmpty { query["marker"] = marker }
            let xml = try xmlRequest(method: "GET", key: nil, query: query, root: "ListBucketResult")
            let page = try xml.children("Contents").map { node -> String in
                guard let key = node.value("Key"), key.hasPrefix(prefix) else { throw CosFailure(.contentMismatch) }
                try validateKey(key)
                return key
            }
            if keys.count + page.count > 100_000 { throw CosFailure(.contentMismatch) }
            keys.append(contentsOf: page)
            guard xml.truncated() else { return keys }
            guard let next = xml.value("NextMarker") ?? page.last, !next.isEmpty, next != marker, seen.insert(next).inserted else {
                throw CosFailure(.contentMismatch)
            }
            marker = next
        }
        throw CosFailure(.contentMismatch)
    }

    public func head(key: String) throws -> ObjectHead? {
        try validateKey(key)
        let response = try send(method: "HEAD", key: key)
        if response.status == 404 { return nil }
        try interpretStatus(response, query: [:])
        guard let length = response.header("Content-Length").flatMap(Int64.init) else { throw CosFailure(.contentMismatch) }
        let hash = response.header("x-cos-meta-sha256").flatMap { value in
            value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil ? value : nil
        }
        return ObjectHead(byteCount: length, sha256: hash)
    }

    public func get(key: String, responseLimit: Int = 32 * 1024 * 1024) throws -> Data {
        try validateKey(key)
        guard (1...JSONWire.metadataLimit).contains(responseLimit) else { throw CosFailure(.configuration) }
        let response = try send(method: "GET", key: key, responseLimit: responseLimit)
        try interpretStatus(response, query: [:])
        return response.body
    }

    /// Download to a private staging file, validate the complete bytes, then publish the cache.
    /// Uses bounded streaming transport; no full media Data allocation.
    public func getFile(key: String, destination: URL, byteCount: Int64, sha256: String) throws {
        try validateKey(key)
        guard destination.isFileURL, (1...V1Validator.maxResourceBytes).contains(byteCount),
              sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw CosFailure(.contentMismatch)
        }
        guard let existing = try head(key: key), existing.byteCount == byteCount,
              existing.sha256 == nil || existing.sha256 == sha256 else { throw CosFailure(.contentMismatch) }
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(".download-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: partial) }
        let response = try send(method: "GET", key: key, responseLimit: Int(byteCount), responseFileURL: partial)
        try interpretStatus(response, query: [:])
        guard response.status == 200 else { throw CosFailure(.contentMismatch) }
        let actual = try Digest.sha256File(partial, maximumBytes: byteCount)
        guard actual.byteCount == byteCount, actual.hash == sha256 else { throw CosFailure(.contentMismatch) }
        if FileManager.default.fileExists(atPath: destination.path) {
            let cached = try Digest.sha256File(destination, maximumBytes: byteCount)
            guard cached.byteCount == byteCount, cached.hash == sha256 else { throw CosFailure(.contentMismatch) }
        } else {
            try FileManager.default.moveItem(at: partial, to: destination)
        }
    }

    /// COS forbid-overwrite is ineffective in versioned or versioning-suspended buckets.
    /// Only a valid, empty configuration proves versioning was never enabled.
    public func verifyImmutableWritesAllowed() throws {
        do {
            let response = try send(method: "GET", key: nil, query: ["versioning": ""], responseLimit: 64 * 1024)
            try interpretStatus(response, query: ["versioning": ""])
            guard VersioningSafetyParser.isNeverEnabled(response.body) else { throw CosFailure(.unsafeVersioning) }
        } catch let error as CosFailure where [.permission, .invalidSecretID, .expiredCredentials, .signature, .network, .timeout].contains(error.failure) {
            throw error
        } catch {
            throw CosFailure(.unsafeVersioning)
        }
    }

    /// Metadata-only interface; use putImmutableFile for media.
    public func put(key: String, body: Data, contentType: String) throws {
        try putImmutable(key: key, body: body, contentType: contentType)
    }

    /// HEAD avoids resending existing bytes; the conditional PUT protects the HEAD/PUT race.
    /// ETag is intentionally unread: a multipart ETag is not a file hash.
    public func putImmutable(key: String, body: Data, contentType: String) throws {
        try validateKey(key)
        if body.count > JSONWire.metadataLimit { throw CosFailure(.contentMismatch) }
        let hash = Digest.sha256Hex(body)
        try verifyImmutableWritesAllowed()
        if try matchingExistingObject(key: key, byteCount: Int64(body.count), sha256: hash) { return }
        var headers = immutableHeaders(contentType: contentType, sha256: hash)
        headers["Content-Length"] = String(body.count)
        let response = try send(method: "PUT", key: key, headers: headers, body: body)
        try acceptImmutableResponse(response, key: key, byteCount: Int64(body.count), sha256: hash)
    }

    /// Snapshot and hash before signing: replacing the original afterwards cannot alter the upload.
    /// Only the private staging directory is removed; the user's original is never changed.
    public func putImmutableFile(key: String, fileURL: URL, byteCount: Int64, sha256: String, contentType: String) throws {
        try validateKey(key)
        guard (1...V1Validator.maxResourceBytes).contains(byteCount),
              sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              key == V1Layout.objectKey(prefix: configuration.prefix, sha256: sha256) else {
            throw CosFailure(.contentMismatch)
        }
        let staged = try StagedMedia(source: fileURL, byteCount: byteCount, sha256: sha256)
        defer { staged.remove() }
        try verifyImmutableWritesAllowed()
        if try matchingExistingObject(key: key, byteCount: byteCount, sha256: sha256) { return }
        var headers = immutableHeaders(contentType: contentType, sha256: sha256)
        headers["Content-Length"] = String(byteCount)
        let response = try send(method: "PUT", key: key, headers: headers, bodyFileURL: staged.url)
        try acceptImmutableResponse(response, key: key, byteCount: byteCount, sha256: sha256)
    }

    private func matchingExistingObject(key: String, byteCount: Int64, sha256: String) throws -> Bool {
        guard let existing = try head(key: key) else { return false }
        guard existing.byteCount == byteCount, existing.sha256 == sha256 else { throw CosFailure(.conflict) }
        return true
    }

    private func acceptImmutableResponse(_ response: ObjectResponse, key: String, byteCount: Int64, sha256: String) throws {
        if response.status == 409 || response.status == 412 {
            guard try matchingExistingObject(key: key, byteCount: byteCount, sha256: sha256) else {
                throw CosFailure(.conflict)
            }
            return
        }
        try interpretStatus(response, query: [:])
    }

    private func xmlRequest(method: String, key: String?, query: [String: String], root: String) throws -> CosXML {
        let response = try send(method: method, key: key, query: query)
        if response.body.contains(Data("<!DOCTYPE".utf8)) || response.body.contains(Data("<!ENTITY".utf8)) {
            throw CosFailure(.contentMismatch)
        }
        if !(200...299).contains(response.status) {
            try interpretStatus(response, query: query)
        }
        let xml = try CosXML.parse(response.body)
        if xml.name == "Error" { try interpretStatus(response, query: query) }
        guard xml.name == root else { throw CosFailure(.contentMismatch) }
        return xml
    }

    private func send(method: String, key: String?, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data(),
                      bodyFileURL: URL? = nil, responseLimit: Int = 32 * 1024 * 1024, responseFileURL: URL? = nil) throws -> ObjectResponse {
        guard ["GET", "HEAD", "PUT", "POST"].contains(method) else { throw CosFailure(.configuration) }
        let path = key.map { "/\($0)" } ?? "/"
        var signing = headers
        signing["Host"] = configuration.host
        signing["Accept-Encoding"] = "identity"
        if let sessionToken { signing["x-cos-security-token"] = sessionToken }
        let authorization = try signer.authorization(method: method, path: path, query: query, headers: signing, now: now(),
                                                     validFor: bodyFileURL == nil ? 900 : 3600)
        signing["Authorization"] = authorization
        let response = try transport.execute(ObjectRequest(method: method, path: path, query: query, headers: signing,
                                                           body: body, bodyFileURL: bodyFileURL, responseLimit: responseLimit, responseFileURL: responseFileURL))
        guard response.body.count <= (responseFileURL == nil ? responseLimit : 64 * 1024) else { throw CosFailure(.contentMismatch) }
        return response
    }

    private func immutableHeaders(contentType: String, sha256: String) -> [String: String] {
        [
            "Content-Type": contentType,
            "x-cos-forbid-overwrite": "true",
            "x-cos-server-side-encryption": "AES256",
            "x-cos-meta-sha256": sha256,
        ]
    }

    private func interpretStatus(_ response: ObjectResponse, query: [String: String]) throws {
        if (200...299).contains(response.status) { return }
        let code = errorCode(response.body)
        switch code {
        case "InvalidAccessKeyId", "AccessKeyIdNotExist": throw CosFailure(.invalidSecretID)
        case "ExpiredToken": throw CosFailure(.expiredCredentials)
        case "SignatureDoesNotMatch", "RequestTimeTooSkewed": throw CosFailure(.signature)
        default:
            if response.status == 401 || response.status == 403 { throw CosFailure(.permission) }
            if response.status == 404 { throw CosFailure(.notFound) }
            throw CosFailure(.network)
        }
    }

    private func errorCode(_ body: Data) -> String? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        guard let start = text.range(of: "<Code>"), let end = text.range(of: "</Code>") else { return nil }
        let code = String(text[start.upperBound..<end.lowerBound])
        guard code.range(of: #"^[A-Za-z]+$"#, options: .regularExpression) != nil else { return nil }
        return code
    }

    private func validateKey(_ key: String, allowPrefix: Bool = false) throws {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let checked = (allowPrefix && parts.last == "") ? Array(parts.dropLast()) : parts
        let objects = V1Layout.objectRoot(prefix: configuration.prefix) + "objects/"
        let allowed = key.hasPrefix(configuration.prefix) || key.hasPrefix(objects)
        let controls = key.unicodeScalars.contains { $0.value < 32 }
        let badSegment = checked.contains { $0.isEmpty || $0 == "." || $0 == ".." }
        if !allowed || (!allowPrefix && key == configuration.prefix) || key.utf8.count > 1024 || key.hasPrefix("/")
            || key.contains("\\") || key.contains("%") || controls || badSegment {
            throw CosFailure(.configuration)
        }
    }
}

public struct ObjectHead: Equatable {
    public let byteCount: Int64
    public let sha256: String?
    public init(byteCount: Int64, sha256: String?) {
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

struct CosXML {
    var name: String
    var text: String
    var children: [CosXML]

    func children(_ name: String) -> [CosXML] { children.filter { $0.name == name } }
    func value(_ name: String) -> String? { children.first { $0.name == name }?.text }
    func truncated() -> Bool { value("IsTruncated") == "true" }

    static func parse(_ data: Data) throws -> CosXML {
        guard let text = String(data: data, encoding: .utf8), !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else {
            throw CosFailure(.contentMismatch)
        }
        var parser = XMLParser(text: text)
        try parser.skipPrologue()
        guard let node = try parser.parseNode() else { throw CosFailure(.contentMismatch) }
        return node
    }
}

private struct XMLParser {
    let text: String
    var index: String.Index

    init(text: String) {
        self.text = text
        index = text.startIndex
    }

    mutating func skipPrologue() throws {
        while true {
            skipUntilTag()
            if text[index...].hasPrefix("<?") {
                guard let end = text.range(of: "?>", range: index..<text.endIndex) else { throw CosFailure(.contentMismatch) }
                index = end.upperBound
                continue
            }
            if text[index...].hasPrefix("<!--") {
                guard let end = text.range(of: "-->", range: index..<text.endIndex) else { throw CosFailure(.contentMismatch) }
                index = end.upperBound
                continue
            }
            return
        }
    }

    mutating func parseNode() throws -> CosXML? {
        skipUntilTag()
        guard peek("<") else { return nil }
        if text[index...].hasPrefix("</") || text[index...].hasPrefix("<?") || text[index...].hasPrefix("<!--") {
            return nil
        }
        index = text.index(after: index)
        let name = try readName()
        try skipAttributes()
        if consume("/>") {
            return CosXML(name: name, text: "", children: [])
        }
        guard consume(">") else { throw CosFailure(.contentMismatch) }
        var children: [CosXML] = []
        var body = ""
        while index < text.endIndex {
            if text[index...].hasPrefix("</") {
                index = text.index(index, offsetBy: 2)
                let closing = try readName()
                guard closing == name, consume(">") else { throw CosFailure(.contentMismatch) }
                return CosXML(name: name, text: unescape(body), children: children)
            }
            if peek("<") {
                if let child = try parseNode() { children.append(child) }
                else { break }
            } else {
                body.append(text[index])
                index = text.index(after: index)
            }
        }
        throw CosFailure(.contentMismatch)
    }

    private mutating func skipAttributes() throws {
        while index < text.endIndex {
            if text[index...].hasPrefix("/>") || text[index] == ">" { return }
            let character = text[index]
            if character == "\"" || character == "'" {
                index = text.index(after: index)
                while index < text.endIndex, text[index] != character { index = text.index(after: index) }
                if index < text.endIndex { index = text.index(after: index) }
                continue
            }
            index = text.index(after: index)
        }
        throw CosFailure(.contentMismatch)
    }

    private mutating func skipUntilTag() {
        while index < text.endIndex, text[index] != "<" { index = text.index(after: index) }
    }

    private mutating func readName() throws -> String {
        let start = index
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber || character == ":" || character == "_" || character == "-" {
                index = text.index(after: index)
            } else { break }
        }
        if start == index { throw CosFailure(.contentMismatch) }
        return String(text[start..<index])
    }

    private func peek(_ prefix: String) -> Bool { text[index...].hasPrefix(prefix) }
    private func peek(_ character: Character) -> Bool { index < text.endIndex && text[index] == character }
    private func peekWhitespace() -> Bool {
        guard index < text.endIndex else { return false }
        return text[index] == " " || text[index] == "\n" || text[index] == "\r" || text[index] == "\t"
    }

    private mutating func consume(_ token: String) -> Bool {
        guard text[index...].hasPrefix(token) else { return false }
        index = text.index(index, offsetBy: token.count)
        return true
    }

    private func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The legacy list parser is intentionally not used for this security gate: a partial or
/// unfamiliar document must never be interpreted as a disabled versioning setting.
private final class VersioningSafetyParser: NSObject, XMLParserDelegate {
    private var depth = 0
    private var rootSeen = false
    private var invalid = false

    static func isNeverEnabled(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8),
              !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { return false }
        let delegate = VersioningSafetyParser()
        let parser = Foundation.XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        return parser.parse() && delegate.rootSeen && delegate.depth == 0 && !delegate.invalid
    }

    func parser(_ parser: Foundation.XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if depth != 0 || rootSeen || elementName != "VersioningConfiguration" { invalid = true }
        if attributeDict.contains(where: { $0.key != "xmlns" || $0.value != "http://s3.amazonaws.com/doc/2006-03-01/" }) {
            invalid = true
        }
        rootSeen = true
        depth += 1
    }

    func parser(_ parser: Foundation.XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        depth -= 1
    }

    func parser(_ parser: Foundation.XMLParser, foundCharacters string: String) {
        if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { invalid = true }
    }

    func parser(_ parser: Foundation.XMLParser, foundCDATA CDATABlock: Data) { invalid = true }
    func parser(_ parser: Foundation.XMLParser, parseErrorOccurred parseError: Error) { invalid = true }
}

private struct StagedMedia {
    let directory: URL
    let url: URL

    init(source: URL, byteCount: Int64, sha256: String) throws {
        guard source.isFileURL else { throw CosFailure(.configuration) }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("jinbao-upload-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent("body")
        do {
            // Do not follow a swapped symlink or block opening a FIFO disguised as media.
            let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw CosFailure(.contentMismatch) }
            let sourceHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? sourceHandle.close() }
            var before = stat()
            guard fstat(sourceHandle.fileDescriptor, &before) == 0,
                  (before.st_mode & S_IFMT) == S_IFREG, before.st_size == byteCount else { throw CosFailure(.contentMismatch) }
            guard fileManager.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CosFailure(.contentMismatch)
            }
            let destination = try FileHandle(forWritingTo: target)
            defer { try? destination.close() }
            var digest = SHA256()
            var copied: Int64 = 0
            var finished = false
            while !finished {
                try autoreleasepool {
                    guard let chunk = try sourceHandle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { finished = true; return }
                    copied += Int64(chunk.count)
                    guard copied <= byteCount else { throw CosFailure(.contentMismatch) }
                    digest.update(data: chunk)
                    try destination.write(contentsOf: chunk)
                }
            }
            var after = stat()
            guard fstat(sourceHandle.fileDescriptor, &after) == 0,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                  copied == byteCount, Digest.hex(Array(digest.finalize())) == sha256 else { throw CosFailure(.contentMismatch) }
            try destination.synchronize()
            try destination.close()
            try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        self.directory = directory
        self.url = target
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
