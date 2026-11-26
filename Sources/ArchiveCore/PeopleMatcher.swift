import Foundation

/// The four services a message can have come from, as the app shows them. `sms` covers `sms` and `mms` rows.
public enum ServiceKey: String, CaseIterable, Sendable, Hashable, Identifiable, Comparable {
    case imessage, sms, messenger, instagram, groupme, skype, whatsapp, snapchat, aim, telegram, slack
    public var id: String { rawValue }
    public var label: String {
        switch self { case .imessage: return "iMessage"; case .sms: return "SMS"; case .messenger: return "Messenger"; case .instagram: return "Instagram"; case .groupme: return "GroupMe"; case .skype: return "Skype"; case .whatsapp: return "WhatsApp"; case .snapchat: return "Snapchat"; case .aim: return "AIM"; case .telegram: return "Telegram"; case .slack: return "Slack" }
    }
    /// The `message.service` values that belong to this service.
    public var messageServices: [String] {
        switch self { case .sms: return ["sms", "mms"]; default: return [rawValue] }
    }
    public static func of(messageService s: String) -> ServiceKey {
        switch s { case "imessage": return .imessage; case "messenger": return .messenger; case "instagram": return .instagram; case "groupme": return .groupme; case "skype": return .skype; case "whatsapp": return .whatsapp; case "snapchat": return .snapchat; case "aim": return .aim; case "telegram": return .telegram; case "slack": return .slack; default: return .sms }
    }
    public static func < (a: ServiceKey, b: ServiceKey) -> Bool { a.sortIndex < b.sortIndex }
    private var sortIndex: Int { switch self { case .imessage: return 0; case .sms: return 1; case .messenger: return 2; case .instagram: return 3; case .groupme: return 4; case .skype: return 5; case .whatsapp: return 6; case .snapchat: return 7; case .aim: return 8; case .telegram: return 9; case .slack: return 10 } }
}

/// Name comparison for matching people across services. Deliberately conservative: only whole, folded full names
/// (two or more words) ever match; nicknames and first names alone are never guessed.
public enum NameMatching {
    /// Case-, diacritic- and width-insensitive; apostrophes dropped; every other non-alphanumeric run becomes one space.
    public static func fold(_ s: String) -> String {
        let t = s.precomposedStringWithCanonicalMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        var out = ""
        var pendingSpace = false
        for ch in t.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(ch)
            } else if ch == "'" || ch == "\u{2019}" || ch == "\u{02BC}" || ch == "\u{2018}" {
                continue
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    public static func tokens(_ folded: String) -> [String] { folded.split(separator: " ").map(String.init) }

    /// Names that stand for "somebody" rather than a person.
    static let generic: Set<String> = ["facebook user", "instagram user", "unknown user", "unknown sender", "unknown contact",
                                       "no name", "private number", "blocked number"]

    /// A matchable full name: at least two words that contain letters, and at least four letters in all.
    public static func isFullName(_ folded: String) -> Bool {
        if generic.contains(folded) { return false }
        let words = tokens(folded).filter { $0.unicodeScalars.contains { CharacterSet.letters.contains($0) } }
        let letters = folded.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return words.count >= 2 && letters >= 4
    }

    /// Letters and digits only, for comparing an Instagram username with a spelled-out name.
    public static func compact(_ s: String) -> String { fold(s).replacingOccurrences(of: " ", with: "") }
}

public struct NameEntry: Sendable, Hashable {
    public var name: String
    public var priority: Int
    public var origin: String
    public init(name: String, priority: Int, origin: String) { self.name = name; self.priority = priority; self.origin = origin }
}

/// What the matcher needs to know about one person-like handle (one that has a 1:1 conversation).
public struct MatchHandle: Sendable {
    public var id: Int64
    public var normalized: String
    public var kind: String
    public var threadID: Int64
    public var names: [NameEntry]
    public var messages: Int
    public var firstTsMs: Int64
    public var lastTsMs: Int64
    /// The Instagram username inferred for this handle (`handle_username`), shown as "@user" only when `usernameHigh`; otherwise it is
    /// a "possible" one. Never part of the handle's identity.
    public var igUsername: String?
    public var usernameHigh = false
    public init(id: Int64, normalized: String, kind: String, threadID: Int64 = 0, names: [NameEntry], messages: Int = 0, firstTsMs: Int64 = 0, lastTsMs: Int64 = 0,
                igUsername: String? = nil, usernameHigh: Bool = false) {
        self.id = id; self.normalized = normalized; self.kind = kind; self.threadID = threadID; self.names = names
        self.messages = messages; self.firstTsMs = firstTsMs; self.lastTsMs = lastTsMs
        self.igUsername = igUsername; self.usernameHigh = usernameHigh
    }

