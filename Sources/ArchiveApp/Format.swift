import SwiftUI
import AppKit
import ArchiveCore

/// Date, number and color helpers shared by the views. Formatters are created once and only touched on the main actor.
@MainActor
enum Fmt {
    static var calendar = Calendar.current

    private static let dayHeader: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEEMMMMdy"); return f }()
    private static let shortDate: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none; return f }()
    private static let timeOnly: DateFormatter = { let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f }()
    private static let weekday: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEE"); return f }()
    private static let full: DateFormatter = { let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .short; return f }()
    private static let month: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMMy"); return f }()
    private static let monthShort: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMy"); return f }()

    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    static func dayHeader(_ ms: Int64) -> String { dayHeader.string(from: date(ms)) }
    static func time(_ ms: Int64) -> String { timeOnly.string(from: date(ms)) }
    static func fullDate(_ ms: Int64) -> String { full.string(from: date(ms)) }
    static func monthTitle(_ ms: Int64) -> String { month.string(from: date(ms)) }
    static func monthTitle(_ year: Int, _ m: Int) -> String {
        guard let d = calendar.date(from: DateComponents(year: year, month: m, day: 1)) else { return "\(year)-\(m)" }
        return month.string(from: d)
    }
    static func monthShortTitle(_ year: Int, _ m: Int) -> String {
        guard let d = calendar.date(from: DateComponents(year: year, month: m, day: 1)) else { return "\(year)-\(m)" }
        return monthShort.string(from: d)
    }

    /// Conversation-list date: time today, "Yesterday", weekday this week, else a short date.
    static func listDate(_ ms: Int64, now: Date = Date()) -> String {
        let d = date(ms)
        if calendar.isDate(d, inSameDayAs: now) { return timeOnly.string(from: d) }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return "Yesterday" }
        if let w = calendar.date(byAdding: .day, value: -6, to: now), d > w { return weekday.string(from: d) }
        return shortDate.string(from: d)
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// +12125550101 -> (212) 555-0101; other handles are shown as stored.
    static func phone(_ normalized: String) -> String {
        let digits = normalized.filter(\.isNumber)
        if normalized.hasPrefix("+1"), digits.count == 11 {
            let d = Array(digits.dropFirst())
            return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
        }
        return normalized
    }

    static func monthRangeMs(_ year: Int, _ m: Int) -> ClosedRange<Int64>? {
        guard let start = calendar.date(from: DateComponents(year: year, month: m, day: 1)),
              let next = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return Int64(start.timeIntervalSince1970 * 1000)...(Int64(next.timeIntervalSince1970 * 1000) - 1)
    }

    static func initials(_ title: String) -> String {
        let words = title.split(separator: " ").filter { $0.first?.isLetter == true }
        if words.isEmpty { return "#" }
        return words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }.joined()
    }

    static func avatarColor(_ key: String) -> Color {
        var h: UInt32 = 5381
        for u in key.unicodeScalars { h = h &* 33 &+ u.value }
        return Color(hue: Double(h % 360) / 360, saturation: 0.45, brightness: 0.78)
    }
}

struct MonthKey: Hashable, Sendable {
    var year: Int
    var month: Int
    var index: Int { year * 12 + month - 1 }
    init(year: Int, month: Int) { self.year = year; self.month = month }
    init(index: Int) { year = index / 12; month = index % 12 + 1 }
}

// MARK: snapshot environment

private struct IsSnapshotKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True while rendering headless PNGs: AppKit-backed containers (List, ScrollView) draw nothing under ImageRenderer,
    /// so the views swap them for plain stacks.
    var isSnapshot: Bool {
        get { self[IsSnapshotKey.self] }
        set { self[IsSnapshotKey.self] = newValue }
    }
}
