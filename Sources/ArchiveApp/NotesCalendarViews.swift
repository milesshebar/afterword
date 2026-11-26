import SwiftUI
import ArchiveCore

// The Notes and Calendar windows (Window menu, or the main window's toolbar): the `note` table (Apple Notes from phones and
// Macs) as a list with the text beside it, and the
// `calendar_event` table as a list of days. Read-only, over the main window's reader.

/// Times of calendar events: a floating time (all-day events, and timed ones the phone kept without a zone) reads in UTC.
@MainActor
enum EventFmt {
    private static let local: DateFormatter = { let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f }()
    private static let utc: DateFormatter = { let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; f.timeZone = TimeZone(identifier: "UTC"); return f }()
    private static let utcDay: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMdy"); f.timeZone = TimeZone(identifier: "UTC"); return f }()

    static func time(_ e: CalendarEventItem) -> String {
        if e.allDay {
            let days = CalendarDays.days(of: e, zone: .current)
            guard days.count > 1, let last = days.last, let lastMs = CalendarDays.start(ofKey: last, in: TimeZone(identifier: "UTC")!) else { return "All day" }
            return "All day, to " + utcDay.string(from: Fmt.date(lastMs))
        }
        let f = e.floating ? utc : local
        let start = f.string(from: Fmt.date(e.startMs))
        guard let end = e.endMs, end > e.startMs, end - e.startMs < 86_400_000 else { return start }
        return start + " – " + f.string(from: Fmt.date(end))
    }

    /// The day header of a `yyyymmdd` key, in this Mac's zone.
    static func dayHeader(_ key: Int) -> String {
        guard let ms = CalendarDays.start(ofKey: key, in: .current) else { return String(key) }
        return Fmt.dayHeader(ms)
    }
}

