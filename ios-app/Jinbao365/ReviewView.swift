import SwiftUI

struct ReviewView: View {
    @EnvironmentObject private var model: AppModel
    private var months: [TimelineMonth] { JinbaoCalendar.months(entries: model.session.timelineEntries().filter { $0.occurredAt > 0 }, timeZone: .current) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if months.isEmpty {
                        FeatureEmptyState(title: "成长值得慢慢回看", detail: "留下第一条记录，就会有属于这个月的回顾。", systemImage: "calendar")
                        GoldButton(title: "记录一个小日常") { model.beginDraft() }.padding(.horizontal, 16)
                    }
                    let unknown = model.session.timelineEntries().filter { $0.occurredAt <= 0 }.count
                    if unknown > 0 {
                        Button { model.tab = .timeline } label: {
                            FeatureRow(title: "\(unknown)条记录的日期未知", subtitle: "可在时光中查看", system: "calendar.badge.exclamationmark")
                        }.background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                    }
                    ForEach(months) { month in
                        NavigationLink { MonthReviewView(month: month) } label: { monthCard(month) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("reviewMonth-\(month.id)")
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("回顾")
        }
    }

    private func monthCard(_ month: TimelineMonth) -> some View {
        let entries = month.days.flatMap(\.moments)
        let counts = mediaCounts(entries)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(month.title).font(.title3.bold()).foregroundStyle(Theme.ink)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.inkSecondary)
            }
            HStack(spacing: 24) {
                stat("记录", value: entries.count)
                stat("照片", value: counts.photos)
                stat("视频", value: counts.videos)
            }
            Text("在\(month.days.count)个日子里，留下了\(entries.count)份成长记忆。")
                .font(.subheadline).foregroundStyle(Theme.inkSecondary)
            if let entry = entries.first {
                Text(entry.displayTitle).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(2)
            }
        }
        .modifier(BrandCard(padding: 20))
    }
    private func stat(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)").font(.title2.bold()).monospacedDigit().foregroundStyle(Theme.ink)
            Text(title).font(.caption).foregroundStyle(Theme.inkSecondary)
        }
    }
}

private func mediaCounts(_ entries: [TimelineEntry]) -> (photos: Int, videos: Int) {
    let videos = entries.flatMap(\.photos).filter { $0.kind == "video" }.count
    let total = entries.reduce(0) { $0 + $1.mediaCount }
    return (max(0, total - videos), videos)
}

private struct MonthReviewView: View {
    @EnvironmentObject private var model: AppModel
    let month: TimelineMonth
    @State private var selected: TimelineEntry?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(month.days) { day in
                    Text(day.title).font(.headline).foregroundStyle(Theme.ink).padding(.top, 8)
                    ForEach(day.moments) { entry in
                        Button { selected = entry } label: { MomentCard(entry: entry).modifier(BrandCard()) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("reviewRecord-\(entry.id)")
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(month.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { entry in MomentDetail(entry: entry) }
    }
}
