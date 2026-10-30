import Foundation

public struct LocalAnniversary: Codable, Equatable, Identifiable {
    public var id: String
    public var owner: ParentIdentity
    public var title: String
    public var date: String
    public var deletedAt: Int64?
    public var updatedAt: Int64
    public private(set) var uploadEligibility: UploadEligibility
    public init(id: String = UUID().uuidString.uppercased(), owner: ParentIdentity, title: String, date: String,
                deletedAt: Int64? = nil, updatedAt: Int64, uploadEligibility: UploadEligibility = .localOnly) {
        self.id = id; self.owner = owner; self.title = title; self.date = date
        self.deletedAt = deletedAt; self.updatedAt = updatedAt; self.uploadEligibility = uploadEligibility
    }
    private enum CodingKeys: String, CodingKey { case id, owner, title, date, deletedAt, updatedAt, uploadEligibility }
    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        id = try v.decode(String.self, forKey: .id)
        owner = try v.decode(ParentIdentity.self, forKey: .owner)
        title = try v.decode(String.self, forKey: .title)
        date = try AnniversaryCalendar.normalizedDate(v.decode(String.self, forKey: .date))
        deletedAt = try v.decodeIfPresent(Int64.self, forKey: .deletedAt)
        updatedAt = try v.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
        uploadEligibility = try v.decodeIfPresent(UploadEligibility.self, forKey: .uploadEligibility) ?? .localOnly
    }
}

public struct RemoteAnniversary: Codable, Equatable, Identifiable {
    public var recordID: String
    public var owner: ParentIdentity
    public var title: String
    public var date: String
    public var deletedAt: Int64?
    public var sourcePrefix: String
    public var updatedAt: Int64
    public var id: String { "remote:\(owner.folder):anniversary:\(recordID.uppercased())" }
    public init(recordID: String, owner: ParentIdentity, title: String, date: String, deletedAt: Int64? = nil,
                sourcePrefix: String, updatedAt: Int64) {
        self.recordID = recordID; self.owner = owner; self.title = title; self.date = date
        self.deletedAt = deletedAt; self.sourcePrefix = sourcePrefix; self.updatedAt = updatedAt
    }
}

public struct AnniversaryEntry: Equatable, Identifiable {
    public var id: String
    public var title: String
    public var date: String
    public var owner: ParentIdentity
    public var readOnly: Bool
    public var isDefault: Bool
    public var yearKnown: Bool { !date.hasPrefix("0004-") }
    public init(id: String, title: String, date: String, owner: ParentIdentity, readOnly: Bool, isDefault: Bool = false) {
        self.id = id; self.title = title; self.date = date; self.owner = owner
        self.readOnly = readOnly; self.isDefault = isDefault
    }
}

public struct UpcomingAnniversary: Equatable, Identifiable {
    public var entry: AnniversaryEntry
    public var daysUntil: Int
    public var years: Int?
    public var nextDate: Date
    public var id: String { entry.id }
    public var shouldRemind: Bool { [0, 1, 2, 3, 7].contains(daysUntil) }
}

public enum AnniversaryCalendar {
    public struct Builtin: Equatable, Identifiable {
        public var id: String
        public var title: String
        public var date: String
    }
    public static let defaults: [Builtin] = [
        Builtin(id: "00000000-0000-4000-8000-000000000101", title: "儿童节", date: "0004-06-01"),
        Builtin(id: "00000000-0000-4000-8000-000000000102", title: "国庆节", date: "0004-10-01"),
        Builtin(id: "00000000-0000-4000-8000-000000000103", title: "元旦", date: "0004-01-01")
    ]
    public static func isDefault(_ id: String) -> Bool { defaults.contains { $0.id.caseInsensitiveCompare(id) == .orderedSame } }

    public static func normalizedDate(_ value: String) throws -> String {
        let date = value.hasPrefix("--") ? "0004-" + value.dropFirst(2) : value
        guard date.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else {
            throw ContractError(path: "anniversary.date", message: "请选择有效的纪念日日期。")
        }
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]), (1...31).contains(parts[2]) else {
            throw ContractError(path: "anniversary.date", message: "请选择有效的纪念日日期。")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let instant = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            throw ContractError(path: "anniversary.date", message: "请选择有效的纪念日日期。")
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: instant)
        guard roundTrip.year == parts[0], roundTrip.month == parts[1], roundTrip.day == parts[2] else {
            throw ContractError(path: "anniversary.date", message: "请选择有效的纪念日日期。")
        }
        return date
    }

    public static func upcoming(_ entries: [AnniversaryEntry], now: Int64, timeZone: TimeZone) -> [UpcomingAnniversary] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(now) / 1000))
        let currentYear = calendar.component(.year, from: today)
        return entries.compactMap { entry -> UpcomingAnniversary? in
            guard let valid = try? normalizedDate(entry.date) else { return nil }
            let parts = valid.split(separator: "-").compactMap { Int($0) }
            // Android LocalDate.withYear clamps a leap-day anniversary to Feb 28 in non-leap years.
            func date(in year: Int) -> Date? {
                guard let monthStart = calendar.date(from: DateComponents(year: year, month: parts[1], day: 1)),
                      let days = calendar.range(of: .day, in: .month, for: monthStart) else { return nil }
                return calendar.date(from: DateComponents(year: year, month: parts[1], day: min(parts[2], days.count)))
            }
            let firstYear = entry.yearKnown ? max(currentYear, parts[0]) : currentYear
            guard var next = date(in: firstYear) else { return nil }
            if next < today { guard let following = date(in: firstYear + 1) else { return nil }; next = following }
            let days = calendar.dateComponents([.day], from: today, to: next).day ?? 0
            let years = entry.yearKnown ? calendar.component(.year, from: next) - parts[0] : nil
            return UpcomingAnniversary(entry: entry, daysUntil: days, years: years, nextDate: next)
        }.sorted { $0.daysUntil == $1.daysUntil ? $0.id < $1.id : $0.daysUntil < $1.daysUntil }
    }
}

