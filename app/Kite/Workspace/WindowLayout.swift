import SwiftUI

/// 一个窗口组：窗口集合、本机排布与焦点。宽屏排成卡片，紧凑布局只显示聚焦窗口。
/// 拖动卡片的接口收内容区里的坐标和内容区的大小，换算由摆卡片的视图做。
@Observable
final class WindowLayout {
    private(set) var motionKind = WindowMotionKind.immediate
    let isFixed: Bool
    private(set) var root: Tile?
    /// 缩小的窗口仍属于这个工作区，按停靠顺序保存。
    private(set) var docked: [Pane] = []
    /// 紧凑布局显示聚焦窗口；宽屏空间不足时优先保留它。
    private(set) var focused: Pane?
    private(set) var drag: CardDrag?
    /// 指针所在、还没换上预览的落点，见 previewDwell。
    @ObservationIgnored private var pendingDrag: CardDrag?
    @ObservationIgnored private var pendingPreview: Task<Void, Never>?
    /// 等指针停下从这里起算，离开超过 previewSlop 重新计时。
    @ObservationIgnored private var dwellAnchor = CGPoint.zero
    /// 正在拖的那道缝，跟手不吸附；松手后清空，排布吸附到模块。
    private(set) var resizing: Split?
    /// 刚松开缝、各窗口还没报上吸附动画（settling）的那一段也算过渡中：吸附动画由卡片在下一次更新里报上来，
    /// 中间这一两帧不算的话，点阵会先淡入、又随吸附收起、吸附完再淡入，闪一下（2026-10-13 用户报）。
    private var releasing = false
    @ObservationIgnored private var releaseEnd: Task<Void, Never>?

    /// 在拖缝，或者刚松开、吸附还没走完：窗口点阵这段时间一直收着，吸附完只淡入一次。
    var resizingOrReleasing: Bool { resizing != nil || releasing }
    /// 拖动时指针在内容区里的位置。一直在变，和 drag 分开，免得每动一下整个排布都重算。
    private(set) var pointer: CGPoint = .zero
    /// 正在走排布动画的窗口，由摆卡片的视图报上来，见 blocksInput。
    private(set) var settling: Set<Pane> = []

    /// 拖动或排布动画（缩小、恢复、让位、放下后归位）进行中。这段时间窗口没有可用的交互，所有窗口都不接点击和悬停：
    /// 窗口掠过指针、指针扫过窗口时，悬停每帧重算命中，还会带着标题栏重排（2026-10-11 Mac 三窗口实测，缩小、恢复掉到约 30 帧）。
    /// 拖动本身由按下时的视图继续接收，不受影响。
    var blocksInput: Bool { drag != nil || !settling.isEmpty }

    /// 过渡中：拖动、拖缝调整大小、排布动画。点阵不参与过渡，停下后再淡入；窗口、停靠栏和缝都不接点击和悬停，Mac 上也不换光标
    /// （2026-10-12 用户确定：过渡中这些都用不上）。正在进行的拖动照常由按下时的视图接。
    var transitioning: Bool { blocksInput || resizingOrReleasing }

    /// 所有 App 窗口里有窗口组在过渡中。主线程上能往后放的工作（如对话藏着量高，见 TranscriptWindow）看它让开，不卡进动画里。
    static var anyTransitioning: Bool { all.allObjects.contains { $0.transitioning } }
    /// 所有 App 窗口里有窗口组在拖缝或吸附：Mac 对话列表这时只量可见区附近的行，见 TranscriptListView。
    static var anyResizing: Bool { all.allObjects.contains { $0.resizingOrReleasing } }
    private static let all = NSHashTable<WindowLayout>.weakObjects()

    func noteSettling(_ pane: Pane, _ settling: Bool) {
        guard self.settling.contains(pane) != settling else { return }
        if settling { self.settling.insert(pane) } else { self.settling.remove(pane) }
    }

    @ObservationIgnored private let storageKey: String?
    @ObservationIgnored private let defaults: UserDefaults
    /// 由当前窗口内容区提供；不随布局写入共享数据或持久化。
    var availableSize: CGSize?
    private(set) var presentation: WorkspacePresentation = .tiled
    /// 紧凑布局里正在看的停靠窗口，回到宽屏后继续显示，但不改写原排布。
    private var carriedFocus: Pane?