/// Shown while the main window has no archive open.
private struct NotOpen: View {
    let text: String
    var body: some View {
        Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: notes

struct NoteRow: View {
    let note: NoteItem
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if note.locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                Text(note.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(note.modifiedMs.map { Fmt.listDate($0) } ?? note.createdMs.map { Fmt.listDate($0) } ?? "no date")
                    .foregroundStyle(.secondary)
                Text(preview).foregroundStyle(.tertiary).lineLimit(1)
            }
            .font(.caption)
            HStack(spacing: 4) {
                Image(systemName: note.deleted ? "trash" : "folder").font(.caption2)
                Text(note.deleted ? "Recently Deleted" : (note.folder ?? "Notes")).lineLimit(1)
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var preview: String {
        if note.locked { return "Locked" }
        let lines = (note.body ?? note.snippet ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let rest = lines.first == note.displayTitle ? Array(lines.dropFirst()) : lines
        return rest.first ?? ""
    }
}

struct NoteDetail: View {
    let note: NoteItem
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note.displayTitle).font(.title2.weight(.semibold)).textSelection(.enabled)
            Text(meta).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if note.deleted { Label("In Recently Deleted when the backup was taken", systemImage: "trash").font(.caption).foregroundStyle(.secondary) }
            Divider()
            if note.locked {
                Label("Password protected: the backup holds only its title and dates, not its text.", systemImage: "lock.fill").foregroundStyle(.secondary)
            } else if let body = note.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // U+FFFC marks where a drawing, scan or picture sat; those are not stored.
                Text(body.replacingOccurrences(of: "\u{FFFC}", with: "[attachment]")).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(note.snippet ?? "No text could be read from this note.").foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var meta: String {
        var parts: [String] = []
        if let f = note.folder { parts.append(f) }
        if let a = note.account { parts.append(a) }
        if let c = note.createdMs { parts.append("created " + Fmt.fullDate(c)) }
        if let m = note.modifiedMs, m != note.createdMs { parts.append("modified " + Fmt.fullDate(m)) }
        if !note.sourceLabel.isEmpty { parts.append("from " + note.sourceLabel) }
        return parts.joined(separator: " · ")
    }
}

struct NotesWindow: View {
    @Environment(AppModel.self) private var app
    // The CLT's macOS 27 SDK makes @State a macro whose plugin ships only with Xcode: state is the State struct directly (README).
    private var _notes = State<[NoteItem]?>(initialValue: nil)
    private var notes: [NoteItem]? { get { _notes.wrappedValue } nonmutating set { _notes.wrappedValue = newValue } }
    private var _failure = State<String?>(initialValue: nil)
    private var failure: String? { get { _failure.wrappedValue } nonmutating set { _failure.wrappedValue = newValue } }
    private var _selection = State<Int64?>(initialValue: nil)
    private var selection: Int64? { get { _selection.wrappedValue } nonmutating set { _selection.wrappedValue = newValue } }
    private var _filter = State<String>(initialValue: "")
    private var filter: String { get { _filter.wrappedValue } nonmutating set { _filter.wrappedValue = newValue } }
    private var _showDeleted = State<Bool>(initialValue: true)
    private var showDeleted: Bool { get { _showDeleted.wrappedValue } nonmutating set { _showDeleted.wrappedValue = newValue } }

    private var shown: [NoteItem] { (notes ?? []).filter { (showDeleted || !$0.deleted) && $0.matches(filter) } }

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 480)
        } detail: {
            if let id = selection, let n = notes?.first(where: { $0.id == id }) {
                ScrollView { NoteDetail(note: n) }.background(Color(nsColor: .textBackgroundColor))
            } else {
                NotOpen(text: notes?.isEmpty == false ? "Select a note" : "")
            }
        }
        .searchable(text: _filter.projectedValue, placement: .sidebar, prompt: "Filter notes")
        .navigationTitle("Notes")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem { Toggle("Show Recently Deleted", isOn: _showDeleted.projectedValue).toggleStyle(.checkbox) }
        }
        .task(id: app.reader.map(ObjectIdentifier.init)) { await load() }
        .frame(minWidth: 700, minHeight: 420)
    }

    @ViewBuilder private var sidebar: some View {
        if app.reader == nil {
            NotOpen(text: "Open the archive in the main window first.")
        } else if let failure {
            NotOpen(text: "Couldn't read the notes: \(failure)")
        } else if let notes {
            if notes.isEmpty {
                NotOpen(text: "This archive has no notes. Import them with archivectl notes-import.")
            } else {
                List(shown, selection: _selection.projectedValue) { NoteRow(note: $0).tag($0.id) }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var subtitle: String {
        guard let notes, !notes.isEmpty else { return "" }
        let n = shown.count
        return n == notes.count ? "\(n.formatted()) notes" : "\(n.formatted()) of \(notes.count.formatted()) notes"
    }

    private func load() async {
        guard let reader = app.reader else { notes = nil; return }
        do {
            let list = try await Task.detached(priority: .userInitiated) { try reader.notes() }.value
            notes = list; failure = nil
            if selection == nil || !list.contains(where: { $0.id == selection }) { selection = list.first?.id }
        } catch { failure = "\(error)"; notes = nil }
    }
}

// MARK: calendar

struct EventRow: View {
    let event: CalendarEventItem
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(EventFmt.time(event)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(event.displaySummary).font(.system(size: 13, weight: .medium))
                    if event.recurring {
                        Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary)
                            .help("Repeats: listed on its first date only (the archive keeps the series, not each occurrence)")
                    }
                }
                if let l = event.location { Text(l).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if let n = event.notes { Text(n).font(.caption).foregroundStyle(.tertiary).lineLimit(3) }
                Text(event.calendar ?? "Calendar").font(.caption2).foregroundStyle(.tertiary)
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

struct CalendarDayHeader: View {
    let day: CalendarDay
    var body: some View {
        HStack {
            Text(EventFmt.dayHeader(day.key)).font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(day.events.count == 1 ? "1 event" : "\(day.events.count) events").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct CalendarWindow: View {
    @Environment(AppModel.self) private var app
    // The CLT's macOS 27 SDK makes @State a macro whose plugin ships only with Xcode: state is the State struct directly (README).
    private var _events = State<[CalendarEventItem]?>(initialValue: nil)
    private var events: [CalendarEventItem]? { get { _events.wrappedValue } nonmutating set { _events.wrappedValue = newValue } }
    private var _days = State<[CalendarDay]>(initialValue: [])
    private var days: [CalendarDay] { get { _days.wrappedValue } nonmutating set { _days.wrappedValue = newValue } }
    private var _failure = State<String?>(initialValue: nil)
    private var failure: String? { get { _failure.wrappedValue } nonmutating set { _failure.wrappedValue = newValue } }
    private var _filter = State<String>(initialValue: "")
    private var filter: String { get { _filter.wrappedValue } nonmutating set { _filter.wrappedValue = newValue } }
    private var _jumpDate = State<Date>(initialValue: Date())
    private var jumpDate: Date { get { _jumpDate.wrappedValue } nonmutating set { _jumpDate.wrappedValue = newValue } }
    private var _target = State<Int?>(initialValue: nil)
    private var target: Int? { get { _target.wrappedValue } nonmutating set { _target.wrappedValue = newValue } }

    var body: some View {
        content
            .searchable(text: _filter.projectedValue, prompt: "Filter events")
            .onChange(of: filter) { _, _ in regroup(); scroll(to: jumpDate) }
            .navigationTitle("Calendar")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItemGroup {
                    DatePicker("Go to", selection: _jumpDate.projectedValue, displayedComponents: .date).labelsHidden()
                        .onChange(of: jumpDate) { _, d in scroll(to: d) }
                        .help("Go to the first day with events on or after this date")
                    Button("Today") { jumpDate = Date(); scroll(to: jumpDate) }
                }
            }
            .task(id: app.reader.map(ObjectIdentifier.init)) { await load() }
            .frame(minWidth: 560, minHeight: 420)
    }

    @ViewBuilder private var content: some View {
        if app.reader == nil {
            NotOpen(text: "Open the archive in the main window first.")
        } else if let failure {
            NotOpen(text: "Couldn't read the calendar: \(failure)")
        } else if let events {
            if events.isEmpty {
                NotOpen(text: "This archive has no calendar events.")
            } else if days.isEmpty {
                NotOpen(text: "No events match “\(filter)”.")
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(days) { day in
                            Section { ForEach(day.events) { EventRow(event: $0) } } header: { CalendarDayHeader(day: day) }
                                .id(day.key)
                        }
                    }
                    .listStyle(.inset)
                    .onChange(of: target) { _, k in if let k { proxy.scrollTo(k, anchor: .top) } }
                    .onAppear { if let k = target { proxy.scrollTo(k, anchor: .top) } }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var subtitle: String {
        guard let events, !events.isEmpty else { return "" }
        let n = days.reduce(0) { $0 + $1.events.count }
        return filter.isEmpty ? "\(events.count.formatted()) events on \(days.count.formatted()) days" : "\(n.formatted()) matching on \(days.count.formatted()) days"
    }

    private func regroup() {
        let list = (events ?? []).filter { $0.matches(filter) }
        days = CalendarDays.group(list, zone: .current)
    }

    /// The first day with events on or after `date`, else the last day.
    static func dayKey(onOrAfter date: Date, in days: [CalendarDay]) -> Int? {
        let k = CalendarDays.key(Int64(date.timeIntervalSince1970 * 1000), in: .current)
        return days.first(where: { $0.key >= k })?.key ?? days.last?.key
    }

    private func scroll(to date: Date) {
        target = nil
        let k = Self.dayKey(onOrAfter: date, in: days)
        Task { @MainActor in target = k }
    }

    private func load() async {
        guard let reader = app.reader else { events = nil; days = []; return }
        do {
            let list = try await Task.detached(priority: .userInitiated) { try reader.calendarEvents() }.value
            events = list; failure = nil
            regroup()
            scroll(to: jumpDate)
        } catch { failure = "\(error)"; events = nil; days = [] }
    }
}

// MARK: snapshot (plain stacks: ImageRenderer cannot draw List)

struct NotesSnapshot: View {
    let notes: [NoteItem]
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notes.prefix(12)) { NoteRow(note: $0); Divider() }
                Spacer(minLength: 0)
            }
            .padding(10).frame(width: 330).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            if let n = notes.first { NoteDetail(note: n).frame(maxHeight: .infinity, alignment: .top).background(Color(nsColor: .textBackgroundColor)) }
        }
        .frame(maxHeight: .infinity, alignment: .top).clipped()
    }
}

struct CalendarSnapshot: View {
    let days: [CalendarDay]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(days.prefix(8)) { day in
                CalendarDayHeader(day: day).padding(.top, 6)
                ForEach(day.events) { EventRow(event: $0) }
                Divider()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top).clipped()
    }
}
