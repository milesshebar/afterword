import SwiftUI
import QuickLook
import ArchiveCore

struct ThreadView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isSnapshot) private var isSnapshot
    @Bindable var model: ThreadModel

    var body: some View {
        Group {
            if isSnapshot { snapshotBody } else { liveBody }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder private func itemView(_ item: ThreadItem) -> some View {
        switch item.kind {
        case .day(let text):
            DaySeparator(text: text)
        case .message(let row, let showSender, let showTime, let tight):
            MessageBubbleRow(model: model, row: row, showSender: showSender, showTime: showTime, tight: tight)
        case .call(let call, let showTime):
            CallLineRow(call: call, showTime: showTime)
        case .voicemail(let vm, let showTime):
            VStack(spacing: 2) {
                if showTime { Text(Fmt.time(vm.tsMs ?? 0)).font(.caption2).foregroundStyle(.tertiary).padding(.top, 6) }
                RecordingCard(row: vm, inTimeline: true)
            }
        }
    }

    private var liveBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // The edge rows keep their height whether or not loading is armed, so arming never shifts content.
                    if !model.reachedStart {
                        ProgressView().controlSize(.small).frame(height: 36)
                            .opacity(model.armed ? 1 : 0)

                    }
                    ForEach(model.items) { item in
                        itemView(item).reportsSpan(item.id).id(item.id)
                    }
                    if !model.reachedEnd {
                        ProgressView().controlSize(.small).frame(height: 36)
                            .opacity(model.armed ? 1 : 0)

                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                .coordinateSpace(name: ThreadScrollSpace.name)
                .background(ScrollViewFinder(driver: model.anchor))
            }
            .onPreferenceChange(RowSpansKey.self) { spans in MainActor.assumeIsolated { model.anchor.spansChanged(spans) } }
            .onAppear {
                model.anchor.nearTop = { [weak model] in model?.loadOlderIfArmed() }
                model.anchor.nearBottom = { [weak model] in model?.loadNewerIfArmed() }
            }
            .onChange(of: model.scrollRequest) { _, req in
                guard let req else { return }
                // Lazy rows below the target have estimated heights on the first pass, so settle with a second scroll.
                proxy.scrollTo(req.id, anchor: req.anchor)
                Task {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    proxy.scrollTo(req.id, anchor: req.anchor)
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    model.scrollApplied(token: req.token)
                }
            }
            .overlay {
                if model.loading && model.items.isEmpty { ProgressView() }
            }
        }
        .quickLookPreview($model.quickLookURL, in: model.quickLookItems)
    }

    /// ImageRenderer cannot draw a ScrollView, so the snapshot shows the bottom of the window as a plain stack.
    private var snapshotBody: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    ForEach(model.items.suffix(60)) { item in itemView(item) }
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
            }
            .clipped()
    }
}

struct JumpToDateButton: View {
    @Environment(AppModel.self) private var app
    // The macOS 27 SDK in the Command Line Tools makes @State a macro whose plugin only ships with Xcode, so state is
    // declared with the State struct directly (exactly what the wrapper expands to).
    private var _shown = State(initialValue: false)
    private var _date = State(initialValue: Date())
    private var shown: Bool { get { _shown.wrappedValue } nonmutating set { _shown.wrappedValue = newValue } }
    private var date: Date { get { _date.wrappedValue } nonmutating set { _date.wrappedValue = newValue } }

    var body: some View {
        Button { shown = true } label: { Label("Jump to Date", systemImage: "calendar") }
            .keyboardShortcut("j", modifiers: .command)
            .help("Jump to a date in this conversation (⌘J)")
            .popover(isPresented: _shown.projectedValue) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Jump to date").font(.headline)
                    DatePicker("", selection: _date.projectedValue, in: range, displayedComponents: .date)
                        .datePickerStyle(.graphical).labelsHidden()
                    HStack {
                        Spacer()
                        Button("Cancel") { shown = false }.keyboardShortcut(.cancelAction)
                        Button("Go") { app.jumpInOpenThread(toDate: date); shown = false }.keyboardShortcut(.defaultAction)
                    }
                }
                .padding(14).frame(width: 260)
            }
            .onAppear { if let o = app.overview?.firstTsMs { date = Fmt.date(o) } }
    }

    private var range: ClosedRange<Date> {
        let lo = app.overview?.firstTsMs.map(Fmt.date) ?? Date(timeIntervalSince1970: 0)
        let hi = app.overview?.lastTsMs.map(Fmt.date) ?? Date()
        return lo...max(lo, hi)
    }
}
