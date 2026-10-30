import Foundation

public enum BackupJobStatus: String, Codable, Equatable {
    case queued, uploading, paused, failed, completed
}

/// Frozen publication payload. Credentials and transient transport handles never enter the archive.
public struct BackupJob: Codable, Equatable, Identifiable {
    public let id: String
    public let bucket: String
    public let region: String
    public let prefix: String
    public let writerDeviceID: String
    public let testBuild: Bool
    public let manifestBytes: Data
    public let commitBytes: Data
    public let commitKey: String
    public let uploads: [BackupUpload]
    public private(set) var status: BackupJobStatus
    public private(set) var completedObjectKeys: Set<String>
    public private(set) var snapshotUploaded: Bool
    public private(set) var lastError: String?
    public var completedCount: Int { completedObjectKeys.count }
    public var totalCount: Int { uploads.count }
    public var progress: Double { Double(completedCount + (snapshotUploaded ? 1 : 0) + (status == .completed ? 1 : 0)) / Double(totalCount + 2) }
    public var manifest: V1Manifest { get throws { try V1Json.decodeManifest(manifestBytes) } }
    public var commit: V1Commit { get throws { try V1Json.decodeCommit(commitBytes) } }

    public mutating func pause() { if status != .completed { status = .paused } }
    public mutating func resume() { if status != .completed { status = .queued; lastError = nil } }

    fileprivate init(id: String, bucket: String, region: String, prefix: String, writerDeviceID: String,
                     testBuild: Bool, manifestBytes: Data, commitBytes: Data, commitKey: String,
                     uploads: [BackupUpload], completed: Bool = false) {
        self.id = id; self.bucket = bucket; self.region = region; self.prefix = prefix
        self.writerDeviceID = writerDeviceID; self.testBuild = testBuild
        self.manifestBytes = manifestBytes; self.commitBytes = commitBytes; self.commitKey = commitKey
        self.uploads = uploads; status = completed ? .completed : .queued
        completedObjectKeys = completed ? Set(uploads.map(\.objectKey)) : []
        snapshotUploaded = completed; lastError = nil
    }

    fileprivate mutating func start() { status = .uploading; lastError = nil }
    fileprivate mutating func didUpload(_ key: String) { completedObjectKeys.insert(key) }
    fileprivate mutating func didUploadSnapshot() { snapshotUploaded = true }
    fileprivate mutating func complete() { status = .completed; lastError = nil }
    fileprivate mutating func fail(_ message: String) { status = .failed; lastError = message }
}

public enum BackupQueue {
    /// Persist this result before calling advance. A retry must reuse its exact bytes and request ID.
    public static func prepare(client: CosClient, session: AppSession, now: Int64,
                               requestID: String = UUID().uuidString) throws -> BackupJob {
        let plan = try BackupPlan.manifest(session: session, now: now)
        guard client.configuration.prefix == plan.prefix,
              client.configuration.bucket == session.link.bucket, client.configuration.region == session.link.region else {
            throw CosFailure(.configuration)
        }
        let manifestHash = Digest.sha256Hex(plan.bytes)
        let previous = try FamilyReader.latest(client: client, prefix: plan.prefix)
        let duplicate = previous?.commit.manifestHash == manifestHash
        let commit = duplicate ? previous!.commit : V1Commit(sequence: (previous?.commit.sequence ?? 0) + 1,
            parentHash: previous?.commitHash, writerDeviceID: try V1Ids.canonical(session.deviceID, path: "writerDeviceID"),
            manifestHash: manifestHash, manifestKey: plan.prefix + "snapshots/\(manifestHash).json",
            createdAt: now, requestID: try V1Ids.canonical(requestID, path: "requestID"))
        let commitKey = plan.prefix + V1Json.commitRelativeKey(commit.sequence)
        if !duplicate {
            try V1Validator.validateCommit(commit: commit, key: commitKey, prefix: plan.prefix,
                                           previous: previous?.commit, previousHash: previous?.commitHash)
        }
        var unique: [String: BackupUpload] = [:]
        for upload in try BackupPlan.uploads(session: session) {
            if let existing = unique[upload.objectKey], existing.sha256 != upload.sha256 || existing.byteCount != upload.byteCount {
                throw CosFailure(.contentMismatch)
            }
            if unique[upload.objectKey] == nil { unique[upload.objectKey] = upload }
        }
        return BackupJob(id: commit.requestID, bucket: client.configuration.bucket, region: client.configuration.region,
                         prefix: plan.prefix, writerDeviceID: commit.writerDeviceID, testBuild: session.testBuild,
                         manifestBytes: plan.bytes, commitBytes: V1Json.encodeCommit(commit), commitKey: commitKey,
                         uploads: unique.keys.sorted().compactMap { unique[$0] }, completed: duplicate)
    }

