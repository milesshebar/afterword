import SwiftUI
import AppKit
import AVKit
import ArchiveCore

// Voicemails, voice memos, recorded meetings and voice messages in the Mac app (the same views as the web
// app's). Read-only, over the main window's reader. Every transcript is shown
// under a label that says it is a machine transcript, never as anyone's verified words.

// MARK: playing

/// One player for one audio file: AVPlayer over the media store's file, the time it is at (for the sentence being spoken), and seeking.
@MainActor @Observable
final class AudioPlayback {
    let player: AVPlayer
    private(set) var time: Double = 0
    @ObservationIgnored private var observer: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.time = t.seconds.isFinite ? t.seconds : 0 }
        }
    }

    func play(from seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    /// Pauses and lets go of the time observer; idempotent. A view that disappears calls it and makes a new playback when it comes back.
    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
    }
}

/// The system's inline audio controls (play, scrub, time) for a playback.
struct PlayerBar: NSViewRepresentable {
    let playback: AudioPlayback
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .inline
        v.showsFullScreenToggleButton = false
        v.player = playback.player
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== playback.player { v.player = playback.player } }
}

@MainActor
enum RecordingText {
    /// What a transcript is, said every time it is shown (the web app's `transcriptLabel`).
    static func label(_ t: RecordingTranscript) -> String {
        if t.origin == "apple" { return "The phone's own voicemail transcription · a machine transcript, not verified" }
        let m = t.model.split(separator: "/").last.map(String.init) ?? ""
        return "Machine transcript" + (m.isEmpty ? "" : " (\(m))") + " · made on the Mac, not verified"
    }

    /// The quiet line under a recording's title: when (an export or file time said to be one), its length, what the source says.
    static func facts(_ r: RecordingRow) -> String {
        var out: [String] = []
        if let ts = r.tsMs {
            let d = Fmt.fullDate(ts)
            if r.timeIsOwn { out.append(d) }
            else { out.append((r.datedBy == "export-time" ? "Saved " : "File dated ") + d + (r.isVoicemail ? " (left earlier; the source has no time for it)" : " (the recording has no time of its own)")) }
        } else { out.append("No date in the source") }
        out.append(RecordingRow.clock(r.durationS))
        if r.isVoicemail { if r.heard == true { out.append("heard") } else if r.heard == false { out.append("not heard") } }
        if r.deleted == true { out.append(r.isVoicemail ? "in the phone's deleted list" : "in Recently Deleted") }
        switch r.content { case "music": out.append("music"); case "noise": out.append("noise, no speech"); case "no-speech": out.append("no words transcribed"); default: break }
        return out.joined(separator: " · ")
    }

    static func symbol(_ r: RecordingRow) -> String { r.isVoicemail ? "recordingtape" : r.isMeeting ? "person.3" : "mic" }

    struct Segment: Decodable, Hashable { var start: Double; var end: Double; var text: String }
    static func segments(_ t: RecordingTranscript) -> [Segment] {
        guard let s = t.segments, let d = s.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Segment].self, from: d)) ?? []
    }
}

/// A transcript under its label: clamped, "Show all" opens it whole, and with timings each sentence is a line that plays from there
/// (the one being spoken is marked).
struct TranscriptBlock: View {
    let transcript: RecordingTranscript
    var playback: AudioPlayback?
    var clampLines = 5
    /// Fetches the same transcript with its timings, when the row came without them.
    var loadSegments: (() async -> RecordingTranscript?)?
    var noWords = "The transcriber heard no words in this recording."
    private var _expanded = State(initialValue: false)
    private var _full = State<RecordingTranscript?>(initialValue: nil)
    private var expanded: Bool { get { _expanded.wrappedValue } nonmutating set { _expanded.wrappedValue = newValue } }
    private var full: RecordingTranscript? { get { _full.wrappedValue } nonmutating set { _full.wrappedValue = newValue } }

    init(transcript: RecordingTranscript, playback: AudioPlayback?, clampLines: Int = 5, noWords: String = "The transcriber heard no words in this recording.",
         loadSegments: (() async -> RecordingTranscript?)? = nil) {
        self.transcript = transcript; self.playback = playback; self.clampLines = clampLines; self.noWords = noWords; self.loadSegments = loadSegments
    }

