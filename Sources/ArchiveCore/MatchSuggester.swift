import Foundation

// Suggestion engine for the review site. Pure: profiles in, ranked suggestions out. It never
// decides anything; every merge is the user's tap. Names are compared more loosely than the automatic matcher (which only links
// whole identical folded full names), so every result here is a *proposal* with human-readable reasons.

/// What the engine needs to know about one person.
public struct SuggestionProfile: Sendable {
    public var id: Int64
    /// Every display name of the person's handles (and a rename), usernames excluded.
    public var names: [String]
    /// Real Instagram usernames inferred with high confidence (`handle_username`).
    public var usernames: [String]
    /// Low-confidence ones ("possible @user"): they count, at `MatchSuggester.possibleUsernameWeight` of the strength of a real one.
    public var possibleUsernames: [String]
    /// Phone/email handles (their messages are SMS/iMessage).
    public var phoneHandles: Int
    public var hasMessenger: Bool
    public var hasInstagram: Bool
    public var messages: Int
    public var firstTsMs: Int64
    public var lastTsMs: Int64
    /// Normalized handle spellings, the stable keys rejections are stored under.
    public var handleKeys: [String]
    /// Persons that share a group thread with this one.
    public var coMembers: Set<Int64>
    /// Number of group threads the person is in.
    public var groupCount: Int
    public var hidden: Bool

    public init(id: Int64, names: [String], usernames: [String] = [], possibleUsernames: [String] = [], phoneHandles: Int = 0, hasMessenger: Bool = false, hasInstagram: Bool = false,
                messages: Int = 0, firstTsMs: Int64 = 0, lastTsMs: Int64 = 0, handleKeys: [String] = [], coMembers: Set<Int64> = [],
                groupCount: Int = 0, hidden: Bool = false) {
        self.id = id; self.names = names; self.usernames = usernames; self.possibleUsernames = possibleUsernames; self.phoneHandles = phoneHandles
        self.hasMessenger = hasMessenger; self.hasInstagram = hasInstagram; self.messages = messages
        self.firstTsMs = firstTsMs; self.lastTsMs = lastTsMs; self.handleKeys = handleKeys; self.coMembers = coMembers
        self.groupCount = groupCount; self.hidden = hidden
    }

    /// A person with no phone/email handle and at least one Meta handle: the first queue's subject.
    public var isMetaOnly: Bool { phoneHandles == 0 && (hasMessenger || hasInstagram) }
}

/// `whos` is not produced by the engine: it is the review service's third queue (Meta-only people with no suggestion).
public enum SuggestionQueue: String, Sendable, Codable { case crossService = "cross", duplicates = "dups", whos = "who" }

public struct SuggestionCandidate: Sendable, Hashable {
    public var personID: Int64
    public var score: Double
    public var reasons: [String]
    /// People who sit in group threads with both sides (the same company on both services).
    public var sharedGroupPeople: Int
    /// True when shared group chats are the only evidence (no name or username relation): always shown as "possible".
    public var groupOnly = false
    /// The group evidence after each group-mate and each side is weighted down by how sociable it is (see `MatchSuggester.mateWeight`).
    public var groupEvidence = 0.0
}

public struct Suggestion: Sendable, Hashable {
    public var queue: SuggestionQueue
    public var sourceID: Int64
    /// Best first.
    public var candidates: [SuggestionCandidate]
    public var topScore: Double { candidates.first?.score ?? 0 }
}

public struct SuggestionOptions: Sendable {
    public var minScore = 0.40
    public var maxCandidates = 5
    /// Group threads with more persons than this say little about who is who.
    public var maxGroupSize = 60
    /// When set, every candidate a rule removes is recorded here (numbers for the tuning report; no effect on the result).
    public var trace: SuggestionTrace?
    public init() {}
}

/// Which rule removed how many candidates, and from which cards. Filled by `MatchSuggester.suggest` when `SuggestionOptions.trace` is set.
public final class SuggestionTrace: @unchecked Sendable {
    public static let usernameRule = "username must match the whole username or a whole token"
    public static let conflictRule = "first or last names conflict"
    public static let hubRule = "group evidence only, not distinctive enough"
    /// Candidates removed, by rule.
    public private(set) var dropped: [String: Int] = [:]
    /// Card (queue and source person) -> the rules that removed at least one of its candidates.
    public private(set) var rulesByCard: [String: Set<String>] = [:]
    public init() {}
    public static func cardKey(_ queue: SuggestionQueue, _ source: Int64) -> String { "\(queue.rawValue):\(source)" }
    func record(rule: String, queue: SuggestionQueue, source: Int64) {
        dropped[rule, default: 0] += 1
        rulesByCard[Self.cardKey(queue, source), default: []].insert(rule)
    }
}

