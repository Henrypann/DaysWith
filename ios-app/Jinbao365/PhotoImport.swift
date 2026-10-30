import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import Photos

/// Stores delivered bytes, not a re-encoded copy. Derived previews never replace originals.
enum PhotoImport {
    static func isDisplayablePreview(_ data: Data, contentType: String) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let imageType = CGImageSourceGetType(source), UTType(imageType as String)?.preferredMIMEType == contentType,
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = values[kCGImagePropertyPixelWidth] as? Int, let height = values[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 32_000_000 else { return false }
        return UIImage(data: data) != nil
    }

    static func store(data: Data, filename: String, provenance: ImportProvenance, directory: URL) throws -> LocalAsset {
        guard !data.isEmpty else { throw error("系统交付了空文件，请重新选择。") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ((filename as NSString).pathExtension.isEmpty ? "jpg" : (filename as NSString).pathExtension))
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try store(file: temporary, filename: filename, provenance: provenance, directory: directory)
    }

    static func store(file: URL, filename: String, provenance: ImportProvenance, directory: URL, libraryDate: Date? = nil) throws -> LocalAsset {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value, (1...V1Validator.maxResourceBytes).contains(size) else {
            throw error("文件为空、不可读取或超过单项媒体大小上限。")
        }
        let isMovie = UTType(filenameExtension: (filename as NSString).pathExtension)?.conforms(to: .movie) == true
        let type = isMovie ? (UTType(filenameExtension: (filename as NSString).pathExtension)?.preferredMIMEType ?? "video/quicktime") : imageType(file)
        guard let type else { throw error("这个文件无法识别为照片或视频，请选择其他文件。") }
        let id = UUID().uuidString.uppercased()
        let folder = directory.appendingPathComponent("media/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let suffix = UTType(mimeType: type)?.preferredFilenameExtension ?? (isMovie ? "mov" : "jpg")
            let original = folder.appendingPathComponent("original.\(suffix)")
            try FileManager.default.copyItem(at: file, to: original)
            let role = isMovie ? "video" : "photo"
            let originalResource = try resource(url: original, assetID: id, role: role, type: type, originalFilename: filename)
            guard let preview = isMovie ? moviePreview(original) : imagePreview(original) else {
                throw error("文件已读到，但无法生成预览。请重试或选择其他文件。")
            }
            let previewResource = try savePreview(preview, folder: folder, assetID: id)
            var capture = libraryDate.map(ImportedCaptureTime.library) ?? (isMovie ? MediaImportMetadata.movie(original) : MediaImportMetadata.image(original))
            if provenance == .camera && capture.millis == 0 {
                capture = ImportedCaptureTime(millis: Int64(Date().timeIntervalSince1970 * 1000), metadata: CaptureMetadata(source: "appCamera"))
            }
            return LocalAsset(id: id, kind: isMovie ? "video" : "photo", capturedAt: capture.millis,
                              provenance: provenance.rawValue, resources: [originalResource, previewResource], captureMetadata: capture.metadata)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func storeLivePhoto(_ livePhoto: PHLivePhoto, directory: URL, libraryDate: Date? = nil) async throws -> LocalAsset {
        let resources = PHAssetResource.assetResources(for: livePhoto)
        guard let still = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }),
              let video = resources.first(where: { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }) else {
            throw error("系统没有交付完整的实况照片资源，请重试。")
        }
        let id = UUID().uuidString.uppercased()
        let folder = directory.appendingPathComponent("media/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            var stored: [LocalResource] = []
            var stillURL: URL?
            for (index, assetResource) in [still, video].enumerated() {
                let fallback = index == 0 ? "heic" : "mov"
                let suffix = UTType(assetResource.uniformTypeIdentifier)?.preferredFilenameExtension ?? fallback
                let url = folder.appendingPathComponent(index == 0 ? "original.\(suffix)" : "paired.\(suffix)")
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    PHAssetResourceManager.default().writeData(for: assetResource, toFile: url, options: options) { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
                let type = UTType(assetResource.uniformTypeIdentifier)?.preferredMIMEType ?? (index == 0 ? "image/heic" : "video/quicktime")
                stored.append(try resource(url: url, assetID: id, role: index == 0 ? "livePhotoImage" : "livePhotoVideo", type: type, originalFilename: assetResource.originalFilename))
                if index == 0 { stillURL = url }
            }
            guard let stillURL, let preview = imagePreview(stillURL) else { throw error("实况照片的预览无法生成，请重试。") }
            stored.append(try savePreview(preview, folder: folder, assetID: id))
            let capture = libraryDate.map(ImportedCaptureTime.library) ?? MediaImportMetadata.image(stillURL)
            return LocalAsset(id: id, kind: "livePhoto", capturedAt: capture.millis, provenance: ImportProvenance.systemProvided.rawValue,
                              resources: stored, captureMetadata: capture.metadata)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func contentType(filename: String, data: Data) -> String {
        if let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source),
           let mime = UTType(type as String)?.preferredMIMEType { return mime }
        return UTType(filenameExtension: (filename as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private static func imageType(_ file: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let type = CGImageSourceGetType(source),
              let mime = UTType(type as String)?.preferredMIMEType, mime.hasPrefix("image/") else { return nil }
        return mime
    }

    private static func resource(url: URL, assetID: String, role: String, type: String, originalFilename: String) throws -> LocalResource {
        let result = try Digest.sha256File(url)
        guard result.byteCount > 0 else { throw error("系统交付了空文件，请重新选择。") }
        return LocalResource(id: UUID().uuidString.uppercased(), role: role, contentType: type,
                             originalFilename: originalFilename.isEmpty ? url.lastPathComponent : originalFilename,
                             byteCount: result.byteCount, sha256: result.hash, relativePath: "media/\(assetID)/\(url.lastPathComponent)")
    }

    private static func savePreview(_ data: Data, folder: URL, assetID: String) throws -> LocalResource {
        let url = folder.appendingPathComponent("preview.jpg")
        try data.write(to: url, options: .atomic)
        return try resource(url: url, assetID: assetID, role: "preview", type: "image/jpeg", originalFilename: "preview.jpg")
    }

    private static func imagePreview(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1280] as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.82)
    }

    private static func moviePreview(_ url: URL) -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        guard let frame = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: frame).jpegData(compressionQuality: 0.82)
    }

    private static func error(_ message: String) -> ContractError { ContractError(path: "media", message: message) }
}