    public var isMessenger: Bool { kind == HandleKind.facebookName.rawValue }
    public var isInstagram: Bool { kind == HandleKind.instagramUser.rawValue }
    public var isGroupMe: Bool { kind == HandleKind.groupmeUser.rawValue }
    public var isSkype: Bool { kind == HandleKind.skypeUser.rawValue }
    public var isWhatsApp: Bool { kind == HandleKind.whatsappUser.rawValue }
    public var isSnapchat: Bool { kind == HandleKind.snapchatUser.rawValue }
    public var isPhoneLike: Bool { !isMessenger && !isInstagram && !isGroupMe && !isSkype && !isWhatsApp && !isSnapchat }
    /// Per-thread placeholder handles of deactivated accounts ("fb:facebook user#123") are never matched.
    public var isPlaceholder: Bool { normalized.contains("#") }

    /// Best name by priority, then more words (a full name beats a first name), then alphabetically. Placeholders and
    /// the folder-slug aliases older imports stored (`instagram-username`, removed by `archivectl ig-usernames`) are not display names.
    public var bestName: String? { Self.best(names.filter { $0.origin != "instagram-username" }) }
    /// A high-confidence real username ("@user"), else nil.
    public var username: String? { usernameHigh ? igUsername : nil }
    /// A low-confidence one, shown only as "possible @user".
    public var possibleUsername: String? { usernameHigh ? nil : igUsername }

    static func best(_ names: [NameEntry]) -> String? {
        names.filter { n in
            let t = n.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && t != "(Unknown)" && t != "null"
        }
        .sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            let ta = a.name.split(separator: " ").count, tb = b.name.split(separator: " ").count
            if ta != tb { return ta > tb }
            return a.name < b.name
        }
        .first?.name
    }
}

public struct MatchGroup: Sendable, Hashable {
    public var handleIDs: [Int64]            // sorted
    public var confidence: Double
    public var reason: String                // single | name | name-phones | ig-username
    public var name: String?
    /// The person id: the smallest handle id in the group.
    public var anchor: Int64 { handleIDs[0] }
}

public struct AmbiguousName: Sendable, Hashable {
    public var key: String                   // the folded name
    public var handleIDs: [Int64]
}

public struct MatchResult: Sendable {
    public var groups: [MatchGroup]
    public var ambiguous: [AmbiguousName]
}

public struct MatchOptions: Sendable {
    /// Two phone numbers with the same name are one person who changed numbers, unless both are busy at the same time.
    public var coexistMinOverlapDays = 30
    public var coexistMinMessages = 20
    public var minUsernameLength = 6
    public init() {}
}