    /// 窄屏只改变呈现，不把暂时放不下的卡片写成永久停靠。
    func updateViewport(_ size: CGSize, presentation: WorkspacePresentation) {
        let nextSize: CGSize? = presentation == .tiled ? size : nil
        if self.presentation != presentation || availableSize != nextSize {
            cancelDrag()
            if resizing != nil { finishResize() }
        }
        if self.presentation == .compact && presentation == .tiled {
            carriedFocus = focused.flatMap { docked.contains($0) ? $0 : nil }
        }
        motionKind = .immediate
        self.presentation = presentation
        availableSize = nextSize
    }

    func cancelDrag() {
        clearPendingPreview()
        motionKind = .settle
        drag = nil
    }

    init(panes: [Pane] = [], arrangement: Arrangement = .oneAndTwo,
         storageKey: String? = nil, defaults: UserDefaults = .standard, reconcileOnLoad: Bool = true) {
        self.isFixed = false
        self.storageKey = storageKey
        self.defaults = defaults
        if let storageKey, let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(SavedLayout.self, from: data) {
            root = saved.root?.tile
            docked = saved.docked
            focused = saved.focused
            // 托管目录尚未加载窗口；此时不能把未知窗口当成已删除。
            if reconcileOnLoad { reconcile(panes) }
        } else {
            root = arrangement.tile(for: panes)
            docked = panes.filter { !(root?.panes.contains($0) ?? false) }
            focused = panes.first
            save()
        }
        Self.all.add(self)
    }

    /// 设备工具页保留固定窗口集合与排布，共用工作区的焦点和模数布局。
    init(fixed root: Tile) {
        isFixed = true
        storageKey = nil
        defaults = .standard
        self.root = root
        focused = root.panes.first
        Self.all.add(self)
    }

    func regions(in bounds: CGRect) -> WindowRegions {
        WindowRegions(in: bounds, showsDock: !isFixed)
    }

    /// 服务端决定窗口是否存在。本机只保留这些 ID 的位置，新窗口默认收进停靠栏。
    func reconcile(_ available: [Pane]) {
        guard !isFixed else { return }
        motionKind = .settle
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
        if isFixed { focus(pane); return }
        withLayoutAnimation(.settle) {
            drag = nil
            carriedFocus = nil
            if docked.contains(pane) {
                if presentation == .tiled {
                    place(pane, in: bounds ?? availableSize.map { CGRect(origin: .zero, size: $0) })
                    docked.removeAll { $0 == pane }
                }
            }
            focused = pane
        }
        save()
    }

    func focus(_ pane: Pane) {
        guard focused != pane, panes.contains(pane) else { return }
        focused = pane
        if carriedFocus != pane { carriedFocus = nil }
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
        if isFixed { return content }
        let dockHeight = 2 * Metrics.padding + CGFloat(docked.count + 1) * (Metrics.dragBubble + Metrics.gap) - Metrics.gap
        return CGSize(width: content.width + Metrics.gap + Metrics.dockWidth,
                      height: max(content.height, dockHeight))
    }

    /// 正在显示的排布。
    var shown: Tile? {
        guard let drag else { return fittedRoot }
        return drag.layout
    }

    var shownDock: [Pane] {
        guard let drag else { return dockedPanes(outside: fittedRoot) }
        return drag.docked
    }

    private var fittedRoot: Tile? {
        if isFixed { return root }
        guard presentation == .tiled, let availableSize else { return root }
        let canvas = regions(in: CGRect(origin: .zero, size: availableSize)).canvas
        var tile = root
        if let carriedFocus, carriedFocus == focused, docked.contains(carriedFocus) {
            tile = tile?.inserting(.pane(carriedFocus), on: .trailing) ?? .pane(carriedFocus)
        }
        let candidates = (tile?.panes ?? []).filter { $0 != focused }
        for pane in candidates {
            guard let current = tile, current.panes.count > 1 else { break }
            let minimum = current.minimumSize
            if minimum.width <= canvas.width && minimum.height <= canvas.height { break }
            tile = current.removing(pane, preservingSource: true)
        }
        return tile
    }

