import Foundation

public enum AppPhase: Equatable {
    case chooseIdentity
    case connectCloud
    case timeline
}

public enum CloudLink: Equatable, Codable {
    case missing
    case placeholder(bucket: String, region: String)
    case verified(bucket: String, region: String)

    public var bucket: String? {
        switch self {
        case .missing: return nil
        case .placeholder(let bucket, _), .verified(let bucket, _): return bucket
        }
    }

    public var region: String? {
        switch self {
        case .missing: return nil
        case .placeholder(_, let region), .verified(_, let region): return region
        }
    }

    public var isConnected: Bool {
        if case .missing = self { return false }
        return true
    }
}

public struct LocalResource: Equatable, Hashable, Codable {
    public var id: String
    public var role: String
    public var contentType: String
    public var originalFilename: String
    public var byteCount: Int64
    public var sha256: String
    public var relativePath: String

    public init(id: String, role: String, contentType: String, originalFilename: String, byteCount: Int64, sha256: String, relativePath: String) {
        self.id = id
        self.role = role
        self.contentType = contentType
        self.originalFilename = originalFilename
        self.byteCount = byteCount
        self.sha256 = sha256
        self.relativePath = relativePath
    }
}

public struct CaptureMetadata: Equatable, Hashable, Codable {
    public var source: String
    public var timezoneOffsetMinutes: Int?
    public var localDateTime: String?
    public var isEstimated: Bool
    public init(source: String, timezoneOffsetMinutes: Int? = nil, localDateTime: String? = nil, isEstimated: Bool = false) {
        self.source = source
        self.timezoneOffsetMinutes = timezoneOffsetMinutes
        self.localDateTime = localDateTime
        self.isEstimated = isEstimated
    }
}

public struct LocalAsset: Equatable, Codable {
    public var id: String
    public var kind: String
    public var capturedAt: Int64
    public var provenance: String?
    public var captureMetadata: CaptureMetadata?
    public var resources: [LocalResource]

    public init(id: String, kind: String, capturedAt: Int64, provenance: String?, resources: [LocalResource], captureMetadata: CaptureMetadata? = nil) {
        self.id = id
        self.kind = kind
        self.capturedAt = capturedAt
        self.provenance = provenance
        self.captureMetadata = captureMetadata
        self.resources = resources
    }
}

public enum UploadEligibility: String, Codable {
    // The former "eligible" value did not record the creation build and cannot be trusted.
    case eligible = "family"
    case testOnly
    case localOnly

    public init(from decoder: Decoder) throws {
        let value = try? decoder.singleValueContainer().decode(String.self)
        self = value.flatMap(Self.init(rawValue:)) ?? .localOnly
    }
}

public struct LocalMoment: Equatable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var note: String
    public var occurredAt: Int64
    public var createdAt: Int64
    public var updatedAt: Int64
    public var revision: Int64
    public var trashedAt: Int64?
    public var parent: ParentIdentity
    public var assets: [LocalAsset]
    public private(set) var uploadEligibility: UploadEligibility

    public init(id: String, title: String, note: String, occurredAt: Int64, createdAt: Int64, updatedAt: Int64,
                revision: Int64 = 1, trashedAt: Int64? = nil, parent: ParentIdentity, assets: [LocalAsset],
                uploadEligibility: UploadEligibility = .localOnly) {
        self.id = id
        self.title = title
        self.note = note
        self.occurredAt = occurredAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.trashedAt = trashedAt
        self.parent = parent
        self.assets = assets
        self.uploadEligibility = uploadEligibility
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, note, occurredAt, createdAt, updatedAt, revision, trashedAt, parent, assets, uploadEligibility
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        note = try values.decode(String.self, forKey: .note)
        occurredAt = try values.decode(Int64.self, forKey: .occurredAt)
        createdAt = try values.decode(Int64.self, forKey: .createdAt)
        updatedAt = try values.decode(Int64.self, forKey: .updatedAt)
        revision = try values.decode(Int64.self, forKey: .revision)
        trashedAt = try values.decodeIfPresent(Int64.self, forKey: .trashedAt)
        parent = try values.decode(ParentIdentity.self, forKey: .parent)
        assets = try values.decode([LocalAsset].self, forKey: .assets)
        uploadEligibility = try values.decodeIfPresent(UploadEligibility.self, forKey: .uploadEligibility) ?? .localOnly
    }
}

