import SwiftUI
import UIKit

struct TimelineView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var searchVisible = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var searchQuery: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var entries: [TimelineEntry] {
        model.session.timelineEntries().filter {
            searchQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(searchQuery) || $0.note.localizedCaseInsensitiveContains(searchQuery)
        }
    }
    private var months: [TimelineMonth] {
        JinbaoCalendar.months(entries: entries.filter { $0.occurredAt > 0 }, timeZone: .current)
    }
    private var unknownDateEntries: [TimelineEntry] { entries.filter { $0.occurredAt <= 0 } }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    header
                    if searchVisible { searchField }
                    if !searchVisible { AnniversaryReminder() }
                    if let draft = model.session.draft {
                        Button { model.beginDraft() } label: {
                            HStack {
                                Image(systemName: "square.and.pencil")
                                Text(draft.title.isEmpty ? "继续未完成的记录" : "草稿：\(draft.title)").lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .font(.subheadline).foregroundStyle(Theme.ink).padding(14)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .accessibilityIdentifier("timelineResumeDraft")
                        .padding(.horizontal, 16).padding(.bottom, 8)
                    }
                    if entries.isEmpty {
                        emptyState
                    } else {
                        ForEach(months) { month in
                            Section {
                                MomentWaterfallLayout(
                                    columns: timelineColumnCount(for: geometry.size.width),
                                    columnSpacing: TimelineDensity.columnSpacing,
                                    rowSpacing: TimelineDensity.rowSpacing
                                ) {
                                    ForEach(monthMoments(month)) { moment in
                                        Button { model.selectedID = moment.id } label: {
                                            MomentCard(entry: moment)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("momentCard-\(moment.id)")
                                    }
                                }
                                .padding(.horizontal, TimelineDensity.horizontalMargin)
                                .padding(.bottom, TimelineDensity.horizontalMargin)
                            } header: {
                                monthHeader(month)
                            }
                        }
                        if !unknownDateEntries.isEmpty {
                            unknownDateHeader
                            MomentWaterfallLayout(
                                columns: timelineColumnCount(for: geometry.size.width),
                                columnSpacing: TimelineDensity.columnSpacing,
                                rowSpacing: TimelineDensity.rowSpacing
                            ) {
                                ForEach(unknownDateEntries) { entry in
                                    Button { model.selectedID = entry.id } label: {
                                        MomentCard(entry: entry)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("momentCard-\(entry.id)")
                                }
                            }
                            .padding(.horizontal, TimelineDensity.horizontalMargin)
                            .padding(.bottom, TimelineDensity.horizontalMargin)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .clipped()
        }
        .background(Theme.background)
        .sheet(item: selectedEntry) { entry in
            MomentDetail(entry: entry)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    BrandMark()
                    Text("DaysWith")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                SwiftUI.TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(Theme.ageLabel(on: context.date))
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                        .accessibilityIdentifier("jinbaoCurrentAge")
                }
            }
            Spacer(minLength: 0)
            Button {
                searchVisible.toggle()
                if !searchVisible { search = "" }
                searchFocused = searchVisible
            } label: {
                Image(systemName: searchVisible ? "xmark" : "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel(searchVisible ? "收起搜索" : "搜索记录")
            .accessibilityIdentifier("timelineSearchToggle")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.inkSecondary)
            TextField("搜索标题和文字", text: $search)
                .font(.body)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { searchFocused = false }
                .accessibilityIdentifier("timelineSearchField")
            if !search.isEmpty {
                Button {
                    search = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(minWidth: 32, minHeight: 32)
                }
                .accessibilityLabel("清除搜索")
                .accessibilityIdentifier("timelineSearchClear")
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.outline, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            BrandMark(size: 88)
                .padding(.bottom, 12)
            Text(searchQuery.isEmpty ? TimelineEmptyCopy.title : "没有找到相关记录")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text(searchQuery.isEmpty ? TimelineEmptyCopy.detail : "换个词再找找吧")
                .font(.body)
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
            if searchQuery.isEmpty {
                GoldButton(title: "记录一个小日常") { model.beginDraft() }.padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(searchQuery.isEmpty ? "timelineEmpty" : "timelineSearchEmpty")
    }

    private func timelineColumnCount(for width: CGFloat) -> Int {
        width < 360 || dynamicTypeSize >= .xxxLarge ? 1 : 2
    }

    private func monthMoments(_ month: TimelineMonth) -> [TimelineEntry] {
        month.days.flatMap(\.moments)
    }

    private func monthHeader(_ month: TimelineMonth) -> some View {
        let count = monthMoments(month).count
        return HStack(spacing: 12) {
            Text(month.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(month.title)
                .accessibilityIdentifier("month-\(month.year)-\(month.month)")
            Text("\(count)条")
                .font(.caption)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize()
                .accessibilityLabel("\(count)条")
                .accessibilityIdentifier("monthCount-\(month.year)-\(month.month)")
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, TimelineDensity.horizontalMargin)
        .background(Theme.background)
        .accessibilityElement(children: .contain)
    }

    private var unknownDateHeader: some View {
        HStack(spacing: 12) {
            Text("日期未知")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("timelineUnknownDate")
            Text("\(unknownDateEntries.count)条")
                .font(.caption)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, TimelineDensity.horizontalMargin)
        .background(Theme.background)
        .accessibilityElement(children: .contain)
    }

    private var selectedEntry: Binding<TimelineEntry?> {
        Binding(
            get: { model.session.timelineEntries().first { $0.id == model.selectedID } },
            set: { model.selectedID = $0?.id }
        )
    }
}

private enum TimelineDensity {
    static let horizontalMargin: CGFloat = 12
    static let columnSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 8
}

/// Shortest-column masonry. Each card is measured at its column width, then placed in the current shortest lane.
private struct MomentWaterfallLayout: Layout {
    let columns: Int
    let columnSpacing: CGFloat
    let rowSpacing: CGFloat

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint], columnWidth: CGFloat) {
        let count = max(1, columns)
        let columnWidth = max(0, (width - CGFloat(count - 1) * columnSpacing) / CGFloat(count))
        var heights = Array(repeating: CGFloat.zero, count: count)
        var origins: [CGPoint] = []
        for subview in subviews {
            let lane = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            origins.append(CGPoint(x: CGFloat(lane) * (columnWidth + columnSpacing), y: heights[lane]))
            heights[lane] += size.height + rowSpacing
        }
        let tallest = heights.max() ?? 0
        let height = subviews.isEmpty ? 0 : max(0, tallest - rowSpacing)
        return (CGSize(width: width, height: height), origins, columnWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? 0, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let origin = result.origins[index]
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: result.columnWidth, height: nil))
        }
    }
}

struct MomentCard: View {
    @EnvironmentObject private var model: AppModel
    let entry: TimelineEntry

    private var hasMedia: Bool { entry.mediaCount > 0 || !entry.photos.isEmpty || entry.previewPath != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasMedia { media }
            VStack(alignment: .leading, spacing: 8) {
                Text(cardDate)
                    .font(.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.displayTitle)
                    .font(.subheadline.weight(hasMedia ? .medium : .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(hasMedia ? 2 : 3)
                if !hasMedia, !entry.note.isEmpty, entry.note != entry.displayTitle {
                    Text(entry.note)
                        .font(.subheadline)
                        .foregroundStyle(Theme.noteInk)
                        .lineLimit(6)
                }
                ParentBadge(parent: entry.parent)
                if entry.readOnly || entry.provenanceLabel != nil {
                    Text([entry.readOnly ? "只读" : nil, entry.provenanceLabel].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(hasMedia ? 0 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hasMedia ? Color.clear : Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var media: some View {
        Color.clear
            .aspectRatio(mediaAspectRatio, contentMode: .fit)
            .overlay {
                Group {
                    if let photo = entry.photos.first {
                        PhotoContent(photo: photo, allowsRetry: false)
                    } else if let image = localImage {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        Text(entry.readOnly ? "照片在云端" : "照片已在这台手机")
                            .font(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                            .padding(12)
                    }
                }
            }
            .background(Theme.photoPlaceholder)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if stackCount > 1 {
                    Text("\(stackCount)张")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.45), in: Capsule())
                        .padding(8)
                        .accessibilityLabel("\(stackCount)张")
                }
            }
    }

    private var localImage: UIImage? {
        let path = entry.photos.first.flatMap { model.previewPath(for: $0) } ?? entry.previewPath
        guard let path, let url = model.fileURL(path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Width ÷ height of the local cover. Unknown size stays square until the file reports its real ratio.
    private var mediaAspectRatio: CGFloat {
        guard let size = localImage?.size, size.width > 0, size.height > 0 else { return 1 }
        return size.width / size.height
    }

    private var stackCount: Int { max(entry.mediaCount, entry.photos.count) }

    private var cardDate: String {
        guard entry.occurredAt > 0 else { return "日期未知" }
        let parts = JinbaoCalendar.parts(millis: entry.occurredAt, timeZone: .current)
        let date = Date(timeIntervalSince1970: TimeInterval(entry.occurredAt) / 1000)
        let clock = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        return "\(parts.month)月\(parts.day)日 · \(clock)"
    }
}

struct MomentDetail: View {
    @EnvironmentObject private var model: AppModel
    let entry: TimelineEntry
    @Environment(\.dismiss) private var dismiss
    @State private var previewSelection: PhotoSelection?
    @State private var trashConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(entry.photos) { photo in
                        VStack(spacing: 0) {
                            PhotoContent(photo: photo)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 180, maxHeight: 360)
                                .background(Theme.photoPlaceholder)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            Button(photo.kind == "video" ? "播放视频" : photo.kind == "livePhoto" || photo.kind == "live_photo" ? "查看动态照片" : "查看第\((entry.photos.firstIndex { $0.id == photo.id } ?? 0) + 1)张大图") {
                                previewSelection = PhotoSelection(id: photo.id)
                            }
                            .font(.footnote.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .accessibilityIdentifier("detailPreview-\(photo.id)")
                        }
                    }
                    if entry.photos.isEmpty, let path = entry.previewPath, let url = model.fileURL(path), let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ParentBadge(parent: entry.parent)
                        Text(entry.displayTitle)
                            .font(.title.weight(.bold))
                            .foregroundStyle(Theme.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text(detailDate)
                            .font(.caption)
                            .foregroundStyle(Theme.inkSecondary)
                        if entry.mediaCount > 0 {
                            Label("\(entry.mediaCount)个媒体文件", systemImage: "photo.on.rectangle")
                                .font(.caption)
                                .foregroundStyle(Theme.inkSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !entry.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entry.note != entry.displayTitle {
                        Text(entry.note)
                            .font(.body)
                            .foregroundStyle(Theme.ink)
                            .modifier(BrandCard(padding: 24))
                    }
                    if entry.mediaCount > entry.photos.count {
                        Text("部分云端媒体没有可用预览，请重新连接后重试。")
                            .font(.subheadline)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    if entry.readOnly {
                        Text("这是另一台设备或另一位家长留下的，这里只读。")
                            .font(.subheadline)
                            .foregroundStyle(Theme.inkSecondary)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.goldSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.background)
            .navigationTitle("小日常")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if !entry.readOnly {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("编辑记录", systemImage: "pencil") {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.beginEditing(id: entry.id) }
                            }.accessibilityIdentifier("editMoment")
                            Button("移到回收站", systemImage: "trash", role: .destructive) { trashConfirmation = true }
                                .accessibilityIdentifier("trashMoment")
                        } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("记录操作")
                        .accessibilityIdentifier("momentActions")
                    }
                }
            }
            .confirmationDialog("移到回收站？", isPresented: $trashConfirmation, titleVisibility: .visible) {
                Button("移到回收站", role: .destructive) { model.trashMoment(id: entry.id); dismiss() }
                Button("取消", role: .cancel) {}
            } message: { Text("可以在我的－设置－回收站恢复，云端原件不会被删除。") }
            .fullScreenCover(item: $previewSelection) { selection in
                PhotoGallery(photos: entry.photos, initialID: selection.id)
            }
        }
    }

    private var detailDate: String {
        guard entry.occurredAt > 0 else { return "日期与时间未知" }
        let date = Date(timeIntervalSince1970: TimeInterval(entry.occurredAt) / 1000)
        let parts = JinbaoCalendar.parts(millis: entry.occurredAt, timeZone: .current)
        return "\(parts.year)年\(JinbaoCalendar.dayTitle(parts)) · \(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))"
    }

}

struct PhotoSelection: Identifiable { let id: String }

struct PhotoContent: View {
    @EnvironmentObject private var model: AppModel
    let photo: TimelinePhoto
    var fullSize = false
    var allowsRetry = true

    var body: some View {
        Group {
            if fullSize {
                MediaPlaybackView(photo: photo)
            } else if let path = model.previewPath(for: photo),
               let url = model.fileURL(path), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityLabel("照片")
                    .accessibilityIdentifier("photoImage-\(photo.id)")
            } else if let reference = photo.remote {
                VStack(spacing: 12) {
                    if case .failed(let message) = model.previewLoads[reference.id] {
                        Text(message).font(.subheadline).multilineTextAlignment(.center)
                        if allowsRetry {
                            Button("重试读取照片") { model.loadPreview(reference, retry: true) }
                                .accessibilityIdentifier("retryPreview-\(photo.id)")
                        } else {
                            Text("打开记录后可重试").font(.footnote)
                        }
                    } else {
                        ProgressView("正在读取照片")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 100)
                .onAppear { model.loadPreview(reference) }
            } else {
                Text("这张照片暂时无法读取")
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
    }
}

struct PhotoGallery: View {
    let photos: [TimelinePhoto]
    let initialID: String
    @State private var selectedID = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedID) {
                ForEach(photos) { photo in
                    PhotoContent(photo: photo, fullSize: true)
                        .tag(photo.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .background(Color.black)
            .navigationTitle("\((photos.firstIndex { $0.id == selectedID } ?? 0) + 1) / \(photos.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭预览") { dismiss() }.accessibilityIdentifier("closePhotoPreview")
                }
            }
            .onAppear { selectedID = initialID }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
    }
}
