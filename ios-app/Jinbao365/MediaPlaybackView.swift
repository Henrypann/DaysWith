import SwiftUI
import AVKit
import PhotosUI
import Photos
import ImageIO

/// Full-size viewer shared by drafts and saved records. Thumbnails remain separate.
struct MediaPlaybackView: View {
    let photo: TimelinePhoto
    @EnvironmentObject private var model: AppModel
    @State private var resources: [String: URL] = [:]
    @State private var loading = false
    @State private var failure: String?
    @State private var cellularConsent = false
    @State private var playToken = 0
    @State private var liveReady = false
    @State private var livePlaying = false
    @State private var playbackGeneration = 0

    var body: some View {
        ZStack {
            Color.black
            if photo.kind == "video", let url = resources["video"] {
                MoviePlayback(url: url)
            } else if photo.kind == "livePhoto", let still = resources["livePhotoImage"], let movie = resources["livePhotoVideo"] {
                LivePhotoPlayback(resourceURLs: [still, movie], playToken: playToken, onReady: { liveReady = true }, onPlayback: { livePlaying = $0 }) { error in
                    failure = error
                }
                .id(playbackGeneration)
                .accessibilityIdentifier("livePhotoPlayback")
                VStack {
                    Spacer()
                    if !liveReady { ProgressView("正在准备实况…").tint(.white).padding() }
                    Text(livePlaying ? "播放中" : "实况照片").font(.caption).accessibilityIdentifier("livePhotoPlaybackStatus")
                    Button { playToken += 1 } label: {
                        Label("播放实况", systemImage: "livephoto.play")
                            .font(.body.weight(.semibold)).padding(14)
                            .background(.black.opacity(0.7), in: Capsule())
                    }.disabled(!liveReady).accessibilityIdentifier("playLivePhoto").padding(.bottom, 38)
                }
            } else if let url = MediaPlaybackResourceLayout.imageURL(kind: photo.kind, resources: resources) {
                ZoomablePhoto(url: url).accessibilityIdentifier("fullSizePhoto")
                if photo.kind == "motionPhoto" {
                    VStack { Text("Android 动态照片 · 静态查看").font(.caption).padding(10).background(.black.opacity(0.7), in: Capsule()); Spacer() }
                        .padding(16).accessibilityIdentifier("motionPhotoStaticNotice")
                }
            } else if let path = photo.localPath, let url = model.fileURL(path) {
                ZoomablePhoto(url: url).opacity(loading ? 0.55 : 1)
            }
            if loading {
                ProgressView("正在读取原件…").tint(.white).foregroundStyle(.white)
                    .padding(16).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }
            if let failure {
                VStack(spacing: 12) {
                    Text(failure).multilineTextAlignment(.center).font(.callout)
                        .accessibilityIdentifier("mediaPlaybackError")
                    Button(cellularConsent ? "使用蜂窝网络下载" : "重试") {
                        Task { await load(allowCellular: cellularConsent) }
                    }.buttonStyle(.borderedProminent).tint(Theme.gold).foregroundStyle(.black)
                        .accessibilityIdentifier(cellularConsent ? "allowCellularOriginal" : "retryOriginal")
                }
                .padding(20).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                .padding(24)
            }
        }
        .foregroundStyle(.white)
        .task(id: photo.id) { await load(allowCellular: false) }
    }

    @MainActor private func load(allowCellular: Bool) async {
        guard !loading else { return }
        loading = true
        liveReady = false
        livePlaying = false
        playbackGeneration += 1
        failure = nil
        cellularConsent = false
        do {
            var local: [String: URL] = [:]
            for resource in photo.localResources {
                if let url = model.fileURL(resource.relativePath), FileManager.default.fileExists(atPath: url.path) {
                    local[resource.role] = url
                }
            }
            // Compatibility with records saved before generalized media resources existed.
            if local.isEmpty, let path = photo.fullSizePath ?? photo.localPath, let url = model.fileURL(path) { local["photo"] = url }
            if !photo.remoteResources.isEmpty {
                resources = try await model.mediaResourceURLs(for: photo, allowCellularOnce: allowCellular)
            } else {
                resources = local
            }
            let required = MediaPlaybackResourceLayout.requiredRoles(kind: photo.kind)
            guard required.allSatisfy({ resources[$0] != nil }) else {
                throw ContractError(path: "media", message: "没有找到完整原件。请检查网络或重新导入媒体。")
            }
        } catch MediaAccessError.cellularPermissionRequired {
            failure = "原件需要通过蜂窝网络下载。也可以连接 Wi-Fi 后重试。"
            cellularConsent = true
        } catch {
            failure = (error as? ContractError)?.message ?? error.localizedDescription
        }
        loading = false
    }
}