public struct ComposerDraft: Equatable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var note: String
    public var occurredAt: Int64
    public var assets: [LocalAsset]
    public var originalMomentID: String?
    public var baselineRevision: Int64?
    public var timeWasEdited: Bool
    public var occurredAtIsEstimated: Bool
    public var hasImportedBatch: Bool
    public private(set) var uploadEligibility: UploadEligibility

    public init(title: String = "", note: String = "", occurredAt: Int64, assets: [LocalAsset] = [],
                uploadEligibility: UploadEligibility = .localOnly, id: String = UUID().uuidString.uppercased(),
                originalMomentID: String? = nil, baselineRevision: Int64? = nil,
                timeWasEdited: Bool = false, hasImportedBatch: Bool = false, occurredAtIsEstimated: Bool = false) {
        self.id = id
        self.title = title
        self.note = note
        self.occurredAt = occurredAt
        self.assets = assets
        self.uploadEligibility = uploadEligibility
        self.originalMomentID = originalMomentID
        self.baselineRevision = baselineRevision
        self.timeWasEdited = timeWasEdited
        self.occurredAtIsEstimated = occurredAtIsEstimated
        self.hasImportedBatch = hasImportedBatch
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, note, occurredAt, assets, uploadEligibility, originalMomentID, baselineRevision, timeWasEdited, hasImportedBatch, occurredAtIsEstimated
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.uppercased()
        title = try values.decode(String.self, forKey: .title)
        note = try values.decode(String.self, forKey: .note)
        occurredAt = try values.decode(Int64.self, forKey: .occurredAt)
        assets = try values.decode([LocalAsset].self, forKey: .assets)
        uploadEligibility = try values.decodeIfPresent(UploadEligibility.self, forKey: .uploadEligibility) ?? .localOnly
        originalMomentID = try values.decodeIfPresent(String.self, forKey: .originalMomentID)
        baselineRevision = try values.decodeIfPresent(Int64.self, forKey: .baselineRevision)
        // Old drafts may contain manually entered dates: never overwrite them during upgrade.
        timeWasEdited = try values.decodeIfPresent(Bool.self, forKey: .timeWasEdited) ?? true
        hasImportedBatch = try values.decodeIfPresent(Bool.self, forKey: .hasImportedBatch) ?? !assets.isEmpty
        occurredAtIsEstimated = try values.decodeIfPresent(Bool.self, forKey: .occurredAtIsEstimated) ?? false
    }

    public var originalCount: Int { assets.count }
}

public struct AppSession: Equatable {
    public var deviceID: String
    public var testBuild: Bool
    public var identity: ParentIdentity?
    public var link: CloudLink
    public var moments: [LocalMoment]
    public var draft: ComposerDraft?
    public var remote: [RemoteMoment]
    public var anniversaries: [LocalAnniversary]
    public var remoteAnniversaries: [RemoteAnniversary]
    public var backupJob: BackupJob?
    public var committedDrafts: [String: String]

    public init(deviceID: String, testBuild: Bool, identity: ParentIdentity? = nil, link: CloudLink = .missing,
                moments: [LocalMoment] = [], draft: ComposerDraft? = nil, remote: [RemoteMoment] = [],
                anniversaries: [LocalAnniversary] = [], remoteAnniversaries: [RemoteAnniversary] = [],
                backupJob: BackupJob? = nil, committedDrafts: [String: String] = [:]) {
        self.deviceID = deviceID
        self.testBuild = testBuild
        self.identity = identity
        self.link = link
        self.moments = moments
        self.draft = draft
        self.remote = remote
        self.anniversaries = anniversaries
        self.remoteAnniversaries = remoteAnniversaries
        self.backupJob = backupJob
        self.committedDrafts = committedDrafts
    }

    public var phase: AppPhase {
        if identity == nil { return .chooseIdentity }
        if !link.isConnected { return .connectCloud }
        return .timeline
    }

    public mutating func confirmIdentity(_ parent: ParentIdentity) throws {
        if let identity {
            guard identity == parent else {
                throw ContractError(path: "identity", message: "这台手机的署名已经确定，不能修改。")
            }
            return
        }
        identity = parent
    }

