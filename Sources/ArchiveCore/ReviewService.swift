import Foundation

// The state and operations behind the review site (`archivectl serve`). archive.sqlite is only ever opened read-only; every
// decision goes to people.sqlite through the same override code the app uses, so the app reflects it on its next load.

public struct ServiceBadge: Codable, Sendable, Equatable { public var key: String; public var label: String; public var count: Int }

public struct PersonBrief: Codable, Sendable, Equatable {
    /// A handle id of the person (its smallest at the time the page was built). The API takes it back to find the person.
    public var anchor: Int64
    public var name: String?
    public var altNames: [String]
    /// Real Instagram usernames (high confidence), shown as "@user".
    public var usernames: [String]
    /// Low-confidence ones, shown only as "possible @user".
    public var possibleUsernames: [String]
    public var services: [ServiceBadge]
    public var phones: [String]          // masked: last four digits only
    public var messages: Int
    public var firstTs: Int64?
    public var lastTs: Int64?
    public var groups: Int
    public var renamed: Bool
}

/// Who is around a person in group chats. For a candidate: the group-mates both sides share (names, most distinctive first, at most
/// `ReviewService.maxMates`) and, per side, the titles of up to `ReviewService.maxThreads` of the group threads that hold them. For a
/// Who's-this card: the person's own group-mates and group threads.
public struct GroupContext: Codable, Sendable, Equatable {
    public var mates: [String]
    public var totalMates: Int
    public var sourceThreads: [String]
    public var candidateThreads: [String]
}

public struct CandidateCard: Codable, Sendable, Equatable {
    public var person: PersonBrief
    public var score: Double
    public var label: String             // strong | likely | possible
    public var reasons: [String]
    public var sharedGroups: Int
    public var context: GroupContext
}

public struct ReviewCard: Codable, Sendable, Equatable {
    public var queue: String
    public var source: PersonBrief
    public var candidates: [CandidateCard]
    /// The source's own group-mates and group threads (Who's-this cards, which have no candidates).
    public var context: GroupContext?
}

public struct ReviewProgress: Codable, Sendable, Equatable {
    public var queue: String
    public var remaining: Int
    public var reviewed: Int             // this session: decided or skipped
    public var skipped: Int
    public var merges: Int               // all time, undone ones not counted
    public var rejections: Int
    public var noMatches: Int            // all time, undone ones not counted
    /// Cards still open in every queue, by queue key (cross, dups, who).
    public var queues: [String: Int]
}

public struct DecisionBrief: Codable, Sendable, Equatable { public var id: Int64; public var kind: String; public var label: String; public var at: Int64; public var undone: Bool }

public struct ReviewState: Codable, Sendable, Equatable {
    public var progress: ReviewProgress
    public var card: ReviewCard?
    public var history: [DecisionBrief]
    /// The one decision an undo may take back now (the newest still in force); nil when there is nothing to undo.
    public var undoableID: Int64?
}

public struct PeekMessage: Codable, Sendable, Equatable { public var fromMe: Bool; public var text: String; public var ts: Int64; public var service: String }
public struct PeekResult: Codable, Sendable, Equatable {
    public var anchor: Int64
    public var mode: String              // latest | earliest | spread
    public var messages: [PeekMessage]
    /// All messages (any kind) in the thread the sample came from, and the thread's whole date range.
    public var totalInThread: Int
    public var firstTs: Int64?
    public var lastTs: Int64?
}

/// Numbers about what the tuning rules removed at the last refresh (no names).
public struct TuningSummary: Sendable, Equatable {
    public var droppedByRule: [String: Int] = [:]
    public var cardsWithDrops = 0
    public var cardsLost = 0
    public var cardsLostByRule: [String: Int] = [:]
}

public struct ReviewError: Error, CustomStringConvertible { public let status: Int; public let description: String
    public init(_ status: Int, _ d: String) { self.status = status; description = d } }

public final class ReviewService: @unchecked Sendable {
    public static let historyLimit = 20
    public static let maxMates = 6
    public static let maxThreads = 3
    public static let peekLimit = 12
    public static let peekChars = 160
    /// A Meta-only person needs this many messages to be worth a Who's-this card.
    public static let minWhoMessages = 15

