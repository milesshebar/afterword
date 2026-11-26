import Foundation

// The read-only web app's data layer: what the JSON API serves, computed from ArchiveReader (so hidden duplicate rows,
// reactions and system notes come out exactly as the Mac app sees them) and from people.sqlite read read-only.
// Nothing here writes. Names are only ever looked up, never stored.

public struct WebPerson: Encodable, Sendable {
    public var id: Int64
    public var name: String
    /// message count per service ("sms", "imessage", "messenger", "instagram", "groupme", "skype", "whatsapp", "snapchat"); only services with messages
    public var services: [String: Int]
    public var messages: Int
    public var lastTs: Int64
    public var preview: String?
    public var threads: [Int64]
    public var usernames: [String]
    public var hidden: Bool
    /// calls with this person, every service (left out when none)
    public var calls: Int?
    /// voicemails this person left (left out when none)
    public var voicemails: Int?
}

public struct WebGroup: Encodable, Sendable {
    public var id: Int64
    public var title: String
    public var members: Int
    public var messages: Int
    public var lastTs: Int64
    public var preview: String?
    public var service: String
    public var hidden: Bool
}

public struct WebPeople: Encodable, Sendable {
    public var people: [WebPerson]
    public var groups: [WebGroup]
    public var generatedAt: Int64
}

public struct WebMonth: Encodable, Sendable { public var y: Int; public var m: Int; public var n: Int }

public struct WebHandle: Encodable, Sendable {
    public var id: Int64
    public var service: String
    public var display: String
    public var name: String?
    public var username: String?
    public var messages: Int
}

public struct WebThread: Encodable, Sendable {
    public var id: Int64
    public var service: String
    public var messages: Int
    public var firstTs: Int64?
    public var lastTs: Int64?
    public var isGroup: Bool
    public var title: String?
    public var members: [String]
    /// A 1:1 thread opened on its own: calls with its person (left out when none, and for groups)
    public var calls: Int?
    /// A 1:1 thread opened on its own: voicemails its person left (left out when none, and for groups)
    public var voicemails: Int?
}

public struct WebPersonDetail: Encodable, Sendable {
    public var id: Int64
    public var name: String
    public var handles: [WebHandle]
    public var threads: [WebThread]
    public var services: [String: Int]
    public var messages: Int
    public var months: [WebMonth]
    /// Facebook and Instagram posts and comments with this person (0 when the archive has none)
    public var posts: Int = 0
    /// Calls with this person (every service, Messenger and Instagram included) and the time talked
    public var calls: Int = 0
    public var callSeconds: Int64 = 0
    /// Voicemails this person left
    public var voicemails: Int = 0
}

/// A page of a person's posts and comments: lines (a post, a comment, or an album's photos of one day folded into one line).
public struct WebPosts: Encodable, Sendable {
    public var entries: [PostEntry]
    /// For the next page: the last item's time and id (nil when this was the last page).
    public var nextTs: Int64?
    public var nextID: String?
}

public struct WebReaction: Encodable, Sendable { public var emoji: String; public var me: Bool; public var name: String? }

public struct WebAttachment: Encodable, Sendable {
    public var id: Int64
    public var sha: String
    public var mime: String?
    public var name: String?
    public var bytes: Int64
    /// image, video, audio or file
    public var kind: String
    /// A voice message (audio with a machine transcript beside it): the content hash a browser plays (`/media/<play>`: the file itself, or an
    /// AAC copy of a format browsers do not play), its length, and the transcript. Nil for any other attachment.
    public var play: String? = nil
    public var duration: Double? = nil
    public var transcripts: [WebTranscript]? = nil
}

public struct WebMessage: Encodable, Sendable {
    public var id: Int64
    public var thread: Int64
    public var ts: Int64
    public var me: Bool
    public var service: String
    public var body: String?
    public var subject: String?
    public var sender: String?
    public var kind: String?
    public var note: String?
    public var reactions: [WebReaction]
    public var attachments: [WebAttachment]
}

