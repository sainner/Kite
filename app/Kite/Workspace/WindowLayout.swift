import SwiftUI

/// 一个窗口组：窗口集合、本机排布与焦点。宽屏排成卡片，紧凑布局只显示聚焦窗口。
/// 拖动卡片的接口收内容区里的坐标和内容区的大小，换算由摆卡片的视图做。
@Observable
final class WindowLayout {
    private(set) var motionKind = WindowMotionKind.immediate
    let isFixed: Bool
    private(set) var root: Tile? {
        // 只有台面上的窗口算固定：缩小、拖进停靠栏、关掉就不再固定
        didSet { if !pinned.isEmpty { pinned.formIntersection(root?.panes ?? []) } }
    }
    /// 缩小的窗口仍属于这个工作区，按停靠顺序保存。
    private(set) var docked: [Pane] = []
    /// 紧凑布局显示聚焦窗口；宽屏空间不足时优先保留它。
    private(set) var focused: Pane?
    /// 固定在台面上的窗口：展开、打开别的窗口时留在原处，别的窗口占它们以外的地方（见 occupying）；台面放不下时也最后才藏。
    private(set) var pinned: Set<Pane> = []
    /// 上一步：展开、打开、缩小之前的排布，见 LayoutMemory；还算不算数见 steps。
    private var memory: LayoutMemory?
    private(set) var drag: CardDrag?
    /// 指针所在、还没换上预览的落点，见 previewDwell。
    @ObservationIgnored private var pendingDrag: CardDrag?
    @ObservationIgnored private var pendingPreview: Task<Void, Never>?
    /// 等指针停下从这里起算，离开超过 previewSlop 重新计时。
    @ObservationIgnored private var dwellAnchor = CGPoint.zero
    /// 正在拖的那道缝，松手后清空。
    private(set) var resizing: Split?
    /// 起拖时的排布，这一次拖缝都从它算，见 resize。
    @ObservationIgnored private var resizeBase: TileBase?
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
    var transitioning: Bool { blocksInput || resizing != nil }

    /// 所有 App 窗口里有窗口组在过渡中，或者在拖侧栏改宽。主线程上能往后放的工作（如对话藏着量高，见 TranscriptWindow）看它让开，不卡进动画里。
    static var anyTransitioning: Bool { resizingLeadingEdge || all.allObjects.contains { $0.transitioning } }
    /// 所有 App 窗口里有窗口组在拖缝，或者在拖侧栏改宽：对话列表这时只量可见区附近的行，停下后补量（见 TranscriptListView、PhoneTranscriptView）。
    static var anyResizing: Bool { sidebarResizing || resizingLeadingEdge || all.allObjects.contains { $0.resizing != nil } }
    /// 在拖侧栏改宽：贴着侧栏的那一列每步改宽（见 shiftLeadingEdge），对话列表和拖缝时一样省着量。
    /// 侧栏改宽都经 updateViewport 认出来，最后一次改过后 leadingQuiet 秒内都算在拖（拖侧栏的边、侧栏收起展开的动画都是逐帧改）。
    static var resizingLeadingEdge: Bool { ProcessInfo.processInfo.systemUptime - leadingShiftedAt < leadingQuiet }
    private static var leadingShiftedAt: TimeInterval = -.infinity
    private static let leadingQuiet: TimeInterval = 0.2
    /// 正在拖侧栏的边，跟着 AppModel.sidebarResizing：iPad 原生台面拖侧栏时宽不经 SwiftUI（见 SidebarDrag），从按下起就算。
    static var sidebarResizing = false
    private static let all = NSHashTable<WindowLayout>.weakObjects()

    func noteSettling(_ pane: Pane, _ settling: Bool) {
        guard self.settling.contains(pane) != settling else { return }
        if settling { self.settling.insert(pane) } else { self.settling.remove(pane) }
    }

