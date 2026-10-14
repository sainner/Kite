import SwiftUI

/// 窗口组里的一个窗口。Mac 上每个是一张卡片，iPhone 上一次显示一个，用页签切换。
struct Pane: Hashable, Codable {
    let id: String
    init(_ id: String) { self.id = id }
}

/// 卡片的排布：一块地方要么放一张卡片，要么沿一个方向切成两块，每块再照此细分。
/// 左右、上下、左一右二都是这样拼出来的。拖动卡片时，预览的排布里会有一个占位。
enum Tile {
    case pane(Pane)
    case placeholder
    case split(Split)
}

@Observable
final class Split {
    let axis: Axis
    /// 第一块占的比例：拖缝、侧栏改宽时改，系统窗口变大变小时各块按它分。
    private var storedRatio: CGFloat
    /// 临时省略卡片时仍调整原分栏；视口恢复后沿用用户拖过的比例。
    let source: Split?
    var ratio: CGFloat {
        get { source?.ratio ?? storedRatio }
        set {
            if let source { source.ratio = newValue }
            else { storedRatio = newValue }
        }
    }
    let first: Tile
    let second: Tile
    /// 临时省略卡片时重建的分栏和原分栏是同一刀：比例、缝的视图和改尺寸前记下的长度都按它认。
    var identity: ObjectIdentifier { ObjectIdentifier(source ?? self) }

    init(_ axis: Axis, _ ratio: CGFloat, _ first: Tile, _ second: Tile, source: Split? = nil) {
        self.axis = axis
        self.storedRatio = ratio
        self.source = source
        self.first = first
        self.second = second
    }

    /// 值没变不写，免得读它的视图跟着重算。
    func setRatio(_ value: CGFloat) {
        if ratio != value { ratio = value }
    }

    /// 把这一刀挪到第一块长 length 的地方（available 是两块加起来的长）：两边都只让紧挨着这一刀的窗口改尺寸，见 Tile.absorb。
    func cut(at length: CGFloat, available: CGFloat, base: TileBase) {
        if let cut = base.cuts[identity] {
            first.absorb(along: axis, from: cut.first, to: length, atEnd: true, base: base)
            second.absorb(along: axis, from: cut.second, to: available - length, atEnd: false, base: base)
        }
        setRatio(length / available)
    }
}

/// 改尺寸之前每一刀两边各多长、比例多少，按 Split.identity 记。拖缝、侧栏改宽都从它算：改回原来的长度，窗口就原样回来，
/// 中途被挤到最小尺寸的也一样。
struct TileBase {
    struct Cut {
        let first: CGFloat
        let second: CGFloat
        let ratio: CGFloat
    }

    let cuts: [ObjectIdentifier: Cut]

    init(_ layout: TileLayout) {
        var cuts: [ObjectIdentifier: Cut] = [:]
        for gap in layout.gaps {
            let horizontal = gap.split.axis == .horizontal
            cuts[gap.id] = Cut(first: horizontal ? gap.rect.minX - gap.region.minX : gap.rect.minY - gap.region.minY,
                               second: horizontal ? gap.region.maxX - gap.rect.maxX : gap.region.maxY - gap.rect.maxY,
                               ratio: gap.split.ratio)
        }
        self.cuts = cuts
    }
}

extension CGSize {
    /// 沿 axis 的长度：左右切看宽，上下切看高。
    func length(along axis: Axis) -> CGFloat { axis == .horizontal ? width : height }
}

/// 一种排布在某块地方里摆出来的样子：各张卡片、占位、每一刀留下的缝各在哪。
struct TileLayout {
    var panes: [Pane: CGRect] = [:]
    var placeholder: CGRect?
    var gaps: [Gap] = []

    /// 一刀留下的缝，拖动它调整这一刀的比例。
    struct Gap: Identifiable {
        let split: Split
        let rect: CGRect
        /// 这一刀切的整块地方。
        let region: CGRect
        var id: ObjectIdentifier { split.identity }
    }
}

