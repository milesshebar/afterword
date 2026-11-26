import Testing
@testable import ArchiveCore

/// A synthetic paged window of rows with varying heights: ids are positions in a virtual timeline, the window holds a slice.
private struct FakeList {
    var first: Int
    var count: Int
    var leadingExtra = 0.0   // spinner row above the first message
    var growth = 0.0         // a row above the anchor grew (a thumbnail replacing its placeholder)
    func height(_ id: Int) -> Double { 40 + Double((id * 7) % 5) * 10 }
    func minY(of id: Int) -> Double {
        var y = leadingExtra + growth
        if id > first { for k in first..<id { y += height(k) } }
        return y
    }
    var rows: [ScrollAnchorTracker<Int>.Row] {
        var out: [ScrollAnchorTracker<Int>.Row] = []
        var y = leadingExtra + growth
        for i in 0..<count {
            let h = height(first + i)
            out.append(.init(id: first + i, minY: y, maxY: y + h))
            y += h
        }
        return out
    }
    var maxOffset: Double { rows.last.map { $0.maxY - 600 } ?? 0 }
}

/// Plays the view's part: applies the tracker's answers until it settles, clamping to the content like a scroll view.
private func settle(_ t: inout ScrollAnchorTracker<Int>, _ list: FakeList, _ offset: inout Double) {
    for _ in 0..<6 {
        guard case .scroll(let o) = t.observe(offset: offset, rows: list.rows) else { return }
        offset = min(o, max(0, list.maxOffset))
        t.didScroll(to: offset)
    }
}

/// Where the row at the top of the viewport sits relative to it.
private func topRow(_ list: FakeList, _ offset: Double) -> (id: Int, y: Double) {
    let r = list.rows.filter { $0.maxY > offset }.min { $0.minY < $1.minY }!
    return (r.id, r.minY - offset)
}

@Suite struct ScrollAnchorTests {
    @Test func prependKeepsAnchorInPlace() {
        var t = ScrollAnchorTracker<Int>()
        var list = FakeList(first: 1000, count: 120)
        var offset = 20.0
        settle(&t, list, &offset)
        let before = list.minY(of: 1000) - offset
        list = FakeList(first: 880, count: 240)   // 120 older rows prepended
        settle(&t, list, &offset)
        #expect(list.minY(of: 1000) - offset == before)
        #expect(t.observe(offset: offset, rows: list.rows) == .none)
    }

    @Test func evictionFromTopKeepsAnchorInPlace() {
        var t = ScrollAnchorTracker<Int>()
        var list = FakeList(first: 0, count: 300)
        var offset = list.maxOffset - 20
        settle(&t, list, &offset)
        let (id, y) = topRow(list, offset)
        list = FakeList(first: 120, count: 300)   // 120 newer rows appended, 120 oldest dropped
        settle(&t, list, &offset)
        #expect(list.minY(of: id) - offset == y)
    }

    @Test func spinnerRowAddedAboveIsAbsorbed() {
        var t = ScrollAnchorTracker<Int>()
        var list = FakeList(first: 0, count: 120)
        var offset = 1000.0
        settle(&t, list, &offset)
        let (id, y) = topRow(list, offset)
        list.leadingExtra = 36
        settle(&t, list, &offset)
        #expect(list.minY(of: id) - offset == y)
    }

    @Test func realHeightsReplacingPlaceholdersAboveAreAbsorbed() {
        var t = ScrollAnchorTracker<Int>()
        var list = FakeList(first: 0, count: 200)
        var offset = 2000.0
        settle(&t, list, &offset)
        let (id, y) = topRow(list, offset)
        list.growth = 83
        settle(&t, list, &offset)
        #expect(list.minY(of: id) - offset == y)
    }

    @Test func userScrollMovesAnchorWithoutCorrection() {
        var t = ScrollAnchorTracker<Int>()
        var list = FakeList(first: 0, count: 200)
        var offset = 100.0
        settle(&t, list, &offset)
        #expect(t.observe(offset: 340, rows: list.rows) == .none)   // scrolled: no correction, new anchor
        list.leadingExtra = 36
        #expect(t.observe(offset: 340, rows: list.rows) == .scroll(to: 376))
    }

    @Test func manySuccessivePageLoadsInBothDirectionsStayStable() {
        var t = ScrollAnchorTracker<Int>()
        var list = FakeList(first: 100_000, count: 60)
        var offset = 0.0
        settle(&t, list, &offset)
        for step in 0..<60 {
            let older = step < 30
            offset = older ? 25 : list.maxOffset - 25   // the reader pushes to an edge of the window
            settle(&t, list, &offset)
            let (id, y) = topRow(list, offset)
            if older { list = FakeList(first: list.first - 60, count: min(300, list.count + 60)) }   // tail evicted past 300
            else { list = FakeList(first: list.first + 60, count: list.count) }                    // head evicted, tail appended
            settle(&t, list, &offset)
            #expect(list.minY(of: id) - offset == y)
        }
    }

    @Test func scrollClampedByShortContentIsReplacedWhenContentGrows() {
        var t = ScrollAnchorTracker<Int>()
        var list = FakeList(first: 1000, count: 120)
        var offset = 20.0
        settle(&t, list, &offset)
        let (id, y) = topRow(list, offset)
        list = FakeList(first: 880, count: 240)
        // The view can only reach 3000 for now; the anchor stays and is placed once the content has grown.
        if case .scroll(let o) = t.observe(offset: offset, rows: list.rows) { #expect(o > 3000); offset = 3000; t.didScroll(to: offset) }
        settle(&t, list, &offset)
        #expect(list.minY(of: id) - offset == y)
    }

    @Test func replacedContentResetsAnchor() {
        var t = ScrollAnchorTracker<Int>()
        var list = FakeList(first: 0, count: 100)
        var offset = 200.0
        settle(&t, list, &offset)
        t.reset()   // jump to date / search hit: the window is replaced and the view scrolls programmatically
        list = FakeList(first: 5000, count: 100)
        #expect(t.observe(offset: 200, rows: list.rows) == .none)
    }

    @Test func anchorGoneFromTheDataIsReplaced() {
        var t = ScrollAnchorTracker<Int>()
        var list = FakeList(first: 0, count: 100)
        var offset = 500.0
        settle(&t, list, &offset)
        list = FakeList(first: 5000, count: 100)
        #expect(t.observe(offset: 500, rows: list.rows) == .none)
        list.leadingExtra = 10
        #expect(t.observe(offset: 500, rows: list.rows) != .none)   // the new top row is now the anchor
    }

    @Test func clampedAtTopDropsAnchor() {
        var t = ScrollAnchorTracker<Int>()
        var list = FakeList(first: 10, count: 100)
        list.leadingExtra = 40
        var offset = 30.0
        settle(&t, list, &offset)
        list.leadingExtra = 0   // content moved up by more than the offset
        #expect(t.observe(offset: 30, rows: list.rows) == .scroll(to: 0))
    }
}
