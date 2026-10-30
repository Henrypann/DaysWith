import Foundation

public struct ChainSnapshot: Equatable {
    public var parent: ParentIdentity
    public var prefix: String
    public var writer: String
    public var createdAt: Int64
    public var manifest: V1Manifest

    public init(parent: ParentIdentity, prefix: String, writer: String, createdAt: Int64, manifest: V1Manifest) {
        self.parent = parent
        self.prefix = prefix
        self.writer = writer
        self.createdAt = createdAt
        self.manifest = manifest
    }
}

/// A bounded image reference derived from a validated family manifest, never an arbitrary URL.
public struct RemotePreview: Equatable, Hashable, Codable, Identifiable {
    public static let maximumBytes: Int64 = 8 * 1024 * 1024
    public var assetID: String
    public var parent: ParentIdentity
    public var chainPrefix: String
    public var objectKey: String
    public var sha256: String
    public var byteCount: Int64
    public var contentType: String
    public var id: String { parent.folder + ":" + sha256 }

    public init(assetID: String, parent: ParentIdentity, chainPrefix: String, objectKey: String,
                sha256: String, byteCount: Int64, contentType: String) {
        self.assetID = assetID
        self.parent = parent
        self.chainPrefix = chainPrefix
        self.objectKey = objectKey
        self.sha256 = sha256
        self.byteCount = byteCount
        self.contentType = contentType
    }

    public func validate() throws {
        let root = parent.prefix
        let suffix = chainPrefix.hasPrefix(root) ? String(chainPrefix.dropFirst(root.count)) : "invalid"
        let validChain = suffix.isEmpty || (suffix.hasSuffix("/") && V1Layout.isDeviceSegment(String(suffix.dropLast())))
        guard validChain, chainPrefix.hasPrefix(root),
              sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              objectKey == V1Layout.objectKey(prefix: chainPrefix, sha256: sha256),
              (1...Self.maximumBytes).contains(byteCount),
              ["image/jpeg", "image/png", "image/heic", "image/heif", "image/webp", "image/gif"].contains(contentType) else {
            throw CosFailure(.contentMismatch)
        }
    }

    public func validate(data: Data) throws {
        try validate()
        guard Int64(data.count) == byteCount, Digest.sha256Hex(data) == sha256 else { throw CosFailure(.contentMismatch) }
    }
}

/// Original reference from a validated family chain; only dad/mom immutable object roots are accepted.
public struct RemoteResource: Equatable, Hashable, Codable, Identifiable {
    public static let maximumBytes: Int64 = 2_147_483_648
    public var id: String
    public var assetID: String
    public var role: String
    public var parent: ParentIdentity
    public var chainPrefix: String
    public var objectKey: String
    public var sha256: String
    public var byteCount: Int64
    public var contentType: String
    public var originalFilename: String
    public init(id: String, assetID: String, role: String, parent: ParentIdentity, chainPrefix: String,
                objectKey: String, sha256: String, byteCount: Int64, contentType: String, originalFilename: String) {
        self.id = id; self.assetID = assetID; self.role = role; self.parent = parent; self.chainPrefix = chainPrefix
        self.objectKey = objectKey; self.sha256 = sha256; self.byteCount = byteCount
        self.contentType = contentType; self.originalFilename = originalFilename
    }
    public func validate() throws {
        let root = parent.prefix
        let suffix = chainPrefix.hasPrefix(root) ? String(chainPrefix.dropFirst(root.count)) : "invalid"
        let validChain = suffix.isEmpty || (suffix.hasSuffix("/") && V1Layout.isDeviceSegment(String(suffix.dropLast())))
        let video = role == "video" || role == "livePhotoVideo"
        guard validChain, chainPrefix.hasPrefix(root),
              ["photo", "video", "livePhotoImage", "livePhotoVideo", "motionPhoto", "preview"].contains(role),
              sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              objectKey == V1Layout.objectKey(prefix: chainPrefix, sha256: sha256),
              (1...Self.maximumBytes).contains(byteCount),
              contentType.utf16.count <= 120,
              contentType.range(of: video ? #"^video/[A-Za-z0-9.+-]+$"# : #"^image/[A-Za-z0-9.+-]+$"#, options: .regularExpression) != nil,
              !originalFilename.isEmpty, originalFilename.utf16.count <= 255,
              !originalFilename.contains("/"), !originalFilename.contains("\\"),
              originalFilename.unicodeScalars.allSatisfy({ $0.value >= 32 }) else { throw CosFailure(.contentMismatch) }
    }
    public func validate(data: Data) throws {
        try validate()
        guard Int64(data.count) == byteCount, Digest.sha256Hex(data) == sha256 else { throw CosFailure(.contentMismatch) }
    }
}

public struct RemoteMedia: Equatable, Codable, Identifiable {
    public var id: String
    public var kind: String
    public var capturedAt: Int64
    public var resources: [RemoteResource]
    public init(id: String, kind: String, capturedAt: Int64, resources: [RemoteResource]) {
        self.id = id; self.kind = kind; self.capturedAt = capturedAt; self.resources = resources
    }
}

public struct RemoteMoment: Equatable, Codable, Identifiable {
    public var id: String
    public var parent: ParentIdentity
    public var title: String
    public var note: String
    public var occurredAt: Int64
    public var readOnly: Bool
    public var mediaCount: Int
    public var previewObjectKey: String?
    public var localPreviewPath: String?
    public var previews: [RemotePreview]
    public var media: [RemoteMedia]

