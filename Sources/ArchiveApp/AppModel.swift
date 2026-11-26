import SwiftUI
import ArchiveCore

enum ConversationSort: String, CaseIterable, Identifiable {
    case recent = "Most recent", messages = "Most messages"
    var id: String { rawValue }
}

enum CoverageScope: String, CaseIterable, Identifiable {
    case archive = "All conversations", thread = "This conversation"
    var id: String { rawValue }
}

enum SearchScope: String, CaseIterable, Identifiable {
    case archive = "Everywhere", thread = "This conversation", posts = "Posts"
    var id: String { rawValue }
}

/// What the list can select: a person (all their 1:1 conversations merged) or a single thread (groups, and 1:1 threads
/// opened from search that have no visible person row).
enum ListItemID: Hashable, Sendable {
    case person(Int64)
    case thread(Int64)
}

struct ConversationRow: Identifiable, Hashable {
    var id: ListItemID
    var title: String
    var isGroup: Bool
    var messageCount: Int
    var lastTsMs: Int64
    var preview: String?
    var services: [ServiceKey]
    var searchKey: String
    /// People: how many handles (numbers, Messenger, Instagram) make up the row.
    var handleCount = 1
    /// People: threads that are hidden by default (shown because "Show hidden" is on).
    var hiddenThreads = 0
    /// The row is only listed because "Show hidden" is on (hidden person, or only hidden threads).
    var isHiddenRow = false
    var threadIDs: [Int64]
    /// Calls with this person (every service), or with the other party of a lone 1:1 thread; 0 for groups.
    var callCount = 0
    var isPerson: Bool { if case .person = id { return true }; return false }
    var personID: Int64? { if case .person(let p) = id { return p }; return nil }
}

