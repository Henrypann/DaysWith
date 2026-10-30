import Foundation
import SwiftUI
import UIKit
import Network

/// Verification and credential persistence are injectable so lifecycle tests never use live secrets.
struct CloudConnectionOperations {
    var validate: (StorageConfiguration, StorageCredentials) throws -> Void
    var load: () throws -> StorageCredentials?
    var save: (StorageCredentials) throws -> Void
    var delete: () -> Void

    static let live = CloudConnectionOperations(validate: { configuration, credentials in
        let client = try CosClient(configuration: configuration, credentials: credentials, transport: URLSessionTransport())
        _ = try client.list(prefix: ParentIdentity.dad.prefix)
        _ = try client.list(prefix: ParentIdentity.mom.prefix)
    }, load: KeychainStore.load, save: KeychainStore.save, delete: KeychainStore.delete)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var session: AppSession
    @Published var bucket: String
    @Published var region: String
    @Published var secretID = ""
    @Published var secretKey = ""
    @Published var sessionToken = ""
    @Published private(set) var sensitiveFormObscured = false
    private let connectionOperations: CloudConnectionOperations
    private let automaticCloudWork: Bool
    var credentialExpiresAt: Int64?
    @Published var busy = false
    @Published var banner: String?
    @Published var bannerIsError = false
    @Published var tab: ShellTab = .timeline
    @Published var addMenuOpen = false
    @Published var composerOpen = false
    @Published var cameraOpen = false
    @Published var openFileImport = false
    @Published var openSystemPicker = false
    @Published var archiveRecoveryMessage: String?
    @Published var allowCellularOriginals = UserDefaults.standard.bool(forKey: "allowCellularOriginals")
    @Published var backupRunning = false
    @Published private(set) var originalLoads: [String: PreviewLoad] = [:]
    private let network = MediaNetworkPolicy()
    private let backupStop = BackupStopFlag()
    private var automaticBackup: Task<Void, Never>?
    private var refreshing = false
    private var connectionGeneration = 0
    @Published var selectedID: String?
    @Published private(set) var previewLoads: [String: PreviewLoad] = [:]

