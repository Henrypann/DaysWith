import SwiftUI

struct CloudConnectView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var mandatory: Bool
    var editingConfiguration = false
    @FocusState private var focusedField: String?
    @State private var sensitiveFocusedField: String?
    @State private var revealID = false
    @State private var disconnectConfirmation = false

    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    BrandMark()
                    Text(mandatory ? "连接云存储" : "云备份")
                        .font(.title.weight(.bold))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                Text("让每一份成长记录安心留下")
                    .font(.body)
                    .foregroundStyle(Theme.inkSecondary)
                if case .placeholder = model.session.link {
                    Label("占位连接 · 仅保存在这台手机", systemImage: "iphone")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.goldSoft, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("storagePlaceholder")
                }
                if let parent = model.session.identity {
                    HStack(spacing: 8) {
                        Text("这台手机")
                            .font(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                        ParentBadge(parent: parent)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("phoneParent")
                }
                if case .verified = model.session.link, !mandatory, !editingConfiguration {
                    connectedActions.modifier(BrandCard())
                } else {
                    Text("填写具有所需目录权限的腾讯云密钥。密钥只保存在这台手机的钥匙串里。")
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                    form.modifier(BrandCard())
                }
                if let banner = model.banner {
                    Text(banner)
                        .font(.subheadline)
                        .foregroundStyle(model.bannerIsError ? Theme.problem : Theme.ink)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(model.bannerIsError ? Color(hex: 0xFCEAEA) : Theme.goldSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityIdentifier("connectionMessage")
                        .id("connectionStatus")
                }
                pathCard
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .confirmationDialog("断开云存储？", isPresented: $disconnectConfirmation, titleVisibility: .visible) {
            Button("断开连接", role: .destructive) { model.disconnect() }
            Button("取消", role: .cancel) {}
        } message: { Text("这台手机上的记录仍然保留。") }
        .onChange(of: model.banner) { _, message in
            if message != nil { scroll.scrollTo("connectionStatus", anchor: .center) }
        }
        }
        .opacity(model.sensitiveFormObscured ? 0 : 1)
        .accessibilityHidden(model.sensitiveFormObscured)
        .overlay {
            if model.sensitiveFormObscured {
                Theme.background.ignoresSafeArea()
                    .overlay { Label("Connection details hidden", systemImage: "lock.fill").foregroundStyle(Theme.inkSecondary) }
                    .accessibilityIdentifier("sensitiveFormCover")
            }
        }
        .onChange(of: model.sensitiveFormObscured) { _, hidden in
            if hidden { revealID = false; focusedField = nil; sensitiveFocusedField = nil }
        }
        .onChange(of: sensitiveFocusedField) { _, field in
            if field != nil { focusedField = nil }
        }
        .onChange(of: focusedField) { _, field in
            if field != nil { sensitiveFocusedField = nil }
        }
        .navigationBarBackButtonHidden(!mandatory && showsCredentialForm)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if focusedField != nil {
                    Spacer()
                    Button("Done") { focusedField = nil }
                        .accessibilityIdentifier("dismissCloudKeyboard")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if !mandatory && showsCredentialForm {
                    Button("Back", systemImage: "chevron.left") {
                        model.cancelCloudConfiguration()
                        dismiss()
                    }
                    .accessibilityIdentifier("leaveCloudConfiguration")
                }
            }
        }
        .onChange(of: model.tab) { _, _ in model.cancelCloudConfiguration() }
    }

    private var showsCredentialForm: Bool {
        if editingConfiguration { return true }
        if case .verified = model.session.link { return false }
        return true
    }

    private var pathCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("存储位置")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.inkSecondary)
            Text(writePath)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
            Text("读取爸爸 life/v1/dad/ 和妈妈 life/v1/mom/，含各设备目录。旧根目录只读，云端文件不会删除。")
                .font(.footnote)
                .foregroundStyle(Theme.inkSecondary)
        }
        .modifier(BrandCard())
    }

    private var writePath: String {
        (try? model.session.writerPrefix()) ?? "确认署名后才会确定文件夹"
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("存储桶", text: $model.bucket, secure: false, identifier: "storageBucket")
            field("地域", text: $model.region, secure: false, identifier: "storageRegion")
            field("密钥编号", text: $model.secretID, secure: !revealID, identifier: "secretID")
            Button(revealID ? "隐藏密钥编号" : "显示密钥编号") { revealID.toggle() }
                .font(.footnote)
                .foregroundStyle(Theme.ink)
            field("密钥", text: $model.secretKey, secure: true, identifier: "secretKey")
            field("临时令牌（可选）", text: $model.sessionToken, secure: true, identifier: "sessionToken")
            Text("使用临时密钥时填写临时令牌；长期密钥可留空。令牌过期后需更新。编号和密钥各为 1 至 1024 位。")
                .font(.footnote)
                .foregroundStyle(Theme.inkSecondary)
            GoldButton(title: model.busy ? "正在验证…" : "验证并继续", enabled: !model.busy, action: model.verify)
                .accessibilityIdentifier("verifyContinue")
            Button("Cancel configuration") {
                model.cancelCloudConfiguration()
                if !mandatory { dismiss() }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("cancelCloudConfiguration")
            #if DEBUG
            Button("占位连接，先看时间线") { model.connectPlaceholder() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("placeholderConnect")
            Text("占位只在调试版出现。它不保存密钥，也不上传。")
                .font(.footnote)
                .foregroundStyle(Theme.inkSecondary)
            #endif
        }
    }

    private var connectedActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.backupStatusTitle)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityIdentifier("storageVerified")
            Text("存储桶：\(model.bucket)\n地域：\(model.region)")
                .font(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
            Text(model.backupStatusDetail)
                .font(.subheadline).foregroundStyle(Theme.inkSecondary)
            if let progress = model.backupProgress {
                ProgressView(value: progress).accessibilityIdentifier("backupProgress")
            }
            if model.backupRunning {
                Button("暂停备份") { model.pauseBackup() }
                    .frame(minHeight: 44).accessibilityIdentifier("pauseBackup")
            } else {
                GoldButton(title: "立即备份 / 重试", enabled: !model.busy, action: model.backupNow)
                    .accessibilityIdentifier("backupNow")
                Button("继续未完成的备份") { model.resumeBackup() }
                    .frame(minHeight: 44).accessibilityIdentifier("resumeBackup")
            }
            Button("重新读取家庭时光") { model.refreshRemote() }
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            Button("断开云存储") { disconnectConfirmation = true }
                .foregroundStyle(Theme.problem)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("disconnectStorage")
        }
    }

    private func field(_ title: String, text: Binding<String>, secure: Bool, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.inkSecondary)
            Group {
                if ["secretID", "secretKey", "sessionToken"].contains(identifier) {
                    SensitiveCredentialField(title: title, text: text, identifier: identifier,
                                             secure: secure, focusedField: $sensitiveFocusedField)
                } else {
                    TextField(title, text: text)
                        .focused($focusedField, equals: identifier)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .accessibilityIdentifier(identifier)
                }
            }
            .font(.body)
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.separator, lineWidth: 1))
        }
    }
}
