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
            let (a, rest) = rect.divided(atDistance: (available * split.ratio).rounded(), from: edge)
            let (gap, b) = rest.divided(atDistance: Metrics.gap, from: edge)
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
            return rebuilt(split, first, second)
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
        let axis: Axis = edge == .leading || edge == .trailing ? .horizontal : .vertical
        let before = edge == .leading || edge == .top
        return replacing(target, with: .split(Split(axis, 0.5, before ? tile : .pane(target), before ? .pane(target) : tile)))
    }

    /// 两边都没变就沿用原来的这一刀：它的缝的视图不用重建，比例也还是同一份。
    private func rebuilt(_ split: Split, _ first: Tile, _ second: Tile) -> Tile {
        first.isSame(split.first) && second.isSame(split.second) ? self : .split(Split(split.axis, split.ratio, first, second))
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

    /// 把 tile 放到落点上的排布；没有落点时为 nil。
    func placing(_ tile: Tile) -> Tile? {
        guard let spot, let rest else { return nil }
        return rest.inserting(tile, beside: spot.target, on: spot.edge)
    }
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

    init(_ arrangement: Arrangement) {
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

    /// 拖动 gap 这道缝。两边都不小于各自的最小尺寸，里面再切过的也算上。
    func resize(_ gap: TileLayout.Gap, to location: CGPoint) {
        let split = gap.split
        let horizontal = split.axis == .horizontal
        let length = { (size: CGSize) in horizontal ? size.width : size.height }
        let available = length(gap.region.size) - Metrics.gap
        let lower = length(split.first.minimumSize)
        let upper = available - length(split.second.minimumSize)
        guard available > 0, lower <= upper else { return }
        let position = (horizontal ? location.x - gap.region.minX : location.y - gap.region.minY) - Metrics.gap / 2
        split.ratio = min(max(position, lower), upper) / available
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
                // 离哪条边近放哪边；这张卡片在那个方向上不够切成两张的，那条边不算
                let x = (location.x - frame.minX) / frame.width
                let y = (location.y - frame.minY) / frame.height
                let wide = frame.width >= 2 * Metrics.minPane + Metrics.gap
                let tall = frame.height >= 2 * Metrics.minPane + Metrics.gap
                let edges: [(Edge, CGFloat)] = [(.leading, x), (.trailing, 1 - x), (.top, y), (.bottom, 1 - y)]
                    .filter { $0.0 == .leading || $0.0 == .trailing ? wide : tall }
                next.spot = edges.min { $0.1 < $1.1 }.map { DropSpot(target: target, edge: $0.0) }
            }
        } else {
            next.spot = nil
        }
        guard drag?.phase == .attached || next.spot != drag?.spot else { return }
        next.layout = next.placing(.placeholder) ?? next.rest
        withAnimation(.snappy) { drag = next }
    }

    func drop(in bounds: CGRect) {
        guard var next = drag else { return }
        guard next.phase == .floating else {
            if next.phase == .attached { drag = nil }
            return
        }
        // 有落点就放进去；没有就回原位，原位先换成占位，别的卡片先让回来
        let final = next.placing(.pane(next.pane)) ?? root
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
