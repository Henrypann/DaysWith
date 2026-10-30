import XCTest
import Foundation
import Security
#if canImport(Jinbao365)
@testable import Jinbao365
#endif

/// Every SecItem operation is injected. No test invokes KeychainOperations.live.
final class KeychainStoreTests: XCTestCase {
    private let original = StorageCredentials(secretID: "AKIDSyntheticOriginal", secretKey: "SyntheticOriginalKey")
    private let replacement = StorageCredentials(secretID: "AKIDSyntheticReplacement", secretKey: "SyntheticReplacementKey")

    func testTemporaryCredentialsRoundTripAsOneBlobAndFailedReplacementPreservesEveryField() throws {
        let memory = MemoryKeychain()
        let store = AtomicCredentialStore(operations: memory.operations)
        let temporary = StorageCredentials(secretID: "AKIDSyntheticTemporary", secretKey: "SyntheticTemporaryKey",
                                           sessionToken: String(repeating: "SyntheticToken+/=", count: 128), expiresAt: 1_900_000_000)
        try store.save(temporary)
        XCTAssertEqual(try store.load(), temporary)
        let before = memory.items
        memory.resetTrace()
        memory.updateFailure = errSecInteractionNotAllowed
        XCTAssertThrowsError(try store.save(replacement))
        XCTAssertEqual(memory.items, before)
        XCTAssertFalse(memory.trace.contains { $0.hasPrefix("delete:") })
        XCTAssertEqual(try store.load(), temporary)
    }

    func testVersionOneBlobLoadsWithoutMigrationOrCredentialLoss() throws {
        let memory = MemoryKeychain()
        memory.items[AtomicCredentialStore.account] = Data(#"{"version":1,"secretID":"AKIDSyntheticOriginal","secretKey":"SyntheticOriginalKey"}"#.utf8)
        let before = memory.items
        let store = AtomicCredentialStore(operations: memory.operations)
        XCTAssertEqual(try store.load(), original)
        XCTAssertEqual(memory.items, before)
        XCTAssertEqual(memory.trace, ["read:" + AtomicCredentialStore.account])
        try store.save(StorageCredentials(secretID: replacement.secretID, secretKey: replacement.secretKey,
                                           sessionToken: "SyntheticToken", expiresAt: 1_900_000_000))
        XCTAssertEqual(try store.load()?.sessionToken, "SyntheticToken")
        XCTAssertEqual(try store.load()?.expiresAt, 1_900_000_000)
    }

    func testUpdateFailurePreservesPreviousBlobAndDoesNotDelete() throws {
        let memory = MemoryKeychain()
        let store = AtomicCredentialStore(operations: memory.operations)
        try store.save(original)
        let before = memory.items
        memory.resetTrace()
        memory.updateFailure = errSecInteractionNotAllowed
        XCTAssertThrowsError(try store.save(replacement))
        XCTAssertEqual(memory.items, before)
        XCTAssertEqual(memory.trace, ["update:" + AtomicCredentialStore.account])
        XCTAssertEqual(try store.load(), original)
    }

    func testAddFailurePreservesBothLegacyFields() throws {
        let memory = MemoryKeychain(legacy: original)
        let store = AtomicCredentialStore(operations: memory.operations)
        let before = memory.items
        memory.addFailure = errSecNotAvailable
        XCTAssertThrowsError(try store.save(replacement))
        XCTAssertEqual(memory.items, before)
        XCTAssertFalse(memory.trace.contains { $0.hasPrefix("delete:") })
    }

    func testFailedLegacyMigrationThrowsInsteadOfReturningNilAndRetainsLegacy() throws {
        let memory = MemoryKeychain(legacy: original)
        let store = AtomicCredentialStore(operations: memory.operations)
        let before = memory.items
        memory.addFailure = errSecInteractionNotAllowed
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual(($0 as? CosFailure)?.failure, .secureStorage) }
        XCTAssertEqual(memory.items, before)
        XCTAssertFalse(memory.trace.contains { $0.hasPrefix("delete:") })
        memory.addFailure = nil
        XCTAssertEqual(try store.load(), original)
    }

