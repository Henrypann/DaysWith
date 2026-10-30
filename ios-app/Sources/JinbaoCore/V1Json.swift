import Foundation

enum V1Json {
    static func encodeManifest(_ manifest: V1Manifest) -> Data {
        var fields: [String: JSONValue] = [
            "version": .int(Int64(manifest.version)),
            "moments": .array(manifest.moments.map(momentValue)),
            "assets": .array(manifest.assets.map(assetValue)),
            "resources": .array(manifest.resources.map(resourceValue)),
        ]
        if manifest.version >= 2 {
            fields["anniversaries"] = .array(manifest.anniversaries.map(anniversaryValue))
        }
        return JSONWire.encode(.object(fields))
    }

    static func encodeCommit(_ commit: V1Commit) -> Data {
        var fields: [String: JSONValue] = [
            "version": .int(Int64(commit.version)),
            "sequence": .int(commit.sequence),
            "writerDeviceID": .string(commit.writerDeviceID),
            "kind": .string(commit.kind),
            "manifestHash": .string(commit.manifestHash),
            "manifestKey": .string(commit.manifestKey),
            "createdAt": .int(commit.createdAt),
            "requestID": .string(commit.requestID),
        ]
        if let parentHash = commit.parentHash { fields["parentHash"] = .string(parentHash) }
        return JSONWire.encode(.object(fields))
    }

    static func decodeManifest(_ data: Data) throws -> V1Manifest {
        let root = try object(JSONWire.parse(data, path: "manifest"), path: "manifest")
        let version = try int32(root, "version", "manifest")
        let moments = try array(root, "moments", "manifest").enumerated().map { index, raw in
            let path = "moments[\(index)]"
            let item = try object(raw, path: path)
            return V1Moment(
                id: try uuid(item, "id", path),
                title: try text(item, "title", path),
                note: try text(item, "note", path),
                occurredAt: try long(item, "occurredAt", path),
                createdAt: try long(item, "createdAt", path),
                updatedAt: try long(item, "updatedAt", path),
                assetIDs: try ids(item, "assetIDs", path),
                trashedAt: try optionalLong(item, "trashedAt", path),
                revision: try long(item, "revision", path),
                deviceManufacturer: optionalText(item, "deviceManufacturer"),
                deviceModel: optionalText(item, "deviceModel")
            )
        }
        let assets = try array(root, "assets", "manifest").enumerated().map { index, raw in
            let path = "assets[\(index)]"
            let item = try object(raw, path: path)
            return V1Asset(
                id: try uuid(item, "id", path),
                kind: try text(item, "kind", path),
                capturedAt: try long(item, "capturedAt", path),
                resourceIDs: try ids(item, "resourceIDs", path),
                revision: try long(item, "revision", path),
                importProvenance: ImportProvenance.known(optionalText(item, "importProvenance"))?.rawValue
            )
        }
        let resources = try array(root, "resources", "manifest").enumerated().map { index, raw in
            let path = "resources[\(index)]"
            let item = try object(raw, path: path)
            return V1Resource(
                id: try uuid(item, "id", path),
                assetID: try uuid(item, "assetID", path),
                role: try text(item, "role", path),
                contentType: try text(item, "contentType", path),
                originalFilename: try text(item, "originalFilename", path),
                byteCount: try long(item, "byteCount", path),
                sha256: try text(item, "sha256", path),
                objectKey: try text(item, "objectKey", path)
            )
        }
        let anniversaries: [V1Anniversary]
        if version >= 2 {
            anniversaries = try array(root, "anniversaries", "manifest").enumerated().map { index, raw in
                let path = "anniversaries[\(index)]"
                let item = try object(raw, path: path)
                let ownerText = try text(item, "owner", path)
                guard let owner = ParentIdentity(folder: ownerText) else {
                    throw ContractError(path: path, message: "Invalid parent identity.")
                }
                return V1Anniversary(
                    id: try uuid(item, "id", path),
                    owner: owner,
                    title: try text(item, "title", path),
                    date: try text(item, "date", path),
                    deletedAt: try optionalLong(item, "deletedAt", path)
                )
            }
        } else {
            anniversaries = []
        }
        var manifest = V1Manifest(version: version, moments: moments, assets: assets, resources: resources, anniversaries: anniversaries)
        if root["items"] != nil {
            let referenced = Set(manifest.moments.flatMap { $0.assetIDs.map { $0.uppercased() } })
            manifest.assets = manifest.assets.filter { referenced.contains($0.id.uppercased()) }
            manifest.resources = manifest.resources.filter { referenced.contains($0.assetID.uppercased()) }
        }
        return manifest
    }

    static func decodeCommit(_ data: Data) throws -> V1Commit {
        let item = try object(JSONWire.parse(data, path: "commit"), path: "commit")
        return V1Commit(
            version: try int32(item, "version", "commit"),
            sequence: try long(item, "sequence", "commit"),
            parentHash: optionalText(item, "parentHash"),
            writerDeviceID: try uuid(item, "writerDeviceID", "commit"),
            kind: try text(item, "kind", "commit"),
            manifestHash: try text(item, "manifestHash", "commit"),
            manifestKey: try text(item, "manifestKey", "commit"),
            createdAt: try long(item, "createdAt", "commit"),
            requestID: try uuid(item, "requestID", "commit")
        )
    }

