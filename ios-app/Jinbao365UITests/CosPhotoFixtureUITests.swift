import XCTest
import UIKit
import Photos
import ImageIO
import CryptoKit

/// Explicitly adds one legible synthetic photo. Does not launch the main app or inspect the library.
@MainActor
final class CosPhotoFixtureUITests: XCTestCase {
    private let fixtureRun = "QA20261019COS"

    func testSeedLegibleSyntheticQA1() async throws {
        guard ProcessInfo.processInfo.environment["JINBAO_COS_PHOTO_FIXTURE"] == "1" else {
            throw XCTSkip("Explicit JINBAO_COS_PHOTO_FIXTURE=1 is required.")
        }
        let folder = try fixtureFolder()
        let manifestURL = folder.appendingPathComponent("manifest.json")
        let photoURL = folder.appendingPathComponent("legible-qa1.png")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let existing = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
            guard existing.version == 1, existing.run == fixtureRun, existing.width == 960, existing.height == 960,
                  existing.photoCreationCommitted else { throw FixtureFailure.incompletePriorAttempt }
            try verifyFile(photoURL, manifest: existing)
            try attachReceipt(existing, reused: true)
            return
        }
        // A file without a manifest is retained for review rather than overwritten or added again.
        guard try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty else {
            throw FixtureFailure.incompletePriorAttempt
        }
        try await authorizeAddOnly()
        let capturedAt = Date()
        let bytes = try makePNG(capturedAt: capturedAt)
        try bytes.write(to: photoURL, options: [.atomic, .completeFileProtection])
        var manifest = Manifest(version: 1, run: fixtureRun, width: 960, height: 960,
                                captureDate: capturedAt, byteCount: bytes.count, sha256: hash(bytes),
                                photoCreationCommitted: false)
        // Persist intent first. A crash between library commit and manifest commit cannot cause an automatic duplicate.
        try save(manifest, to: manifestURL)
        let success: Bool = await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = capturedAt
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "JINBAO_QA1_LEGIBLE_QA20261019COS.png"
                options.uniformTypeIdentifier = "public.png"
                request.addResource(with: .photo, data: bytes, options: options)
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
        guard success else { throw FixtureFailure.creationFailed }
        manifest.photoCreationCommitted = true
        try save(manifest, to: manifestURL)
        try verifyFile(photoURL, manifest: manifest)
        try attachReceipt(manifest, reused: false)
    }

    private func authorizeAddOnly() async throws {
        let existing = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if existing == .authorized { return }
        guard existing == .notDetermined else { throw FixtureFailure.authorizationDenied }
        var result: PHAuthorizationStatus?
        let authorization = Task { result = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(120)
        var allowedExpectedPrompt = false
        while Date() < deadline, result == nil {
            let alert = springboard.alerts.firstMatch
            if alert.exists, !allowedExpectedPrompt, isExpectedAddOnlyPrompt(alert) {
                let labels = ["Allow Photos to Be Added", "Allow Adding Photos", "允许添加照片", "允许添加", "允许", "Allow", "OK", "好"]
                for label in labels {
                    let buttons = alert.buttons.matching(NSPredicate(format: "label == %@", label))
                        .allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
                    if buttons.count == 1 { buttons[0].tap(); allowedExpectedPrompt = true; break }
                }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard result == .authorized else {
            authorization.cancel()
            throw FixtureFailure.authorizationDenied
        }
        await authorization.value
    }

    private func isExpectedAddOnlyPrompt(_ alert: XCUIElement) -> Bool {
        // Match the same runner add-only prompt as migration seeding. Alert text is never retained or attached.
        let text = ([alert.label] + alert.staticTexts.allElementsBoundByAccessibilityElement.map(\.label))
            .joined(separator: " ").lowercased()
        let namesRunner = text.contains("jinbao") || text.contains("孩子") || text.contains("runner") || text.contains("uitests")
        let addsPhotos = (text.contains("添加") && text.contains("照片")) || (text.contains("add") && text.contains("photo"))
        return namesRunner && addsPhotos
    }

    private func makePNG(capturedAt: Date) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let lines: [(String, CGFloat, CGFloat)] = [("JINBAO QA 1", 80, 300), ("RUN", 60, 430), (fixtureRun, 72, 540)]
        // Draw each line at its measured size; never wrap, shrink, truncate or crop a marker.
        for (text, size, _) in lines {
            let measured = (text as NSString).size(withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: size, weight: .bold)])
            guard measured.width <= 864, measured.height <= 120 else { throw FixtureFailure.renderingFailed }
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 960, height: 960), format: format).image { context in
            UIColor(red: 0.05, green: 0.30, blue: 0.80, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 960, height: 960))
            for (text, size, y) in lines {
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: size, weight: .bold),
                                                                 .foregroundColor: UIColor.white]
                let measured = (text as NSString).size(withAttributes: attributes)
                (text as NSString).draw(at: CGPoint(x: (960 - measured.width) / 2, y: y), withAttributes: attributes)
            }
        }
        guard let cgImage = image.cgImage else { throw FixtureFailure.renderingFailed }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else {
            throw FixtureFailure.renderingFailed
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        let properties: [String: Any] = [kCGImagePropertyExifDictionary as String:
            [kCGImagePropertyExifDateTimeOriginal as String: formatter.string(from: capturedAt)]]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FixtureFailure.renderingFailed }
        return encoded as Data
    }

    private func fixtureFolder() throws -> URL {
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = cache.appendingPathComponent("JinbaoCOSLegiblePhotoFixture-QA20261019COS-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        return folder
    }
    private func save(_ manifest: Manifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url, options: [.atomic, .completeFileProtection])
    }
    private func verifyFile(_ url: URL, manifest: Manifest) throws {
        let bytes = try Data(contentsOf: url)
        guard bytes.count == manifest.byteCount, hash(bytes) == manifest.sha256,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              properties[kCGImagePropertyPixelWidth as String] as? Int == 960,
              properties[kCGImagePropertyPixelHeight as String] as? Int == 960 else { throw FixtureFailure.renderingFailed }
    }
    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func attachReceipt(_ manifest: Manifest, reused: Bool) throws {
        let receipt: [String: Any] = ["byteCount": manifest.byteCount, "sha256": manifest.sha256,
            "singlePhotoCreationCommitted": manifest.photoCreationCommitted, "idempotentManifestReused": reused,
            "syntheticFileHashVerified": true, "markersNotWrappedOrCropped": true,
            "creationUsedAddOnlyAuthorization": true, "mainAppLaunched": false, "mainAppRecordsChanged": false,
            "photoLibraryReadOrEnumerated": false, "photoLibraryDeleted": false]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "Legible synthetic QA1 fixture receipt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct Manifest: Codable {
        let version: Int
        let run: String
        let width: Int
        let height: Int
        let captureDate: Date
        let byteCount: Int
        let sha256: String
        var photoCreationCommitted: Bool
    }
    private enum FixtureFailure: Error { case incompletePriorAttempt, authorizationDenied, creationFailed, renderingFailed }
}