extension Tile {
    /// 排布里有哪些窗口，从左上到右下。
    var panes: [Pane] {
        switch self {
        case .pane(let pane): [pane]
        case .placeholder: []
        case .split(let split): split.first.panes + split.second.panes
        }
    }

    /// 最小尺寸：每张卡片不小于 minPane；切成两块时，沿切的方向两块相加再加上缝，另一个方向取大的。
    var minimumSize: CGSize {
        switch self {
        case .pane, .placeholder:
            CGSize(width: Metrics.minPane, height: Metrics.minPane)
        case .split(let split):
            split.axis == .horizontal
                ? CGSize(width: split.first.minimumSize.width + Metrics.gap + split.second.minimumSize.width,
                         height: max(split.first.minimumSize.height, split.second.minimumSize.height))
                : CGSize(width: max(split.first.minimumSize.width, split.second.minimumSize.width),
                         height: split.first.minimumSize.height + Metrics.gap + split.second.minimumSize.height)
        }
    }

    /// 各块按比例分；排出来的长度取到半点，见 halfPoint。
    func layout(in rect: CGRect) -> TileLayout {
        var result = TileLayout()
        place(in: rect, into: &result)
        return result
    }

    private func place(in rect: CGRect, into result: inout TileLayout) {
        switch self {
        case .pane(let pane):
            result.panes[pane] = rect
        case .placeholder:
            result.placeholder = rect
        case .split(let split):
            let horizontal = split.axis == .horizontal
            let edge: CGRectEdge = horizontal ? .minXEdge : .minYEdge
            let available = max((horizontal ? rect.width : rect.height) - Metrics.gap, 0)
            let firstMinimum = split.first.minimumSize.length(along: split.axis)
            let secondMinimum = split.second.minimumSize.length(along: split.axis)
            // 比例照常保存，窗口变大变小时按比例分
            let requested = Self.halfPoint(available * split.ratio)
            let length = available >= firstMinimum + secondMinimum
                ? min(max(requested, firstMinimum), available - secondMinimum) : requested
            let (a, rest) = rect.divided(atDistance: length, from: edge)
            let (gap, b) = rest.divided(atDistance: Metrics.gap, from: edge)
            result.gaps.append(TileLayout.Gap(split: split, rect: gap, region: rect))
            split.first.place(in: a, into: &result)
            split.second.place(in: b, into: &result)
        }
    }

    /// 长度取到半点：Retina 屏上边缘落在像素上。台面的宽高也是半点的整数倍（界面按像素摆），
    /// 加减不出零头，改尺寸时不相邻的窗口一点不差地保持原来的长度。
    static func halfPoint(_ length: CGFloat) -> CGFloat { (length * 2).rounded() / 2 }

    /// 沿 axis 把这一块从 old 改成 new 长，只让贴着 end 那条边的窗口改尺寸，其余窗口保持 base 里的长度；
    /// 贴边的小到最小尺寸后，再由离这条边近的往远处依次让出。end 为 true 是后头那条边（右、下），false 是前头（左、上）。
    /// 顺着另一个方向切开的两块都贴着这条边，各自照此调整。都从 base 算，长度改回 base 里的就回到原来的比例。
    func absorb(along axis: Axis, from old: CGFloat, to new: CGFloat, atEnd end: Bool, base: TileBase) {
        guard case .split(let split) = self, let cut = base.cuts[split.identity] else { return }
        guard old != new else {
            restore(base)
            return
        }
        guard split.axis == axis else {
            split.first.absorb(along: axis, from: old, to: new, atEnd: end, base: base)
            split.second.absorb(along: axis, from: old, to: new, atEnd: end, base: base)
            return
        }
        let available = new - Metrics.gap
        guard available > 0 else { return }
        let (near, far) = end ? (split.second, split.first) : (split.first, split.second)
        let (nearOld, farOld) = end ? (cut.second, cut.first) : (cut.first, cut.second)
        let nearMinimum = near.minimumSize.length(along: axis), farMinimum = far.minimumSize.length(along: axis)
        // 远的一块保持原长；近的到了最小尺寸，远的再让，也不小于它自己的最小尺寸
        let farNew = max(min(farOld, available - nearMinimum), min(farMinimum, farOld))
        let nearNew = available - farNew
        near.absorb(along: axis, from: nearOld, to: nearNew, atEnd: end, base: base)
        far.absorb(along: axis, from: farOld, to: farNew, atEnd: end, base: base)
        split.setRatio((end ? farNew : nearNew) / available)
    }