    static func commitRelativeKey(_ sequence: Int64) -> String {
        let width = sequence < 0 ? 19 : 20
        let body = sequence < 0 ? String(String(sequence).dropFirst()) : String(sequence)
        let padded = String(repeating: "0", count: max(0, width - body.count)) + body
        if sequence < 0 { return "commits/-\(padded).json" }
        return "commits/\(padded).json"
    }

    private static func momentValue(_ moment: V1Moment) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(moment.id),
            "title": .string(moment.title),
            "note": .string(moment.note),
            "occurredAt": .int(moment.occurredAt),
            "createdAt": .int(moment.createdAt),
            "updatedAt": .int(moment.updatedAt),
            "revision": .int(moment.revision),
            "assetIDs": .array(moment.assetIDs.map { .string($0) }),
        ]
        if let trashedAt = moment.trashedAt { fields["trashedAt"] = .int(trashedAt) }
        if let value = moment.deviceManufacturer { fields["deviceManufacturer"] = .string(value) }
        if let value = moment.deviceModel { fields["deviceModel"] = .string(value) }
        return .object(fields)
    }

    private static func assetValue(_ asset: V1Asset) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(asset.id),
            "kind": .string(asset.kind),
            "capturedAt": .int(asset.capturedAt),
            "revision": .int(asset.revision),
            "resourceIDs": .array(asset.resourceIDs.map { .string($0) }),
        ]
        if let provenance = ImportProvenance.known(asset.importProvenance) {
            fields["importProvenance"] = .string(provenance.rawValue)
        }
        return .object(fields)
    }

    private static func resourceValue(_ resource: V1Resource) -> JSONValue {
        .object([
            "id": .string(resource.id),
            "assetID": .string(resource.assetID),
            "role": .string(resource.role),
            "contentType": .string(resource.contentType),
            "originalFilename": .string(resource.originalFilename),
            "byteCount": .int(resource.byteCount),
            "sha256": .string(resource.sha256),
            "objectKey": .string(resource.objectKey),
        ])
    }

    private static func anniversaryValue(_ anniversary: V1Anniversary) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(anniversary.id),
            "owner": .string(anniversary.owner.folder),
            "title": .string(anniversary.title),
            "date": .string(anniversary.date),
        ]
        if let deletedAt = anniversary.deletedAt { fields["deletedAt"] = .int(deletedAt) }
        return .object(fields)
    }

    private static func object(_ value: JSONValue, path: String) throws -> [String: JSONValue] {
        guard let object = value.object else { throw ContractError(path: path, message: "Expected an object.") }
        return object
    }

    private static func array(_ object: [String: JSONValue], _ key: String, _ path: String) throws -> [JSONValue] {
        guard let value = object[key] else { throw ContractError(path: "\(path).\(key)", message: "Required field is missing.") }
        guard let array = value.array else { throw ContractError(path: "\(path).\(key)", message: "Expected an array.") }
        return array
    }

    private static func text(_ object: [String: JSONValue], _ key: String, _ path: String) throws -> String {
        guard let value = object[key] else { throw ContractError(path: "\(path).\(key)", message: "Required field is missing.") }
        guard let text = value.string else { throw ContractError(path: "\(path).\(key)", message: "Expected a string.") }
        return text
    }

    private static func optionalText(_ object: [String: JSONValue], _ key: String) -> String? {
        if case .string(let text)? = object[key] { return text }
        return nil
    }

    private static func long(_ object: [String: JSONValue], _ key: String, _ path: String) throws -> Int64 {
        guard let value = object[key] else { throw ContractError(path: "\(path).\(key)", message: "Required field is missing.") }
        guard let number = value.int else { throw ContractError(path: "\(path).\(key)", message: "Expected an integer.") }
        return number
    }

    private static func optionalLong(_ object: [String: JSONValue], _ key: String, _ path: String) throws -> Int64? {
        guard let value = object[key], value != .null else { return nil }
        guard let number = value.int else { throw ContractError(path: "\(path).\(key)", message: "Expected an integer.") }
        return number
    }

    private static func int32(_ object: [String: JSONValue], _ key: String, _ path: String) throws -> Int {
        let number = try long(object, key, path)
        guard number >= Int64(Int32.min), number <= Int64(Int32.max) else {
            throw ContractError(path: "\(path).\(key)", message: "Integer is outside Int32 range.")
        }
        return Int(number)
    }

    private static func uuid(_ object: [String: JSONValue], _ key: String, _ path: String) throws -> String {
        try V1Ids.canonical(try text(object, key, path), path: "\(path).\(key)")
    }

    private static func ids(_ object: [String: JSONValue], _ key: String, _ path: String) throws -> [String] {
        try array(object, key, path).enumerated().map { index, value in
            let field = "\(path).\(key)[\(index)]"
            guard let text = value.string else { throw ContractError(path: field, message: "Expected a string.") }
            return try V1Ids.canonical(text, path: field)
        }
    }
}
