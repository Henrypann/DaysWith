import Foundation

public struct TimelineDay: Equatable, Identifiable {
    public var date: DateParts
    public var title: String
    public var moments: [TimelineEntry]
    public var id: String { "\(date.year)-\(date.month)-\(date.day)" }
    public init(date: DateParts, title: String, moments: [TimelineEntry]) {
        self.date = date
        self.title = title
        self.moments = moments
    }
}

public struct TimelineMonth: Equatable, Identifiable {
    public var year: Int
    public var month: Int
    public var days: [TimelineDay]
    public var id: String { "\(year)-\(month)" }
    /// Always four-digit year, including months in the current year.
    public var title: String { Self.title(year: year, month: month) }
    public init(year: Int, month: Int, days: [TimelineDay]) {
        self.year = year
        self.month = month
        self.days = days
    }
    public static func title(year: Int, month: Int) -> String { "\(year)年\(month)月" }
}

public struct DateParts: Equatable, Hashable {
    public var year: Int
    public var month: Int
    public var day: Int
    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }
}

public struct TimelinePhoto: Equatable, Hashable, Identifiable {
    public var id: String
    public var localPath: String?
    public var fullSizePath: String?
    public var remote: RemotePreview?
    public var kind: String
    public var localResources: [LocalResource]
    public var remoteResources: [RemoteResource]
    public init(id: String, localPath: String? = nil, fullSizePath: String? = nil, remote: RemotePreview? = nil, kind: String = "photo",
                localResources: [LocalResource] = [], remoteResources: [RemoteResource] = []) {
        self.id = id
        self.localPath = localPath
        self.fullSizePath = fullSizePath
        self.remote = remote
        self.kind = kind
        self.localResources = localResources
        self.remoteResources = remoteResources
    }
}

public struct TimelineEntry: Equatable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var note: String
    public var occurredAt: Int64
    public var parent: ParentIdentity
    public var readOnly: Bool
    public var mediaCount: Int
    public var previewPath: String?
    public var provenanceLabel: String?
    public var photos: [TimelinePhoto]

    public init(id: String, title: String, note: String, occurredAt: Int64, parent: ParentIdentity,
                readOnly: Bool, mediaCount: Int, previewPath: String?, provenanceLabel: String?, photos: [TimelinePhoto] = []) {
        self.id = id
        self.title = title
        self.note = note
        self.occurredAt = occurredAt
        self.parent = parent
        self.readOnly = readOnly
        self.mediaCount = mediaCount
        self.previewPath = previewPath
        self.provenanceLabel = provenanceLabel
        self.photos = photos
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let noteText = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !noteText.isEmpty { return noteText }
        return "值得留住的小日常"
    }
}

public enum TimelineEmptyCopy {
    public static let title = "留住我们的第一个小日常"
    public static let detail = "轻点下面的＋，存下照片或写一段话"
}

public enum JinbaoCalendar {

    public static func parts(millis: Int64, timeZone: TimeZone) -> DateParts {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return DateParts(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    public static func age(on date: DateParts, birthday: DateParts? = nil) -> (years: Int, months: Int, days: Int)? {
        guard let birthday else { return nil }
        if compare(date, birthday) < 0 { return nil }
        let months = wholeMonths(from: birthday, to: date)
        let anchor = addingMonths(months, to: birthday)
        let days = wholeDays(from: anchor, to: date)
        return (months / 12, months % 12, days)
    }

    public static func dayTitle(_ date: DateParts) -> String {
        return "\(date.month)月\(date.day)日"
    }

    public static func months(entries: [TimelineEntry], timeZone: TimeZone) -> [TimelineMonth] {
        let sorted = entries.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            return $0.id < $1.id
        }
        var byMonth: [String: (DateParts, [TimelineEntry])] = [:]
        for entry in sorted {
            let date = parts(millis: entry.occurredAt, timeZone: timeZone)
            let key = "\(date.year)-\(date.month)"
            var bucket = byMonth[key] ?? (date, [])
            bucket.1.append(entry)
            byMonth[key] = bucket
        }
        let months = byMonth.map { _, value -> TimelineMonth in
            let date = value.0
            let grouped = Dictionary(grouping: value.1) { parts(millis: $0.occurredAt, timeZone: timeZone) }
            let days = grouped.map { day, moments in
                TimelineDay(date: day, title: dayTitle(day), moments: moments)
            }.sorted { compare($0.date, $1.date) > 0 }
            return TimelineMonth(year: date.year, month: date.month, days: days)
        }
        return months.sorted { lhs, rhs in
            if lhs.year != rhs.year { return lhs.year > rhs.year }
            return lhs.month > rhs.month
        }
    }

    private static func compare(_ lhs: DateParts, _ rhs: DateParts) -> Int {
        if lhs.year != rhs.year { return lhs.year < rhs.year ? -1 : 1 }
        if lhs.month != rhs.month { return lhs.month < rhs.month ? -1 : 1 }
        if lhs.day != rhs.day { return lhs.day < rhs.day ? -1 : 1 }
        return 0
    }

    private static func wholeMonths(from start: DateParts, to end: DateParts) -> Int {
        var months = (end.year - start.year) * 12 + (end.month - start.month)
        if end.day < start.day { months -= 1 }
        return max(0, months)
    }

    private static func addingMonths(_ months: Int, to date: DateParts) -> DateParts {
        let total = date.year * 12 + (date.month - 1) + months
        let year = total / 12
        let month = total % 12 + 1
        let day = min(date.day, daysInMonth(year: year, month: month))
        return DateParts(year: year, month: month, day: day)
    }

    private static func wholeDays(from start: DateParts, to end: DateParts) -> Int {
        julian(end) - julian(start)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeap(year) ? 29 : 28
        default: return 30
        }
    }

    private static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    private static func julian(_ date: DateParts) -> Int {
        var year = date.year
        var month = date.month
        let a = (14 - month) / 12
        year -= a
        month += 12 * a - 3
        return date.day + (153 * month + 2) / 5 + 365 * year + year / 4 - year / 100 + year / 400 - 32045
    }
}