    public mutating func connectPlaceholder(bucket: String, region: String) throws {
        guard identity != nil else { throw ContractError(path: "identity", message: "请先选择爸爸或妈妈。") }
        // Synthetic metadata for the local-only placeholder, never a verified destination.
        let placeholderBucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "example-1234567890" : bucket
        let placeholderRegion = region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "ap-shanghai" : region
        let configuration = StorageConfiguration(bucket: placeholderBucket, region: placeholderRegion, prefix: "life/v1/")
        try configuration.validate()
        link = .placeholder(bucket: placeholderBucket, region: placeholderRegion)
    }

    public mutating func connectVerified(bucket: String, region: String) throws {
        guard identity != nil else { throw ContractError(path: "identity", message: "请先选择爸爸或妈妈。") }
        let configuration = StorageConfiguration(bucket: bucket, region: region, prefix: "life/v1/")
        try configuration.validate()
        link = .verified(bucket: bucket, region: region)
    }

    public mutating func disconnectCloud() {
        link = .missing
    }

    public var newUploadEligibility: UploadEligibility {
        if case .verified = link { return testBuild ? .testOnly : .eligible }
        return .localOnly
    }

    /// Reopening the composer resumes its durable draft; it never silently discards work.
    public mutating func beginDraft(now: Int64) {
        guard draft == nil else { return }
        draft = ComposerDraft(occurredAt: now, uploadEligibility: newUploadEligibility)
    }

    public mutating func beginEdit(id: String, now: Int64) throws {
        guard let moment = moments.first(where: { $0.id == id && $0.parent == identity && $0.trashedAt == nil }) else {
            throw ContractError(path: "moment", message: "只能编辑这台手机创建的记录。")
        }
        if let draft {
            if draft.originalMomentID == id { return }
            throw ContractError(path: "draft", message: "请先保存或放弃正在编辑的草稿。")
        }
        draft = ComposerDraft(title: moment.title, note: moment.note, occurredAt: moment.occurredAt,
                              assets: moment.assets, uploadEligibility: moment.uploadEligibility,
                              originalMomentID: moment.id, baselineRevision: moment.revision,
                              timeWasEdited: true, hasImportedBatch: true)
        _ = now
    }

    public mutating func discardDraft() { draft = nil }

    public mutating func updateDraft(title: String, note: String) {
        draft?.title = title
        draft?.note = note
    }

    public mutating func setDraftOccurredAt(_ occurredAt: Int64) {
        draft?.occurredAt = occurredAt
        draft?.timeWasEdited = true
        draft?.occurredAtIsEstimated = false
    }

    public mutating func addAsset(_ asset: LocalAsset) throws { try addAssets([asset]) }

    /// Call once per picker result batch so its earliest known timestamp is used consistently.
    public mutating func addAssets(_ assets: [LocalAsset], timeZone: TimeZone = .current) throws {
        guard var current = draft else { throw ContractError(path: "draft", message: "请先开始一条记录。") }
        guard !assets.isEmpty else { return }
        guard current.assets.count + assets.count <= 30 else {
            throw ContractError(path: "draft.assets", message: "一条记录最多 30 项媒体。")
        }
        let combined = current.assets + assets
        guard Set(combined.map { $0.id.uppercased() }).count == combined.count else {
            throw ContractError(path: "draft.assets", message: "这项媒体已经在记录中。")
        }
        if current.originalMomentID == nil && !current.hasImportedBatch && !current.timeWasEdited && current.assets.isEmpty {
            let candidates: [(millis: Int64, estimated: Bool)] = assets.compactMap { asset in
                if asset.capturedAt > 0 && asset.capturedAt <= V1Validator.maxTimestamp {
                    return (asset.capturedAt, asset.captureMetadata?.isEstimated ?? false)
                }
                // A local date with an unknown zone is useful for the form, but not an absolute asset timestamp.
                guard let local = asset.captureMetadata?.localDateTime else { return nil }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = timeZone
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                formatter.isLenient = false
                guard let date = formatter.date(from: local), formatter.string(from: date) == local else { return nil }
                let value = Int64(date.timeIntervalSince1970 * 1000)
                guard value > 0, value <= V1Validator.maxTimestamp else { return nil }
                return (value, true)
            }
            if let earliest = candidates.min(by: { $0.millis < $1.millis }) {
                current.occurredAt = earliest.millis
                current.occurredAtIsEstimated = earliest.estimated
            } else { current.occurredAtIsEstimated = true }
        }
        current.hasImportedBatch = true
        current.assets = combined
        draft = current
    }

    public mutating func removeAsset(id: String) { draft?.assets.removeAll { $0.id == id } }

