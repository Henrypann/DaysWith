import XCTest
import UIKit
import ImageIO
import AVFoundation
@testable import Jinbao365

final class MediaImportTests: XCTestCase {
    func testEXIFOffsetAndSubsecondIdentifyInstant() throws {
        let capture = MediaImportMetadata.parseEXIF("2026:10:19 14:15:16", offset: "+08:00", subsecond: "123")
        let expected = ISO8601DateFormatter().date(from: "2026-10-19T06:15:16Z")!
        XCTAssertEqual(capture.millis, Int64(expected.timeIntervalSince1970 * 1000) + 123)
        XCTAssertEqual(capture.metadata.timezoneOffsetMinutes, 480)
        XCTAssertFalse(capture.metadata.isEstimated)
    }

    func testUnknownTimezonePreservesWallClockWithoutInventingInstant() {
        let capture = MediaImportMetadata.parseEXIF("2021:01:02 03:04:05", offset: nil)
        XCTAssertEqual(capture.millis, 0)
        XCTAssertEqual(capture.metadata.localDateTime, "2021-01-02 03:04:05")
        XCTAssertNil(capture.metadata.timezoneOffsetMinutes)
        XCTAssertTrue(capture.metadata.isEstimated)
    }

    func testInvalidMetadataCannotBecomeCaptureTime() {
        XCTAssertEqual(MediaImportMetadata.parseEXIF("not a date", offset: "+08:00").millis, 0)
        XCTAssertEqual(MediaImportMetadata.parseEXIF("2026:10:19 14:15:16", offset: "+99:99").millis, 0)
    }

    func testLibraryDateIsAnAbsoluteInstantWithKnownSource() {
        let date = Date(timeIntervalSince1970: 1_700_000_123)
        let capture = ImportedCaptureTime.library(date)
        XCTAssertEqual(capture.millis, 1_700_000_123_000)
        XCTAssertEqual(capture.metadata.source, "photosCreationDate")
        XCTAssertFalse(capture.metadata.isEstimated)
    }

    @MainActor func testDeliveredBytesAreUnchangedAndPreviewIsSeparate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 8))
        let image = renderer.image { context in UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 12, height: 8)) }
        let bytes = try XCTUnwrap(image.pngData())
        let asset = try PhotoImport.store(data: bytes, filename: "synthetic.png", provenance: .systemProvided, directory: directory)
        let original = try XCTUnwrap(asset.resources.first { $0.role == "photo" })
        let preview = try XCTUnwrap(asset.resources.first { $0.role == "preview" })
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(original.relativePath)), bytes)
        XCTAssertEqual(original.sha256, Digest.sha256Hex(bytes))
        XCTAssertNotEqual(original.relativePath, preview.relativePath)
        XCTAssertEqual(preview.contentType, "image/jpeg")
        XCTAssertEqual(asset.provenance, "systemProvided")
        XCTAssertEqual(asset.capturedAt, 0)
    }

    @MainActor func testCameraFallbackHasActualCaptureSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.jpegData(compressionQuality: 0.9)!
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let asset = try PhotoImport.store(data: bytes, filename: "camera.jpg", provenance: .camera, directory: directory)
        XCTAssertGreaterThanOrEqual(asset.capturedAt, before)
        XCTAssertEqual(asset.captureMetadata?.source, "appCamera")
    }

    func testEmptyFileIsRejectedWithoutSavingAnAsset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try PhotoImport.store(data: Data(), filename: "empty.jpg", provenance: .fileSelected, directory: directory))
    }
    @MainActor func testAndroidMotionPhotoUsesOriginalStaticImageWithoutPretendingToBeLivePhoto() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 8)).image { context in
            UIColor.cyan.setFill(); context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        }
        var delivered = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        // Motion-photo containers append a video payload after the complete JPEG image.
        delivered.append(Data([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x6D, 0x70, 0x34, 0x32]))
        let original = folder.appendingPathComponent("android-motion.jpg")
        try delivered.write(to: original)
        let selected = try XCTUnwrap(MediaPlaybackResourceLayout.imageURL(kind: "motionPhoto", resources: ["motionPhoto": original]))
        XCTAssertEqual(selected, original)
        XCTAssertEqual(MediaPlaybackResourceLayout.requiredRoles(kind: "motionPhoto"), ["motionPhoto"])
        XCTAssertNotNil(UIImage(contentsOfFile: selected.path))
        XCTAssertEqual(try Data(contentsOf: selected), delivered)
        XCTAssertNil(MediaPlaybackResourceLayout.imageURL(kind: "livePhoto", resources: ["motionPhoto": original]))
    }

}