/// One name, tokenized for comparison.
struct NameForm {
    let original: String
    let tokens: [String]               // folded, suffixes and bare numbers dropped
    var joined: String { tokens.joined(separator: " ") }
    var first: String { tokens[0] }
    var last: String { tokens[tokens.count - 1] }
    /// Words after the first (a hyphenated or multi-word surname).
    var surnameTokens: [String] { Array(tokens.dropFirst()) }

    static let suffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv", "md", "phd"]

    init?(_ name: String) {
        let folded = NameMatching.fold(name)
        if NameMatching.generic.contains(folded) || folded == "unknown" || folded == "null" { return nil }
        let t = NameMatching.tokens(folded).filter { tok in
            !NameForm.suffixes.contains(tok) && tok.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        }
        guard !t.isEmpty else { return nil }
        original = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tokens = t
    }
}

public enum MatchSuggester {

    // MARK: nickname table (deliberately small; each line is one interchangeable set)

    static let nicknameSets: [[String]] = [
        ["alex", "alexander", "alexandra", "lex"], ["kate", "katie", "katherine", "catherine", "kathryn", "katy", "kat", "kathy"],
        ["will", "william", "bill", "billy", "willy"], ["mike", "michael", "mikey"], ["bob", "rob", "robert", "bobby", "robbie"],
        ["liz", "lizzie", "beth", "elizabeth", "eliza", "betty"], ["jim", "james", "jimmy"], ["tom", "thomas", "tommy"],
        ["dan", "daniel", "danny"], ["dave", "david"], ["matt", "matthew"], ["nick", "nicholas", "nicolas"],
        ["chris", "christopher"], ["steve", "steven", "stephen"], ["ben", "benjamin", "benny"], ["sam", "samuel", "samantha"],
        ["joe", "joseph", "joey"], ["tony", "anthony"], ["andy", "andrew", "drew"], ["jen", "jenny", "jennifer"],
        ["jess", "jessie", "jessica"], ["becca", "becky", "rebecca"], ["abby", "abigail"], ["pat", "patrick", "patricia"],
        ["rich", "rick", "ricky", "richard"], ["ed", "eddie", "edward"], ["greg", "gregory"], ["jake", "jacob"],
        ["josh", "joshua"], ["zach", "zack", "zachary"], ["tim", "timothy"], ["ken", "kenneth"], ["larry", "lawrence"],
        ["nate", "nathan", "nathaniel"], ["pete", "peter"], ["phil", "philip", "phillip"], ["maggie", "meg", "margaret", "peggy"],
        ["mandy", "amanda"], ["john", "johnny", "jon", "jonathan"], ["charlie", "charles", "chuck"], ["hank", "henry"],
        ["sue", "susan"], ["vicky", "victoria", "vicki"], ["debbie", "deborah", "deb"], ["theo", "theodore"],
    ]

    static let nickGroup: [String: Int] = {
        var m: [String: Int] = [:]
        for (i, set) in nicknameSets.enumerated() { for n in set { m[n] = i } }
        return m
    }()

    /// A token's identity for the shortlist: its nickname set, or itself.
    static func canon(_ token: String) -> String { nickGroup[token].map { "#\($0)" } ?? token }

    static func nickVariants(_ token: String) -> [String] { nickGroup[token].map { nicknameSets[$0] } ?? [token] }

    // MARK: name comparison

