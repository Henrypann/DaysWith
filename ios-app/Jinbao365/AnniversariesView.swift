import SwiftUI

struct AnniversariesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: AnniversaryEntry?
    @State private var adding = false

    private var entries: [AnniversaryEntry] {
        model.session.anniversaryEntries().sorted {
            let lhs = AnniversaryPresentation($0), rhs = AnniversaryPresentation($1)
            return lhs.daysUntil == rhs.daysUntil ? $0.title < $1.title : lhs.daysUntil < rhs.daysUntil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if entries.isEmpty {
                        FeatureEmptyState(title: "把重要的日子记下来", detail: "生日、纪念日，还有你们的小约定。", systemImage: "heart")
                    }
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        Button { editing = entry } label: {
                            AnniversaryCard(entry: entry, featured: index == 0)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("anniversary-\(entry.id)")
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("纪念")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("添加纪念日")
                        .accessibilityIdentifier("addAnniversary")
                }
            }
            .sheet(isPresented: $adding) { AnniversaryEditor(entry: nil) }
            .sheet(item: $editing) { entry in AnniversaryEditor(entry: entry) }
        }
    }
}

struct AnniversaryCard: View {
    let entry: AnniversaryEntry
    var featured = false
    private var presentation: AnniversaryPresentation { AnniversaryPresentation(entry) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { facts; Spacer(minLength: 8); countdown }
            VStack(alignment: .leading, spacing: 12) { facts; countdown }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(featured ? Theme.goldSoft : Theme.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.title).font(.headline).foregroundStyle(Theme.ink)
            Text(presentation.subtitle).font(.subheadline).foregroundStyle(Theme.inkSecondary)
            HStack(spacing: 8) {
                ParentBadge(parent: entry.owner)
                if entry.readOnly { Text("只读").font(.caption).foregroundStyle(Theme.inkSecondary) }
                if presentation.daysUntil <= 7 { Text("就在这周").font(.caption.weight(.medium)).foregroundStyle(Theme.ink) }
            }
        }
    }
    private var countdown: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if presentation.daysUntil == 0 {
                Text("就是今天").font(.title2.bold())
            } else {
                Text("还有").font(.caption)
                Text("\(presentation.daysUntil)").font(.system(size: featured ? 42 : 34, weight: .bold)).monospacedDigit()
                Text("天").font(.subheadline)
            }
        }
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}

/// UI formatting only. Stored dates and IDs are managed by the shared anniversary repository.
struct AnniversaryPresentation {
    let daysUntil: Int
    let subtitle: String
    init(_ entry: AnniversaryEntry, now: Date = .now) {
        let raw = entry.date.split(separator: "-", omittingEmptySubsequences: true).compactMap { Int($0) }
        let known = raw.count == 3 && raw[0] != 4
        let month = raw.count >= 2 ? raw[raw.count - 2] : 1
        let day = raw.last ?? 1
        let upcoming = AnniversaryCalendar.upcoming([entry], now: Int64(now.timeIntervalSince1970 * 1000), timeZone: .current).first
        daysUntil = upcoming?.daysUntil ?? 0
        if known, let years = upcoming?.years {
            let label = entry.title.contains("生日") ? "\(years)岁" : "\(years)周年"
            subtitle = "\(raw[0])年\(month)月\(day)日 · \(label)"
        } else {
            subtitle = "每年\(month)月\(day)日 · 年份未填写"
        }
    }
}

