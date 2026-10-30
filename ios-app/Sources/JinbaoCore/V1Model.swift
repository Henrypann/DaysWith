import Foundation

public struct V1Commit: Equatable {
    public var version: Int
    public var sequence: Int64
    public var parentHash: String?
    public var writerDeviceID: String
    public var kind: String
    public var manifestHash: String
    public var manifestKey: String
    public var createdAt: Int64
    public var requestID: String

    public init(version: Int = 1, sequence: Int64, parentHash: String? = nil, writerDeviceID: String,
                kind: String = "snapshot", manifestHash: String, manifestKey: String, createdAt: Int64, requestID: String) {
        self.version = version
        self.sequence = sequence
        self.parentHash = parentHash
        self.writerDeviceID = writerDeviceID
        self.kind = kind
        self.manifestHash = manifestHash
        self.manifestKey = manifestKey
        self.createdAt = createdAt
        self.requestID = requestID
    }
}

public struct V1Manifest: Equatable {
    public var version: Int
    public var moments: [V1Moment]
    public var assets: [V1Asset]
    public var resources: [V1Resource]
    public var anniversaries: [V1Anniversary]

    public init(version: Int = 1, moments: [V1Moment] = [], assets: [V1Asset] = [],
                resources: [V1Resource] = [], anniversaries: [V1Anniversary] = []) {
        self.version = version
        self.moments = moments
        self.assets = assets
        self.resources = resources
        self.anniversaries = anniversaries
    }
}

public struct V1Moment: Equatable {
    public var id: String
    public var title: String
    public var note: String
    public var occurredAt: Int64
    public var createdAt: Int64
    public var updatedAt: Int64
    public var assetIDs: [String]
    public var trashedAt: Int64?
    public var revision: Int64
    public var deviceManufacturer: String?
    public var deviceModel: String?

    public init(id: String, title: String = "", note: String = "", occurredAt: Int64, createdAt: Int64,
                updatedAt: Int64, assetIDs: [String], trashedAt: Int64? = nil, revision: Int64 = 0,
                deviceManufacturer: String? = nil, deviceModel: String? = nil) {
        self.id = id
        self.title = title
        self.note = note
        self.occurredAt = occurredAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.assetIDs = assetIDs
        self.trashedAt = trashedAt
        self.revision = revision
        self.deviceManufacturer = deviceManufacturer
        self.deviceModel = deviceModel
    }
}

public struct V1Asset: Equatable {
    public var id: String
    public var kind: String
    public var capturedAt: Int64
    public var resourceIDs: [String]
    public var revision: Int64
    public var importProvenance: String?

    public init(id: String, kind: String, capturedAt: Int64, resourceIDs: [String], revision: Int64 = 0, importProvenance: String? = nil) {
        self.id = id
        self.kind = kind
        self.capturedAt = capturedAt
        self.resourceIDs = resourceIDs
        self.revision = revision
        self.importProvenance = importProvenance
    }
}

public struct V1Resource: Equatable {
    public var id: String
    public var assetID: String
    public var role: String
    public var contentType: String
    public var originalFilename: String
    public var byteCount: Int64
    public var sha256: String
    public var objectKey: String

    public init(id: String, assetID: String, role: String, contentType: String, originalFilename: String,
                byteCount: Int64, sha256: String, objectKey: String) {
        self.id = id
        self.assetID = assetID
        self.role = role
        self.contentType = contentType
        self.originalFilename = originalFilename
        self.byteCount = byteCount
        self.sha256 = sha256
        self.objectKey = objectKey
    }
}

public struct V1Anniversary: Equatable {
    public var id: String
    public var owner: ParentIdentity
    public var title: String
    public var date: String
    public var deletedAt: Int64?

    public init(id: String, owner: ParentIdentity, title: String, date: String, deletedAt: Int64? = nil) {
        self.id = id
        self.owner = owner
        self.title = title
        self.date = date
        self.deletedAt = deletedAt
    }
}

public enum ImportProvenance: String, Equatable {
    case camera
    case verifiedOriginal
    case systemProvided
    case fileSelected

    public var label: String {
        switch self {
        case .camera: return "App内拍摄"
        case .verifiedOriginal: return "已确认原件"
        case .systemProvided: return "系统提供版本"
        case .fileSelected: return "文件导入"
        }
    }

    public static func known(_ value: String?) -> ImportProvenance? {
        guard let value else { return nil }
        return ImportProvenance(rawValue: value)
    }
}
