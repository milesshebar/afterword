import Foundation

/// One handle as a member of a person.
public struct PersonHandle: Sendable, Hashable, Identifiable {
    public var id: Int64 { handleID }
    public var handleID: Int64
    public var normalized: String
    public var raw: String
    public var kind: String
    public var name: String?
    /// Instagram handles: the inferred real username ("@user", high confidence) and a low-confidence one ("possible @user"). Else nil.
    public var username: String?
    public var possibleUsername: String?
    public var threadIDs: [Int64]
    public var messages: Int
    /// `auto` (matched by name) or `manual` (joined or split by the user).
    public var origin: String
    public var confidence: Double
    public var reason: String
    /// Messenger / Instagram for those handles; nil for phone numbers and emails (their messages are SMS or iMessage).
    public var service: ServiceKey? {
        if kind == HandleKind.facebookName.rawValue { return .messenger }
        if kind == HandleKind.instagramUser.rawValue { return .instagram }
        if kind == HandleKind.groupmeUser.rawValue { return .groupme }
        if kind == HandleKind.skypeUser.rawValue { return .skype }
        if kind == HandleKind.whatsappUser.rawValue { return .whatsapp }
        if kind == HandleKind.snapchatUser.rawValue { return .snapchat }
        if kind == HandleKind.aimUser.rawValue { return .aim }
        if kind == HandleKind.telegramUser.rawValue { return .telegram }
        if kind == HandleKind.slackUser.rawValue { return .slack }
        return nil
    }
}

/// A person: one or more handles whose 1:1 conversations read as one.
public struct Person: Sendable, Identifiable, Hashable {
    /// The smallest handle id among the handles. Stable while the membership is; ids are not kept across merges and splits.
    public var id: Int64
    public var handles: [PersonHandle]
    public var archiveName: String?
    public var renamedTo: String?
    public var hidden: Bool
    public var name: String? { renamedTo ?? archiveName }
    public var threadIDs: [Int64] { handles.flatMap(\.threadIDs).sorted() }
    /// Real usernames (high confidence), sorted, and the possible ones (low), which are not repeated among the real ones.
    public var usernames: [String] { Array(Set(handles.compactMap(\.username))).sorted() }
    public var possibleUsernames: [String] { Array(Set(handles.compactMap(\.possibleUsername)).subtracting(usernames)).sorted() }
    public var messages: Int { handles.reduce(0) { $0 + $1.messages } }
    public var hasManualEdits: Bool { renamedTo != nil || hidden || handles.contains { $0.origin == "manual" } }
}

/// The effective person mapping: automatic matches with the user's corrections applied.
public struct PeopleIndex: Sendable {
    public enum Source: String, Sendable { case stored, computed }
    public var persons: [Int64: Person] = [:]
    public var personOfHandle: [Int64: Int64] = [:]
    public var personOfThread: [Int64: Int64] = [:]
    public var ambiguous: [AmbiguousName] = []
    public var source: Source = .computed
    public var overrides = OverrideSet()

    public static let empty = PeopleIndex()

    public func person(ofThread t: Int64) -> Person? { personOfThread[t].flatMap { persons[$0] } }
    public func person(ofHandle h: Int64) -> Person? { personOfHandle[h].flatMap { persons[$0] } }
    public func person(normalized n: String) -> Person? { persons.values.first { $0.handles.contains { $0.normalized == n } } }