    /// Synchronous worker API; persist may marshal to the app's serial repository/main actor.
    /// shouldPause is consulted before every object and before snapshot/commit publication.
    public static func advance(client: CosClient, session: AppSession, job: inout BackupJob,
                               resolve: (String) throws -> URL,
                               persist: (BackupJob) throws -> Void,
                               shouldPause: () -> Bool = { false }) throws {
        try validate(job: job, session: session, client: client)
        if job.status == .completed || job.status == .paused { return }
        do {
            job.start()
            try persist(job)
            for upload in job.uploads {
                if shouldPause() { job.pause(); try persist(job); return }
                if job.completedObjectKeys.contains(upload.objectKey),
                   let head = try client.head(key: upload.objectKey),
                   head.byteCount == upload.byteCount, head.sha256 == upload.sha256 { continue }
                try client.putImmutableFile(key: upload.objectKey, fileURL: resolve(upload.relativePath),
                                            byteCount: upload.byteCount, sha256: upload.sha256,
                                            contentType: upload.contentType)
                guard let head = try client.head(key: upload.objectKey),
                      head.byteCount == upload.byteCount, head.sha256 == upload.sha256 else { throw CosFailure(.contentMismatch) }
                job.didUpload(upload.objectKey)
                try persist(job)
            }
            if shouldPause() { job.pause(); try persist(job); return }
            let commit = try job.commit
            try client.putImmutable(key: commit.manifestKey, body: job.manifestBytes, contentType: "application/json")
            guard try client.get(key: commit.manifestKey) == job.manifestBytes else { throw CosFailure(.contentMismatch) }
            job.didUploadSnapshot()
            try persist(job)
            if shouldPause() { job.pause(); try persist(job); return }
            // Immutable PUT checks existing identical bytes, including after a lost response/restart.
            try client.putImmutable(key: job.commitKey, body: job.commitBytes, contentType: "application/json")
            guard try client.get(key: job.commitKey) == job.commitBytes else { throw CosFailure(.contentMismatch) }
            job.complete()
            try persist(job)
        } catch {
            let message: String
            if let failure = error as? CosFailure { message = failure.failure.message }
            else if let failure = error as? ContractError { message = failure.message }
            else { message = "备份未完成，原件仍保存在本机，可稍后重试。" }
            job.fail(message)
            try? persist(job)
            throw error
        }
    }

    public static func validate(job: BackupJob, session: AppSession, client: CosClient) throws {
        guard case .verified(let bucket, let region) = session.link,
              bucket == job.bucket, region == job.region,
              session.testBuild == job.testBuild,
              session.deviceID.uppercased() == job.writerDeviceID.uppercased(),
              try session.writerPrefix() == job.prefix,
              client.configuration.prefix == job.prefix,
              client.configuration.bucket == job.bucket, client.configuration.region == job.region,
              !V1Layout.isLegacyRoot(job.prefix) else { throw CosFailure(.configuration) }
        let manifest = try job.manifest
        let commit = try job.commit
        try V1Validator.validate(manifest: manifest, prefix: job.prefix)
        guard commit.requestID == job.id, commit.writerDeviceID == job.writerDeviceID,
              commit.manifestHash == Digest.sha256Hex(job.manifestBytes),
              commit.manifestKey == job.prefix + "snapshots/\(commit.manifestHash).json",
              job.commitKey == job.prefix + V1Json.commitRelativeKey(commit.sequence),
              commit.sequence > 0, commit.kind == "snapshot" else { throw CosFailure(.contentMismatch) }
        let eligible: UploadEligibility = session.testBuild ? .testOnly : .eligible
        let allowedIDs = Set(try session.moments.filter { $0.uploadEligibility == eligible && $0.parent == session.identity }.map { try V1Ids.map(kind: "record", localID: $0.id) })
        let anniversaryIDs = Set(try session.backupAnniversaries().map(\.id))
        guard manifest.moments.allSatisfy({ allowedIDs.contains($0.id) }),
              manifest.anniversaries.allSatisfy({ anniversaryIDs.contains($0.id) }) else { throw CosFailure(.configuration) }
        let resources = Dictionary(grouping: manifest.resources, by: \.objectKey)
        guard Set(job.uploads.map(\.objectKey)) == Set(resources.keys), Set(job.uploads.map(\.objectKey)).count == job.uploads.count,
              job.completedObjectKeys.isSubset(of: Set(resources.keys)) else { throw CosFailure(.contentMismatch) }
        for upload in job.uploads {
            guard let resource = resources[upload.objectKey]?.first,
                  upload.byteCount == resource.byteCount, upload.sha256 == resource.sha256,
                  upload.contentType == resource.contentType,
                  !upload.relativePath.hasPrefix("/"), !upload.relativePath.contains("\\"),
                  !upload.relativePath.split(separator: "/").contains("..") else { throw CosFailure(.contentMismatch) }
        }
    }
}