    public let root: ArchiveRoot
    private let lock = NSLock()
    private let db: Database
    private let reader: ArchiveReader
    private var gathered: PeopleStore.Gathered
    private var handleByID: [Int64: MatchHandle]
    private let stored: (groups: [MatchGroup], ambiguous: [AmbiguousName])
    private let groupThreads: [(id: Int64, members: [Int64])]
    private let groupTitle: [Int64: String]
    private var threadServices: [Int64: [String: Int]]?
    private var writer: PeopleOverrides?
    private var diskSignature = DiskSignature()

    private var index = PeopleIndex()
    private var rejections: Set<String>
    private var noMatch = Set<String>()
    private var coCountByHandle: [Int64: Int] = [:]
    private var groupPersonsCache: [(thread: Int64, persons: Set<Int64>)]?
    private var cards: [StoredCard] = []
    private var skipped = Set<Int64>()
    private var done = Set<Int64>()            // handle ids of sources merged this session
    private var rejectedDone = Set<Int64>()    // handle ids of sources whose every suggestion was rejected this session
    private var searchIndex: [(id: Int64, folded: String, compact: String, messages: Int)] = []
    public private(set) var lastRefreshSeconds = 0.0
    public private(set) var suggestionCount: [SuggestionQueue: Int] = [:]
    public private(set) var tuning = TuningSummary()

