import XCTest
import UIKit
import AVFoundation
import ImageIO
import Photos
import PhotosUI
import UniformTypeIdentifiers
@testable import Jinbao365

/// Explicit, serial physical-device acceptance. Only this run's synthetic resources are uploaded.
@MainActor
final class CosMediaDeviceAcceptanceTests: XCTestCase {
    func testSyntheticMediaBackupRecoveryAndImmutableDownload() async throws {
        guard ProcessInfo.processInfo.environment["JINBAO_COS_MEDIA_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Explicit COS media acceptance is disabled.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device COS acceptance is required.")
        #else
        var stage = Stage.credentials
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cos-media-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            guard let credentials = try KeychainStore.load() else { throw MediaFailure.precondition }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            stage = .fixtures
            let fixture = SyntheticMediaFixture()
            var photos: [LocalAsset] = []
            for number in 1...3 {
                let url = folder.appendingPathComponent("synthetic-\(number).jpg")
                try fixture.photo(to: url, number: number)
                photos.append(try PhotoImport.store(file: url, filename: url.lastPathComponent,
                                                    provenance: .fileSelected, directory: folder))
            }
            let videoFile = folder.appendingPathComponent("synthetic-large.mov")
            try await fixture.movie(to: videoFile)
            try fixture.padValidMovie(to: videoFile, targetBytes: 34 * 1024 * 1024)
            let video = try PhotoImport.store(file: videoFile, filename: videoFile.lastPathComponent,
                                              provenance: .fileSelected, directory: folder)
            guard video.resources.contains(where: { $0.role == "video" && $0.byteCount >= 33 * 1024 * 1024 }) else {
                throw MediaFailure.fixture
            }
            let live = try await fixture.livePhoto(in: folder)
            let importedLive = try await PhotoImport.storeLivePhoto(live, directory: folder)
            guard importedLive.kind == "livePhoto",
                  Set(importedLive.resources.map(\.role)) == Set(["livePhotoImage", "livePhotoVideo", "preview"]) else {
                throw MediaFailure.fixture
            }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            var session = AppSession(deviceID: UUID().uuidString, testBuild: true, identity: .dad,
                                     link: .verified(bucket: "example-1234567890", region: "ap-shanghai"))
            let groups = [[photos[0]], [photos[1], photos[2]], [video], [importedLive]]
            session.moments = groups.enumerated().map { index, assets in
                LocalMoment(id: UUID().uuidString, title: "Synthetic COS acceptance \(index + 1)", note: "",
                            occurredAt: now, createdAt: now, updatedAt: now, parent: .dad, assets: assets,
                            uploadEligibility: .testOnly)
            }
            let prefix = try session.writerPrefix()
            guard prefix.hasPrefix("life/v1/test/"), !prefix.contains("/dad/"), !prefix.contains("/mom/") else {
                throw MediaFailure.precondition
            }
            let allowedObjectKeys = Set(session.moments.flatMap(\.assets).flatMap(\.resources).map { V1Layout.objectKey(prefix: prefix, sha256: $0.sha256) })
            let transport = AcceptanceTransport(prefix: prefix, allowedObjectKeys: allowedObjectKeys)
            let configuration = StorageConfiguration(bucket: "example-1234567890", prefix: prefix)
            let client = try CosClient(configuration: configuration, credentials: credentials, transport: transport)
            stage = .prepare
            var job = try BackupQueue.prepare(client: client, session: session, now: now)
            let store = ArchiveStore(url: folder.appendingPathComponent("isolated-archive.json"))
            func persist(_ next: BackupJob) throws {
                var snapshot = session
                snapshot.backupJob = next
                try store.save(PersistedArchive(session: snapshot))
            }
            try persist(job)
            stage = .pause
            var completedCount = 0
            try BackupQueue.advance(client: client, session: session, job: &job,
                                    resolve: { folder.appendingPathComponent($0) },
                                    persist: { next in completedCount = next.completedCount; try persist(next) },
                                    shouldPause: { completedCount >= 1 })
            guard job.status == .paused, job.completedCount == 1,
                  let paused = try store.load()?.backupJob, paused == job else { throw MediaFailure.persistence }
            job = paused
            let pausedPuts = transport.successfulPUTCount
            try BackupQueue.advance(client: client, session: session, job: &job,
                                    resolve: { folder.appendingPathComponent($0) }, persist: persist)
            guard job.status == .paused, transport.successfulPUTCount == pausedPuts else { throw MediaFailure.persistence }
            stage = .failureRetry
            job.resume()
            transport.failNextPUT = true
            var networkFailure = false
            do {
                try BackupQueue.advance(client: client, session: session, job: &job,
                                        resolve: { folder.appendingPathComponent($0) }, persist: persist)
            } catch let error as CosFailure { networkFailure = error.failure == .network }
            catch { throw MediaFailure.retry }
            guard networkFailure, job.status == .failed,
                  let failed = try store.load()?.backupJob, failed == job else { throw MediaFailure.retry }
            job = failed
            job.resume()
            let restartedClient = try CosClient(configuration: configuration, credentials: credentials, transport: transport)
            try BackupQueue.advance(client: restartedClient, session: session, job: &job,
                                    resolve: { folder.appendingPathComponent($0) }, persist: persist)
            guard job.status == .completed, job.completedCount == job.totalCount,
                  try store.load()?.backupJob == job else { throw MediaFailure.retry }
            stage = .download
            let manifest = try job.manifest
            let commit = try job.commit
            guard manifest.version == 2, manifest.moments.count == 4, manifest.assets.count == 5,
                  manifest.resources.allSatisfy({ allowedObjectKeys.contains($0.objectKey) && $0.objectKey.hasPrefix("life/v1/test/objects/") }),
                  try client.get(key: commit.manifestKey) == job.manifestBytes,
                  try client.get(key: job.commitKey) == job.commitBytes else { throw MediaFailure.manifest }
            var evidence: [[String: Any]] = []
            var downloaded: [String: URL] = [:]
            for resource in manifest.resources {
                let ext = resource.contentType.hasPrefix("video/") ? "mov" : resource.contentType == "image/jpeg" ? "jpg" : "bin"
                let destination = folder.appendingPathComponent("downloads/\(resource.id).\(ext)")
                guard let head = try client.head(key: resource.objectKey), head.byteCount == resource.byteCount,
                      head.sha256 == resource.sha256 else { throw MediaFailure.download }
                try client.getFile(key: resource.objectKey, destination: destination,
                                   byteCount: resource.byteCount, sha256: resource.sha256)
                let actual = try Digest.sha256File(destination)
                guard actual.byteCount == resource.byteCount, actual.hash == resource.sha256 else { throw MediaFailure.download }
                if ["preview", "photo", "livePhotoImage"].contains(resource.role) {
                    guard UIImage(contentsOfFile: destination.path) != nil else { throw MediaFailure.playback }
                }
                downloaded[resource.id] = destination
                evidence.append(["role": resource.role, "contentType": resource.contentType,
                                 "objectKey": resource.objectKey, "byteCount": resource.byteCount,
                                 "sha256": resource.sha256, "downloadSHA256": actual.hash, "headVerified": true])
            }
            stage = .playback
            var videoDuration: Double = 0
            var nativeVideoAdvance: Double = 0
            let nativePlayback = try NativeMediaPlaybackOverlay.make()
            defer { nativePlayback.close() }
            for asset in manifest.assets where asset.kind == "video" {
                guard let resource = manifest.resources.first(where: { $0.assetID == asset.id && $0.role == "video" }),
                      let url = downloaded[resource.id] else { throw MediaFailure.playback }
                videoDuration = CMTimeGetSeconds(try await AVURLAsset(url: url).load(.duration))
                guard videoDuration.isFinite, videoDuration > 0 else { throw MediaFailure.playback }
                nativeVideoAdvance = try await nativePlayback.verifyVideoTimeAdvances(url: url)
            }
            guard let liveAsset = manifest.assets.first(where: { $0.kind == "livePhoto" }),
                  let still = manifest.resources.first(where: { $0.assetID == liveAsset.id && $0.role == "livePhotoImage" }),
                  let motion = manifest.resources.first(where: { $0.assetID == liveAsset.id && $0.role == "livePhotoVideo" }),
                  let stillURL = downloaded[still.id], let movieURL = downloaded[motion.id] else { throw MediaFailure.playback }
            let downloadedLivePhoto = try await SyntheticMediaFixture.requestLivePhoto(photo: stillURL, movie: movieURL)
            try await nativePlayback.verifyFullLivePhotoPlayback(downloadedLivePhoto)
            nativePlayback.close()
            stage = .duplicate
            let beforeDuplicate = transport.successfulPUTCount
            try BackupQueue.advance(client: client, session: session, job: &job,
                                    resolve: { folder.appendingPathComponent($0) }, persist: persist)
            var duplicate = try BackupQueue.prepare(client: client, session: session, now: now + 1000)
            try BackupQueue.advance(client: client, session: session, job: &duplicate,
                                    resolve: { folder.appendingPathComponent($0) }, persist: { _ in })
            guard duplicate.status == .completed, duplicate.commitKey == job.commitKey,
                  transport.successfulPUTCount == beforeDuplicate,
                  try client.list(prefix: prefix + "commits/").count == 1 else { throw MediaFailure.duplicate }
            stage = .conflict
            let originalBytes = Data("synthetic-conflict".utf8)
            let conflictKey = prefix + "snapshots/" + Digest.sha256Hex(originalBytes) + ".json"
            try client.putImmutable(key: conflictKey, body: originalBytes, contentType: "application/json")
            // Hide HEAD once to force a real conditional PUT against the existing synthetic object.
            transport.hideNextHEADFor = "/" + conflictKey
            let conditionalBefore = transport.conditionalConflictCount
            try client.putImmutable(key: conflictKey, body: originalBytes, contentType: "application/json")
            guard transport.conditionalConflictCount == conditionalBefore + 1,
                  try client.get(key: conflictKey) == originalBytes else { throw MediaFailure.conflict }
            var conflictRejected = false
            do { try client.putImmutable(key: conflictKey, body: Data("different-synthetic-bytes".utf8), contentType: "application/json") }
            catch let error as CosFailure { conflictRejected = error.failure == .conflict }
            catch { throw MediaFailure.conflict }
            guard conflictRejected, try client.get(key: conflictKey) == originalBytes,
                  transport.allWritesConfined, transport.allPUTsConditional else { throw MediaFailure.conflict }
            stage = .evidence
            let report: [String: Any] = [
                "status": "passed", "deviceClass": "physical", "manifestVersion": manifest.version,
                "testPrefix": prefix, "momentCount": manifest.moments.count, "assetCount": manifest.assets.count,
                "resources": evidence, "videoDurationSeconds": videoDuration,
                "nativeVideoPlaybackAdvancedSeconds": nativeVideoAdvance,
                "nativeLivePhotoFullPlaybackStartCount": nativePlayback.fullPlaybackStartCount,
                "nativeLivePhotoFullPlaybackEndCount": nativePlayback.fullPlaybackEndCount,
                "nativePlaybackOverlaySyntheticOnly": true,
                "nativePlaybackScope": "Downloaded synthetic media in AVPlayerLayer and PHLivePhotoView widgets",
                "largeVideoFixture": "2-second valid MOV with a top-level free atom; large-file transport, not long-video playback",
                "livePhotoReconstruction": true, "pausePersistenceRoundtrip": true, "injectedNetworkFailureRetried": true,
                "newClientAfterDiskReload": true, "duplicateBackupAddedNoPUT": true,
                "conditionalConflictProtected": true, "writesConfinedToTestRoot": true, "sharedObjectsRestrictedToSyntheticHashes": true,
                "notExercised": ["physical network disconnection", "process termination during an in-flight upload",
                                 "real cellular consent UI", "independent expired or denied STS", "production App end-to-end media UI"]
            ]
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
            attachment.name = "synthetic-cos-media-evidence.json"
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            // Arbitrary SDK errors can expose signed URLs or parser context. Report fixed stages only.
            let category: String
            if let error = error as? CosFailure { category = String(describing: error.failure) }
            else if let error = error as? MediaFailure { category = String(describing: error) }
            else if error is ContractError { category = "contract-validation" }
            else { category = "redacted-operation" }
            XCTFail("COS media acceptance failed at stage: \(stage.rawValue), category: \(category).")
        }
        #endif
    }
    private enum Stage: String { case credentials, fixtures, prepare, pause, failureRetry, download, playback, duplicate, conflict, evidence }
}

