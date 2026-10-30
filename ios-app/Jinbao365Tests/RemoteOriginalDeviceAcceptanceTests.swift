import XCTest
@testable import Jinbao365

/// Downloads stay on the device in an isolated, disposable cache. Attachments contain only booleans/counts.
@MainActor
final class RemoteOriginalDeviceAcceptanceTests: XCTestCase {
    func testRemoteOriginalCacheMissHitAndCorruptionRecovery() async throws {
        guard ProcessInfo.processInfo.environment["JINBAO_COS_ORIGINAL_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Explicit original-media acceptance is disabled.")
        }
        try await exerciseOriginalCache(requireMeteredPath: false)
    }

    func testRealMeteredPathRequiresOneTimeConsent() async throws {
        guard ProcessInfo.processInfo.environment["JINBAO_COS_CELLULAR_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Explicit metered-network acceptance is disabled.")
        }
        try await exerciseOriginalCache(requireMeteredPath: true)
    }

    private func exerciseOriginalCache(requireMeteredPath: Bool) async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device original-media acceptance is required.")
        #else
        var stage = Stage.initialState
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("original-acceptance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            guard try KeychainStore.load() != nil else { throw XCTSkip("Imported credentials are unavailable.") }
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: false)
            guard let archive = try ArchiveStore(url: support.appendingPathComponent("Jinbao365/archive.json")).load(),
                  case .verified = archive.link else { throw XCTSkip("A verified archive is unavailable.") }
            let candidates = archive.remote.flatMap(\.media).flatMap(\.resources).filter {
                $0.role != "preview" && $0.contentType.hasPrefix("image/") && (try? $0.validate()) != nil
            }.sorted { $0.byteCount < $1.byteCount }
            guard let resource = candidates.first else { throw XCTSkip("A validated remote image original is unavailable.") }
            let model = AppModel(directory: folder, automaticCloudWork: false)
            guard model.archiveRecoveryMessage == nil else { throw OriginalFailure.initialState }
            model.session = AppSession(deviceID: UUID().uuidString, testBuild: true,
                                       identity: archive.session().identity, link: archive.link, remote: archive.remote)
            model.allowCellularOriginals = false
            let savedPreference = UserDefaults.standard.object(forKey: "allowCellularOriginals") as? NSNumber
            let photo = TimelinePhoto(id: resource.assetID, kind: "photo", remoteResources: [resource])
            stage = .network
            let metered = try await waitForNetwork()
            if requireMeteredPath && !metered { throw XCTSkip("A real metered network path is unavailable.") }
            if !requireMeteredPath && metered { throw XCTSkip("An unmetered network path is unavailable; consent was not granted.") }
            var cellularDenied = false
            if requireMeteredPath {
                do { _ = try await load(model: model, photo: photo, allowOnce: false) }
                catch MediaAccessError.cellularPermissionRequired { cellularDenied = true }
                guard cellularDenied else { throw OriginalFailure.consent }
            }
            stage = .cacheMiss
            let first = try await load(model: model, photo: photo, allowOnce: requireMeteredPath)
            guard let url = first[resource.role], first.count == 1,
                  url.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/original-cache/") else {
                throw OriginalFailure.cache
            }
            try verify(url, resource: resource)
            let firstModification = try modificationDate(url)
            stage = .cacheHit
            // A known old timestamp makes an unnecessary replacement detectable even on coarse filesystems.
            let markerDate = Date(timeIntervalSince1970: 1_234_567_890)
            try FileManager.default.setAttributes([.modificationDate: markerDate], ofItemAtPath: url.path)
            let beforeHit = try modificationDate(url)
            let second = try await load(model: model, photo: photo, allowOnce: requireMeteredPath)
            guard second[resource.role] == url, try modificationDate(url) == beforeHit else { throw OriginalFailure.cache }
            try verify(url, resource: resource)
            stage = .corruptionRecovery
            try Data("synthetic corrupt isolated cache".utf8).write(to: url, options: .atomic)
            let third = try await load(model: model, photo: photo, allowOnce: requireMeteredPath)
            guard third[resource.role] == url else { throw OriginalFailure.cache }
            try verify(url, resource: resource)
            guard try modificationDate(url) != beforeHit,
                  !model.allowCellularOriginals,
                  (UserDefaults.standard.object(forKey: "allowCellularOriginals") as? NSNumber) == savedPreference else {
                throw OriginalFailure.consent
            }
            _ = firstModification // The value remains device-local and is never attached.
            let report: [String: Any] = [
                "resourceCount": 1, "cacheMissHashVerified": true, "cacheHitMtimePreserved": true,
                "corruptCacheRefetchedAndHashVerified": true, "meteredPath": metered,
                "cellularDenialVerified": cellularDenied, "oneTimeConsentVerified": requireMeteredPath,
                "persistentCellularPreferenceUnchanged": true, "cacheStayedInIsolatedDirectory": true
            ]
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
            attachment.name = requireMeteredPath ? "metered-original-booleans.json" : "original-cache-booleans.json"
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch let skipped as XCTSkip {
            throw skipped
        } catch MediaAccessError.offline {
            throw XCTSkip("A usable network path is unavailable.")
        } catch MediaAccessError.cellularPermissionRequired {
            throw XCTSkip("The network requires separate cellular consent.")
        } catch {
            // Never attach private media, hashes, object keys, titles, signed requests, or arbitrary errors.
            XCTFail("Remote-original acceptance failed at stage: \(stage.rawValue).")
        }
        #endif
    }

    private func waitForNetwork() async throws -> Bool {
        let policy = MediaNetworkPolicy()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            do { try policy.requireDownload(allowCellular: false); return false }
            catch MediaAccessError.cellularPermissionRequired { return true }
            catch MediaAccessError.offline { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { throw OriginalFailure.network }
        }
        throw XCTSkip("A usable network path is unavailable.")
    }

    private func load(model: AppModel, photo: TimelinePhoto, allowOnce: Bool) async throws -> [String: URL] {
        let deadline = Date().addingTimeInterval(10)
        while true {
            do { return try await model.mediaResourceURLs(for: photo, allowCellularOnce: allowOnce) }
            catch MediaAccessError.offline {
                guard Date() < deadline else { throw XCTSkip("The model has no usable network path.") }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func verify(_ url: URL, resource: RemoteResource) throws {
        let digest = try Digest.sha256File(url, maximumBytes: resource.byteCount)
        guard digest.byteCount == resource.byteCount, digest.hash == resource.sha256 else { throw OriginalFailure.cache }
    }
    private func modificationDate(_ url: URL) throws -> Date {
        guard let date = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date else {
            throw OriginalFailure.cache
        }
        return date
    }
    private enum Stage: String { case initialState, network, cacheMiss, cacheHit, corruptionRecovery }
    private enum OriginalFailure: Error { case initialState, network, cache, consent }
}
