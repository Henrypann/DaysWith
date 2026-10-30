import PhotosUI
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ComposerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private enum EditingField: Hashable { case title, note }
    @FocusState private var focusedField: EditingField?
    @State private var title = ""
    @State private var note = ""
    @State private var importing = false
    @State private var importProgress = ""
    @State private var requests: [MediaImportRequest] = []
    @State private var pickerOpen = false
    @State private var documentsOpen = false
    @State private var closeConfirmation = false
    @State private var previewSelection: PhotoSelection?
    @State private var authorizationMessage = ""
    @State private var metadataAuthorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    private var assets: [LocalAsset] { model.session.draft?.assets ?? [] }
    private var photos: [TimelinePhoto] {
        assets.map { asset in
            TimelinePhoto(id: asset.id, localPath: asset.resources.first { $0.role == "preview" }?.relativePath,
                          fullSizePath: asset.resources.first { $0.role == "photo" || $0.role == "livePhotoImage" }?.relativePath,
                          kind: asset.kind, localResources: asset.resources)
        }
    }
    private var canSave: Bool {
        !importing && (!title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                       !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !assets.isEmpty)
    }
    private var occurredDate: Binding<Date> {
        Binding(get: { Date(timeIntervalSince1970: Double(model.session.draft?.occurredAt ?? Int64(Date().timeIntervalSince1970 * 1000)) / 1000) },
                set: { model.updateDraftOccurredAt(Int64($0.timeIntervalSince1970 * 1000)) })
    }

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("平凡的日子，也是宝贵的时光。")
                        .font(.system(size: 13)).foregroundStyle(Theme.inkSecondary)
                    TextField("给这一天起个名字", text: $title)
                        .font(.system(size: 20, weight: .semibold)).accessibilityIdentifier("draftTitle")
                        .focused($focusedField, equals: .title).submitLabel(.done).onSubmit { focusedField = nil }
                        .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    TextField("今天有哪些小小的美好？", text: $note, axis: .vertical)
                        .lineLimit(4...10).font(.system(size: 17)).accessibilityIdentifier("draftNote")
                        .focused($focusedField, equals: .note)
                        .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 12) {
                        dateTimeField("记录日期", components: .date, identifier: "draftDate")
                        dateTimeField("记录时间", components: .hourAndMinute, identifier: "draftTime")
                        if assets.contains(where: { $0.capturedAt == 0 || $0.captureMetadata?.isEstimated == true }) {
                            Text("部分媒体未提供完整拍摄时间。当前记录日期可修改；原始时间未知的媒体会保留未知状态。")
                                .font(.caption).foregroundStyle(Theme.inkSecondary).accessibilityIdentifier("estimatedCaptureTime")
                        } else if !assets.isEmpty {
                            Text("首次选图取最早拍摄时间，追加媒体不会覆盖记录日期。")
                                .font(.caption).foregroundStyle(Theme.inkSecondary)
                        }
                    }
                    .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    if !assets.isEmpty { mediaStrip }
                    if importing {
                        ProgressView(importProgress).accessibilityIdentifier("photoImportProgress")
                    }
                    ForEach(requests.filter { $0.message != nil }) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(request.title)：\(request.message ?? "导入失败")")
                                .font(.callout).foregroundStyle(Theme.problem).accessibilityIdentifier("photoImportFailure")
                            HStack {
                                Button("重试") { Task { await importRequests(only: request.id) } }.disabled(importing)
                                Button("重新选择") { requests.removeAll { $0.id == request.id }; pickerOpen = true }.disabled(importing || assets.count >= 30)
                                Button("移除", role: .destructive) { requests.removeAll { $0.id == request.id } }.disabled(importing)
                            }
                        }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Button {
                        focusedField = nil
                        pickerOpen = true
                    } label: {
                        Label(assets.count >= 30 ? "已选满 30 项媒体" : "选照片或视频 · \(assets.count)/30", systemImage: "photo.badge.plus")
                            .font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 52)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .accessibilityIdentifier("composerPickPhoto").disabled(importing || assets.count >= 30)
                    Button("从文件导入", systemImage: "doc.badge.plus") { focusedField = nil; documentsOpen = true }
                        .frame(minHeight: 44).accessibilityIdentifier("composerImportFiles").disabled(importing || assets.count >= 30)
                    if metadataAuthorization != .authorized && metadataAuthorization != .limited {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("系统选图无需开放整个相册。若文件未带拍摄日期，可选授权后重新选择，或直接修改记录日期。")
                                .font(.caption).foregroundStyle(Theme.inkSecondary)
                            Button("补充相册日期权限") { requestMetadataAuthorization() }
                                .frame(minHeight: 44).accessibilityIdentifier("authorizeCaptureDate")
                        }
                    }
                    if !authorizationMessage.isEmpty { Text(authorizationMessage).font(.caption).foregroundStyle(Theme.inkSecondary) }
                    if model.bannerIsError, let banner = model.banner {
                        Text(banner).foregroundStyle(Theme.problem).accessibilityIdentifier("composerError")
                    }
                    if !canSave && !importing {
                        Text("添加媒体、标题或文字，就可以保存这条记录。")
                            .font(.system(size: 13)).foregroundStyle(Theme.inkSecondary)
                    }
                }
                .foregroundStyle(Theme.ink)
                .frame(width: max(0, viewport.size.width - 32), alignment: .leading)
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively).background(Theme.background)
            .navigationTitle(model.session.draft?.originalMomentID == nil ? "记录小日常" : "编辑记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }.accessibilityIdentifier("dismissComposerKeyboard")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { focusedField = nil; closeConfirmation = true }.disabled(importing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        Text("保存").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 16).frame(minHeight: 44)
                            .background(canSave ? Theme.gold : Theme.separator, in: Capsule())
                    }.disabled(!canSave).accessibilityIdentifier("saveDraft")
                }
            }
            .onAppear {
                title = model.session.draft?.title ?? ""
                note = model.session.draft?.note ?? ""
                if model.openFileImport { model.openFileImport = false; documentsOpen = true }
                if model.openSystemPicker { model.openSystemPicker = false; pickerOpen = true }
            }
            .onChange(of: model.openSystemPicker) { _, open in
                if open { model.openSystemPicker = false; pickerOpen = true }
            }
            .onChange(of: model.openFileImport) { _, open in
                if open { model.openFileImport = false; documentsOpen = true }
            }
            .onChange(of: title) { _, _ in model.updateDraft(title: title, note: note) }
            .onChange(of: note) { _, _ in model.updateDraft(title: title, note: note) }
            .interactiveDismissDisabled()
            .confirmationDialog("保留这份草稿吗？", isPresented: $closeConfirmation, titleVisibility: .visible) {
                Button("保留草稿并关闭") { dismiss() }
                Button("放弃草稿", role: .destructive) { model.discardDraft(); if model.session.draft == nil { dismiss() } }
                Button("继续编辑", role: .cancel) {}
            }
            .sheet(isPresented: $pickerOpen) {
                SystemMediaPicker(maximumSelection: max(1, 30 - assets.count)) { results in
                    pickerOpen = false
                    guard !results.isEmpty else { return }
                    requests.append(contentsOf: results.enumerated().map { MediaImportRequest(result: $0.element, index: $0.offset) })
                    Task { await importRequests() }
                }
            }
            .fileImporter(isPresented: $documentsOpen, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    guard !urls.isEmpty else { return }
                    requests.append(contentsOf: urls.map { MediaImportRequest(file: $0) })
                    Task { await importRequests() }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { model.show(error) }
                }
            }
            .fullScreenCover(item: $previewSelection) { selection in PhotoGallery(photos: photos, initialID: selection.id) }
            }
        }
    }

    @ViewBuilder
    private func dateTimeField(_ label: String, components: DatePickerComponents, identifier: String) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(label).font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                // UIKit's compact date button has an intrinsic minimum width. Keep only
                // this native control within normal text sizes; the separate label and
                // the rest of the editor retain the user's full accessibility size.
                DatePicker(label, selection: occurredDate, displayedComponents: components)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier(identifier)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            DatePicker(label, selection: occurredDate, displayedComponents: components)
                .datePickerStyle(.compact)
                .accessibilityIdentifier(identifier)
        }
    }

    private var mediaStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                    VStack(alignment: .leading, spacing: 6) {
                        Button { focusedField = nil; previewSelection = PhotoSelection(id: asset.id) } label: {
                            ZStack(alignment: .bottomLeading) {
                                if let path = asset.resources.first(where: { $0.role == "preview" })?.relativePath,
                                   let url = model.fileURL(path), let image = UIImage(contentsOfFile: url.path) {
                                    Image(uiImage: image).resizable().scaledToFill().frame(width: 144, height: 156).clipped()
                                } else { Color.gray.frame(width: 144, height: 156) }
                                if asset.kind != "photo" {
                                    Label(asset.kind == "video" ? "视频" : asset.kind == "motionPhoto" ? "动态照片" : "实况", systemImage: asset.kind == "video" ? "play.fill" : "livephoto")
                                        .font(.caption.bold()).padding(6).foregroundStyle(.white).background(.black.opacity(0.6))
                                }
                            }.clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .accessibilityLabel("预览第\(index + 1)张照片").accessibilityIdentifier("draftPreview-\(asset.id)")
                        Text(ImportProvenance.known(asset.provenance)?.label ?? "来源未知").font(.caption).foregroundStyle(Theme.inkSecondary)
                        HStack {
                            Button { model.moveDraftAsset(from: index, to: index - 1) } label: { Image(systemName: "arrow.left") }
                                .disabled(importing || index == 0).accessibilityLabel("前移第\(index + 1)项媒体").frame(minWidth: 40, minHeight: 44)
                            Button { model.moveDraftAsset(from: index, to: index + 1) } label: { Image(systemName: "arrow.right") }
                                .disabled(importing || index == assets.count - 1).accessibilityLabel("后移第\(index + 1)项媒体").frame(minWidth: 40, minHeight: 44)
                            Button { model.removeAsset(asset.id) } label: { Image(systemName: "trash") }
                                .foregroundStyle(Theme.problem).disabled(importing).accessibilityLabel("移除第\(index + 1)项媒体")
                                .accessibilityIdentifier("removeDraftAsset-\(asset.id)").frame(minWidth: 40, minHeight: 44)
                        }
                    }.frame(width: 144).padding(8).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }.accessibilityIdentifier("draftPhotos")
    }

    private func save() {
        focusedField = nil
        guard model.updateDraft(title: title, note: note) else { return }
        model.commitDraft()
    }

    @MainActor private func importRequests(only requestID: UUID? = nil) async {
        guard !importing else { return }
        importing = true
        var prepared: [LocalAsset] = []
        var preparedRequests: [UUID] = []
        let candidates = requests.filter { requestID == nil ? $0.message == nil && $0.completedAssetID == nil : $0.id == requestID }
        for (index, request) in candidates.enumerated() {
            if assets.count + prepared.count >= 30 {
                setFailure(request.id, "一条记录最多 30 项媒体，请移除部分内容后重试。")
                continue
            }
            importProgress = "正在导入第 \(index + 1)/\(candidates.count) 项媒体，iCloud 文件可能需要下载"
            await Task.yield()
            do {
                let asset = try await request.load(directory: model.directory)
                prepared.append(asset)
                preparedRequests.append(request.id)
                setFailure(request.id, nil)
            } catch {
                setFailure(request.id, "\((error as? ContractError)?.message ?? error.localizedDescription) 请检查网络或文件后重试。")
            }
        }
        if !prepared.isEmpty {
            if model.importAssets(prepared) {
                requests.removeAll { preparedRequests.contains($0.id) }
            } else {
                for id in preparedRequests { setFailure(id, model.banner ?? "保存导入结果失败，请重试。") }
            }
        }
        importing = false
        importProgress = ""
    }

    private func setFailure(_ id: UUID, _ message: String?) {
        if let index = requests.firstIndex(where: { $0.id == id }) { requests[index].message = message }
    }

    private func requestMetadataAuthorization() {
        if metadataAuthorization == .denied || metadataAuthorization == .restricted {
            authorizationMessage = "相册日期权限未开放。你仍可使用系统选图并手动修改日期，也可在系统设置中调整权限。"
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                metadataAuthorization = status
                authorizationMessage = status == .authorized || status == .limited ? "已授权。重新选择媒体时会尝试读取所选内容的相册日期。" : "未授权也可以继续选图；缺失日期时可手动修改。"
            }
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (Data, String, ImportProvenance) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.modalPresentationStyle = .fullScreen
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.imageURL] as? URL, let data = try? Data(contentsOf: url), !data.isEmpty {
                parent.onImage(data, url.lastPathComponent, .camera)
            } else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.95) {
                parent.onImage(data, "camera.jpg", .camera)
            } else {
                let alert = UIAlertController(title: "照片未保存", message: "相机没有交付可读取的照片。请重新拍摄，或使用系统选图。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "返回", style: .default) { [weak self] _ in self?.parent.dismiss() })
                picker.present(alert, animated: true)
                return
            }
            parent.dismiss()
        }
    }
}
