import SwiftUI

/// 内容区里的小窗口。Mac 上每个是一张卡片，iPhone 上用页签切换。
enum Pane: CaseIterable {
    case session, files, terminal, preview
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
    var ratio: CGFloat
    let first: Tile
    let second: Tile

    init(_ axis: Axis, _ ratio: CGFloat, _ first: Tile, _ second: Tile) {
        self.axis = axis
        self.ratio = ratio
        self.first = first
        self.second = second
    }

    /// 第一块的长度。两块之间留一道缝。
    func firstLength(in total: CGFloat) -> CGFloat {
        (max(total - Metrics.gap, 0) * ratio).rounded()
    }
}

extension Tile {
    /// 各张卡片在 rect 里的位置，和 SplitView 的排法一致。
    func frames(in rect: CGRect) -> [Pane: CGRect] {
        switch self {
        case .pane(let pane):
            return [pane: rect]
        case .placeholder:
            return [:]
        case .split(let split):
            let horizontal = split.axis == .horizontal
            let first = split.firstLength(in: horizontal ? rect.width : rect.height)
            let rest = (horizontal ? rect.width : rect.height) - first - Metrics.gap
            let a = horizontal
                ? CGRect(x: rect.minX, y: rect.minY, width: first, height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: first)
            let b = horizontal
                ? CGRect(x: a.maxX + Metrics.gap, y: rect.minY, width: rest, height: rect.height)
                : CGRect(x: rect.minX, y: a.maxY + Metrics.gap, width: rect.width, height: rest)
            return split.first.frames(in: a).merging(split.second.frames(in: b)) { old, _ in old }
        }
    }

    /// 拿掉一张卡片，它所在的那一刀由另一半补上。
    func removing(_ pane: Pane) -> Tile? {
        switch self {
        case .pane(let p):
            return p == pane ? nil : self
        case .placeholder:
            return self
        case .split(let split):
            guard let first = split.first.removing(pane) else { return split.second }
            guard let second = split.second.removing(pane) else { return first }
            return .split(Split(split.axis, split.ratio, first, second))
        }
    }

    /// 从 target 的 edge 那边切一刀，把 tile 放进去，两半各占一半。
    func inserting(_ tile: Tile, beside target: Pane, on edge: Edge) -> Tile {
        switch self {
        case .pane(let p) where p == target:
            let axis: Axis = edge == .leading || edge == .trailing ? .horizontal : .vertical
            let before = edge == .leading || edge == .top
            return .split(Split(axis, 0.5, before ? tile : self, before ? self : tile))
        case .pane, .placeholder:
            return self
        case .split(let split):
            return .split(Split(split.axis, split.ratio,
                                split.first.inserting(tile, beside: target, on: edge),
                                split.second.inserting(tile, beside: target, on: edge)))
        }
    }
}

/// 几种预设的排布，先用来看布局。
enum Arrangement: String, CaseIterable {
    case sideBySide = "左右"
    case stacked = "上下"
    case oneAndTwo = "左一右二"
    case oneAndThree = "左一右三"

    var tile: Tile {
        switch self {
        case .sideBySide:
            .split(Split(.horizontal, 0.6, .pane(.session), .pane(.files)))
        case .stacked:
            .split(Split(.vertical, 0.65, .pane(.session), .pane(.terminal)))
        case .oneAndTwo:
            .split(Split(.horizontal, 0.6, .pane(.session),
                         .split(Split(.vertical, 0.5, .pane(.files), .pane(.terminal)))))
        case .oneAndThree:
            .split(Split(.horizontal, 0.55, .pane(.session),
                         .split(Split(.vertical, 1.0 / 3, .pane(.files),
                                      .split(Split(.vertical, 0.5, .pane(.terminal), .pane(.preview)))))))
        }
    }
}

/// 松手后卡片放在哪：另一张卡片某条边的那一侧。
struct DropSpot: Equatable {
    let target: Pane
    let edge: Edge
}

/// 拖动卡片：指针离开这张卡片后，它脱离布局，变成跟着指针的圆；指针落在别的卡片上时，
/// 在离指针最近的那条边插进占位，按放下后的样子预览；松手放进占位，没有占位就回原位。
struct CardDrag {
    let pane: Pane
    /// 脱离后剩下的排布。只剩这一张卡片时脱离后什么都不剩，也是 nil，所以另记 detached。
    var detached = false
    var rest: Tile?
    var spot: DropSpot?
    /// 带占位的预览排布，spot 变了才重算。
    var preview: Tile?
}

@Observable
final class Workspace {
    private(set) var root = Arrangement.oneAndTwo.tile
    private(set) var drag: CardDrag?
    /// 指针在内容区里的位置，拖动时一直变，和 drag 分开，免得每动一下整个排布都重算。
    private(set) var pointer: CGPoint = .zero
    /// 内容区在窗口里的位置和大小，把窗口坐标换算到内容区。
    var area: CGRect = .zero

    /// 正在显示的排布。
    var shown: Tile? {
        guard let drag, drag.detached else { return root }
        return drag.preview ?? drag.rest
    }

    func arrange(_ arrangement: Arrangement) {
        root = arrangement.tile
    }

    /// point 是窗口坐标。
    func drag(_ pane: Pane, to point: CGPoint) {
        let location = CGPoint(x: point.x - area.minX, y: point.y - area.minY)
        let bounds = CGRect(origin: .zero, size: area.size)
        pointer = location
        var next = drag ?? CardDrag(pane: pane)
        if !next.detached {
            if drag == nil { drag = next }
            guard let frame = root.frames(in: bounds)[pane], !frame.contains(location) else { return }
            next.detached = true
            next.rest = root.removing(pane)
        }
        // 按脱离后、插占位之前的排布判断落点：预览一变卡片就挪位置，按预览判断会来回跳。
        // 指针在卡片之间的缝里时保持原来的落点，出了内容区才取消
        if let rest = next.rest, bounds.contains(location) {
            if let (target, frame) = rest.frames(in: bounds).first(where: { $0.value.contains(location) }) {
                let x = (location.x - frame.minX) / frame.width
                let y = (location.y - frame.minY) / frame.height
                let edges: [(Edge, CGFloat)] = [(.leading, x), (.trailing, 1 - x), (.top, y), (.bottom, 1 - y)]
                next.spot = DropSpot(target: target, edge: edges.min { $0.1 < $1.1 }!.0)
            }
        } else {
            next.spot = nil
        }
        guard next.detached != drag?.detached || next.spot != drag?.spot else { return }
        next.preview = next.spot.flatMap { spot in next.rest?.inserting(.placeholder, beside: spot.target, on: spot.edge) }
        withAnimation(.snappy) { drag = next }
    }

    func drop() {
        guard let drag else { return }
        withAnimation(.snappy) {
            if let spot = drag.spot, let rest = drag.rest {
                root = rest.inserting(.pane(drag.pane), beside: spot.target, on: spot.edge)
            }
            self.drag = nil
        }
    }
}