public struct WebMessages: Encodable, Sendable {
    public var messages: [WebMessage]
    /// For `around`: the index of the requested message in `messages` (or nil when it was not found).
    public var at: Int?
    /// When the page sent its zone: the calendar events of the days these messages fall on (only days that have events).
    public var events: [WebEventDay]?
    /// The calls this page's span holds (phone, FaceTime, WhatsApp, Skype ...; Messenger, Instagram and GroupMe calls are messages
    /// already), oldest first. The spans of consecutive pages tile the timeline: a page reaching an end of the conversation also carries
    /// every call beyond it, so the page shows a call when its time is inside the window it has loaded.
    public var calls: [WebCall]?
    /// The voicemails this page's span holds, left by the timeline's person (the same spans as `calls`), oldest first.
    public var voicemails: [WebRecording]?
}

/// A transcript of a recording as the page shows it: always labeled as a machine transcript, never as anyone's verified words.
public struct WebTranscript: Encodable, Sendable {
    /// machine (made on the Mac by `model`) | apple (the phone's own voicemail transcription)
    public var origin: String
    public var model: String
    public var text: String
    public var segments: [WebSegment]?
}

public struct WebSegment: Codable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
}

/// One voicemail, voice memo or recorded meeting.
public struct WebRecording: Encodable, Sendable {
    public var id: Int64
    /// voicemail | memo | meeting
    public var kind: String
    public var ts: Int64?
    /// false: `ts` is when the file was exported or written, an upper bound, not when it was recorded
    public var timeIsOwn: Bool
    public var datedBy: String?
    public var duration: Double
    /// A memo's title; a voicemail's caller ("Voicemail from ...")
    public var title: String
    /// voicemail: the caller's name or number, when known
    public var who: String?
    public var person: Int64?
    public var thread: Int64?
    public var heard: Bool?
    public var deleted: Bool?
    /// speech | no-speech | music | noise
    public var content: String?
    /// the content hash a browser plays (`/media/<audio>`); nil when the source held no audio
    public var audio: String?
    public var mime: String?
    /// the source's own file when it is not the one played (an AMR voicemail)
    public var original: String?
    public var note: String?
    public var source: String
    public var transcripts: [WebTranscript]
    /// a search hit: the matched words between U+0001 and U+0002
    public var snippet: String?
    /// a meeting's saved chat (`/media/<chat>`, plain text)
    public var chat: String? = nil
}

/// A page of the recordings list, newest first.
public struct WebRecordings: Encodable, Sendable {
    public var recordings: [WebRecording]
    public var nextTs: Int64?
    public var nextID: Int64?
    public var voicemails: Int
    public var memos: Int
    public var seconds: Double
    public var meetings: Int = 0
}

/// One call as a line in a timeline.
public struct WebCall: Encodable, Sendable {
    public var id: Int64
    public var ts: Int64
    public var me: Bool
    /// The filter chip this call goes with (sms for phone calls, imessage for FaceTime ...), nil when none
    public var service: String?
    /// The call's own service: phone, facetime-audio, facetime-video, whatsapp, skype ...
    public var kind: String
    public var outcome: String
    public var duration: Int64
    /// "Outgoing phone call · 12 min", "Missed FaceTime video call"
    public var label: String
}

/// One calendar event as the web app shows it under a day header. `floating`: the time has no zone and reads in UTC.
public struct WebEvent: Encodable, Sendable {
    public var summary: String
    public var start: Int64
    public var end: Int64?
    public var allDay: Bool
    public var floating: Bool
    public var recurring: Bool
    public var location: String?
    public var calendar: String?
}

/// A day (`yyyymmdd` in the viewer's zone, the page's own `dayKey`) and its events, all-day first.
public struct WebEventDay: Encodable, Sendable {
    public var day: Int
    public var events: [WebEvent]
}

public struct WebHit: Encodable, Sendable {
    public var id: Int64
    public var thread: Int64
    public var person: Int64?
    public var ts: Int64
    public var me: Bool
    public var service: String
    public var sender: String?
    /// Where the hit lives: the person's name, or the group's title.
    public var `where`: String
    /// Snippet with U+0001 / U+0002 around the matched words.
    public var snippet: String
    /// true: the words matched the message's voice message (its machine transcript), and the snippet is from that transcript
    public var voice: Bool? = nil
}

