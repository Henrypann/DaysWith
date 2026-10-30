import XCTest
import Foundation
import ImageIO
@testable import Jinbao365

/// Run stage and resume as separate invocations. The operator terminates the stage host externally.
final class CosProcessRecoveryDeviceTests: XCTestCase {
    func test01StageInterruptedUpload() async throws {
        try await Task.detached { try self.stageInterruptedUpload() }.value
    }

    private func stageInterruptedUpload() throws {
        try requireOptInDevice()
        let folder = try recoveryFolder()
        let store = ArchiveStore(url: folder.appendingPathComponent("isolated-archive.json"))
        let credentials = try XCTUnwrap(KeychainStore.load())
        var session: AppSession
        if let previous = try store.load() {
            session = previous.session()
            guard session.backupJob?.status == .queued,
                  !FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready.json").path) else {
                throw XCTSkip("Existing recovery evidence was preserved; run resume rather than restaging.")
            }
        } else {
            guard try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty else {
                throw XCTSkip("Existing partial recovery fixture was preserved; inspect it before starting another run.")
            }
            session = try makeSession(in: folder)
        }
        let prefix = try session.writerPrefix()
        let transport = RecoveryStageTransport(folder: folder, prefix: prefix)
        let client = try CosClient(configuration: StorageConfiguration(bucket: "example-1234567890", region: "ap-shanghai", prefix: prefix),
                                   credentials: credentials, transport: transport)
        var job = try session.backupJob ?? BackupQueue.prepare(client: client, session: session, now: Self.now)
        session.backupJob = job
        try store.save(PersistedArchive(session: session))
        try BackupQueue.advance(client: client, session: session, job: &job,
                                resolve: { try Self.resolve($0, in: folder) }, persist: { next in
            var checkpoint = session
            checkpoint.backupJob = next
            try store.save(PersistedArchive(session: checkpoint))
        })
        XCTFail("Stage completed without external process termination; this is not interruption evidence.")
    }

    func test02ResumeInterruptedUpload() async throws {
        try await Task.detached { try self.resumeInterruptedUpload() }.value
    }

    private func resumeInterruptedUpload() throws {
        try requireOptInDevice()
        let folder = try recoveryFolder()
        let store = ArchiveStore(url: folder.appendingPathComponent("isolated-archive.json"))
        guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("stage-timeout.json").path) else {
            throw RecoveryFailure.invalidEvidence
        }
        var session = try XCTUnwrap(store.load()).session()
        var job = try XCTUnwrap(session.backupJob)
        guard job.status == .uploading else { throw RecoveryFailure.invalidEvidence }
        let readyURL = folder.appendingPathComponent("ready.json")
        let ready = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: readyURL)) as? [String: Any])
        let sent = (ready["bytesSent"] as? NSNumber)?.int64Value ?? 0
        let expected = (ready["expected"] as? NSNumber)?.int64Value ?? 0
        let previousPID = (ready["processID"] as? NSNumber)?.int32Value ?? 0
        guard sent > 0, sent < expected, expected >= 33 * 1024 * 1024,
              ready["taskSuspended"] as? Bool == true,
              previousPID > 0, previousPID != ProcessInfo.processInfo.processIdentifier else {
            throw RecoveryFailure.invalidEvidence
        }
        let responseReturned = FileManager.default.fileExists(atPath: folder.appendingPathComponent("put-returned.json").path)
        let credentials = try XCTUnwrap(KeychainStore.load())
        let prefix = try session.writerPrefix()
        guard prefix.hasPrefix("life/v1/test/"), job.prefix == prefix, session.testBuild else { throw RecoveryFailure.invalidEvidence }
        let client = try CosClient(configuration: StorageConfiguration(bucket: job.bucket, region: job.region, prefix: prefix),
                                   credentials: credentials, transport: RecoveryScopeTransport(prefix: prefix))
        let frozenManifest = job.manifestBytes, frozenCommit = job.commitBytes, frozenCommitKey = job.commitKey
        job.resume()
        try BackupQueue.advance(client: client, session: session, job: &job,
                                resolve: { try Self.resolve($0, in: folder) }, persist: { next in
            var checkpoint = session
            checkpoint.backupJob = next
            try store.save(PersistedArchive(session: checkpoint))
        })
        guard job.status == .completed, job.completedCount == job.totalCount,
              job.manifestBytes == frozenManifest, job.commitBytes == frozenCommit, job.commitKey == frozenCommitKey,
              try store.load()?.backupJob == job,
              try client.get(key: job.commitKey) == frozenCommit,
              try client.get(key: job.commit.manifestKey) == frozenManifest else { throw RecoveryFailure.verification }
        var downloads: [[String: Any]] = []
        for upload in job.uploads {
            let destination = folder.appendingPathComponent("download-" + upload.sha256)
            try client.getFile(key: upload.objectKey, destination: destination, byteCount: upload.byteCount, sha256: upload.sha256)
            let actual = try Digest.sha256File(destination)
            guard actual.hash == upload.sha256, actual.byteCount == upload.byteCount else { throw RecoveryFailure.verification }
            downloads.append(["key": upload.objectKey, "sha256": actual.hash, "byteCount": actual.byteCount])
        }
        // A second production prepare must recognize the frozen publication as already complete.
        session.backupJob = job
        let duplicate = try BackupQueue.prepare(client: client, session: session, now: Self.now)
        guard duplicate.status == .completed, duplicate.commitKey == job.commitKey else { throw RecoveryFailure.verification }
        let result: [String: Any] = ["interruptedUploadingCheckpointRecovered": true, "differentHostProcess": true, "completed": true,
            "frozenPublicationReused": true, "allDownloadedHashesMatch": true, "duplicatePrepareCompleted": true,
            "putResponseReturnedBeforeTermination": responseReturned,
            "networkProgressObservedBeforeTermination": true,
            "networkUploadSuspendedBeforeTermination": true,
            "terminationDuringNetworkRequestSupported": !responseReturned,
            "writesLimitedToTest": true, "testMainArchiveAccessed": false, "keychainWritten": false,
            "photosLibraryAccessed": false, "downloads": downloads]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "COS process recovery result"
        attachment.lifetime = .keepAlways
        add(attachment)
        try FileManager.default.removeItem(at: folder)
    }

    private func requireOptInDevice() throws {
        guard ProcessInfo.processInfo.environment["JINBAO_COS_PROCESS_RECOVERY"] == "1" else {
            throw XCTSkip("Explicit JINBAO_COS_PROCESS_RECOVERY=1 is required.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device process recovery only.")
        #endif
    }
    private func recoveryFolder() throws -> URL {
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let run = ProcessInfo.processInfo.environment["JINBAO_COS_PROCESS_RUN_ID"] ?? "20261020"
        guard run.range(of: #"^[A-Z0-9-]{8,40}$"#, options: .regularExpression) != nil else { throw RecoveryFailure.invalidEvidence }
        let folder = cache.appendingPathComponent("JinbaoCOSProcessRecovery-" + run, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        return folder
    }
    private func makeSession(in folder: URL) throws -> AppSession {
        let width = 4096, height = 3072, pixels = width * height * 3
        let file = folder.appendingPathComponent("synthetic-recovery.bmp")
        var header = Data([0x42, 0x4D])
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { header.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { header.append(contentsOf: $0) } }
        u32(UInt32(pixels + 54)); u32(0); u32(54); u32(40); u32(UInt32(width)); u32(UInt32(height))
        u16(1); u16(24); u32(0); u32(UInt32(pixels)); u32(2835); u32(2835); u32(0); u32(0)
        guard FileManager.default.createFile(atPath: file.path, contents: header) else { throw RecoveryFailure.fixture }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let seed = Array(UUID().uuidString.utf8)
        let chunk = Data((0..<(1024 * 1024)).map { seed[$0 % seed.count] })
        for _ in 0..<36 { try handle.write(contentsOf: chunk) }
        try handle.close()
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0,
                  [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 128] as CFDictionary) else {
            throw RecoveryFailure.fixture
        }
        let preview = folder.appendingPathComponent("synthetic-recovery-preview.png")
        guard let destination = CGImageDestinationCreateWithURL(preview as CFURL, "public.png" as CFString, 1, nil) else { throw RecoveryFailure.fixture }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { throw RecoveryFailure.fixture }
        func resource(_ url: URL, role: String, type: String) throws -> LocalResource {
            let digest = try Digest.sha256File(url)
            return LocalResource(id: UUID().uuidString, role: role, contentType: type, originalFilename: url.lastPathComponent,
                                 byteCount: digest.byteCount, sha256: digest.hash, relativePath: url.lastPathComponent)
        }
        let asset = LocalAsset(id: UUID().uuidString, kind: "photo", capturedAt: Self.now, provenance: "syntheticAcceptance",
                               resources: [try resource(file, role: "photo", type: "image/bmp"),
                                           try resource(preview, role: "preview", type: "image/png")])
        let moment = LocalMoment(id: UUID().uuidString, title: "Synthetic process recovery", note: "", occurredAt: Self.now,
                                 createdAt: Self.now, updatedAt: Self.now, parent: .dad, assets: [asset], uploadEligibility: .testOnly)
        return AppSession(deviceID: UUID().uuidString, testBuild: true, identity: .dad,
                          link: .verified(bucket: "example-1234567890", region: "ap-shanghai"), moments: [moment])
    }
    private static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private static func resolve(_ relative: String, in folder: URL) throws -> URL {
        guard !relative.contains("/"), !relative.contains(".."), !relative.contains("\\") else { throw RecoveryFailure.invalidEvidence }
        return folder.appendingPathComponent(relative)
    }
}

private class RecoveryScopeTransport: ObjectTransport {
    let prefix: String
    let live = URLSessionTransport()
    init(prefix: String) { self.prefix = prefix }
    func execute(_ request: ObjectRequest) throws -> ObjectResponse {
        guard prefix.hasPrefix("life/v1/test/") else { throw RecoveryFailure.invalidEvidence }
        if request.method == "PUT" {
            guard request.path.hasPrefix("/" + prefix) || request.path.hasPrefix("/life/v1/test/objects/") else {
                throw RecoveryFailure.invalidEvidence
            }
        }
        return try live.execute(request)
    }
}

private final class RecoveryStageTransport: RecoveryScopeTransport {
    let folder: URL
    private var observedLargePut = false
    init(folder: URL, prefix: String) { self.folder = folder; super.init(prefix: prefix) }
    override func execute(_ request: ObjectRequest) throws -> ObjectResponse {
        guard request.method == "PUT", request.bodyFileURL != nil,
              let count = request.headers.first(where: { $0.key.lowercased() == "content-length" }).flatMap({ Int64($0.value) }),
              count >= 33 * 1024 * 1024, !observedLargePut else { return try super.execute(request) }
        guard request.path.hasPrefix("/life/v1/test/objects/") else { throw RecoveryFailure.invalidEvidence }
        observedLargePut = true
        let progress = RecoveryUploadProgress(folder: folder)
        let host = try XCTUnwrap(request.headers.first(where: { $0.key.lowercased() == "host" })?.value)
        guard let url = URL(string: "https://" + host + COSEncoding.encode(request.path, preserveSlash: true)) else { throw RecoveryFailure.invalidEvidence }
        var native = URLRequest(url: url)
        native.httpMethod = "PUT"
        for (name, value) in request.headers where name.lowercased() != "host" { native.setValue(value, forHTTPHeaderField: name) }
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForResource = 240
        settings.urlCache = nil; settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil
        let session = URLSession(configuration: settings, delegate: progress, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.uploadTask(with: native, fromFile: try XCTUnwrap(request.bodyFileURL))
        task.resume()
        guard progress.completed.wait(timeout: .now() + 245) == .success else { throw CosFailure(.timeout) }
        if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("stage-timeout.json").path) {
            try progress.write(["responseReturned": true, "status": progress.status], name: "put-returned.json")
        }
        throw RecoveryFailure.stageNotTerminated
    }
}

private final class RecoveryUploadProgress: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let folder: URL
    let completed = DispatchSemaphore(value: 0)
    var status = 0
    private var announced = false
    init(folder: URL) { self.folder = folder }
    func write(_ value: [String: Any], name: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard !announced, totalBytesSent > 0, totalBytesSent < totalBytesExpectedToSend else { return }
        announced = true
        // Suspend this real request after observing a partially sent body, providing a bounded kill window.
        // Suspension is a test transport action; it is not represented as loss of network connectivity.
        task.suspend()
        try? write(["bytesSent": totalBytesSent, "expected": totalBytesExpectedToSend,
                    "taskSuspended": true, "processID": ProcessInfo.processInfo.processIdentifier], name: "ready.json")
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) { [self] in
            try? write(["externalTerminationObserved": false], name: "stage-timeout.json")
            task.cancel()
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.cancel)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { completed.signal() }
}

private enum RecoveryFailure: Error { case fixture, invalidEvidence, verification, stageNotTerminated }
