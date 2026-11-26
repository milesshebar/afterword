import SwiftUI
import AppKit
import ArchiveCore

enum ArchiveChooser {
    @MainActor static func pick(message: String = "Choose the folder that holds archive.sqlite and media/") -> URL? {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = false
        p.prompt = "Use This Archive"; p.message = message
        return p.runModal() == .OK ? p.url : nil
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.phase {
            case .loading:
                ProgressView("Opening archive…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                MainView()
            case .missing(let text):
                Problem(symbol: "externaldrive.badge.questionmark", title: "No archive found", text: text)
            case .failed(let text):
                Problem(symbol: "exclamationmark.triangle", title: "Couldn't open the archive", text: text)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    private struct Problem: View {
        @Environment(AppModel.self) private var app
        let symbol: String, title: String, text: String
        var body: some View {
            VStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.secondary)
                Text(title).font(.title2.weight(.semibold))
                Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460).textSelection(.enabled)
                Text(app.root.url.path).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                HStack {
                    Button("Choose Archive Folder…") { if let u = ArchiveChooser.pick() { app.setRoot(u) } }
                    Button("Try Again") { app.reload() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if app.isSearching { SearchResultsView() } else { ConversationListView() }
    }
}

struct EmptyDetail: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble").font(.system(size: 42)).foregroundStyle(.tertiary)
            Text("Select a conversation").font(.title3).foregroundStyle(.secondary)
            if let o = app.overview {
                Text("\(o.messages.formatted()) messages in \(o.threads.formatted()) conversations" + (o.isDemo ? " · demo archive (fake data)" : ""))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Header of the open conversation (snapshot only for a plain thread; the live window shows it in the toolbar).
struct ThreadHeader: View {
    @Environment(AppModel.self) private var app
    let model: ThreadModel
    var body: some View {
        HStack(spacing: 10) {
            Avatar(title: app.selectionTitle, isGroup: model.isGroup, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(app.selectionTitle).font(.headline).lineLimit(1)
                if !app.selectionTotalsLine.isEmpty { Text(app.selectionTotalsLine).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }
}

/// Header of a person's merged timeline: who, how many accounts, and the per-service filter chips.
struct PersonHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isSnapshot) private var isSnapshot
    let person: Person
    var body: some View {
        let counts = app.selectionServiceCounts
        let filter = app.serviceFilter
        HStack(spacing: 10) {
            Avatar(title: app.selectionTitle, isGroup: false, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.selectionTitle).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if counts.count > 1 {
                HStack(spacing: 6) {
                    ForEach(counts, id: \.0) { (service, n) in
                        let chip = ServiceChip(service: service, count: n, on: filter == nil || filter!.contains(service))
                        if isSnapshot { chip } else {
                            Button { app.toggleService(service) } label: { chip }.buttonStyle(.plain)
                                .help(filter == nil ? "Show only \(service.label)" : "Show or hide \(service.label)")
                        }
                    }
                    if filter != nil, !isSnapshot { Button("All") { app.clearServiceFilter() }.buttonStyle(.link).font(.caption) }
                }
            }
            if app.postsState.toggleVisible && !isSnapshot {
                Toggle(isOn: Binding(get: { app.showPosts }, set: { app.showPosts = $0 })) { Label("Posts and comments", systemImage: "text.bubble.fill") }
                    .toggleStyle(.button).controlSize(.small).help("Show this person's Facebook and Instagram posts and comments instead of the messages")
            }
            if isSnapshot { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
            else {
                Menu { PersonActionsMenu(personID: person.id) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("Fix this match: rename, merge, split")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    private var subtitle: String {
        var parts: [String] = []
        if !app.selectionTotalsLine.isEmpty { parts.append(app.selectionTotalsLine) }
        let accounts = person.handles.count
        if accounts > 1 { parts.append("\(accounts) accounts") }
        // Instagram usernames are inferred from the export's follower lists: "@user" only when sure, otherwise "possible @user".
        parts += person.usernames.map { "@" + $0 }
        parts += person.possibleUsernames.map { "possible @" + $0 }
        if person.hasManualEdits { parts.append("edited by you") }
        else if let h = person.handles.first(where: { $0.origin == "auto" && $0.reason != "single" }), accounts > 1, h.confidence < 0.7 { parts.append("matched by one-word name, check it") }
        return parts.joined(separator: " · ")
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isSnapshot) private var isSnapshot
    var body: some View {
        VStack(spacing: 0) {
            if let t = app.thread {
                if let p = app.selectedPerson { PersonHeader(person: p); Divider() }
                else if isSnapshot { ThreadHeader(model: t); Divider() }
                if app.showPosts && app.selectedPerson != nil { PersonPostsView() }
                else { ThreadView(model: t).id(ObjectIdentifier(t)) }
            } else {
                EmptyDetail()
            }
            Divider()
            CoverageStrip()
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 290, ideal: 350, max: 520)
        } detail: {
            DetailView()
                .navigationTitle(app.selection != nil ? app.selectionTitle : Product.name)
                .navigationSubtitle(app.selectionTotalsLine)
                .toolbar {
                    if app.thread != nil { ToolbarItem(placement: .primaryAction) { JumpToDateButton() } }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Recordings") { openWindow(id: "recordings") }
                            Button("Notes") { openWindow(id: "notes") }
                            Button("Calendar") { openWindow(id: "calendar") }
                        } label: { Label("Recordings, Notes and Calendar", systemImage: "note.text") }
                        .help("Open the archive's voicemails and voice memos, notes or calendar (also in the Window menu)")
                    }
                }
        }
        .searchable(text: $app.searchText, placement: .toolbar, prompt: "Search all messages")
        .onChange(of: app.searchText) { _, _ in app.resetHitLimit(); app.searchChanged() }
        .sheet(item: $app.sheet) { sheet in PeopleSheetView(sheet: sheet) }
        .alert("Couldn't change that", isPresented: Binding(get: { app.actionError != nil }, set: { if !$0 { app.actionError = nil } })) {
            Button("OK") { app.actionError = nil }
        } message: { Text(app.actionError ?? "") }
    }
}
