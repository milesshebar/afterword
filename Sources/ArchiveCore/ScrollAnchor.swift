import Foundation

/// Scroll anchoring for a paged list whose rows are all laid out: remembers which row sits at the top of the viewport
/// and, when the layout shifts underneath without the reader scrolling (rows prepended or evicted, a thumbnail
/// replacing its placeholder, a window resize re-wrapping text), says what the scroll offset must become to keep that
/// row exactly where it was. Pure geometry, so it is tested on synthetic rows; the app feeds it real frames.
public struct ScrollAnchorTracker<ID: Hashable> {
    public struct Row {
        public var id: ID
        public var minY: Double
        public var maxY: Double
        public init(id: ID, minY: Double, maxY: Double) { self.id = id; self.minY = minY; self.maxY = maxY }
    }

    public enum Action: Equatable where ID: Equatable {
        case none
        /// Set the scroll offset to this value.
        case scroll(to: Double)
    }

    private var anchorID: ID?
    /// Where the anchor row's top edge sits relative to the viewport top: the invariant this type maintains.
    private var viewportTop = 0.0
    private var lastOffset: Double?
    public let tolerance: Double

    public init(tolerance: Double = 0.5) { self.tolerance = tolerance }

    /// Forget the anchor (the content was replaced, or a programmatic scroll is about to happen).
    public mutating func reset() { anchorID = nil; lastOffset = nil }

    /// The view could not scroll to the offset it was asked for (the content is shorter than the target for now) and
    /// ended up here; the anchor is kept and re-placed as the content changes.
    public mutating func didScroll(to actual: Double) { lastOffset = actual }

    /// Feed the current scroll offset and the frames of the rows (document coordinates). If the offset is where the
    /// tracker left it, the reader did not scroll, so a displaced anchor row is put back. Otherwise the reader
    /// scrolled (or there is no anchor yet) and the row at the top of the viewport becomes the anchor.
    public mutating func observe(offset: Double, rows: [Row]) -> Action {
        if let id = anchorID, let last = lastOffset, abs(last - offset) <= tolerance,
           let cur = rows.first(where: { $0.id == id }) {
            let wanted = cur.minY - viewportTop
            guard abs(wanted - offset) > tolerance else { return .none }
            let target = max(0, wanted)
            lastOffset = target
            if target != wanted { anchorID = nil }   // pinned against the top edge: the place cannot be kept
            return abs(target - offset) <= tolerance ? .none : .scroll(to: target)
        }
        lastOffset = offset
        let top = rows.filter { $0.maxY > offset + tolerance }.min { $0.minY < $1.minY }
        anchorID = top?.id
        viewportTop = (top?.minY ?? 0) - offset
        return .none
    }
}