    /// How alike two names are (0 = nothing), with the reason. Only the first and last words carry the comparison, so a
    /// dropped or extra middle name does not matter.
    static func compare(_ a: NameForm, _ b: NameForm) -> (score: Double, reason: String)? {
        if a.tokens.count >= 2, a.joined == b.joined { return (1.0, "same full name") }
        if a.tokens.count == 1 || b.tokens.count == 1 {
            let (single, other) = a.tokens.count == 1 ? (a, b) : (b, a)
            if other.tokens.count == 1 {
                if single.first == other.first { return (0.28, "same first name only") }
                if canon(single.first) == canon(other.first) { return (0.22, "first names are nicknames of each other, no last name to check") }
                return nil
            }
            if single.first == other.first { return (0.30, "first name matches (the other side has only a first name)") }
            if canon(single.first) == canon(other.first), single.first != other.first { return (0.24, "first name matches as a nickname (the other side has only a first name)") }
            return nil
        }
        if Set(a.tokens) == Set(b.tokens) { return (0.95, "same words in a different order") }
        if a.first == b.last, a.last == b.first { return (0.90, "first and last name swapped") }

        // last name
        var lastRel = 0.0
        var lastNote = "same last name"
        if a.last == b.last { lastRel = 1.0 }
        else if a.last.count >= 3, b.surnameTokens.contains(a.last) { lastRel = 0.9; lastNote = "hyphenated or compound surname" }
        else if b.last.count >= 3, a.surnameTokens.contains(b.last) { lastRel = 0.9; lastNote = "hyphenated or compound surname" }
        guard lastRel > 0 else { return nil }

        // first name
        var firstRel = 0.0
        var firstNote = ""
        let fa = a.first, fb = b.first
        if fa == fb { firstRel = 1.0; firstNote = "same first name" }
        else if canon(fa) == canon(fb) { firstRel = 0.9; firstNote = "first names are nicknames (\(fa) / \(fb))" }
        else if min(fa.count, fb.count) >= 3, fa.hasPrefix(fb) || fb.hasPrefix(fa) { firstRel = 0.75; firstNote = "one first name is a short form of the other (\(fa) / \(fb))" }
        else if min(fa.count, fb.count) == 1, fa.first == fb.first { firstRel = 0.6; firstNote = "first initial matches" }
        guard firstRel > 0 else { return nil }

        var s = 0.45 + 0.5 * firstRel * lastRel
        var notes = [firstNote, lastNote]
        let ma = a.tokens.count - 2, mb = b.tokens.count - 2
        if ma > 0, mb > 0, Set(a.tokens[1..<(a.tokens.count - 1)]) != Set(b.tokens[1..<(b.tokens.count - 1)]), lastRel == 1.0 {
            s -= 0.10; notes.append("middle names differ")
        } else if ma != mb, lastRel == 1.0, ma <= 0 || mb <= 0 {
            notes.append("middle name dropped")
        }
        return (max(0, s), notes.joined(separator: ", "))
    }

    /// Highest score a proposal can reach on a name match alone (the "strong" label starts at 0.80).
    static let nameOnlyCeiling = 0.79

    // MARK: username comparison

    /// A low-confidence username is itself inferred from a display name, so what it says about a person counts for this fraction.
    static let possibleUsernameWeight = 0.6

    /// A username reduced to letters: the whole thing (digits, dots, underscores and the like removed) and its tokens (the runs of
    /// letters between dots, underscores, other separators and digits: `elin92shop` is `elin` and `shop`).
    static func usernameParts(_ username: String) -> (whole: String, tokens: [String]) {
        var tokens: [String] = []
        var cur = ""
        for ch in NameMatching.fold(username) {
            if ch.isLetter { cur.append(ch) } else if !cur.isEmpty { tokens.append(cur); cur = "" }
        }
        if !cur.isEmpty { tokens.append(cur) }
        return (tokens.joined(), tokens)
    }

    /// True when the whole username, one of its tokens, or a run of adjacent tokens joined (`e.lin.studio` holds `elin`) is exactly
    /// `shape`. Never a substring: a username that merely contains the letters of "e" + "lin" says nothing about a person named E. Lin.
    private static func isWholeOrToken(_ shape: String, _ parts: (whole: String, tokens: [String])) -> Bool {
        if parts.whole == shape || parts.tokens.contains(shape) { return true }
        let t = parts.tokens
        for i in 0..<t.count {
            var acc = t[i]
            for j in (i + 1)..<max(i + 1, t.count) {
                acc += t[j]
                if acc == shape { return true }
                if acc.count >= shape.count { break }
            }
        }
        return false
    }

    /// The username is exactly the person's full name (first + last or last + first, nothing else).
    static func usernameIsFullName(_ username: String, _ n: NameForm) -> Bool {
        guard n.tokens.count >= 2 else { return false }
        let w = usernameParts(username).whole
        return w == n.first + n.last || w == n.last + n.first
    }

