import XCTest
import SwiftUI
@testable import Jinbao365

/// Every fixture has an isolated archive and in-memory credentials. No real Keychain or COS access.
@MainActor
final class CredentialLifecycleTests: XCTestCase {
    func testTwoBackgroundForegroundCyclesKeepPendingInputAndHideForm() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        fixture.fill()
        for _ in 0..<2 {
            model.updateScenePhase(.inactive)
            XCTAssertTrue(model.sensitiveFormObscured)
            fixture.assertPending()
            model.updateScenePhase(.background)
            XCTAssertTrue(model.sensitiveFormObscured)
            fixture.assertPending()
            model.updateScenePhase(.active)
            XCTAssertFalse(model.sensitiveFormObscured)
            fixture.assertPending()
        }
        XCTAssertNil(fixture.memory.value)
        let restored = fixture.relaunch()
        XCTAssertEqual(restored.secretID, "")
        XCTAssertEqual(restored.secretKey, "")
        XCTAssertEqual(restored.sessionToken, "")
        XCTAssertNil(restored.credentialExpiresAt)
    }

    func testSuccessfulVerificationCommitsCredentialsThenClearsAllPendingFields() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.fill()
        fixture.model.verify()
        try await waitForVerification(fixture.model)
        XCTAssertFalse(fixture.model.bannerIsError)
        XCTAssertEqual(fixture.memory.value, fixture.pending)
        assertEmpty(fixture.model)
        XCTAssertEqual(fixture.model.session.link, .verified(bucket: fixture.model.bucket, region: fixture.model.region))
        let restored = fixture.relaunch()
        XCTAssertEqual(restored.session.link, fixture.model.session.link)
        XCTAssertEqual(fixture.memory.value, fixture.pending)
        assertEmpty(restored)
    }

    func testFailedVerificationRetainsPendingInputAndPreviousCredentialsForRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.memory.value = fixture.previous
        fixture.memory.validationFailure = true
        fixture.fill()
        fixture.model.verify()
        try await waitForVerification(fixture.model)
        XCTAssertTrue(fixture.model.bannerIsError)
        fixture.assertPending()
        XCTAssertEqual(fixture.memory.value, fixture.previous)
        fixture.memory.validationFailure = false
        fixture.model.verify()
        try await waitForVerification(fixture.model)
        XCTAssertEqual(fixture.memory.value, fixture.pending)
        assertEmpty(fixture.model)
    }

    func testFailedKeychainReplacementRetainsPendingInputAndPreviousCredentials() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.memory.value = fixture.previous
        fixture.memory.saveFailure = true
        fixture.fill()
        fixture.model.verify()
        try await waitForVerification(fixture.model)
        XCTAssertTrue(fixture.model.bannerIsError)
        fixture.assertPending()
        XCTAssertEqual(fixture.memory.value, fixture.previous)
    }

    func testFailedArchiveCommitRestoresPreviousCredentialsAndRetainsInput() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.memory.value = fixture.previous
        fixture.fill()
        let session = fixture.model.session
        try FileManager.default.removeItem(at: fixture.directory)
        try Data("Synthetic archive write obstruction".utf8).write(to: fixture.directory)
        fixture.model.verify()
        try await waitForVerification(fixture.model)
        XCTAssertTrue(fixture.model.bannerIsError)
        fixture.assertPending()
        XCTAssertEqual(fixture.memory.value, fixture.previous)
        XCTAssertEqual(fixture.model.session, session)
    }

    func testCancelClearsInputWithoutDeletingStoredCredentialsOrRecords() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.memory.value = fixture.previous
        fixture.fill()
        let session = fixture.model.session
        fixture.model.cancelCloudConfiguration()
        assertEmpty(fixture.model)
        XCTAssertEqual(fixture.memory.value, fixture.previous)
        XCTAssertEqual(fixture.model.session, session)
    }

    func testDisconnectClearsPendingAndStoredCredentialsButKeepsIdentityAndDraft() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.memory.value = fixture.previous
        fixture.model.connectPlaceholder()
        fixture.model.beginDraft()
        _ = fixture.model.updateDraft(title: "Synthetic draft", note: "Keep on disconnect")
        let draft = fixture.model.session.draft
        fixture.fill()
        fixture.model.disconnect()
        assertEmpty(fixture.model)
        XCTAssertNil(fixture.memory.value)
        XCTAssertEqual(fixture.model.session.draft, draft)
        XCTAssertEqual(fixture.model.session.identity, .dad)
    }

    func testCancelledInFlightVerificationCannotReplaceStoredCredentials() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.memory.value = fixture.previous
        let entered = expectation(description: "Synthetic verifier entered")
        let exited = expectation(description: "Synthetic verifier exited")
        let resume = DispatchSemaphore(value: 0)
        fixture.memory.validate = {
            entered.fulfill()
            _ = resume.wait(timeout: .now() + 5)
            exited.fulfill()
        }
        fixture.fill()
        fixture.model.verify()
        await fulfillment(of: [entered], timeout: 5)
        fixture.model.cancelCloudConfiguration()
        resume.signal()
        await fulfillment(of: [exited], timeout: 5)
        // Allow the verifier's queued MainActor completion to observe the cancelled generation.
        for _ in 0..<10 { await Task.yield() }
        assertEmpty(fixture.model)
        XCTAssertFalse(fixture.model.busy)
        XCTAssertEqual(fixture.memory.value, fixture.previous)
        XCTAssertEqual(fixture.memory.saveCount, 0)
    }

    private func assertEmpty(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(model.secretID, "", file: file, line: line)
        XCTAssertEqual(model.secretKey, "", file: file, line: line)
        XCTAssertEqual(model.sessionToken, "", file: file, line: line)
        XCTAssertNil(model.credentialExpiresAt, file: file, line: line)
    }

    private func waitForVerification(_ model: AppModel) async throws {
        for _ in 0..<500 {
            if !model.busy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Synthetic verification did not finish")
    }
}

