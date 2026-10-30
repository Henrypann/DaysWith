import AVFoundation
import CryptoKit
import ImageIO
import Photos
import UniformTypeIdentifiers
import SwiftUI
import UIKit

@MainActor
final class PhotoFixture: ObservableObject {
    let runID: String
    let fullMedia: Bool
    @Published private(set) var status = "Ready. Add-only photo access is required."
    @Published private(set) var addedCount = 0
    @Published private(set) var busy = false
    @Published private(set) var statusFileError: String?
    private let automaticAddRequested: Bool
    private var automaticAddStarted = false
    private var authorization: PHAuthorizationStatus

    private struct StatusSnapshot: Codable {
        let runID: String
        let addedCount: Int
        let status: String
        let authorization: String
        let authorizationRawValue: Int
        var fullMedia: Bool? = nil
        var resources: [FixtureResource]? = nil
    }

    struct FixtureResource: Codable {
        let filename: String
        let role: String
        let byteCount: Int
        let sha256: String
        let captureDate: String
        let pairIdentifier: String?
    }
    private var generatedResources: [FixtureResource] = []

    init(runID requestedRunID: String? = nil, fullMedia requestedFullMedia: Bool? = nil,
         automaticAddRequested requestedAutomaticAdd: Bool? = nil) {
        let arguments = ProcessInfo.processInfo.arguments
        automaticAddRequested = requestedAutomaticAdd ?? arguments.contains("--fixture-auto-add")
        fullMedia = requestedFullMedia ?? arguments.contains("--fixture-full-media")
        authorization = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let value = requestedRunID ?? arguments.firstIndex(of: "--fixture-run-id").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        } ?? UUID().uuidString
        let safe = value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
        let sanitized = String(String.UnicodeScalarView(safe)).prefix(80)
        runID = sanitized.isEmpty ? UUID().uuidString : String(sanitized)
        // The helper reads only its own prior status, never the photo library.
        if let url = try? statusURL(),
           let data = try? Data(contentsOf: url),
           let previous = try? JSONDecoder().decode(StatusSnapshot.self, from: data),
           previous.runID == runID, previous.addedCount == (fullMedia ? 4 : 2),
           previous.fullMedia == fullMedia || (!fullMedia && previous.fullMedia == nil) {
            addedCount = previous.addedCount
            status = previous.status
            generatedResources = previous.resources ?? []
        }
        persistStatus()
    }

    func addAutomaticallyIfRequested() async {
        guard automaticAddRequested, !automaticAddStarted else { return }
        automaticAddStarted = true
        await addPhotos()
    }

    /// Reads only this process container's synthetic manifest and generated files.
    /// Idempotency is based on our own committed status; the Photos library is never enumerated.
    func verifiedFullMediaSummary() throws -> Data {
        guard fullMedia, addedCount == 4, generatedResources.count == 5, statusFileError == nil else {
            throw FixtureFailure("The run has not completed four synthetic media assets with five resource files.")
        }
        let expected: Set<String> = ["QA1.photo", "QA2.photo", "QA3.video", "QA4.photo", "QA4.pairedVideo"]
        guard Set(generatedResources.map(\.role)) == expected else {
            throw FixtureFailure("Synthetic resource roles do not match the complete fixture set.")
        }
        let document = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let prefix = "fixtures-\(runID)/"
        for resource in generatedResources {
            guard resource.filename.hasPrefix(prefix), !resource.filename.contains(".."), !resource.filename.hasPrefix("/") else {
                throw FixtureFailure("Synthetic resource path is outside the run's generated directory.")
            }
            let bytes = try Data(contentsOf: document.appendingPathComponent(resource.filename), options: .mappedIfSafe)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard bytes.count == resource.byteCount, hash == resource.sha256 else {
                throw FixtureFailure("A generated synthetic resource changed or is incomplete.")
            }
        }
        return try Data(contentsOf: statusURL())
    }

    private func statusURL() throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("fixture-status.json")
    }

    private func persistStatus() {
        let name: String
        switch authorization {
        case .notDetermined: name = "notDetermined"
        case .restricted: name = "restricted"
        case .denied: name = "denied"
        case .authorized: name = "authorized"
        case .limited: name = "limited"
        @unknown default: name = "unknown"
        }
        let snapshot = StatusSnapshot(runID: runID, addedCount: addedCount, status: status,
                                      authorization: name, authorizationRawValue: authorization.rawValue,
                                      fullMedia: fullMedia, resources: generatedResources)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: statusURL(), options: .atomic)
            statusFileError = nil
        } catch {
            statusFileError = "Could not write fixture-status.json: \(error.localizedDescription)"
        }
    }

    func image(number: Int) -> UIImage {
        if fullMedia { return fixtureImage(number: number) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 960, height: 720), format: format).image { context in
            let bounds = CGRect(x: 0, y: 0, width: 960, height: 720)
            (number == 1 ? UIColor(red: 0.05, green: 0.30, blue: 0.80, alpha: 1)
                         : UIColor(red: 0.85, green: 0.22, blue: 0.05, alpha: 1)).setFill()
            context.fill(bounds)
            UIColor.white.withAlphaComponent(0.18).setFill()
            let shape = CGRect(x: 650, y: 60, width: 240, height: 240)
            if number == 1 {
                context.cgContext.fillEllipse(in: shape)
            } else {
                context.fill(shape)
            }
            let white: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 88), .foregroundColor: UIColor.white
            ]
            ("JINBAO QA \(number)" as NSString).draw(in: CGRect(x: 54, y: 290, width: 870, height: 120), withAttributes: white)
            ("960 × 720 · SYNTHETIC" as NSString).draw(
                in: CGRect(x: 60, y: 438, width: 840, height: 60),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 34), .foregroundColor: UIColor.white])
            ("RUN \(runID)" as NSString).draw(
                in: CGRect(x: 60, y: 540, width: 840, height: 140),
                withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 26, weight: .medium), .foregroundColor: UIColor.white])
        }
    }

    func addPhotos() async {
        guard !busy, addedCount == 0 else { return }
        busy = true
        status = "Requesting add-only photo access."
        persistStatus()
        defer {
            busy = false
            persistStatus()
        }
        authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        persistStatus()
        guard authorization == .authorized else {
            status = "Photo access was not granted. Enable Add Photos Only in Settings, then retry."
            return
        }
        if fullMedia {
            do { try await addFullMedia() }
            catch { status = "Full media creation failed: \(error.localizedDescription). No partial batch was submitted." }
            return
        }
        let resources = (1...2).compactMap { number -> (Int, Data)? in
            guard let data = image(number: number).pngData() else { return nil }
            return (number, data)
        }
        guard resources.count == 2 else {
            status = "Could not generate the two synthetic images. No photos were added."
            return
        }
        let identifier = runID
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for (number, data) in resources {
                    let request = PHAssetCreationRequest.forAsset()
                    request.creationDate = Date()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = "JINBAO_QA_\(number)_\(identifier).png"
                    request.addResource(with: .photo, data: data, options: options)
                }
            }
            addedCount = 2
            status = "Added 2 synthetic photos. Match the visible run ID before importing."
        } catch {
            // Keep the error visible without enumerating the photo library.
            status = "Photo creation failed: \(error.localizedDescription)"
        }
    }
}