private enum MediaFailure: Error { case precondition, fixture, persistence, retry, manifest, download, playback, duplicate, conflict, nativeWindow, nativeVideoPlayback, nativeLivePhotoPlayback }

/// Exercises native widgets using downloaded synthetic files. Does not inspect or modify the App's root UI.
@MainActor
private final class NativeMediaPlaybackOverlay: NSObject, PHLivePhotoViewDelegate {
    private let window: UIWindow
    private let hostView: UIView
    private var playerLayer: AVPlayerLayer?
    private var liveView: PHLivePhotoView?
    private(set) var fullPlaybackStartCount = 0
    private(set) var fullPlaybackEndCount = 0

    init(activeScene: UIWindowScene) {
        let controller = UIViewController()
        controller.loadViewIfNeeded()
        controller.view.backgroundColor = .black
        let overlay = UIWindow(windowScene: activeScene)
        overlay.frame = activeScene.coordinateSpace.bounds
        overlay.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        overlay.backgroundColor = .black
        overlay.rootViewController = controller
        self.window = overlay
        self.hostView = controller.view
        super.init()
        overlay.isHidden = false
        hostView.layoutIfNeeded()
    }

    static func make() throws -> NativeMediaPlaybackOverlay {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { throw MediaFailure.nativeWindow }
        return NativeMediaPlaybackOverlay(activeScene: scene)
    }