    private func dockedPanes(outside tile: Tile?) -> [Pane] {
        let visible = Set(tile?.panes ?? [])
        return (docked + (root?.panes ?? [])).filter { !visible.contains($0) }
    }

    func arrange(_ arrangement: Arrangement) {
        guard !isFixed else { return }
        let tile = arrangement.tile(for: panes)
        let remaining = panes.filter { !(tile?.panes.contains($0) ?? false) }
        withLayoutAnimation(.settle) {
            drag = nil
            carriedFocus = nil
            root = tile
            docked = remaining
            focusVisiblePane()
        }
        save()
    }

    /// 收进停靠栏，保留窗口和内容。
    func minimize(_ pane: Pane) {
        guard !isFixed else { return }
        if carriedFocus == pane {
            carriedFocus = nil
            focusVisiblePane()
            save()
            return
        }
        guard root?.panes.contains(pane) == true else { return }
        withLayoutAnimation(.settle) {
            drag = nil
            root = root?.removing(pane)
            docked.append(pane)
            focusVisiblePane()
        }
        save()
    }

    /// 当前窗口铺满内容区，其余窗口依次收进停靠栏。
    func expand(_ pane: Pane) {
        guard !isFixed else { return }
        guard shown?.panes.contains(pane) == true else { return }
        withLayoutAnimation(.settle) {
            drag = nil
            carriedFocus = nil
            docked = docked.filter { $0 != pane } + (root?.panes ?? []).filter { $0 != pane }
            self.root = .pane(pane)
            focused = pane
        }
        save()
    }

    /// 点击停靠窗口与新建窗口使用同一放置顺序和展开动画。
    func restore(_ pane: Pane, in bounds: CGRect) {
        guard drag == nil, shownDock.contains(pane) else { return }
        activate(pane, in: bounds)
    }

    private func place(_ pane: Pane, in bounds: CGRect?) {
        guard let root else { self.root = .pane(pane); return }
        let column = root.inserting(.pane(pane), on: .trailing)
        guard let bounds else { self.root = column; return }
        let canvas = regions(in: bounds).canvas
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
        guard !isFixed else { return }
        // 每动一下都会走到这里，值没变不写，免得读它们的视图每帧重算
        if motionKind != .immediate { motionKind = .immediate }
        let split = gap.split
        let horizontal = split.axis == .horizontal
        let length = { (size: CGSize) in horizontal ? size.width : size.height }
        let available = length(gap.region.size) - Metrics.gap
        let lower = length(split.first.minimumSize)
        let upper = available - length(split.second.minimumSize)
        guard available > 0, lower <= upper else { return }
        let position = (horizontal ? location.x - gap.region.minX : location.y - gap.region.minY) - Metrics.gap / 2
        let source = split.source ?? split
        if resizing !== source { resizing = source }
        if releasing {
            releaseEnd?.cancel()
            releasing = false
        }
        split.ratio = min(max(position, lower), upper) / available
    }