    func testSuccessfulMigrationCommitsOneBlobBeforeDeletingLegacyFields() throws {
        let memory = MemoryKeychain(legacy: original)
        let store = AtomicCredentialStore(operations: memory.operations)
        XCTAssertEqual(try store.load(), original)
        XCTAssertEqual(Set(memory.items.keys), [AtomicCredentialStore.account])
        let add = try XCTUnwrap(memory.trace.firstIndex(of: "add:" + AtomicCredentialStore.account))
        let deleteID = try XCTUnwrap(memory.trace.firstIndex(of: "delete:secretID"))
        let deleteKey = try XCTUnwrap(memory.trace.firstIndex(of: "delete:secretKey"))
        XCTAssertLessThan(add, deleteID)
        XCTAssertLessThan(add, deleteKey)
        XCTAssertEqual(memory.addedAccessible as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        memory.resetTrace()
        XCTAssertEqual(try store.load(), original)
        XCTAssertEqual(memory.trace, ["read:" + AtomicCredentialStore.account])
    }

    func testAtomicUpdateChangesBothFieldsInSingleOperation() throws {
        let memory = MemoryKeychain()
        let store = AtomicCredentialStore(operations: memory.operations)
        try store.save(original)
        memory.resetTrace()
        try store.save(replacement)
        XCTAssertEqual(memory.trace.filter { $0.hasPrefix("update:") }, ["update:" + AtomicCredentialStore.account])
        XCTAssertFalse(memory.trace.contains { $0.hasPrefix("add:") || $0 == "delete:" + AtomicCredentialStore.account })
        XCTAssertEqual(try store.load(), replacement)
    }

    func testReadFailureDoesNotFallBackToLegacyOrDeleteData() throws {
        let memory = MemoryKeychain(legacy: original)
        memory.readFailure = errSecInteractionNotAllowed
        let before = memory.items
        let store = AtomicCredentialStore(operations: memory.operations)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(memory.items, before)
        XCTAssertEqual(memory.trace, ["read:" + AtomicCredentialStore.account])
    }

    func testCorruptOrUnknownBlobFailsClosedAndPreservesLegacy() throws {
        for blob in [Data("corrupt".utf8), Data(#"{"version":999,"secretID":"SyntheticID","secretKey":"SyntheticKey"}"#.utf8)] {
            let memory = MemoryKeychain(legacy: original)
            memory.items[AtomicCredentialStore.account] = blob
            let before = memory.items
            let store = AtomicCredentialStore(operations: memory.operations)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(memory.items, before)
            XCTAssertEqual(memory.trace, ["read:" + AtomicCredentialStore.account])
        }
    }

    func testPartialLegacyNeverBecomesEmptyOrGetsDeleted() throws {
        let memory = MemoryKeychain()
        memory.items["secretID"] = Data(original.secretID.utf8)
        let before = memory.items
        let store = AtomicCredentialStore(operations: memory.operations)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(memory.items, before)
        XCTAssertFalse(memory.trace.contains { $0.hasPrefix("delete:") })
    }

    func testCompletelyMissingCredentialsReturnNilWithoutMutation() throws {
        let memory = MemoryKeychain()
        let store = AtomicCredentialStore(operations: memory.operations)
        XCTAssertNil(try store.load())
        XCTAssertTrue(memory.items.isEmpty)
        XCTAssertTrue(memory.trace.allSatisfy { $0.hasPrefix("read:") })
    }

    func testInvalidInputDoesNotTouchPreviousCredentials() throws {
        let memory = MemoryKeychain(legacy: original)
        let before = memory.items
        let store = AtomicCredentialStore(operations: memory.operations)
        XCTAssertThrowsError(try store.save(StorageCredentials(secretID: "", secretKey: "invalid")))
        XCTAssertTrue(memory.trace.isEmpty)
        XCTAssertEqual(memory.items, before)
    }

    func testDuplicateAddRaceRetriesAtomicUpdateWithoutDeletion() throws {
        let memory = MemoryKeychain()
        memory.duplicateOnAdd = true
        let store = AtomicCredentialStore(operations: memory.operations)
        try store.save(replacement)
        XCTAssertEqual(try store.load(), replacement)
        XCTAssertEqual(memory.trace.filter { $0.hasPrefix("update:") }.count, 2)
        XCTAssertFalse(memory.trace.contains("delete:" + AtomicCredentialStore.account))
    }

    func testFailedLegacyCleanupCannotInvalidateCommittedBlob() throws {
        let memory = MemoryKeychain(legacy: original)
        memory.deleteFailure = errSecInteractionNotAllowed
        let store = AtomicCredentialStore(operations: memory.operations)
        try store.save(replacement)
        XCTAssertNotNil(memory.items["secretID"])
        XCTAssertNotNil(memory.items["secretKey"])
        XCTAssertEqual(try store.load(), replacement)
    }
}

private final class MemoryKeychain {
    var items: [String: Data] = [:]
    var trace: [String] = []
    var updateFailure: OSStatus?
    var addFailure: OSStatus?
    var readFailure: OSStatus?
    var deleteFailure: OSStatus?
    var duplicateOnAdd = false
    var addedAccessible: Any?

    init(legacy: StorageCredentials? = nil) {
        if let legacy {
            items["secretID"] = Data(legacy.secretID.utf8)
            items["secretKey"] = Data(legacy.secretKey.utf8)
        }
    }
    func resetTrace() { trace = [] }
    private func account(_ query: [String: Any]) -> String { query[kSecAttrAccount as String] as! String }
    var operations: KeychainOperations {
        KeychainOperations(copyMatching: { [unowned self] query in
            let name = self.account(query); self.trace.append("read:" + name)
            if let failure = self.readFailure { return (failure, nil) }
            guard let data = self.items[name] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }, update: { [unowned self] query, attributes in
            let name = self.account(query); self.trace.append("update:" + name)
            if let failure = self.updateFailure { return failure }
            guard self.items[name] != nil else { return errSecItemNotFound }
            self.items[name] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }, add: { [unowned self] attributes in
            let name = self.account(attributes); self.trace.append("add:" + name)
            if let failure = self.addFailure { return failure }
            if self.duplicateOnAdd {
                self.duplicateOnAdd = false
                self.items[name] = Data("other writer's existing blob".utf8)
                return errSecDuplicateItem
            }
            guard self.items[name] == nil else { return errSecDuplicateItem }
            self.items[name] = attributes[kSecValueData as String] as? Data
            self.addedAccessible = attributes[kSecAttrAccessible as String]
            return errSecSuccess
        }, delete: { [unowned self] query in
            let name = self.account(query); self.trace.append("delete:" + name)
            if let failure = self.deleteFailure { return failure }
            return self.items.removeValue(forKey: name) == nil ? errSecItemNotFound : errSecSuccess
        })
    }
}