    public mutating func moveAsset(from: Int, to: Int) throws {
        guard var current = draft, current.assets.indices.contains(from), (0...current.assets.count).contains(to) else {
            throw ContractError(path: "draft.assets", message: "找不到要移动的媒体。")
        }
        let item = current.assets.remove(at: from)
        current.assets.insert(item, at: min(to, current.assets.count))
        draft = current
    }

    @discardableResult
    public mutating func commitDraft(now: Int64) throws -> LocalMoment {
        guard let parent = identity, var current = draft else {
            throw ContractError(path: "draft", message: "请先开始一条记录。")
        }
        if let savedID = committedDrafts[current.id], let saved = moments.first(where: { $0.id == savedID }) {
            draft = nil
            return saved
        }
        current.title = current.title.trimmingCharacters(in: .whitespacesAndNewlines)
        current.note = current.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.title.isEmpty || !current.note.isEmpty || !current.assets.isEmpty else {
            throw ContractError(path: "draft", message: "写一段话，或选择媒体。")
        }
        guard current.title.utf16.count <= 200, current.note.utf16.count <= 10_000,
              (0...V1Validator.maxTimestamp).contains(current.occurredAt),
              current.assets.count <= 30 else {
            throw ContractError(path: "draft", message: "请检查日期、文字长度和媒体数量。")
        }
        let saved: LocalMoment
        if let originalID = current.originalMomentID {
            guard let index = moments.firstIndex(where: { $0.id == originalID && $0.parent == parent }),
                  moments[index].revision == current.baselineRevision, moments[index].trashedAt == nil else {
                throw ContractError(path: "draft.baseline", message: "记录已经改变，请保留草稿并重新检查原记录。")
            }
            var edited = moments[index]
            edited.title = current.title
            edited.note = current.note
            edited.occurredAt = current.occurredAt
            edited.assets = current.assets
            edited.updatedAt = now
            edited.revision += 1
            // Keep the original immutable upload eligibility, including placeholder origins.
            moments[index] = edited
            saved = edited
        } else {
            saved = LocalMoment(id: current.id, title: current.title, note: current.note,
                                occurredAt: current.occurredAt, createdAt: now, updatedAt: now,
                                parent: parent, assets: current.assets, uploadEligibility: current.uploadEligibility)
            if let existing = moments.first(where: { $0.id == saved.id }) {
                guard existing == saved else { throw ContractError(path: "draft.id", message: "记录编号冲突，已保留草稿。") }
            } else { moments.append(saved) }
        }
        committedDrafts[current.id] = saved.id
        draft = nil
        return saved
    }

    public mutating func trashMoment(id: String, now: Int64) throws {
        guard let index = moments.firstIndex(where: { $0.id == id && $0.parent == identity }) else {
            throw ContractError(path: "moment", message: "只能移入这台手机创建的记录。")
        }
        guard moments[index].trashedAt == nil else { return }
        moments[index].trashedAt = now
        moments[index].updatedAt = now
        moments[index].revision += 1
    }

    public mutating func restoreMoment(id: String, now: Int64) throws {
        guard let index = moments.firstIndex(where: { $0.id == id && $0.parent == identity }) else {
            throw ContractError(path: "moment", message: "只能恢复这台手机创建的记录。")
        }
        guard moments[index].trashedAt != nil else { return }
        moments[index].trashedAt = nil
        moments[index].updatedAt = now
        moments[index].revision += 1
    }

    public func months(timeZone: TimeZone) -> [TimelineMonth] {
        JinbaoCalendar.months(entries: timelineEntries(), timeZone: timeZone)
    }

