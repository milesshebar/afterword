import SwiftUI
import ArchiveCore

/// Messages per month across the archive's years. Gaps are the point: a month with nothing inside the covered span draws
/// a red tick, a thin month (under 15% of the median) draws orange. Click a month to jump there.
struct CoverageStrip: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isSnapshot) private var isSnapshot
    // The macOS 27 SDK in the Command Line Tools makes @State a macro whose plugin only ships with Xcode, so state is
    // declared with the State struct directly (exactly what the wrapper expands to).
    private var _hover = State<Int?>(initialValue: nil)
    private var hover: Int? { get { _hover.wrappedValue } nonmutating set { _hover.wrappedValue = newValue } }
    private var _widthForHover = State<CGFloat>(initialValue: 800)
    private var widthForHover: CGFloat { get { _widthForHover.wrappedValue } nonmutating set { _widthForHover.wrappedValue = newValue } }

    private static let firstYear = 2011, lastYear = 2020

    private var months: [MonthCount] { app.activeMonths }

    private var axis: (start: Int, end: Int) {
        let all = app.archiveMonths
        let lo = min(Self.firstYear * 12, (all.first?.id ?? Self.firstYear * 12) / 12 * 12)
        let hi = max(Self.lastYear * 12 + 11, ((all.last?.id ?? 0) / 12) * 12 + 11)
        return (lo, hi)
    }

    private var scopeLabel: String {
        app.coverageScope == .thread && app.thread != nil ? app.selectionTitle : "all conversations"
    }

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Coverage").font(.caption.weight(.semibold))
                if app.thread != nil {
                    if isSnapshot { Text("Scope: \(app.coverageScope.rawValue)").font(.caption) }
                    else {
                        Picker("Scope", selection: $app.coverageScope) {
                            ForEach(CoverageScope.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                    }
                } else {
                    Text(scopeLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(hoverText).font(.caption).foregroundStyle(hover == nil ? .tertiary : .secondary).lineLimit(1)
            }
            Canvas { ctx, size in draw(ctx, size) }
                .frame(height: 62)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hover = index(at: p.x, width: widthForHover)
                    case .ended: hover = nil
                    }
                }
                .background(GeometryReader { g in Color.clear.preference(key: StripWidthKey.self, value: g.size.width) })
                .onPreferenceChange(StripWidthKey.self) { widthForHover = $0 }
                .gesture(SpatialTapGesture().onEnded { v in
                    if let i = index(at: v.location.x, width: widthForHover) { app.coverageClick(MonthKey(index: i)) }
                })
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    private var counts: [Int: Int] { Dictionary(uniqueKeysWithValues: months.map { ($0.id, $0.count) }) }

    private var hoverText: String {
        guard let h = hover else {
            if let m = app.monthFilter { return "\(Fmt.monthTitle(m.year, m.month)) selected · click again to clear" }
            return app.coverageScope == .thread && app.thread != nil ? "Click a month to scroll this conversation" : "Click a month to list who you talked to then"
        }
        let k = MonthKey(index: h)
        let n = counts[h] ?? 0
        return "\(Fmt.monthTitle(k.year, k.month)) · \(n == 0 ? "no messages" : "\(n.formatted()) message\(n == 1 ? "" : "s")")"
    }

    private func index(at x: CGFloat, width: CGFloat) -> Int? {
        let a = axis
        let n = a.end - a.start + 1
        guard width > 0, x >= 0, x < width else { return nil }
        return a.start + min(n - 1, Int(x / width * CGFloat(n)))
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let a = axis
        let n = a.end - a.start + 1
        let labelH: CGFloat = 15
        let plotH = size.height - labelH
        let w = size.width / CGFloat(n)
        let c = counts
        let nonzero = c.values.sorted()
        let maxC = Double(nonzero.last ?? 1)
        let median = nonzero.isEmpty ? 0 : Double(nonzero[nonzero.count / 2])
        let thin = median * 0.15
        let spanLo = c.keys.min() ?? a.start, spanHi = c.keys.max() ?? a.end
        let selected = app.highlightedMonth?.index

        for i in 0..<n {
            let idx = a.start + i
            let x = CGFloat(i) * w
            if idx == selected || idx == hover {
                ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: plotH)), with: .color(Color.primary.opacity(idx == selected ? 0.16 : 0.08)))
            }
            let count = c[idx] ?? 0
            if count == 0 {
                let inSpan = idx >= spanLo && idx <= spanHi
                ctx.fill(Path(CGRect(x: x + 0.5, y: plotH - 4, width: max(1, w - 1), height: 4)),
                         with: .color(inSpan ? Color.red.opacity(0.75) : Color.secondary.opacity(0.18)))
            } else {
                let h = max(3, plotH * CGFloat((Double(count) / maxC).squareRoot()))
                let color: Color = Double(count) < thin ? .orange : .teal
                ctx.fill(Path(CGRect(x: x + 0.5, y: plotH - h, width: max(1, w - 1), height: h)), with: .color(color.opacity(0.9)))
            }
            if idx % 12 == 0 {
                ctx.fill(Path(CGRect(x: x, y: plotH + 1, width: 0.5, height: 4)), with: .color(.secondary.opacity(0.6)))
                ctx.draw(Text(String(idx / 12)).font(.system(size: 10)).foregroundColor(.secondary), at: CGPoint(x: x + 3, y: plotH + 3), anchor: .topLeading)
            }
        }
        ctx.fill(Path(CGRect(x: 0, y: plotH, width: size.width, height: 0.5)), with: .color(.secondary.opacity(0.35)))
    }
}

private struct StripWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 800
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
