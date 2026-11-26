import SwiftUI
import AppKit
import ArchiveCore

/// Headless self-check: renders the real views against a given archive root to PNGs, so UI work can be checked without
/// screen-recording permission. ImageRenderer cannot draw AppKit-backed containers (List, ScrollView, NavigationSplitView),
/// so the composite window is rebuilt from the same content views inside plain stacks (`isSnapshot`).
@MainActor
enum SnapshotRunner {
    static func start(outDir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let code = await run(outDir: URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath, isDirectory: true))
            fflush(stdout)
            exit(code)
        }
        app.run()
    }

    static var report: [String] = []
    static var pagingFailures = 0
    static func log(_ s: String) { report.append(s); print(s) }

    static func run(outDir: URL) async -> Int32 {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let root = AppModel.initialRoot(flag: Launch.archiveFlag)
        let model = AppModel(root: root, isSnapshot: true)
        let t0 = Date()
        await model.load()
        guard model.phase == .ready else { log("snapshot: archive did not open (\(model.phase)) at \(root.url.path)"); return 1 }
        log("archive: \(root.url.path)")
        let personRows = model.rows.filter(\.isPerson)
        log(String(format: "open + list (%d rows: %d people, %d groups/other; %d threads, %d messages; people mapping %.0f ms): %.0f ms",
                   model.rows.count, personRows.count, model.rows.count - personRows.count, model.allConversations.count,
                   model.overview?.messages ?? 0, model.peopleSeconds * 1000, model.loadSeconds * 1000))
        log("people: \(model.people.persons.count) (\(model.people.persons.values.filter { $0.handles.count > 1 }.count) multi-account), mapping \(model.people.source.rawValue), ambiguous names \(model.people.ambiguous.count)")

        // The biggest person (by messages) and the richest merged one (most services, then most messages), plus a group.
        guard let big = personRows.max(by: { $0.messageCount < $1.messageCount }) ?? model.rows.max(by: { $0.messageCount < $1.messageCount }) else { log("snapshot: archive is empty"); return 1 }
        let merged = personRows.filter { $0.services.count > 1 }.max { ($0.services.count, $0.messageCount) < ($1.services.count, $1.messageCount) }
        let group = model.rows.filter(\.isGroup).max(by: { $0.messageCount < $1.messageCount })

        func open(_ id: ListItemID, _ jump: AppModel.JumpTarget? = nil) async {
            model.select(id, jump: jump, force: true)
            await model.settle()
            model.thread?.armForTesting()
            preloadThumbnails(model)
        }
        func size() -> CGSize { CGSize(width: 1180, height: 760) }

        // 1. main window, light and dark: newest page of the biggest person.
        let tOpen = Date()
        await open(big.id)
        log(String(format: "open person of %d messages in %d thread(s) (first %d rows): %.0f ms", big.messageCount, big.threadIDs.count, ThreadModel.initialPage, Date().timeIntervalSince(tOpen) * 1000))
        render(Composite(), name: "main-light", dark: false, model: model, size: size())
        render(Composite(), name: "main-dark", dark: true, model: model, size: size())

        // 1b. a person with several services: merged timeline, service tags, filter chips.
        if let m = merged {
            let t = Date()
            await open(m.id)
            log(String(format: "open merged person (%d messages, %d threads, services %@): %.0f ms", m.messageCount, m.threadIDs.count, m.services.map(\.label).joined(separator: "+"), Date().timeIntervalSince(t) * 1000))
            render(Composite(), name: "person-merged-light", dark: false, model: model, size: size())
            render(Composite(), name: "person-merged-dark", dark: true, model: model, size: size())
            let tJ = Date()
            let jumpPerson = Int64(((model.overview?.firstTsMs ?? 0) + (model.overview?.lastTsMs ?? 0)) / 2)
            await open(m.id, .date(jumpPerson))
            log(String(format: "merged person: jump to date (window of %d messages): %.0f ms", model.thread?.messages.count ?? 0, Date().timeIntervalSince(tJ) * 1000))
            // per-service filter: open on each service alone
            for svc in m.services {
                let tf = Date()
                model.select(m.id, force: true)
                await model.settle()
                model.toggleService(svc)
                await model.settle()
                model.thread?.armForTesting()
                log(String(format: "merged person: only %@ (%d messages in window): %.0f ms", svc.label, model.thread?.messages.count ?? 0, Date().timeIntervalSince(tf) * 1000))
                if svc == m.services.last { render(Composite(), name: "person-filtered", dark: false, model: model, size: size()) }
            }
            model.clearServiceFilter()
            await model.settle()
            // the fix-a-match sheets
            model.present(.split(m.personID ?? 0))
            if let p = model.people.persons[m.personID ?? 0] {
                render(SplitSheet(person: p).background(Color(nsColor: .windowBackgroundColor)), name: "sheet-split", dark: false, model: model, size: CGSize(width: 500, height: 330))
            }
            model.sheet = nil
        }

        // 2. photos: jump to the newest message with a picture (single-thread scope of the biggest person's biggest thread).
        let counts = Dictionary(model.allConversations.map { ($0.id, $0.messageCount) }, uniquingKeysWith: { a, _ in a })
        if let reader = model.reader, let tid = big.threadIDs.max(by: { counts[$0, default: 0] < counts[$1, default: 0] }),
           let img = try? reader.messagesWithAttachments(thread: tid, mimePrefix: "image/", limit: 3).last {
            await open(big.id, .message(img))
            render(Composite(), name: "thread-photo", dark: false, model: model, size: size())
        }

        // 3. jump to a date (mid-archive).
        let jumpMs = Int64(((model.overview?.firstTsMs ?? 0) + (model.overview?.lastTsMs ?? 0)) / 2)
        let tJump = Date()
        await open(big.id, .date(jumpMs))
        log(String(format: "jump to date (window of %d messages): %.0f ms", model.thread?.messages.count ?? 0, Date().timeIntervalSince(tJump) * 1000))
        render(Composite(), name: "thread-jump-date", dark: false, model: model, size: size())

        // 3b. calls: the person with the most calls, opened at their newest call (call lines among the messages, the count in the header).
        if let callee = personRows.max(by: { $0.callCount < $1.callCount }), callee.callCount > 0 {
            await open(callee.id)
            // none among the newest messages: jump to just before the newest call (the open-both-ways span returns the newest)
            if model.thread?.calls.isEmpty ?? true, let reader = model.reader, let scope = model.selectionScope,
               let c = try? reader.calls(scope: scope, in: .all, limit: 1).last {
                await open(callee.id, .date(c.tsMs - 3_600_000))
            }
            log("calls: person with the most calls has \(callee.callCount) (\(model.selectionCalls?.summary ?? "none")); \(model.thread?.calls.count ?? 0) call lines in the window of \(model.thread?.messages.count ?? 0) messages")
            render(Composite(), name: "thread-calls", dark: false, model: model, size: size())
        } else {
            log("calls: no person has calls")
        }

        // 3c. voicemails: the person who left the most, opened at their newest voicemail (a card with the player and transcripts).
        func voicemailsOf(_ r: ConversationRow) -> Int {
            guard case .person(let pid) = r.id, let p = model.people.persons[pid] else { return 0 }
            return p.handles.reduce(0) { $0 + (model.voicemailCounts[$1.handleID] ?? 0) }
        }
        if let reader = model.reader, let vmTop = personRows.max(by: { voicemailsOf($0) < voicemailsOf($1) }), voicemailsOf(vmTop) > 0 {
            await open(vmTop.id)
            if let scope = model.selectionScope, let v = try? reader.voicemails(scope: scope, in: .all, limit: 1).last, let ts = v.tsMs {
                await open(vmTop.id, .date(ts - 600_000))
            }
            log("voicemails: \(model.selectionTotalsLine); \(model.thread?.voicemails.count ?? 0) voicemail cards in the window")
            render(Composite(), name: "thread-voicemail", dark: false, model: model, size: size())
        } else { log("voicemails: none") }

        // 3d. a voice message on a thread: its player and machine transcript under it.
        if let reader = model.reader, let vm = try? reader.newestVoiceMessage() {
            model.open(hit: SearchHit(messageID: vm.messageID, threadID: vm.threadID, tsMs: 0, isFromMe: false, snippet: ""))
            await model.settle()
            log("voice messages: \(model.thread?.voice.count ?? 0) in the window of the newest transcribed one")
            render(Composite(), name: "thread-voice-message", dark: false, model: model, size: size())
            // the snapshot draws the bottom of the window: the rows that carry a voice message, on their own
            if let t = model.thread {
                let rows = t.items.filter { if case .message(let r, _, _, _) = $0.kind { return r.attachments.contains { t.voice[$0.sha256] != nil } }; return false }
                render(VStack(spacing: 0) { ForEach(rows) { item in
                    if case .message(let r, let sender, _, _) = item.kind { MessageBubbleRow(model: t, row: r, showSender: sender, showTime: true, tight: false) }
                }; Spacer() }.padding(18), name: "voice-message-rows", dark: false, model: model, size: CGSize(width: 900, height: 560))
            }
        } else { log("voice messages: none transcribed") }

        // 4. group thread (sender names).
        if let group {
            await open(group.id)
            render(Composite(), name: "thread-group", dark: false, model: model, size: size())
        }

        // 4b. the list with hidden threads and people shown.
        model.select(nil)
        let before = model.visibleRows.count
        model.showHidden = true
        await model.settle()
        log("show hidden: \(before) -> \(model.visibleRows.count) rows")
        render(Composite(), name: "list-hidden-shown", dark: false, model: model, size: size())
        model.showHidden = false

        // 5. search (everywhere, then inside a merged person).
        let query = Launch.value(after: "--query") ?? "pizza"
        model.searchText = query
        model.searchChanged(immediately: true)
        await model.settle()
        log(String(format: "search \"%@\": %d hits (limit %d) in %.0f ms", query, model.searchHits.count, 200, model.searchSeconds * 1000))
        if let first = model.searchHits.first {
            model.open(hit: first)
            await model.settle()
            model.thread?.armForTesting()
            preloadThumbnails(model)
        }
        render(Composite(), name: "search", dark: false, model: model, size: size())
        if let m = merged {
            model.select(m.id, force: true)
            model.searchScope = .thread
            await model.settle()
            log(String(format: "search \"%@\" inside the merged person: %d hits in %.0f ms", query, model.searchHits.count, model.searchSeconds * 1000))
            model.searchScope = .archive
        }
        model.clearSearch()

        // 6. coverage strip: whole archive and one month selected (conversation list filtered).
        model.select(nil)
        model.coverageScope = .archive
        model.coverageClick(MonthKey(year: 2014, month: 6))
        await model.settle()
        if let first = model.visibleRows.first { await open(first.id) }
        render(Composite(), name: "month-filter", dark: false, model: model, size: size())
        model.setMonthFilter(nil)
        await model.settle()
        if let m = merged {
            await open(m.id)
            render(CoverageStrip().frame(width: 1100), name: "coverage-person", dark: false, model: model, size: CGSize(width: 1100, height: 100))
        }
        model.select(nil)
        model.coverageScope = .archive
        render(CoverageStrip().frame(width: 1100), name: "coverage", dark: false, model: model, size: CGSize(width: 1100, height: 100))
        render(CoverageStrip().frame(width: 1100), name: "coverage-dark", dark: true, model: model, size: CGSize(width: 1100, height: 100))
        render(EmptyComposite(), name: "empty-selection", dark: false, model: model, size: CGSize(width: 1180, height: 560))

        // 6b. the real window (NavigationSplitView, List, ScrollView) drawn by AppKit, if the system lets us.
        await liveWindow(root: root, outDir: outDir)

        // 6c. Notes and Calendar (plain stacks of the windows' rows), when the archive has them.
        if let reader = model.reader {
            if let notes = try? reader.notes(), !notes.isEmpty {
                log("notes: \(notes.count) (\(notes.filter(\.locked).count) locked, \(notes.filter(\.deleted).count) recently deleted)")
                render(NotesSnapshot(notes: notes), name: "notes", dark: false, model: model, size: CGSize(width: 980, height: 680))
            } else { log("notes: none in this archive") }
            if let events = try? reader.calendarEvents(), !events.isEmpty {
                let days = CalendarDays.group(events, zone: .current)
                let from = CalendarWindow.dayKey(onOrAfter: Fmt.date(events[events.count / 2].startMs), in: days)
                let shown = Array(days.drop(while: { $0.key < (from ?? 0) }))
                log("calendar: \(events.count) events on \(days.count) days")
                render(CalendarSnapshot(days: shown), name: "calendar", dark: false, model: model, size: CGSize(width: 760, height: 720))
                render(CalendarSnapshot(days: shown), name: "calendar-dark", dark: true, model: model, size: CGSize(width: 760, height: 720))
            } else { log("calendar: none in this archive") }
        }

        // 6d. Recordings: the newest rows and the newest one as a card; a recorded meeting when there is one.
        if let reader = model.reader, (try? reader.hasRecordings()) == true {
            let rows = (try? reader.recordings(limit: 14)) ?? []
            let counts = (try? reader.recordingCounts()) ?? RecordingCounts()
            log("recordings: \(counts.voicemails) voicemails, \(counts.memos) memos, \(counts.meetings) meetings")
            if let first = rows.first, let full = try? reader.recording(id: first.id) {
                render(RecordingsSnapshot(rows: rows, card: full), name: "recordings", dark: false, model: model, size: CGSize(width: 1040, height: 720))
            }
            if let m = (try? reader.recordings(kind: "meeting", limit: 5))?.first, let full = try? reader.recording(id: m.id) {
                render(RecordingsSnapshot(rows: (try? reader.recordings(kind: "meeting", limit: 5)) ?? [], card: full), name: "recordings-meeting", dark: false, model: model, size: CGSize(width: 1040, height: 900))
            }
        }

        // 7. settings.
        render(SettingsView(), name: "settings", dark: false, model: model, size: CGSize(width: 560, height: 420))

        log(String(format: "total: %.1f s", Date().timeIntervalSince(t0)))
        try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        return pagingFailures == 0 ? 0 : 1
    }

    static func preloadThumbnails(_ model: AppModel) {
        guard let t = model.thread else { return }
        for item in t.items.suffix(60) {
            if case .message(let r, _, _, _) = item.kind { for a in r.attachments where a.isImage { _ = Thumbnails.shared.loadSync(a) } }
        }
    }

    /// The Recordings window as plain stacks (ImageRenderer cannot draw a List or a ScrollView).
    struct RecordingsSnapshot: View {
        let rows: [RecordingRow]
        let card: RecordingRow
        var body: some View {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { RecordingListRow(row: $0) }
                    Spacer()
                }
                .padding(10).frame(width: 360).frame(maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor))
                Divider()
                VStack { RecordingCard(row: card); Spacer() }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    struct Composite: View {
        @Environment(AppModel.self) private var app
        var body: some View {
            HStack(spacing: 0) {
                SidebarView().frame(width: 340).background(Color(nsColor: .controlBackgroundColor))
                Divider()
                DetailView()
            }
        }
    }
    struct EmptyComposite: View {
        var body: some View {
            HStack(spacing: 0) {
                SidebarView().frame(width: 340).background(Color(nsColor: .controlBackgroundColor))
                Divider()
                DetailView()
            }
        }
    }

    static func render<V: View>(_ view: V, name: String, dark: Bool, model: AppModel, size: CGSize) {
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = previous }
        let content = view
            .environment(model)
            .environment(\.isSnapshot, true)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let r = ImageRenderer(content: content)
        r.scale = 2
        let url = URL(fileURLWithPath: "\(Launch.snapshotDir.map { ($0 as NSString).expandingTildeInPath } ?? ".")/\(name).png")
        guard let cg = r.cgImage else { log("render failed: \(name)"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            log("wrote \(url.lastPathComponent) (\(cg.width)x\(cg.height))")
        }
    }

    /// Hosts the real RootView in an off-screen window and captures it with cacheDisplay (no screen-recording permission).
    static func liveWindow(root: ArchiveRoot, outDir: URL) async {
        let live = AppModel(root: root, isSnapshot: false)
        await live.load()
        let host = NSHostingView(rootView: RootView().environment(live))
        let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1180, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.contentView = host
        win.orderFrontRegardless()
        if let big = live.rows.filter(\.isPerson).max(by: { $0.messageCount < $1.messageCount }) { live.select(big.id) }
        await live.settle()
        try? await Task.sleep(nanoseconds: 900_000_000)
        host.layoutSubtreeIfNeeded()
        await pagingCheck(live, host: host)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { log("live window: no bitmap"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: outDir.appendingPathComponent("live-window.png"))
            log("wrote live-window.png (\(rep.pixelsWide)x\(rep.pixelsHigh)), real AppKit window")
        }
        win.orderOut(nil)
    }

    /// Drives the real ScrollView in the off-screen window through repeated page loads (older, then newer, past the window
    /// cap so edges are evicted), then after a jump to a date, and asserts the message at the top of the viewport stays
    /// within a point of where it was across every load.
    static func pagingCheck(_ live: AppModel, host: NSView) async {
        func wait(_ ms: Int) async { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
        var failures = 0, loads = 0, worst = 0.0
        func settleViews() async { await wait(350); host.layoutSubtreeIfNeeded() }

        func page(_ label: String, older: Bool, times: Int) async {
            for n in 1...times {
                guard let t = live.thread, let d = Optional(t.anchor), d.scrollView != nil else { log("paging \(label): no scroll view"); failures += 1; return }
                let before = t.messages.count, first = t.messages.first?.id, last = t.messages.last?.id
                if older { guard !t.reachedStart else { return }; d.setOffset(20) } else { guard !t.reachedEnd else { return }; d.setOffset(d.maxOffset - 20) }
                guard let top = d.topRow() else { log("paging \(label) #\(n): no realized rows"); failures += 1; return }
                // The load fires once the edge spinner appears; wait for the window to change.
                var waited = 0
                while waited < 3000, t.messages.first?.id == first, t.messages.last?.id == last { await wait(50); waited += 50 }
                await settleViews()
                guard t.messages.first?.id != first || t.messages.last?.id != last else { log("paging \(label) #\(n): no page loaded in 3 s"); failures += 1; return }
                loads += 1
                // For a viewport that was parked at the edge, re-read the same row.
                if let now = d.spans[top.id] {
                    let drift = (now.minY - d.offset) - top.viewportTop
                    worst = max(worst, abs(drift))
                    if abs(drift) > 1.5 { failures += 1; log(String(format: "paging %@ #%d: anchor drifted %.1f pt (window %d -> %d)", label, n, drift, before, t.messages.count)) }
                } else { failures += 1; log("paging \(label) #\(n): anchor row \(top.id) not realized after load") }
            }
        }

        // Open latency as the reader sees it: selection until the first rows are laid out in the real scroll view.
        if let big = live.rows.filter(\.isPerson).max(by: { $0.messageCount < $1.messageCount }) {
            var best = Double.infinity
            for _ in 0..<3 {
                live.select(nil); await wait(150)
                let t = Date()
                live.select(big.id, force: true)
                while (live.thread?.anchor.spans.isEmpty ?? true) && Date().timeIntervalSince(t) < 5 { await wait(5) }
                best = min(best, Date().timeIntervalSince(t) * 1000)
                await wait(600)
            }
            log(String(format: "open in real scroll view (%d messages, first rows laid out): %.0f ms", big.messageCount, best))
        }
        guard let t0 = live.thread else { log("paging: no thread"); return }
        // Main-thread heartbeat: the longest gap between 10 ms ticks while pages load is the worst visible stall.
        nonisolated(unsafe) var stall = 0.0
        let beat = Task { @MainActor in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
                let now = Date(); stall = max(stall, now.timeIntervalSince(last) * 1000 - 10); last = now
            }
        }
        defer { beat.cancel() }
        for _ in 0..<20 where t0.anchor.scrollView == nil || t0.anchor.spans.isEmpty { await wait(100) }
        await page("older", older: true, times: 8)
        await page("newer", older: false, times: 3)
        // After a jump to a date the window is replaced; paging both ways must still hold the place.
        let mid = Int64(((live.overview?.firstTsMs ?? 0) + (live.overview?.lastTsMs ?? 0)) / 2)
        if let big = live.rows.filter(\.isPerson).max(by: { $0.messageCount < $1.messageCount }) {
            live.select(big.id, jump: .date(mid), force: true)
            await live.settle()
            await wait(1200)
            await page("after-jump older", older: true, times: 3)
            await page("after-jump newer", older: false, times: 3)
            // A search-result jump (to a message id) must hold too.
            if let msgs = live.thread?.messages, msgs.count > 10 {
                live.select(big.id, jump: .message(msgs[msgs.count / 3].id), force: true)
                await live.settle()
                await wait(1200)
                await page("after-hit older", older: true, times: 3)
                await page("after-hit newer", older: false, times: 3)
            }
        }
        pagingFailures = failures
        log(String(format: "paging check: %d page loads, worst anchor drift %.2f pt, longest main-thread stall %.0f ms, %d failure(s) (corrections applied: %d)", loads, worst, stall, failures, live.thread?.anchor.corrections ?? 0))
    }
}