    /// Applies `overrides` to `auto` groups over `handles`.
    static func build(handles: [MatchHandle], threadsByHandle: [Int64: [Int64]], raws: [Int64: String], auto: [MatchGroup],
                      ambiguous: [AmbiguousName], overrides: OverrideSet, source: Source) -> PeopleIndex {
        let byID = Dictionary(handles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let idOf = Dictionary(handles.map { ($0.normalized, $0.id) }, uniquingKeysWith: { a, _ in a })
        var parent: [Int64: Int64] = [:]
        for h in handles { parent[h.id] = h.id }
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
        var autoInfo: [Int64: (Double, String)] = [:]
        let detached = Set(overrides.detached.compactMap { idOf[$0] })
        for g in auto {
            let ids = g.handleIDs.filter { byID[$0] != nil }
            for id in ids { autoInfo[id] = (g.confidence, g.reason) }
            let free = ids.filter { !detached.contains($0) }
            for id in free.dropFirst() { union(free[0], id) }
        }
        var manual = detached
        for l in overrides.links where l.count == 2 {
            guard let a = idOf[l[0]], let b = idOf[l[1]] else { continue }
            union(a, b); manual.insert(a); manual.insert(b)
        }

        var members: [Int64: [Int64]] = [:]
        for h in handles { members[find(h.id), default: []].append(h.id) }
        var out = PeopleIndex()
        out.source = source
        out.overrides = overrides
        out.ambiguous = ambiguous
        for (_, ids) in members {
            let sorted = ids.sorted()
            let hs: [PersonHandle] = sorted.compactMap { id in
                guard let h = byID[id] else { return nil }
                let isManual = manual.contains(id)
                let info = autoInfo[id]
                return PersonHandle(handleID: id, normalized: h.normalized, raw: raws[id] ?? h.normalized, kind: h.kind, name: h.bestName,
                                    username: h.username, possibleUsername: h.possibleUsername, threadIDs: threadsByHandle[id] ?? [h.threadID], messages: h.messages,
                                    origin: isManual ? "manual" : "auto", confidence: isManual ? 1.0 : (sorted.count == 1 ? 1.0 : (info?.0 ?? 0.9)),
                                    reason: isManual ? "manual" : (sorted.count == 1 ? "single" : (info?.1 ?? "name")))
            }
            guard let first = hs.first else { continue }
            let all = sorted.flatMap { byID[$0]?.names.filter { $0.origin != "instagram-username" } ?? [] }
            let renamed = sorted.compactMap { id in byID[id].flatMap { overrides.renames[$0.normalized] } }.max { $0.at < $1.at }
            let hidden = !sorted.isEmpty && sorted.allSatisfy { id in byID[id].map { overrides.hidden.contains($0.normalized) } ?? false }
            let p = Person(id: first.handleID, handles: hs, archiveName: MatchHandle.best(all), renamedTo: renamed?.name, hidden: hidden)
            out.persons[p.id] = p
            for h in hs {
                out.personOfHandle[h.handleID] = p.id
                for t in h.threadIDs { out.personOfThread[t] = p.id }
            }
        }
        return out
    }
}

/// Reading and writing the automatic matches in `archive.sqlite` (`person`, `person_handle`, `person_ambiguous`).
public enum PeopleStore {
    struct Gathered {
        var handles: [MatchHandle]
        var threadsByHandle: [Int64: [Int64]]
        var raws: [Int64: String]
    }

    /// The inferred Instagram usernames by handle id (empty when the archive predates `handle_username`).
    static func usernames(db: Database) throws -> [Int64: (name: String, high: Bool)] {
        guard try db.tableExists("handle_username") else { return [:] }
        var out: [Int64: (name: String, high: Bool)] = [:]
        let st = try db.prepare("SELECT handle_id, username, confidence FROM handle_username")
        while try st.step() { out[st.int(0)] = (st.string(1) ?? "", st.string(2) == IGConfidence.high.rawValue) }
        return out
    }

    /// Every handle that has a 1:1 conversation with at least one message, with its names and activity.
    static func gather(db: Database, extraNames: [String: String] = [:]) throws -> Gathered {
        var names: [Int64: [NameEntry]] = [:]
        let nst = try db.prepare("SELECT handle_id, name, priority, origin FROM contact_name")
        while try nst.step() {
            names[nst.int(0), default: []].append(NameEntry(name: nst.string(1) ?? "", priority: Int(nst.int(2)), origin: nst.string(3) ?? ""))
        }
        let igUsers = try usernames(db: db)
        var byHandle: [Int64: MatchHandle] = [:]
        var threads: [Int64: [Int64]] = [:]
        var raws: [Int64: String] = [:]
        let st = try db.prepare("""
            SELECT h.id, h.normalized, h.kind, h.raw, t.id, a.n, a.lo, a.hi
            FROM thread t
            JOIN thread_member tm ON tm.thread_id = t.id
            JOIN handle h ON h.id = tm.handle_id
            JOIN (SELECT thread_id, count(*) n, min(ts_ms) lo, max(ts_ms) hi FROM message WHERE canonical_id IS NULL GROUP BY thread_id) a ON a.thread_id = t.id
            WHERE t.is_group = 0
            ORDER BY h.id, t.id
            """)
        while try st.step() {
            let id = st.int(0)
            raws[id] = st.string(3)
            threads[id, default: []].append(st.int(4))
            if var h = byHandle[id] {
                h.messages += Int(st.int(5)); h.firstTsMs = min(h.firstTsMs, st.int(6)); h.lastTsMs = max(h.lastTsMs, st.int(7))
                byHandle[id] = h
            } else {
                var ns = names[id] ?? []
                if let extra = extraNames[st.string(1) ?? ""] { ns.append(NameEntry(name: extra, priority: ContactPriority.contactsApp, origin: ContactOrigin.contactsApp)) }
                byHandle[id] = MatchHandle(id: id, normalized: st.string(1) ?? "", kind: st.string(2) ?? "other", threadID: st.int(4), names: ns,
                                           messages: Int(st.int(5)), firstTsMs: st.int(6), lastTsMs: st.int(7),
                                           igUsername: igUsers[id]?.name, usernameHigh: igUsers[id]?.high ?? false)
            }
        }
        return Gathered(handles: byHandle.values.sorted { $0.id < $1.id }, threadsByHandle: threads, raws: raws)
    }