private struct MoviePlayback: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var elapsed = "0:00"
    @State private var statusObserver: NSKeyValueObservation?
    @State private var itemObserver: NSKeyValueObservation?
    @State private var playbackError: String?
    @State private var playerGeneration = UUID()
    @State private var timeObserver: Any?
    var body: some View {
        ZStack(alignment: .topLeading) {
            VideoPlayer(player: player).accessibilityIdentifier("videoPlayback")
            HStack(spacing: 12) {
                Button {
                    if playing { player?.pause() } else {
                        if let player, let duration = player.currentItem?.duration.seconds,
                           duration.isFinite, player.currentTime().seconds >= duration - 0.1 { player.seek(to: .zero) }
                        player?.play()
                    }
                } label: {
                    Label(playing ? "暂停" : "播放", systemImage: playing ? "pause.fill" : "play.fill")
                        .padding(12).background(.black.opacity(0.7), in: Capsule())
                }
                .accessibilityIdentifier("videoTogglePlayback")
                .accessibilityValue(playing ? "播放中" : "已暂停")
                Text(elapsed).monospacedDigit().accessibilityIdentifier("videoPlaybackTime")
            }.padding(16)
            if let playbackError {
                VStack(spacing: 12) {
                    Text(playbackError).multilineTextAlignment(.center).accessibilityIdentifier("videoPlaybackError")
                    Button("重新加载视频") { releasePlayer(); installPlayer() }
                        .buttonStyle(.bordered).accessibilityIdentifier("retryVideoPlayback")
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.7))
            }
        }
        .onAppear { installPlayer() }
        .onDisappear { releasePlayer() }
        .onChange(of: url) { _, _ in releasePlayer(); installPlayer() }
    }
    private func installPlayer() {
        guard player == nil else { return }
        playbackError = nil
        let generation = UUID()
        playerGeneration = generation
        let created: AVPlayer
        do {
            created = try MoviePlaybackPlayerFactory.makePlayer(url: url)
        } catch {
            playbackError = "视频音频暂时无法启用，请重试。"
            return
        }
        player = created
        itemObserver = created.currentItem?.observe(\.status, options: [.initial, .new]) { item, _ in
            if item.status == .failed { DispatchQueue.main.async {
                guard playerGeneration == generation else { return }
                playbackError = "视频暂时无法播放，请检查文件是否完整，或重新导入受支持的视频。"
            } }
        }
        statusObserver = created.observe(\.timeControlStatus, options: [.initial, .new]) { observed, _ in
            DispatchQueue.main.async {
                guard playerGeneration == generation else { return }
                playing = observed.timeControlStatus == .playing
            }
        }
        timeObserver = created.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
            guard playerGeneration == generation else { return }
            let seconds = time.seconds.isFinite ? max(0, Int(time.seconds)) : 0
            elapsed = "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
        }
    }
    private func releasePlayer() {
        playerGeneration = UUID()
        player?.pause()
        statusObserver?.invalidate(); statusObserver = nil
        itemObserver?.invalidate(); itemObserver = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil; player = nil; playing = false
    }
}

/// Both VideoPlayer's native controls and the custom controls use this prepared player.
enum MoviePlaybackPlayerFactory {
    static func makePlayer(url: URL) throws -> AVPlayer {
        // Playback respects media volume and the current route, including in Silent mode.
        // AVPlayer activates the session when playback starts; opening a viewer alone need not interrupt other audio.
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        return AVPlayer(url: url)
    }
}