    /// 分栏拖动只改内存，松手后吸附到模块并保存最终比例。
    func finishResize() {
        releasing = true
        withLayoutAnimation(.settle) { resizing = nil }
        save()
        // 吸附动画走完以后各窗口的 settling 已经接上；吸附位移为零、没有窗口动时，到点就算停下
        releaseEnd?.cancel()
        releaseEnd = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(WindowMotionKind.settle.duration)) } catch { return }
            self?.releasing = false
        }
    }

    /// 手势层达到起拖距离后调用，布局层从第一次调用起就接管窗口排布。
    /// dockIndex 按停靠栏的实际分组给出插入位置；不给时按格子顺序算。
    func drag(_ pane: Pane, to location: CGPoint, in bounds: CGRect, dockIndex: (([Pane], CGPoint) -> Int)? = nil) {
        guard !isFixed else { return }
        guard panes.contains(pane), drag == nil || drag?.pane == pane else { return }
        pointer = location
        if drag == nil { clearPendingPreview() }
        let regions = regions(in: bounds)
        let fitted = fittedRoot
        // 接着指针最近所在的落点判断，缝里保留的也是它
        var next = pendingDrag ?? drag ?? CardDrag(pane: pane, rest: fitted?.removing(pane))
        // 按脱离后、插占位之前的排布判断落点：预览一变卡片就挪位置，按预览判断会来回跳。
        // 指针在卡片之间的缝里时保持原来的落点，出了内容区才取消
        let remainingDock = dockedPanes(outside: fitted).filter { $0 != pane }
        if regions.dock.contains(location) {
            next.spot = .dock(dockIndex?(remainingDock, location) ?? regions.dockIndex(at: location, count: remainingDock.count))
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
        if let drag, next.spot == drag.spot {
            // 回到了正在预览的落点
            clearPendingPreview()
            return
        }
        if let pendingDrag, next.spot == pendingDrag.spot {
            if hypot(location.x - dwellAnchor.x, location.y - dwellAnchor.y) > Self.previewSlop { schedulePreview(at: location) }
            return
        }
        next.layout = next.placing(.placeholder, in: regions.canvas) ?? next.rest
        next.docked = remainingDock
        if case .dock(let index) = next.spot { next.docked.insert(pane, at: index) }
        // 刚起拖时立刻缩成停靠形状、让出位置；不改窗口尺寸的落点（停靠栏里换位置）也立刻跟上
        guard let drag, resizesPanes(from: drag, to: next, in: regions.canvas) else {
            showPreview(next)
            return
        }
        pendingDrag = next
        schedulePreview(at: location)
    }

    /// 拖动中换落点，等指针停下这么久再换预览。换一次预览，尺寸变了的窗口要按新尺寸重排正文，
    /// 一次几十毫秒（2026-10-11 Mac 实测 32～82ms）；指针还在动时，跟手的头像会跟着卡一下，扫过几个落点就卡几下。
    /// 停下再换，这一下落在头像不动的时候。
    private static let previewDwell = Duration.milliseconds(120)
    /// 指针动了不到这么多（点）算停着，触控板上手指停住也会有细小的移动。
    private static let previewSlop: CGFloat = 3

    private func schedulePreview(at location: CGPoint) {
        dwellAnchor = location
        pendingPreview?.cancel()
        pendingPreview = Task { [weak self] in
            do { try await Task.sleep(for: Self.previewDwell) } catch { return }
            guard let self, let next = pendingDrag, drag?.pane == next.pane else { return }
            showPreview(next)
        }
    }

    private func showPreview(_ next: CardDrag) {
        clearPendingPreview()
        withLayoutAnimation(.preview) { drag = next }
    }

    private func clearPendingPreview() {
        pendingDrag = nil
        pendingPreview?.cancel()
        pendingPreview = nil
    }

    /// 换成 next 的预览，台面上有没有窗口要改尺寸。
    private func resizesPanes(from current: CardDrag, to next: CardDrag, in canvas: CGRect) -> Bool {
        func sizes(_ drag: CardDrag) -> [Pane: CGSize] { drag.layout?.layout(in: canvas).panes.mapValues(\.size) ?? [:] }
        return sizes(current) != sizes(next)
    }

    /// 排布变化按 kind 的曲线和时长在动画里提交，逐帧取样读同一个 motionKind；事务上标明，见 Transaction.windowLayoutChange。
    private func withLayoutAnimation(_ kind: WindowMotionKind, _ body: () -> Void) {
        motionKind = kind
        var transaction = Transaction(animation: kind.animation)
        transaction.windowLayoutChange = true
        withTransaction(transaction, body)
    }

    func drop(in bounds: CGRect) {
        guard !isFixed else { return }
        // 按指针所在的落点放，还没换上预览的也算
        guard let committed = drag else { return }
        let next = pendingDrag ?? committed
        clearPendingPreview()
        // 一次提交树和停靠顺序；同一张 CardSlot 在圆和卡片之间直接动画，不留下延迟回调覆盖新拖动。
        withLayoutAnimation(.settle) {
            switch next.spot {
            case .dock:
                carriedFocus = nil
                root = next.rest
                docked = next.docked
            case .edge, .beside, .canvas:
                carriedFocus = nil
                root = next.placing(.pane(next.pane), in: regions(in: bounds).canvas)
                docked = next.docked.filter { $0 != next.pane && !(root?.panes.contains($0) ?? false) }
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
