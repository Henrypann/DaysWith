import Foundation

/// Serial, atomic local snapshots. A corrupt primary is never replaced by a new empty archive.
public final class ArchiveStore {
    public let url: URL
    public var recoveryURL: URL { url.appendingPathExtension("recovery") }
    private let lock = NSRecursiveLock()

    public init(url: URL) { self.url = url }

    public func load() throws -> PersistedArchive? {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if FileManager.default.fileExists(atPath: recoveryURL.path) {
                throw ContractError(path: "archive.recovery", message: "主档案暂时缺失，已找到恢复副本，请先恢复。")
            }
            return nil
        }
        return try decode(Data(contentsOf: url))
    }

    public func save(_ archive: PersistedArchive) throws {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(archive)
        _ = try decode(bytes)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url)
            let old = try decode(existing) // Fail closed before touching the last known-good copy.
            guard old.deviceID == archive.deviceID, old.identityFolder == nil || old.identityFolder == archive.identityFolder else {
                throw ContractError(path: "archive.identity", message: "档案设备或身份发生变化，已保留原数据。")
            }
            try existing.write(to: recoveryURL, options: .atomic)
        } else {
            guard !FileManager.default.fileExists(atPath: recoveryURL.path) else {
                throw ContractError(path: "archive.recovery", message: "已找到现有恢复副本，不能创建空档案覆盖。")
            }
            try bytes.write(to: recoveryURL, options: .atomic)
        }
        try bytes.write(to: url, options: .atomic)
    }

    public func loadRecovery() throws -> PersistedArchive {
        lock.lock(); defer { lock.unlock() }
        return try decode(Data(contentsOf: recoveryURL))
    }

    /// Explicit recovery preserves the unreadable primary for later inspection.
    @discardableResult
    public func restoreRecovery() throws -> PersistedArchive {
        lock.lock(); defer { lock.unlock() }
        let bytes = try Data(contentsOf: recoveryURL)
        let archive = try decode(bytes)
        if FileManager.default.fileExists(atPath: url.path) {
            let quarantined = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".unreadable-" + UUID().uuidString)
            try Data(contentsOf: url).write(to: quarantined, options: .atomic)
        }
        try bytes.write(to: url, options: .atomic)
        return archive
    }

    private func decode(_ data: Data) throws -> PersistedArchive {
        let archive = try JSONDecoder().decode(PersistedArchive.self, from: data)
        _ = try V1Ids.canonical(archive.deviceID, path: "archive.deviceID")
        guard Set(archive.moments.map { $0.id.uppercased() }).count == archive.moments.count else {
            throw ContractError(path: "archive.moments", message: "档案包含重复记录编号，原数据已保留。")
        }
        let assets = archive.moments.flatMap(\.assets) + (archive.draft?.assets ?? [])
        for resource in assets.flatMap(\.resources) {
            let path = resource.relativePath
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
                  !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
                throw ContractError(path: "archive.media", message: "档案媒体路径无效，原数据已保留。")
            }
        }
        return archive
    }
}
