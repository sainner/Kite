import SwiftUI

/// 内容区里的小窗口。Mac 上每个是一张卡片，iPhone 上用窗口顶部的页签切换。
enum Pane: CaseIterable {
    case session, files, terminal, preview
}

/// 卡片的排布：一块地方要么放一张卡片，要么沿一个方向切成两块，每块再照此细分。
/// 左右、上下、左一右二都是这样拼出来的。
enum Tile {
    case pane(Pane)
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

extension Tile {
    var panes: [Pane] {
        switch self {
        case .pane(let pane): [pane]
        case .split(let split): split.first.panes + split.second.panes
        }
    }

    /// 拿掉一张卡片，它所在的那一刀由另一半补上。
    func removing(_ pane: Pane) -> Tile? {
        switch self {
        case .pane(let p):
            return p == pane ? nil : self
        case .split(let split):
            guard let first = split.first.removing(pane) else { return split.second }
            guard let second = split.second.removing(pane) else { return first }
            return .split(Split(split.axis, split.ratio, first, second))
        }
    }

    /// 从 target 的 edge 那边切一刀，把 pane 放进去，两半各占一半。
    func inserting(_ pane: Pane, beside target: Pane, on edge: Edge) -> Tile {
        switch self {
        case .pane(let p) where p == target:
            let axis: Axis = edge == .leading || edge == .trailing ? .horizontal : .vertical
            let before = edge == .leading || edge == .top
            return .split(Split(axis, 0.5, before ? .pane(pane) : self, before ? self : .pane(pane)))
        case .pane:
            return self
        case .split(let split):
            return .split(Split(split.axis, split.ratio,
                                split.first.inserting(pane, beside: target, on: edge),
                                split.second.inserting(pane, beside: target, on: edge)))
        }
    }

    func swapping(_ a: Pane, _ b: Pane) -> Tile {
        switch self {
        case .pane(let p):
            return .pane(p == a ? b : p == b ? a : p)
        case .split(let split):
            return .split(Split(split.axis, split.ratio, split.first.swapping(a, b), split.second.swapping(a, b)))
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

/// 拖动卡片时松手会落到哪：另一张卡片的某条边旁边，或者和它互换位置。
enum DropSpot: Equatable {
    case beside(Pane, Edge)
    case swap(Pane)
}

@Observable
final class Workspace {
    /// 拖动时用的坐标系，整个内容区。
    static let space = "workspace"

    private(set) var root = Arrangement.oneAndTwo.tile
    /// 正在拖的卡片和指针位置。
    private(set) var dragging: (pane: Pane, location: CGPoint)?
    /// 各张卡片在内容区里的位置，判断指针落在哪张卡片上。
    var frames: [Pane: CGRect] = [:]

    func arrange(_ arrangement: Arrangement) {
        root = arrangement.tile
    }

    func drag(_ pane: Pane, to location: CGPoint) {
        dragging = (pane, location)
    }

    func drop() {
        if let pane = dragging?.pane, let spot = dropSpot {
            withAnimation(.snappy) { move(pane, to: spot) }
        }
        dragging = nil
    }

    /// 指针在另一张卡片上：中间一块是互换，其余按离哪条边最近，放到那条边旁边。
    var dropSpot: DropSpot? {
        guard let (dragged, point) = dragging else { return nil }
        guard let (target, frame) = root.panes.lazy.compactMap({ pane in self.frames[pane].map { (pane, $0) } })
            .first(where: { $0.1.contains(point) }), target != dragged else { return nil }
        let x = (point.x - frame.minX) / frame.width
        let y = (point.y - frame.minY) / frame.height
        if abs(x - 0.5) < 0.2 && abs(y - 0.5) < 0.2 { return .swap(target) }
        let edges: [(Edge, CGFloat)] = [(.leading, x), (.trailing, 1 - x), (.top, y), (.bottom, 1 - y)]
        return .beside(target, edges.min { $0.1 < $1.1 }!.0)
    }

    /// 松手后卡片会占的位置，拖动时高亮出来。
    var dropRect: CGRect? {
        switch dropSpot {
        case .swap(let target):
            return frames[target]
        case .beside(let target, let edge):
            guard let frame = frames[target] else { return nil }
            switch edge {
            case .leading: return CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
            case .trailing: return CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
            case .top: return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
            case .bottom: return CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
            }
        case nil:
            return nil
        }
    }

    private func move(_ pane: Pane, to spot: DropSpot) {
        switch spot {
        case .swap(let target):
            root = root.swapping(pane, target)
        case .beside(let target, let edge):
            if let rest = root.removing(pane) { root = rest.inserting(pane, beside: target, on: edge) }
        }
    }
}