    /// What people.sqlite looked like when the in-memory person map was built; a change (the app edited it, or another process) means
    /// the map is stale and must be rebuilt before the next read or write.
    struct DiskSignature: Equatable {
        var exists = false, size = 0, modified = Date.distantPast, inode: UInt64 = 0
        init() {}
        init(root: ArchiveRoot) {
            let path = PeopleOverrides.fileURL(root: root).path
            guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return }
            exists = true
            size = (a[.size] as? NSNumber)?.intValue ?? 0
            modified = (a[.modificationDate] as? Date) ?? .distantPast
            inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }
    }

    struct StoredCard { var queue: SuggestionQueue; var source: Int64; var candidates: [SuggestionCandidate]; var handleCount = 0 }

    public init(root: ArchiveRoot) throws {
        self.root = root
        db = try Schema.openArchive(root: root, readOnly: true)
        reader = try ArchiveReader(root: root)
        gathered = try PeopleStore.gather(db: db)
        handleByID = Dictionary(gathered.handles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let s = try PeopleStore.storedGroups(db: db) { stored = s }
        else {
            let r = try PeopleStore.compute(db: db, g: gathered)
            stored = (r.groups, r.ambiguous)
        }
        var members: [Int64: [Int64]] = [:]
        let st = try db.prepare("SELECT tm.thread_id, tm.handle_id FROM thread_member tm JOIN thread t ON t.id = tm.thread_id WHERE t.is_group = 1 ORDER BY tm.thread_id")
        while try st.step() { members[st.int(0), default: []].append(st.int(1)) }
        groupThreads = members.keys.sorted().map { ($0, members[$0]!) }
        var titles: [Int64: String] = [:]
        let tt = try db.prepare("SELECT id, title FROM thread WHERE is_group = 1 AND title IS NOT NULL AND trim(title) <> ''")
        while try tt.step() { if let t = tt.string(1) { titles[tt.int(0)] = t } }
        groupTitle = titles
        rejections = PeopleOverrides.readRejections(root: root)
        try refresh()
    }

    // MARK: building

    /// Call (lock held) at the start of every request: if people.sqlite changed since the map was built, reload corrections and
    /// rejections so a merge or an undo never works from a handle list the app has since changed.
    private func syncWithDisk() {
        let now = DiskSignature(root: root)
        guard now != diskSignature else { return }
        rejections = PeopleOverrides.readRejections(root: root)
        rebuildIndex()
    }

    private func rebuildIndex() {
        diskSignature = DiskSignature(root: root)
        noMatch = PeopleOverrides.readNoMatchKeys(root: root)
        groupPersonsCache = nil
        index = PeopleIndex.build(handles: gathered.handles, threadsByHandle: gathered.threadsByHandle, raws: gathered.raws, auto: stored.groups,
                                  ambiguous: stored.ambiguous, overrides: currentOverrides(), source: .stored)
        searchIndex = index.persons.values.map { p in
            let names = allNames(p) + p.usernames + p.possibleUsernames
            return (p.id, names.map(NameMatching.fold).joined(separator: "|"), names.map(NameMatching.compact).joined(separator: "|"), p.messages)
        }
    }

    /// Re-reads the inferred Instagram usernames (`archivectl ig-usernames` may have rewritten them since this server started), so a
    /// refresh recomputes the suggestions from the current ones. Handle identity and the stored person mapping are untouched.
    private func reloadUsernames() {
        guard let users = try? PeopleStore.usernames(db: db) else { return }
        for i in gathered.handles.indices {
            let id = gathered.handles[i].id
            gathered.handles[i].igUsername = users[id]?.name
            gathered.handles[i].usernameHigh = users[id]?.high ?? false
        }
        handleByID = Dictionary(gathered.handles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func currentOverrides() -> OverrideSet {
        PeopleOverrides.read(root: root)
    }

    private func allNames(_ p: Person) -> [String] {
        var out: [String] = []
        if let r = p.renamedTo { out.append(r) }
        for h in p.handles { for n in handleByID[h.handleID]?.names ?? [] where n.origin != "instagram-username" { out.append(n.name) } }
        var seen = Set<String>()
        return out.filter { n in
            let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && t != "(Unknown)" && t != "null" && seen.insert(t).inserted
        }
    }

    private func profiles(maxGroup: Int) -> [SuggestionProfile] {
        var co: [Int64: Set<Int64>] = [:], groupCount: [Int64: Int] = [:]
        for g in groupThreads {
            let ps = Set(g.members.compactMap { index.personOfHandle[$0] })
            if ps.count < 2 || ps.count > maxGroup { continue }
            for p in ps { groupCount[p, default: 0] += 1; co[p, default: []].formUnion(ps.subtracting([p])) }
        }
        // How many different people each person shares group chats with, kept by handle so it survives a merge.
        coCountByHandle = [:]
        for p in index.persons.values { for h in p.handles { coCountByHandle[h.handleID] = co[p.id]?.count ?? 0 } }
        return index.persons.values.map { p in
            let hs = p.handles.compactMap { handleByID[$0.handleID] }
            let firsts = hs.map(\.firstTsMs).filter { $0 > 0 }, lasts = hs.map(\.lastTsMs).filter { $0 > 0 }
            return SuggestionProfile(id: p.id, names: allNames(p), usernames: p.usernames, possibleUsernames: p.possibleUsernames,
                                     phoneHandles: p.handles.filter { $0.service == nil }.count,
                                     hasMessenger: p.handles.contains { $0.service == .messenger }, hasInstagram: p.handles.contains { $0.service == .instagram },
                                     messages: p.messages, firstTsMs: firsts.min() ?? 0, lastTsMs: lasts.max() ?? 0,
                                     handleKeys: p.handles.map(\.normalized), coMembers: co[p.id] ?? [], groupCount: groupCount[p.id] ?? 0, hidden: p.hidden)
        }
    }

    /// Recomputes the person mapping and both suggestion queues from scratch (a few seconds on the real archive).
    public func refresh() throws {
        lock.lock(); defer { lock.unlock() }
        let t0 = Date()
        reloadUsernames()
        rejections = PeopleOverrides.readRejections(root: root)
        rebuildIndex()
        var ambiguousPairs = Set<String>()
        for a in index.ambiguous {
            let ps = Array(Set(a.handleIDs.compactMap { index.personOfHandle[$0] })).sorted()
            for i in 0..<ps.count { for j in (i + 1)..<ps.count { ambiguousPairs.insert(MatchSuggester.personPairKey(ps[i], ps[j])) } }
        }
        var options = SuggestionOptions()
        let trace = SuggestionTrace()
        options.trace = trace
        let profs = profiles(maxGroup: options.maxGroupSize)
        let sug = MatchSuggester.suggest(profiles: profs, rejectedPairs: rejections, ambiguousPairs: ambiguousPairs, options: options)
        cards = sug.map { StoredCard(queue: $0.queue, source: $0.sourceID, candidates: $0.candidates) }
        // Third queue: Meta-only people with enough messages and no suggestion, who were not reviewed already (they were the card of a
        // reject decision still in force). Somebody who was only ever a rejected candidate on another person's card was never looked at.
        let suggested = Set(sug.filter { $0.queue == .crossService }.map(\.sourceID))
        var reviewedPersons = Set<Int64>()
        for d in PeopleOverrides.readDecisions(root: root, limit: 1_000_000) where d.kind == "reject" && !d.undone {
            if let data = d.payload.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let src = (obj["source"] as? NSNumber)?.int64Value, let pid = index.personOfHandle[src] { reviewedPersons.insert(pid) }
        }
        let whos = profs.filter { $0.isMetaOnly && !$0.hidden && $0.messages >= Self.minWhoMessages && !suggested.contains($0.id)
            && !reviewedPersons.contains($0.id) }
            .sorted { $0.messages != $1.messages ? $0.messages > $1.messages : $0.id < $1.id }
        cards += whos.map { StoredCard(queue: .whos, source: $0.id, candidates: [], handleCount: $0.handleKeys.count) }
        suggestionCount = [.crossService: sug.filter { $0.queue == .crossService }.count, .duplicates: sug.filter { $0.queue == .duplicates }.count, .whos: whos.count]
        var t = TuningSummary()
        t.droppedByRule = trace.dropped
        t.cardsWithDrops = trace.rulesByCard.count
        for (key, rules) in trace.rulesByCard where !sug.contains(where: { MatchSuggester.cardKeyOf($0) == key }) {
            t.cardsLost += 1
            for r in rules { t.cardsLostByRule[r, default: 0] += 1 }
        }
        tuning = t
        skipped = []; done = []; rejectedDone = []
        lastRefreshSeconds = Date().timeIntervalSince(t0)
    }

    // MARK: briefs

    private func serviceCounts() -> [Int64: [String: Int]] {
        if let t = threadServices { return t }
        var out: [Int64: [String: Int]] = [:]
        if let st = try? db.prepare("SELECT thread_id, service, count(*) FROM message WHERE canonical_id IS NULL GROUP BY thread_id, service") {
            while (try? st.step()) == true { out[st.int(0), default: [:]][st.string(1) ?? "sms"] = Int(st.int(2)) }
        }
        threadServices = out
        return out
    }

    private func brief(_ p: Person, groupCounts: [Int64: Int]? = nil) -> PersonBrief {
        let sc = serviceCounts()
        var perService: [ServiceKey: Int] = [:]
        for t in p.threadIDs { for (svc, n) in sc[t] ?? [:] { perService[ServiceKey.of(messageService: svc), default: 0] += n } }
        let hs = p.handles.compactMap { handleByID[$0.handleID] }
        let firsts = hs.map(\.firstTsMs).filter { $0 > 0 }, lasts = hs.map(\.lastTsMs).filter { $0 > 0 }
        let display = p.name
        let alts = allNames(p).filter { $0 != display }
        let phones: [String] = p.handles.filter { $0.service == nil }.map { h in
            let digits = h.normalized.filter(\.isNumber)
            return h.kind == "email" ? "email" : (digits.count >= 4 ? "\u{2022}\u{2022}\u{2022}\u{2022} " + digits.suffix(4) : h.kind)
        }
        var groups = 0
        for g in groupThreads where g.members.contains(where: { index.personOfHandle[$0] == p.id }) { groups += 1 }
        return PersonBrief(anchor: p.id, name: display, altNames: Array(alts.prefix(4)), usernames: p.usernames, possibleUsernames: p.possibleUsernames,
                           services: perService.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { ServiceBadge(key: $0.key.rawValue, label: $0.key.label, count: $0.value) },
                           phones: phones, messages: p.messages, firstTs: firsts.min(), lastTs: lasts.max(), groups: groups, renamed: p.renamedTo != nil)
    }

    public static func label(_ score: Double) -> String { score >= 0.80 ? "strong" : (score >= 0.55 ? "likely" : "possible") }

    // MARK: serving cards

    private struct Resolved { var card: StoredCard; var source: Person; var candidates: [(Person, SuggestionCandidate)] }

    private func resolve(_ c: StoredCard) -> Resolved? {
        guard let src = index.person(ofHandle: c.source), !src.hidden else { return nil }
        if src.handles.contains(where: { skipped.contains($0.handleID) || done.contains($0.handleID) }) { return nil }
        if c.queue != .duplicates, src.handles.contains(where: { $0.service == nil }) { return nil }        // got a number: linked
        if c.queue == .whos {
            // Merged with somebody since the queue was built, or marked "No match": no longer a lone Meta person to ask about.
            if src.handles.count != c.handleCount || src.handles.contains(where: { noMatch.contains($0.normalized) }) { return nil }
            return Resolved(card: c, source: src, candidates: [])
        }
        var seen = Set<Int64>([src.id])
        var out: [(Person, SuggestionCandidate)] = []
        for cand in c.candidates {
            guard let p = index.person(ofHandle: cand.personID), !p.hidden, seen.insert(p.id).inserted else { continue }
            if c.queue == .crossService {
                if src.handles.contains(where: { $0.service == .messenger }) && p.handles.contains(where: { $0.service == .messenger }) { continue }
                if src.handles.contains(where: { $0.service == .instagram }) && p.handles.contains(where: { $0.service == .instagram }) { continue }
            }
            if isRejected(src, p) { continue }
            out.append((p, cand))
        }
        return out.isEmpty ? nil : Resolved(card: c, source: src, candidates: out)
    }

    private func isRejected(_ a: Person, _ b: Person) -> Bool {
        guard !rejections.isEmpty else { return false }
        for x in a.handles { for y in b.handles where rejections.contains(MatchSuggester.rejectionKey(x.normalized, y.normalized)) { return true } }
        return false
    }

    private func progress(_ queue: SuggestionQueue) -> ReviewProgress {
        var remaining = [SuggestionQueue.crossService: 0, .duplicates: 0, .whos: 0]
        for c in cards where resolve(c) != nil { remaining[c.queue, default: 0] += 1 }
        let merges = PeopleOverrides.decisionCount(root: root, kind: "merge")
        let rejs = PeopleOverrides.decisionCount(root: root, kind: "reject")
        let nones = PeopleOverrides.decisionCount(root: root, kind: "none")
        return ReviewProgress(queue: queue.rawValue, remaining: remaining[queue] ?? 0, reviewed: skipped.count + done.count + rejectedDone.count, skipped: skipped.count,
                              merges: merges, rejections: rejs, noMatches: nones, queues: Dictionary(uniqueKeysWithValues: remaining.map { ($0.key.rawValue, $0.value) }))
    }

    private func make(_ r: Resolved) -> ReviewCard {
        let queue = r.card.queue
        if queue == .whos {
            return ReviewCard(queue: queue.rawValue, source: brief(r.source), candidates: [], context: context(r.source, nil))
        }
        return ReviewCard(queue: queue.rawValue, source: brief(r.source),
                          candidates: r.candidates.map { CandidateCard(person: brief($0.0), score: $0.1.score, label: Self.label($0.1.score), reasons: $0.1.reasons,
                                                                        sharedGroups: $0.1.sharedGroupPeople, context: context(r.source, $0.0)) },
                          context: nil)
    }

    private func card(_ queue: SuggestionQueue) -> ReviewCard? {
        for c in cards where c.queue == queue {
            if let r = resolve(c) { return make(r) }
        }
        return nil
    }

    /// Every card still open in a queue, in queue order (the page serves them one at a time; the CLI lists them all).
    public func remainingCards(_ queue: SuggestionQueue) -> [ReviewCard] {
        lock.lock(); defer { lock.unlock() }
        syncWithDisk()
        return cards.filter { $0.queue == queue }.compactMap { c in resolve(c).map(make) }
    }

    // MARK: group context

    /// The group threads (2 to 60 current persons) with their persons, under the current person mapping.
    private func groupPersons() -> [(thread: Int64, persons: Set<Int64>)] {
        if let c = groupPersonsCache { return c }
        let maxGroup = SuggestionOptions().maxGroupSize
        var out: [(thread: Int64, persons: Set<Int64>)] = []
        for g in groupThreads {
            let ps = Set(g.members.compactMap { index.personOfHandle[$0] })
            if ps.count >= 2, ps.count <= maxGroup { out.append((g.id, ps)) }
        }
        groupPersonsCache = out
        return out
    }

    private func coCount(_ id: Int64) -> Int {
        index.persons[id]?.handles.map { coCountByHandle[$0.handleID] ?? 0 }.max() ?? 0
    }

    private func threadTitle(_ thread: Int64, size: Int) -> String { groupTitle[thread] ?? "(untitled group of \(size))" }

    /// Group-mates and group threads around `source` (and shared with `candidate`, when there is one). Mates come most distinctive
    /// first: the fewest group chat partners of their own. Threads: those holding the most shared mates, titled ones first.
    private func context(_ source: Person, _ candidate: Person?) -> GroupContext {
        let groups = groupPersons()
        let sg = groups.filter { $0.persons.contains(source.id) }
        var mates = Set(sg.flatMap(\.persons)); mates.remove(source.id)
        var cg: [(thread: Int64, persons: Set<Int64>)] = []
        if let c = candidate {
            cg = groups.filter { $0.persons.contains(c.id) }
            var theirs = Set(cg.flatMap(\.persons)); theirs.remove(c.id)
            mates.formIntersection(theirs)
            mates.remove(c.id)
        }
        let ranked = mates.sorted { l, r in
            let cl = coCount(l), cr = coCount(r)
            if cl != cr { return cl < cr }
            return (index.persons[l]?.name ?? "") < (index.persons[r]?.name ?? "")
        }
        func titles(_ gs: [(thread: Int64, persons: Set<Int64>)]) -> [String] {
            let scored = gs.map { g in (g, candidate == nil ? 0 : g.persons.intersection(mates).count) }
                .filter { candidate == nil || $0.1 > 0 }
                .sorted { l, r in
                    let lt = groupTitle[l.0.thread] != nil, rt = groupTitle[r.0.thread] != nil
                    if lt != rt { return lt }
                    if l.1 != r.1 { return l.1 > r.1 }
                    if l.0.persons.count != r.0.persons.count { return l.0.persons.count < r.0.persons.count }
                    return l.0.thread < r.0.thread
                }
            return scored.prefix(Self.maxThreads).map { threadTitle($0.0.thread, size: $0.0.persons.count) }
        }
        return GroupContext(mates: ranked.prefix(Self.maxMates).map { index.persons[$0]?.name ?? "(no name)" }, totalMates: ranked.count,
                            sourceThreads: titles(sg), candidateThreads: candidate == nil ? [] : titles(cg))
    }

    private func history() -> [DecisionBrief] {
        PeopleOverrides.readDecisions(root: root, limit: Self.historyLimit).map { DecisionBrief(id: $0.id, kind: $0.kind, label: $0.label, at: $0.at, undone: $0.undone) }
    }

    public func state(queue: SuggestionQueue) -> ReviewState {
        lock.lock(); defer { lock.unlock() }
        syncWithDisk()
        return ReviewState(progress: progress(queue), card: card(queue), history: history(),
                           undoableID: PeopleOverrides.newestLiveDecision(root: root)?.id)
    }

    /// The only place people.sqlite is opened for writing (creating, migrating and journal-mode setup happen here, on the first
    /// decision, never on a page load).
    private func requireWriter() throws -> PeopleOverrides {
        if let writer { return writer }
        let w = try PeopleOverrides(root: root)
        writer = w
        return w
    }

    // MARK: decisions

    private func person(_ anchor: Int64) throws -> Person {
        guard let p = index.person(ofHandle: anchor) else { throw ReviewError(404, "no such person") }
        return p
    }

    private func short(_ p: Person) -> String { p.name ?? "(no name)" }

    @discardableResult
    public func merge(source: Int64, target: Int64) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        syncWithDisk()
        let a = try person(source), b = try person(target)
        guard a.id != b.id else { throw ReviewError(409, "already the same person") }
        let w = try requireWriter()
        let ka = a.handles.map(\.normalized), kb = b.handles.map(\.normalized)
        let id = try w.atomically { () throws -> Int64 in
            let fresh = try w.mergeReturningNew(ka, with: kb)
            return try w.logDecision(kind: "merge", label: "Merged \(short(a)) with \(short(b))", payload: ["links": fresh, "source": source, "target": target])
        }
        done.insert(source)
        rebuildIndex()
        return id
    }

    /// "Not the same person": every handle of the source against every handle of each target, stored so it is never suggested again.
    @discardableResult
    public func reject(source: Int64, targets: [Int64]) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        syncWithDisk()
        let a = try person(source)
        let ps = try targets.map(person).filter { $0.id != a.id }
        guard !ps.isEmpty else { throw ReviewError(400, "nothing to reject") }
        let w = try requireWriter()
        let label = ps.count == 1 ? "Not the same: \(short(a)) and \(short(ps[0]))" : "Not the same: \(short(a)) and \(ps.count) others"
        var fresh: [[String]] = []
        let id = try w.atomically { () throws -> Int64 in
            for p in ps { fresh += try w.reject(a.handles.map(\.normalized), p.handles.map(\.normalized)) }
            return try w.logDecision(kind: "reject", label: label, payload: ["pairs": fresh, "source": source])
        }
        for pair in fresh where pair.count == 2 { rejections.insert(MatchSuggester.rejectionKey(pair[0], pair[1])) }
        diskSignature = DiskSignature(root: root)
        if let stored = cards.first(where: { index.personOfHandle[$0.source] == a.id }), resolve(stored) == nil { rejectedDone.insert(source) }
        return id
    }

    /// "No match" in the Who's-this queue: stored as a decision of kind `none` in the log (no new table), so it is undoable and the
    /// person does not come back.
    @discardableResult
    public func noMatch(source: Int64) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        syncWithDisk()
        let a = try person(source)
        guard !a.handles.contains(where: { $0.service == nil }) else { throw ReviewError(409, "this person has a number already") }
        let w = try requireWriter()
        let keys = a.handles.map(\.normalized)
        let id = try w.atomically { () throws -> Int64 in
            try w.logDecision(kind: "none", label: "No match for \(short(a))", payload: ["keys": keys, "source": source])
        }
        noMatch.formUnion(keys)
        diskSignature = DiskSignature(root: root)
        rejectedDone.insert(source)
        return id
    }

    public func skip(source: Int64) {
        lock.lock(); defer { lock.unlock() }
        syncWithDisk()
        skipped.insert(source)
    }

    @discardableResult
    public func rename(person anchor: Int64, to name: String) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        syncWithDisk()
        let p = try person(anchor)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 120 else { throw ReviewError(400, "name too long") }
        let w = try requireWriter()
        let keys = p.handles.map(\.normalized)
        let label = trimmed.isEmpty ? "Cleared the name of \(short(p))" : "Renamed \(short(p)) to \(trimmed)"
        let id = try w.atomically { () throws -> Int64 in
            let prev = try w.renames(of: keys)
            try w.rename(keys, to: trimmed)
            let prevJSON: [String: [Any]] = prev.mapValues { [$0.name, $0.at] }
            return try w.logDecision(kind: "rename", label: label, payload: ["handles": keys, "previous": prevJSON, "set": trimmed])
        }
        rebuildIndex()
        return id
    }

    /// Undoes the newest decision still in force. Undo is last-in-first-out: a later decision may build on an earlier one (a second
    /// merge that links the same person on, a rename of the same handles), so naming any older id is refused with 409.
    @discardableResult
    public func undo(id: Int64? = nil) throws -> DecisionBrief {
        lock.lock(); defer { lock.unlock() }
        syncWithDisk()
        guard FileManager.default.fileExists(atPath: PeopleOverrides.fileURL(root: root).path) else { throw ReviewError(404, "nothing to undo") }
        let w = try requireWriter()
        guard let d = try w.newestLiveDecision() else { throw ReviewError(404, "nothing to undo") }
        if let id, id != d.id { throw ReviewError(409, "only the newest decision can be undone") }
        let obj = (try? JSONSerialization.jsonObject(with: Data(d.payload.utf8))) as? [String: Any] ?? [:]
        try w.atomically {
            switch d.kind {
            case "merge":
                try w.removeLinks(obj["links"] as? [[String]] ?? [])
                if let s = (obj["source"] as? NSNumber)?.int64Value { done.remove(s); skipped.remove(s) }
            case "reject":
                let pairs = obj["pairs"] as? [[String]] ?? []
                try w.removeRejections(pairs)
                for pair in pairs where pair.count == 2 { rejections.remove(MatchSuggester.rejectionKey(pair[0], pair[1])) }
                if let s = (obj["source"] as? NSNumber)?.int64Value { rejectedDone.remove(s); skipped.remove(s) }
            case "none":
                noMatch.subtract(obj["keys"] as? [String] ?? [])
                if let s = (obj["source"] as? NSNumber)?.int64Value { rejectedDone.remove(s); skipped.remove(s) }
            case "rename":
                let handles = obj["handles"] as? [String] ?? []
                // Changed since in the app? Then putting the old name back would overwrite that newer rename.
                if let set = obj["set"] as? String {
                    let current = try w.renames(of: handles)
                    for h in handles where current[h]?.name != (set.isEmpty ? nil : set) { throw ReviewError(409, "renamed again since, in the app: nothing to undo here") }
                }
                var prev: [String: OverrideSet.Rename] = [:]
                for (h, v) in obj["previous"] as? [String: [Any]] ?? [:] {
                    if v.count == 2, let name = v[0] as? String, let at = (v[1] as? Int64) ?? (v[1] as? Int).map(Int64.init) ?? (v[1] as? NSNumber)?.int64Value {
                        prev[h] = OverrideSet.Rename(name: name, at: at)
                    }
                }
                try w.restoreRenames(handles: handles, previous: prev)
            default: throw ReviewError(400, "unknown decision kind")
            }
            try w.markUndone(d.id)
        }
        rebuildIndex()
        return DecisionBrief(id: d.id, kind: d.kind, label: d.label, at: d.at, undone: true)
    }

    // MARK: search and peek

    public func search(_ q: String, exclude: Int64?, limit: Int = 20) -> [PersonBrief] {
        lock.lock(); defer { lock.unlock() }
        syncWithDisk()
        let folded = NameMatching.fold(q), compact = NameMatching.compact(q)
        guard folded.count >= 2 else { return [] }
        let words = NameMatching.tokens(folded)
        let excluded = exclude.flatMap { index.personOfHandle[$0] }
        let hits = searchIndex.filter { e in
            if e.id == excluded { return false }
            return words.allSatisfy { e.folded.contains($0) } || (compact.count >= 3 && e.compact.contains(compact))
        }.sorted { $0.messages != $1.messages ? $0.messages > $1.messages : $0.id < $1.id }
        return hits.prefix(limit).compactMap { index.persons[$0.id] }.map { brief($0) }
    }

    /// Up to `peekLimit` text messages of the person's biggest 1:1 thread (the newest, the oldest, or evenly spread across the whole
    /// thread), each cut to `peekChars` characters, with the thread's date range and message count. Nothing else is read; no media.
    public func peek(person anchor: Int64, mode: ArchiveReader.SampleMode = .latest) throws -> PeekResult {
        lock.lock()
        syncWithDisk()
        let p: Person
        do { p = try person(anchor) } catch { lock.unlock(); throw error }
        lock.unlock()
        var best: (id: Int64, n: Int)?
        for t in p.threadIDs {
            let n = (try? reader.messageCount(thread: t)) ?? 0
            if best == nil || n > best!.n { best = (t, n) }
        }
        guard let b = best, b.n > 0 else { return PeekResult(anchor: anchor, mode: mode.rawValue, messages: [], totalInThread: 0, firstTs: nil, lastTs: nil) }
        let sample = try reader.textSample(thread: b.id, mode: mode, limit: Self.peekLimit)
        let range = try reader.messageRange(thread: b.id)
        var out: [PeekMessage] = []
        for r in sample.rows {
            guard let body = r.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { continue }
            let flat = body.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            out.append(PeekMessage(fromMe: r.isFromMe, text: flat.count > Self.peekChars ? String(flat.prefix(Self.peekChars)) + "\u{2026}" : flat, ts: r.tsMs, service: r.serviceKey.rawValue))
        }
        return PeekResult(anchor: anchor, mode: mode.rawValue, messages: out, totalInThread: b.n, firstTs: range?.first, lastTs: range?.last)
    }

    /// Counts for tests and the CLI report: top scores of the first queue, and how many have group evidence.
    public func queueSummary() -> (cross: [Suggestion], total: Int) {
        lock.lock(); defer { lock.unlock() }
        let s = cards.filter { $0.queue == .crossService }.map { Suggestion(queue: $0.queue, sourceID: $0.source, candidates: $0.candidates) }
        return (s, cards.count)
    }
}
