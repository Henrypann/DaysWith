import SwiftUI

@main
struct Jinbao365App: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.light)
                .tint(Theme.ink)
                .task { model.activate() }
                .onChange(of: scenePhase) { _, phase in
                    model.updateScenePhase(phase)
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let message = model.archiveRecoveryMessage {
                VStack(spacing: 20) {
                    Text("本地档案需要恢复").font(.title2.bold())
                    Text(message)
                    if let detail = model.banner { Text(detail).foregroundStyle(Theme.problem) }
                    Button("重新读取档案") { model.retryArchive() }.buttonStyle(.bordered)
                    Button("恢复有效副本") { model.recoverArchive() }.buttonStyle(.borderedProminent)
                }.padding(24).accessibilityIdentifier("archiveRecovery")
            } else { switch model.session.phase {
            case .chooseIdentity:
                IdentityView()
            case .connectCloud:
                CloudConnectView(mandatory: true)
            case .timeline:
                MainShell()
            } }
        }
        .background(Theme.background.ignoresSafeArea())
    }
}

struct IdentityView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pending: ParentIdentity?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                BrandWordmark()
                    .padding(.top, 24)
                    .padding(.bottom, 12)
                VStack(alignment: .leading, spacing: 12) {
                    BrandMark()
                    Text("这台手机是谁")
                        .font(.title.weight(.bold))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("每一条生活记录，都会留下你的署名。确认之后不能修改。")
                        .font(.body)
                        .foregroundStyle(Theme.inkSecondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.goldSoft, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                parentButton(.dad, identifier: "chooseDad")
                parentButton(.mom, identifier: "chooseMom")
                if let banner = model.banner {
                    Text(banner).foregroundStyle(model.bannerIsError ? Theme.problem : Theme.ink).font(.subheadline)
                }
            }
            .padding(24)
        }
        .alert("确认这台手机的署名", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("重新选", role: .cancel) { pending = nil }
            Button("确定") {
                if let pending { model.confirm(pending) }
                self.pending = nil
            }
            .accessibilityIdentifier("confirmParent")
        } message: {
            Text("这台手机记的内容会署名「\(pending?.label ?? "")」，之后不能修改。")
        }
    }

    private func parentButton(_ parent: ParentIdentity, identifier: String) -> some View {
        Button { pending = parent } label: {
            HStack(spacing: 16) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Theme.parentInk(parent))
                    .frame(width: 56, height: 56)
                    .background(Theme.parentBackground(parent), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text(parent.label)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.outline)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 88)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.separator, lineWidth: 1))
        }
        .accessibilityIdentifier(identifier)
    }
}
