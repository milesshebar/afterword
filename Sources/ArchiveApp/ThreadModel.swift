import SwiftUI
import ArchiveCore

enum ThreadItemID: Hashable, Sendable {
    case day(Int)
    case message(Int64)
    case call(Int64)
    case voicemail(Int64)
}

struct ThreadItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case day(String)
        case message(MessageRow, showSender: Bool, showTime: Bool, tight: Bool)
        /// A call from the call logs at its time (1:1 timelines only)
        case call(CallRow, showTime: Bool)
        /// A voicemail its person left, at its time (1:1 timelines only): a card with a player and the transcripts
        case voicemail(RecordingRow, showTime: Bool)
    }
    var id: ThreadItemID
    var kind: Kind
}

struct ScrollRequest: Equatable {
    var token: Int
    var id: ThreadItemID
    var anchor: UnitPoint
}

/// One open conversation: a window of messages around where the reader is looking, paged lazily from SQLite. The window
/// is capped at `maxWindow` messages (the far edge is dropped as you page), so a 31,000-message thread costs one page
/// to open and stays cheap to scroll.
@MainActor @Observable
final class ThreadModel {
    static let page = 60
    /// Opening and jumping load small windows, because the stack lays out every row it holds; edge loading then
    /// extends them by a full page as soon as the reader gets near an edge.
    static let initialPage = 40
    static let jumpSide = 30
    /// The window never holds more than this many messages; paging in one edge drops the far edge, so every rebuild
    /// and SwiftUI diff stays bounded however far the reader scrolls.
    static let maxWindow = 5 * 60

    /// What this view shows: one thread, or all of a person's 1:1 threads merged by time (optionally one service).
    let scope: MessageScope
    let isGroup: Bool
    /// True for a person's merged timeline: bubbles carry a small service tag.
    let isMerged: Bool
    private let reader: ArchiveReader
    private let root: ArchiveRoot

    private(set) var messages: [MessageRow] = []
    /// The calls the window shows: between its first and last message, and past an end of the conversation it has reached.
    private(set) var calls: [CallRow] = []
    /// The voicemails of the same span as `calls`.
    private(set) var voicemails: [RecordingRow] = []
    /// The window's voice messages: what the archive holds beside an audio attachment (its playable copy and machine transcript).
    private(set) var voice: [String: VoiceMessageInfo] = [:]
    private(set) var items: [ThreadItem] = []
    private(set) var reachedStart = false
    private(set) var reachedEnd = true
    private(set) var loading = true
    private(set) var loadSeconds: Double = 0
    /// Edge loaders only fire once the pending scroll request has been applied, otherwise the first layout (at the top)
    /// would immediately page backwards.
    private(set) var armed = false
    private(set) var scrollRequest: ScrollRequest?
    private(set) var highlightID: Int64?
    private var tokenCounter = 0
    private var generation = 0
    private var pendingToken: Int?
    /// Holds the reader's place across page loads and window evictions (see `ScrollAnchorDriver`).
    let anchor = ScrollAnchorDriver()

    var quickLookURL: URL?
    var quickLookItems: [URL] = []

    init(scope: MessageScope, isGroup: Bool, isMerged: Bool = false, reader: ArchiveReader, root: ArchiveRoot) {
        self.scope = scope; self.isGroup = isGroup; self.isMerged = isMerged; self.reader = reader; self.root = root
    }

    private func fetch<T: Sendable>(_ work: @escaping @Sendable (ArchiveReader) throws -> T) async -> T? {
        let r = reader
        return try? await Task.detached(priority: .userInitiated) { try work(r) }.value
    }

    // MARK: window changes