/// Automatic person matching. Rules:
/// 1. Only handles with a 1:1 conversation take part; a handle's name is its best-priority name.
/// 2. Only a whole folded full name (two or more words) matches. First names alone never link; nicknames are not guessed.
/// 3. One name, one handle per service: phone/email handles with that name, the Messenger handle and the Instagram handle
///    become one person (confidence 0.9; 0.8 when several phone/email handles of the same name are joined).
/// 4. Two *phone numbers* with the same name that were both busy during the same stretch are two people who share a name:
///    the name is ambiguous, nobody is linked, and the name is listed.
/// 5. An Instagram handle with no usable full name matches its one-word display name (letters and digits only) against a unique
///    full name (confidence 0.6). Inferred usernames play no part here, so the stored person mapping does not move when they change.
public enum PeopleMatcher {
    public static func run(handles: [MatchHandle], options: MatchOptions = MatchOptions(),
                           coexist: (MatchHandle, MatchHandle) -> Bool) -> MatchResult {
        var parent: [Int64: Int64] = [:]
        func find(_ x: Int64) -> Int64 {
            var r = x
            while let p = parent[r], p != r { r = p }
            var c = x
            while let p = parent[c], p != r { parent[c] = r; c = p }
            return r
        }
        func union(_ a: Int64, _ b: Int64) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        for h in handles { parent[h.id] = h.id }
        var reason: [Int64: (String, Double)] = [:]      // by group root, strongest evidence last

        // Bucket by folded full name.
        var buckets: [String: [MatchHandle]] = [:]
        var unnamedInstagram: [MatchHandle] = []
        for h in handles where !h.isPlaceholder {
            let folded = h.bestName.map(NameMatching.fold) ?? ""
            if NameMatching.isFullName(folded) { buckets[folded, default: []].append(h) }
            else if h.isInstagram { unnamedInstagram.append(h) }
        }

        var ambiguous: [AmbiguousName] = []
        var ambiguousKeys = Set<String>()
        for (key, hs) in buckets.sorted(by: { $0.key < $1.key }) where hs.count >= 2 {
            let phones = hs.filter { $0.isPhoneLike }
            let msgr = hs.filter { $0.isMessenger }, ig = hs.filter { $0.isInstagram }, gm = hs.filter { $0.isGroupMe }, sk = hs.filter { $0.isSkype }, wa = hs.filter { $0.isWhatsApp }, sn = hs.filter { $0.isSnapchat }
            // Rule 4: two busy phone numbers at once are two people.
            var clash = false
            let numbers = phones.filter { $0.kind == HandleKind.phone.rawValue }
            outer: for i in 0..<numbers.count { for j in (i + 1)..<max(i + 1, numbers.count) where coexist(numbers[i], numbers[j]) { clash = true; break outer } }
            // Several Messenger/Instagram handles with one folded name cannot happen (the name is the handle) except
            // through manual splits; treat as ambiguous to be safe.
            if msgr.count > 1 || ig.count > 1 || gm.count > 1 || sk.count > 1 || wa.count > 1 || sn.count > 1 { clash = true }
            if clash {
                ambiguous.append(AmbiguousName(key: key, handleIDs: hs.map(\.id).sorted()))
                ambiguousKeys.insert(key)
                continue
            }
            let strength = phones.count >= 2 ? 0.8 : 0.9
            let ids = hs.map(\.id)
            for id in ids.dropFirst() { union(ids[0], id) }
            reason[find(ids[0])] = (phones.count >= 2 && msgr.isEmpty && ig.isEmpty && gm.isEmpty ? "name-phones" : "name", strength)
        }

        // Rule 5: Instagram usernames against unique full names.
        if !unnamedInstagram.isEmpty {
            var byCompact: [String: Set<String>] = [:]          // compact name -> folded name keys
            for key in buckets.keys { byCompact[NameMatching.compact(key), default: []].insert(key) }
            for h in unnamedInstagram.sorted(by: { $0.id < $1.id }) {
                let candidate = NameMatching.compact(h.bestName ?? "")
                guard candidate.count >= options.minUsernameLength, let keys = byCompact[candidate], keys.count == 1,
                      let key = keys.first, !ambiguousKeys.contains(key), let target = buckets[key]?.first else { continue }
                union(target.id, h.id)
                reason[find(target.id)] = ("ig-username", min(reason[find(target.id)]?.1 ?? 0.6, 0.6))
            }
        }

        var members: [Int64: [Int64]] = [:]
        for h in handles { members[find(h.id), default: []].append(h.id) }
        let byID = Dictionary(uniqueKeysWithValues: handles.map { ($0.id, $0) })
        var groups: [MatchGroup] = []
        for (root, ids) in members {
            let sorted = ids.sorted()
            let r = reason[find(root)]
            let name = MatchHandle.best(sorted.flatMap { byID[$0]?.names.filter { $0.origin != "instagram-username" } ?? [] })
            groups.append(MatchGroup(handleIDs: sorted, confidence: sorted.count == 1 ? 1.0 : (r?.1 ?? 0.9),
                                     reason: sorted.count == 1 ? "single" : (r?.0 ?? "name"), name: name))
        }
        groups.sort { $0.anchor < $1.anchor }
        return MatchResult(groups: groups, ambiguous: ambiguous.sorted { $0.key < $1.key })
    }
}