    public init(id: String, parent: ParentIdentity, title: String, note: String, occurredAt: Int64,
                readOnly: Bool = true, mediaCount: Int = 0, previewObjectKey: String? = nil, localPreviewPath: String? = nil,
                previews: [RemotePreview] = [], media: [RemoteMedia] = []) {
        self.id = id
        self.parent = parent
        self.title = title
        self.note = note
        self.occurredAt = occurredAt
        self.readOnly = readOnly
        self.mediaCount = mediaCount
        self.previewObjectKey = previewObjectKey
        self.localPreviewPath = localPreviewPath
        self.previews = previews
        self.media = media
    }

    private enum CodingKeys: String, CodingKey {
        case id, parent, title, note, occurredAt, readOnly, mediaCount, previewObjectKey, localPreviewPath, previews, media
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        parent = try values.decode(ParentIdentity.self, forKey: .parent)
        title = try values.decode(String.self, forKey: .title)
        note = try values.decode(String.self, forKey: .note)
        occurredAt = try values.decode(Int64.self, forKey: .occurredAt)
        readOnly = true
        mediaCount = try values.decodeIfPresent(Int.self, forKey: .mediaCount) ?? 0
        previewObjectKey = try values.decodeIfPresent(String.self, forKey: .previewObjectKey)
        localPreviewPath = try values.decodeIfPresent(String.self, forKey: .localPreviewPath)
        let decodedParent = parent
        previews = ((try? values.decode([RemotePreview].self, forKey: .previews)) ?? []).filter {
            $0.parent == decodedParent && (try? $0.validate()) != nil
        }
        media = (try values.decodeIfPresent([RemoteMedia].self, forKey: .media) ?? []).filter {
            $0.resources.allSatisfy { $0.parent == decodedParent && (try? $0.validate()) != nil }
        }
    }
}

/// Read-side merge. Newest edit wins. A newer deletion hides the older copy. Nothing here writes or deletes.
public enum ArchiveMerge {
    public static func merge(_ sources: [ChainSnapshot]) -> [RemoteMoment] {
        struct Copy {
            var parent: ParentIdentity
            var moment: V1Moment
            var manifest: V1Manifest
            var prefix: String
        }
        let copies = sources.flatMap { source in
            source.manifest.moments.map { moment in
                (key: "\(source.parent.folder):\(moment.id.uppercased())", copy: Copy(parent: source.parent, moment: moment, manifest: source.manifest, prefix: source.prefix))
            }
        }
        let grouped = Dictionary(grouping: copies, by: \.key)
        var hidden = Set<String>()
        var winners: [(String, Copy)] = []
        for (key, group) in grouped {
            let best = group.map(\.copy).max { lhs, rhs in
                if lhs.moment.updatedAt != rhs.moment.updatedAt { return lhs.moment.updatedAt < rhs.moment.updatedAt }
                if lhs.moment.revision != rhs.moment.revision { return lhs.moment.revision < rhs.moment.revision }
                return lhs.moment.trashedAt == nil && rhs.moment.trashedAt != nil
            }
            guard let best else { continue }
            if best.moment.trashedAt != nil {
                hidden.insert(remoteID(parent: best.parent, momentID: best.moment.id))
            } else {
                winners.append((key, best))
            }
        }
        return winners.compactMap { _, copy in
            let id = remoteID(parent: copy.parent, momentID: copy.moment.id)
            guard !hidden.contains(id), copy.moment.trashedAt == nil else { return nil }
            let resources = copy.manifest.resources
            let previews = copy.moment.assetIDs.compactMap { assetID -> RemotePreview? in
                guard let asset = copy.manifest.assets.first(where: { $0.id.uppercased() == assetID.uppercased() }),
                      let resource = resources.first(where: {
                          $0.assetID.uppercased() == assetID.uppercased() && $0.role == "preview"
                              && asset.resourceIDs.map { $0.uppercased() }.contains($0.id.uppercased())
                      }) else { return nil }
                let reference = RemotePreview(assetID: assetID, parent: copy.parent, chainPrefix: copy.prefix,
                                              objectKey: resource.objectKey, sha256: resource.sha256,
                                              byteCount: resource.byteCount, contentType: resource.contentType)
                guard (try? reference.validate()) != nil else { return nil }
                return reference
            }
            let media = copy.moment.assetIDs.compactMap { assetID -> RemoteMedia? in
                guard let asset = copy.manifest.assets.first(where: { $0.id.uppercased() == assetID.uppercased() }) else { return nil }
                let originals = asset.resourceIDs.compactMap { id -> RemoteResource? in
                    guard let r = resources.first(where: { $0.id.uppercased() == id.uppercased() && $0.assetID.uppercased() == assetID.uppercased() }) else { return nil }
                    let reference = RemoteResource(id: r.id, assetID: assetID, role: r.role, parent: copy.parent,
                                                   chainPrefix: copy.prefix, objectKey: r.objectKey, sha256: r.sha256,
                                                   byteCount: r.byteCount, contentType: r.contentType, originalFilename: r.originalFilename)
                    return (try? reference.validate()) == nil ? nil : reference
                }
                return RemoteMedia(id: assetID, kind: asset.kind, capturedAt: asset.capturedAt, resources: originals)
            }
            return RemoteMoment(
                id: id,
                parent: copy.parent,
                title: copy.moment.title,
                note: copy.moment.note,
                occurredAt: copy.moment.occurredAt,
                mediaCount: copy.moment.assetIDs.count,
                previewObjectKey: previews.first?.objectKey,
                previews: previews, media: media
            )
        }
    }