    public func timelineEntries() -> [TimelineEntry] {
        let local = moments.filter { $0.trashedAt == nil }.map { moment in
            let preview = moment.assets.first?.resources.first { $0.role == "preview" }?.relativePath
                ?? moment.assets.first?.resources.first { $0.role == "photo" }?.relativePath
            let provenance = moment.assets.first.flatMap { ImportProvenance.known($0.provenance)?.label }
            return TimelineEntry(
                id: moment.id,
                title: moment.title,
                note: moment.note,
                occurredAt: moment.occurredAt,
                parent: moment.parent,
                readOnly: moment.parent != identity,
                mediaCount: moment.assets.count,
                previewPath: preview,
                provenanceLabel: provenance,
                photos: moment.assets.map { asset in
                    TimelinePhoto(id: asset.id, localPath: asset.resources.first { $0.role == "preview" }?.relativePath
                        ?? asset.resources.first { $0.role == "photo" || $0.role == "livePhotoImage" }?.relativePath,
                        fullSizePath: asset.resources.first { $0.role == "photo" || $0.role == "livePhotoImage" }?.relativePath,
                        kind: asset.kind, localResources: asset.resources)
                }
            )
        }
        let remoteEntries = remote.map { item in
            TimelineEntry(
                id: item.id,
                title: item.title,
                note: item.note,
                occurredAt: item.occurredAt,
                parent: item.parent,
                readOnly: true,
                mediaCount: item.mediaCount,
                previewPath: item.localPreviewPath,
                provenanceLabel: nil,
                photos: item.media.isEmpty ? item.previews.map { TimelinePhoto(id: $0.assetID, remote: $0) } : item.media.map { media in
                    TimelinePhoto(id: media.id, remote: item.previews.first(where: { $0.assetID == media.id }),
                                  kind: media.kind, remoteResources: media.resources)
                }
            )
        }
        return local + remoteEntries
    }

    public func writerPrefix() throws -> String {
        guard let identity else { throw ContractError(path: "identity", message: "请先选择爸爸或妈妈。") }
        return try V1Layout.chainPrefix(parent: identity, deviceID: deviceID, test: testBuild)
    }

    public func objectRoot() throws -> String {
        V1Layout.objectRoot(prefix: try writerPrefix())
    }
}

public struct PersistedArchive: Codable, Equatable {
    public static let currentVersion = 2
    public var schemaVersion: Int
    public var deviceID: String
    public var testBuild: Bool
    public var identityFolder: String?
    public var link: CloudLink
    public var moments: [LocalMoment]
    public var draft: ComposerDraft?
    public var remote: [RemoteMoment]
    public var anniversaries: [LocalAnniversary]
    public var remoteAnniversaries: [RemoteAnniversary]
    public var backupJob: BackupJob?
    public var committedDrafts: [String: String]

    public init(session: AppSession) {
        schemaVersion = Self.currentVersion
        deviceID = session.deviceID
        testBuild = session.testBuild
        identityFolder = session.identity?.folder
        link = session.link
        moments = session.moments
        draft = session.draft
        remote = session.remote
        anniversaries = session.anniversaries
        remoteAnniversaries = session.remoteAnniversaries
        backupJob = session.backupJob
        committedDrafts = session.committedDrafts
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, deviceID, testBuild, identityFolder, link, moments, draft, remote
        case anniversaries, remoteAnniversaries, backupJob, committedDrafts
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentVersion).contains(schemaVersion) else {
            throw ContractError(path: "archive.schemaVersion", message: "此档案需要更新版本的 App，原数据已保留。")
        }
        deviceID = try values.decode(String.self, forKey: .deviceID)
        testBuild = try values.decode(Bool.self, forKey: .testBuild)
        identityFolder = try values.decodeIfPresent(String.self, forKey: .identityFolder)
        if let identityFolder, ParentIdentity(folder: identityFolder) == nil {
            throw ContractError(path: "archive.identity", message: "档案身份无法识别，原数据已保留。")
        }
        link = try values.decode(CloudLink.self, forKey: .link)
        moments = try values.decode([LocalMoment].self, forKey: .moments)
        draft = try values.decodeIfPresent(ComposerDraft.self, forKey: .draft)
        remote = try values.decodeIfPresent([RemoteMoment].self, forKey: .remote) ?? []
        anniversaries = try values.decodeIfPresent([LocalAnniversary].self, forKey: .anniversaries) ?? []
        remoteAnniversaries = try values.decodeIfPresent([RemoteAnniversary].self, forKey: .remoteAnniversaries) ?? []
        backupJob = try values.decodeIfPresent(BackupJob.self, forKey: .backupJob)
        committedDrafts = try values.decodeIfPresent([String: String].self, forKey: .committedDrafts) ?? [:]
    }

    public func session() -> AppSession {
        AppSession(deviceID: deviceID, testBuild: testBuild,
                   identity: identityFolder.flatMap(ParentIdentity.init(folder:)), link: link,
                   moments: moments, draft: draft, remote: remote, anniversaries: anniversaries,
                   remoteAnniversaries: remoteAnniversaries, backupJob: backupJob, committedDrafts: committedDrafts)
    }
}