    @ObservationIgnored private let storageKey: String?
    @ObservationIgnored private let defaults: UserDefaults
    /// 由当前窗口内容区提供；不随布局写入共享数据或持久化。
    var availableSize: CGSize?
    /// 内容区左边在 App 窗口里的位置，见 updateViewport。
    @ObservationIgnored private var viewportLeading: CGFloat = 0
    @ObservationIgnored private var leadingShift: LeadingShift?
    private(set) var presentation: WorkspacePresentation = .tiled
    /// 紧凑布局里正在看的停靠窗口，回到宽屏后继续显示，但不改写原排布。
    private var carriedFocus: Pane?

    /// 窄屏只改变呈现，不把暂时放不下的卡片写成永久停靠。leading 是内容区左边在 App 窗口里的位置：
    /// 宽度的变化正好是左边挪的那一段，就是侧栏改了宽（拖动、收起、展开），由贴着侧栏的那一列吸收，见 shiftLeadingEdge；
    /// 其余的宽度变化（系统窗口改尺寸、换到另一个窗口里）各列照比例分。
    func updateViewport(_ size: CGSize, presentation: WorkspacePresentation, leading: CGFloat = 0) {
        let nextSize: CGSize? = presentation == .tiled ? size : nil
        if self.presentation != presentation || availableSize != nextSize {
            cancelDrag()
            if resizing != nil { finishResize() }
        }
        // 界面按像素摆，内容区的左边和宽各自取整，两者的变化差不到一点
        if self.presentation == .tiled, presentation == .tiled, let previous = availableSize, size.width != previous.width,
           leading != viewportLeading, abs(size.width - previous.width + leading - viewportLeading) < 1 {
            Self.leadingShiftedAt = ProcessInfo.processInfo.systemUptime
            shiftLeadingEdge(from: previous, to: size)
        }
        if self.presentation == .compact && presentation == .tiled {
            carriedFocus = focused.flatMap { docked.contains($0) ? $0 : nil }
        }
        motionKind = .immediate
        self.presentation = presentation
        availableSize = nextSize
        viewportLeading = leading
    }

    /// 一轮侧栏改宽：开始前的排布和台面宽度，上一次改完台面多宽、各刀的比例。
    private struct LeadingShift {
        let base: TileBase
        let width: CGFloat
        var target: CGFloat
        var ratios: [ObjectIdentifier: CGFloat] = [:]
    }