    /// 各刀回到 base 里的比例。
    private func restore(_ base: TileBase) {
        guard case .split(let split) = self else { return }
        if let cut = base.cuts[split.identity] { split.setRatio(cut.ratio) }
        split.first.restore(base)
        split.second.restore(base)
    }

    /// 各刀现在的比例，按 Split.identity 记。
    var ratios: [ObjectIdentifier: CGFloat] {
        guard case .split(let split) = self else { return [:] }
        var ratios = split.first.ratios.merging(split.second.ratios) { a, _ in a }
        ratios[split.identity] = split.ratio
        return ratios
    }

    /// 拿掉一张卡片，它所在的那一刀由另一半补上。
    func removing(_ pane: Pane, preservingSource: Bool = false) -> Tile? {
        switch self {
        case .pane(let p):
            return p == pane ? nil : self
        case .placeholder:
            return self
        case .split(let split):
            guard let first = split.first.removing(pane, preservingSource: preservingSource) else { return split.second }
            guard let second = split.second.removing(pane, preservingSource: preservingSource) else { return first }
            return rebuilt(split, first, second, preservingSource: preservingSource)
        }
    }

    /// 把一张卡片换成 tile，位置不变。
    func replacing(_ pane: Pane, with tile: Tile) -> Tile {
        switch self {
        case .pane(let p):
            return p == pane ? tile : self
        case .placeholder:
            return self
        case .split(let split):
            return rebuilt(split, split.first.replacing(pane, with: tile), split.second.replacing(pane, with: tile))
        }
    }

    /// 从 target 的 edge 那边切一刀，把 tile 放进去，两半各占一半。
    func inserting(_ tile: Tile, beside target: Pane, on edge: Edge) -> Tile {
        replacing(target, with: Tile.pane(target).inserting(tile, on: edge))
    }

    /// 在整个排布外面切一刀，原来的窗口一起放在另一侧。
    func inserting(_ tile: Tile, on edge: Edge, ratio: CGFloat = 0.5) -> Tile {
        let axis: Axis = edge == .leading || edge == .trailing ? .horizontal : .vertical
        let before = edge == .leading || edge == .top
        return .split(Split(axis, ratio, before ? tile : self, before ? self : tile))
    }

    /// 两边都没变就沿用原来的这一刀：它的缝的视图不用重建，比例也还是同一份。
    private func rebuilt(_ split: Split, _ first: Tile, _ second: Tile, preservingSource: Bool = false) -> Tile {
        first.isSame(split.first) && second.isSame(split.second) ? self
            : .split(Split(split.axis, split.ratio, first, second, source: preservingSource ? (split.source ?? split) : nil))
    }

    private func isSame(_ other: Tile) -> Bool {
        switch (self, other) {
        case (.pane(let a), .pane(let b)): a == b
        case (.placeholder, .placeholder): true
        case (.split(let a), .split(let b)): a === b
        default: false
        }
    }
}

/// 几种预设的排布，先用来看布局。
enum Arrangement: String, CaseIterable {
    case sideBySide = "左右"
    case stacked = "上下"
    case oneAndTwo = "左一右二"
    case oneAndThree = "左一右三"

    func tile(for panes: [Pane]) -> Tile? {
        guard let first = panes.first else { return nil }
        let count = min(panes.count, self == .oneAndThree ? 4 : self == .oneAndTwo ? 3 : 2)
        guard count > 1 else { return .pane(first) }
        if self == .sideBySide || self == .stacked {
            return .split(Split(self == .sideBySide ? .horizontal : .vertical, 0.6, .pane(first), .pane(panes[1])))
        }
        func column(_ remaining: ArraySlice<Pane>) -> Tile {
            guard remaining.count > 1 else { return .pane(remaining.first!) }
            return .split(Split(.vertical, 1 / CGFloat(remaining.count), .pane(remaining.first!), column(remaining.dropFirst())))
        }
        return .split(Split(.horizontal, 0.6, .pane(first), column(panes[1..<count])))
    }
}