    var body: some View {
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 3) {
            Text(RecordingText.label(transcript).uppercased()).font(.system(size: 10)).foregroundStyle(.tertiary).kerning(0.3)
            if text.isEmpty {
                Text(noWords).font(.callout).italic().foregroundStyle(.secondary)
            } else if expanded, let segs = Optional(RecordingText.segments(full ?? transcript)), !segs.isEmpty, let playback {
                let now = segs.lastIndex { $0.start <= playback.time + 0.05 }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(segs.enumerated()), id: \.offset) { i, s in
                        Button { playback.play(from: s.start) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(RecordingRow.clock(s.start)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 52, alignment: .trailing)
                                Text(s.text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 1).padding(.horizontal, 3)
                            .background(i == now ? Color.yellow.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("Play from \(RecordingRow.clock(s.start))")
                    }
                }
                .textSelection(.enabled)
            } else {
                Text(text).font(.callout).lineLimit(expanded ? nil : clampLines).textSelection(.enabled)
                if !expanded {
                    Button("Show all") {
                        expanded = true
                        if full == nil, transcript.segments == nil, let loadSegments { Task { full = await loadSegments() } }
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(.leading, 9)
        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 2) }
    }
}

// MARK: a recording

/// One voicemail, voice memo or recorded meeting as a card: what and when, a player, its transcripts, and (a voicemail) a way to its
/// conversation; a meeting adds its note and its saved chat.
/// What a snapshot draws in place of the player (ImageRenderer cannot draw an AppKit view).
struct PlayerPlaceholder: View {
    let seconds: Double
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.fill")
            Capsule().fill(Color.primary.opacity(0.15)).frame(height: 4)
            Text("0:00 / " + RecordingRow.clock(seconds)).font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary).padding(.horizontal, 8).frame(height: 30)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct RecordingCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isSnapshot) private var isSnapshot
    let row: RecordingRow
    var inTimeline = false
    var openConversation: ((RecordingRow) -> Void)?
    private var _playback = State<AudioPlayback?>(initialValue: nil)
    private var playback: AudioPlayback? { get { _playback.wrappedValue } nonmutating set { _playback.wrappedValue = newValue } }

    init(row: RecordingRow, inTimeline: Bool = false, openConversation: ((RecordingRow) -> Void)? = nil) {
        self.row = row; self.inTimeline = inTimeline; self.openConversation = openConversation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: RecordingText.symbol(row)).foregroundStyle(.secondary)
                Text(app.recordingTitle(row)).font(.headline).lineLimit(2)
                Spacer(minLength: 4)
            }
            Text(RecordingText.facts(row)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if row.isMeeting, let note = row.note { Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if row.playSha256 != nil {
                if isSnapshot { PlayerPlaceholder(seconds: row.durationS) }
                else if let playback { PlayerBar(playback: playback).frame(height: 30) }
                else { Text("The audio is not reachable from this Mac (is the media folder mounted?)").font(.caption).italic().foregroundStyle(.secondary) }
            } else {
                Text("No audio: " + (row.note ?? "the source holds this recording's entry but not its sound")).font(.caption).italic().foregroundStyle(.secondary)
            }
            ForEach(Array(row.transcripts.enumerated()), id: \.offset) { _, t in
                TranscriptBlock(transcript: t, playback: playback, clampLines: inTimeline ? 4 : 8) { await app.recordingWithTimings(row.id)?.transcripts.first { $0.origin == t.origin && $0.model == t.model } }
            }
            if row.playSha256 != nil, row.transcripts.isEmpty { Text("No transcript").font(.caption).foregroundStyle(.tertiary) }
            HStack(spacing: 14) {
                if !inTimeline, row.isVoicemail, row.handleID != nil || row.threadID != nil || row.address != nil, let openConversation {
                    Button(row.timeIsOwn && row.tsMs != nil ? "Open the conversation at this time" : "Open the conversation") { openConversation(row) }.buttonStyle(.link)
                }
                if let chat = row.chatSha256, let url = app.mediaURL(recordingSha: chat) {
                    Button("The meeting's saved chat (Zoom's own file)") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
                }
            }
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: inTimeline ? 460 : .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.10)))
        .frame(maxWidth: .infinity)
        .padding(.vertical, inTimeline ? 6 : 0)
        .task(id: row.playSha256) {
            if playback == nil, let sha = row.playSha256, let url = app.mediaURL(recordingSha: sha) { playback = AudioPlayback(url: url) }
        }
        .onDisappear { playback?.stop(); playback = nil }
    }
}

