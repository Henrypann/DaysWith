import PhotosUI
import Photos
import SwiftUI
import UniformTypeIdentifiers

struct SystemMediaPicker: UIViewControllerRepresentable {
    var maximumSelection: Int
    let onResults: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos, .livePhotos])
        configuration.selectionLimit = max(1, maximumSelection)
        configuration.selection = .ordered
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onResults: onResults) }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onResults: ([PHPickerResult]) -> Void
        init(onResults: @escaping ([PHPickerResult]) -> Void) { self.onResults = onResults }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) { onResults(results) }
    }
}

/// Providers remain in memory for explicit retry; picker cancellation never changes a draft.
struct MediaImportRequest: Identifiable {
    let id = UUID()
    let result: PHPickerResult?
    let file: URL?
    let title: String
    var message: String?
    var completedAssetID: String?

    init(result: PHPickerResult, index: Int) {
        self.result = result
        file = nil
        title = result.itemProvider.suggestedName ?? "第 \(index + 1) 项媒体"
    }
    init(file: URL) {
        result = nil
        self.file = file
        title = file.lastPathComponent
    }

    func load(directory: URL) async throws -> LocalAsset {
        if let file {
            let access = file.startAccessingSecurityScopedResource()
            defer { if access { file.stopAccessingSecurityScopedResource() } }
            return try PhotoImport.store(file: file, filename: file.lastPathComponent, provenance: .fileSelected, directory: directory)
        }
        guard let result else { throw ContractError(path: "media", message: "请重新选择这项媒体。") }
        let date = Self.authorizedDate(identifier: result.assetIdentifier)
        let provider = result.itemProvider
        if provider.canLoadObject(ofClass: PHLivePhoto.self) {
            let live: PHLivePhoto = try await withCheckedThrowingContinuation { continuation in
                provider.loadObject(ofClass: PHLivePhoto.self) { object, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let live = object as? PHLivePhoto { continuation.resume(returning: live) }
                    else { continuation.resume(throwing: ContractError(path: "media", message: "实况照片下载未完成，请检查网络后重试。")) }
                }
            }
            return try await PhotoImport.storeLivePhoto(live, directory: directory, libraryDate: date)
        }
        let identifier = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .movie) == true }
            ?? provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
        guard let identifier else { throw ContractError(path: "media", message: "这项内容不是支持的照片或视频。") }
        let copied: URL = try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw ContractError(path: "media", message: "系统未交付文件，请检查网络后重试。") }
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          let size = (attributes[.size] as? NSNumber)?.int64Value, (1...V1Validator.maxResourceBytes).contains(size) else {
                        throw ContractError(path: "media", message: "文件为空或超过单项媒体大小上限。")
                    }
                    let suffix = UTType(identifier)?.preferredFilenameExtension ?? url.pathExtension
                    let target = FileManager.default.temporaryDirectory.appendingPathComponent("jinbao-picker-\(UUID().uuidString).\(suffix)")
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: target)
                } catch { continuation.resume(throwing: error) }
            }
        }
        defer { try? FileManager.default.removeItem(at: copied) }
        var name = provider.suggestedName ?? copied.lastPathComponent
        if (name as NSString).pathExtension.isEmpty { name += "." + copied.pathExtension }
        return try PhotoImport.store(file: copied, filename: name, provenance: .systemProvided, directory: directory, libraryDate: date)
    }

    static func authorizedDate(identifier: String?) -> Date? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited, let identifier else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject?.creationDate
    }
}
