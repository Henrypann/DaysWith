import Foundation

enum V1Validator {
    static let maxTimestamp: Int64 = 8_640_000_000_000_000
    static let maxRevision: Int64 = 9_007_199_254_740_991
    static let maxResourceBytes: Int64 = 2_147_483_648
    private static let hash = #"^[a-f0-9]{64}$"#

    static func validate(manifest: V1Manifest, prefix: String) throws {
        try V1Layout.validatePrefix(prefix)
        guard (1...2).contains(manifest.version) else {
            throw ContractError(path: "manifest.version", message: "This archive needs a newer app version.")
        }
        if manifest.version != 2 && !manifest.anniversaries.isEmpty {
            throw ContractError(path: "manifest.anniversaries", message: "Anniversaries require version 2.")
        }
        try identities("anniversaries", manifest.anniversaries.map(\.id))
        for anniversary in manifest.anniversaries {
            let entity = "anniversaries[\(anniversary.id)]"
            guard V1Layout.owns(owner: anniversary.owner, prefix: prefix) else {
                throw ContractError(path: "\(entity).owner", message: "Anniversary belongs to another parent.")
            }
            _ = try AnniversaryCalendar.normalizedDate(anniversary.date)
            if let deletedAt = anniversary.deletedAt { try timestamp(deletedAt, "\(entity).deletedAt") }
            guard !anniversary.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, anniversary.title.utf16.count <= 100 else {
                throw ContractError(path: "\(entity).title", message: "Invalid anniversary title.")
            }
        }
        try identities("moments", manifest.moments.map(\.id))
        try identities("assets", manifest.assets.map(\.id))
        try identities("resources", manifest.resources.map(\.id))
        try manifest.moments.forEach(validateMoment)
        let assets = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.id.uppercased(), $0) })
        var used = Set<String>()
        for moment in manifest.moments {
            let entity = "moments[\(moment.id)]"
            for id in moment.assetIDs {
                guard assets[id.uppercased()] != nil else {
                    throw ContractError(path: "\(entity).assetIDs", message: "A selected media item is missing: \(id).")
                }
                used.insert(id.uppercased())
            }
        }
        if let orphan = assets.keys.first(where: { !used.contains($0) }) {
            throw ContractError(path: "assets[\(orphan)].id", message: "Archive contains unreferenced media.")
        }
        for resource in manifest.resources where !used.contains(resource.assetID.uppercased()) {
            throw ContractError(path: "resources[\(resource.id)].assetID", message: "Archive contains missing or unreferenced media.")
        }
        let grouped = Dictionary(grouping: manifest.resources, by: { $0.assetID.uppercased() })
        for asset in manifest.assets {
            try validateAsset(asset, resources: grouped[asset.id.uppercased()] ?? [])
        }
        var seen: [String: V1Resource] = [:]
        for resource in manifest.resources {
            let entity = "resources[\(resource.id)]"
            guard resource.objectKey == V1Layout.objectKey(prefix: prefix, sha256: resource.sha256) else {
                throw ContractError(path: "\(entity).objectKey", message: "Archive contains an invalid object reference.")
            }
            if let first = seen[resource.objectKey], first.byteCount != resource.byteCount || first.sha256 != resource.sha256 {
                throw ContractError(path: "\(entity).objectKey", message: "The file does not match its saved hash or byteCount.")
            }
            seen[resource.objectKey] = resource
        }
    }

    static func validateCommit(commit: V1Commit, key: String, prefix: String, previous: V1Commit?, previousHash: String?) throws {
        try V1Layout.validatePrefix(prefix)
        let entity = "commits[\(commit.sequence)]"
        guard commit.version == 1 else { throw ContractError(path: "\(entity).version", message: "The archive commit chain is incomplete or invalid.") }
        let expected = (previous?.sequence ?? 0) + 1
        guard commit.sequence > 0, commit.sequence == expected else {
            throw ContractError(path: "\(entity).sequence", message: "The archive commit chain is incomplete or invalid.")
        }
        guard key == prefix + V1Json.commitRelativeKey(commit.sequence) else {
            throw ContractError(path: "\(entity).key", message: "The archive commit chain is incomplete or invalid.")
        }
        guard (previous == nil) == (previousHash == nil), commit.parentHash == previousHash else {
            throw ContractError(path: "\(entity).parentHash", message: "The archive commit chain is incomplete or invalid.")
        }
        _ = try V1Ids.canonical(commit.writerDeviceID, path: "\(entity).writerDeviceID")
        _ = try V1Ids.canonical(commit.requestID, path: "\(entity).requestID")
        guard commit.kind == "snapshot" || commit.kind == "takeover" else {
            throw ContractError(path: "\(entity).kind", message: "The archive commit chain is incomplete or invalid.")
        }
        if previous == nil && commit.kind != "snapshot" {
            throw ContractError(path: "\(entity).kind", message: "The archive commit chain is incomplete or invalid.")
        }
        if let previous, commit.kind != "takeover", commit.writerDeviceID.uppercased() != previous.writerDeviceID.uppercased() {
            throw ContractError(path: "\(entity).writerDeviceID", message: "The archive commit chain is incomplete or invalid.")
        }
        guard commit.manifestHash.range(of: hash, options: .regularExpression) != nil else {
            throw ContractError(path: "\(entity).manifestHash", message: "The archive commit chain is incomplete or invalid.")
        }
        guard commit.manifestKey == prefix + "snapshots/\(commit.manifestHash).json" else {
            throw ContractError(path: "\(entity).manifestKey", message: "The archive commit chain is incomplete or invalid.")
        }
        try timestamp(commit.createdAt, "\(entity).createdAt")
    }

    private static func validateMoment(_ moment: V1Moment) throws {
        let entity = "moments[\(moment.id)]"
        guard moment.title.utf16.count <= 200 else {
            throw ContractError(path: "\(entity).title", message: "Title is limited to 200 UTF-16 characters.")
        }
        guard moment.note.utf16.count <= 10_000 else {
            throw ContractError(path: "\(entity).note", message: "Note is limited to 10,000 UTF-16 characters.")
        }
        try timestamp(moment.occurredAt, "\(entity).occurredAt")
        try timestamp(moment.createdAt, "\(entity).createdAt")
        try timestamp(moment.updatedAt, "\(entity).updatedAt")
        if let trashedAt = moment.trashedAt { try timestamp(trashedAt, "\(entity).trashedAt") }
        guard (0...maxRevision).contains(moment.revision) else {
            throw ContractError(path: "\(entity).revision", message: "Invalid record version.")
        }
        let distinct = Set(moment.assetIDs.map { $0.uppercased() })
        guard (0...30).contains(moment.assetIDs.count), distinct.count == moment.assetIDs.count else {
            throw ContractError(path: "\(entity).assetIDs", message: "Choose 0–30 distinct media items.")
        }
        let hasText = !moment.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !moment.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !moment.assetIDs.isEmpty || hasText else {
            throw ContractError(path: "\(entity).assetIDs", message: "Add a title, note, or media item.")
        }
    }

    private static func validateAsset(_ asset: V1Asset, resources: [V1Resource]) throws {
        let entity = "assets[\(asset.id)]"
        try timestamp(asset.capturedAt, "\(entity).capturedAt")
        guard (0...maxRevision).contains(asset.revision) else {
            throw ContractError(path: "\(entity).revision", message: "Invalid record version.")
        }
        let expected: Set<String>
        switch asset.kind {
        case "photo": expected = ["photo", "preview"]
        case "video": expected = ["video", "preview"]
        case "motionPhoto": expected = ["motionPhoto", "preview"]
        case "livePhoto": expected = ["livePhotoImage", "livePhotoVideo", "preview"]
        default:
            throw ContractError(path: "\(entity).kind", message: "Invalid media kind.")
        }
        let ids = Set(asset.resourceIDs.map { $0.uppercased() })
        let roles = Set(resources.map(\.role))
        guard ids.count == asset.resourceIDs.count, resources.count == ids.count, resources.count == expected.count,
              resources.allSatisfy({ ids.contains($0.id.uppercased()) }), roles == expected else {
            throw ContractError(path: "\(entity).resourceIDs.role", message: "A complete original and a preview are required.")
        }
        for resource in resources {
            let resourceEntity = "resources[\(resource.id)]"
            guard (1...maxResourceBytes).contains(resource.byteCount) else {
                throw ContractError(path: "\(resourceEntity).byteCount", message: "Invalid media resource size.")
            }
            guard resource.sha256.range(of: hash, options: .regularExpression) != nil else {
                throw ContractError(path: "\(resourceEntity).sha256", message: "Expected a lowercase SHA-256 hash.")
            }
            let typePrefix = (resource.role == "video" || resource.role == "livePhotoVideo") ? "video" : "image"
            let typeOK = resource.contentType.utf16.count <= 120
                && resource.contentType.range(of: "^\(typePrefix)/[A-Za-z0-9.+-]+$", options: .regularExpression) != nil
            guard typeOK else {
                throw ContractError(path: "\(resourceEntity).contentType", message: "The media type is invalid for role \(resource.role).")
            }
            let nameOK = (1...255).contains(resource.originalFilename.utf16.count)
                && !resource.originalFilename.contains("/") && !resource.originalFilename.contains("\\")
                && resource.originalFilename.unicodeScalars.allSatisfy { $0.value >= 32 }
            guard nameOK else {
                throw ContractError(path: "\(resourceEntity).originalFilename", message: "The original filename is invalid.")
            }
        }
    }

    private static func identities(_ kind: String, _ ids: [String]) throws {
        var seen = Set<String>()
        for id in ids {
            _ = try V1Ids.canonical(id, path: "\(kind)[\(id)].id")
            guard seen.insert(id.uppercased()).inserted else {
                throw ContractError(path: "\(kind)[\(id)].id", message: "Archive contains duplicate identities.")
            }
        }
    }

    private static func timestamp(_ value: Int64, _ path: String) throws {
        guard (0...maxTimestamp).contains(value) else {
            throw ContractError(path: path, message: "Choose a valid record date.")
        }
    }
}