/// Sheets for fixing a wrong match.
enum PeopleSheet: Identifiable, Equatable {
    case merge(Int64), split(Int64), rename(Int64)
    var id: String {
        switch self { case .merge(let p): return "merge\(p)"; case .split(let p): return "split\(p)"; case .rename(let p): return "rename\(p)" }
    }
    var personID: Int64 { switch self { case .merge(let p), .split(let p), .rename(let p): return p } }
}

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable { case loading, ready, missing(String), failed(String) }

    static let rootDefaultsKey = "archiveRoot"

    // archive
    private(set) var root: ArchiveRoot
    private(set) var phase: Phase = .loading
    private(set) var overview: ArchiveOverview?
    private(set) var reader: ArchiveReader?
    private var searchReader: ArchiveReader?
    let isSnapshot: Bool
    let contacts: ContactsResolver

    // people and the conversation list
    /// Every thread with messages (hidden ones included), whole archive.
    private(set) var allConversations: [ConversationSummary] = []
    /// Per-thread summaries limited to a month while the coverage strip filters the list.
    private(set) var rangeConversations: [ConversationSummary]?
    private(set) var people: PeopleIndex = .empty
    /// Calls per handle (the call table, canonical rows), for the list's and the header's counts.
    private(set) var callCounts: [Int64: CallCount] = [:]
    /// Voicemails per handle (canonical rows), for the header's count.
    private(set) var voicemailCounts: [Int64: Int] = [:]
    private var conversationByID: [Int64: ConversationSummary] = [:]
    private(set) var threadTitles: [Int64: String] = [:]
    private(set) var rows: [ConversationRow] = [] { didSet { rowByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }); recomputeVisible() } }
    private(set) var rowByID: [ListItemID: ConversationRow] = [:]
    /// Filtered and sorted `rows`, recomputed only when the rows, the filter text or the sort change.
    private(set) var visibleRows: [ConversationRow] = []
    var filterText = "" { didSet { if oldValue != filterText { recomputeVisible() } } }
    var sort: ConversationSort = .recent { didSet { if oldValue != sort { recomputeVisible() } } }
    /// Filtered threads and message requests (and people the user hid) stay out of the list unless this is on.
    var showHidden = false { didSet { if oldValue != showHidden { hiddenToggled() } } }
    /// Checked once per load, off the main thread (a hung network mount must not freeze the UI).
    private(set) var isNetworkRoot = false
    private(set) var monthFilter: MonthKey?
    var conversations: [ConversationSummary] { rangeConversations ?? allConversations }

    // selection and thread
    private(set) var selection: ListItemID?
    private(set) var thread: ThreadModel?
    /// Services shown in the open person's timeline; nil = all.
    private(set) var serviceFilter: Set<ServiceKey>?

    // fixing matches
    var sheet: PeopleSheet?
    var mergeQuery = ""
    var renameText = ""
    var mergePick: Int64?
    var splitPicks: Set<Int64> = []
    var actionError: String?

    // search
    var searchText = ""
    var searchScope: SearchScope = .archive { didSet { if oldValue != searchScope { searchChanged(immediately: true) } } }
    var searchOrder: SearchOrder = .bestMatch { didSet { if oldValue != searchOrder { searchChanged(immediately: true) } } }
    private(set) var searchHits: [SearchHit] = []
    /// The Posts scope's results (Facebook and Instagram posts and comments).
    private(set) var postHits: [PostItem] = []
    /// A person's posts and comments, shown instead of the messages when `showPosts` is on. Loading (reset on every person,
    /// paged, real total, the count and pages arriving in the background) is ArchiveCore's tested PersonPostsLoader;
    /// `postsState` mirrors its state for the views.
    private(set) var postsState = PersonPostsState(pageSize: 500)
    @ObservationIgnored private lazy var postsLoader: PersonPostsLoader = {
        let l = PersonPostsLoader(pageSize: 500)
        l.changed = { [weak self, unowned l] in self?.postsState = l.state }
        return l
    }()
    var showPosts: Bool {
        get { postsState.showPosts }
        set { postsLoader.setShowPosts(newValue) }
    }
    var personPosts: [PostEntry] { postsState.entries(zone: .current) }
    var personPostCount: Int? { postsState.total }
    private(set) var searchRunning = false
    private(set) var searchSeconds: Double = 0
    private(set) var searchHitLimit = 200
    private var searchTask: Task<Void, Never>?
    private var threadTask: Task<Void, Never>?
    private var monthsTask: Task<Void, Never>?
    private var listTask: Task<Void, Never>?
    private var peopleTask: Task<Void, Never>?
    var selectedHitID: Int64?

    // coverage
    private(set) var archiveMonths: [MonthCount] = []
    private(set) var scopeMonths: [MonthCount] = []
    var coverageScope: CoverageScope = .archive
    private(set) var highlightedMonth: MonthKey?

    // timings for the snapshot report
    private(set) var loadSeconds: Double = 0
    private(set) var peopleSeconds: Double = 0

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    init(root: ArchiveRoot, isSnapshot: Bool = false) {
        self.root = root
        self.isSnapshot = isSnapshot
        self.contacts = ContactsResolver(enabled: !isSnapshot)
    }

    /// The root the app opens: explicit `--archive`, then the Settings choice, then MESSAGE_ARCHIVE_ROOT, then the default.
    static func initialRoot(flag: String?) -> ArchiveRoot {
        if let flag, !flag.isEmpty { return ArchiveRoot.resolve(flag: flag) }
        if let saved = UserDefaults.standard.string(forKey: rootDefaultsKey), !saved.isEmpty { return ArchiveRoot.resolve(flag: saved) }
        return ArchiveRoot.resolve()
    }

    func setRoot(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.path, forKey: Self.rootDefaultsKey)
            root = ArchiveRoot(url: url)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.rootDefaultsKey)
            root = ArchiveRoot.resolve()
        }
        Task { await load() }
    }

    // MARK: loading

    func load() async {
        let t0 = Date()
        phase = .loading
        thread = nil; selection = nil; monthFilter = nil; highlightedMonth = nil; serviceFilter = nil; rangeConversations = nil
        searchHits = []; scopeMonths = []; searchHitLimit = 200; sheet = nil
        let root = self.root
        let probe = await Task.detached(priority: .userInitiated) {
            (exists: FileManager.default.fileExists(atPath: root.databaseURL.path), network: root.isOnNetworkVolume)
        }.value
        isNetworkRoot = probe.network
        let stampBefore = await Task.detached { Self.stamp(root) }.value
        Thumbnails.shared.configure(root: root, onNetwork: probe.network)
        if !probe.exists {
            reader = nil; searchReader = nil; allConversations = []; people = .empty; rows = []; overview = nil; archiveMonths = []
            phase = .missing(Self.missingMessage(for: root))
            return
        }
        do {
            struct Loaded: @unchecked Sendable {
                var reader: ArchiveReader, search: ArchiveReader, overview: ArchiveOverview
                var conversations: [ConversationSummary], months: [MonthCount], people: PeopleIndex, peopleSeconds: Double
                var calls: [Int64: CallCount]
                var voicemails: [Int64: Int]
            }
            let loaded = try await Task.detached(priority: .userInitiated) { () -> Loaded in
                let r = try ArchiveReader(root: root)
                let s = try ArchiveReader(root: root)
                let convs = try r.conversations(includeHidden: true)
                let tp = Date()
                let idx = try r.people(overrides: PeopleOverrides.read(root: root))
                return Loaded(reader: r, search: s, overview: try r.overview(), conversations: convs, months: try r.monthCounts(),
                              people: idx, peopleSeconds: Date().timeIntervalSince(tp), calls: (try? r.callCountsByHandle()) ?? [:],
                              voicemails: (try? r.voicemailCountsByHandle()) ?? [:])
            }.value
            reader = loaded.reader; searchReader = loaded.search; overview = loaded.overview
            // the file the readers opened: taken before they opened it, and checked after; a push in between reloads at the next activation
            loadedStamp = await Task.detached { Self.stamp(root) }.value == stampBefore ? stampBefore : "changed while loading"
            allConversations = loaded.conversations; archiveMonths = loaded.months; people = loaded.people; peopleSeconds = loaded.peopleSeconds
            callCounts = loaded.calls
            voicemailCounts = loaded.voicemails
            conversationByID = Dictionary(loaded.conversations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            rebuildRows()
            phase = .ready
            loadSeconds = Date().timeIntervalSince(t0)
        } catch {
            reader = nil; searchReader = nil; allConversations = []; people = .empty; rows = []
            phase = .failed("\(error)")
        }
        await contacts.refresh()
        // Contacts names can match more people; without them the load already has the mapping.
        if contacts.access == .authorized, !contacts.names.isEmpty { await reloadPeople() }
    }

    static func missingMessage(for root: ArchiveRoot) -> String {
        let comps = root.url.pathComponents
        if comps.count > 2, comps[1] == "Volumes" {
            let vol = "/Volumes/" + comps[2]
            if !FileManager.default.fileExists(atPath: vol) {
                return "\(vol) is not mounted, so there is no archive at \(root.url.path). Connect to the server (Finder, Go, Connect to Server) and reload."
            }
        }
        return "There is no archive (archive.sqlite) in \(root.url.path)."
    }

    func reload() { Task { await load() } }

    /// The open database file's identity (inode, size, modification time). When a newer archive.sqlite is copied over the open one
    /// (another machine pushing an update to a shared copy), the stamp changes and the app reloads when it is next brought forward.
    @ObservationIgnored private var loadedStamp: String?
    private nonisolated static func stamp(_ root: ArchiveRoot) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: root.databaseURL.path) else { return nil }
        return "\(a[.systemFileNumber] ?? 0)|\(a[.size] ?? 0)|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }
    func reloadIfArchiveChanged() {
        guard phase == .ready, let was = loadedStamp else { return }
        let root = self.root
        Task {
            let now = await Task.detached { Self.stamp(root) }.value
            if let now, now != was, self.loadedStamp == was { self.reload() }
        }
    }

    func refreshContacts() async {
        await contacts.refresh()
        await reloadPeople()
    }

    /// Recomputes the person mapping (after a correction, or when Contacts names arrive and can match more people).
    func reloadPeople() async {
        guard let reader else { return }
        let root = self.root
        let extra = contacts.access == .authorized ? contacts.names : [:]
        let t0 = Date()
        let idx = try? await Task.detached(priority: .userInitiated) {
            try reader.people(overrides: PeopleOverrides.read(root: root), extraNames: extra)
        }.value
        if let idx { people = idx; peopleSeconds = Date().timeIntervalSince(t0) }
        rebuildRows()
        // The open person may have been renumbered by a merge or split.
        if case .person(let pid) = selection, people.persons[pid] == nil { select(nil) }
    }

    // MARK: names

    func memberName(_ m: ThreadMember) -> String {
        contacts.names[m.normalized] ?? m.archiveName ?? Fmt.phone(m.normalized)
    }

    func senderName(normalized: String?, archiveName: String?) -> String {
        guard let normalized else { return archiveName ?? "Unknown" }
        return contacts.names[normalized] ?? archiveName ?? (normalized.hasPrefix("fb:") || normalized.hasPrefix("ig:") ? (archiveName ?? String(normalized.dropFirst(3))) : Fmt.phone(normalized))
    }

    /// The user's rename, then Contacts.app, then the best archive name, then the first number or account name.
    func displayName(_ p: Person) -> String {
        if let r = p.renamedTo, !r.isEmpty { return r }
        for h in p.handles.sorted(by: { $0.messages > $1.messages }) { if let n = contacts.names[h.normalized] { return n } }
        if let n = p.archiveName { return n }
        if let h = p.handles.max(by: { $0.messages < $1.messages }) { return h.service != nil ? h.raw : Fmt.phone(h.normalized) }
        return "Unknown"
    }

    func title(for c: ConversationSummary) -> String {
        if let t = c.storedTitle, !t.isEmpty { return t }
        if c.members.isEmpty { return "Unknown" }
        let names = c.members.map { memberName($0) }
        if names.count == 1 { return names[0] }
        let sorted = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if sorted.count <= 3 { return sorted.joined(separator: ", ") }
        return sorted.prefix(2).joined(separator: ", ") + " & \(sorted.count - 2) others"
    }

    /// Title of a thread as search results show it: the person's name for a 1:1 thread.
    func title(forThread id: Int64) -> String { threadTitles[id] ?? "Conversation" }

    var selectedPerson: Person? {
        if case .person(let p) = selection { return people.persons[p] }
        return nil
    }

    var selectionTitle: String {
        switch selection {
        case .person(let p): return people.persons[p].map(displayName) ?? "Conversation"
        case .thread(let t): return title(forThread: t)
        case nil: return Product.name
        }
    }

    /// Threads a person's timeline covers right now (hidden ones only when "Show hidden" is on).
    func threads(ofPerson pid: Int64) -> [Int64] {
        (people.persons[pid]?.threadIDs ?? []).filter { t in
            guard let c = conversationByID[t] else { return false }
            return showHidden || !c.hidden
        }
    }

    /// Whole-archive message count of the open item (not limited by the month filter).
    var selectionTotal: Int? {
        switch selection {
        case .person(let p): return threads(ofPerson: p).reduce(0) { $0 + (conversationByID[$1]?.messageCount ?? 0) }
        case .thread(let t): return conversationByID[t]?.messageCount
        case nil: return nil
        }
    }

    /// Calls with the open person (all their accounts, every service) or with the other party of a lone 1:1 thread; nil for a group.
    var selectionCalls: CallCount? {
        switch selection {
        case .person(let p): return people.persons[p].map { CallCount.sum($0.handles.map(\.handleID), in: callCounts) }
        case .thread(let t):
            guard let c = conversationByID[t], !c.isGroup else { return nil }
            return CallCount.sum(c.members.map(\.handleID), in: callCounts)
        case nil: return nil
        }
    }

    /// Voicemails left by the open person (all their accounts) or the other party of a lone 1:1 thread; nil for a group.
    var selectionVoicemails: Int? {
        switch selection {
        case .person(let p): return people.persons[p].map { $0.handles.reduce(0) { $0 + (voicemailCounts[$1.handleID] ?? 0) } }
        case .thread(let t):
            guard let c = conversationByID[t], !c.isGroup else { return nil }
            return c.members.reduce(0) { $0 + (voicemailCounts[$1.handleID] ?? 0) }
        case nil: return nil
        }
    }

    /// "1,234 messages · 56 calls · 14 h talked · 3 voicemails": the open item's totals (window subtitle and headers).
    var selectionTotalsLine: String {
        var parts: [String] = []
        if let n = selectionTotal { parts.append("\(n.formatted()) messages") }
        if let c = selectionCalls?.summary { parts.append(c) }
        if let v = selectionVoicemails, v > 0 { parts.append(v == 1 ? "1 voicemail" : "\(v.formatted()) voicemails") }
        return parts.joined(separator: " · ")
    }

    // MARK: recordings

    /// "Voicemail from Alice", a memo's title, a meeting's title.
    func recordingTitle(_ r: RecordingRow) -> String {
        if r.isVoicemail {
            var who: String?
            if let h = r.handleID, let p = people.person(ofHandle: h) { who = displayName(p) }
            else if let a = r.address, let p = people.person(normalized: a) { who = displayName(p) }
            else if let n = r.name, !n.isEmpty { who = n }
            else if let a = r.address { who = Fmt.phone(a) }
            return "Voicemail" + (who.map { " from " + $0 } ?? "")
        }
        if let t = r.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return r.isMeeting ? "Recorded meeting" : "Voice memo"
    }

    /// One recording again, with its transcripts' timings.
    func recordingWithTimings(_ id: Int64) async -> RecordingRow? {
        guard let reader else { return nil }
        struct One: @unchecked Sendable { var row: RecordingRow? }
        return (try? await Task.detached { One(row: try reader.recording(id: id)) }.value)?.row
    }

    /// The media store's file of a recording's audio, its playable copy or a meeting's chat, when it is there.
    func mediaURL(recordingSha sha: String) -> URL? {
        guard let a = try? reader?.recordingMedia(sha256: sha) else { return nil }
        return fileURL(a.mediaPath)
    }

    /// A voice message's playable file: the attachment itself, or its copy.
    func mediaURL(voicePlay v: VoiceMessageInfo, attachment: AttachmentInfo) -> URL? {
        if v.playSha256 == attachment.sha256 { return fileURL(attachment.mediaPath) }
        guard let a = try? reader?.voiceMessageMedia(sha256: v.playSha256) else { return nil }
        return fileURL(a.mediaPath)
    }

    private func fileURL(_ rel: String) -> URL? {
        guard rel.hasPrefix(ArchiveRoot.mediaDirName + "/"), !rel.contains(".."), root.mediaContains(relativePath: rel) else { return nil }
        let u = root.resolve(relativePath: rel)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Opens a voicemail's conversation (its caller as a person, else the 1:1 thread) at its time when the time is its own.
    func openConversation(of r: RecordingRow) {
        let jump: JumpTarget? = r.timeIsOwn ? r.tsMs.map { .voicemail(id: r.id, ts: $0) } : nil
        // a voicemail shows with SMS: a service filter left on from before could hide it
        serviceFilter = nil
        var pid: Int64?
        if let h = r.handleID { pid = people.personOfHandle[h] }
        if pid == nil, let a = r.address { pid = people.person(normalized: a)?.id }
        if let pid, people.persons[pid] != nil { select(.person(pid), jump: jump, force: true) }
        else if let t = r.threadID { select(.thread(t), jump: jump, force: true) }
    }

    /// Services with messages in the open person's timeline, with counts (the filter chips).
    var selectionServiceCounts: [(ServiceKey, Int)] {
        guard case .person(let p) = selection else { return [] }
        var counts: [ServiceKey: Int] = [:]
        for t in threads(ofPerson: p) { for (k, v) in conversationByID[t]?.serviceCounts ?? [:] { counts[k, default: 0] += v } }
        return counts.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private func rebuildRows() {
        let source = conversations
        let roll = PeopleList.roll(conversations: source, index: people, includeHidden: showHidden)
        var out: [ConversationRow] = []
        out.reserveCapacity(roll.people.count + roll.groups.count + roll.orphans.count)
        for r in roll.people {
            let title = displayName(r.person)
            var key = title.lowercased()
            for h in r.person.handles {
                key += " " + (h.name ?? "").lowercased() + " " + h.raw.lowercased() + " " + h.normalized
                    + " " + (contacts.names[h.normalized] ?? "").lowercased() + " " + h.raw.filter { $0.isNumber }
            }
            out.append(ConversationRow(id: .person(r.id), title: title, isGroup: false, messageCount: r.messageCount, lastTsMs: r.lastTsMs,
                                       preview: r.preview, services: r.services, searchKey: key, handleCount: r.person.handles.count,
                                       hiddenThreads: r.hiddenThreads, isHiddenRow: r.person.hidden || r.hiddenThreads == r.threadIDs.count,
                                       threadIDs: r.threadIDs, callCount: CallCount.sum(r.person.handles.map(\.handleID), in: callCounts).calls))
        }
        for c in roll.groups + roll.orphans {
            let t = title(for: c)
            var key = t.lowercased()
            for m in c.members { key += " " + memberName(m).lowercased() + " " + m.normalized + " " + m.raw.filter { $0.isNumber || $0.isLetter } }
            out.append(ConversationRow(id: .thread(c.id), title: t, isGroup: c.isGroup, messageCount: c.messageCount, lastTsMs: c.lastTsMs,
                                       preview: c.preview, services: c.services, searchKey: key, hiddenThreads: c.hidden ? 1 : 0,
                                       isHiddenRow: c.hidden, threadIDs: [c.id],
                                       callCount: c.isGroup ? 0 : CallCount.sum(c.members.map(\.handleID), in: callCounts).calls))
        }
        rows = out
        var titles: [Int64: String] = [:]
        for c in allConversations {
            if !c.isGroup, let pid = people.personOfThread[c.id], let p = people.persons[pid] { titles[c.id] = displayName(p) }
            else { titles[c.id] = title(for: c) }
        }
        threadTitles = titles
    }

    private func hiddenToggled() {
        rebuildRows()
        if let s = selection, case .person = s { select(s, force: true) }
    }

    private func recomputeVisible() {
        let q = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        var out = rows
        if !q.isEmpty {
            let terms = q.split(separator: " ").map(String.init)
            let digits = q.filter(\.isNumber)
            out = out.filter { r in terms.allSatisfy { r.searchKey.contains($0) } || (digits.count >= 3 && r.searchKey.contains(digits)) }
        }
        switch sort {
        case .recent: out.sort { $0.lastTsMs > $1.lastTsMs }
        case .messages: out.sort { $0.messageCount > $1.messageCount }
        }
        visibleRows = out
    }

    // MARK: selection

    /// `voicemail`: the window around a voicemail's time, scrolled to its card (a voicemail before the first message or after the last
    /// is still the one shown).
    enum JumpTarget { case latest, message(Int64), date(Int64), voicemail(id: Int64, ts: Int64) }

    /// The messages the open item shows.
    var selectionScope: MessageScope? {
        switch selection {
        case .person(let p): return MessageScope(threads: threads(ofPerson: p), services: serviceFilter)
        case .thread(let t): return MessageScope(thread: t)
        case nil: return nil
        }
    }

    /// Opens a person or a conversation. With a month filter active it opens at that month; `jump` overrides.
    func select(_ item: ListItemID?, jump: JumpTarget? = nil, force: Bool = false) {
        guard item != selection || jump != nil || force else { return }
        if item != selection { serviceFilter = nil }
        selection = item
        if searchScope == .thread, isSearching { searchChanged(immediately: true) }
        guard item != nil, let scope = selectionScope, let reader else { thread = nil; scopeMonths = []; return }
        var isGroup = false
        var merged = false
        switch item {
        case .thread(let t): isGroup = conversationByID[t]?.isGroup ?? false
        case .person: merged = true
        case nil: break
        }
        let model = ThreadModel(scope: scope, isGroup: isGroup, isMerged: merged, reader: reader, root: root)
        thread = model
        var start = jump ?? .latest
        if jump == nil, let mf = monthFilter, let r = Fmt.monthRangeMs(mf.year, mf.month) { start = .date(r.lowerBound) }
        threadTask = Task { await model.start(start) }
        scopeMonths = []
        monthsTask = Task {
            let months = try? await Task.detached { try reader.monthCounts(scope: scope) }.value
            if self.selection == item { self.scopeMonths = months ?? [] }
        }
        coverageScope = .thread
        if case .person = item { loadPersonPosts() } else { postsLoader.open(person: nil, handles: [], source: nil) }
    }

    func select(person id: Int64?, jump: JumpTarget? = nil) { select(id.map { .person($0) }, jump: jump) }
    func select(thread id: Int64?, jump: JumpTarget? = nil) { select(id.map { .thread($0) }, jump: jump) }

    /// Which services the open person's timeline shows. Tapping a chip while everything is on shows only that service.
    func toggleService(_ k: ServiceKey) {
        let available = Set(selectionServiceCounts.map(\.0))
        guard available.contains(k) else { return }
        var current = serviceFilter ?? available
        if serviceFilter == nil { current = [k] }
        else if current.contains(k) { current.remove(k) } else { current.insert(k) }
        if current.isEmpty || current == available { serviceFilter = nil } else { serviceFilter = current }
        if let s = selection { select(s, force: true) }
    }

    func clearServiceFilter() {
        serviceFilter = nil
        if let s = selection { select(s, force: true) }
    }

    func open(hit: SearchHit) {
        selectedHitID = hit.messageID
        serviceFilter = nil
        if let c = conversationByID[hit.threadID], !c.isGroup, let pid = people.personOfThread[hit.threadID], let p = people.persons[pid],
           showHidden || (!c.hidden && !p.hidden) {
            select(.person(pid), jump: .message(hit.messageID), force: true)
        } else {
            select(.thread(hit.threadID), jump: .message(hit.messageID), force: true)
        }
    }

    func jumpInOpenThread(toDate d: Date) {
        guard let t = thread else { return }
        threadTask = Task { await t.start(.date(Int64(d.timeIntervalSince1970 * 1000))) }
    }

    // MARK: coverage

    var activeMonths: [MonthCount] {
        coverageScope == .thread && thread != nil ? scopeMonths : archiveMonths
    }

    /// Strip click: with a conversation open in "This conversation" scope, scroll it to that month; otherwise filter the
    /// conversation list to the conversations that have messages in that month (click again to clear).
    func coverageClick(_ m: MonthKey) {
        highlightedMonth = m
        if coverageScope == .thread, thread != nil, let r = Fmt.monthRangeMs(m.year, m.month) {
            let t = thread
            threadTask = Task { await t?.start(.date(r.lowerBound)) }
            return
        }
        if monthFilter == m { setMonthFilter(nil) } else { setMonthFilter(m) }
    }

    func setMonthFilter(_ m: MonthKey?) {
        monthFilter = m
        if m == nil { highlightedMonth = nil } else { highlightedMonth = m }
        if m != nil { searchText = ""; searchHits = [] }
        guard let reader else { return }
        guard let range = m.flatMap({ Fmt.monthRangeMs($0.year, $0.month) }) else {
            rangeConversations = nil
            rebuildRows()
            return
        }
        listTask = Task {
            let list = try? await Task.detached { try reader.conversations(range: range, includeHidden: true) }.value
            if self.monthFilter == m, let list { self.rangeConversations = list; self.rebuildRows() }
        }
    }

    // MARK: fixing matches

    func present(_ s: PeopleSheet) {
        mergeQuery = ""; mergePick = nil; splitPicks = []
        if case .rename(let p) = s { renameText = people.persons[p].map(displayName) ?? "" }
        sheet = s
    }

    private func run(_ what: String, _ body: (PeopleOverrides, PeopleIndex) throws -> ListItemID?) {
        do {
            let ov = try PeopleOverrides(root: root)
            let next = try body(ov, people)
            peopleTask = Task {
                await self.reloadPeople()
                if let next { self.select(next, force: true) }
            }
        } catch {
            actionError = "Couldn't \(what): \(error)"
        }
    }

    func rename(person id: Int64, to name: String?) {
        run("rename") { ov, idx in
            try PeopleActions.rename(person: id, to: name, in: idx, overrides: ov)
            return .person(id)
        }
    }

    func merge(person id: Int64, with other: Int64) {
        run("merge") { ov, idx in
            try PeopleActions.merge([id, other], in: idx, overrides: ov).map { .person($0) }
        }
    }

    func split(person id: Int64, handleIDs: [Int64]) {
        run("split") { ov, idx in
            guard let r = try PeopleActions.split(person: id, handleIDs: handleIDs, in: idx, overrides: ov) else {
                self.actionError = "Pick at least one account to split off, and leave at least one behind."
                return nil
            }
            return .person(r.splitOff)
        }
    }

    func setHidden(person id: Int64, _ hidden: Bool) {
        run(hidden ? "hide" : "unhide") { ov, idx in
            try PeopleActions.setHidden(person: id, hidden, in: idx, overrides: ov)
            return hidden && !self.showHidden ? nil : .person(id)
        }
    }

    func resetCorrections(person id: Int64) {
        run("reset") { ov, idx in
            try PeopleActions.reset(person: id, in: idx, overrides: ov)
            return .person(id)
        }
    }

    // MARK: search

    func searchChanged(immediately: Bool = false) {
        searchTask?.cancel()
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let reader = searchReader else {
            searchHits = []; searchRunning = false
            return
        }
        searchRunning = true
        let scope: MessageScope? = searchScope == .thread ? selectionScope : nil
        let order = searchOrder
        let limit = searchHitLimit
        if searchScope == .posts {
            searchTask = Task {
                if !immediately { try? await Task.sleep(nanoseconds: 220_000_000) }
                if Task.isCancelled { return }
                let t0 = Date()
                let postOrder: PostsOrder = order == .newest ? .newest : order == .oldest ? .oldest : .best
                let hits = try? await Task.detached(priority: .userInitiated) { try reader.searchPosts(text, order: postOrder, limit: limit) }.value
                if Task.isCancelled { return }
                self.postHits = hits ?? []
                self.searchHits = []
                self.searchSeconds = Date().timeIntervalSince(t0)
                self.searchRunning = false
            }
            return
        }
        postHits = []
        searchTask = Task {
            if !immediately { try? await Task.sleep(nanoseconds: 220_000_000) }
            if Task.isCancelled { return }
            let t0 = Date()
            let hits = try? await Task.detached(priority: .userInitiated) {
                try reader.search(text, scope: scope, order: order, limit: limit)
            }.value
            if Task.isCancelled { return }
            self.searchHits = hits ?? []
            self.searchSeconds = Date().timeIntervalSince(t0)
            self.searchRunning = false
        }
    }

    /// Waits for every background load started so far (used by the snapshot runner and tests).
    func settle() async {
        await threadTask?.value; await monthsTask?.value; await listTask?.value; await searchTask?.value; await peopleTask?.value
        await postsLoader.settle()
    }

    func resetHitLimit() { searchHitLimit = 200 }

    /// Search shows 200 hits at a time; this asks for 200 more.
    func loadMoreHits() {
        searchHitLimit += 200
        searchChanged(immediately: true)
    }

    func clearSearch() { searchText = ""; searchHits = []; postHits = []; selectedHitID = nil }

    // MARK: posts

    /// A person opened: back to their messages, their total counted so the toggle shows only when they have posts.
    func loadPersonPosts() {
        let p = selectedPerson
        postsLoader.open(person: p?.id, handles: p?.handles.map(\.handleID) ?? [], source: reader.map(PersonPostsLoader.Source.archive))
    }

    /// The next page of the open person's posts (no silent stop at 2,000).
    func loadMorePersonPosts() { postsLoader.loadMore() }
}
