import Foundation

// Real Instagram usernames for Instagram handles.
//
// The export never pairs a display name with a username. A thread folder is `<slug>_<threadid>` where the slug is the lowercased
// display name with punctuation stripped, so it is *not* a handle. Real usernames appear only in the follower / following lists
// (`connections/followers_and_following/*.html`) and in story links inside messages (`instagram.com/stories/<user>/<id>`, which name
// the story's owner). So a username is inferred by comparing a display name with the pool of usernames the export lists, and is
// stored with a confidence and the method that found it. Handle identity (handle.id / handle.normalized) is never touched.

public enum IGConfidence: String, Sendable, Equatable { case high, low }

public struct IGUsernameMatch: Sendable, Equatable {
    public var username: String
    public var confidence: IGConfidence
    /// How it was found, e.g. `title-exact`, `name-first-last+story`, `story`, `low-contains-names`.
    public var method: String
}

/// The pool of usernames the export lists, indexed by their normalized spelling.
public struct IGUsernamePool: Sendable {
    public let usernames: [String]               // distinct, lowercased, sorted
    let norm: [String]                           // parallel to usernames: a-z0-9 only
    let byNorm: [String: [Int]]

    public init(_ names: some Sequence<String>) {
        let u = Array(Set(names.map { $0.lowercased() }.filter { !$0.isEmpty })).sorted()
        usernames = u
        norm = u.map { InstagramUsernames.normalize($0) }
        var m: [String: [Int]] = [:]
        for (i, n) in norm.enumerated() where !n.isEmpty { m[n, default: []].append(i) }
        byNorm = m
    }
    public var count: Int { usernames.count }
}

public enum InstagramUsernames {

    // MARK: normalization