/// A voice message on a thread: its player (the playable copy when the file is one AVPlayer may not take as is) and its machine
/// transcript under it.
struct VoiceMessageView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isSnapshot) private var isSnapshot
    let model: ThreadModel
    let attachment: AttachmentInfo
    let info: VoiceMessageInfo
    let mine: Bool
    private var _playback = State<AudioPlayback?>(initialValue: nil)
    private var playback: AudioPlayback? { get { _playback.wrappedValue } nonmutating set { _playback.wrappedValue = newValue } }

    init(model: ThreadModel, attachment: AttachmentInfo, info: VoiceMessageInfo, mine: Bool) {
        self.model = model; self.attachment = attachment; self.info = info; self.mine = mine
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                Text("Voice message · " + RecordingRow.clock(info.durationS)).font(.caption).foregroundStyle(.secondary)
            }
            if isSnapshot { PlayerPlaceholder(seconds: info.durationS) }
            else if let playback { PlayerBar(playback: playback).frame(height: 30) }
            else { Text("The audio is not reachable from this Mac").font(.caption).italic().foregroundStyle(.secondary) }
            ForEach(Array(info.transcripts.enumerated()), id: \.offset) { _, t in
                TranscriptBlock(transcript: t, playback: playback, clampLines: 4, noWords: "The transcriber heard no words in this voice message.") {
                    await model.voiceTranscriptWithTimings(attachment.sha256, origin: t.origin, model: t.model)
                }
            }
        }
        .padding(10)
        .frame(width: 320, alignment: .leading)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: info.playSha256) {
            if playback == nil, let url = app.mediaURL(voicePlay: info, attachment: attachment) { playback = AudioPlayback(url: url) }
        }
        .onDisappear { playback?.stop(); playback = nil }
    }
}

// MARK: the Recordings window

enum RecordingKindFilter: String, CaseIterable, Identifiable {
    case all, voicemail, memo, meeting
    var id: String { rawValue }
    var label: String { switch self { case .all: "All"; case .voicemail: "Voicemails"; case .memo: "Memos"; case .meeting: "Meetings" } }
    var kind: String? { self == .all ? nil : rawValue }
}

/// The Recordings window's state: a page of recordings newest first (or the search's hits), the selected one with its timings.
@MainActor @Observable
final class RecordingsModel {
    var kind: RecordingKindFilter = .all
    var query = ""
    private(set) var rows: [RecordingRow] = []
    private(set) var counts = RecordingCounts()
    private(set) var hasMore = false
    private(set) var loading = false
    var selectedID: Int64?
    private(set) var selected: RecordingRow?
    private var generation = 0
    static let page = 200

    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Rows grouped by month, newest first (a row with no time last); a search's hits, in their order, as one section (best matches are
    /// not in date order, and a month must never be two sections with one title).
    var sections: [(title: String, rows: [RecordingRow])] {
        if searching { return rows.isEmpty ? [] : [(title: "Best matches", rows: rows)] }
        var out: [(String, [RecordingRow])] = []
        for r in rows {
            let t = r.tsMs.map { Fmt.monthTitle($0) } ?? "No date"
            if out.last?.0 == t { out[out.count - 1].1.append(r) } else { out.append((t, [r])) }
        }
        return out.map { (title: $0.0, rows: $0.1) }
    }

    func reload(_ reader: ArchiveReader?) {
        guard let reader else { return }
        generation += 1
        let gen = generation, kind = kind.kind, q = query.trimmingCharacters(in: .whitespaces), searching = searching, n = Self.page
        loading = true
        Task {
            struct Page: @unchecked Sendable { var rows: [RecordingRow]; var counts: RecordingCounts }
            let page = try? await Task.detached(priority: .userInitiated) { () -> Page in
                let rows = searching ? try reader.searchRecordings(q, kind: kind, limit: n) : try reader.recordings(kind: kind, limit: n)
                return Page(rows: rows, counts: try reader.recordingCounts())
            }.value
            guard gen == generation else { return }
            rows = page?.rows ?? []; counts = page?.counts ?? RecordingCounts()
            hasMore = rows.count == Self.page
            loading = false
            if selectedID == nil || !rows.contains(where: { $0.id == selectedID }) { selectedID = rows.first?.id }
            select(reader)
        }
    }