    /// An Instagram username against a spelled-out name. "First initial + last name" and "first name + last initial" have to be the
    /// whole username or a whole token of it; the other shapes (first and last name, last name alone, first name alone) are
    /// still found inside the username.
    static func usernameScore(_ username: String, _ n: NameForm, substringShapes: Bool = false) -> (score: Double, reason: String)? {
        let parts = usernameParts(username)
        let u = NameMatching.compact(username)
        guard u.count >= 4 else { return nil }
        let firsts = nickVariants(n.first).filter { $0.count >= 3 }
        let hasFirst = firsts.contains { u.contains($0) }
        if n.tokens.count == 1 { return hasFirst && n.first.count >= 4 ? (0.20, "username contains the first name") : nil }
        let last = n.last
        let hasLast = last.count >= 3 && u.contains(last)
        if hasFirst && hasLast {
            // A short name (under 5 letters) is easily found inside a longer word (`joannaleeds` holds "ann" and "lee"): it has to be a
            // token or the start or end of the username, or first and last have to sit side by side as the whole of it or as tokens.
            func placed(_ part: String) -> Bool {
                part.count >= 5 ? u.contains(part) : (parts.tokens.contains(part) || parts.whole.hasPrefix(part) || parts.whole.hasSuffix(part))
            }
            func adjacent(_ f: String) -> Bool {
                [f + last, last + f].contains { isWholeOrToken($0, parts) || parts.whole.hasPrefix($0) || parts.whole.hasSuffix($0) }
            }
            if firsts.contains(where: { f in u.contains(f) && ((f.count >= 5 && last.count >= 5) || adjacent(f) || (placed(f) && placed(last))) }) {
                return (0.60, "username contains the first and last name")
            }
        }
        if hasLast, let i = n.first.first {
            let shape = String(i) + last
            if substringShapes ? u.contains(shape) : isWholeOrToken(shape, parts) { return (0.50, "username is first initial + last name") }
        }
        if hasFirst, n.first.count >= 4, let li = last.first,
           firsts.contains(where: { f in substringShapes ? u.contains(f + String(li)) : isWholeOrToken(f + String(li), parts) }) {
            return (0.35, "username is first name + last initial")
        }
        if hasLast, last.count >= 5 { return (0.30, "username contains the last name") }
        if hasFirst, n.first.count >= 4 { return (0.20, "username contains the first name") }
        return nil
    }

    // MARK: conflicts

    enum NameRelation { case compatible, changedSurname, conflict }

    /// A first name that can be the same person's: identical, nicknames, a short form, or an initial.
    private static func firstsCompatible(_ x: String, _ y: String) -> Bool {
        x == y || canon(x) == canon(y) || (min(x.count, y.count) >= 3 && (x.hasPrefix(y) || y.hasPrefix(x)))
            || (min(x.count, y.count) == 1 && x.first == y.first)
    }

    /// "Sadie M" and "Sadie Fakebrook": one last name is a single letter that starts the other, and the first names fit.
    private static func lastInitialFits(_ x: NameForm, _ y: NameForm) -> Bool {
        guard firstsCompatible(x.first, y.first) else { return false }
        func fits(_ short: NameForm, _ long: NameForm) -> Bool {
            short.last.count == 1 && long.last.count > 1 && long.surnameTokens.contains { $0.first == short.last.first }
        }
        return fits(x, y) || fits(y, x)
    }

    /// Both sides spell out a first and a last name and no pair of those spellings can be one person. `.conflict`: different first
    /// names that are neither nicknames, a short form, an initial, nor the same words reordered. `.changedSurname`: the first names
    /// are identical and only the last names differ (a married or changed name), which needs more evidence than a plain match.
    static func nameRelation(_ a: [NameForm], _ b: [NameForm]) -> NameRelation {
        let fa = a.filter { $0.tokens.count >= 2 }, fb = b.filter { $0.tokens.count >= 2 }
        guard !fa.isEmpty, !fb.isEmpty else { return .compatible }
        var sameFirst = false
        for x in fa { for y in fb {
            if compare(x, y) != nil { return .compatible }
            // A middle name used as the first name ("Mary Anne Smith" / "Anne Smith"): one name contains the other's words.
            let sx = Set(x.tokens), sy = Set(y.tokens)
            if sx.isSubset(of: sy) || sy.isSubset(of: sx) { return .compatible }
            if lastInitialFits(x, y) { return .compatible }
            if x.first == y.first { sameFirst = true }
        } }
        return sameFirst ? .changedSurname : .conflict
    }

    static func namesConflict(_ a: [NameForm], _ b: [NameForm]) -> Bool { nameRelation(a, b) != .compatible }

    // MARK: group evidence

    /// How much one group-mate says, by how many different people they share group chats with. Somebody in group chats with
    /// hundreds of people tells almost nothing about who is who; somebody with a handful tells a lot.
    static func mateWeight(coMembers n: Int) -> Double { 1.0 / (1.0 + Double(max(0, n - 8)) / 20.0) }

    /// The same idea for the two sides of a pair: a very social person overlaps with everybody by chance.
    static func sideFactor(coMembers n: Int) -> Double { 1.0 / (1.0 + Double(max(0, n - 40)) / 80.0) }

    /// Group evidence at least this heavy (after weighting) counts as distinctive on its own.
    static let distinctiveEvidence = 2.5
    /// A candidate that rests on group chats alone must have this many times the evidence of every other candidate.
    static let clearMargin = 1.5