    /// Runs the matcher over the archive without storing anything.
    static func compute(db: Database, g: Gathered, options: MatchOptions = MatchOptions()) throws -> MatchResult {
        let count = try db.prepare("SELECT count(*) FROM message WHERE thread_id = ? AND canonical_id IS NULL AND ts_ms BETWEEN ? AND ?")
        func busy(_ h: MatchHandle, _ lo: Int64, _ hi: Int64) -> Int {
            var n = 0
            for t in g.threadsByHandle[h.id] ?? [h.threadID] {
                count.bind(1, t).bind(2, lo).bind(3, hi)
                if (try? count.step()) == true { n += Int(count.int(0)) }
                count.reset()
            }
            return n
        }
        return PeopleMatcher.run(handles: g.handles, options: options) { a, b in
            let lo = max(a.firstTsMs, b.firstTsMs), hi = min(a.lastTsMs, b.lastTsMs)
            guard hi - lo >= Int64(options.coexistMinOverlapDays) * 86_400_000 else { return false }
            return busy(a, lo, hi) >= options.coexistMinMessages && busy(b, lo, hi) >= options.coexistMinMessages
        }
    }

    public static func hasTables(_ db: Database) -> Bool {
        (try? db.tableExists("person_handle")) == true
    }

    /// Stored automatic groups, or nil when the archive predates them or no match has been run.
    static func storedGroups(db: Database) throws -> (groups: [MatchGroup], ambiguous: [AmbiguousName])? {
        guard hasTables(db), try db.scalarString("SELECT value FROM meta WHERE key = 'people.matched_at'") != nil else { return nil }
        var by: [Int64: (ids: [Int64], conf: Double, reason: String)] = [:]
        let st = try db.prepare("SELECT person_id, handle_id, confidence, reason FROM person_handle ORDER BY person_id, handle_id")
        while try st.step() {
            var e = by[st.int(0)] ?? ([], st.double(2), st.string(3) ?? "name")
            e.ids.append(st.int(1))
            by[st.int(0)] = e
        }
        let groups = by.values.map { MatchGroup(handleIDs: $0.ids.sorted(), confidence: $0.conf, reason: $0.reason, name: nil) }
        var amb: [String: [Int64]] = [:]
        let ast = try db.prepare("SELECT name_key, handle_id FROM person_ambiguous ORDER BY name_key, handle_id")
        while try ast.step() { amb[ast.string(0) ?? "", default: []].append(ast.int(1)) }
        return (groups, amb.map { AmbiguousName(key: $0.key, handleIDs: $0.value) }.sorted { $0.key < $1.key })
    }

    /// Re-runs the automatic matching and replaces the stored result. Manual corrections live elsewhere and are untouched.
    @discardableResult
    public static func rematch(db: Database, options: MatchOptions = MatchOptions()) throws -> RematchReport {
        let g = try gather(db: db)
        let r = try compute(db: db, g: g, options: options)
        try db.transaction {
            try db.exec("DELETE FROM person_ambiguous")
            try db.exec("DELETE FROM person_handle")
            try db.exec("DELETE FROM person")
            let insP = try db.prepare("INSERT INTO person(id, display_name, handle_count, confidence, reason) VALUES (?,?,?,?,?)")
            let insH = try db.prepare("INSERT INTO person_handle(person_id, handle_id, origin, confidence, reason) VALUES (?,?, 'auto', ?, ?)")
            for grp in r.groups {
                insP.bind(1, grp.anchor).bind(2, grp.name).bind(3, grp.handleIDs.count).bind(4, grp.confidence).bind(5, grp.reason)
                try insP.run()
                for h in grp.handleIDs { insH.bind(1, grp.anchor).bind(2, h).bind(3, grp.confidence).bind(4, grp.reason); try insH.run() }
            }
            let insA = try db.prepare("INSERT INTO person_ambiguous(name_key, handle_id) VALUES (?,?)")
            for a in r.ambiguous { for h in a.handleIDs { insA.bind(1, a.key).bind(2, h); try insA.run() } }
            try db.exec("INSERT OR REPLACE INTO meta(key, value) VALUES ('people.matched_at', '\(Int64(Date().timeIntervalSince1970))')")
        }
        let linked = r.groups.filter { $0.handleIDs.count > 1 }
        return RematchReport(handles: g.handles.count, persons: r.groups.count, linkedPersons: linked.count,
                             linkedHandles: linked.reduce(0) { $0 + $1.handleIDs.count }, ambiguousNames: r.ambiguous.count,
                             ambiguousHandles: r.ambiguous.reduce(0) { $0 + $1.handleIDs.count })
    }

