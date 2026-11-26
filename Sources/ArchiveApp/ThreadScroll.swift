import SwiftUI
import AppKit
import ArchiveCore

/// Vertical extent of one realized row in the scroll content's coordinate space.
struct RowSpan: Equatable { var minY: Double; var maxY: Double }

struct RowSpansKey: PreferenceKey {
    static let defaultValue: [ThreadItemID: RowSpan] = [:]
    static func reduce(value: inout [ThreadItemID: RowSpan], nextValue: () -> [ThreadItemID: RowSpan]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Reports this row's frame (content coordinates) so the scroll anchor can see where it is.
    func reportsSpan(_ id: ThreadItemID) -> some View {
        background(GeometryReader { g in
            let f = g.frame(in: .named(ThreadScrollSpace.name))
            Color.clear.preference(key: RowSpansKey.self, value: [id: RowSpan(minY: f.minY, maxY: f.maxY)])
        })
    }
}

enum ThreadScrollSpace { static let name = "thread-content" }

/// Keeps the message under the top of the viewport exactly where it is while pages load. The stack holds a bounded
/// window of rows, all laid out (a lazy stack estimates the height of rows it has not built, so content above the
/// viewport shifts unpredictably when rows are prepended or evicted). This watches the real row frames and the real
/// NSScrollView offset and puts the offset back whenever the anchor row moved but the reader did not (the geometry
/// itself is `ScrollAnchorTracker`). It also fires the edge loaders from the scroll offset.
@MainActor
final class ScrollAnchorDriver {
    private var tracker = ScrollAnchorTracker<ThreadItemID>()
    private(set) var spans: [ThreadItemID: RowSpan] = [:]
    private(set) weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    /// Held off while a programmatic jump (latest / date / search hit) is being applied.
    private(set) var suspended = true
    /// Edge loading: fired when the viewport comes within `edgeMargin` of either end of the window.
    var nearTop: (() -> Void)?
    var nearBottom: (() -> Void)?
    static let edgeMargin = 1200.0
    private(set) var corrections = 0
    /// Frames reported before the next layout belong to the previous data and are not acted on.
    private var spansStale = false
    /// True while this driver itself scrolls, so the resulting bounds notification is not mistaken for the reader.
    private var applying = false

    /// Called whenever the window's rows change, before SwiftUI lays the new rows out.
    func dataChanged() {
        spansStale = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.spansStale = false }
    }

    func suspend() { suspended = true; tracker.reset() }
    func resume() { suspended = false; tracker.reset(); run() }

    func attach(_ sv: NSScrollView?) {
        guard let sv, sv !== scrollView else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        scrollView = sv
        sv.contentView.postsBoundsChangedNotifications = true
        var targets: [(Notification.Name, NSView)] = [(NSView.boundsDidChangeNotification, sv.contentView)]
        if let doc = sv.documentView {
            // The document is resized a beat after the rows are laid out; an anchor that could not be placed is retried then.
            doc.postsFrameChangedNotifications = true
            targets.append((NSView.frameDidChangeNotification, doc))
        }
        observers = targets.map { name, view in
            NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.run() }
            }
        }
    }

    func spansChanged(_ s: [ThreadItemID: RowSpan]) {
        spans = s
        spansStale = false
        run()
    }

    // MARK: offset <-> AppKit

    private var flipped: Bool { scrollView?.documentView?.isFlipped ?? true }
    var offset: Double {
        guard let sv = scrollView, let doc = sv.documentView else { return 0 }
        let b = sv.contentView.bounds
        return flipped ? b.origin.y : doc.bounds.height - b.maxY
    }
    var docHeight: Double { Double(scrollView?.documentView?.bounds.height ?? 0) }
    var maxOffset: Double {
        guard let sv = scrollView, let doc = sv.documentView else { return 0 }
        return max(0, doc.bounds.height - sv.contentView.bounds.height)
    }
    func setOffset(_ value: Double) {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let v = min(max(0, value), maxOffset)
        let b = sv.contentView.bounds
        let y = flipped ? v : doc.bounds.height - b.height - v
        sv.contentView.scroll(to: NSPoint(x: b.origin.x, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    /// The row that is first on screen and where its top edge sits relative to the viewport (for the self-check).
    func topRow() -> (id: ThreadItemID, viewportTop: Double)? {
        let off = offset
        guard let t = spans.filter({ $0.value.maxY > off + 0.5 }).min(by: { $0.value.minY < $1.value.minY }) else { return nil }
        return (t.key, t.value.minY - off)
    }

    /// Fires the edge loaders when the viewport is near either end of the window (they ignore the call unless armed).
    func checkEdges() {
        guard !suspended, scrollView != nil else { return }
        let off = offset
        if off < Self.edgeMargin { nearTop?() }
        if off > maxOffset - Self.edgeMargin { nearBottom?() }
    }

    private func run() {
        guard !suspended, !applying, scrollView != nil else { return }
        defer { checkEdges() }
        guard !spansStale else { return }
        let rows = spans.map { ScrollAnchorTracker<ThreadItemID>.Row(id: $0.key, minY: $0.value.minY, maxY: $0.value.maxY) }
        guard case .scroll(let o) = tracker.observe(offset: offset, rows: rows) else { return }
        corrections += 1
        applying = true
        setOffset(o)
        applying = false
        tracker.didScroll(to: offset)
    }
}

/// Zero-size NSView inside the scroll content whose only job is to find the enclosing NSScrollView.
struct ScrollViewFinder: NSViewRepresentable {
    let driver: ScrollAnchorDriver
    func makeNSView(context: Context) -> NSView { FinderView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        let d = driver
        (nsView as? FinderView)?.onFound = { sv in MainActor.assumeIsolated { d.attach(sv) } }
        DispatchQueue.main.async { MainActor.assumeIsolated { d.attach(nsView.enclosingScrollView) } }
    }
    final class FinderView: NSView {
        var onFound: ((NSScrollView) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let sv = enclosingScrollView { onFound?(sv) }
        }
    }
}
