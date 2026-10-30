import Foundation

public enum ParentIdentity: String, Codable, CaseIterable, Equatable {
    case dad
    case mom

    public var label: String { self == .dad ? "爸爸" : "妈妈" }
    public var folder: String { rawValue }
    public var prefix: String { "life/v1/\(folder)/" }
    public var other: ParentIdentity { self == .dad ? .mom : .dad }

    public init?(folder: String) {
        switch folder {
        case "dad": self = .dad
        case "mom": self = .mom
        default: return nil
        }
    }
}

/// Keychain service owned by DaysWith. It must stay distinct from any ootd365 service.
public enum CredentialStoreContract {
    public static let keychainService = "com.henrypann.jinbao365.credentials"
    public static let bundleIdentifier = "com.henrypann.jinbao365"
    public static let displayName = "DaysWith"
}

public struct StorageCredentials: Equatable, CustomStringConvertible {
    public let secretID: String
    public let secretKey: String
    public let sessionToken: String?
    /// Unix seconds. A missing value lets COS enforce the token expiry.
    public let expiresAt: Int64?

    public init(secretID: String, secretKey: String, sessionToken: String? = nil, expiresAt: Int64? = nil) {
        self.secretID = secretID
        self.secretKey = secretKey
        self.sessionToken = sessionToken
        self.expiresAt = expiresAt
    }

    public var isValid: Bool {
        Self.validID(secretID) && Self.validKey(secretKey)
            && (sessionToken.map(Self.validSessionToken) ?? true)
            && (expiresAt.map { $0 > 0 } ?? true)
    }

    public static func validSessionToken(_ value: String) -> Bool {
        // STS tokens are opaque header values, often longer than access keys.
        // Printable ASCII excludes CR/LF, whitespace, DEL and Unicode controls.
        (1...16_384).contains(value.utf8.count)
            && value.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }
    public var description: String { "StorageCredentials(redacted)" }

    public static func validID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{1,1024}$"#, options: .regularExpression) != nil
    }

    public static func validKey(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_+\/=-]{1,1024}$"#, options: .regularExpression) != nil
    }
}

public struct StorageConfiguration: Equatable {
    public var bucket: String
    public var region: String
    public var prefix: String

    public init(bucket: String = "", region: String = "ap-shanghai", prefix: String = "life/v1/") {
        self.bucket = bucket
        self.region = region
        self.prefix = prefix
    }

    public var host: String {
        "\(bucket).cos.\(region).myqcloud.com"
    }

    public func validate() throws {
        guard bucket.range(of: #"^[a-z0-9][a-z0-9-]{1,48}-[0-9]{5,20}$"#, options: .regularExpression) != nil else {
            throw ContractError(path: "configuration.bucket", message: "请检查存储桶和地域代码。")
        }
        guard region.range(of: #"^[a-z]{2}-[a-z][a-z0-9-]{1,40}$"#, options: .regularExpression) != nil else {
            throw ContractError(path: "configuration.region", message: "请检查存储桶和地域代码。")
        }
        try V1Layout.validatePrefix(prefix)
    }
}

/// Multi-device layout shared with Android 2.2.6.
public enum V1Layout {
    public static let testRoot = "life/v1/test/"
    private static let uuid = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#

    public static func identityRoot(parent: ParentIdentity, test: Bool) -> String {
        test ? testRoot : parent.prefix
    }

    public static func chainPrefix(parent: ParentIdentity, deviceID: String, test: Bool) throws -> String {
        guard deviceID.range(of: uuid, options: .regularExpression) != nil else {
            throw ContractError(path: "deviceID", message: "Invalid device id")
        }
        return identityRoot(parent: parent, test: test) + deviceID.lowercased() + "/"
    }

    public static func isDeviceSegment(_ value: String) -> Bool {
        value.range(of: uuid, options: .regularExpression) != nil
    }

    /// Device chains share the identity root's objects/. Legacy roots keep their own.
    public static func objectRoot(prefix: String) -> String {
        let parts = prefix.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let trimmed = prefix.hasSuffix("/") ? Array(parts.dropLast()) : parts
        if trimmed.count >= 2, let last = trimmed.last, isDeviceSegment(last) {
            return trimmed.dropLast().joined(separator: "/") + "/"
        }
        return prefix
    }

    public static func objectKey(prefix: String, sha256: String) -> String {
        objectRoot(prefix: prefix) + "objects/\(sha256.prefix(2))/\(sha256)"
    }

    public static func owns(owner: ParentIdentity, prefix: String) -> Bool {
        prefix == owner.prefix || objectRoot(prefix: prefix) == owner.prefix || objectRoot(prefix: prefix) == testRoot
    }

    /// 忽略名单：`objects/`、只有快照没有提交的目录，以及身份根以外的键，都不是一条提交链。
    public static func chainsUnder(root: String, keys: [String]) -> [String] {
        var found: [String] = []
        for key in keys {
            guard key.hasPrefix(root) else { continue }
            let rest = String(key.dropFirst(root.count))
            let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let chain: String?
            if parts.first == "commits" {
                chain = root
            } else if parts.count >= 3, let first = parts.first, isDeviceSegment(first), parts[1] == "commits" {
                chain = root + first + "/"
            } else {
                chain = nil
            }
            if let chain, !found.contains(chain) { found.append(chain) }
        }
        return found.sorted()
    }

    public static func validatePrefix(_ prefix: String) throws {
        let parts = prefix.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let body = prefix.hasSuffix("/") ? Array(parts.dropLast()) : parts
        let segmentsOK = prefix.hasSuffix("/") && !prefix.hasPrefix("/") && body.allSatisfy { segment in
            !segment.isEmpty && segment != "." && segment != ".."
                && segment.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
        }
        guard (1...256).contains(prefix.count), segmentsOK else {
            throw ContractError(path: "configuration.prefix", message: "The backup configuration is invalid.")
        }
    }

    public static func isLegacyRoot(_ prefix: String) -> Bool {
        prefix == ParentIdentity.dad.prefix || prefix == ParentIdentity.mom.prefix
    }
}