    /// Replaces the window: newest messages, or a window centred on a message / the first message on or after a date.
    func start(_ target: AppModel.JumpTarget) async {
        generation += 1
        let gen = generation
        let t0 = Date()
        loading = true; armed = false
        anchor.suspend()
        let scope = scope, page = Self.initialPage, side = Self.jumpSide

        var voicemailID: Int64?
        if case .voicemail(let id, _) = target { voicemailID = id }
        func showLatest() async {
            let rows = await fetch { try $0.latest(scope: scope, limit: page) } ?? []
            let calls = await windowCalls(rows, reachedStart: rows.count < page, reachedEnd: true)
            guard gen == generation else { return }
            apply(rows, calls: calls, reachedStart: rows.count < page, reachedEnd: true)
            highlightID = nil
            if let v = voicemailID, items.contains(where: { $0.id == .voicemail(v) }) { requestScroll(to: .voicemail(v), anchor: .center) }
            else { requestScroll(to: items.last?.id, anchor: .bottom) }
            loadSeconds = Date().timeIntervalSince(t0)
            finish()
        }

        var key: MessageKey?
        var highlight: Int64?
        switch target {
        case .latest:
            await showLatest(); return
        case .message(let id):
            if let k = (await fetch { try $0.key(ofMessage: id) }) ?? nil, scope.threadIDs.contains(k.thread) { key = k.key; highlight = id }
        case .date(let ms):
            key = (await fetch { try $0.firstMessage(scope: scope, atOrAfter: ms) }) ?? nil
        case .voicemail(_, let ms):
            key = (await fetch { try $0.firstMessage(scope: scope, atOrAfter: ms) }) ?? nil
        }
        guard gen == generation else { return }
        guard let key else { await showLatest(); return }

        let rows = await fetch { try $0.around(scope: scope, key: key, before: side, after: side) } ?? []
        guard gen == generation else { return }
        let idx = rows.firstIndex { $0.id == key.id } ?? 0
        let calls = await windowCalls(rows, reachedStart: idx < side, reachedEnd: rows.count - idx - 1 < side)
        guard gen == generation else { return }
        apply(rows, calls: calls, reachedStart: idx < side, reachedEnd: rows.count - idx - 1 < side)
        highlightID = highlight
        // A search hit is centred; a date jump lands on the day heading when the message opens its day.
        if highlight != nil { requestScroll(to: .message(key.id), anchor: .center) }
        else if let v = voicemailID, items.contains(where: { $0.id == .voicemail(v) }) { requestScroll(to: .voicemail(v), anchor: .center) }
        else {
            var target = ThreadItemID.message(key.id)
            if let i = items.firstIndex(where: { $0.id == .message(key.id) }), i > 0, case .day = items[i - 1].kind { target = items[i - 1].id }
            requestScroll(to: target, anchor: .top)
        }
        loadSeconds = Date().timeIntervalSince(t0)
        finish()
        if let h = highlight {
            Task {
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                if self.highlightID == h { self.highlightID = nil }
            }
        }
    }

    func loadOlderIfArmed() {
        guard armed, !loading, !reachedStart, let first = messages.first else { return }
        loading = true; armed = false
        let gen = generation
        let scope = scope, page = Self.page
        let key = MessageKey(tsMs: first.tsMs, id: first.id)
        Task {
            let rows = await fetch { try $0.before(scope: scope, key: key, limit: page) } ?? []
            guard gen == generation else { return }
            var all = rows + messages
            var end = reachedEnd
            if all.count > Self.maxWindow { all.removeLast(all.count - Self.maxWindow); end = false }
            let calls = await windowCalls(all, reachedStart: rows.count < page, reachedEnd: end)
            guard gen == generation else { return }
            apply(all, calls: calls, reachedStart: rows.count < page, reachedEnd: end)
            // No scroll request: the anchor driver keeps the message at the top of the viewport where it was.
            finishPaging()
        }
    }

