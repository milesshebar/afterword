import SwiftUI
import ArchiveCore

/// The three ways to fix a wrong match. State lives in AppModel (the CLT's SwiftUI has no usable @State macro).
struct PeopleSheetView: View {
    @Environment(AppModel.self) private var app
    let sheet: PeopleSheet

    var body: some View {
        Group {
            if let p = app.people.persons[sheet.personID] {
                switch sheet {
                case .rename: RenameSheet(person: p)
                case .merge: MergeSheet(person: p)
                case .split: SplitSheet(person: p)
                }
            } else {
                Text("That person is no longer in the list.").padding(30)
            }
        }
    }
}

private struct SheetFrame<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content
        }
        .padding(18).frame(width: 440)
    }
}

struct RenameSheet: View {
    @Environment(AppModel.self) private var app
    let person: Person
    var body: some View {
        @Bindable var app = app
        SheetFrame(title: "Rename", subtitle: "The name is yours: it replaces the automatic one in the list and survives re-imports. Leave it empty to go back to the automatic name.") {
            TextField("Name", text: $app.renameText).textFieldStyle(.roundedBorder).onSubmit { save() }
            HStack {
                Spacer()
                Button("Cancel") { app.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
    }
    private func save() {
        app.rename(person: person.id, to: app.renameText)
        app.sheet = nil
    }
}

struct MergeSheet: View {
    @Environment(AppModel.self) private var app
    let person: Person

    /// A person row keyed by its plain person id. The list's selection is `Int64?`, so every row's tag must be a
    /// non-optional `Int64`: tagging with `ConversationRow.personID` (an `Int64?`) never matched and nothing was selectable.
    private struct Candidate: Identifiable { let id: Int64; let row: ConversationRow }

    private var candidates: [Candidate] {
        let q = app.mergeQuery.trimmingCharacters(in: .whitespaces).lowercased()
        var rows = app.rows.filter { $0.isPerson && $0.personID != person.id }
        if !q.isEmpty {
            let terms = q.split(separator: " ").map(String.init)
            rows = rows.filter { r in terms.allSatisfy { r.searchKey.contains($0) } }
        }
        return rows.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }.prefix(150)
            .compactMap { r in r.personID.map { Candidate(id: $0, row: r) } }
    }

    var body: some View {
        @Bindable var app = app
        SheetFrame(title: "Merge \(app.displayName(person)) with…",
                   subtitle: "Their conversations become one timeline. You can split them apart again later.") {
            TextField("Search people", text: $app.mergeQuery).textFieldStyle(.roundedBorder)
            List(selection: $app.mergePick) {
                ForEach(candidates) { c in
                    let r = c.row
                    HStack(spacing: 8) {
                        Avatar(title: r.title, isGroup: false, size: 24)
                        Text(r.title).lineLimit(1)
                        Spacer(minLength: 4)
                        ForEach(r.services) { ServiceBadge(service: $0) }
                        Text(r.messageCount.formatted()).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(c.id)
                }
            }
            .frame(height: 260)
            HStack {
                Spacer()
                Button("Cancel") { app.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Merge") {
                    if let other = app.mergePick { app.merge(person: person.id, with: other) }
                    app.sheet = nil
                }
                .keyboardShortcut(.defaultAction).disabled(app.mergePick == nil)
            }
        }
    }
}

struct SplitSheet: View {
    @Environment(AppModel.self) private var app
    let person: Person
    var body: some View {
        SheetFrame(title: "Split \(app.displayName(person))",
                   subtitle: "Tick the accounts that are a different person. They become a person of their own; the rest stay here. The automatic matching won't join them again.") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(person.handles) { h in
                    Toggle(isOn: Binding(get: { app.splitPicks.contains(h.handleID) },
                                         set: { on in if on { app.splitPicks.insert(h.handleID) } else { app.splitPicks.remove(h.handleID) } })) {
                        HStack(spacing: 6) {
                            if let s = h.service { ServiceBadge(service: s) } else { Text("Phone / email").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary) }
                            Text(label(h)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(h.messages.formatted()).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { app.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Split Off") {
                    app.split(person: person.id, handleIDs: Array(app.splitPicks))
                    app.sheet = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(app.splitPicks.isEmpty || app.splitPicks.count >= person.handles.count)
            }
        }
    }
    private func label(_ h: PersonHandle) -> String {
        let n = app.contacts.names[h.normalized] ?? h.name
        return h.service != nil ? (n ?? h.raw) : [n, Fmt.phone(h.normalized)].compactMap { $0 }.joined(separator: " · ")
    }
}
