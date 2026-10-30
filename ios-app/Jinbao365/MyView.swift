import SwiftUI

struct MyView: View {
    @EnvironmentObject private var model: AppModel
    private var records: [TimelineEntry] { model.session.timelineEntries() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 14) {
                            BrandMark(size: 58)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("共同的生活档案").font(.title3.bold()).foregroundStyle(Theme.ink)
                                if let parent = model.session.identity { ParentBadge(parent: parent) }
                            }
                        }
                        HStack(spacing: 0) {
                            count("记录", records.count)
                            count("媒体", records.reduce(0) { $0 + $1.mediaCount })
                            count("纪念日", model.session.anniversaryEntries().count)
                        }
                    }.modifier(BrandCard(padding: 20))
                    VStack(spacing: 0) {
                        Button { model.tab = .timeline } label: { FeatureRow(title: "家庭时光", subtitle: "爸爸和妈妈一起留下的记录", system: "photo.on.rectangle") }
                        Divider()
                        NavigationLink { DraftsView() } label: { FeatureRow(title: "草稿箱", subtitle: model.session.draft == nil ? "暂时没有草稿" : "1 条未完成的记录", system: "square.and.pencil") }
                            .accessibilityIdentifier("openDrafts")
                        Divider()
                        NavigationLink { CloudConnectView(mandatory: false).navigationTitle("云备份").navigationBarTitleDisplayMode(.inline) } label: {
                            FeatureRow(title: "云备份", subtitle: model.backupStatusTitle, system: "icloud")
                        }.accessibilityIdentifier("tabCloud")
                        Divider()
                        NavigationLink { SettingsView() } label: { FeatureRow(title: "设置", subtitle: "连接、存储与应用信息", system: "gearshape") }
                            .accessibilityIdentifier("openSettings")
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                    Text("记录成长，收藏美好").font(.footnote).foregroundStyle(Theme.inkSecondary).padding(.top, 8)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("我的")
        }
    }
    private func count(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 4) {
            Text("\(value)").font(.title2.bold()).monospacedDigit().foregroundStyle(Theme.ink)
            Text(title).font(.caption).foregroundStyle(Theme.inkSecondary)
        }.frame(maxWidth: .infinity)
    }
}

struct FeatureRow: View {
    let title: String
    var subtitle: String? = nil
    let system: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: system).font(.title3).frame(width: 28).foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(Theme.ink)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.inkSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct DraftsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var discardConfirmation = false
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let draft = model.session.draft {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(draft.title.isEmpty ? "未完成的小日常" : draft.title).font(.headline).foregroundStyle(Theme.ink)
                        if !draft.note.isEmpty { Text(draft.note).lineLimit(3).foregroundStyle(Theme.inkSecondary) }
                        Text("\(draft.assets.count)个媒体文件 · 保存在这台手机").font(.caption).foregroundStyle(Theme.inkSecondary)
                        GoldButton(title: "继续编辑") { model.beginDraft() }.accessibilityIdentifier("resumeDraft")
                        Button("放弃草稿", role: .destructive) { discardConfirmation = true }.frame(minHeight: 44)
                    }.modifier(BrandCard())
                } else {
                    FeatureEmptyState(title: "草稿箱是空的", detail: "没有写完的记录会保存在这里。", systemImage: "square.and.pencil")
                    GoldButton(title: "写一条记录") { model.beginDraft() }
                }
            }.padding(16)
        }
        .background(Theme.background)
        .navigationTitle("草稿箱")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("放弃这条草稿？", isPresented: $discardConfirmation, titleVisibility: .visible) {
            Button("放弃草稿", role: .destructive) { model.discardDraft() }
            Button("取消", role: .cancel) {}
        } message: { Text("草稿会从这台手机移除，已保存的记录不受影响。") }
    }
}