/// 内容区和右侧停靠栏使用同一坐标系，拖动时不跨视图换算落点。
struct WindowRegions {
    let canvas: CGRect
    let dock: CGRect

    init(in bounds: CGRect, showsDock: Bool = true) {
        let dockWidth = showsDock ? Metrics.dockWidth : 0
        canvas = CGRect(x: bounds.minX, y: bounds.minY,
                        width: max(0, bounds.width - dockWidth - (showsDock ? Metrics.gap : 0)), height: bounds.height)
        dock = CGRect(x: bounds.maxX - dockWidth, y: bounds.minY, width: dockWidth, height: bounds.height)
    }

    func dockFrame(at index: Int) -> CGRect {
        CGRect(x: dock.midX - Metrics.dragBubble / 2,
               y: dock.minY + CGFloat(index) * (Metrics.dragBubble + Metrics.gap),
               width: Metrics.dragBubble, height: Metrics.dragBubble)
    }

    func dockIndex(at point: CGPoint, count: Int) -> Int {
        min(max(Int((point.y - dock.minY) / (Metrics.dragBubble + Metrics.gap)), 0), count)
    }

    func canvasEdge(at point: CGPoint) -> Edge? {
        guard canvas.contains(point) else { return nil }
        let distances: [(Edge, CGFloat)] = [
            (.leading, point.x - canvas.minX), (.trailing, canvas.maxX - point.x),
            (.top, point.y - canvas.minY), (.bottom, canvas.maxY - point.y)
        ]
        return distances.filter { $0.1 <= Metrics.windowEdgeDrop }.min { $0.1 < $1.1 }?.0
    }
}

/// 松手后放在整个内容区的一侧、另一张卡片旁、空内容区，或者停靠栏中。
enum DropSpot: Equatable {
    case edge(Edge)
    case beside(Pane, Edge)
    case canvas
    case dock(Int)
}

/// 拖动卡片：标题栏拖够一段距离后，卡片脱离布局并缩成圆跟着指针；指针落在卡片上时，
/// 在离指针最近的那条边插进占位；靠近内容区外缘时占满整条边，也可放进右侧停靠栏；没有落点就回原位。
struct CardDrag {
    let pane: Pane
    /// 脱离后剩下的排布；只剩这一张卡片时为 nil。
    var rest: Tile?
    var spot: DropSpot?
    /// 贴着内容区外缘放时，其余窗口挤不下、给它腾地方收进停靠栏的那几个，见 WindowLayout.edgeRoom。
    var displaced: [Pane] = []
    /// 拖动中显示的排布：剩下的，或者插了占位的预览。
    var layout: Tile?
    /// 拖动期间的停靠顺序，包含落点占位所对应的窗口。
    var docked: [Pane] = []

    /// 把 tile 放到落点上的排布；没有落点时为 nil。
    func placing(_ tile: Tile, in canvas: CGRect) -> Tile? {
        switch spot {
        case .edge(let edge):
            guard let rest = displaced.reduce(rest, { $0?.removing($1) }) else { return nil }
            let horizontal = edge == .leading || edge == .trailing
            let before = edge == .leading || edge == .top
            let length = { (size: CGSize) in horizontal ? size.width : size.height }
            let available = length(canvas.size) - Metrics.gap
            // 优先各占一半；其余窗口嵌套较深时，给它们留足最小尺寸。
            let first = length(before ? tile.minimumSize : rest.minimumSize)
            let second = length(before ? rest.minimumSize : tile.minimumSize)
            let ratio = min(max(0.5, first / available), 1 - second / available)
            return rest.inserting(tile, on: edge, ratio: ratio)
        case .beside(let target, let edge): return rest?.inserting(tile, beside: target, on: edge)
        case .canvas: return tile
        default: return nil
        }
    }
}
