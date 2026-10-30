import Foundation
import Security

/// A narrow SecItem seam: tests supply an in-memory implementation and never touch the Keychain.
struct KeychainOperations {
    var copyMatching: ([String: Any]) -> (status: OSStatus, data: Data?)
    var update: ([String: Any], [String: Any]) -> OSStatus
    var add: ([String: Any]) -> OSStatus
    var delete: ([String: Any]) -> OSStatus

    static let live = KeychainOperations(
        copyMatching: { query in
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item as? Data)
        },
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        delete: { SecItemDelete($0 as CFDictionary) }
    )
}

/// Stores the entire credential set in one atomic Keychain item. Failed writes never delete the existing item.
final class AtomicCredentialStore {
    static let account = "credentials-v1"
    private let operations: KeychainOperations
    private let lock = NSRecursiveLock()

    private struct Blob: Codable {
        var version: Int
        var secretID: String
        var secretKey: String
        var sessionToken: String?
        var expiresAt: Int64?
    }

    init(operations: KeychainOperations) { self.operations = operations }

    func save(_ credentials: StorageCredentials) throws {
        lock.lock(); defer { lock.unlock() }
        guard credentials.isValid else { throw CosFailure(.configuration) }
        let data = try JSONEncoder().encode(Blob(version: 2, secretID: credentials.secretID, secretKey: credentials.secretKey,
                                                  sessionToken: credentials.sessionToken, expiresAt: credentials.expiresAt))
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let query = baseQuery(account: Self.account)
        var status = operations.update(query, attributes)
        if status == errSecItemNotFound {
            let item = query.merging(attributes) { _, new in new }
            status = operations.add(item)
            // Another writer may have inserted the item between update and add.
            if status == errSecDuplicateItem { status = operations.update(query, attributes) }
        }
        guard status == errSecSuccess else { throw CosFailure(.secureStorage) }
        // Cleanup is best effort after the atomic commit. The blob is always authoritative,
        // including if the system temporarily refuses removal of an obsolete legacy item.
        for account in ["secretID", "secretKey"] { _ = operations.delete(baseQuery(account: account)) }
    }

    func load() throws -> StorageCredentials? {
        lock.lock(); defer { lock.unlock() }
        if let data = try read(account: Self.account) {
            guard let blob = try? JSONDecoder().decode(Blob.self, from: data), [1, 2].contains(blob.version) else {
                throw CosFailure(.secureStorage)
            }
            let credentials = StorageCredentials(secretID: blob.secretID, secretKey: blob.secretKey,
                                                 sessionToken: blob.sessionToken, expiresAt: blob.expiresAt)
            guard credentials.isValid else { throw CosFailure(.secureStorage) }
            return credentials
        }
        let identifier = try read(account: "secretID")
        let key = try read(account: "secretKey")
        switch (identifier, key) {
        case (nil, nil): return nil
        case let (identifier?, key?):
            guard let identifier = String(data: identifier, encoding: .utf8),
                  let key = String(data: key, encoding: .utf8) else { throw CosFailure(.secureStorage) }
            let credentials = StorageCredentials(secretID: identifier, secretKey: key)
            guard credentials.isValid else { throw CosFailure(.secureStorage) }
            // A failed migration throws and leaves both old fields intact. It never reports
            // "no credentials" for unreadable, locked, partial, or unsupported stored data.
            try save(credentials)
            return credentials
        default: throw CosFailure(.secureStorage)
        }
    }

    /// Explicit disconnect only; failed reads/writes never use this destructive operation.
    func delete() {
        lock.lock(); defer { lock.unlock() }
        for account in [Self.account, "secretID", "secretKey"] { _ = operations.delete(baseQuery(account: account)) }
    }

    private func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let result = operations.copyMatching(query)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess, let data = result.data else { throw CosFailure(.secureStorage) }
        return data
    }

    private func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: CredentialStoreContract.keychainService,
         kSecAttrAccount as String: account]
    }
}

enum KeychainStore {
    private static let storage = AtomicCredentialStore(operations: .live)
    static func save(_ credentials: StorageCredentials) throws { try storage.save(credentials) }
    static func load() throws -> StorageCredentials? { try storage.load() }
    static func delete() { storage.delete() }
}