    func loadNewerIfArmed() {
        guard armed, !loading, !reachedEnd, let last = messages.last else { return }
        loading = true; armed = false
        let gen = generation
        let scope = scope, page = Self.page
        let key = MessageKey(tsMs: last.tsMs, id: last.id)
        Task {
            let rows = await fetch { try $0.after(scope: scope, key: key, limit: page) } ?? []
            guard gen == generation else { return }
            var all = messages + rows
            var start = reachedStart
            if all.count > Self.maxWindow { all.removeFirst(all.count - Self.maxWindow); start = false }
            let calls = await windowCalls(all, reachedStart: start, reachedEnd: rows.count < page)
            guard gen == generation else { return }
            apply(all, calls: calls, reachedStart: start, reachedEnd: rows.count < page)
            finishPaging()
        }
    }

    // MARK: internals

    private func apply(_ rows: [MessageRow], calls extras: Extras, reachedStart: Bool, reachedEnd: Bool) {
        messages = rows
        self.calls = extras.calls
        self.voicemails = extras.voicemails
        self.voice = extras.voice
        self.reachedStart = reachedStart
        self.reachedEnd = reachedEnd
        items = ThreadModel.buildItems(rows, calls: extras.calls, voicemails: extras.voicemails, isGroup: isGroup, merged: isMerged)
        anchor.dataChanged()
    }

    /// What sits in the window beside its messages: the calls and voicemails of its span (a group has none; the reader answers that from
    /// the threads), and the voice messages among its audio attachments.
    struct Extras: Sendable { var calls: [CallRow] = []; var voicemails: [RecordingRow] = []; var voice: [String: VoiceMessageInfo] = [:] }
    private func windowCalls(_ rows: [MessageRow], reachedStart: Bool, reachedEnd: Bool) async -> Extras {
        let scope = scope, isGroup = isGroup
        let span = CallSpan.window(firstTs: rows.first?.tsMs, lastTs: rows.last?.tsMs, reachedStart: reachedStart, reachedEnd: reachedEnd)
        let audio = Set(rows.flatMap { $0.attachments.filter(\.isAudio).map(\.sha256) })
        return await fetch { r in
            Extras(calls: isGroup ? [] : try r.calls(scope: scope, in: span), voicemails: isGroup ? [] : try r.voicemails(scope: scope, in: span),
                   voice: try r.voiceMessages(shas: audio))
        } ?? Extras()
    }

    /// A voice message's transcript again, with its timings (for "Show all").
    func voiceTranscriptWithTimings(_ sha: String, origin: String, model: String) async -> RecordingTranscript? {
        await fetch { try $0.voiceMessages(shas: [sha], segments: true)[sha] }??.transcripts.first { $0.origin == origin && $0.model == model }
    }

    private func requestScroll(to id: ThreadItemID?, anchor: UnitPoint) {
        guard let id else { return }
        tokenCounter += 1
        pendingToken = tokenCounter
        scrollRequest = ScrollRequest(token: tokenCounter, id: id, anchor: anchor)
    }

    private func finish() {
        loading = false
        // With a scroll request pending, the view calls `scrollApplied` once it has moved; otherwise arm right away.
        if pendingToken == nil { armed = true; anchor.resume() }  // resume re-checks the edges
    }

