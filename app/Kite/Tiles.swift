import SwiftUI

/// 窗口组里的一个窗口。Mac 上每个是一张卡片，iPhone 上一次显示一个，用页签切换。
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
        var id: ObjectIdentifier { ObjectIdentifier(split) }
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
            let first = split.firstLength(in: horizontal ? rect.width : rect.height)
            let rest = (horizontal ? rect.width : rect.height) - first - Metrics.gap
            let a = horizontal
                ? CGRect(x: rect.minX, y: rect.minY, width: first, height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: first)
            let gap = horizontal
                ? CGRect(x: a.maxX, y: rect.minY, width: Metrics.gap, height: rect.height)
                : CGRect(x: rect.minX, y: a.maxY, width: rect.width, height: Metrics.gap)
            let b = horizontal
                ? CGRect(x: gap.maxX, y: rect.minY, width: rest, height: rect.height)
                : CGRect(x: rect.minX, y: gap.maxY, width: rect.width, height: rest)
            result.gaps.append(TileLayout.Gap(split: split, rect: gap, region: rect))
            split.first.place(in: a, into: &result)
            split.second.place(in: b, into: &result)
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

    /// 把一张卡片换成 tile，位置不变。
    func replacing(_ pane: Pane, with tile: Tile) -> Tile {
        switch self {
        case .pane(let p):
            return p == pane ? tile : self
        case .placeholder:
            return self
        case .split(let split):
            return .split(Split(split.axis, split.ratio, split.first.replacing(pane, with: tile), split.second.replacing(pane, with: tile)))
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

/// 拖动卡片：指针离开这张卡片后，它脱离布局，在原处缩成一个圆跟着指针；指针落在别的卡片上时，
/// 在离指针最近的那条边插进占位，按放下后的样子预览；松手时圆展开进占位，没有占位就展开回原位。
struct CardDrag {
    enum Phase: Equatable {
        /// 指针还在这张卡片里，什么都不变。
        case attached
        /// 脱离布局，跟着指针。
        case floating
        /// 松手后正展开到这个位置，展开完才定下排布。
        case landing(CGRect)
    }

    let pane: Pane
    var phase = Phase.attached
    /// 脱离后剩下的排布；只剩这一张卡片时为 nil。
    var rest: Tile?
    var spot: DropSpot?
    /// 拖动中显示的排布：剩下的，或者插了占位的预览。
    var layout: Tile?
}

/// 一个窗口组：有哪些窗口、Mac 上怎么排、聚焦的是哪个。Mac 把它们排成卡片，iPhone 一次显示聚焦的那个。
/// 拖动卡片的接口收内容区里的坐标和内容区的大小，换算由摆卡片的视图做。
@Observable
final class Workspace {
    private(set) var root: Tile
    /// 聚焦的窗口，iPhone 上显示的就是它。
    var focused: Pane
    private(set) var drag: CardDrag?
    /// 拖动时指针在内容区里的位置。一直在变，和 drag 分开，免得每动一下整个排布都重算。
    private(set) var pointer: CGPoint = .zero

    init(_ arrangement: Arrangement = .oneAndTwo) {
        let tile = arrangement.tile
        root = tile
        focused = tile.panes[0]
    }

    /// 正在显示的排布。
    var shown: Tile? {
        guard let drag, drag.phase != .attached else { return root }
        return drag.layout
    }

    func arrange(_ arrangement: Arrangement) {
        withAnimation(.snappy) { root = arrangement.tile }
        if !root.panes.contains(focused) { focused = root.panes[0] }
    }

    /// 拖动 gap 这道缝。
    func resize(_ gap: TileLayout.Gap, to location: CGPoint) {
        let horizontal = gap.split.axis == .horizontal
        let available = (horizontal ? gap.region.width : gap.region.height) - Metrics.gap
        guard available > 0 else { return }
        let position = horizontal ? location.x - gap.region.minX : location.y - gap.region.minY
        let lower = min(Metrics.minPane / available, 0.5)
        gap.split.ratio = min(max((position - Metrics.gap / 2) / available, lower), 1 - lower)
    }

    func drag(_ pane: Pane, to location: CGPoint, in bounds: CGRect) {
        pointer = location
        var next = drag ?? CardDrag(pane: pane)
        switch next.phase {
        case .landing:
            return
        case .attached:
            if drag == nil { drag = next }
            guard let frame = root.layout(in: bounds).panes[pane], !frame.contains(location) else { return }
            next.phase = .floating
            next.rest = root.removing(pane)
        case .floating:
            break
        }
        // 按脱离后、插占位之前的排布判断落点：预览一变卡片就挪位置，按预览判断会来回跳。
        // 指针在卡片之间的缝里时保持原来的落点，出了内容区才取消
        if let rest = next.rest, bounds.contains(location) {
            if let (target, frame) = rest.layout(in: bounds).panes.first(where: { $0.value.contains(location) }) {
                let x = (location.x - frame.minX) / frame.width
                let y = (location.y - frame.minY) / frame.height
                let edges: [(Edge, CGFloat)] = [(.leading, x), (.trailing, 1 - x), (.top, y), (.bottom, 1 - y)]
                next.spot = DropSpot(target: target, edge: edges.min { $0.1 < $1.1 }!.0)
            }
        } else {
            next.spot = nil
        }
        guard drag?.phase == .attached || next.spot != drag?.spot else { return }
        next.layout = next.spot.flatMap { spot in next.rest?.inserting(.placeholder, beside: spot.target, on: spot.edge) } ?? next.rest
        withAnimation(.snappy) { drag = next }
    }

    func drop(in bounds: CGRect) {
        guard var next = drag else { return }
        guard next.phase == .floating else {
            if next.phase == .attached { drag = nil }
            return
        }
        // 有落点就放进去；没有就回原位，原位先换成占位，别的卡片先让回来
        let final = next.spot.flatMap { spot in next.rest?.inserting(.pane(next.pane), beside: spot.target, on: spot.edge) } ?? root
        if next.spot == nil { next.layout = root.replacing(next.pane, with: .placeholder) }
        next.phase = .landing(final.layout(in: bounds).panes[next.pane] ?? .zero)
        withAnimation(.snappy) {
            drag = next
        } completion: {
            // 展开后和占位一样大，定下排布时卡片不用再动
            self.root = final
            self.drag = nil
        }
    }
}