@MainActor
private final class Fixture {
    let directory: URL
    let memory = MemoryCredentials()
    let model: AppModel
    let pending = StorageCredentials(secretID: "SyntheticPendingID", secretKey: "SyntheticPendingKey", sessionToken: "SyntheticToken", expiresAt: 4_000_000_000)
    let previous = StorageCredentials(secretID: "SyntheticPreviousID", secretKey: "SyntheticPreviousKey")

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("credential-lifecycle-" + UUID().uuidString)
        model = AppModel(directory: directory, connectionOperations: memory.operations, automaticCloudWork: false)
        model.bucket = "synthetic-lifecycle-12345"
        model.region = "ap-shanghai"
        model.confirm(.dad)
        XCTAssertNil(model.archiveRecoveryMessage)
    }
    func fill() {
        model.secretID = pending.secretID
        model.secretKey = pending.secretKey
        model.sessionToken = pending.sessionToken ?? ""
        model.credentialExpiresAt = pending.expiresAt
    }
    func assertPending(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(model.secretID, pending.secretID, file: file, line: line)
        XCTAssertEqual(model.secretKey, pending.secretKey, file: file, line: line)
        XCTAssertEqual(model.sessionToken, pending.sessionToken, file: file, line: line)
        XCTAssertEqual(model.credentialExpiresAt, pending.expiresAt, file: file, line: line)
    }
    func relaunch() -> AppModel { AppModel(directory: directory, connectionOperations: memory.operations, automaticCloudWork: false) }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private final class MemoryCredentials {
    var value: StorageCredentials?
    var validationFailure = false
    var saveFailure = false
    var saveCount = 0
    var validate: (() -> Void)?
    var operations: CloudConnectionOperations {
        CloudConnectionOperations(validate: { [self] _, _ in
            validate?()
            if validationFailure { throw CosFailure(.configuration) }
        }, load: { [self] in value }, save: { [self] credentials in
            if saveFailure { throw CosFailure(.secureStorage) }
            saveCount += 1
            value = credentials
        }, delete: { [self] in value = nil })
    }
}