struct AnniversaryReminder: View {
    @EnvironmentObject private var model: AppModel
    private var upcoming: AnniversaryEntry? {
        model.session.anniversaryEntries()
            .filter { [0, 1, 2, 3, 7].contains(AnniversaryPresentation($0).daysUntil) }
            .sorted { AnniversaryPresentation($0).daysUntil < AnniversaryPresentation($1).daysUntil }.first
    }
    var body: some View {
        if let entry = upcoming {
            Button { model.tab = .anniversaries } label: {
                HStack(spacing: 10) {
                    Image(systemName: "heart.fill")
                    let days = AnniversaryPresentation(entry).daysUntil
                    Text(days == 0 ? "今天是\(entry.title)" : "还有\(days)天，\(entry.title)")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }
                .foregroundStyle(Theme.ink)
                .padding(14)
                .background(Theme.goldSoft, in: RoundedRectangle(cornerRadius: 14))
            }
            .accessibilityIdentifier("anniversaryReminder")
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}

private struct AnniversaryEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let entry: AnniversaryEntry?
    @State private var title = ""
    @State private var date = Date.now
    @State private var yearKnown = true
    @State private var deleteConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("重要的日子") {
                    TextField("名称", text: $title).accessibilityIdentifier("anniversaryTitle")
                        .onChange(of: title) { _, value in if value.count > 100 { title = String(value.prefix(100)) } }
                    Toggle("填写年份", isOn: $yearKnown).accessibilityIdentifier("anniversaryYearKnown")
                    if yearKnown {
                        DatePicker("日期", selection: $date, displayedComponents: .date)
                            .accessibilityIdentifier("anniversaryDate")
                    } else {
                        HStack {
                            Picker("月", selection: monthBinding) { ForEach(1...12, id: \.self) { Text("\($0)月").tag($0) } }
                            Picker("日", selection: dayBinding) { ForEach(1...daysInMonth, id: \.self) { Text("\($0)日").tag($0) } }
                        }
                        .pickerStyle(.menu)
                    }
                }
                .disabled(entry?.readOnly == true)
                Section {
                    if let entry {
                        HStack { Text("署名"); Spacer(); ParentBadge(parent: entry.owner) }
                        if entry.readOnly { Text("来自另一台设备或另一位家长，仅可查看。").foregroundStyle(Theme.inkSecondary) }
                    }
                    Text("提醒会显示在应用内，不发送系统通知。").font(.footnote).foregroundStyle(Theme.inkSecondary)
                }
                if let entry, !entry.readOnly {
                    Section { Button("删除纪念日", role: .destructive) { deleteConfirmation = true }.accessibilityIdentifier("deleteAnniversary") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(entry == nil ? "添加纪念日" : "纪念日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                if entry?.readOnly != true {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            if model.saveAnniversary(id: entry?.id, title: title, date: storedDate) { dismiss() }
                        }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("saveAnniversary")
                    }
                }
            }
            .confirmationDialog("删除纪念日？", isPresented: $deleteConfirmation, titleVisibility: .visible) {
                Button("删除", role: .destructive) { if let entry { model.deleteAnniversary(id: entry.id) }; dismiss() }
                Button("取消", role: .cancel) {}
            } message: { Text("从列表移除这条纪念日，云端文件不会被删除。") }
            .onAppear { load() }
        }
    }

    private var monthBinding: Binding<Int> { Binding(get: { Calendar.current.component(.month, from: date) }, set: { set(month: $0, day: Calendar.current.component(.day, from: date)) }) }
    private var dayBinding: Binding<Int> { Binding(get: { Calendar.current.component(.day, from: date) }, set: { set(month: Calendar.current.component(.month, from: date), day: $0) }) }
    private var daysInMonth: Int {
        let month = Calendar.current.component(.month, from: date)
        let anchor = Calendar.current.date(from: DateComponents(year: 2000, month: month, day: 1)) ?? date
        return Calendar.current.range(of: .day, in: .month, for: anchor)?.count ?? 31
    }
    private func set(month: Int, day: Int) {
        let anchor = Calendar.current.date(from: DateComponents(year: 2000, month: month, day: 1)) ?? date
        let maximum = Calendar.current.range(of: .day, in: .month, for: anchor)?.count ?? 31
        date = Calendar.current.date(from: DateComponents(year: 2000, month: month, day: min(day, maximum))) ?? date
    }
    private var storedDate: String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return yearKnown ? String(format: "%04d-%02d-%02d", components.year ?? 2000, components.month ?? 1, components.day ?? 1) : String(format: "--%02d-%02d", components.month ?? 1, components.day ?? 1)
    }
    private func load() {
        guard let entry else { return }
        title = entry.title
        let values = entry.date.split(separator: "-", omittingEmptySubsequences: true).compactMap { Int($0) }
        yearKnown = values.count == 3 && values[0] != 4
        guard values.count >= 2 else { return }
        date = Calendar.current.date(from: DateComponents(year: yearKnown ? values[0] : 2000, month: values[values.count - 2], day: values.last)) ?? date
    }
}

struct FeatureEmptyState: View {
    let title: String
    let detail: String
    let systemImage: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage).font(.system(size: 42)).foregroundStyle(Theme.inkSecondary)
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
            Text(detail).font(.body).foregroundStyle(Theme.inkSecondary)
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}