    public struct RematchReport: Sendable {
        public var handles: Int, persons: Int, linkedPersons: Int, linkedHandles: Int, ambiguousNames: Int, ambiguousHandles: Int
    }

    /// The effective mapping for an archive: the stored automatic matches when present (else computed on the spot, so a
    /// read-only archive from before the person tables works), with `overrides` applied. `extraNames` (normalized handle ->
    /// name, for example from Contacts.app) forces a fresh computation that counts them as top-priority names.
    public static func index(db: Database, overrides: OverrideSet, extraNames: [String: String] = [:]) throws -> PeopleIndex {
        let g = try gather(db: db, extraNames: extraNames)
        if extraNames.isEmpty, let stored = try storedGroups(db: db) {
            return PeopleIndex.build(handles: g.handles, threadsByHandle: g.threadsByHandle, raws: g.raws, auto: stored.groups,
                                     ambiguous: stored.ambiguous, overrides: overrides, source: .stored)
        }
        let r = try compute(db: db, g: g)
        return PeopleIndex.build(handles: g.handles, threadsByHandle: g.threadsByHandle, raws: g.raws, auto: r.groups,
                                 ambiguous: r.ambiguous, overrides: overrides, source: .computed)
    }
}

/// Edits to the effective mapping, expressed on people (ids from a `PeopleIndex`) and stored as overrides.
public enum PeopleActions {
    /// Joins persons into one. Returns the id of the resulting person.
    @discardableResult
    public static func merge(_ ids: [Int64], in index: PeopleIndex, overrides: PeopleOverrides) throws -> Int64? {
        let people = ids.compactMap { index.persons[$0] }
        guard people.count >= 2 else { return people.first?.id }
        let first = people[0].handles.map(\.normalized)
        for p in people.dropFirst() { try overrides.merge(first, with: p.handles.map(\.normalized)) }
        // Merged people share all cross pairs; link the later ones to each other as well.
        if people.count > 2 {
            for i in 1..<people.count { for j in (i + 1)..<people.count { try overrides.merge(people[i].handles.map(\.normalized), with: people[j].handles.map(\.normalized)) } }
        }
        return people.flatMap(\.handles).map(\.handleID).min()
    }

    /// Takes the given handles out of a person, as one new person. At least one handle must stay behind.
    @discardableResult
    public static func split(person id: Int64, handleIDs: [Int64], in index: PeopleIndex, overrides: PeopleOverrides) throws -> (stays: Int64, splitOff: Int64)? {
        guard let p = index.persons[id] else { return nil }
        let off = p.handles.filter { handleIDs.contains($0.handleID) }
        let stay = p.handles.filter { !handleIDs.contains($0.handleID) }
        guard !off.isEmpty, !stay.isEmpty else { return nil }
        try overrides.split(off.map(\.normalized), together: true)
        return (stay.map(\.handleID).min()!, off.map(\.handleID).min()!)
    }

    public static func rename(person id: Int64, to name: String?, in index: PeopleIndex, overrides: PeopleOverrides) throws {
        guard let p = index.persons[id] else { return }
        try overrides.rename(p.handles.map(\.normalized), to: name)
    }

    public static func setHidden(person id: Int64, _ hidden: Bool, in index: PeopleIndex, overrides: PeopleOverrides) throws {
        guard let p = index.persons[id] else { return }
        try overrides.setHidden(p.handles.map(\.normalized), hidden)
    }

    public static func reset(person id: Int64, in index: PeopleIndex, overrides: PeopleOverrides) throws {
        guard let p = index.persons[id] else { return }
        try overrides.reset(p.handles.map(\.normalized))
    }
}
