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
    /// 第一块占的比例，拖动两块之间的缝时改变。
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

    init(_ axis: Axis, _ ratio: CGFloat, _ first: Tile, _ second: Tile, source: Split? = nil) {
        self.axis = axis
        self.storedRatio = ratio
        self.source = source
        self.first = first
        self.second = second
    }
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
        var id: ObjectIdentifier { ObjectIdentifier(split.source ?? split) }
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

    /// 每一刀都吸附到模块线上；free 是正在拖的那一刀，跟手不吸附，松手后再吸附。
    func layout(in rect: CGRect, free: Split? = nil) -> TileLayout {
        var result = TileLayout()
        place(in: rect, free: free, into: &result)
        return result
    }

    private func place(in rect: CGRect, free: Split?, into result: inout TileLayout) {
        switch self {
        case .pane(let pane):
            result.panes[pane] = rect
        case .placeholder:
            result.placeholder = rect
        case .split(let split):
            let horizontal = split.axis == .horizontal
            let edge: CGRectEdge = horizontal ? .minXEdge : .minYEdge
            let available = max((horizontal ? rect.width : rect.height) - Metrics.gap, 0)
            let firstMinimum = horizontal ? split.first.minimumSize.width : split.first.minimumSize.height
            let secondMinimum = horizontal ? split.second.minimumSize.width : split.second.minimumSize.height
            // 比例照常保存，窗口变大变小时按比例分；排出来的长度取整到模块。
            let requested = (split.source ?? split) === free ? (available * split.ratio).rounded() : DotMetrics.snap(available * split.ratio)
            let length = available >= firstMinimum + secondMinimum
                ? min(max(requested, firstMinimum), available - secondMinimum) : requested
            let (a, rest) = rect.divided(atDistance: length, from: edge)
            let (gap, b) = rest.divided(atDistance: Metrics.gap, from: edge)
            result.gaps.append(TileLayout.Gap(split: split, rect: gap, region: rect))
            split.first.place(in: a, free: free, into: &result)
            split.second.place(in: b, free: free, into: &result)
        }
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

    /// 内容区从模块线开始；尺寸不是模块整数倍时，余下的不足一格留在右边和下边。
    init(in bounds: CGRect, showsDock: Bool = true) {
        let width = DotMetrics.snapDown(bounds.width), height = DotMetrics.snapDown(bounds.height)
        let dockWidth = showsDock ? Metrics.dockWidth : 0
        canvas = CGRect(x: bounds.minX, y: bounds.minY,
                        width: max(0, width - dockWidth - (showsDock ? Metrics.gap : 0)), height: height)
        dock = CGRect(x: bounds.minX + width - dockWidth, y: bounds.minY,
                      width: dockWidth, height: height)
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
    /// 拖动中显示的排布：剩下的，或者插了占位的预览。
    var layout: Tile?
    /// 拖动期间的停靠顺序，包含落点占位所对应的窗口。
    var docked: [Pane] = []

    /// 把 tile 放到落点上的排布；没有落点时为 nil。
    func placing(_ tile: Tile, in canvas: CGRect) -> Tile? {
        switch spot {
        case .edge(let edge):
            guard let rest else { return nil }
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