    func verifyVideoTimeAdvances(url: URL) async throws -> Double {
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        let layer = AVPlayerLayer(player: player)
        layer.frame = hostView.bounds
        layer.videoGravity = .resizeAspect
        hostView.layer.addSublayer(layer)
        playerLayer = layer
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
            layer.player = nil
            layer.removeFromSuperlayer()
            playerLayer = nil
        }
        let initialSeconds = CMTimeGetSeconds(player.currentTime())
        guard initialSeconds.isFinite else { throw MediaFailure.nativeVideoPlayback }
        player.playImmediately(atRate: 1)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            guard player.status != .failed, player.currentItem?.status != .failed else { throw MediaFailure.nativeVideoPlayback }
            let elapsed = CMTimeGetSeconds(player.currentTime()) - initialSeconds
            if elapsed.isFinite, elapsed >= 0.35, player.rate > 0, layer.isReadyForDisplay { return elapsed }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw MediaFailure.nativeVideoPlayback
    }

    func verifyFullLivePhotoPlayback(_ photo: PHLivePhoto) async throws {
        let view = PHLivePhotoView(frame: hostView.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.backgroundColor = .black
        view.contentMode = .scaleAspectFit
        view.isMuted = true
        view.livePhoto = photo
        view.delegate = self
        hostView.addSubview(view)
        liveView = view
        hostView.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 250_000_000)
        view.startPlayback(with: .full)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if fullPlaybackStartCount > 0, fullPlaybackEndCount > 0 { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw MediaFailure.nativeLivePhotoPlayback
    }

    func livePhotoView(_ livePhotoView: PHLivePhotoView, willBeginPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
        if playbackStyle == .full { fullPlaybackStartCount += 1 }
    }
    func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
        if playbackStyle == .full, fullPlaybackStartCount > 0 { fullPlaybackEndCount += 1 }
    }

    func close() {
        playerLayer?.player?.pause()
        playerLayer?.player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        liveView?.delegate = nil
        liveView?.stopPlayback()
        liveView?.livePhoto = nil
        liveView?.removeFromSuperview()
        liveView = nil
        window.isHidden = true
        window.rootViewController = nil
    }
}

