import Foundation

/// Published legacy v1 identities depend on this namespace. Never change it after publication.
public enum V1Ids {
    public static let namespace = "6F0F3B0E-6B2F-5C55-9E57-0D365A7D0001"
    private static let pattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#

    public static func map(kind: String, localID: String) throws -> String {
        guard kind == "record" || kind == "asset" || kind == "resource" else {
            throw ContractError(path: "id", message: "Unsupported v1 identity kind.")
        }
        let stripped = (kind == "record" && localID.hasPrefix("rec-")) ? String(localID.dropFirst(4)) : localID
        if stripped.range(of: pattern, options: .regularExpression) != nil {
            return stripped.uppercased()
        }
        return try legacyID(kind: kind, localID: localID)
    }

    public static func legacyID(kind: String, localID: String) throws -> String {
        guard kind == "record" || kind == "asset" || kind == "resource" else {
            throw ContractError(path: "id", message: "Unsupported v1 identity kind.")
        }
        if localID.range(of: pattern, options: .regularExpression) != nil {
            throw ContractError(path: "id", message: "Canonical UUIDs must be uploaded directly.")
        }
        return uuidV5(namespace: namespace, name: "\(kind):\(localID)").uppercased()
    }

    public static func canonical(_ value: String, path: String) throws -> String {
        guard value.range(of: pattern, options: .regularExpression) != nil, UUID(uuidString: value) != nil else {
            throw ContractError(path: path, message: "Expected a UUID.")
        }
        return value.uppercased()
    }

    /// RFC 4122 version 5. The returned text is lowercase.
    public static func uuidV5(namespace: String, name: String) -> String {
        let prefix = uuidBytes(namespace)
        var digest = Digest.sha1(prefix + Array(name.utf8))
        digest[6] = (digest[6] & 0x0f) | 0x50
        digest[8] = (digest[8] & 0x3f) | 0x80
        return format(Array(digest.prefix(16)), upper: false)
    }

    static func uuidBytes(_ value: String) -> [UInt8] {
        let hex = value.replacingOccurrences(of: "-", with: "")
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    static func format(_ bytes: [UInt8], upper: Bool) -> String {
        let hex = bytes.map { String(format: upper ? "%02X" : "%02x", $0) }.joined()
        let cuts = [8, 12, 16, 20]
        var out = ""
        for (offset, character) in hex.enumerated() {
            if cuts.contains(offset) { out.append("-") }
            out.append(character)
        }
        return out
    }
}