    /// NFKD, lowercased, reduced to a-z and 0-9 (accents drop, punctuation, spaces and non-Latin letters vanish).
    public static func normalize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for sc in s.decomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            if (sc.value >= 97 && sc.value <= 122) || (sc.value >= 48 && sc.value <= 57) { out.append(sc) }
        }
        return String(out)
    }

    // MARK: resolution (pure)

    /// The username for one display name, given the story owners seen in that person's 1:1 threads (self already removed).
    public static func resolve(name: String, storyOwners: Set<String>, pool: IGUsernamePool) -> IGUsernameMatch? {
        let folded = NameMatching.fold(name)
        if NameMatching.generic.contains(folded) || folded == "unknown" || folded.isEmpty { return nil }
        let tokens = name.split(whereSeparator: { $0.isWhitespace }).map { normalize(String($0)) }.filter { !$0.isEmpty }
        let full = tokens.joined()
        let owners = Set(storyOwners.map { $0.lowercased() })
        let soleOwner: String? = owners.count == 1 ? owners.first : nil

        // High tiers: the name spells exactly one username.
        enum Tier { case hit(Int, String), ambiguous([Int]), none }
        func ids(_ shapes: [String]) -> [Int] {
            Array(Set(shapes.flatMap { pool.byNorm[$0] ?? [] })).sorted()
        }
        func tier(_ shapes: [String], _ method: String) -> Tier {
            let hits = ids(shapes)
            if hits.count == 1 { return .hit(hits[0], method) }
            return hits.isEmpty ? .none : .ambiguous(hits)
        }
        var outcome: Tier = .none
        if full.count >= 3 { outcome = tier([full], "title-exact") }
        if case .none = outcome, tokens.count >= 2, let f = tokens.first, let l = tokens.last {
            if f.count + l.count >= 3 { outcome = tier([f + l, l + f], "name-first-last") }
            if case .none = outcome, f.count + 1 >= 4 || l.count + 1 >= 4 {
                var shapes: [String] = []
                if f.count >= 3, let li = l.first { shapes.append(f + String(li)) }
                if l.count >= 3, let fi = f.first { shapes.append(String(fi) + l) }
                outcome = tier(shapes.filter { $0.count >= 4 }, "name-initial")
            }
        }

        switch outcome {
        case .hit(let i, let method):
            let u = pool.usernames[i]
            // A short single first name that equals a username is often a stranger's account: it needs a story that agrees.
            if tokens.count == 1, full.count <= 6, full.unicodeScalars.allSatisfy({ $0.value >= 97 && $0.value <= 122 }) {
                if soleOwner == u { return IGUsernameMatch(username: u, confidence: .high, method: method + "+story") }
                return IGUsernameMatch(username: u, confidence: .low, method: "low-short-name")
            }
            guard let s = soleOwner else { return IGUsernameMatch(username: u, confidence: .high, method: method) }
            // A story that agrees confirms the name match; one that contradicts is flagged, and the name match stands.
            return IGUsernameMatch(username: u, confidence: .high, method: method + (s == u ? "+story" : "+story-conflict"))
        case .ambiguous(let hits):
            // Several usernames fit the name; a lone story owner among them settles it, otherwise nothing is claimed.
            if let s = soleOwner, hits.contains(where: { pool.usernames[$0] == s }) {
                return IGUsernameMatch(username: s, confidence: .high, method: "story-among-names")
            }
            return nil
        case .none:
            // A lone story owner is often a third party's story that one side shared, so it stands alone only when the owner is a
            // listed account or its spelling overlaps the name; otherwise it is not claimed at all.
            if let s = soleOwner {
                let sn = normalize(s)
                let overlaps = tokens.contains { $0.count >= 3 && sn.contains($0) }
                if pool.usernames.contains(s) || overlaps { return IGUsernameMatch(username: s, confidence: .high, method: "story") }
            }
        }

        // Low tiers, strongest first. The first tier with any candidate decides: one candidate is a "possible", several is nothing.
        guard !full.isEmpty else { return nil }
        func lowOutcome(_ hits: [Int], _ method: String) -> IGUsernameMatch? {
            hits.count == 1 ? IGUsernameMatch(username: pool.usernames[hits[0]], confidence: .low, method: method) : nil
        }
        func scan(_ test: (String) -> Bool) -> [Int] { pool.norm.indices.filter { test(pool.norm[$0]) } }
        if tokens.count >= 2, let f = tokens.first, let l = tokens.last {
            if f.count >= 2, l.count >= 3 {
                let a = f + l, b = l + f
                let hits = scan { $0.contains(a) || $0.contains(b) }
                if !hits.isEmpty { return lowOutcome(hits, "low-contains-names") }
            }
            if l.count >= 4, let fi = f.first {
                let hits = scan { $0.contains(l) && $0.hasPrefix(String(fi)) }
                if !hits.isEmpty { return lowOutcome(hits, "low-last-name-initial") }
            }
        } else if tokens.count == 1, full.count >= 4 {
            let hits = scan { $0.hasPrefix(full) && $0 != full }
            if !hits.isEmpty { return lowOutcome(hits, "low-unique-prefix") }
        }
        if full.count >= 5 {
            var best = (ratio: 0.0, idx: -1), second = 0.0
            for i in pool.norm.indices {
                let u = pool.norm[i]
                let longest = max(u.count, full.count)
                if Double(abs(u.count - full.count)) / Double(longest) > 0.15 { continue }
                let r = similarity(full, u)
                if r > best.ratio { second = best.ratio; best = (r, i) } else if r > second { second = r }
            }
            if best.ratio >= 0.85, best.ratio - second >= 0.10 {
                return IGUsernameMatch(username: pool.usernames[best.idx], confidence: .low, method: "low-fuzzy")
            }
        }
        return nil
    }

    /// 1 - editDistance / longerLength.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.utf8), y = Array(b.utf8)
        if x.isEmpty && y.isEmpty { return 1 }
        var prev = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...max(y.count, 1) where !y.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    // MARK: reading the export

    static let listFiles = ["followers_1.html", "following.html", "close_friends.html", "recently_unfollowed_profiles.html",
                            "profiles_you've_favorited.html", "recent_follow_requests.html"]
    static let reservedPaths: Set<String> = ["p", "reel", "reels", "explore", "accounts", "stories", "tv", "direct", "_u", "about", "legal", "web"]

    /// The username in a profile link `https://www.instagram.com/<username>` (an `_u/` prefix is dropped); nil for any other link.
    static func username(fromHref href: String) -> String? {
        guard let r = href.range(of: "instagram.com/") else { return nil }
        var path = href[r.upperBound...].prefix(while: { $0 != "?" && $0 != "#" })
        if path.hasPrefix("_u/") { path = path.dropFirst(3) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 1 else { return nil }
        let u = parts[0].lowercased()
        guard !u.isEmpty, !reservedPaths.contains(u),
              u.unicodeScalars.allSatisfy({ ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || $0 == "." || $0 == "_" })
        else { return nil }
        return u
    }

    public static func loadPool(exportRoot: URL) -> IGUsernamePool {
        var all: [String] = []
        let dir = exportRoot.appendingPathComponent("connections/followers_and_following")
        for f in listFiles {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(f), options: .mappedIfSafe) else { continue }
            // Only the anchors: a link element's href, not the text around it.
            all += anchorHrefUsernames(d)
        }
        return IGUsernamePool(all)
    }

    /// Every profile link's username in one list page.
    static func anchorHrefUsernames(_ data: Data) -> [String] {
        var out: [String] = []
        let text = String(decoding: data, as: UTF8.self)
        var rest = text[...]
        while let r = rest.range(of: "href=\"") {
            rest = rest[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            if let u = username(fromHref: String(rest[..<end])) { out.append(u) }
            rest = rest[end...]
        }
        return out
    }

    /// The export owner's own username (personal_information.html: `Username<div><div>NAME</div>`), nil when not found.
    public static func selfUsername(exportRoot: URL) -> String? {
        let u = exportRoot.appendingPathComponent("personal_information/personal_information/personal_information.html")
        guard let d = try? Data(contentsOf: u, options: .mappedIfSafe) else { return nil }
        let text = String(decoding: d, as: UTF8.self)
        guard let r = text.range(of: "Username<div><div>") else { return nil }
        let name = text[r.upperBound...].prefix(while: { $0 != "<" }).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name.isEmpty ? nil : name
    }

    /// Owners named by `instagram.com/stories/<user>/<id>` links.
    static func storyOwner(_ link: String) -> String? {
        guard let r = link.range(of: "instagram.com/stories/") else { return nil }
        let u = link[r.upperBound...].prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" }).lowercased()
        return u.isEmpty || u == "highlights" ? nil : u
    }

    struct Evidence { var name: String; var storyOwners: Set<String> = []; var oneToOne = false }
    struct Scan { var evidence: [String: Evidence] = [:]; var ownerHandles: [String: Set<String>] = [:] }

    /// Per Instagram handle (normalized key): its display name and the story owners seen in its 1:1 threads. Groups add names only.
    static func scan(exportRoot: URL, me: String) -> Scan {
        let meFold = ServiceHandle.foldName(me)
        var out = Scan()
        for f in MetaImporter.enumerate(service: .instagram, exportRoot: exportRoot) {
            var title = ""
            var labels: [String: String] = [:], labelOrder: [String] = [], participantNames: [String] = []
            var owners: [String] = []
            for u in f.files {
                guard let data = try? Data(contentsOf: u, options: .alwaysMapped) else { continue }
                let page = MetaFileParser.parse(data: data)
                if title.isEmpty { title = page.title.trimmingCharacters(in: .whitespacesAndNewlines) }
                for b in page.blocks {
                    if let s = b.sender {
                        let k = ServiceHandle.foldName(s)
                        if labels[k] == nil { labels[k] = s; labelOrder.append(k) }
                    }
                    if let l = b.labelOnly, let list = MetaImporter.participantList(l) {
                        for n in list where !participantNames.contains(where: { ServiceHandle.foldName($0) == ServiceHandle.foldName(n) }) { participantNames.append(n) }
                    }
                    for link in b.shareLinks { if let o = storyOwner(link) { owners.append(o) } }
                }
            }
            let (others, _) = MetaImporter.determineOthers(labels: labels, labelOrder: labelOrder, participantNames: participantNames, title: title, meFold: meFold)
            for o in others {
                let k = o.fold
                if k == "facebook user" || k == "instagram user" || k == "unknown" { continue }     // per-thread placeholders: no identity
                let key = ServiceHandle.instagram(name: o.name).normalized
                var e = out.evidence[key] ?? Evidence(name: o.name)
                if others.count == 1 { e.oneToOne = true; e.storyOwners.formUnion(owners) }
                out.evidence[key] = e
                // every story owner seen in any thread (groups included) with this handle, to spot an owner shared across people
                for ow in owners { out.ownerHandles[ow, default: []].insert(key) }
            }
        }
        return out
    }

    /// Cross-handle check after resolution: a username that is high on two or more handles is dropped from all of them (the name
    /// match or story evidence is not unique to one person); a low assignment is dropped when the username is high on another handle.
    static func reconcile(_ results: [(Int64, IGUsernameMatch)]) -> (kept: [(Int64, IGUsernameMatch)], duplicateHighDropped: Int, lowDroppedForHigh: Int) {
        var highCount: [String: Int] = [:]
        for (_, m) in results where m.confidence == .high { highCount[m.username, default: 0] += 1 }
        let dupes = Set(highCount.filter { $0.value >= 2 }.keys)
        var step1: [(Int64, IGUsernameMatch)] = []
        var dropped1 = 0
        for r in results { if dupes.contains(r.1.username) { dropped1 += 1 } else { step1.append(r) } }
        let highNames = Set(step1.filter { $0.1.confidence == .high }.map { $0.1.username })
        var kept: [(Int64, IGUsernameMatch)] = []
        var dropped2 = 0
        for r in step1 { if r.1.confidence == .low && highNames.contains(r.1.username) { dropped2 += 1 } else { kept.append(r) } }
        return (kept, dropped1, dropped2)
    }

    // MARK: apply

    public struct Report: Sendable, Equatable {
        public var poolUsernames = 0
        public var selfUsername: Bool = false
        public var instagramHandles = 0          // all kind = instagram-user handles
        public var placeholders = 0              // deleted accounts: no identity, never resolved
        public var high = 0, low = 0, none = 0   // over the named (non-placeholder) handles
        public var byMethod: [String: Int] = [:]
        public var storyConflicts = 0
        public var duplicateHighDropped = 0      // assignments removed because one username was high on 2+ handles
        public var lowDroppedForHigh = 0         // low assignments removed because the username is high on another handle
        public var legacyAliasesRemoved = 0
        public var written = false
    }

    /// Resolves usernames for every Instagram handle in `db` from the export and stores them (`handle_username` is replaced for
    /// Instagram handles; the old folder-slug aliases are removed). With `write: false` nothing is changed.
    @discardableResult
    public static func apply(exportRoot: URL, into db: Database, me: String? = nil, write: Bool = true) throws -> Report {
        if write { try Schema.migrate(db) }
        let who: String
        if let me { who = me }
        else if let m = try MetaImporter.metaValue(db, "instagram.me") { who = m }
        else { throw ArchiveError("this archive has no Instagram import yet (no instagram.me recorded)") }

        var report = Report()
        let pool = loadPool(exportRoot: exportRoot)
        report.poolUsernames = pool.count
        let selfUser = selfUsername(exportRoot: exportRoot)
        report.selfUsername = selfUser != nil
        let scanned = scan(exportRoot: exportRoot, me: who)
        var evidence = scanned.evidence

        // Without the owner's own username, the owner of the most story links across threads is taken as the owner (a story shared back
        // and forth in many conversations). Needs real repetition, else nothing is dropped.
        var selfNames: Set<String> = selfUser.map { [$0] } ?? []
        if selfNames.isEmpty {
            var threadsPer: [String: Int] = [:]
            for e in evidence.values { for o in e.storyOwners { threadsPer[o, default: 0] += 1 } }
            if let top = threadsPer.max(by: { $0.value < $1.value }), top.value >= 5 { selfNames = [top.key] }
        }
        for k in evidence.keys { evidence[k]!.storyOwners.subtract(selfNames) }
        // A story owner who turns up in other people's threads is not this person's account (a third party one side shared).
        for k in evidence.keys {
            evidence[k]!.storyOwners = evidence[k]!.storyOwners.filter { (scanned.ownerHandles[$0]?.count ?? 0) <= 1 }
        }

        var handles: [(id: Int64, normalized: String)] = []
        let hs = try db.prepare("SELECT id, normalized FROM handle WHERE kind = ? ORDER BY id")
        hs.bind(1, HandleKind.instagramUser.rawValue)
        while try hs.step() { handles.append((hs.int(0), hs.string(1) ?? "")) }
        hs.reset()
        report.instagramHandles = handles.count

        var results: [(Int64, IGUsernameMatch)] = []
        var named = 0
        for h in handles {
            if h.normalized.contains("#") { report.placeholders += 1; continue }
            named += 1
            if let e = evidence[h.normalized], let m = resolve(name: e.name, storyOwners: e.storyOwners, pool: pool) { results.append((h.id, m)) }
        }
        let rec = reconcile(results)
        results = rec.kept
        report.duplicateHighDropped = rec.duplicateHighDropped
        report.lowDroppedForHigh = rec.lowDroppedForHigh
        for (_, m) in results {
            if m.confidence == .high { report.high += 1 } else { report.low += 1 }
            report.byMethod[m.confidence.rawValue + ":" + m.method, default: 0] += 1
            if m.method.hasSuffix("+story-conflict") { report.storyConflicts += 1 }
        }
        report.none = named - results.count
        report.legacyAliasesRemoved = Int(try db.scalarInt("SELECT count(*) FROM contact_name WHERE origin = 'instagram-username'"))
        guard write else { return report }

        try db.transaction {
            try db.exec("DELETE FROM handle_username WHERE handle_id IN (SELECT id FROM handle WHERE kind = 'instagram-user')")
            let ins = try db.prepare("INSERT INTO handle_username(handle_id, username, confidence, method) VALUES (?,?,?,?)")
            for (id, m) in results {
                ins.bind(1, id).bind(2, m.username).bind(3, m.confidence.rawValue).bind(4, m.method)
                try ins.run()
            }
            // The folder slug used to be stored as a "username" alias; it was the display name, not a handle.
            try db.exec("DELETE FROM contact_name WHERE origin = 'instagram-username'")
        }
        report.written = true
        return report
    }
}