    let directory: URL
    static var isTestBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    init(directory overrideDirectory: URL? = nil, connectionOperations: CloudConnectionOperations = .live, automaticCloudWork: Bool = true) {
        self.connectionOperations = connectionOperations
        self.automaticCloudWork = automaticCloudWork
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        directory = overrideDirectory ?? (base ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("Jinbao365", isDirectory: true)
        var loaded: AppSession?
        var failure: String?
        do {
            guard base != nil else { throw CosFailure(.secureStorage) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            loaded = try ArchiveStore(url: directory.appendingPathComponent("archive.json")).load()?.session()
        } catch { failure = "本地档案暂时无法读取。现有文件已保留，请恢复上一份有效档案后继续。" }
        var restored = loaded ?? AppSession(deviceID: UUID().uuidString.lowercased(), testBuild: Self.isTestBuild)
        restored.testBuild = Self.isTestBuild
        session = restored
        bucket = restored.link.bucket ?? ""
        region = restored.link.region ?? "ap-shanghai"
        archiveRecoveryMessage = failure
        if failure == nil {
            do { try archiveStore.save(PersistedArchive(session: restored)) }
            catch { archiveRecoveryMessage = "本地档案暂时无法保存。现有记录已保留，请检查存储空间后重试。" }
        }
    }

    private var archiveStore: ArchiveStore { ArchiveStore(url: directory.appendingPathComponent("archive.json")) }

    func recoverArchive() {
        do {
            var restored = try archiveStore.restoreRecovery().session()
            restored.testBuild = Self.isTestBuild
            try archiveStore.save(PersistedArchive(session: restored))
            session = restored
            bucket = restored.link.bucket ?? bucket
            region = restored.link.region ?? region
            archiveRecoveryMessage = nil
            banner = "已恢复有效档案，原损坏文件仍保留。"
            bannerIsError = false
        } catch { banner = "暂时没有可恢复的有效副本，原档案未改动。"; bannerIsError = true }
    }

    func retryArchive() {
        do {
            guard var restored = try archiveStore.load()?.session() else { throw CosFailure(.notFound) }
            restored.testBuild = Self.isTestBuild
            try archiveStore.save(PersistedArchive(session: restored))
            session = restored; archiveRecoveryMessage = nil
        } catch { show(error) }
    }

    func confirm(_ parent: ParentIdentity) {
        mutate { try $0.confirmIdentity(parent) }
    }

    func connectPlaceholder() {
        #if DEBUG
        guard !busy, !backupRunning else { show(ContractError(path: "backup", message: "请等待连接验证完成，或先暂停备份。")); return }
        guard mutate({ try $0.connectPlaceholder(bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines),
                                           region: region.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { return }
        connectionGeneration += 1; refreshing = false
        banner = "这是占位连接，没有保存密钥，也不会上传。"
        bannerIsError = false
        #endif
    }

    func verify() {
        guard !busy, !backupRunning else { return }
        let identifier = secretID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials = StorageCredentials(secretID: identifier, secretKey: key,
                                             sessionToken: sessionToken.isEmpty ? nil : sessionToken,
                                             expiresAt: credentialExpiresAt)
        let configuration: StorageConfiguration
        do {
            configuration = StorageConfiguration(
                bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines),
                region: region.trimmingCharacters(in: .whitespacesAndNewlines),
                prefix: "life/v1/"
            )
            try configuration.validate()
            guard credentials.isValid else { throw CosFailure(.configuration) }
        } catch {
            show(error)
            return
        }
        connectionGeneration += 1
        // The previous refresh belongs to an expired connection generation. Its callback
        // intentionally cannot clear this state, so release it before verification starts.
        refreshing = false
        let generation = connectionGeneration
        busy = true
        banner = nil
        let operations = connectionOperations
        Task.detached {
            do {
                try operations.validate(configuration, credentials)
                await MainActor.run {
                    guard self.connectionGeneration == generation else { return }
                    self.busy = false
                    do {
                        let previous = try operations.load()
                        try operations.save(credentials)
                        guard self.mutate({ value in
                            let changed = value.link.bucket != configuration.bucket || value.link.region != configuration.region
                            try value.connectVerified(bucket: configuration.bucket, region: configuration.region)
                            if changed { value.remote = []; value.remoteAnniversaries = [] }
                            let newPrefix = try value.writerPrefix()
                            if let job = value.backupJob, job.bucket != configuration.bucket || job.region != configuration.region || job.prefix != newPrefix || job.testBuild != value.testBuild {
                                value.backupJob = nil
                            }
                        }) else {
                            if let previous { try operations.save(previous) } else { operations.delete() }
                            return
                        }
                    } catch { self.show(error); return }
                    self.clearSecretFields()
                    self.previewLoads = [:]
                    self.originalLoads = [:]
                    self.banner = "云存储已连接"
                    self.bannerIsError = false
                    self.refreshing = false
                    if self.automaticCloudWork {
                        self.refreshRemote()
                        self.scheduleAutomaticBackup()
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.connectionGeneration == generation else { return }
                    self.busy = false
                    self.show(error)
                }
            }
        }
    }

    func disconnect() {
        guard !busy else { banner = "正在验证连接，请稍后再断开。"; return }
        guard !backupRunning else { pauseBackup(); banner = "正在暂停备份，完成当前文件后可断开连接。"; return }
        guard mutate({ value in
            value.disconnectCloud(); value.remote = []; value.remoteAnniversaries = []
        }) else { return }
        connectionGeneration += 1; refreshing = false
        connectionOperations.delete()
        clearSecretFields(); previewLoads = [:]; originalLoads = [:]
        banner = "已断开云存储。这台手机上的记录还在。"; bannerIsError = false
    }

    func updateScenePhase(_ phase: ScenePhase) {
        sensitiveFormObscured = phase != .active
        if phase == .active { activate() }
    }

    func cancelCloudConfiguration() {
        // Invalidate in-flight validation so a cancelled form cannot later replace credentials.
        if busy {
            connectionGeneration += 1
            busy = false
            refreshing = false
        }
        clearSecretFields()
        bucket = session.link.bucket ?? bucket
        region = session.link.region ?? region
    }

    func clearSecretFields() {
        secretID = ""
        secretKey = ""
        sessionToken = ""
        credentialExpiresAt = nil
    }

    func beginDraft(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        if session.draft == nil, !mutate({ $0.beginDraft(now: now) }) { return }
        composerOpen = true; addMenuOpen = false
    }

    func beginEditing(id: String) {
        guard mutate({ try $0.beginEdit(id: id, now: Self.now) }) else { return }
        selectedID = nil
        DispatchQueue.main.async { self.composerOpen = true }
    }

    @discardableResult
    func updateDraft(title: String, note: String) -> Bool { mutate { $0.updateDraft(title: title, note: note) } }
    func updateDraftDate(_ date: Date) { updateDraftOccurredAt(Int64(date.timeIntervalSince1970 * 1000)) }
    func updateDraftOccurredAt(_ millis: Int64) { mutate { $0.setDraftOccurredAt(millis) } }
    func moveDraftAsset(from: Int, to: Int) { mutate { try $0.moveAsset(from: from, to: to) } }
    func reorderAssets(from: Int, to: Int) { moveDraftAsset(from: from, to: to) }
    func discardDraft() { if mutate({ $0.discardDraft() }) { composerOpen = false } }

    @discardableResult
    func importAssets(_ assets: [LocalAsset]) -> Bool {
        guard !assets.isEmpty else { return true }
        let result = mutate { value in
            if value.draft == nil { value.beginDraft(now: Self.now) }
            try value.addAssets(assets)
        }
        if result { banner = "已加入 \(assets.count) 项媒体，原文件保存在这台手机。"; bannerIsError = false }
        return result
    }

    @discardableResult
    func addImported(data: Data, filename: String, provenance: ImportProvenance) -> Bool {
        beginDraft()
        do {
            let asset = try PhotoImport.store(data: data, filename: filename, provenance: provenance, directory: directory)
            return importAssets([asset])
        } catch { show(error); return false }
    }

    func removeAsset(_ id: String) { mutate { $0.removeAsset(id: id) } }

    func commitDraft() {
        guard mutate({ _ = try $0.commitDraft(now: Self.now) }) else { return }
        composerOpen = false; tab = .timeline
        scheduleAutomaticBackup()
    }

    func trashMoment(id: String) {
        if mutate({ try $0.trashMoment(id: id, now: Self.now) }) { selectedID = nil; scheduleAutomaticBackup() }
    }
    func restoreMoment(id: String) {
        if mutate({ try $0.restoreMoment(id: id, now: Self.now) }) { scheduleAutomaticBackup() }
    }
    @discardableResult
    func saveAnniversary(id: String?, title: String, date: String) -> Bool {
        let result = mutate { try $0.saveAnniversary(id: id, title: title, date: date, now: Self.now) }
        if result { scheduleAutomaticBackup() }
        return result
    }
    func deleteAnniversary(id: String) {
        if mutate({ try $0.deleteAnniversary(id: id, now: Self.now) }) { scheduleAutomaticBackup() }
    }
    func setAllowCellularOriginals(_ allowed: Bool) {
        UserDefaults.standard.set(allowed, forKey: "allowCellularOriginals")
        allowCellularOriginals = allowed
    }
    var localStorageBytes: Int64 {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return 0 }
        return files.compactMap { $0 as? URL }.reduce(0) { total, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return total + (values?.isRegularFile == true ? Int64(values?.fileSize ?? 0) : 0)
        }
    }
    nonisolated static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    func refreshRemote() {
        guard !refreshing, archiveRecoveryMessage == nil, case .verified(let bucket, let region) = session.link else { return }
        refreshing = true
        let generation = connectionGeneration
        let owner = session.identity
        let deviceID = session.deviceID
        let testBuild = session.testBuild
        guard let owner else { refreshing = false; return }
        Task.detached {
            do {
                guard let credentials = try KeychainStore.load() else { throw CosFailure(.secureStorage) }
                let client = try CosClient(
                    configuration: StorageConfiguration(bucket: bucket, region: region, prefix: "life/v1/"),
                    credentials: credentials,
                    transport: URLSessionTransport()
                )
                let remote = try FamilyReader.readArchive(client: client, owner: owner, deviceID: deviceID, testBuild: testBuild)
                await MainActor.run {
                    guard self.connectionGeneration == generation else { return }
                    self.refreshing = false
                    guard self.session.link == .verified(bucket: bucket, region: region) else { return }
                    self.mutate { value in value.remote = remote.moments; value.remoteAnniversaries = remote.anniversaries }
                }
            } catch {
                await MainActor.run { if self.connectionGeneration == generation { self.refreshing = false; self.show(error) } }
            }
        }
    }

    var backupStatusTitle: String {
        guard case .verified = session.link else { return "仅保存在这台手机" }
        guard let job = session.backupJob, backupMatchesScope(job) else { return "尚未备份" }
        switch job.status {
        case .queued: return "等待继续备份"
        case .uploading: return backupRunning ? "正在备份" : "备份已中断，可继续"
        case .paused: return "备份已暂停"
        case .failed: return "备份未完成"
        case .completed:
            if let plan = try? BackupPlan.manifest(session: session, now: Self.now), plan.bytes != job.manifestBytes { return "有新的内容待备份" }
            return "已备份"
        }
    }
    var backupStatusDetail: String {
        guard case .verified = session.link else { return "占位或未连接时不会上传；仅本地记录以后也不会自动上传。" }
        guard let job = session.backupJob, backupMatchesScope(job) else { return "新建的可备份记录会在应用打开时自动备份。" }
        if let error = job.lastError { return error }
        return "原件已核验 \(job.completedCount) / \(job.totalCount)；本机记录始终保留。"
    }
    var backupProgress: Double? {
        guard let job = session.backupJob, backupMatchesScope(job) else { return nil }; return job.progress
    }
    private func backupMatchesScope(_ job: BackupJob) -> Bool {
        job.bucket == session.link.bucket && job.region == session.link.region && job.prefix == (try? session.writerPrefix()) && job.testBuild == session.testBuild
    }

    func activate() {
        guard automaticCloudWork, archiveRecoveryMessage == nil else { return }
        refreshRemote()
        if let job = session.backupJob, job.status == .queued || job.status == .uploading { backupNow() }
        else if session.backupJob?.status != .paused && session.backupJob?.status != .failed { scheduleAutomaticBackup() }
    }

    private func scheduleAutomaticBackup() {
        automaticBackup?.cancel()
        guard case .verified = session.link,
              let plan = try? BackupPlan.manifest(session: session, now: Self.now),
              session.backupJob?.status != .paused,
              session.backupJob?.status != .failed,
              session.backupJob?.manifestBytes != plan.bytes || session.backupJob?.status != .completed || !(session.backupJob.map(backupMatchesScope) ?? false) else { return }
        automaticBackup = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.backupNow()
        }
    }

    func pauseBackup() {
        automaticBackup?.cancel()
        backupStop.set(true)
        if !backupRunning { mutate { $0.backupJob?.pause() } }
        banner = backupRunning ? "正在暂停，当前文件完成后停止。" : "备份已暂停。"
        bannerIsError = false
    }
    func resumeBackup() { backupNow() }

    func backupNow() {
        guard !backupRunning, !busy, archiveRecoveryMessage == nil else { return }
        guard case .verified = session.link else {
            banner = "占位连接不会上传。请在真机填写密钥后再备份。"; bannerIsError = true; return
        }
        let snapshot = session
        let generation = connectionGeneration
        let folder = directory
        let stop = backupStop
        stop.set(false)
        backupRunning = true
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                guard let credentials = try KeychainStore.load() else { throw CosFailure(.secureStorage) }
                let prefix = try snapshot.writerPrefix()
                let client = try CosClient(configuration: StorageConfiguration(bucket: snapshot.link.bucket ?? "", region: snapshot.link.region ?? "", prefix: prefix), credentials: credentials, transport: URLSessionTransport())
                var job: BackupJob
                if let existing = snapshot.backupJob, existing.status != .completed,
                   existing.prefix == prefix, existing.bucket == snapshot.link.bucket, existing.region == snapshot.link.region,
                   existing.testBuild == snapshot.testBuild {
                    job = existing; job.resume()
                } else { job = try BackupQueue.prepare(client: client, session: snapshot, now: Self.now) }
                let checkpoint: (BackupJob) throws -> Void = { updated in
                    try DispatchQueue.main.sync {
                        try MainActor.assumeIsolated {
                            guard self.connectionGeneration == generation, self.session.link == snapshot.link, self.session.deviceID == snapshot.deviceID,
                                  self.archiveRecoveryMessage == nil else { throw CosFailure(.configuration) }
                            var latest = self.session
                            latest.backupJob = updated
                            try self.archiveStore.save(PersistedArchive(session: latest))
                            self.session = latest
                        }
                    }
                }
                try checkpoint(job)
                try BackupQueue.advance(client: client, session: snapshot, job: &job, resolve: { relative in
                    let url = folder.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
                    guard url.path.hasPrefix(folder.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { throw CosFailure(.contentMismatch) }
                    return url
                }, persist: checkpoint, shouldPause: { stop.value })
                let completedStatus = job.status
                await MainActor.run {
                    self.backupRunning = false
                    self.banner = completedStatus == .completed ? "已备份到云端，本机记录仍然保留。" : "备份已暂停，可稍后继续。"
                    self.bannerIsError = false
                    if completedStatus == .completed { self.scheduleAutomaticBackup() }
                }
            } catch {
                await MainActor.run { self.backupRunning = false; self.show(error) }
            }
        }
    }

    func mediaResourceURLs(for photo: TimelinePhoto, allowCellularOnce: Bool = false) async throws -> [String: URL] {
        var result: [String: URL] = [:]
        for resource in photo.localResources where resource.role != "preview" {
            guard let url = fileURL(resource.relativePath), FileManager.default.fileExists(atPath: url.path) else { throw CosFailure(.notFound) }
            result[resource.role] = url
        }
        if result.isEmpty, let path = photo.fullSizePath, let url = fileURL(path), FileManager.default.fileExists(atPath: url.path) {
            result["photo"] = url
        }
        guard !photo.remoteResources.isEmpty else { return result }
        let link = session.link
        let generation = connectionGeneration
        let folder = directory
        let policy = network
        let permitted = allowCellularOriginals || allowCellularOnce
        for resource in photo.remoteResources where resource.role != "preview" {
            try resource.validate()
            let ext = URL(fileURLWithPath: resource.originalFilename).pathExtension.lowercased()
            let safeExt = ext.range(of: #"^[a-z0-9]{1,10}$"#, options: .regularExpression) != nil ? ext : "bin"
            let relative = "original-cache/\(resource.parent.folder)-\(resource.sha256).\(safeExt)"
            let url = folder.appendingPathComponent(relative)
            let cached = await Task.detached { () -> Bool in
                guard let digest = try? Digest.sha256File(url, maximumBytes: resource.byteCount) else { return false }
                return digest.hash == resource.sha256 && digest.byteCount == resource.byteCount
            }.value
            if cached { result[resource.role] = url; originalLoads[resource.id] = .ready(relative); continue }
            // A corrupt cache is disposable; originals in media/ are never removed.
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            guard case .verified(let bucket, let region) = link else { throw CosFailure(.configuration) }
            try policy.requireDownload(allowCellular: permitted)
            originalLoads[resource.id] = .loading
            do {
                try await Task.detached {
                    guard let credentials = try KeychainStore.load() else { throw CosFailure(.secureStorage) }
                    let settings = URLSessionConfiguration.ephemeral
                    settings.allowsCellularAccess = permitted
                    settings.allowsExpensiveNetworkAccess = permitted
                    settings.allowsConstrainedNetworkAccess = permitted
                    let client = try CosClient(configuration: StorageConfiguration(bucket: bucket, region: region, prefix: resource.parent.prefix), credentials: credentials, transport: URLSessionTransport(configuration: settings))
                    try client.getFile(key: resource.objectKey, destination: url, byteCount: resource.byteCount, sha256: resource.sha256)
                }.value
                guard connectionGeneration == generation, session.link == link else { throw CosFailure(.configuration) }
                originalLoads[resource.id] = .ready(relative)
                result[resource.role] = url
            } catch {
                originalLoads[resource.id] = .failed("原件暂时无法读取，请重试。")
                throw error
            }
        }
        return result
    }

    func fileURL(_ relative: String) -> URL? {
        guard !relative.isEmpty, !relative.contains(".."), !relative.hasPrefix("/") else { return nil }
        return directory.appendingPathComponent(relative)
    }

    func previewPath(for photo: TimelinePhoto) -> String? {
        if let local = photo.localPath { return local }
        guard let reference = photo.remote, case .ready(let path) = previewLoads[reference.id] else { return nil }
        return path
    }

    func loadPreview(_ reference: RemotePreview, retry: Bool = false) {
        if !retry, previewLoads[reference.id] != nil { return }
        guard case .verified(let bucket, let region) = session.link else {
            previewLoads[reference.id] = .failed("请先连接云存储，再读取照片。")
            return
        }
        let folder = directory
        previewLoads[reference.id] = .loading
        Task.detached {
            do {
                try reference.validate()
                let relative = "preview-cache/\(reference.parent.folder)-\(reference.sha256)"
                let url = folder.appendingPathComponent(relative)
                var bytes: Data?
                if let cachedFile = try? FileHandle(forReadingFrom: url) {
                    // Read one bounded look-ahead byte to reject oversized/corrupt caches.
                    let cached = try? cachedFile.read(upToCount: Int(reference.byteCount) + 1)
                    try? cachedFile.close()
                    if let cached, (try? reference.validate(data: cached)) != nil { bytes = cached }
                }
                if bytes == nil {
                    guard let credentials = try KeychainStore.load() else { throw CosFailure(.secureStorage) }
                    let client = try CosClient(
                        configuration: StorageConfiguration(bucket: bucket, region: region, prefix: reference.parent.prefix),
                        credentials: credentials, transport: URLSessionTransport())
                    guard let head = try client.head(key: reference.objectKey), head.byteCount == reference.byteCount else {
                        throw CosFailure(.contentMismatch)
                    }
                    let downloaded = try client.get(key: reference.objectKey, responseLimit: Int(RemotePreview.maximumBytes))
                    try reference.validate(data: downloaded)
                    bytes = downloaded
                }
                guard let bytes, PhotoImport.isDisplayablePreview(bytes, contentType: reference.contentType) else { throw CosFailure(.contentMismatch) }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: url, options: .atomic)
                await MainActor.run {
                    guard self.session.link == .verified(bucket: bucket, region: region) else { return }
                    self.previewLoads[reference.id] = .ready(relative)
                }
            } catch {
                await MainActor.run {
                    guard self.session.link == .verified(bucket: bucket, region: region) else { return }
                    self.previewLoads[reference.id] = .failed("照片暂时无法读取，请重试。")
                }
            }
        }
    }

    func show(_ error: Error) {
        bannerIsError = true
        if let failure = error as? CosFailure {
            banner = failure.failure.message
        } else if let contract = error as? ContractError {
            banner = contract.message
        } else {
            banner = "暂时无法完成，请稍后再试。"
        }
    }

    @discardableResult
    private func mutate(_ body: (inout AppSession) throws -> Void) -> Bool {
        guard archiveRecoveryMessage == nil else { return false }
        var copy = session
        do {
            try body(&copy)
            try archiveStore.save(PersistedArchive(session: copy))
            session = copy
            return true
        } catch { show(error); return false }
    }

    private func persist() throws { try archiveStore.save(PersistedArchive(session: session)) }

}

enum ShellTab {
    case timeline
    case anniversaries
    case review
    case my
}

enum PreviewLoad: Equatable {
    case loading
    case ready(String)
    case failed(String)
}