/// Does not retain request headers, URLs, response bodies, tokens or authorization.
private final class AcceptanceTransport: ObjectTransport {
    private let base = URLSessionTransport()
    private let prefix: String
    private let allowedObjectPaths: Set<String>
    var failNextPUT = false
    var hideNextHEADFor: String?
    private(set) var successfulPUTCount = 0
    private(set) var conditionalConflictCount = 0
    private(set) var allWritesConfined = true
    private(set) var allPUTsConditional = true
    init(prefix: String, allowedObjectKeys: Set<String>) {
        self.prefix = prefix
        allowedObjectPaths = Set(allowedObjectKeys.map { "/" + $0 })
    }
    func execute(_ request: ObjectRequest) throws -> ObjectResponse {
        guard request.method != "POST" else { allWritesConfined = false; throw MediaFailure.precondition }
        if request.method == "PUT" {
            guard (request.path.hasPrefix("/" + prefix) || allowedObjectPaths.contains(request.path)),
                  request.path.hasPrefix("/life/v1/test/"), prefix.hasPrefix("life/v1/test/") else {
                allWritesConfined = false; throw MediaFailure.precondition
            }
            guard request.headers.first(where: { $0.key.lowercased() == "x-cos-forbid-overwrite" })?.value == "true" else {
                allPUTsConditional = false; throw MediaFailure.precondition
            }
            if failNextPUT { failNextPUT = false; throw CosFailure(.network) }
        }
        if request.method == "HEAD", request.path == hideNextHEADFor {
            hideNextHEADFor = nil
            return ObjectResponse(status: 404)
        }
        let response = try base.execute(request)
        if request.method == "PUT" {
            if (200...299).contains(response.status) { successfulPUTCount += 1 }
            if response.status == 409 || response.status == 412 { conditionalConflictCount += 1 }
        }
        return response
    }
}

