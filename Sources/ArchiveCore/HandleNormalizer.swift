import Foundation

public enum HandleKind: String, Sendable {
    case phone, short, email, other
    case facebookName = "facebook-name"      // Messenger: a display name (the export carries nothing else)
    case instagramUser = "instagram-user"    // Instagram: a display name (the folder name's username is kept as an alias)
    case groupmeUser = "groupme-user"        // GroupMe: the account's numeric user id (display names are per group and change)
    case skypeUser = "skype-user"            // Skype: the account's Skype name (stable; display names change)
    case snapchatUser = "snapchat-user"      // Snapchat: the account's username (display names change)
    case whatsappUser = "whatsapp-user"      // WhatsApp: the account's JID user part (a phone number for people, a long id for groups)
    case aimUser = "aim-user"                // AIM (iChat transcripts, 2011-12): the screen name, or the email address used as one
    case telegramUser = "telegram-user"      // Telegram: the account's numeric user id (names change)
    case slackUser = "slack-user"            // Slack: workspace id + the member's user id (names change; ids are per workspace)
}

public struct NormalizedHandle: Hashable, Sendable {
    public let normalized: String
    public let kind: HandleKind
}

/// Phone/email normalization without a phone library. US-centric by design (a known limit): 10 digits or 11 with a
/// leading 1 become +1XXXXXXXXXX; anything with an explicit + or 00/011 international prefix becomes +digits; short
/// codes (up to 6 digits) and alphanumeric sender ids are kept raw; emails are lowercased.
public enum HandleNormalizer {
    /// Placeholders Android writes for "no address".
    static let placeholders: Set<String> = ["", "null", "insert-address-token", "unknown", "(unknown)", "undisclosed-recipients"]

    public static func normalize(_ raw: String) -> NormalizedHandle? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if placeholders.contains(trimmed.lowercased()) { return nil }
        if trimmed.contains("@") { return NormalizedHandle(normalized: trimmed.lowercased(), kind: .email) }

        var digits = ""
        digits.reserveCapacity(trimmed.count)
        var hasLetters = false
        for ch in trimmed.unicodeScalars {
            if ch.value >= 48 && ch.value <= 57 { digits.unicodeScalars.append(ch) }
            else if CharacterSet.letters.contains(ch) { hasLetters = true }
        }
        if hasLetters || digits.isEmpty {
            // Alphanumeric sender id (e.g. a bank name): keep as typed, lowercased for matching.
            return NormalizedHandle(normalized: trimmed.lowercased(), kind: .other)
        }
        let hasPlus = trimmed.hasPrefix("+")
        if hasPlus {
            return digits.count >= 7 ? NormalizedHandle(normalized: "+" + digits, kind: .phone)
                                     : NormalizedHandle(normalized: digits, kind: .short)
        }
        if digits.hasPrefix("011"), digits.count > 11 { return NormalizedHandle(normalized: "+" + digits.dropFirst(3), kind: .phone) }
        if digits.hasPrefix("00"), digits.count > 9 { return NormalizedHandle(normalized: "+" + digits.dropFirst(2), kind: .phone) }
        switch digits.count {
        case 10: return NormalizedHandle(normalized: "+1" + digits, kind: .phone)
        case 11 where digits.hasPrefix("1"): return NormalizedHandle(normalized: "+" + digits, kind: .phone)
        case 1...6: return NormalizedHandle(normalized: digits, kind: .short)
        case 7...9: return NormalizedHandle(normalized: digits, kind: .other)   // local numbers without an area code
        default: return NormalizedHandle(normalized: "+" + digits, kind: .phone)
        }
    }
}

/// Thread keys are the sorted set of participant handles (excluding me), so the same people always land in the same
/// thread regardless of source or ordering.
public enum ThreadKey {
    public static func key(for participants: [String]) -> String {
        let set = Set(participants).sorted()
        return set.isEmpty ? "unknown" : set.joined(separator: "|")
    }
}

/// A handle that is not a phone number or email: Messenger and Instagram people are identified by display name only.
/// The normalized form is service-prefixed (`fb:` / `ig:`) so it can never collide with a phone, an email or the other
/// service, then Unicode NFC and case-folded so the same name always lands on the same handle.
public struct ServiceHandle: Hashable, Sendable {
    public let kind: HandleKind
    public let normalized: String
    public let raw: String
    public init(kind: HandleKind, normalized: String, raw: String) { self.kind = kind; self.normalized = normalized; self.raw = raw }

    public static func facebook(name: String, unique: String? = nil) -> ServiceHandle {
        ServiceHandle(kind: .facebookName, normalized: "fb:" + foldName(name) + (unique.map { "#" + $0 } ?? ""), raw: name)
    }
    public static func instagram(name: String, unique: String? = nil) -> ServiceHandle {
        ServiceHandle(kind: .instagramUser, normalized: "ig:" + foldName(name) + (unique.map { "#" + $0 } ?? ""), raw: name)
    }

    /// GroupMe people are identified by their account's numeric user id (`gm:<id>`); `name` is the display name seen first.
    public static func groupme(userID: String, name: String) -> ServiceHandle {
        ServiceHandle(kind: .groupmeUser, normalized: "gm:" + userID, raw: name)
    }

    /// Skype people are identified by their Skype name (`sk:<name>`, lowercased); `name` is the display name seen first.
    public static func skype(skypeName: String, name: String) -> ServiceHandle {
        ServiceHandle(kind: .skypeUser, normalized: "sk:" + skypeName.lowercased(), raw: name)
    }

    /// Snapchat people are identified by their username (`sn:<username>`, lowercased); `name` is the display name.
    public static func snapchat(username: String, name: String) -> ServiceHandle {
        ServiceHandle(kind: .snapchatUser, normalized: "sn:" + username.lowercased(), raw: name)
    }

    /// Telegram people are identified by their numeric user id (`tg:<id>`); `name` is the name the store shows.
    public static func telegram(userID: Int64, name: String) -> ServiceHandle {
        ServiceHandle(kind: .telegramUser, normalized: "tg:\(userID)", raw: name)
    }

    /// Slack people are identified by workspace and user id (`slack:<team>:<user>`); `name` is the name the workspace shows.
    public static func slack(team: String, userID: String, name: String) -> ServiceHandle {
        ServiceHandle(kind: .slackUser, normalized: "slack:\(team):\(userID)", raw: name)
    }

    /// AIM people are identified by their screen name (`aim:<name>`, lowercased, spaces removed: AIM ignored both).
    public static func aim(screenName: String) -> ServiceHandle {
        ServiceHandle(kind: .aimUser, normalized: "aim:" + screenName.lowercased().filter { $0 != " " }, raw: screenName)
    }

    /// WhatsApp people are identified by the user part of their JID (`wa:<number>`); `name` is the name WhatsApp shows.
    public static func whatsapp(jidUser: String, name: String) -> ServiceHandle {
        ServiceHandle(kind: .whatsappUser, normalized: "wa:" + jidUser, raw: name)
    }

    /// NFC, case-folded, whitespace runs collapsed.
    public static func foldName(_ s: String) -> String {
        let nfc = s.precomposedStringWithCanonicalMapping
        let folded = nfc.folding(options: [.caseInsensitive], locale: nil)
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