    public static func mergeAnniversaries(_ sources: [ChainSnapshot]) -> [RemoteAnniversary] {
        var winners: [String: RemoteAnniversary] = [:]
        for source in sources.sorted(by: { $0.prefix < $1.prefix }) {
            for item in source.manifest.anniversaries {
                guard item.owner == source.parent, (try? AnniversaryCalendar.normalizedDate(item.date)) != nil else { continue }
                let candidate = RemoteAnniversary(recordID: item.id, owner: item.owner, title: item.title,
                                                  date: item.date, deletedAt: item.deletedAt,
                                                  sourcePrefix: source.prefix, updatedAt: source.createdAt)
                let key = item.owner.folder + ":" + item.id.uppercased()
                if let existing = winners[key], existing.updatedAt > candidate.updatedAt { continue }
                if let existing = winners[key], existing.updatedAt == candidate.updatedAt, existing.deletedAt != nil, candidate.deletedAt == nil { continue }
                winners[key] = candidate
            }
        }
        // Keep tombstones to suppress virtual built-ins as well as stale remote copies.
        return winners.keys.sorted().compactMap { winners[$0] }
    }

    public static func remoteID(parent: ParentIdentity, momentID: String) -> String {
        "remote:\(parent.folder):record:\(momentID.uppercased())"
    }
}

public struct CommitReceipt: Equatable {
    public var commit: V1Commit
    public var commitHash: String
    public var manifest: V1Manifest
    public init(commit: V1Commit, commitHash: String, manifest: V1Manifest) {
        self.commit = commit
        self.commitHash = commitHash
        self.manifest = manifest
    }
}

public struct FamilyArchive: Equatable {
    public var moments: [RemoteMoment]
    public var anniversaries: [RemoteAnniversary]
    public init(moments: [RemoteMoment], anniversaries: [RemoteAnniversary]) {
        self.moments = moments; self.anniversaries = anniversaries
    }
}

public enum FamilyReader {
    /// Lists dad and mom only. Legacy roots stay read-only. This device's own chain is skipped.
    /// `life/v1/test/` is not part of the family read.
    public static func read(client: CosClient, owner: ParentIdentity, deviceID: String, testBuild: Bool) throws -> [RemoteMoment] {
        try readArchive(client: client, owner: owner, deviceID: deviceID, testBuild: testBuild).moments
    }

