import SwiftUI
import UIKit
import AVFoundation

struct MainShell: View {
    @EnvironmentObject private var model: AppModel
    @State private var cameraMessage = false
    @State private var keyboardVisible = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if let banner = model.banner {
                    Text(banner)
                        .font(.subheadline)
                        .foregroundStyle(model.bannerIsError ? Theme.problem : Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(model.bannerIsError ? Color(hex: 0xF8E8E8) : Theme.goldSoft)
                }
                Group {
                    switch model.tab {
                    case .timeline: TimelineView()
                    case .anniversaries: AnniversariesView()
                    case .review: ReviewView()
                    case .my: MyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.addMenuOpen { addMenu }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { if !keyboardVisible { capsuleBar } }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .sheet(isPresented: $model.composerOpen) { ComposerView() }
        .sheet(isPresented: $model.cameraOpen) { CameraPicker { data, name, provenance in
            model.cameraOpen = false
            DispatchQueue.main.async {
                model.addImported(data: data, filename: name, provenance: provenance)
            }
        } }
        .alert("这台设备没有相机", isPresented: $cameraMessage) {
            Button("好", role: .cancel) {}
        } message: {
            Text("模拟器通常不能拍照。可以选照片，或先写一段话。")
        }
        .onAppear { model.refreshRemote() }
    }

    private var capsuleBar: some View {
        HStack(spacing: 0) {
            barButton("时光", system: "photo.on.rectangle.angled", selected: model.tab == .timeline, identifier: "tabTimeline") { select(.timeline) }
            barButton("纪念", system: "heart", selected: model.tab == .anniversaries, identifier: "tabAnniversaries") { select(.anniversaries) }
            Color.clear.frame(width: 60, height: 48).accessibilityHidden(true)
            barButton("回顾", system: "calendar", selected: model.tab == .review, identifier: "tabReview") { select(.review) }
            barButton("我的", system: "person.crop.circle", selected: model.tab == .my, identifier: "tabMy") { select(.my) }
        }
        .padding(6)
        .frame(minHeight: 64)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().stroke(Color.black.opacity(15.0 / 255), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.10), radius: 12, y: 4)
        .overlay {
            Button {
                model.addMenuOpen.toggle()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 56, height: 56)
                    .background(Theme.gold, in: Circle())
                    .shadow(color: Color.black.opacity(0.10), radius: 8, y: 3)
            }
            .accessibilityIdentifier("addMoment")
            .accessibilityLabel("添加记录")
            .offset(y: -8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private func select(_ tab: ShellTab) {
        model.tab = tab
        model.addMenuOpen = false
    }

    private func barButton(_ title: String, system: String, selected: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: system)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(selected ? Theme.ink : Theme.outline)
                if dynamicTypeSize < .accessibility1 {
                    Text(title).font(.caption2.weight(.medium))
                        .foregroundStyle(selected ? Theme.ink : Theme.inkSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .background(selected ? Theme.goldSoft : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var addMenu: some View {
        VStack(spacing: 0) {
            menuRow("拍照", system: "camera", identifier: "addCameraMenuAction") { openCamera() }
            menuRow("选照片或视频", system: "photo.on.rectangle", identifier: "addPhotosMenuAction") {
                model.addMenuOpen = false
                model.beginDraft()
                model.openSystemPicker = true
            }
            menuRow("写文字", system: "square.and.pencil", identifier: "addNoteMenuAction") {
                model.beginDraft()
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.12), radius: 16, y: 6)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(Color.black.opacity(0.04).ignoresSafeArea().onTapGesture { model.addMenuOpen = false })
    }

    private func menuRow(_ title: String, system: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: system).frame(width: 24)
                Text(title).font(.body)
                Spacer()
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .accessibilityIdentifier(identifier)
    }

    private func openCamera() {
        model.addMenuOpen = false
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraMessage = true
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: model.cameraOpen = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { allowed in
                DispatchQueue.main.async {
                    if allowed { model.cameraOpen = true }
                    else { model.show(ContractError(path: "camera", message: "相机权限未开放，可在系统设置中允许后再拍照。你仍可选图或写文字。")) }
                }
            }
        default:
            model.show(ContractError(path: "camera", message: "相机权限未开放，可在系统设置中允许后再拍照。你仍可选图或写文字。"))
        }
    }
}
