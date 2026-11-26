import SwiftUI
import ArchiveCore

struct Avatar: View {
    let title: String
    let isGroup: Bool
    var size: CGFloat = 38
    var body: some View {
        ZStack {
            Circle().fill(Fmt.avatarColor(title).gradient)
            if isGroup { Image(systemName: "person.2.fill").font(.system(size: size * 0.40)).foregroundStyle(.white) }
            else { Text(Fmt.initials(title)).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white) }
        }
        .frame(width: size, height: size)
    }
}

struct ConversationRowView: View {
    let row: ConversationRow
    let selected: Bool
    var body: some View {
        HStack(spacing: 10) {
            Avatar(title: row.title, isGroup: row.isGroup)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if row.isHiddenRow { Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.tertiary) }
                    Spacer(minLength: 4)
                    Text(Fmt.listDate(row.lastTsMs)).font(.caption).foregroundStyle(.secondary)
                }
                Text(row.preview ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 5) {
                    Text("\(row.messageCount.formatted()) \(row.messageCount == 1 ? "message" : "messages")").font(.caption2).foregroundStyle(.tertiary)
                    if row.callCount > 0 {
                        Text("· \(row.callCount.formatted()) \(row.callCount == 1 ? "call" : "calls")").font(.caption2).foregroundStyle(.tertiary)
                    }
                    ForEach(row.services) { ServiceBadge(service: $0, compact: row.services.count > 2) }
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// The corrections for a wrong match, as a menu (row context menu and the person header's menu).
struct PersonActionsMenu: View {
    @Environment(AppModel.self) private var app
    let personID: Int64
    var body: some View {
        if let p = app.people.persons[personID] {
            Button("Rename…") { app.present(.rename(personID)) }
            Button("Merge with…") { app.present(.merge(personID)) }
            Button("Split Accounts Off…") { app.present(.split(personID)) }.disabled(p.handles.count < 2)
            Divider()
            Button(p.hidden ? "Show in List" : "Hide from List") { app.setHidden(person: personID, !p.hidden) }
            if p.hasManualEdits { Button("Undo My Corrections") { app.resetCorrections(person: personID) } }
        }
    }
}

struct ConversationListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary).font(.caption)
                    if isSnapshot { Text(app.filterText.isEmpty ? "Filter conversations" : app.filterText).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    else { TextField("Filter conversations", text: $app.filterText).textFieldStyle(.plain) }
                    if !app.filterText.isEmpty {
                        Button { app.filterText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                HStack {
                    Text(summaryLine).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if isSnapshot { Text(app.showHidden ? "Hidden shown" : "Hidden off").font(.caption2).foregroundStyle(.secondary) }
                    else {
                        Toggle("Show hidden", isOn: $app.showHidden).toggleStyle(.checkbox).controlSize(.small)
                            .help("Filtered threads, message requests and people you hid")
                    }
                    if isSnapshot { Text(app.sort.rawValue + " ⌄").font(.caption) }
                    else {
                        Picker("Sort", selection: $app.sort) {
                            ForEach(ConversationSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                    }
                }
                if let m = app.monthFilter { monthChip(m) }
                if !isSnapshot, app.contacts.access == .notDetermined, ContactsResolver.canPrompt { contactsBanner }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            list
        }
    }

    private var summaryLine: String {
        let n = app.visibleRows.count
        return "\(n.formatted()) \(n == 1 ? "person or group" : "people and groups")"
    }

    private var contactsBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle")
            Text("Show names from Contacts?").font(.caption)
            Spacer(minLength: 0)
            Button("Allow") { Task { await app.contacts.requestAccess(); await app.refreshContacts() } }.controlSize(.small)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
    }

    private func monthChip(_ m: MonthKey) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
            Text("\(Fmt.monthTitle(m.year, m.month)): conversations active in this month").font(.caption).lineLimit(1)
            Spacer(minLength: 0)
            Button { app.setMonthFilter(nil) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
        .foregroundStyle(Color.accentColor)
    }

    @ViewBuilder private var list: some View {
        let rows = app.visibleRows
        if isSnapshot {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    VStack(spacing: 0) {
                        ForEach(rows.prefix(14)) { r in
                            ConversationRowView(row: r, selected: r.id == app.selection)
                                .padding(.horizontal, 10)
                                .background(r.id == app.selection ? Color.accentColor.opacity(0.22) : .clear)
                        }
                    }
                }
                .clipped()
        } else if rows.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Text(app.filterText.isEmpty ? "No conversations" : "No matches").foregroundStyle(.secondary)
                Spacer()
            }.frame(maxWidth: .infinity)
        } else {
            List(selection: Binding(get: { app.selection }, set: { app.select($0) })) {
                ForEach(rows) { r in
                    ConversationRowView(row: r, selected: false).tag(r.id as ListItemID?)
                        .contextMenu { if let p = r.personID { PersonActionsMenu(personID: p) } }
                }
            }
            .listStyle(.sidebar)
        }
    }
}
