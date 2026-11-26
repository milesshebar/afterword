import Foundation

/// Ranks a source label against a list of prefixes, for choosing which copy wins a duplicate group (smaller is better).
/// A label matches a prefix when it equals it or starts with `<prefix>-`; earlier prefixes win. Among labels of one prefix, the
/// one naming the later year wins (`vm-phone-2026` over `vm-phone-2016`: a newer backup carries the more complete record), and a
/// label with no year comes after the dated ones. A label matching no prefix ranks after all of them.
enum SourceRank {
    static let unmatched = 1_000_000

    static func rank(_ label: String, prefixes: [String]) -> Int {
        guard let i = prefixes.firstIndex(where: { label == $0 || label.hasPrefix($0 + "-") }) else { return unmatched }
        let rest = label.dropFirst(prefixes[i].count)
        return i * 10_000 + (year(in: rest).map { 10_000 - $0 } ?? 9_999)
    }

    /// The first run of exactly four digits from 1900 to 2099, if any.
    static func year(in s: Substring) -> Int? {
        var digits = ""
        for c in s + "-" {
            if c.isASCII && c.isNumber { digits.append(c); continue }
            if digits.count == 4, let y = Int(digits), (1900...2099).contains(y) { return y }
            digits = ""
        }
        return nil
    }
}
