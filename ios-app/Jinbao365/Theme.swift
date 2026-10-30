import SwiftUI

enum Theme {
    static let background = Color(hex: 0xF4F4F2)
    static let surface = Color.white
    static let ink = Color(hex: 0x0F2747)
    static let inkSecondary = Color(hex: 0x6E6E73)
    static let separator = Color(hex: 0xE5E5EA)
    static let gold = Color(hex: 0xF7C948)
    static let goldSoft = Color(hex: 0xFEF4D6)
    static let navy = Color(hex: 0x0F2747)
    static let onNavy = Color(hex: 0xFDF6E9)
    static let outline = Color(hex: 0x8C8C91)
    static let photoPlaceholder = Color(hex: 0xECECEA)
    static let noteInk = Color(hex: 0x3A4A5E)
    static let dadBackground = Color(hex: 0xDEEDF8)
    static let dadInk = Color(hex: 0x2F5A75)
    static let momBackground = Color(hex: 0xF9E1E8)
    static let momInk = Color(hex: 0x86495D)
    static let problem = Color(hex: 0xA33333)

    static func parentBackground(_ parent: ParentIdentity) -> Color {
        parent == .dad ? dadBackground : momBackground
    }

    static func parentInk(_ parent: ParentIdentity) -> Color {
        parent == .dad ? dadInk : momInk
    }

    static func ageLabel(on date: Date = .now) -> String {
        let parts = JinbaoCalendar.parts(millis: Int64(date.timeIntervalSince1970 * 1000), timeZone: .current)
        guard let age = JinbaoCalendar.age(on: parts) else { return "留住一起度过的日子" }
        return "\(age.years)岁\(age.months)个月\(age.days)天"
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}

struct BrandMark: View {
    var size: CGFloat = 36
    var body: some View {
        Image("BrandMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .background(Theme.navy)
            .clipShape(RoundedRectangle(cornerRadius: size * 2 / 9, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct BrandWordmark: View {
    var body: some View {
        Text("DaysWith")
            .font(.system(size: 36, weight: .bold))
            .frame(maxWidth: 230)
            .accessibilityLabel("DaysWith · 记录成长，收藏美好")
    }
}

struct ParentBadge: View {
    let parent: ParentIdentity
    var body: some View {
        Text(parent.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.parentInk(parent))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.parentBackground(parent), in: Capsule())
            .fixedSize()
    }
}

struct BrandCard: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct GoldButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .frame(minHeight: 52)
                .background(enabled ? Theme.gold : Theme.separator, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(!enabled)
    }
}