@MainActor
private final class SyntheticMediaFixture {
    let runID = UUID().uuidString
    func photo(to url: URL, number: Int) throws {
        try writeJPEG(image: fixtureImage(number: number), to: url, date: "2026:10:20 10:30:00")
    }
    func movie(to url: URL) async throws {
        try await writeMovie(to: url, number: 3, captureDate: "2026-10-20T10:30:00+08:00", pairID: nil)
    }
    func livePhoto(in folder: URL) async throws -> PHLivePhoto {
        let photo = folder.appendingPathComponent("synthetic-live.jpg")
        let movie = folder.appendingPathComponent("synthetic-live.mov")
        let pair = UUID().uuidString
        try writeJPEG(image: fixtureImage(number: 4, phase: 0.5), to: photo, date: "2026:10:20 10:30:00", pairID: pair)
        try await writeMovie(to: movie, number: 4, captureDate: "2026-10-20T10:30:00+08:00", pairID: pair)
        return try await Self.requestLivePhoto(photo: photo, movie: movie)
    }
    func padValidMovie(to file: URL, targetBytes: Int64) throws {
        let padding = targetBytes - (try Digest.sha256File(file).byteCount)
        guard padding >= 8, padding <= Int64(UInt32.max) else { throw MediaFailure.fixture }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var atomSize = UInt32(padding).bigEndian
        try withUnsafeBytes(of: &atomSize) { try handle.write(contentsOf: Data($0)) }
        try handle.write(contentsOf: Data("free".utf8))
        let zeroes = Data(count: 1024 * 1024)
        var remaining = padding - 8
        while remaining > 0 {
            let count = Int(min(Int64(zeroes.count), remaining))
            try handle.write(contentsOf: zeroes.prefix(count))
            remaining -= Int64(count)
        }
    }
    static func requestLivePhoto(photo: URL, movie: URL) async throws -> PHLivePhoto {
        try await withCheckedThrowingContinuation { continuation in
            let result = LivePhotoResult(continuation)
            PHLivePhoto.request(withResourceFileURLs: [photo, movie], placeholderImage: nil,
                                targetSize: CGSize(width: 960, height: 720), contentMode: .aspectFit) { live, info in
                if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true { return }
                if let live, live.size.width > 0 { result.finish(.success(live)) }
                else { result.finish(.failure(MediaFailure.fixture)) }
            }
        }
    }
    private func fixtureImage(number: Int, phase: CGFloat = 0) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 960, height: 720), format: format).image { context in
            let colors: [UIColor] = [.systemBlue, .systemOrange, .systemPurple, .systemTeal]
            colors[min(3, max(0, number - 1))].setFill()
            context.fill(CGRect(x: 0, y: 0, width: 960, height: 720))
            UIColor.white.withAlphaComponent(0.35).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 90 + phase * 650, y: 70, width: 100, height: 100))
            let center = NSMutableParagraphStyle()
            center.alignment = .center
            let title = "JINBAO QA \(number)" as NSString
            title.draw(in: CGRect(x: 90, y: 250, width: 780, height: 105), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 82), .foregroundColor: UIColor.white, .paragraphStyle: center])
            ("RUN \(runID)" as NSString).draw(in: CGRect(x: 100, y: 365, width: 760, height: 95), withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 30, weight: .bold), .foregroundColor: UIColor.white, .paragraphStyle: center])
            let label = number == 3 ? "SYNTHETIC VIDEO" : number == 4 ? "SYNTHETIC LIVE PHOTO" : "2026-10-19 · SYNTHETIC"
            (label as NSString).draw(in: CGRect(x: 90, y: 490, width: 780, height: 65), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 32), .foregroundColor: UIColor.white, .paragraphStyle: center])
        }
    }

    private func writeJPEG(image: UIImage, to url: URL, date: String, pairID: String? = nil) throws {
        guard let cg = image.cgImage else { throw FixtureFailure("Synthetic image is missing pixels.") }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { throw FixtureFailure("Could not create synthetic JPEG.") }
        var properties: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: 0.96,
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: date, kCGImagePropertyExifDateTimeDigitized as String: date, "OffsetTimeOriginal": "+08:00", "OffsetTimeDigitized": "+08:00"],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFDateTime as String: date, kCGImagePropertyTIFFMake as String: "JINBAO SYNTHETIC FIXTURE"]]
        if let pairID { properties[kCGImagePropertyMakerAppleDictionary as String] = ["17": pairID] }
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FixtureFailure("Could not finalize synthetic JPEG.") }
        try (bytes as Data).write(to: url, options: .atomic)
    }

    private func writeMovie(to url: URL, number: Int, captureDate: String, pairID: String?) async throws {
        // Only the helper's run-specific generated file can be replaced; no library assets are read or removed.
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 960, AVVideoHeightKey: 720])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw FixtureFailure("Video encoder is unavailable.") }
        writer.add(input)
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 960, kCVPixelBufferHeightKey as String: 720, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        let creation = AVMutableMetadataItem()
        creation.identifier = .quickTimeMetadataCreationDate
        creation.value = captureDate as NSString
        creation.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [creation]
        var metadataInput: AVAssetWriterInput?
        var metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
        if let pairID {
            let identifier = AVMutableMetadataItem()
            identifier.identifier = .quickTimeMetadataContentIdentifier
            identifier.value = pairID as NSString
            identifier.dataType = kCMMetadataBaseDataType_UTF8 as String
            writer.metadata.append(identifier)
            let specification: [String: Any] = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time", kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.int8"]
            var description: CMFormatDescription?
            let result = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &description)
            guard result == noErr, let description else { throw FixtureFailure("Could not create Live Photo metadata format.") }
            let track = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
            guard writer.canAdd(track) else { throw FixtureFailure("Live Photo metadata track is unavailable.") }
            writer.add(track)
            metadataInput = track
            metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: track)
        }
        guard writer.startWriting() else { throw writer.error ?? FixtureFailure("Could not start the synthetic movie.") }
        writer.startSession(atSourceTime: .zero)
        if let metadataAdaptor {
            let still = AVMutableMetadataItem()
            still.keySpace = .quickTimeMetadata
            still.key = "com.apple.quicktime.still-image-time" as NSString
            still.value = NSNumber(value: Int8(0))
            still.dataType = "com.apple.metadata.datatype.int8"
            guard metadataAdaptor.append(AVTimedMetadataGroup(items: [still], timeRange: CMTimeRange(start: CMTime(value: 30, timescale: 30), duration: CMTime(value: 1, timescale: 30)))) else {
                throw writer.error ?? FixtureFailure("Could not append Live Photo still-image marker.")
            }
            metadataInput?.markAsFinished()
        }
        for frame in 0..<60 {
            var waits = 0
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, waits < 1000 else { throw writer.error ?? FixtureFailure("Synthetic video encoder timed out.") }
                waits += 1
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let image = fixtureImage(number: number, phase: CGFloat(frame) / 59)
            guard let cg = image.cgImage else { throw FixtureFailure("Synthetic video frame failed.") }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 960, 720, kCVPixelFormatType_32ARGB, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { throw FixtureFailure("Synthetic video pixel buffer failed.") }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 960, height: 720, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw FixtureFailure("Synthetic video bitmap context failed.")
            }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 960, height: 720))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard pixels.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? FixtureFailure("Synthetic video frame append failed.") }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FixtureFailure("Synthetic movie did not finish.") }
    }


}

private final class LivePhotoResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PHLivePhoto, Error>?
    init(_ continuation: CheckedContinuation<PHLivePhoto, Error>) { self.continuation = continuation }
    func finish(_ result: Result<PHLivePhoto, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

private struct FixtureFailure: Error {
    init(_ ignored: String) {}
}