public enum BackupPlan {
    public static func manifest(session: AppSession, now: Int64) throws -> (prefix: String, manifest: V1Manifest, bytes: Data) {
        guard case .verified = session.link else {
            throw ContractError(path: "backup", message: "占位连接不会上传。请在真机填写密钥后再备份。")
        }
        let prefix = try session.writerPrefix()
        guard !V1Layout.isLegacyRoot(prefix) else {
            throw ContractError(path: "backup.prefix", message: "旧目录只读，不能写入。")
        }
        let includedMoments = backupMoments(session: session)
        let anniversaries = try session.backupAnniversaries()
        guard !includedMoments.isEmpty || !anniversaries.isEmpty else {
            throw ContractError(path: "backup", message: "没有可备份的记录。")
        }
        let moments = try includedMoments.map { moment -> V1Moment in
            V1Moment(
                id: try V1Ids.map(kind: "record", localID: moment.id),
                title: moment.title,
                note: moment.note,
                occurredAt: moment.occurredAt,
                createdAt: moment.createdAt,
                updatedAt: moment.updatedAt,
                assetIDs: try moment.assets.map { try V1Ids.map(kind: "asset", localID: $0.id) },
                trashedAt: moment.trashedAt,
                revision: moment.revision
            )
        }.sorted { $0.id < $1.id }
        let assets = try includedMoments.flatMap(\.assets).map { asset -> V1Asset in
            V1Asset(
                id: try V1Ids.map(kind: "asset", localID: asset.id),
                kind: asset.kind,
                capturedAt: asset.capturedAt,
                resourceIDs: try asset.resources.map { try V1Ids.map(kind: "resource", localID: $0.id) },
                importProvenance: asset.provenance
            )
        }.sorted { $0.id < $1.id }
        let resources = try includedMoments.flatMap(\.assets).flatMap { asset in
            try asset.resources.map { resource -> V1Resource in
                let hash = resource.sha256.lowercased()
                return V1Resource(
                    id: try V1Ids.map(kind: "resource", localID: resource.id),
                    assetID: try V1Ids.map(kind: "asset", localID: asset.id),
                    role: resource.role,
                    contentType: resource.contentType,
                    originalFilename: safeFilename(resource.originalFilename),
                    byteCount: resource.byteCount,
                    sha256: hash,
                    objectKey: V1Layout.objectKey(prefix: prefix, sha256: hash)
                )
            }
        }.sorted { $0.id < $1.id }
        let uniqueAssets = try deduplicate(assets, id: { $0.id })
        let uniqueResources = try deduplicate(resources, id: { $0.id })
        let manifest = V1Manifest(version: 2, moments: moments, assets: uniqueAssets, resources: uniqueResources, anniversaries: anniversaries)
        try V1Validator.validate(manifest: manifest, prefix: prefix)
        _ = now
        return (prefix, manifest, V1Json.encodeManifest(manifest))
    }

    private static func backupMoments(session: AppSession) -> [LocalMoment] {
        let eligibility: UploadEligibility = session.testBuild ? .testOnly : .eligible
        return session.moments.filter { $0.uploadEligibility == eligibility && $0.parent == session.identity }
    }

    private static func deduplicate<T: Equatable>(_ values: [T], id: (T) -> String) throws -> [T] {
        var unique: [String: T] = [:]
        for value in values {
            let key = id(value).uppercased()
            if let existing = unique[key], existing != value {
                throw ContractError(path: key, message: "媒体编号对应不同原件，已停止备份。")
            }
            unique[key] = value
        }
        return unique.keys.sorted().compactMap { unique[$0] }
    }

    public static func safeFilename(_ filename: String) -> String {
        let replaced = String(filename.map { character -> Character in
            if character == "/" || character == "\\" || character.unicodeScalars.contains(where: { $0.value < 32 }) {
                return "_"
            }
            return character
        })
        if replaced.isEmpty { return "import" }
        if replaced.utf16.count <= 255 { return replaced }
        // Android's wire limit is UTF-16 code units. Keep complete grapheme clusters as well
        // as complete surrogate pairs, so emoji and combining sequences remain readable.
        var result = ""
        var units = 0
        for character in replaced {
            let width = String(character).utf16.count
            guard units + width <= 255 else { break }
            result.append(character)
            units += width
        }
        return result.isEmpty ? "import" : result
    }
}