extension PhotoFixture {
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

    private func addFullMedia() async throws {
        status = "Generating synthetic photos, video and Live Photo resources."
        persistStatus()
        let document = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = document.appendingPathComponent("fixtures-\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dates = ["2026-10-19T10:30:00+08:00", "2026-10-19T11:45:00+08:00", "2026-10-19T12:00:00+08:00", "2026-10-19T12:30:00+08:00"]
        let pairID = UUID().uuidString
        let photo1 = folder.appendingPathComponent("JINBAO_QA_1_\(runID).jpg")
        let photo2 = folder.appendingPathComponent("JINBAO_QA_2_\(runID).jpg")
        let video = folder.appendingPathComponent("JINBAO_QA_3_\(runID).mov")
        let liveStill = folder.appendingPathComponent("JINBAO_QA_4_\(runID).jpg")
        let liveVideo = folder.appendingPathComponent("JINBAO_QA_4_\(runID).mov")
        try writeJPEG(image: fixtureImage(number: 1), to: photo1, date: "2026:10:19 10:30:00")
        try writeJPEG(image: fixtureImage(number: 2), to: photo2, date: "2026:10:19 11:45:00")
        try await writeMovie(to: video, number: 3, captureDate: dates[2], pairID: nil)
        try writeJPEG(image: fixtureImage(number: 4, phase: 0.5), to: liveStill, date: "2026:10:19 12:30:00", pairID: pairID)
        try await writeMovie(to: liveVideo, number: 4, captureDate: dates[3], pairID: pairID)
        status = "Validating the synthetic Live Photo resource pair before adding."
        persistStatus()
        try await validateLivePair(photo: liveStill, video: liveVideo)
        let definitions: [(URL, String, String, String?)] = [
            (photo1, "QA1.photo", dates[0], nil), (photo2, "QA2.photo", dates[1], nil),
            (video, "QA3.video", dates[2], nil), (liveStill, "QA4.photo", dates[3], pairID), (liveVideo, "QA4.pairedVideo", dates[3], pairID)]
        generatedResources = try definitions.map { url, role, capture, identifier in
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            return FixtureResource(filename: "fixtures-\(runID)/\(url.lastPathComponent)", role: role, byteCount: bytes.count,
                                   sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), captureDate: capture, pairIdentifier: identifier)
        }
        persistStatus()
        let formatter = ISO8601DateFormatter()
        let instants = dates.compactMap { formatter.date(from: $0) }
        guard instants.count == 4 else { throw FixtureFailure("Synthetic capture dates are invalid.") }
        try await PHPhotoLibrary.shared().performChanges {
            for (index, url) in [photo1, photo2, video].enumerated() {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = instants[index]
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = url.lastPathComponent
                request.addResource(with: index == 2 ? .video : .photo, fileURL: url, options: options)
            }
            let live = PHAssetCreationRequest.forAsset()
            live.creationDate = instants[3]
            let stillOptions = PHAssetResourceCreationOptions()
            stillOptions.originalFilename = liveStill.lastPathComponent
            let motionOptions = PHAssetResourceCreationOptions()
            motionOptions.originalFilename = liveVideo.lastPathComponent
            live.addResource(with: .photo, fileURL: liveStill, options: stillOptions)
            live.addResource(with: .pairedVideo, fileURL: liveVideo, options: motionOptions)
        }
        addedCount = 4
        status = "Added 4 synthetic assets: QA1, QA2, QA3 video and validated QA4 Live Photo. Resource copies and SHA-256 are in Documents."
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

    private func validateLivePair(photo: URL, video: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHLivePhoto.request(withResourceFileURLs: [photo, video], placeholderImage: nil, targetSize: CGSize(width: 960, height: 720), contentMode: .aspectFit) { live, info in
                if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true { return }
                if let live, live.size.width > 0 { continuation.resume() }
                else { continuation.resume(throwing: FixtureFailure("Photos rejected the generated Live Photo pair; no static substitute was added.")) }
            }
        }
    }
}

private struct FixtureFailure: LocalizedError {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { detail }
}
