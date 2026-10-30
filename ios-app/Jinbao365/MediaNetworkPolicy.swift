import Foundation
import Network

enum MediaAccessError: LocalizedError {
    case cellularPermissionRequired
    case offline
    var errorDescription: String? {
        switch self {
        case .cellularPermissionRequired: return "当前使用蜂窝或计量网络，下载原件前需要确认。"
        case .offline: return "当前网络不可用，已缓存的原件仍可查看。"
        }
    }
}

final class MediaNetworkPolicy: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var available = false
    private var expensive = true
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.available = path.status == .satisfied
            self.expensive = path.isExpensive || path.isConstrained || path.usesInterfaceType(.cellular)
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "jinbao.media-network"))
    }
    deinit { monitor.cancel() }
    func requireDownload(allowCellular: Bool) throws {
        lock.lock(); let ready = available; let metered = expensive; lock.unlock()
        guard ready else { throw MediaAccessError.offline }
        if metered && !allowCellular { throw MediaAccessError.cellularPermissionRequired }
    }
}

final class BackupStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func set(_ value: Bool) { lock.lock(); stopped = value; lock.unlock() }
}