public struct BackupUpload: Equatable, Codable {
    public var objectKey: String
    public var relativePath: String
    public var contentType: String
    public var sha256: String
    public var byteCount: Int64
    public init(objectKey: String, relativePath: String, contentType: String, sha256: String, byteCount: Int64) {
        self.objectKey = objectKey
        self.relativePath = relativePath
        self.contentType = contentType
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

public extension BackupPlan {
    static func uploads(session: AppSession) throws -> [BackupUpload] {
        let planned = try manifest(session: session, now: 0)
        let locals = backupMoments(session: session).flatMap(\.assets).flatMap(\.resources)
        return try planned.manifest.resources.map { resource in
            guard let local = try locals.first(where: { try V1Ids.map(kind: "resource", localID: $0.id) == resource.id }) else {
                throw ContractError(path: resource.id, message: "原件还在本地，暂时找不到。")
            }
            return BackupUpload(
                objectKey: resource.objectKey,
                relativePath: local.relativePath,
                contentType: resource.contentType,
                sha256: resource.sha256,
                byteCount: resource.byteCount
            )
        }
    }
}

public enum BackupPublisher {
    public static func publish(client: CosClient, session: AppSession, files: [String: Data], now: Int64, requestID: String) throws -> V1Commit {
        try publish(client: client, session: session, now: now, requestID: requestID) { resource in
            guard let bytes = files[resource.objectKey] ?? files[resource.sha256] else {
                throw ContractError(path: resource.objectKey, message: "原件还在本地，暂时找不到。")
            }
            guard Digest.sha256Hex(bytes) == resource.sha256, Int64(bytes.count) == resource.byteCount else {
                throw ContractError(path: resource.objectKey, message: "原件和记录里的校验不一致，已停止备份。")
            }
            try client.putImmutable(key: resource.objectKey, body: bytes, contentType: resource.contentType)
        }
    }

    /// Production backup retains only URLs. Each media object is staged, verified, uploaded,
    /// and released independently instead of loading all originals into a Data dictionary.
    public static func publish(client: CosClient, session: AppSession, fileURLs: [String: URL], now: Int64, requestID: String) throws -> V1Commit {
        try publish(client: client, session: session, now: now, requestID: requestID) { resource in
            guard let url = fileURLs[resource.objectKey] ?? fileURLs[resource.sha256] else {
                throw ContractError(path: resource.objectKey, message: "原件还在本地，暂时找不到。")
            }
            try client.putImmutableFile(key: resource.objectKey, fileURL: url, byteCount: resource.byteCount,
                                        sha256: resource.sha256, contentType: resource.contentType)
        }
    }

    private static func publish(client: CosClient, session: AppSession, now: Int64, requestID: String,
                                upload: (V1Resource) throws -> Void) throws -> V1Commit {
        // Planning first preserves the no-network guarantee for placeholder/local-only archives.
        let planned = try BackupPlan.manifest(session: session, now: now)
        guard client.configuration.prefix == planned.prefix else { throw CosFailure(.configuration) }
        try client.verifyImmutableWritesAllowed()
        for resource in planned.manifest.resources {
            guard resource.objectKey.hasPrefix(V1Layout.objectRoot(prefix: planned.prefix)) else {
                throw CosFailure(.configuration)
            }
            try upload(resource)
        }
        let manifestBytes = planned.bytes
        let manifestHash = Digest.sha256Hex(manifestBytes)
        try client.putImmutable(key: planned.prefix + "snapshots/\(manifestHash).json", body: manifestBytes, contentType: "application/json")
        let receipt = try FamilyReader.latest(client: client, prefix: planned.prefix)
        let sequence = (receipt?.commit.sequence ?? 0) + 1
        let commit = V1Commit(
            sequence: sequence,
            parentHash: receipt?.commitHash,
            writerDeviceID: try V1Ids.canonical(session.deviceID, path: "writerDeviceID"),
            manifestHash: manifestHash,
            manifestKey: planned.prefix + "snapshots/\(manifestHash).json",
            createdAt: now,
            requestID: try V1Ids.canonical(requestID, path: "requestID")
        )
        let commitBytes = V1Json.encodeCommit(commit)
        let commitKey = planned.prefix + V1Json.commitRelativeKey(sequence)
        try V1Validator.validateCommit(commit: commit, key: commitKey, prefix: planned.prefix, previous: receipt?.commit, previousHash: receipt?.commitHash)
        try client.putImmutable(key: commitKey, body: commitBytes, contentType: "application/json")
        return commit
    }
}