    public static func readArchive(client: CosClient, owner: ParentIdentity, deviceID: String, testBuild: Bool) throws -> FamilyArchive {
        guard client.configuration.prefix == "life/v1/" else { throw CosFailure(.configuration) }
        var sources: [ChainSnapshot] = []
        for parent in [owner.other, owner] {
            let root = parent.prefix
            let keys = try client.list(prefix: root)
            let chains = V1Layout.chainsUnder(root: root, keys: keys)
            let own = (parent == owner && !testBuild) ? try V1Layout.chainPrefix(parent: owner, deviceID: deviceID, test: false) : nil
            for chain in chains {
                if let own, chain == own { continue }
                guard let receipt = try latest(client: client, prefix: chain) else { continue }
                if parent == owner && receipt.commit.writerDeviceID.uppercased() == deviceID.uppercased() { continue }
                sources.append(ChainSnapshot(
                    parent: parent,
                    prefix: chain,
                    writer: receipt.commit.writerDeviceID,
                    createdAt: receipt.commit.createdAt,
                    manifest: receipt.manifest
                ))
            }
        }
        return FamilyArchive(moments: ArchiveMerge.merge(sources), anniversaries: ArchiveMerge.mergeAnniversaries(sources))
    }

    static func latest(client: CosClient, prefix: String) throws -> CommitReceipt? {
        let keys = try client.list(prefix: prefix + "commits/").sorted()
        var previous: V1Commit?
        var previousHash: String?
        for key in keys {
            let bytes = try client.get(key: key)
            let commit = try V1Json.decodeCommit(bytes)
            try V1Validator.validateCommit(commit: commit, key: key, prefix: prefix, previous: previous, previousHash: previousHash)
            previous = commit
            previousHash = Digest.sha256Hex(bytes)
        }
        guard let commit = previous, let previousHash else { return nil }
        let manifestBytes = try client.get(key: commit.manifestKey)
        guard Digest.sha256Hex(manifestBytes) == commit.manifestHash else {
            throw ContractError(path: "commits[\(commit.sequence)].manifestHash", message: "The file does not match its saved hash.")
        }
        let manifest = try V1Json.decodeManifest(manifestBytes)
        try V1Validator.validate(manifest: manifest, prefix: prefix)
        return CommitReceipt(commit: commit, commitHash: previousHash, manifest: manifest)
    }
}