private struct LivePhotoPlayback: UIViewRepresentable {
    let resourceURLs: [URL]
    let playToken: Int
    let onReady: () -> Void
    let onPlayback: (Bool) -> Void
    let onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady, onPlayback: onPlayback, onError: onError) }
    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.delegate = context.coordinator
        view.backgroundColor = .black
        context.coordinator.load(urls: resourceURLs, into: view)
        return view
    }
    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if context.coordinator.urls != resourceURLs { context.coordinator.load(urls: resourceURLs, into: view) }
        if context.coordinator.playToken != playToken {
            context.coordinator.playToken = playToken
            view.startPlayback(with: .full)
        }
    }
    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        view.stopPlayback()
        coordinator.cancel()
    }
    final class Coordinator: NSObject, PHLivePhotoViewDelegate {
        var urls: [URL] = []
        var playToken = 0
        var requestID: PHLivePhotoRequestID?
        private var generation = 0
        let onReady: () -> Void
        let onPlayback: (Bool) -> Void
        let onError: (String) -> Void
        init(onReady: @escaping () -> Void, onPlayback: @escaping (Bool) -> Void, onError: @escaping (String) -> Void) { self.onReady = onReady; self.onPlayback = onPlayback; self.onError = onError }
        func livePhotoView(_ livePhotoView: PHLivePhotoView, willBeginPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) { onPlayback(true) }
        func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) { onPlayback(false) }
        func cancel() { generation += 1; if let requestID { PHLivePhoto.cancelRequest(withRequestID: requestID) }; requestID = nil }
        func load(urls: [URL], into view: PHLivePhotoView) {
            cancel()
            self.urls = urls
            let loadGeneration = generation
            requestID = PHLivePhoto.request(withResourceFileURLs: urls, placeholderImage: nil, targetSize: CGSize(width: 2048, height: 2048), contentMode: .aspectFit) { [weak self, weak view] livePhoto, info in
                DispatchQueue.main.async {
                    guard let self, self.generation == loadGeneration else { return }
                    if info[PHLivePhotoInfoIsDegradedKey] as? Bool == true { return }
                    if let livePhoto { view?.livePhoto = livePhoto; self.onReady() }
                    else if let error = info[PHLivePhotoInfoErrorKey] as? Error { self.onError("实况照片无法播放：\(error.localizedDescription)") }
                    else if info[PHLivePhotoInfoCancelledKey] as? Bool == true { self.onError("实况照片加载已取消，请重试。") }
                }
            }
        }
    }
}

/// UIScrollView provides pinch, double-tap and pan without interfering with page swipes at 1x.
private struct ZoomablePhoto: UIViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .black
        scroll.bouncesZoom = true
        let image = UIImageView()
        image.contentMode = .scaleAspectFit
        image.isUserInteractionEnabled = false
        image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(image)
        context.coordinator.imageView = image
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(tap)
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.url != url {
            coordinator.url = url
            scroll.setZoomScale(1, animated: false)
            // Bound decoded dimensions while leaving original bytes intact on disk.
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) {
                coordinator.imageView?.image = UIImage(cgImage: thumbnail)
            }
        }
        if scroll.zoomScale == 1 { coordinator.imageView?.frame = scroll.bounds }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        var url: URL?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 { scroll.setZoomScale(1, animated: true) }
            else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}

/// Android Motion Photos keep a JPEG-compatible still plus embedded video in one original.
/// The iOS compatibility reader displays that still and preserves the complete resource.
enum MediaPlaybackResourceLayout {
    static func requiredRoles(kind: String) -> [String] {
        switch kind {
        case "video": return ["video"]
        case "livePhoto": return ["livePhotoImage", "livePhotoVideo"]
        case "motionPhoto": return ["motionPhoto"]
        default: return ["photo"]
        }
    }
    static func imageURL(kind: String, resources: [String: URL]) -> URL? {
        let role = kind == "motionPhoto" ? "motionPhoto" : kind == "livePhoto" ? "livePhotoImage" : "photo"
        return resources[role] ?? resources["preview"]
    }
}