    // MARK: engine

    private struct Prepared {
        var p: SuggestionProfile
        var forms: [NameForm]
        var canonTokens: Set<String>
        var usernames: [String]
        var possible: [String]
    }

    private static func pairKey(_ a: String, _ b: String) -> String { a < b ? a + "\u{1}" + b : b + "\u{1}" + a }

    /// Suggestions for both queues. `rejectedPairs` holds `pairKey` spellings of handle pairs the user said are not the same
    /// person; `ambiguousPairs` the person-id pairs the automatic matcher left apart on purpose (two busy numbers, one name).
    public static func suggest(profiles: [SuggestionProfile], rejectedPairs: Set<String> = [], ambiguousPairs: Set<String> = [],
                               options: SuggestionOptions = SuggestionOptions()) -> [Suggestion] {
        let prepared: [Prepared] = profiles.filter { !$0.hidden }.map { p in
            let forms = Array(Set(p.names)).sorted().compactMap { NameForm($0) }
            var ct = Set<String>()
            for f in forms { for t in f.tokens where t.count >= 2 { ct.insert(canon(t)) } }
            return Prepared(p: p, forms: forms, canonTokens: ct, usernames: p.usernames.filter { NameMatching.compact($0).count >= 4 },
                            possible: p.possibleUsernames.filter { NameMatching.compact($0).count >= 4 })
        }
        var byCanon: [String: [Int]] = [:]
        for (i, pr) in prepared.enumerated() { for t in pr.canonTokens { byCanon[t, default: []].append(i) } }

        // Username links: a username that contains a token of somebody's name (found by substring lookup, not by scanning).
        var tokenIndex: [String: [Int]] = [:]
        for (i, pr) in prepared.enumerated() {
            var seen = Set<String>()
            for f in pr.forms { for t in f.tokens where t.count >= 3 { for v in nickVariants(t) where v.count >= 3 { seen.insert(v) } } }
            for t in seen { tokenIndex[t, default: []].append(i) }
        }
        var userLinks: [Int: Set<Int>] = [:]
        for (i, pr) in prepared.enumerated() {
            for uname in pr.usernames + pr.possible {
                let u = Array(NameMatching.compact(uname))
                var seen = Set<String>()
                for start in 0..<u.count {
                    for len in 3...min(14, max(3, u.count - start)) where start + len <= u.count {
                        let sub = String(u[start..<(start + len)])
                        if seen.insert(sub).inserted, let hits = tokenIndex[sub] {
                            for j in hits where j != i { userLinks[i, default: []].insert(j); userLinks[j, default: []].insert(i) }
                        }
                    }
                }
            }
        }

        // Co-member index: for each person, who sits in a group with them, inverted.
        var coIndex: [Int64: [Int]] = [:]
        for (i, pr) in prepared.enumerated() { for m in pr.p.coMembers { coIndex[m, default: []].append(i) } }
        let groupsOf: [Int64: Int] = Dictionary(prepared.map { ($0.p.id, $0.p.groupCount) }, uniquingKeysWith: { a, _ in a })
        let coCount: [Int64: Int] = Dictionary(prepared.map { ($0.p.id, $0.p.coMembers.count) }, uniquingKeysWith: { a, _ in a })

        // How many people with a number go by each first name (nickname sets count as one): a bare first-name match against the
        // only one of them is worth more than against one of twelve.
        var firstNameHolders: [String: Set<Int64>] = [:]
        for pr in prepared where pr.p.phoneHandles > 0 { for f in pr.forms { firstNameHolders[canon(f.first), default: []].insert(pr.p.id) } }

        func rejected(_ a: SuggestionProfile, _ b: SuggestionProfile) -> Bool {
            guard !rejectedPairs.isEmpty else { return false }
            for x in a.handleKeys { for y in b.handleKeys where rejectedPairs.contains(pairKey(x, y)) { return true } }
            return false
        }

        struct Rules { var wholeUsernames = true; var conflicts = true; var hub = true }

        func score(_ s: Int, _ c: Int, sharedWeighted effective: Double, legacyWeighted: Double, sharedCount: Int, nameOnlyGate: Double?, rules: Rules = Rules()) -> SuggestionCandidate? {
            let a = prepared[s], b = prepared[c]
            // With the hub rule off (tracing only) the group evidence is weighted the way it was before: by how many groups a mate is in.
            let sharedWeighted = rules.hub ? effective : legacyWeighted
            var reasons: [String] = []
            var nameBest = 0.0, nameReason = ""
            for fa in a.forms { for fb in b.forms {
                if let r = compare(fa, fb), r.score > nameBest { nameBest = r.score; nameReason = r.reason }
            } }
            var userBest = 0.0, userReason = ""
            let sub = !rules.wholeUsernames
            for u in a.usernames { for f in b.forms { if let r = usernameScore(u, f, substringShapes: sub), r.score > userBest { userBest = r.score; userReason = "Instagram username: " + r.reason } } }
            for u in b.usernames { for f in a.forms { if let r = usernameScore(u, f, substringShapes: sub), r.score > userBest { userBest = r.score; userReason = "Instagram username: " + r.reason } } }
            // A possible username is weaker evidence: it is itself guessed from a display name.
            let pw = Self.possibleUsernameWeight
            for u in a.possible { for f in b.forms { if let r = usernameScore(u, f, substringShapes: sub), r.score * pw > userBest { userBest = r.score * pw; userReason = "possible Instagram username: " + r.reason } } }
            for u in b.possible { for f in a.forms { if let r = usernameScore(u, f, substringShapes: sub), r.score * pw > userBest { userBest = r.score * pw; userReason = "possible Instagram username: " + r.reason } } }
            if let gate = nameOnlyGate, nameBest < gate { return nil }

            var surnameChange = false
            if rules.conflicts {
                let rel = nameRelation(a.forms, b.forms)
                if rel != .compatible {
                    // A username that spells the other side's name (exactly, or containing its first and last name) is evidence the
                    // names are one person's; Adam X and Anya X are two people without it.
                    func spells(_ user: Prepared, _ other: Prepared) -> Bool {
                        user.usernames.contains { u in other.forms.contains { f in
                            usernameIsFullName(u, f) || (usernameScore(u, f)?.score ?? 0) >= 0.60
                        } }
                    }
                    let named = spells(a, b) || spells(b, a)
                    if rel == .conflict { if !named { return nil } }
                    else {
                        // Same first name, different last name: kept only with distinctive group chats or a username, and never above "possible".
                        if !named, sharedWeighted < Self.distinctiveEvidence { return nil }
                        surnameChange = true
                    }
                }
            }
            let groupOnly = nameBest == 0 && userBest == 0
            if rules.hub, groupOnly, sharedWeighted < Self.distinctiveEvidence { return nil }

            var identity = max(nameBest, userBest)
            if nameBest > 0, nameBest <= 0.30, b.p.phoneHandles > 0 {
                // first-name-only match: the candidate's whole name is a single word
                if let f = b.forms.first(where: { $0.tokens.count == 1 }), firstNameHolders[canon(f.first)]?.count == 1 {
                    nameBest += 0.15; identity = max(nameBest, userBest); nameReason += "; the only person with that first name among your numbers"
                }
            }
            if nameBest > 0 { reasons.append("Name: " + nameReason) }
            if userBest > 0 { reasons.append(userReason) }
            if nameBest > 0, userBest > 0 { identity = min(1.0, identity + 0.15 * min(nameBest, userBest)) }

            var groupPart = 0.0
            if sharedWeighted > 0 {
                groupPart = min(0.40, 0.08 + 0.065 * sharedWeighted)
                reasons.append("\(sharedCount) \(sharedCount == 1 ? "person is" : "people are") in group chats with both")
            }
            var total = identity + groupPart
            if total <= 0 { return nil }

            // Weak context (dates, volume) only sharpens a proposal that already stands on a name, username or group; it never
            // lifts a bare first-name match over the line.
            var weak = 0.0
            let standing = total >= options.minScore - 0.07
            let lo = max(a.p.firstTsMs, b.p.firstTsMs), hi = min(a.p.lastTsMs, b.p.lastTsMs)
            let day: Int64 = 86_400_000
            if standing, a.p.lastTsMs > 0, b.p.lastTsMs > 0 {
                if hi - lo >= 30 * day { weak += 0.04; reasons.append("active in the same period (\((hi - lo) / (30 * day)) months overlap)") }
                else if hi < lo, lo - hi <= 365 * day { weak += 0.03; reasons.append("one picks up within a year of where the other ends") }
            }
            let (big, small) = (max(a.p.messages, b.p.messages), min(a.p.messages, b.p.messages))
            if standing, small > 0, big <= 4 * small { weak += 0.02; reasons.append("similar message volume") }
            total += weak

            if a.p.coMembers.contains(b.p.id) {
                total -= 0.60
                reasons.append("they are in a group chat together, so probably two people")
            }
            if ambiguousPairs.contains(pairKey(String(a.p.id), String(b.p.id))) {
                total -= 0.25
                reasons.append("one name on two busy numbers: may really be two people")
            }
            // A name alone (no username, no shared group) is never "strong": two different people can share a name, and a careless tap
            // on a strong-looking card is the false-merge risk. It tops out at "likely".
            if userBest == 0, groupPart == 0, total > Self.nameOnlyCeiling { total = Self.nameOnlyCeiling }
            // Group chats alone are never more than "possible".
            if groupOnly {
                total = min(total, 0.54)
                reasons.append("shared group chats are the only evidence, so this is only a possibility")
            }
            if surnameChange {
                total = min(total, 0.54)
                reasons.append("last names differ (married or changed name?)")
            }
            guard total >= options.minScore else { return nil }
            var cand = SuggestionCandidate(personID: b.p.id, score: min(1.0, (total * 100).rounded() / 100), reasons: reasons, sharedGroupPeople: sharedCount)
            cand.groupOnly = groupOnly
            cand.groupEvidence = sharedWeighted
            return cand
        }

        /// Candidates of the current card that the earlier rules would also have produced (tracing only).
        var keptBefore = Set<Int64>()

        /// `score`, and when a trace is on, the rule that removed a candidate the earlier rules would have let through.
        func scoreTraced(_ queue: SuggestionQueue, _ s: Int, _ c: Int, sharedWeighted: Double, legacyWeighted: Double, sharedCount: Int, nameOnlyGate: Double?) -> SuggestionCandidate? {
            let now = score(s, c, sharedWeighted: sharedWeighted, legacyWeighted: legacyWeighted, sharedCount: sharedCount, nameOnlyGate: nameOnlyGate)
            guard let trace = options.trace else { return now }
            func with(_ r: Rules) -> SuggestionCandidate? { score(s, c, sharedWeighted: sharedWeighted, legacyWeighted: legacyWeighted, sharedCount: sharedCount, nameOnlyGate: nameOnlyGate, rules: r) }
            let before = with(Rules(wholeUsernames: false, conflicts: false, hub: false)) != nil
            if now != nil { if before { keptBefore.insert(prepared[c].p.id) }; return now }
            if before {
                // A duplicate card belongs to the busier of the two.
                let busierIsC = queue == .duplicates && (prepared[c].p.messages, -prepared[c].p.id) > (prepared[s].p.messages, -prepared[s].p.id)
                let src = prepared[busierIsC ? c : s].p.id
                if with(Rules(wholeUsernames: true, conflicts: false, hub: false)) == nil { trace.record(rule: SuggestionTrace.usernameRule, queue: queue, source: src) }
                else if with(Rules(wholeUsernames: true, conflicts: true, hub: false)) == nil { trace.record(rule: SuggestionTrace.conflictRule, queue: queue, source: src) }
                else { trace.record(rule: SuggestionTrace.hubRule, queue: queue, source: src) }
            }
            return now
        }

        var out: [Suggestion] = []

        // Queue 1: Meta-only persons against persons they could be the other half of.
        let sources = prepared.indices.filter { prepared[$0].p.isMetaOnly }.sorted {
            prepared[$0].p.messages != prepared[$1].p.messages ? prepared[$0].p.messages > prepared[$1].p.messages : prepared[$0].p.id < prepared[$1].p.id
        }
        for s in sources {
            let a = prepared[s]
            var shortlist = Set<Int>()
            for t in a.canonTokens { for j in byCanon[t] ?? [] { shortlist.insert(j) } }
            for j in userLinks[s] ?? [] { shortlist.insert(j) }
            // Group-mates of the source who are also group-mates of a candidate, each weighted by how few people they know.
            var shared: [Int: (w: Double, n: Int)] = [:]
            var legacy: [Int: Double] = [:]
            let sideS = Self.sideFactor(coMembers: a.p.coMembers.count)
            for m in a.p.coMembers {
                let w = Self.mateWeight(coMembers: coCount[m] ?? 0)
                let old = 1.0 / (1.0 + 0.15 * Double(max(0, (groupsOf[m] ?? 0) - 3)))
                for c in coIndex[m] ?? [] { var e = shared[c] ?? (0, 0); e.w += w; e.n += 1; shared[c] = e; legacy[c, default: 0] += old }
            }
            for c in shared.keys { shortlist.insert(c); shared[c]!.w *= sideS * Self.sideFactor(coMembers: prepared[c].p.coMembers.count) }
            keptBefore = []
            var cands: [SuggestionCandidate] = []
            var weightOf: [Int64: Double] = [:]
            for c in shortlist where c != s {
                let b = prepared[c]
                // The other half must not already hold the same Meta service, and has to bring something new: a number or the other service.
                if a.p.hasMessenger && b.p.hasMessenger { continue }
                if a.p.hasInstagram && b.p.hasInstagram { continue }
                if b.p.phoneHandles == 0 && !(b.p.hasMessenger || b.p.hasInstagram) { continue }
                // Two Meta-only persons: offer the pair once, from the busier side.
                if b.p.isMetaOnly, (b.p.messages, -b.p.id) > (a.p.messages, -a.p.id) { continue }
                if rejected(a.p, b.p) { continue }
                let sh = shared[c] ?? (0, 0)
                weightOf[b.p.id] = sh.w
                if let cand = scoreTraced(.crossService, s, c, sharedWeighted: sh.w, legacyWeighted: legacy[c] ?? 0, sharedCount: sh.n, nameOnlyGate: nil) { cands.append(cand) }
            }
            // A candidate that rests on group chats alone has to clearly beat every other candidate's group evidence; otherwise it is
            // the same few sociable people turning up on card after card.
            cands = cands.filter { cand in
                guard cand.groupOnly else { return true }
                let rival = weightOf.filter { $0.key != cand.personID }.map(\.value).max() ?? 0
                if cand.groupEvidence >= Self.clearMargin * rival { return true }
                if keptBefore.contains(cand.personID) { options.trace?.record(rule: SuggestionTrace.hubRule, queue: .crossService, source: a.p.id) }
                return false
            }
            cands.sort { $0.score != $1.score ? $0.score > $1.score : $0.personID < $1.personID }
            if !cands.isEmpty { out.append(Suggestion(queue: .crossService, sourceID: a.p.id, candidates: Array(cands.prefix(options.maxCandidates)))) }
        }

        // Queue 2: two persons with phone/email handles that are probably one (changed number, nickname, reordered name).
        let phoners = prepared.indices.filter { prepared[$0].p.phoneHandles > 0 && !prepared[$0].forms.isEmpty }
        var dupBySource: [Int: [SuggestionCandidate]] = [:]
        var byToken: [String: [Int]] = [:]
        for i in phoners { for t in prepared[i].canonTokens { byToken[t, default: []].append(i) } }
        var done = Set<String>()
        for s in phoners {
            let a = prepared[s]
            var shortlist = Set<Int>()
            for t in a.canonTokens { for j in byToken[t] ?? [] { shortlist.insert(j) } }
            for c in shortlist where c != s {
                let b = prepared[c]
                if a.p.hasMessenger && b.p.hasMessenger { continue }
                if a.p.hasInstagram && b.p.hasInstagram { continue }
                let key = pairKey(String(a.p.id), String(b.p.id))
                if done.contains(key) { continue }
                // Both need a real full name; a first-name-only match is not a duplicate.
                guard a.forms.contains(where: { $0.tokens.count >= 2 }), b.forms.contains(where: { $0.tokens.count >= 2 }) else { continue }
                if rejected(a.p, b.p) { continue }
                let shared = a.p.coMembers.intersection(b.p.coMembers)
                guard let cand = scoreTraced(.duplicates, s, c, sharedWeighted: Double(shared.count) * 0.5, legacyWeighted: Double(shared.count) * 0.5, sharedCount: shared.count, nameOnlyGate: 0.70) else { continue }
                done.insert(key)
                // The busier person is the card; the other is its candidate.
                let (src, dst) = (a.p.messages, -a.p.id) >= (b.p.messages, -b.p.id) ? (s, c) : (c, s)
                var cc = cand
                cc.personID = prepared[dst].p.id
                dupBySource[src, default: []].append(cc)
            }
        }
        for (src, cs) in dupBySource {
            let sorted = cs.sorted { $0.score != $1.score ? $0.score > $1.score : $0.personID < $1.personID }
            out.append(Suggestion(queue: .duplicates, sourceID: prepared[src].p.id, candidates: Array(sorted.prefix(options.maxCandidates))))
        }
        let messagesOf = Dictionary(prepared.map { ($0.p.id, $0.p.messages) }, uniquingKeysWith: { a, _ in a })
        out.sort { l, r in
            if l.queue != r.queue { return l.queue == .crossService }
            let lm = messagesOf[l.sourceID] ?? 0, rm = messagesOf[r.sourceID] ?? 0
            return lm != rm ? lm > rm : l.sourceID < r.sourceID
        }
        return out
    }

    static func cardKeyOf(_ s: Suggestion) -> String { SuggestionTrace.cardKey(s.queue, s.sourceID) }

    /// The key a rejection pair is stored and looked up under.
    public static func rejectionKey(_ a: String, _ b: String) -> String { pairKey(a, b) }
    public static func personPairKey(_ a: Int64, _ b: Int64) -> String { pairKey(String(a), String(b)) }
}
