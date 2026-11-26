import Foundation

/// Instagram's own system lines as this account's export wrote them: in Burmese, not English (a known quirk of Meta's
/// exports; the account was never set to Burmese). The English versions never occur in the data. `translate` maps a line to
/// the `kind` / `note` the archive stores, so the app can show it as a quiet system note instead of a bubble in a foreign script.
public enum InstagramSystemLines {
    public struct Result: Equatable, Sendable {
        public var kind: String          // system | call
        public var note: String
        public var fallback: Bool        // true: unrecognized line, caught by the all-Myanmar last-resort rule
    }

    static let fallbackNote = "(Instagram system line)"

    static func isMyanmar(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x1000...0x109F).contains($0.value) }
    }

    /// True when the text holds any Myanmar-script character.
    public static func containsMyanmar(_ s: String) -> Bool { s.contains(where: isMyanmar) }

    static func asciiDigits(_ s: String) -> String {
        String(s.unicodeScalars.map { (0x1040...0x1049).contains($0.value) ? Character(UnicodeScalar(UInt32(48) + $0.value - 0x1040)!) : Character($0) })
    }

    private static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let actorPrefix = regex(#"^([^က-႟]+?)\s*က(?=\s|$)"#)
    private static let reacted = regex(#"သင့်မက်ဆေ့\s*ကို\s*(.+?)\s*ပေးထားပါတယ်"#)
    private static let groupName = regex(#"(?:အမည်ကို|အဖွဲ့ကို)\s*(.+?)\s*လို့"#)
    private static let theme = regex(#"အရောင်ကို\s*(.+?)\s*အဖြစ်"#)
    private static let others = regex(#"အခြား\s*(\S+?)\s*ဦး"#)

    /// Substring tests by Character (canonical equivalence), the same on every platform. Burmese marks in the exports and in
    /// the markers here are not always in the same code-point order; Linux Foundation's `contains` compares code units and
    /// would miss them (macOS resolved to the stdlib's Character search, which does not).
    static func has(_ hay: String, _ needle: String) -> Bool {
        let n = Array(needle), h = Array(hay)
        guard !n.isEmpty, h.count >= n.count else { return false }
        for i in 0...(h.count - n.count) where h[i] == n[0] {
            if h[i..<(i + n.count)].elementsEqual(n) { return true }
        }
        return false
    }

    static func starts(_ hay: String, _ needle: String) -> Bool { Array(hay).starts(with: Array(needle)) }

    private static func capture(_ re: NSRegularExpression, _ s: String) -> String? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// `actor`: who sent the line when the text names nobody ("You" for my own rows, the sender's name otherwise).
    /// Returns nil for text that is not a system line (no Myanmar script, or mostly something else).
    public static func translate(_ raw: String, actor senderName: String?, isMe: Bool = false) -> Result? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard containsMyanmar(text) else { return nil }

        // A leading username ("name က …") or "A contact" is the actor; otherwise it is whoever sent the row.
        var rest = text
        var named: String?
        let contact = "အဆက်အသွယ်တစ်ဦး"
        if starts(rest, contact) {
            named = "A contact"
            rest = String(rest.dropFirst(contact.count))
            if starts(rest, "က") { rest = String(rest.dropFirst()) }
        } else if let name = capture(actorPrefix, rest) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            // "Max Laz ကို …": the Latin run is a person in the sentence, not an actor; the pattern needs က then a space.
            named = trimmed
            let ns = rest as NSString
            if let m = actorPrefix.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)) { rest = ns.substring(from: m.range.upperBound) }
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        let hasYou = has(rest, "သင်")
        let who: String = named ?? (hasYou || isMe ? "You" : (senderName ?? "Someone"))

        // "You can now message and call each other…": Instagram's notice when two accounts start sharing a chat.
        if starts(rest, "အခုဆိုရင် သင့်အနေနဲ့ အပြန်အလှန်") { return Result(kind: "system", note: "You can now message and call each other", fallback: false) }
        if has(rest, "နှစ်သက်ခဲ့ပါတယ်") { return Result(kind: "system", note: "\(who) liked a message", fallback: false) }
        if let emoji = capture(reacted, rest) { return Result(kind: "system", note: "\(who) reacted \(emoji) to your message", fallback: false) }

        for (marker, label) in [("ဗီဒီယိုစကားဝိုင်း", "video call"), ("အသံခေါ်ဆိုမှု", "audio call")] where has(rest, marker) {
            let a = label.hasPrefix("a") ? "an" : "a"
            if has(rest, "ဓာတ်ပုံ") { return Result(kind: "system", note: "\(who) took a photo during the \(label)", fallback: false) }
            if has(rest, "လွတ်သွား") || has(rest, "မကိုင်") { return Result(kind: "call", note: "\(who) missed \(a) \(label)", fallback: false) }
            if has(rest, "ပြီးဆုံး") { return Result(kind: "call", note: label.prefix(1).uppercased() + label.dropFirst() + " ended", fallback: false) }
            if has(rest, "စတင်") { return Result(kind: "call", note: "\(who) started \(a) \(label)", fallback: false) }
        }

        if has(rest, "ထွက်သွားပါပြီ") { return Result(kind: "system", note: "\(who) left the group", fallback: false) }
        if has(rest, "အရောင်ကို"), let t = capture(theme, rest) { return Result(kind: "system", note: "\(who) changed the theme to \(t)", fallback: false) }
        if has(rest, "လို့"), let n = capture(groupName, rest), has(rest, "ပေးခဲ့") || has(rest, "နာမည်ပေး") {
            return Result(kind: "system", note: "\(who) named the group \(n)", fallback: false)
        }
        if has(rest, "ဖန်တီးခဲ့ပါတယ်") { return Result(kind: "system", note: "\(who) created the group", fallback: false) }
        if has(rest, "ထည့်သွင်းခဲ့ပါတယ်") || has(rest, "ထည့်လိုက်သည်") {
            // "<people> ကို အဖွဲ့ထဲ …": the people come first. "you and N others" is spelled "သင့်နဲ့ အခြား N ဦး".
            var people = rest.components(separatedBy: "ကို").first?.trimmingCharacters(in: .whitespaces) ?? ""
            if let count = capture(others, people).map(asciiDigits) {
                let head = people.components(separatedBy: "နဲ့").first?.trimmingCharacters(in: .whitespaces) ?? ""
                people = (head == "သင့်" ? "you" : head) + " and \(count) others"
            } else {
                people = people == "သင့်" ? "you" : people
            }
            return Result(kind: "system", note: people.isEmpty ? "\(who) added people to the group" : "\(who) added \(people) to the group", fallback: false)
        }

        // Last resort: a line that is Myanmar script apart from emoji, punctuation and Latin names.
        var my = 0, other = 0
        for c in rest where c.isLetter { if isMyanmar(c) { my += 1 } else { other += 1 } }
        if my > other { return Result(kind: "system", note: fallbackNote, fallback: true) }
        return nil
    }
}

/// Apple tapbacks that reached the archive as text ("Loved “…”"), e.g. an iPhone user's reaction forwarded to an Android phone
/// phone as an SMS. Parsing is shared by the in-place reclassify pass and any importer.
public struct Tapback: Equatable, Sendable {
    public var emoji: String
    public var quote: String
    public var removal: Bool

    static let added: [(prefix: String, emoji: String)] = [
        ("Loved ", "❤️"), ("Liked ", "👍"), ("Disliked ", "👎"), ("Laughed at ", "😂"), ("Emphasized ", "‼️"), ("Questioned ", "❓"),
    ]
    static let removed: [(what: String, emoji: String)] = [
        ("a heart", "❤️"), ("a like", "👍"), ("a thumbs up", "👍"), ("a dislike", "👎"), ("a thumbs down", "👎"),
        ("a laugh", "😂"), ("a ha ha", "😂"), ("an exclamation", "‼️"), ("an exclamation mark", "‼️"), ("an emphasis", "‼️"),
        ("a question mark", "❓"), ("a question", "❓"),
    ]

    /// The text inside the outer quotes: “…” or "…". nil when the body does not end with the closing quote.
    private static func quoted(_ s: Substring) -> String? {
        guard let first = s.first, let last = s.last, s.count >= 2 else { return nil }
        if first == "“" && last == "”" { return String(s.dropFirst().dropLast()) }
        if first == "\"" && last == "\"" { return String(s.dropFirst().dropLast()) }
        return nil
    }

    public static func parse(_ body: String?) -> Tapback? {
        guard let body else { return nil }
        let s = body.trimmingCharacters(in: .whitespacesAndNewlines)
        for (p, e) in added where s.hasPrefix(p) {
            if let q = quoted(s.dropFirst(p.count)) { return Tapback(emoji: e, quote: q, removal: false) }
        }
        if s.hasPrefix("Removed ") {
            let rest = s.dropFirst("Removed ".count)
            for (w, e) in removed where rest.hasPrefix(w + " from ") {
                if let q = quoted(rest.dropFirst(w.count + " from ".count)) { return Tapback(emoji: e, quote: q, removal: true) }
            }
        }
        return nil
    }

    /// Whitespace-collapsed form, for the second matching attempt.
    public static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