    /// After a page load the edge spinner may sit in view until the anchor driver has moved the content back, so edge
    /// loading is re-armed after a beat (otherwise it would chain-load pages).
    private func finishPaging() {
        loading = false
        let gen = generation
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if gen == generation, !loading, pendingToken == nil { armed = true; anchor.checkEdges() }
        }
    }

    func scrollApplied(token: Int) {
        guard pendingToken == token else { return }
        pendingToken = nil
        armed = true
        anchor.resume()
    }

    /// Snapshot and test hook: arms edge loading without a view.
    func armForTesting() { armed = true }

    // MARK: quick look

    func resolvedURL(_ a: AttachmentInfo) -> URL? {
        guard !a.mediaPath.hasPrefix("/"), !a.mediaPath.contains("..") else { return nil }
        return root.resolve(relativePath: a.mediaPath)
    }

    func quickLook(_ a: AttachmentInfo, in message: MessageRow) {
        let urls = message.attachments.compactMap { resolvedURL($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let u = resolvedURL(a), urls.contains(u) else { return }
        quickLookItems = urls
        quickLookURL = u
    }

    // MARK: item building

    /// Messages, calls and voicemails in time order (a call or voicemail after the messages of its millisecond, a voicemail after a call of
    /// the same instant), with day headings, times and runs.
    static func buildItems(_ rows: [MessageRow], calls callRows: [CallRow] = [], voicemails: [RecordingRow] = [], isGroup: Bool, merged: Bool = false) -> [ThreadItem] {
        enum Extra { case call(CallRow), vm(RecordingRow)
            var ts: Int64 { switch self { case .call(let c): c.tsMs; case .vm(let v): v.tsMs ?? 0 } }
            var order: (Int, Int64) { switch self { case .call(let c): (0, c.id); case .vm(let v): (1, v.id) } }
        }
        let calls: [Extra] = (callRows.map { Extra.call($0) } + voicemails.filter { $0.tsMs != nil }.map { Extra.vm($0) })
            .sorted { $0.ts != $1.ts ? $0.ts < $1.ts : $0.order < $1.order }
        var out: [ThreadItem] = []
        out.reserveCapacity(rows.count + calls.count + rows.count / 8)
        var prev: MessageRow?
        var prevTs: Int64?          // the previous line's time, a message's or a call's
        var prevWasCall = false     // a call line breaks a run like a system line does
        var prevDay = Int.min
        let cal = Fmt.calendar
        var ci = 0
        func emitCall(_ e: Extra) {
            let ts = e.ts
            let comps = cal.dateComponents([.year, .month, .day], from: Fmt.date(ts))
            let dk = (comps.year ?? 0) * 10_000 + (comps.month ?? 0) * 100 + (comps.day ?? 0)
            var showTime = false
            if dk != prevDay { out.append(ThreadItem(id: .day(dk), kind: .day(Fmt.dayHeader(ts)))); prevDay = dk; showTime = true }
            if prevTs.map({ ts - $0 > 30 * 60_000 }) ?? true { showTime = true }
            switch e {
            case .call(let c): out.append(ThreadItem(id: .call(c.id), kind: .call(c, showTime: showTime)))
            case .vm(let v): out.append(ThreadItem(id: .voicemail(v.id), kind: .voicemail(v, showTime: showTime)))
            }
            prevTs = ts; prevWasCall = true
        }
        for r in rows {
            while ci < calls.count, calls[ci].ts < r.tsMs { emitCall(calls[ci]); ci += 1 }
            let date = Fmt.date(r.tsMs)
            let comps = cal.dateComponents([.year, .month, .day], from: date)
            let dayKey = (comps.year ?? 0) * 10_000 + (comps.month ?? 0) * 100 + (comps.day ?? 0)
            var showTime = false
            if dayKey != prevDay {
                out.append(ThreadItem(id: .day(dayKey), kind: .day(Fmt.dayHeader(r.tsMs))))
                prevDay = dayKey
                showTime = true
            }
            let gap = prevTs.map { r.tsMs - $0 } ?? Int64.max
            if gap > 30 * 60_000 { showTime = true }
            // System lines (added, left, calls) never join a run; in a merged timeline a change of thread or service starts one.
            var sameRun = prev != nil && !prevWasCall && !showTime && prev!.isFromMe == r.isFromMe && prev!.senderHandleID == r.senderHandleID
                && r.kind == nil && prev!.kind == nil
            if merged, let p = prev, p.threadID != r.threadID || p.serviceKey != r.serviceKey { sameRun = false }
            let showSender = isGroup && !r.isFromMe && !sameRun && r.kind == nil
            out.append(ThreadItem(id: .message(r.id), kind: .message(r, showSender: showSender, showTime: showTime, tight: sameRun && gap < 120_000)))
            prev = r; prevTs = r.tsMs; prevWasCall = false
        }
        while ci < calls.count { emitCall(calls[ci]); ci += 1 }
        return out
    }
}