public struct WebOverview: Encodable, Sendable {
    public var messages: Int
    public var threads: Int
    public var people: Int
    public var groups: Int
    public var firstTs: Int64?
    public var lastTs: Int64?
    public var demo: Bool
    public var months: [WebMonth]
    /// voicemails and voice memos in the archive (0: the page shows no Recordings button)
    public var recordings: Int = 0
}

public struct WebError: Error, CustomStringConvertible, Sendable {
    public let status: Int
    public let description: String
    public init(_ status: Int, _ message: String) { self.status = status; description = message }
}

public final class WebService: @unchecked Sendable {
    public let root: ArchiveRoot
    public let reader: ArchiveReader
    private let lock = NSLock()
    private var index = PeopleIndex.empty
    private var summaries: [Int64: ConversationSummary] = [:]
    private var roll = ListRoll(people: [], groups: [], orphans: [])
    private var rollTs: Int64 = 0
    private var callCounts: [Int64: CallCount] = [:]
    private var voicemailCounts: [Int64: Int] = [:]
    private var peopleSignature = FileSignature()
    public private(set) var lastRefreshSeconds = 0.0

    public static let pageLimit = 200
    public static let searchLimit = 100

    public init(root: ArchiveRoot) throws {
        self.root = root
        reader = try ArchiveReader(root: root)
        try refresh()
    }

    // MARK: people index

    /// Size, mtime and inode of people.sqlite: when they change (an app or review-site correction), the index is rebuilt
    /// before the next answer.
    struct FileSignature: Equatable {
        var exists = false, size = 0, modified = Date.distantPast, inode: UInt64 = 0
        init() {}
        init(root: ArchiveRoot) {
            guard let a = try? FileManager.default.attributesOfItem(atPath: PeopleOverrides.fileURL(root: root).path) else { return }
            exists = true
            size = (a[.size] as? NSNumber)?.intValue ?? 0
            modified = (a[.modificationDate] as? Date) ?? .distantPast
            inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }
    }

