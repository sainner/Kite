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
            let firstMinimum = horizontal ? split.first.minimumSize.width : split.first.minimumSize.height
            let secondMinimum = horizontal ? split.second.minimumSize.width : split.second.minimumSize.height
            let requested = (available * split.ratio).rounded()
            let length = available >= firstMinimum + secondMinimum
                ? min(max(requested, firstMinimum), available - secondMinimum) : requested
            let (a, rest) = rect.divided(atDistance: length, from: edge)
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
        replacing(target, with: Tile.pane(target).inserting(tile, on: edge))
    }

    /// 在整个排布外面切一刀，原来的窗口一起放在另一侧。
    func inserting(_ tile: Tile, on edge: Edge, ratio: CGFloat = 0.5) -> Tile {
        let axis: Axis = edge == .leading || edge == .trailing ? .horizontal : .vertical
        let before = edge == .leading || edge == .top
        return .split(Split(axis, ratio, before ? tile : self, before ? self : tile))
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

    init(in bounds: CGRect) {
        canvas = CGRect(x: bounds.minX, y: bounds.minY,
                        width: max(0, bounds.width - Metrics.dockWidth - Metrics.gap), height: bounds.height)
        dock = CGRect(x: bounds.maxX - Metrics.dockWidth, y: bounds.minY,
                      width: Metrics.dockWidth, height: bounds.height)
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

/// 一个窗口组：有哪些窗口、Mac 上怎么排、聚焦的是哪个。Mac 把它们排成卡片，iPhone 一次显示聚焦的那个。
/// 拖动卡片的接口收内容区里的坐标和内容区的大小，换算由摆卡片的视图做。
@Observable
final class WindowLayout {
    private(set) var root: Tile?
    /// 缩小的窗口仍属于这个工作区，按停靠顺序保存。
    private(set) var docked: [Pane] = []
    /// 聚焦的窗口，iPhone 上显示的就是它；窗口组为空时没有焦点。
    private(set) var focused: Pane?
    private(set) var drag: CardDrag?
    /// 拖动时指针在内容区里的位置。一直在变，和 drag 分开，免得每动一下整个排布都重算。
    private(set) var pointer: CGPoint = .zero

    @ObservationIgnored private let storageKey: String?
    @ObservationIgnored private let defaults: UserDefaults
    /// 由当前窗口内容区提供；不随布局写入共享数据或持久化。
    @ObservationIgnored var availableSize: CGSize?

    init(panes: [Pane] = [], arrangement: Arrangement = .oneAndTwo,
         storageKey: String? = nil, defaults: UserDefaults = .standard) {
        self.storageKey = storageKey
        self.defaults = defaults
        if let storageKey, let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(SavedLayout.self, from: data) {
            root = saved.root?.tile
            docked = saved.docked
            focused = saved.focused
            reconcile(panes)
        } else {
            root = arrangement.tile(for: panes)
            docked = panes.filter { !(root?.panes.contains($0) ?? false) }
            focused = panes.first
            save()
        }
    }

    /// 服务端决定窗口是否存在。本机只保留这些 ID 的位置，新窗口默认收进停靠栏。
    func reconcile(_ available: [Pane]) {
        let allowed = Set(available)
        guard Set(panes) != allowed else { return }
        drag = nil
        let hadWindows = !panes.isEmpty
        for pane in panes where !allowed.contains(pane) { root = root?.removing(pane) }
        docked.removeAll { !allowed.contains($0) }
        let known = Set(panes)
        let added = available.filter { !known.contains($0) }
        if root == nil && docked.isEmpty, let first = added.first {
            root = .pane(first)
            docked = Array(added.dropFirst())
        } else {
            docked += added
        }
        if !hadWindows || focused.map({ !allowed.contains($0) }) != false { focusVisiblePane() }
        save()
    }

    /// 当前设备主动打开窗口时，让它出现在内容区；远端添加仅由 reconcile 收入停靠栏。
    func activate(_ pane: Pane, in bounds: CGRect? = nil) {
        guard panes.contains(pane) else { return }
        withAnimation(.snappy) {
            drag = nil
            if docked.contains(pane) {
                #if os(macOS)
                place(pane, in: bounds ?? availableSize.map { CGRect(origin: .zero, size: $0) })
                docked.removeAll { $0 == pane }
                #endif
            }
            focused = pane
        }
        save()
    }

    func focus(_ pane: Pane) {
        guard focused != pane, panes.contains(pane) else { return }
        focused = pane
        save()
    }

    private func save() {
        guard let storageKey else { return }
        let saved = SavedLayout(root: root.map(SavedTile.init), docked: docked, focused: focused)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: storageKey) }
    }

    var panes: [Pane] { (root?.panes ?? []) + docked }

    var minimumSize: CGSize {
        let content = root?.minimumSize ?? CGSize(width: Metrics.minPane, height: Metrics.minPane)
        let dockHeight = 2 * Metrics.padding + CGFloat(docked.count + 1) * (Metrics.dragBubble + Metrics.gap) - Metrics.gap
        return CGSize(width: content.width + Metrics.gap + Metrics.dockWidth,
                      height: max(content.height, dockHeight))
    }

    /// 正在显示的排布。
    var shown: Tile? {
        guard let drag else { return root }
        return drag.layout
    }

    var shownDock: [Pane] {
        drag?.docked ?? docked
    }

    func arrange(_ arrangement: Arrangement) {
        let tile = arrangement.tile(for: panes)
        let remaining = panes.filter { !(tile?.panes.contains($0) ?? false) }
        withAnimation(.snappy) {
            drag = nil
            root = tile
            docked = remaining
            focusVisiblePane()
        }
        save()
    }

    /// 收进停靠栏，保留窗口和内容。
    func minimize(_ pane: Pane) {
        guard root?.panes.contains(pane) == true else { return }
        withAnimation(.snappy) {
            drag = nil
            root = root?.removing(pane)
            docked.append(pane)
            focusVisiblePane()
        }
        save()
    }

    /// 当前窗口铺满内容区，其余窗口依次收进停靠栏。
    func expand(_ pane: Pane) {
        guard let root, root.panes.contains(pane) else { return }
        withAnimation(.snappy) {
            drag = nil
            docked += root.panes.filter { $0 != pane }
            self.root = .pane(pane)
            focused = pane
        }
        save()
    }

    /// 点击停靠窗口与新建窗口使用同一放置顺序和展开动画。
    func restore(_ pane: Pane, in bounds: CGRect) {
        guard drag == nil, docked.contains(pane) else { return }
        activate(pane, in: bounds)
    }

    private func place(_ pane: Pane, in bounds: CGRect?) {
        guard let root else { self.root = .pane(pane); return }
        let column = root.inserting(.pane(pane), on: .trailing)
        guard let bounds else { self.root = column; return }
        let canvas = WindowRegions(in: bounds).canvas
        let fits = { (tile: Tile) in tile.minimumSize.width <= canvas.width && tile.minimumSize.height <= canvas.height }
        if fits(column) { self.root = column; return }
        let targets = root.panes.sorted { $0 == focused && $1 != focused }
        for target in targets {
            let rows = root.inserting(.pane(pane), beside: target, on: .bottom)
            if fits(rows) { self.root = rows; return }
        }
        // 保留当前聚焦窗口；容量已满时，用一个非聚焦窗口的位置接住新窗口。
        if let victim = root.panes.first(where: { $0 != focused }) ?? root.panes.first {
            self.root = root.replacing(victim, with: .pane(pane))
            docked.append(victim)
        }
    }

    private func focusVisiblePane() {
        let visible = root?.panes ?? []
        if let focused, visible.contains(focused) { return }
        focused = visible.first ?? docked.first
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

    /// 分栏拖动只改内存，松手后保存最终比例。
    func finishResize() { save() }

    /// 手势层达到起拖距离后调用，布局层从第一次调用起就接管窗口排布。
    func drag(_ pane: Pane, to location: CGPoint, in bounds: CGRect) {
        guard panes.contains(pane), drag == nil || drag?.pane == pane else { return }
        pointer = location
        let regions = WindowRegions(in: bounds)
        var next = drag ?? CardDrag(pane: pane, rest: root?.removing(pane))
        // 按脱离后、插占位之前的排布判断落点：预览一变卡片就挪位置，按预览判断会来回跳。
        // 指针在卡片之间的缝里时保持原来的落点，出了内容区才取消
        let remainingDock = docked.filter { $0 != pane }
        if regions.dock.contains(location) {
            next.spot = .dock(regions.dockIndex(at: location, count: remainingDock.count))
        } else if regions.canvas.contains(location), let rest = next.rest {
            if let edge = regions.canvasEdge(at: location) {
                let minimum = rest.inserting(.placeholder, on: edge).minimumSize
                next.spot = minimum.width <= regions.canvas.width && minimum.height <= regions.canvas.height ? .edge(edge) : nil
            } else if let (target, frame) = rest.layout(in: regions.canvas).panes.first(where: { $0.value.contains(location) }) {
                // 离哪条边近放哪边；这张卡片在那个方向上不够切成两张的，那条边不算
                let x = (location.x - frame.minX) / frame.width
                let y = (location.y - frame.minY) / frame.height
                let wide = frame.width >= 2 * Metrics.minPane + Metrics.gap
                let tall = frame.height >= 2 * Metrics.minPane + Metrics.gap
                let edges: [(Edge, CGFloat)] = [(.leading, x), (.trailing, 1 - x), (.top, y), (.bottom, 1 - y)]
                    .filter { $0.0 == .leading || $0.0 == .trailing ? wide : tall }
                next.spot = edges.min { $0.1 < $1.1 }.map { .beside(target, $0.0) }
            } else if case .beside = next.spot {
                // 卡片之间的缝里保留上一个分割落点。
            } else {
                next.spot = nil
            }
        } else if regions.canvas.contains(location), next.rest == nil {
            next.spot = .canvas
        } else {
            next.spot = nil
        }
        guard drag == nil || next.spot != drag?.spot else { return }
        next.layout = next.placing(.placeholder, in: regions.canvas) ?? next.rest
        next.docked = remainingDock
        if case .dock(let index) = next.spot { next.docked.insert(pane, at: index) }
        withAnimation(.snappy) { drag = next }
    }

    func drop(in bounds: CGRect) {
        guard let next = drag else { return }
        // 一次提交树和停靠顺序；同一张 CardSlot 在圆和卡片之间直接动画，不留下延迟回调覆盖新拖动。
        withAnimation(.snappy) {
            switch next.spot {
            case .dock:
                root = next.rest
                docked = next.docked
            case .edge, .beside, .canvas:
                root = next.placing(.pane(next.pane), in: WindowRegions(in: bounds).canvas)
                docked.removeAll { $0 == next.pane }
                focused = next.pane
            case nil:
                break
            }
            drag = nil
            focusVisiblePane()
        }
        save()
    }
}

/// 本地文件只记录窗口 ID 和布局数值，不缓存窗口目标或业务对象。
private struct SavedLayout: Codable {
    let root: SavedTile?
    let docked: [Pane]
    let focused: Pane?
}

private indirect enum SavedTile: Codable {
    case pane(Pane)
    case split(horizontal: Bool, ratio: Double, first: SavedTile, second: SavedTile)

    init(_ tile: Tile) {
        switch tile {
        case .pane(let pane): self = .pane(pane)
        case .split(let split):
            self = .split(horizontal: split.axis == .horizontal, ratio: split.ratio,
                          first: SavedTile(split.first), second: SavedTile(split.second))
        case .placeholder: preconditionFailure("拖动预览不能持久化")
        }
    }

    var tile: Tile {
        switch self {
        case .pane(let pane): return .pane(pane)
        case .split(let horizontal, let ratio, let first, let second):
            return .split(Split(horizontal ? .horizontal : .vertical, min(max(ratio, 0.05), 0.95), first.tile, second.tile))
        }
    }
}