    /// 侧栏改宽，内容区从 previous 变成 size：宽度的变化由贴着侧栏的那一列吸收，其余列保持原来的宽度；
    /// 那一列到了最小宽度，再从左往右依次让出。一轮侧栏改宽都从第一次改之前的排布算，侧栏拖回去、收起再展开，
    /// 窗口原样回来，中途挤小的也回来。排布被别的改动改过（拖缝、放卡片、换排布），或台面宽度另有变化（系统窗口改尺寸），
    /// 就从当时的排布重新算起。
    private func shiftLeadingEdge(from previous: CGSize, to size: CGSize) {
        guard let tile = fittedRoot else { return }
        let canvas = regions(in: CGRect(origin: .zero, size: previous)).canvas
        let target = regions(in: CGRect(origin: .zero, size: size)).canvas.width
        var current = leadingShift.flatMap { $0.target == canvas.width && $0.ratios == tile.ratios ? $0 : nil }
            ?? LeadingShift(base: TileBase(tile.layout(in: canvas)), width: canvas.width, target: canvas.width)
        tile.absorb(along: .horizontal, from: current.width, to: target, atEnd: false, base: current.base)
        current.target = target
        current.ratios = tile.ratios
        leadingShift = current
        saveSoon()
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
            pinned = Set(saved.pinned ?? []).intersection(root?.panes ?? [])
            memory = saved.memory
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
        let removed = Set(panes).subtracting(allowed)
        // 展开、打开的那个窗口关掉了：回到那一步之前
        let occupant = steps.first { $0.kind != .minimize && removed.contains($0.pane) }
        for pane in removed { root = root?.removing(pane) }
        docked.removeAll { removed.contains($0) }
        memory = memory?.removing(removed)
        if let occupant { goBack(occupant.removing(removed)) }
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
            if docked.contains(pane), presentation == .tiled { open(pane, in: bounds) }
            focused = pane
        }
        saveSoon()
    }

    /// 停靠栏里的窗口放上台面，记下这一步，缩小或关掉它时回来（见 minimize、reconcile）。刚缩小的窗口直接回到缩小之前；
    /// 有固定的窗口时占掉它们以外的地方，没有时照常放（见 place）。
    private func open(_ pane: Pane, in bounds: CGRect?) {
        if let step = steps.first(where: { $0.kind == .minimize && $0.pane == pane }) {
            goBack(step)
            return
        }
        let bounds = bounds ?? availableSize.map { CGRect(origin: .zero, size: $0) }
        remember(.open, pane) {
            if !pinned.isEmpty, let root, let next = occupying(pane, in: root, canvas: bounds.map { regions(in: $0).canvas }) {
                let placed = Set(next.panes)
                docked = (docked + root.panes).filter { !placed.contains($0) }
                self.root = next
            } else {
                place(pane, in: bounds)
                docked.removeAll { $0 == pane }
            }
        }
    }

    /// pane 占掉台面上别的固定窗口以外的地方以后的排布：台面上的窗口占它所在的那一块，新放上来的占最大的一块；
    /// 不含固定窗口的地方不连成一块时（比如两个固定窗口斜对着），别的几块不动。没有这样一块时为 nil。
    private func occupying(_ pane: Pane, in root: Tile, canvas: CGRect?) -> Tile? {
        let blocks = root.blocks(without: pinned.subtracting([pane]))
        if let own = blocks.first(where: { $0.panes.contains(pane) }) { return root.replacing(block: own, with: .pane(pane)) }
        let frames = root.layout(in: canvas ?? CGRect(x: 0, y: 0, width: 1000, height: 1000)).panes
        func area(_ block: Tile) -> CGFloat {
            let frame = block.panes.compactMap { frames[$0] }.reduce(CGRect.null) { $0.union($1) }
            return frame.isNull ? 0 : frame.width * frame.height
        }
        return blocks.max { area($0) < area($1) }.map { root.replacing(block: $0, with: .pane(pane)) }
    }

    /// 还算数的几步，最近的在前：排布还是那一步刚做完时的样子（只比怎么切、各放哪个窗口，拖缝改过大小也算数），期间被别的操作改过就不算；
    /// 展开、打开的窗口还在台面上，缩小的还在停靠栏里。缩小底下可能压着同样算数的一步，见 LayoutMemory.beneath。
    private var steps: [LayoutMemory] {
        var steps: [LayoutMemory] = []
        var next = memory
        while let step = next, holds(step) {
            steps.append(step)
            next = step.beneath
        }
        return steps
    }

    private func holds(_ step: LayoutMemory) -> Bool {
        guard SavedTile.sameShape(step.after, root) else { return false }
        return step.kind == .minimize ? docked.contains(step.pane) : root?.panes.contains(step.pane) == true
    }

    /// 做 change 这一步，记下做之前的排布，回去时用（见 goBack）：回去以后接着用做之前还算数的那一步；做完以后还算数的那一步压在底下。
    private func remember(_ kind: LayoutMemory.Kind, _ pane: Pane, _ change: () -> Void) {
        let resumes = steps.first
        let before = root.map(SavedTile.init), dockedBefore = docked, pinnedBefore = pinned
        change()
        let depth = LayoutMemory.depth - 1
        memory = LayoutMemory(kind: kind, pane: pane, root: before, docked: dockedBefore, unpinned: Array(pinnedBefore.subtracting(pinned)),
                              after: root.map(SavedTile.init), resumes: resumes?.trimmed(depth), beneath: steps.first?.trimmed(depth))
    }

    /// 回到 step 之前的排布，接着用做它之前还算数的那一步。期间关掉的窗口不回来，期间新来的窗口留在停靠栏；leaving 是这时要收进停靠栏的窗口，
    /// 回去以后也不放上台面，排在停靠栏最后。
    private func goBack(_ step: LayoutMemory, leaving: Pane? = nil) {
        let current = panes
        var tile = step.root?.tile
        for pane in tile?.panes ?? [] where pane == leaving || !current.contains(pane) { tile = tile?.removing(pane) }
        let placed = Set(tile?.panes ?? [])
        var next = step.docked.filter { current.contains($0) && !placed.contains($0) && $0 != leaving }
        next += current.filter { !placed.contains($0) && !next.contains($0) && $0 != leaving }
        if let leaving { next.append(leaving) }
        root = tile
        docked = next
        pinned.formUnion(step.unpinned.filter(placed.contains))
        memory = step.resumes
    }

    func focus(_ pane: Pane) {
        guard focused != pane, panes.contains(pane) else { return }
        focused = pane
        if carriedFocus != pane { carriedFocus = nil }
        save()
    }

    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let storageKey else { return }
        let saved = SavedLayout(root: root.map(SavedTile.init), docked: docked, focused: focused,
                                pinned: root?.panes.filter(pinned.contains), memory: memory)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: storageKey) }
    }

    /// 侧栏拖动时比例每步都在变，停下一会儿再存；排布动画（缩小、恢复、展开、放下）开始的那一轮也不当场编码写盘，动画走完再存。
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    private func saveSoon() {
        guard storageKey != nil else { return }
        _ = Self.flushesOnLeave
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(0.5)) } catch { return }
            self?.save()
        }
    }

    /// 所有窗口组还挂着的存盘立刻落盘。推迟存盘的那 0.5 秒里退出，这次排布改动就丢了：App 失去活跃、进后台、要退出时都调；
    /// 别处要立刻读到存好的排布（测量版写回原样之前）也调这个。
    static func flushPendingSaves() {
        for layout in all.allObjects where layout.pendingSave != nil { layout.save() }
    }

    /// 头一次推迟存盘时挂上，之后一直在。不给队列，通知在发出的主线程上当场处理，退出前就落完盘。
    /// Mac 失去活跃先于退出；iOS 从多任务里划掉之前先失去活跃，不一定等到进后台。
    private static let flushesOnLeave: Void = {
        #if os(macOS)
        let names = [NSApplication.willResignActiveNotification, NSApplication.willTerminateNotification]
        #else
        let names = [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification]
        #endif
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated { flushPendingSaves() }
            }
        }
    }()

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
        let others = (tile?.panes ?? []).filter { $0 != focused }
        for pane in others.filter({ !pinned.contains($0) }) + others.filter(pinned.contains) {
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
        saveSoon()
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
        // 展开、打开它的那一步回去：让给它的窗口回到原处
        let occupant = steps.first { $0.kind != .minimize && $0.pane == pane }
        withLayoutAnimation(.settle) {
            drag = nil
            // 记下缩小之前的排布，从停靠栏点回它时原样回来（见 open）
            remember(.minimize, pane) {
                if let occupant {
                    goBack(occupant, leaving: pane)
                } else {
                    root = root?.removing(pane)
                    docked.append(pane)
                }
            }
            focusVisiblePane()
        }
        saveSoon()
    }

    /// 当前窗口占满内容区里别的固定窗口以外的地方，让出来的窗口依次收进停靠栏；记下这一步，还原、缩小或关掉它时回来。
    func expand(_ pane: Pane) {
        guard let next = expanded(pane) else { return }
        withLayoutAnimation(.settle) {
            drag = nil
            carriedFocus = nil
            remember(.expand, pane) {
                let placed = Set(next.panes)
                docked = (docked + (root?.panes ?? [])).filter { !placed.contains($0) }
                root = next
            }
            focused = pane
        }
        saveSoon()
    }

    /// 还原展开的窗口：回到展开之前的排布。
    func collapse(_ pane: Pane) {
        guard let step = expandedStep(pane) else { return }
        withLayoutAnimation(.settle) {
            drag = nil
            carriedFocus = nil
            goBack(step)
            focused = pane
            focusVisiblePane()
        }
        saveSoon()
    }

    /// 窗口按钮里展开那一格是展开、还原，还是没有（没有可让的窗口）。
    func expansion(of pane: Pane) -> PaneExpansion {
        if expandedStep(pane) != nil { return .restore }
        return expanded(pane) == nil ? .unavailable : .expand
    }

    private func expandedStep(_ pane: Pane) -> LayoutMemory? {
        steps.first { $0.kind == .expand && $0.pane == pane }
    }

    /// 展开 pane 以后的排布；没有窗口可让时为 nil。
    private func expanded(_ pane: Pane) -> Tile? {
        guard !isFixed, let shown, shown.panes.contains(pane), shown.panes.count > 1, let root else { return nil }
        let canvas = availableSize.map { regions(in: CGRect(origin: .zero, size: $0)).canvas }
        guard let next = occupying(pane, in: root, canvas: canvas), next.panes != root.panes else { return nil }
        return next
    }

    /// 固定或取消固定台面上的窗口，不改排布，也不算一步。
    func togglePin(_ pane: Pane) {
        guard !isFixed, root?.panes.contains(pane) == true else { return }
        if pinned.remove(pane) == nil { pinned.insert(pane) }
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
        // 保留当前聚焦窗口；容量已满时，用一个非聚焦窗口的位置接住新窗口，先换没固定的。
        if let victim = root.panes.first(where: { $0 != focused && !pinned.contains($0) })
            ?? root.panes.first(where: { $0 != focused }) ?? root.panes.first {
            self.root = root.replacing(victim, with: .pane(pane))
            docked.append(victim)
        }
    }

    private func focusVisiblePane() {
        let visible = root?.panes ?? []
        if let focused, visible.contains(focused) { return }
        focused = visible.first ?? docked.first
    }

    /// 拖动 gap 这道缝：只有紧挨着缝的窗口改尺寸，其余窗口保持起拖时的大小；紧挨着的小到最小尺寸后，
    /// 再由离缝近的往远处依次让出（见 Tile.absorb）。缝能拖到哪不变：两边都不小于各自的最小尺寸，里面再切过的也算上。
    /// 一次拖动都从起拖时的排布算，拖回去时中途挤小的窗口也原样回来。
    func resize(_ gap: TileLayout.Gap, to location: CGPoint) {
        guard !isFixed else { return }
        // 每动一下都会走到这里，值没变不写，免得读它们的视图每帧重算
        if motionKind != .immediate { motionKind = .immediate }
        let split = gap.split
        let horizontal = split.axis == .horizontal
        let available = gap.region.size.length(along: split.axis) - Metrics.gap
        let lower = split.first.minimumSize.length(along: split.axis)
        let upper = available - split.second.minimumSize.length(along: split.axis)
        guard available > 0, lower <= upper else { return }
        let position = (horizontal ? location.x - gap.region.minX : location.y - gap.region.minY) - Metrics.gap / 2
        let source = split.source ?? split
        if resizing !== source {
            resizing = source
            resizeBase = TileBase(Tile.split(split).layout(in: gap.region))
        }
        guard let resizeBase else { return }
        split.cut(at: Tile.halfPoint(min(max(position, lower), upper)), available: available, base: resizeBase)
    }

    /// 分栏拖动只改内存，松手后保存最终比例。
    func finishResize() {
        resizing = nil
        resizeBase = nil
        save()
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
        let previous = next.spot
        if regions.dock.contains(location) {
            next.spot = .dock(dockIndex?(remainingDock, location) ?? regions.dockIndex(at: location, count: remainingDock.count))
        } else if regions.canvas.contains(location), let rest = next.rest {
            if let edge = regions.canvasEdge(at: location) {
                // 剩下的排布这一次拖动里不变，同一条边腾出的窗口也不变
                if previous != .edge(edge) {
                    let displaced = Self.edgeRoom(for: edge, rest: rest, canvas: regions.canvas)
                    next.spot = displaced == nil ? nil : .edge(edge)
                    next.displaced = displaced ?? []
                }
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
        if case .edge = next.spot {} else { next.displaced = [] }
        next.layout = next.placing(.placeholder, in: regions.canvas) ?? next.rest
        next.docked = remainingDock + next.displaced
        if case .dock(let index) = next.spot { next.docked.insert(pane, at: index) }
        // 刚起拖时立刻缩成停靠形状、让出位置；不改窗口尺寸的落点（停靠栏里换位置）也立刻跟上
        guard let drag, resizesPanes(from: drag, to: next, in: regions.canvas) else {
            showPreview(next)
            return
        }
        pendingDrag = next
        schedulePreview(at: location)
    }

    /// 沿内容区的 edge 贴满放一张卡片时，其余窗口里要收进停靠栏的。先照原样挤：其余窗口照旧排、让出这一边（同 Mac）；
    /// 挤不下（触屏的窗口最小尺寸大，iPad 上两个并排的窗口再从左右边放一个就放不下）就收掉最少的几个，一样多时收离这条边远的，
    /// 像是被推出去；这个方向连两张卡片都放不下时为 nil，这条边不算落点。
    static func edgeRoom(for edge: Edge, rest: Tile, canvas: CGRect) -> [Pane]? {
        func fits(_ tile: Tile?) -> Bool {
            guard let minimum = tile?.inserting(.placeholder, on: edge).minimumSize else { return false }
            return minimum.width <= canvas.width && minimum.height <= canvas.height
        }
        if fits(rest) { return [] }
        let frames = rest.layout(in: canvas).panes
        func distance(_ pane: Pane) -> CGFloat {
            guard let frame = frames[pane] else { return 0 }
            switch edge {
            case .leading: return frame.minX - canvas.minX
            case .trailing: return canvas.maxX - frame.maxX
            case .top: return frame.minY - canvas.minY
            case .bottom: return canvas.maxY - frame.maxY
            }
        }
        let panes = rest.panes
        guard panes.count > 1 else { return nil }
        // 挑出 count 个的各种组合，按排布里的先后
        func combinations(_ count: Int, from start: Int = 0) -> [[Pane]] {
            guard count > 0 else { return [[]] }
            guard start < panes.count else { return [] }
            return (start..<panes.count).flatMap { index in combinations(count - 1, from: index + 1).map { [panes[index]] + $0 } }
        }
        for count in 1..<panes.count {
            var best: (panes: [Pane], distance: CGFloat)?
            for removed in combinations(count) where fits(removed.reduce(rest, { $0?.removing($1) })) {
                let total = removed.map(distance).reduce(0, +)
                // 一样远时收排布里靠后的（右边、下边的）
                if total >= best?.distance ?? -.infinity { best = (removed, total) }
            }
            if let best { return best.panes }
        }
        return nil
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

    /// 排布变化按 kind 的曲线和时长在动画里提交，逐帧取样读同一个 motionKind。
    private func withLayoutAnimation(_ kind: WindowMotionKind, _ body: () -> Void) {
        motionKind = kind
        withAnimation(kind.animation, body)
    }

    func drop(in bounds: CGRect) {
        guard !isFixed else { return }
        // 按指针所在的落点放，还没换上预览的也算
        guard let committed = drag else { return }
        let next = pendingDrag ?? committed
        clearPendingPreview()
        // 一次提交树和停靠顺序；同一张卡片在圆和卡片之间直接动画，不留下延迟回调覆盖新拖动。
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
        saveSoon()
    }
}


/// 窗口按钮里展开那一格，见 WindowLayout.expansion。
enum PaneExpansion: Equatable {
    case unavailable, expand, restore
}

/// 本地文件只记录窗口 ID 和布局数值，不缓存窗口目标或业务对象。
private struct SavedLayout: Codable {
    let root: SavedTile?
    let docked: [Pane]
    let focused: Pane?
    let pinned: [Pane]?
    let memory: LayoutMemory?
}

/// 展开、打开、缩小之前的排布，回到上一步时用，见 WindowLayout.steps。
private final class LayoutMemory: Codable {
    enum Kind: String, Codable {
        /// 展开：pane 占了别的窗口的地方，还原、缩小或关掉它时回去。
        case expand
        /// 打开：pane 从停靠栏或新建放上台面，缩小或关掉它时回去。
        case open
        /// 缩小：pane 收进停靠栏，从停靠栏点回它时回去。
        case minimize
    }

    /// 最多往回记这么多步。
    static let depth = 6

    let kind: Kind
    let pane: Pane
    /// 这一步之前的排布和停靠顺序。
    let root: SavedTile?
    let docked: [Pane]
    /// 这一步取消固定的窗口（缩小了固定的窗口），回去时再固定上。
    let unpinned: [Pane]
    /// 这一步刚做完时的排布，只看它怎么切、各放哪个窗口。
    let after: SavedTile?
    /// 回去以后接着用的一步：做这一步之前还算数的那一步。
    let resumes: LayoutMemory?
    /// 做完这一步以后同样算数、压在它底下的一步。缩小打开的窗口时回到打开之前，打开之前的那一步又算数了：
    /// 先后打开 X、Y，缩小 Y 回到有 X 的样子，点回 Y 用这一步，缩小 X 用底下打开 X 的那一步。
    let beneath: LayoutMemory?

    init(kind: Kind, pane: Pane, root: SavedTile?, docked: [Pane], unpinned: [Pane], after: SavedTile?,
         resumes: LayoutMemory?, beneath: LayoutMemory?) {
        self.kind = kind
        self.pane = pane
        self.root = root
        self.docked = docked
        self.unpinned = unpinned
        self.after = after
        self.resumes = resumes
        self.beneath = beneath
    }

    /// 只留往回 depth 步，0 时为 nil。
    func trimmed(_ depth: Int) -> LayoutMemory? {
        guard depth > 0 else { return nil }
        return LayoutMemory(kind: kind, pane: pane, root: root, docked: docked, unpinned: unpinned, after: after,
                            resumes: resumes?.trimmed(depth - 1), beneath: beneath?.trimmed(depth - 1))
    }

    /// 窗口关掉了：各步都拿掉它，排布里它所在的那一刀由另一半补上，同台面上一样。
    func removing(_ panes: Set<Pane>) -> LayoutMemory {
        guard !panes.isEmpty else { return self }
        func strip(_ tile: SavedTile?) -> SavedTile? { panes.reduce(tile?.tile) { $0?.removing($1) }.map(SavedTile.init) }
        return LayoutMemory(kind: kind, pane: pane, root: strip(root), docked: docked.filter { !panes.contains($0) },
                            unpinned: unpinned.filter { !panes.contains($0) }, after: strip(after),
                            resumes: resumes?.removing(panes), beneath: beneath?.removing(panes))
    }
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
            return .split(Split(horizontal ? .horizontal : .vertical, min(max(ratio, 0), 1), first.tile, second.tile))
        }
    }

    /// 切法和各处的窗口一样，不比比例。
    static func sameShape(_ saved: SavedTile?, _ tile: Tile?) -> Bool {
        switch (saved, tile) {
        case (nil, nil): true
        case (.pane(let a)?, .pane(let b)?): a == b
        case (.split(let horizontal, _, let first, let second)?, .split(let split)?):
            horizontal == (split.axis == .horizontal) && sameShape(first, split.first) && sameShape(second, split.second)
        default: false
        }
    }
}