    /// Rebuilds the person mapping and the conversation list (a few seconds on the real archive).
    public func refresh() throws {
        let t0 = Date()
        let overrides = PeopleOverrides.read(root: root)
        let idx = try reader.people(overrides: overrides)
        let convs = try reader.conversations(includeHidden: true)
        let r = PeopleList.roll(conversations: convs, index: idx, includeHidden: true)
        let calls = try reader.callCountsByHandle()
        let voicemails = try reader.voicemailCountsByHandle()
        lock.lock(); defer { lock.unlock() }
        index = idx
        callCounts = calls
        voicemailCounts = voicemails
        summaries = Dictionary(convs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        roll = r
        rollTs = Int64(Date().timeIntervalSince1970 * 1000)
        peopleSignature = FileSignature(root: root)
        lastRefreshSeconds = Date().timeIntervalSince(t0)
    }

    private func synced<T>(_ body: () throws -> T) throws -> T {
        if FileSignature(root: root) != (lock.withLock { peopleSignature }) { try refresh() }
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    // MARK: names

    /// +12125550101 -> (212) 555-0101; emails and other handles as stored.
    public static func prettyHandle(_ normalized: String) -> String {
        let digits = normalized.filter(\.isNumber)
        if normalized.hasPrefix("+1"), digits.count == 11 {
            let d = Array(digits.dropFirst())
            return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
        }
        return normalized
    }

    static func displayName(_ p: Person) -> String {
        if let n = p.name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty, n != "null" { return n }
        let named = p.handles.sorted { $0.messages > $1.messages }
        if let n = named.compactMap(\.name).first(where: { !$0.isEmpty && $0 != "(Unknown)" && $0 != "null" }) { return n }
        if let u = p.usernames.first { return "@" + u }
        return named.first.map { Self.prettyHandle($0.normalized) } ?? "Unknown"
    }

    private func senderName(_ row: MessageRow) -> String? {
        guard !row.isFromMe else { return nil }
        if let h = row.senderHandleID, let p = index.person(ofHandle: h) { return Self.displayName(p) }
        if let n = row.senderArchiveName, !n.isEmpty { return n }
        return row.senderNormalized.map(Self.prettyHandle)
    }

    private func actorName(_ r: ReactionInfo) -> String? {
        if r.byMe { return nil }
        if let n = r.actorNormalized, let p = index.person(normalized: n) { return Self.displayName(p) }
        return r.actorArchiveName ?? r.actorNormalized.map(Self.prettyHandle)
    }

    private func groupTitle(_ c: ConversationSummary) -> String {
        if let t = c.storedTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t != "null" { return t }
        let names = c.members.prefix(4).map { m -> String in
            if let p = index.person(ofHandle: m.handleID) { return Self.displayName(p).split(separator: " ").first.map(String.init) ?? Self.displayName(p) }
            return m.archiveName?.split(separator: " ").first.map(String.init) ?? Self.prettyHandle(m.normalized)
        }
        return names.isEmpty ? "Group" : names.joined(separator: ", ") + (c.members.count > 4 ? " +\(c.members.count - 4)" : "")
    }

    // MARK: lists

    public func overview() throws -> WebOverview {
        let o = try reader.overview()
        let months = try reader.monthCounts().map { WebMonth(y: $0.year, m: $0.month, n: $0.count) }
        let rec = try reader.recordingCounts()
        return try synced {
            WebOverview(messages: o.messages, threads: o.threads, people: roll.people.filter { !$0.person.hidden }.count,
                        groups: roll.groups.filter { !$0.hidden }.count, firstTs: o.firstTsMs, lastTs: o.lastTsMs, demo: o.isDemo, months: months,
                        recordings: rec.voicemails + rec.memos + rec.meetings)
        }
    }

    /// Everyone (and every group), most recent first. Hidden people and threads are included with `hidden: true` so the page can
    /// offer "Show hidden" without a second request; orphan 1:1 threads (no person) are listed as groups of one.
    public func people() throws -> WebPeople {
        try synced {
            var people = roll.people.map { r -> WebPerson in
                var services: [String: Int] = [:]
                for (k, v) in r.serviceCounts where v > 0 { services[k.rawValue] = v }
                let calls = CallCount.sum(r.person.handles.map(\.handleID), in: callCounts).calls
                let vms = Set(r.person.handles.map(\.handleID)).reduce(0) { $0 + (voicemailCounts[$1] ?? 0) }
                return WebPerson(id: r.person.id, name: Self.displayName(r.person), services: services, messages: r.messageCount, lastTs: r.lastTsMs,
                                 preview: r.preview, threads: r.threadIDs, usernames: r.person.usernames, hidden: r.person.hidden,
                                 calls: calls > 0 ? calls : nil, voicemails: vms > 0 ? vms : nil)
            }
            people.sort { $0.lastTs != $1.lastTs ? $0.lastTs > $1.lastTs : $0.id < $1.id }
            var groups = (roll.groups + roll.orphans).map { c in
                WebGroup(id: c.id, title: groupTitle(c), members: c.members.count, messages: c.messageCount, lastTs: c.lastTsMs, preview: c.preview,
                         service: c.services.first?.rawValue ?? ServiceKey.of(messageService: c.service ?? "sms").rawValue, hidden: c.hidden)
            }
            groups.sort { $0.lastTs != $1.lastTs ? $0.lastTs > $1.lastTs : $0.id < $1.id }
            return WebPeople(people: people, groups: groups, generatedAt: rollTs)
        }
    }

    public func person(_ id: Int64) throws -> WebPersonDetail {
        let (p, row, calls, vms) = try synced { () -> (Person, PersonRow, CallCount, Int) in
            guard let p = index.persons[id] else { throw WebError(404, "no such person") }
            let row = roll.people.first { $0.person.id == id } ?? PersonRow(person: p, threadIDs: p.threadIDs, messageCount: 0, lastTsMs: 0, preview: nil, serviceCounts: [:], hiddenThreads: 0)
            return (p, row, CallCount.sum(p.handles.map(\.handleID), in: callCounts), Set(p.handles.map(\.handleID)).reduce(0) { $0 + (voicemailCounts[$1] ?? 0) })
        }
        let months = try reader.monthCounts(scope: MessageScope(threads: row.threadIDs)).map { WebMonth(y: $0.year, m: $0.month, n: $0.count) }
        var threads: [WebThread] = []
        for t in row.threadIDs {
            let range = try reader.messageRange(thread: t)
            let c = lock.withLock { summaries[t] }
            threads.append(WebThread(id: t, service: c?.services.first?.rawValue ?? "sms", messages: c?.messageCount ?? 0, firstTs: range?.first, lastTs: range?.last,
                                     isGroup: false, title: nil, members: []))
        }
        let handles = p.handles.sorted { $0.messages > $1.messages }.map { h in
            WebHandle(id: h.handleID, service: (h.service ?? .sms).rawValue, display: (h.service ?? .sms) != .sms && h.service != .imessage ? (h.name ?? h.raw) : Self.prettyHandle(h.normalized),
                      name: h.name, username: h.username ?? h.possibleUsername, messages: h.messages)
        }
        var services: [String: Int] = [:]
        for (k, v) in row.serviceCounts where v > 0 { services[k.rawValue] = v }
        var d = WebPersonDetail(id: id, name: Self.displayName(p), handles: handles, threads: threads, services: services, messages: row.messageCount, months: months)
        d.posts = (try? reader.postCount(handles: p.handles.map(\.handleID))) ?? 0
        d.calls = calls.calls; d.callSeconds = calls.seconds
        d.voicemails = vms
        return d
    }

    // MARK: posts and comments

    /// A person's posts and comments, newest first, album photos of one album and one day (in the viewer's zone) folded.
    private func personHandles(_ id: Int64) throws -> [Int64] {
        try synced { () -> [Int64] in
            guard let p = index.persons[id] else { throw WebError(404, "no such person") }
            return p.handles.map(\.handleID)
        }
    }

    /// A person's posts and comments, newest first, album photos of one album and one day folded in `zone` (the viewer's zone,
    /// so each row's own date decides its day, daylight saving included).
    public func posts(person id: Int64, before: (ts: Int64, id: String)?, limit: Int, zone: TimeZone) throws -> WebPosts {
        let handles = try personHandles(id)
        let items = try reader.posts(handles: handles, limit: limit, before: before)
        let last = items.count == limit ? items.last : nil
        return WebPosts(entries: ArchiveReader.groupAlbums(items, zone: zone), nextTs: last?.ts, nextID: last?.id)
    }

    /// Posts and comments matching the words, everywhere or with one person, best match, newest or oldest first.
    public func searchPosts(_ text: String, person: Int64?, order: PostsOrder, limit: Int, offset: Int) throws -> [PostItem] {
        let filter = try person.map { PostsFilter(handles: try personHandles($0)) } ?? PostsFilter()
        return try reader.searchPosts(text, filter: filter, order: order, limit: limit, offset: offset)
    }

    public func thread(_ id: Int64) throws -> WebThread {
        let c = try synced { () -> ConversationSummary in
            guard let c = summaries[id] else { throw WebError(404, "no such thread") }
            return c
        }
        let range = try reader.messageRange(thread: id)
        let members = try synced {
            c.members.map { m -> String in
                if let p = index.person(ofHandle: m.handleID) { return Self.displayName(p) }
                return m.archiveName ?? Self.prettyHandle(m.normalized)
            }
        }
        let calls = c.isGroup ? 0 : try synced { CallCount.sum(c.members.map(\.handleID), in: callCounts).calls }
        let vms = c.isGroup ? 0 : try synced { Set(c.members.map(\.handleID)).reduce(0) { $0 + (voicemailCounts[$1] ?? 0) } }
        return WebThread(id: id, service: c.services.first?.rawValue ?? "sms", messages: c.messageCount, firstTs: range?.first, lastTs: range?.last,
                         isGroup: c.isGroup, title: try synced { groupTitle(c) }, members: members, calls: calls > 0 ? calls : nil,
                         voicemails: vms > 0 ? vms : nil)
    }

    public func months(scope: MessageScope) throws -> [WebMonth] {
        try reader.monthCounts(scope: scope).map { WebMonth(y: $0.year, m: $0.month, n: $0.count) }
    }

    // MARK: scopes

    /// A person's 1:1 threads (all of them, hidden included: the person was asked for by id) or one thread, optionally one or
    /// more services.
    public func scope(person: Int64?, thread: Int64?, services: Set<ServiceKey>?) throws -> MessageScope {
        try synced {
            if let person {
                guard let p = index.persons[person] else { throw WebError(404, "no such person") }
                let threads = roll.people.first { $0.person.id == person }?.threadIDs ?? p.threadIDs
                return MessageScope(threads: threads, services: services)
            }
            if let thread {
                guard summaries[thread] != nil else { throw WebError(404, "no such thread") }
                return MessageScope(threads: [thread], services: services)
            }
            throw WebError(400, "person or thread required")
        }
    }

    public static func services(_ list: String?) -> Set<ServiceKey>? {
        guard let list, !list.isEmpty else { return nil }
        let keys = Set(list.split(separator: ",").compactMap { ServiceKey(rawValue: String($0)) })
        return keys.isEmpty ? nil : keys
    }

    // MARK: messages

    func convert(_ rows: [MessageRow]) throws -> [WebMessage] {
        // voice messages: the transcripts and playable copies of the page's audio attachments
        let voice = try reader.voiceMessages(shas: Set(rows.flatMap { $0.attachments.filter(\.isAudio).map(\.sha256) }))
        return try synced {
            rows.map { r in
                WebMessage(id: r.id, thread: r.threadID, ts: r.tsMs, me: r.isFromMe, service: r.serviceKey.rawValue, body: r.body, subject: r.subject,
                           sender: senderName(r), kind: r.kind, note: r.note,
                           reactions: r.reactions.map { WebReaction(emoji: $0.emoji, me: $0.byMe, name: actorName($0)) },
                           attachments: r.attachments.map { a in
                               var w = WebAttachment(id: a.id, sha: a.sha256, mime: a.mime, name: a.filename, bytes: a.bytes,
                                                     kind: a.isImage ? "image" : a.isVideo ? "video" : a.isAudio ? "audio" : "file")
                               if a.isAudio, let v = voice[a.sha256] {
                                   w.play = v.playSha256; w.duration = v.durationS
                                   w.transcripts = v.transcripts.map { Self.webTranscript($0) }
                               }
                               return w
                           })
            }
        }
    }

    public func latest(scope: MessageScope, limit: Int, zone: TimeZone? = nil) throws -> WebMessages {
        let rows = try reader.latest(scope: scope, limit: limit)
        let span = CallSpan(lower: rows.count < limit ? nil : rows.first?.tsMs, upper: nil)
        return try withCalls(withEvents(WebMessages(messages: try convert(rows), at: nil), zone: zone), scope: scope, span: span)
    }

    public func before(scope: MessageScope, key: MessageKey, limit: Int, zone: TimeZone? = nil) throws -> WebMessages {
        let rows = try reader.before(scope: scope, key: key, limit: limit)
        // up to the cursor message's time, not including it: the page that holds the cursor carries the calls at that time
        let span = CallSpan(lower: rows.count < limit ? nil : rows.first?.tsMs, upper: key.tsMs, upperInclusive: false)
        return try withCalls(withEvents(WebMessages(messages: try convert(rows), at: nil), zone: zone), scope: scope, span: span)
    }

    public func after(scope: MessageScope, key: MessageKey, limit: Int, zone: TimeZone? = nil) throws -> WebMessages {
        let rows = try reader.after(scope: scope, key: key, limit: limit)
        let span = CallSpan(lower: key.tsMs, lowerInclusive: false, upper: rows.count < limit ? nil : rows.last?.tsMs)
        return try withCalls(withEvents(WebMessages(messages: try convert(rows), at: nil), zone: zone), scope: scope, span: span)
    }

    /// A window around a message id (a search hit), or around the first message on or after a date.
    public func around(scope: MessageScope, message id: Int64?, atOrAfter ts: Int64?, side: Int, zone: TimeZone? = nil) throws -> WebMessages {
        var key: MessageKey?
        if let id {
            guard let k = try reader.key(ofMessage: id), scope.threadIDs.contains(k.thread) else { throw WebError(404, "no such message in this conversation") }
            key = k.key
        } else if let ts {
            key = try reader.firstMessage(scope: scope, atOrAfter: ts)
        }
        guard let key else { return try latest(scope: scope, limit: side * 2, zone: zone) }
        let rows = try reader.around(scope: scope, key: key, before: side, after: side)
        let at = rows.firstIndex { $0.id == key.id }
        let i = at ?? 0   // the page reads a missing index as 0, and so decides which ends it reached
        let span = CallSpan.window(firstTs: rows.first?.tsMs, lastTs: rows.last?.tsMs, reachedStart: i < side, reachedEnd: rows.count - i - 1 < side)
        return try withCalls(withEvents(WebMessages(messages: try convert(rows), at: at), zone: zone), scope: scope, span: span)
    }

    // MARK: calls

    private func withCalls(_ page: WebMessages, scope: MessageScope, span: CallSpan) throws -> WebMessages {
        var p = page
        let calls = try reader.calls(scope: scope, in: span)
        p.calls = calls.isEmpty ? nil : calls.map {
            WebCall(id: $0.id, ts: $0.tsMs, me: $0.isFromMe, service: $0.serviceKey?.rawValue, kind: $0.service, outcome: $0.outcome,
                    duration: $0.durationS, label: $0.label)
        }
        // the voicemails of the same span: a voicemail sits in its caller's timeline at its time, like the call it was
        let vms = try reader.voicemails(scope: scope, in: span)
        p.voicemails = vms.isEmpty ? nil : try convert(recordings: vms)
        return p
    }

    // MARK: voicemails and voice memos

    /// A voicemail's caller: the person the handle belongs to, else the name the source carried, else the number.
    private func caller(_ r: RecordingRow) -> (who: String?, person: Int64?) {
        if let h = r.handleID, let p = index.person(ofHandle: h) { return (Self.displayName(p), p.id) }
        if let a = r.address, let p = index.person(normalized: a) { return (Self.displayName(p), p.id) }
        if let n = r.name, !n.isEmpty { return (n, nil) }
        return (r.address.map(Self.prettyHandle), nil)
    }

    func convert(recordings rows: [RecordingRow]) throws -> [WebRecording] {
        try synced {
            rows.map { r in
                let c = r.isVoicemail ? caller(r) : (nil, nil)
                let title: String
                if r.isVoicemail { title = "Voicemail" + (c.0.map { " from " + $0 } ?? "") }
                else { title = r.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? r.title! : (r.isMeeting ? "Recorded meeting" : "Voice memo") }
                let transcripts = r.transcripts.map { Self.webTranscript($0) }
                return WebRecording(id: r.id, kind: r.kind, ts: r.tsMs, timeIsOwn: r.timeIsOwn, datedBy: r.datedBy, duration: r.durationS, title: title,
                                    who: c.0, person: c.1, thread: r.threadID, heard: r.heard, deleted: r.deleted, content: r.content,
                                    audio: r.playSha256, mime: r.playMime, original: r.sha256 != r.playSha256 ? r.sha256 : nil, note: r.note,
                                    source: r.sourceLabel, transcripts: transcripts, snippet: r.snippet, chat: r.chatSha256)
            }
        }
    }

    static func webTranscript(_ t: RecordingTranscript) -> WebTranscript {
        WebTranscript(origin: t.origin, model: t.model, text: t.text,
                      segments: t.segments.flatMap { try? JSONDecoder().decode([WebSegment].self, from: Data($0.utf8)) })
    }

    static func recordingKind(_ s: String?) throws -> String? {
        guard let s, !s.isEmpty, s != "all" else { return nil }
        guard RecordingImporter.kinds.contains(s) else { throw WebError(400, "kind must be voicemail, memo or meeting") }
        return s
    }

    /// One voice message's transcripts with their timings (`GET /api/voice/<sha256>`), for "Show all" under an audio attachment; the page
    /// picks the one it shows by origin and model.
    public func voiceMessage(sha256: String) throws -> [WebTranscript] {
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw WebError(400, "bad hash") }
        guard let v = try reader.voiceMessages(shas: [sha256], segments: true)[sha256] else { throw WebError(404, "no such voice message") }
        return v.transcripts.map { Self.webTranscript($0) }
    }

    /// Every voicemail and voice memo, newest first, one page.
    public func recordings(kind: String?, before: (ts: Int64, id: Int64)?, limit: Int) throws -> WebRecordings {
        let rows = try reader.recordings(kind: kind, before: before, limit: limit)
        let counts = try reader.recordingCounts()
        let last = rows.count == limit ? rows.last : nil
        return WebRecordings(recordings: try convert(recordings: rows), nextTs: last.map { $0.tsMs ?? 0 }, nextID: last?.id,
                             voicemails: counts.voicemails, memos: counts.memos, seconds: counts.seconds, meetings: counts.meetings)
    }

    public func searchRecordings(_ text: String, kind: String?, order: SearchOrder, limit: Int, offset: Int) throws -> [WebRecording] {
        try convert(recordings: try reader.searchRecordings(text, kind: kind, order: order, limit: limit, offset: offset))
    }

    /// One recording, with its transcripts' timings.
    public func recording(_ id: Int64) throws -> WebRecording {
        guard let r = try reader.recording(id: id) else { throw WebError(404, "no such recording") }
        return try convert(recordings: [r])[0]
    }

    // MARK: calendar

    /// The calendar events of the days a page of messages covers, in the viewer's zone (nil zone: an older page, no events).
    public func eventDays(forMessagesAt timestamps: [Int64], zone: TimeZone) throws -> [WebEventDay] {
        let keys = Set(timestamps.map { CalendarDays.key($0, in: zone) })
        return try reader.calendarDays(keys, zone: zone).map { d in
            WebEventDay(day: d.key, events: d.events.map {
                WebEvent(summary: $0.displaySummary, start: $0.startMs, end: $0.endMs, allDay: $0.allDay, floating: $0.floating,
                         recurring: $0.recurring, location: $0.location, calendar: $0.calendar)
            })
        }
    }

    private func withEvents(_ page: WebMessages, zone: TimeZone?) throws -> WebMessages {
        guard let zone else { return page }
        var p = page
        p.events = try eventDays(forMessagesAt: page.messages.map(\.ts), zone: zone)
        return p
    }

    // MARK: search

    public func search(_ text: String, scope: MessageScope?, order: SearchOrder, limit: Int, offset: Int) throws -> [WebHit] {
        let hits = try reader.search(text, scope: scope, order: order, limit: limit, offset: offset)
        return try synced {
            hits.map { h in
                let personID = index.personOfThread[h.threadID]
                let whereLabel: String
                if let c = summaries[h.threadID], c.isGroup { whereLabel = groupTitle(c) }
                else if let pid = personID, let p = index.persons[pid] { whereLabel = Self.displayName(p) }
                else if let c = summaries[h.threadID], let m = c.members.first { whereLabel = m.archiveName ?? Self.prettyHandle(m.normalized) }
                else { whereLabel = "Unknown" }
                var sender: String?
                if !h.isFromMe {
                    if let n = h.senderNormalized, let p = index.person(normalized: n) { sender = Self.displayName(p) }
                    else { sender = h.senderArchiveName ?? h.senderNormalized.map(Self.prettyHandle) }
                }
                return WebHit(id: h.messageID, thread: h.threadID, person: personID, ts: h.tsMs, me: h.isFromMe, service: h.service, sender: sender,
                              where: whereLabel, snippet: h.snippet, voice: h.isVoice ? true : nil)
            }
        }
    }

    // MARK: media

    /// The stored file for a content hash, checked to be a plain root-relative path inside media/.
    public func mediaFile(sha256: String) throws -> (url: URL, info: AttachmentInfo)? {
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw WebError(400, "bad hash") }
        guard let a = try reader.attachment(sha256: sha256) ?? reader.recordingMedia(sha256: sha256) ?? reader.voiceMessageMedia(sha256: sha256) else { return nil }
        let p = a.mediaPath
        guard !p.isEmpty, !p.hasPrefix("/"), !p.contains(".."), p.hasPrefix(ArchiveRoot.mediaDirName + "/") else { return nil }
        // inside the media folder also once symlinks are resolved (a symlinked folder must not let a hash name a file elsewhere)
        guard root.mediaContains(relativePath: p) else { return nil }
        let url = root.resolve(relativePath: p)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url, a)
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
