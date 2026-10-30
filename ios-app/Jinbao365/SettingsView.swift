import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var disconnectConfirmation = false

    var body: some View {
        Form {
            Section("这台手机") {
                if let parent = model.session.identity {
                    HStack { Text("署名"); Spacer(); ParentBadge(parent: parent) }
                }
                Text("署名已确认，用来区分爸爸和妈妈的记录。").font(.footnote).foregroundStyle(Theme.inkSecondary)
            }
            Section("云备份") {
                NavigationLink { CloudConnectView(mandatory: false).navigationTitle("云备份").navigationBarTitleDisplayMode(.inline) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.backupStatusTitle)
                        Text(model.backupStatusDetail).font(.caption).foregroundStyle(Theme.inkSecondary)
                    }
                }.accessibilityIdentifier("settingsBackup")
                NavigationLink { CloudConnectView(mandatory: false, editingConfiguration: true).navigationTitle("连接设置").navigationBarTitleDisplayMode(.inline) } label: {
                    Label("编辑连接", systemImage: "link")
                }.accessibilityIdentifier("editConnection")
                if model.session.link.bucket != nil {
                    Button("断开云存储", role: .destructive) { disconnectConfirmation = true }
                        .accessibilityIdentifier("settingsDisconnect")
                }
            }
            Section {
                Toggle("允许蜂窝网络下载原件", isOn: Binding(get: { model.allowCellularOriginals }, set: { model.setAllowCellularOriginals($0) }))
                    .accessibilityIdentifier("allowCellularOriginals")
            } footer: {
                Text("关闭后，使用蜂窝网络查看云端原件时会先询问。已经缓存的原件可以离线查看。")
            }
            Section("本机档案") {
                NavigationLink { DraftsView() } label: { Label("草稿箱", systemImage: "square.and.pencil") }
                NavigationLink { TrashView() } label: { Label("回收站", systemImage: "trash") }
                    .accessibilityIdentifier("openTrash")
                Button {
                    model.beginDraft()
                    model.openFileImport = true
                } label: { Label("从文件导入", systemImage: "folder") }
                    .accessibilityIdentifier("importFiles")
                HStack { Text("本机存储占用"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: model.localStorageBytes, countStyle: .file)).foregroundStyle(Theme.inkSecondary) }
            }
            Section("关于") {
                HStack { Text("版本"); Spacer(); Text(version).foregroundStyle(Theme.inkSecondary) }
                LabeledContent("设备编号") { Text(model.session.deviceID).font(.caption).textSelection(.enabled).foregroundStyle(Theme.inkSecondary) }
                Text("Android 使用自建相册网格；iOS 使用系统选图器。两端支持多选、预览和保存，选图界面暂有差异，后续可统一。").font(.footnote).foregroundStyle(Theme.inkSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("断开云存储？", isPresented: $disconnectConfirmation, titleVisibility: .visible) {
            Button("断开连接", role: .destructive) { model.disconnect() }
            Button("取消", role: .cancel) {}
        } message: { Text("这台手机上的记录仍然保留。重新连接后可继续读取云端档案。") }
    }
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        return "\(name) (\(build))"
    }
}

struct TrashView: View {
    @EnvironmentObject private var model: AppModel
    private var moments: [LocalMoment] { model.session.moments.filter { $0.trashedAt != nil }.sorted { ($0.trashedAt ?? 0) > ($1.trashedAt ?? 0) } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if moments.isEmpty {
                    FeatureEmptyState(title: "回收站是空的", detail: "移除的本机记录会保留在这里，可以随时恢复。", systemImage: "trash")
                } else {
                    Text("这里只保留这台手机移除的记录。恢复会重新显示记录，云端原件不会被删除。")
                        .font(.subheadline).foregroundStyle(Theme.inkSecondary)
                    ForEach(moments) { moment in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(moment.title.isEmpty ? (moment.note.isEmpty ? "值得留住的小日常" : moment.note) : moment.title)
                                .font(.headline).foregroundStyle(Theme.ink).lineLimit(3)
                            Text(moment.occurredAt > 0 ? Date(timeIntervalSince1970: Double(moment.occurredAt) / 1000).formatted(date: .abbreviated, time: .shortened) : "日期未知")
                                .font(.caption).foregroundStyle(Theme.inkSecondary)
                            Text("\(moment.assets.count)个媒体文件").font(.caption).foregroundStyle(Theme.inkSecondary)
                            GoldButton(title: "恢复记录") { model.restoreMoment(id: moment.id) }
                                .accessibilityIdentifier("restoreMoment-\(moment.id)")
                        }.modifier(BrandCard())
                    }
                }
            }.padding(16)
        }
        .background(Theme.background)
        .navigationTitle("回收站")
        .navigationBarTitleDisplayMode(.inline)
    }
}