public extension AppSession {
    func anniversaryEntries() -> [AnniversaryEntry] {
        guard let owner = identity else { return [] }
        var result = anniversaries.filter { $0.deletedAt == nil && !AnniversaryCalendar.isDefault($0.id) }.map {
            AnniversaryEntry(id: $0.id, title: $0.title, date: $0.date, owner: $0.owner, readOnly: $0.owner != owner)
        }
        result += remoteAnniversaries.filter { remote in
            remote.deletedAt == nil && !AnniversaryCalendar.isDefault(remote.recordID)
                && !anniversaries.contains(where: { $0.owner == remote.owner && $0.id.caseInsensitiveCompare(remote.recordID) == .orderedSame })
        }.map { AnniversaryEntry(id: $0.id, title: $0.title, date: $0.date, owner: $0.owner, readOnly: true) }
        for item in AnniversaryCalendar.defaults {
            if let local = anniversaries.first(where: { $0.owner == owner && $0.id.caseInsensitiveCompare(item.id) == .orderedSame }) {
                if local.deletedAt == nil { result.append(AnniversaryEntry(id: local.id, title: local.title, date: local.date, owner: owner, readOnly: false, isDefault: true)) }
            } else if let remote = remoteAnniversaries.filter({ $0.recordID.caseInsensitiveCompare(item.id) == .orderedSame }).sorted(by: {
                if ($0.owner == owner) != ($1.owner == owner) { return $0.owner == owner }
                return $0.updatedAt > $1.updatedAt
            }).first {
                if remote.deletedAt == nil { result.append(AnniversaryEntry(id: remote.id, title: remote.title, date: remote.date, owner: remote.owner, readOnly: true, isDefault: true)) }
            } else { result.append(AnniversaryEntry(id: item.id, title: item.title, date: item.date, owner: owner, readOnly: false, isDefault: true)) }
        }
        return result
    }

    @discardableResult
    mutating func saveAnniversary(id: String? = nil, title: String, date: String, now: Int64) throws -> LocalAnniversary {
        guard let owner = identity else { throw ContractError(path: "identity", message: "请先选择爸爸或妈妈。") }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, cleanTitle.utf16.count <= 100 else { throw ContractError(path: "anniversary.title", message: "请填写 1–100 字的标题。") }
        let validDate = try AnniversaryCalendar.normalizedDate(date)
        let recordID = try V1Ids.canonical(id ?? UUID().uuidString, path: "anniversary.id")
        if let index = anniversaries.firstIndex(where: { $0.id.caseInsensitiveCompare(recordID) == .orderedSame && $0.owner == owner }) {
            anniversaries[index].title = cleanTitle; anniversaries[index].date = validDate
            anniversaries[index].deletedAt = nil; anniversaries[index].updatedAt = now
            return anniversaries[index]
        }
        if remoteAnniversaries.contains(where: { $0.owner == owner && $0.recordID.caseInsensitiveCompare(recordID) == .orderedSame }) {
            throw ContractError(path: "anniversary", message: "其他设备创建的纪念日只读。")
        }
        let item = LocalAnniversary(id: recordID, owner: owner, title: cleanTitle, date: validDate,
                                    updatedAt: now, uploadEligibility: newUploadEligibility)
        anniversaries.append(item)
        return item
    }

    mutating func deleteAnniversary(id: String, now: Int64) throws {
        guard let owner = identity else { throw ContractError(path: "identity", message: "请先选择爸爸或妈妈。") }
        if let index = anniversaries.firstIndex(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame && $0.owner == owner }) {
            if anniversaries[index].deletedAt == nil { anniversaries[index].deletedAt = now; anniversaries[index].updatedAt = now }
            return
        }
        guard !remoteAnniversaries.contains(where: { $0.recordID.caseInsensitiveCompare(id) == .orderedSame }),
              let item = AnniversaryCalendar.defaults.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw ContractError(path: "anniversary", message: "只能删除这台手机创建的纪念日。")
        }
        anniversaries.append(LocalAnniversary(id: item.id, owner: owner, title: item.title, date: item.date,
                                             deletedAt: now, updatedAt: now, uploadEligibility: newUploadEligibility))
    }

    func backupAnniversaries() throws -> [V1Anniversary] {
        let eligibility: UploadEligibility = testBuild ? .testOnly : .eligible
        return try anniversaries.filter { $0.uploadEligibility == eligibility && $0.owner == identity }.map {
            V1Anniversary(id: try V1Ids.canonical($0.id, path: "anniversary.id"), owner: $0.owner,
                          title: $0.title, date: try AnniversaryCalendar.normalizedDate($0.date), deletedAt: $0.deletedAt)
        }.sorted { $0.id < $1.id }
    }
}