    func loadMore(_ reader: ArchiveReader?) {
        guard let reader, hasMore, !loading else { return }
        let gen = generation, kind = kind.kind, q = query.trimmingCharacters(in: .whitespaces), searching = searching, count = rows.count, n = Self.page
        let last = rows.last.map { (ts: $0.tsMs ?? 0, id: $0.id) }
        loading = true
        Task {
            struct Rows: @unchecked Sendable { var rows: [RecordingRow] }
            let more = try? await Task.detached(priority: .userInitiated) { () -> Rows in
                Rows(rows: searching ? try reader.searchRecordings(q, kind: kind, limit: n, offset: count) : try reader.recordings(kind: kind, before: last, limit: n))
            }.value
            guard gen == generation else { return }
            rows += more?.rows ?? []
            hasMore = (more?.rows.count ?? 0) == Self.page
            loading = false
        }
    }

    /// Loads the selected recording again with its transcripts' timings.
    func select(_ reader: ArchiveReader?) {
        guard let reader, let id = selectedID else { selected = nil; return }
        selected = rows.first { $0.id == id }
        let gen = generation
        Task {
            struct One: @unchecked Sendable { var row: RecordingRow? }
            let one = try? await Task.detached(priority: .userInitiated) { One(row: try reader.recording(id: id)) }.value
            if gen == generation, selectedID == id, let r = one?.row { selected = r }
        }
    }
}

struct RecordingListRow: View {
    @Environment(AppModel.self) private var app
    let row: RecordingRow
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: RecordingText.symbol(row)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.recordingTitle(row)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(row.tsMs.map { Fmt.listDate($0) + (row.timeIsOwn ? "" : " (saved)") } ?? "no date")
                    Text(RecordingRow.clock(row.durationS))
                    if row.sha256 == nil { Text("no audio") }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let s = row.snippet, s.contains("\u{1}") { Text(Snippet.attributed(s)).font(.caption).lineLimit(2) }
                else if let t = row.transcripts.first?.text, !t.isEmpty { Text(t).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Every voicemail, voice memo and recorded meeting by date (sections by month), with the kind chips and a search over transcripts,
/// titles and callers' names; the selected one on the right as a card with its player and timed transcripts.
struct RecordingsWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    let model: RecordingsModel

    var body: some View {
        @Bindable var model = model
        Group {
            if app.reader == nil { Text("Open an archive in the main window first.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                NavigationSplitView {
                    VStack(spacing: 0) {
                        Picker("", selection: $model.kind) { ForEach(RecordingKindFilter.allCases) { Text($0.label).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().padding(8)
                        List(selection: $model.selectedID) {
                            ForEach(model.sections, id: \.title) { section in
                                Section(section.title) {
                                    ForEach(section.rows) { r in RecordingListRow(row: r).tag(r.id as Int64?) }
                                }
                            }
                            if model.hasMore { Button("More") { model.loadMore(app.reader) }.buttonStyle(.link) }
                        }
                        .overlay { if model.rows.isEmpty && !model.loading { Text(model.searching ? "No recording matches" : "No recordings in this archive").foregroundStyle(.secondary) } }
                        Divider()
                        Text(summary).font(.caption).foregroundStyle(.secondary).padding(6)
                    }
                    .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 520)
                } detail: {
                    ScrollView {
                        if let r = model.selected {
                            RecordingCard(row: r) { row in app.openConversation(of: row); openWindow(id: "main") }.id(r.id).padding(16)
                        } else {
                            Text("Select a recording").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                        }
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
                .searchable(text: $model.query, placement: .toolbar, prompt: "Search transcripts and titles")
            }
        }
        .navigationTitle("Recordings")
        .onAppear { model.reload(app.reader) }
        .onChange(of: model.kind) { _, _ in model.reload(app.reader) }
        .onChange(of: model.query) { _, _ in model.reload(app.reader) }
        .onChange(of: model.selectedID) { _, _ in model.select(app.reader) }
        .onChange(of: app.overview?.messages) { _, _ in model.reload(app.reader) }
    }

    private var summary: String {
        let c = model.counts
        var parts = ["\(c.voicemails.formatted()) voicemails", "\(c.memos.formatted()) voice memos"]
        if c.meetings > 0 { parts.append(c.meetings == 1 ? "1 recorded meeting" : "\(c.meetings) recorded meetings") }
        parts.append("\(Int((c.seconds / 3600).rounded()).formatted()) h")
        if model.searching { parts.insert("\(model.rows.count)\(model.hasMore ? "+" : "") matching", at: 0) }
        return parts.joined(separator: " · ")
    }
}
