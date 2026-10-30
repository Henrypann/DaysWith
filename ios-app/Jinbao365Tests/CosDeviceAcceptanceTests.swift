import XCTest
import CryptoKit
import Security
@testable import Jinbao365

/// Explicit, device-only acceptance. No credential enters test arguments, logs, attachments or plaintext files.
/// Run alone. Persistent import is separately opted in; existing records and drafts are preserved.
@MainActor
final class CosDeviceAcceptanceTests: XCTestCase {
    func testReceiveEphemeralCredentialsAndReadFamilyArchive() async throws {
        guard ProcessInfo.processInfo.environment["JINBAO_COS_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Explicit COS acceptance is disabled.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("This exchange requires the physical acceptance device.")
        #else
        let persistentImport = ProcessInfo.processInfo.environment["JINBAO_COS_KEYCHAIN_IMPORT"] == "1"
        let permissionProbe = ProcessInfo.processInfo.environment["JINBAO_COS_PERMISSION_PROBE"] == "1"
        var previousCredentials: StorageCredentials?
        var originalArchive: PersistedArchive?
        var credentialStoreChanged = false
        var stage = "initial-state"
        var exchange: URL?
        do {
            // Allow the host's initial placeholder model to finish its synchronous load/save.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let store = ArchiveStore(url: support.appendingPathComponent("Jinbao365/archive.json"))
            guard let baseline = try store.load(),
                  baseline.identityFolder != nil,
                  baseline.backupJob?.status != .uploading, baseline.backupJob?.status != .queued else {
                throw ExchangeFailure.invalidInitialState
            }
            if !persistentImport && !permissionProbe {
                guard case .placeholder = baseline.link, baseline.backupJob == nil,
                  baseline.remote.isEmpty, baseline.remoteAnniversaries.isEmpty,
                  baseline.moments.allSatisfy({ $0.uploadEligibility == .localOnly }),
                  baseline.anniversaries.allSatisfy({ $0.uploadEligibility == .localOnly }),
                  baseline.draft == nil || baseline.draft?.uploadEligibility == .localOnly else {
                    throw ExchangeFailure.invalidInitialState
                }
            }
            originalArchive = baseline
            previousCredentials = try KeychainStore.load()
            let model = AppModel(automaticCloudWork: false)
            guard model.archiveRecoveryMessage == nil, PersistedArchive(session: model.session) == baseline,
                  model.session.testBuild, try model.session.writerPrefix().hasPrefix("life/v1/test/") else {
                throw ExchangeFailure.invalidInitialState
            }
            let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = cache.appendingPathComponent("JinbaoCOSAcceptance", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            exchange = folder
            defer {
                for name in ["ready.json", "envelope.json", "public-key.der"] {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                }
            }
            for name in ["ready.json", "envelope.json", "result.json", "failure.json", "public-key.der"] {
                let url = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            stage = "key-generation"
            let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                            kSecAttrKeySizeInBits as String: 2048,
                                            kSecAttrIsPermanent as String: false]
            var keyError: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &keyError),
                  let publicKey = SecKeyCopyPublicKey(privateKey),
                  let publicBytes = SecKeyCopyExternalRepresentation(publicKey, &keyError) as Data? else {
                throw ExchangeFailure.crypto
            }
            let challenge = UUID().uuidString.lowercased()
            try publicBytes.write(to: folder.appendingPathComponent("public-key.der"), options: [.atomic, .completeFileProtection])
            try writeJSON(["version": 1, "challenge": challenge, "publicKeyFormat": "PKCS1-DER",
                           "keyWrap": "RSA-OAEP-SHA256", "contentCipher": "AES-256-GCM",
                           "authenticatedData": "UTF8(challenge)", "expiresAtUnit": "unix-seconds",
                           "createdAt": Int64(Date().timeIntervalSince1970), "envelopeWaitSeconds": 180], to: folder, name: "ready.json")
            stage = "envelope-wait"
            let envelopeURL = folder.appendingPathComponent("envelope.json")
            let deadline = Date().addingTimeInterval(180)
            while !FileManager.default.fileExists(atPath: envelopeURL.path), Date() < deadline {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard FileManager.default.fileExists(atPath: envelopeURL.path),
                  let fileSize = try envelopeURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  fileSize <= 128 * 1024 else { throw ExchangeFailure.exchangeTimeout }
            stage = "envelope-decryption"
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: envelopeURL))
            guard envelope.version == 1, envelope.challenge == challenge,
                  let wrapped = Data(base64Encoded: envelope.wrappedKey), wrapped.count == 256,
                  let nonce = Data(base64Encoded: envelope.nonce), nonce.count == 12,
                  let ciphertext = Data(base64Encoded: envelope.ciphertext), ciphertext.count <= 64 * 1024,
                  let tag = Data(base64Encoded: envelope.tag), tag.count == 16,
                  SecKeyIsAlgorithmSupported(privateKey, .decrypt, .rsaEncryptionOAEPSHA256),
                  let keyData = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA256, wrapped as CFData, &keyError) as Data?,
                  keyData.count == 32 else { throw ExchangeFailure.crypto }
            let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
            var plaintext = try AES.GCM.open(sealed, using: SymmetricKey(data: keyData), authenticating: Data(challenge.utf8))
            defer { plaintext.resetBytes(in: 0..<plaintext.count) }
            let payload = try JSONDecoder().decode(CredentialsPayload.self, from: plaintext)
            let now = Int64(Date().timeIntervalSince1970)
            let supplied = StorageCredentials(secretID: payload.secretID, secretKey: payload.secretKey,
                                              sessionToken: payload.sessionToken, expiresAt: payload.expiresAt)
            let boundedTemporary = !(payload.sessionToken ?? "").isEmpty &&
                (payload.expiresAt ?? 0) > now + 60 && (payload.expiresAt ?? Int64.max) <= now + 7200
            let persistent = persistentImport && payload.sessionToken == nil && payload.expiresAt == nil
            guard payload.bucket == "example-1234567890", payload.region == "ap-shanghai",
                  (boundedTemporary || persistent), supplied.isValid else {
                throw ExchangeFailure.invalidCredentials
            }
            // One-use encrypted exchange: remove ciphertext after authenticated decoding; the private key is process-only.
            try FileManager.default.removeItem(at: envelopeURL)
            if permissionProbe {
                stage = "permission-probe"
                guard boundedTemporary else { throw ExchangeFailure.invalidCredentials }
                let configuration = StorageConfiguration(bucket: payload.bucket, region: payload.region, prefix: "life/v1/")
                let client = try CosClient(configuration: configuration, credentials: supplied, transport: URLSessionTransport())
                var denied = false
                do { _ = try client.list(prefix: "life/v1/dad/") }
                catch let error as CosFailure { denied = error.failure == .permission }
                guard denied else { throw ExchangeFailure.permissionProbe }
                let expiredClient = try CosClient(configuration: configuration, credentials: supplied, transport: URLSessionTransport(),
                                                  now: { (payload.expiresAt ?? 0) + 1 })
                var expired = false
                do { _ = try expiredClient.list(prefix: "life/v1/dad/") }
                catch let error as CosFailure { expired = error.failure == .expiredCredentials }
                guard expired, try store.load() == baseline, try KeychainStore.load() == previousCredentials else {
                    throw ExchangeFailure.permissionProbe
                }
                try writeJSON(["status": "permission-probes-complete", "serverDenied": true,
                               "clientExpiredSignerRejected": true, "storedCredentialsUnchanged": true,
                               "localArchiveUnchanged": true, "cloudWrites": 0], to: folder, name: "result.json")
                return
            }
            stage = "production-verification"
            model.bucket = payload.bucket; model.region = payload.region
            model.secretID = payload.secretID; model.secretKey = payload.secretKey
            model.sessionToken = payload.sessionToken ?? ""; model.credentialExpiresAt = payload.expiresAt
            model.verify()
            let verifyDeadline = Date().addingTimeInterval(120)
            while model.busy, Date() < verifyDeadline { try await Task.sleep(nanoseconds: 250_000_000) }
            guard !model.busy, !model.bannerIsError, case .verified = model.session.link else { throw ExchangeFailure.verification }
            credentialStoreChanged = true
            guard try KeychainStore.load() == supplied, model.secretID.isEmpty, model.secretKey.isEmpty,
                  model.sessionToken.isEmpty else { throw ExchangeFailure.verification }
            stage = "production-family-read"
            let owner = try XCTUnwrap(model.session.identity)
            let deviceID = model.session.deviceID
            let family = try await Task.detached {
                let client = try CosClient(configuration: StorageConfiguration(bucket: payload.bucket, region: payload.region, prefix: "life/v1/"),
                                           credentials: supplied, transport: URLSessionTransport())
                return try FamilyReader.readArchive(client: client, owner: owner, deviceID: deviceID, testBuild: true)
            }.value
            guard !family.moments.isEmpty else { throw ExchangeFailure.familyRead }
            model.session.remote = family.moments
            model.session.remoteAnniversaries = family.anniversaries
            try store.save(PersistedArchive(session: model.session))
            // FamilyReader publishes the complete validated archive in one MainActor mutation.
            let final = PersistedArchive(session: model.session)
            guard final.deviceID == baseline.deviceID, final.identityFolder == baseline.identityFolder,
                  final.moments == baseline.moments, final.draft == baseline.draft,
                  final.anniversaries == baseline.anniversaries, final.committedDrafts == baseline.committedDrafts,
                  final.backupJob == baseline.backupJob, !model.backupRunning,
                  try store.load() == final else { throw ExchangeFailure.localStateChanged }
            let prefix = try model.session.writerPrefix()
            guard prefix.hasPrefix("life/v1/test/"), final.remote.allSatisfy(\.readOnly) else { throw ExchangeFailure.scope }
            var years: [String: Int] = [:]
            var parents: [String: Int] = [:]
            let remote = final.remote.map { item -> [String: Any] in
                let parts = JinbaoCalendar.parts(millis: item.occurredAt, timeZone: .current)
                years[String(parts.year), default: 0] += 1
                parents[item.parent.folder, default: 0] += 1
                return ["id": item.id, "occurredAt": item.occurredAt, "year": parts.year, "month": parts.month,
                        "parent": item.parent.folder, "readOnly": item.readOnly]
            }
            try writeJSON(["status": "read-complete", "challenge": challenge, "yearCounts": years,
                           "parentCounts": parents, "remote": remote, "writerPrefix": prefix,
                           "localRecordCount": final.moments.count, "oldIDs": baseline.moments.map(\.id),
                           "uploadEligibility": Dictionary(uniqueKeysWithValues: final.moments.map { ($0.id, $0.uploadEligibility.rawValue) }),
                           "deviceIDPreserved": true, "draftPreserved": true, "localRecordsUnchanged": true,
                           "backupStarted": false, "keychainImport": persistentImport,
                           "expiresAt": payload.expiresAt.map { $0 as Any } ?? NSNull()], to: folder, name: "result.json")
            guard years["2025", default: 0] > 0 else { throw ExchangeFailure.no2025Records }
        } catch {
            if credentialStoreChanged, let originalArchive {
                do {
                    if let previousCredentials { try KeychainStore.save(previousCredentials) }
                    else { KeychainStore.delete() }
                    let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                    try ArchiveStore(url: support.appendingPathComponent("Jinbao365/archive.json")).save(originalArchive)
                } catch { stage = "rollback-failed" }
            }
            // Fixed categories only: SDK errors or decoding contexts can otherwise contain sensitive data.
            let category = (error as? ExchangeFailure)?.rawValue ?? "operation-failed"
            if let exchange { try? writeJSON(["status": "failed", "stage": stage, "category": category], to: exchange, name: "failure.json") }
            XCTFail("COS acceptance failed at \(stage): \(category). Private data was not attached.")
        }
        #endif
    }

    private func writeJSON(_ object: [String: Any], to folder: URL, name: String) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
            .write(to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
    }
    private struct Envelope: Decodable {
        let version: Int; let challenge: String; let wrappedKey: String
        let nonce: String; let ciphertext: String; let tag: String
    }
    private struct CredentialsPayload: Decodable {
        let bucket: String; let region: String; let secretID: String; let secretKey: String
        let sessionToken: String?; let expiresAt: Int64?
    }
    private enum ExchangeFailure: String, Error {
        case invalidInitialState = "invalid-initial-state", crypto = "crypto-failed", exchangeTimeout = "exchange-timeout"
        case invalidCredentials = "credential-scope-or-expiry", verification = "connection-verification"
        case familyRead = "family-read", localStateChanged = "local-state-changed", scope = "scope-mismatch"
        case no2025Records = "no-2025-records", permissionProbe = "permission-probe"
    }
}
