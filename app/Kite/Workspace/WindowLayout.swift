import SwiftUI

/// 一个窗口组：本机知道的全部窗口（工作区里是全部未归档的实例，按停靠栏的顺序）、台面集合与排布（root）和焦点，都只在本机。
/// 宽屏排成卡片，紧凑布局只显示聚焦窗口。台面只记一步：展开前的排布（见 expansion），没有固定、没有停靠顺序。
/// 拖动卡片的接口收内容区里的坐标和内容区的大小，换算由摆卡片的视图做。
@Observable
final class WindowLayout {
    private(set) var motionKind = WindowMotionKind.immediate
    let isFixed: Bool
    /// 台面：哪些窗口放在台面上、怎么切；不在里面的窗口收在停靠栏里（offStage）。
    private(set) var root: Tile?
    /// 本机知道的全部窗口，按停靠栏的顺序（由 reconcile 给）；台面垫底的窗口不在这里，见 floor。
    private var stored: [Pane] = []
    /// 紧凑布局显示聚焦窗口；宽屏空间不足时优先保留它。
    private(set) var focused: Pane?
    /// 台面上一个窗口都没有（紧凑布局是一个窗口都没有）时垫底的窗口，由 WorkArea 给（新建实例的选择页）：
    /// 不在 stored 里，缩不小、拖不动，别的窗口放上台面它就退下；选了插件时同一个 ID 变成实例的窗口，卡片不换。
    var floor: Pane?
    /// 台面唯一记住的上一步：展开前的排布，见 expand、collapse；展开的那张还独占着台面才算数（见 holdsExpansion）。
    private var expansion: ExpansionMemory?
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
    /// 拖侧栏的边每步都经 updateViewport 认出来，最后一次改过后 leadingQuiet 秒内都算在拖。侧栏收起、展开不算：台面一下子换到终点，
    /// 窗口飞过去，正文只按终点排一次（见 updateViewport 的 animated）。
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
    /// animated 是侧栏收起、展开：台面一下子换到终点，窗口照排布动画飞过去；别的视口变化都是跟手的，当场摆到位。
    func updateViewport(_ size: CGSize, presentation: WorkspacePresentation, leading: CGFloat = 0, animated: Bool = false) {
        let nextSize: CGSize? = presentation == .tiled ? size : nil
        if self.presentation != presentation || availableSize != nextSize {
            cancelDrag()
            if resizing != nil { finishResize() }
        }
        // 界面按像素摆，内容区的左边和宽各自取整，两者的变化差不到一点
        if self.presentation == .tiled, presentation == .tiled, let previous = availableSize, size.width != previous.width,
           leading != viewportLeading, abs(size.width - previous.width + leading - viewportLeading) < 1 {
            if !animated { Self.leadingShiftedAt = ProcessInfo.processInfo.systemUptime }
            shiftLeadingEdge(from: previous, to: size)
        }
        if self.presentation == .compact && presentation == .tiled {
            carriedFocus = focused.flatMap { stored.contains($0) && root?.panes.contains($0) != true ? $0 : nil }
        }
        motionKind = animated ? .settle : .immediate
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
         storageKey: String? = nil, defaults: UserDefaults = .standard) {
        self.isFixed = false
        self.storageKey = storageKey
        self.defaults = defaults
        stored = panes
        if let storageKey, let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(SavedLayout.self, from: data) {
            root = saved.root?.tile
            focused = saved.focused
            expansion = saved.expansion
        } else {
            root = arrangement.tile(for: panes)
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

    /// 工作机决定实例是否存在（工作区在 WorkArea 里按停靠栏的顺序给出全部窗口）。本机只保留这些 ID 的台面集合与排布，新窗口只收进停靠栏，
    /// 由本机的动作放上台面。展开的那张没了先按还原处理。
    /// complete 是工作机给的完整清单：这时存档里排着、却不在清单里的窗口（上次退出时的草稿和新建页、已经没了的实例）也从台面拿掉，
    /// 不然占着一块空白、没有卡片（2026-10-26 实测）。还没连上工作机、或插件定义还没读到时不算完整（见 WorkArea.rebuild），只拿掉上次知道、这次没了的。
    func reconcile(_ available: [Pane], complete: Bool = true) {
        guard !isFixed else { return }
        motionKind = .settle
        let removed = Set(stored).union(complete ? root?.panes ?? [] : []).subtracting(available)
        guard stored != available || !removed.isEmpty else { return }
        if !removed.isEmpty {
            drag = nil
            if let expansion, removed.contains(expansion.pane), holdsExpansion { goBack() }
            for pane in removed { root = root?.removing(pane) }
        }
        stored = available
        if focused.map({ !panes.contains($0) }) != false { focusVisiblePane() }
        save()
    }

    /// 当前设备主动打开窗口时，让它出现在内容区；远端添加仅由 reconcile 收入停靠栏。展开中打开别的窗口先还原（2026-10-25 用户定）。
    func activate(_ pane: Pane, in bounds: CGRect? = nil) {
        guard panes.contains(pane) else { return }
        if isFixed { focus(pane); return }
        withLayoutAnimation(.settle) {
            drag = nil
            carriedFocus = nil
            if stored.contains(pane), root?.panes.contains(pane) != true, presentation == .tiled {
                if holdsExpansion, expansion?.pane != pane { goBack() }
                // 还原后它可能已经在排布里（展开前就在台面上）
                if root?.panes.contains(pane) != true { place(pane, in: bounds ?? availableSize.map { CGRect(origin: .zero, size: $0) }) }
            }
            focused = pane
        }
        saveSoon()
    }

    /// 回到展开之前的排布：期间关掉的窗口不回来。
    private func goBack() {
        guard let expansion else { return }
        root = keepingStored(expansion.before?.tile)
        self.expansion = nil
    }

    /// tile 里只留本机知道的窗口，拿掉的那一张所在的一刀由另一半补上。
    private func keepingStored(_ tile: Tile?) -> Tile? {
        (tile?.panes ?? []).reduce(tile) { next, pane in stored.contains(pane) ? next : next?.removing(pane) }
    }

    /// 展开那一步还算数：展开的那张还独占着台面。拖进别的窗口、换排布都让它作废，「还原」随之变回「展开」。
    private var holdsExpansion: Bool {
        guard let expansion, case .pane(let pane)? = root else { return false }
        return pane == expansion.pane
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
        let saved = SavedLayout(root: root.map(SavedTile.init), focused: focused, expansion: holdsExpansion ? expansion : nil)
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

    /// 垫底的窗口此刻顶上来了：台面上一个窗口都没有（紧凑布局是一个窗口都没有）。
    private var floorShown: Bool {
        // 同一个 ID 已经是正式的窗口（新建页原地变成了实例）时不再垫底
        guard let floor, !isFixed, !stored.contains(floor) else { return false }
        return presentation == .compact ? stored.isEmpty : root?.panes.isEmpty ?? true
    }

    /// 全部窗口，按停靠栏的顺序；垫底的窗口顶上来时排在最后。
    var panes: [Pane] { floorShown ? stored + [floor!] : stored }

    /// 不在台面上的窗口，按停靠栏的顺序。
    var offStage: [Pane] {
        let visible = Set(shown?.panes ?? [])
        return stored.filter { !visible.contains($0) }
    }

    /// 停靠栏放不下时堆叠，不撑高窗口，只占右边一列。
    var minimumSize: CGSize {
        let content = root?.minimumSize ?? CGSize(width: Metrics.minPane, height: Metrics.minPane)
        if isFixed { return content }
        return CGSize(width: content.width + Metrics.gap + Metrics.dockWidth, height: content.height)
    }

    /// 正在显示的排布。
    var shown: Tile? {
        guard let drag else { return fittedRoot }
        return drag.layout
    }

    /// 台面上摆的：root，台面空着时是垫底的窗口。
    private var displayedRoot: Tile? {
        root ?? (floorShown ? floor.map(Tile.pane) : nil)
    }

    private var fittedRoot: Tile? {
        if isFixed { return root }
        guard presentation == .tiled, let availableSize else { return displayedRoot }
        let canvas = regions(in: CGRect(origin: .zero, size: availableSize)).canvas
        var tile = displayedRoot
        if let carriedFocus, carriedFocus == focused, stored.contains(carriedFocus), root?.panes.contains(carriedFocus) != true {
            tile = root?.inserting(.pane(carriedFocus), on: .trailing) ?? .pane(carriedFocus)
        }
        for pane in (tile?.panes ?? []).filter({ $0 != focused }) {
            guard let current = tile, current.panes.count > 1 else { break }
            let minimum = current.minimumSize
            if minimum.width <= canvas.width && minimum.height <= canvas.height { break }
            tile = current.removing(pane, preservingSource: true)
        }
        return tile
    }

    func arrange(_ arrangement: Arrangement) {
        guard !isFixed else { return }
        withLayoutAnimation(.settle) {
            drag = nil
            carriedFocus = nil
            expansion = nil
            root = arrangement.tile(for: stored)
            focusVisiblePane()
        }
        saveSoon()
    }

    /// 整个台面换成这组排布（打开布局）：不在 panes 里的拿掉，焦点落在左上角那张；展开那一步作废。
    func present(_ tile: Tile) {
        guard !isFixed else { return }
        guard let next = keepingStored(tile) else { return }
        withLayoutAnimation(.settle) {
            drag = nil
            carriedFocus = nil
            expansion = nil
            root = next
            focused = next.panes.first
        }
        saveSoon()
    }

    /// 缩小：本机把它从台面拿掉，对实例什么都不做。缩小展开的那张先还原（2026-10-25 用户定）。
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
            if holdsExpansion, expansion?.pane == pane { goBack() }
            root = root?.removing(pane)
            focusVisiblePane()
        }
        saveSoon()
    }

    /// 当前窗口占满台面，别的暂时离开；记下展开前的排布，还原、缩小或关掉它时回去。
    func expand(_ pane: Pane) {
        guard let next = expanded(pane) else { return }
        withLayoutAnimation(.settle) {
            drag = nil
            carriedFocus = nil
            expansion = ExpansionMemory(pane: pane, before: root.map(SavedTile.init))
            root = next
            focused = pane
        }
        saveSoon()
    }

    /// 还原展开的窗口：回到展开之前的排布。
    func collapse(_ pane: Pane) {
        guard holdsExpansion, expansion?.pane == pane else { return }
        withLayoutAnimation(.settle) {
            drag = nil
            carriedFocus = nil
            goBack()
            focused = pane
            focusVisiblePane()
        }
        saveSoon()
    }

    /// 窗口按钮里展开那一格是展开、还原，还是没有（没有可让的窗口）。
    func expansion(of pane: Pane) -> PaneExpansion {
        if holdsExpansion, expansion?.pane == pane { return .restore }
        return expanded(pane) == nil ? .unavailable : .expand
    }

    /// 展开 pane 以后的排布；没有窗口可让时为 nil。
    private func expanded(_ pane: Pane) -> Tile? {
        guard !isFixed, let shown, shown.panes.contains(pane), shown.panes.count > 1, root != nil, stored.contains(pane) else { return nil }
        return .pane(pane)
    }

    /// 停靠栏里点一格：实例在本机台面上就聚焦，不在就放上台面（见 StagePlan.show）；新建窗口也走同一放置顺序和展开动画。
    func restore(_ pane: Pane, in bounds: CGRect) {
        guard drag == nil, shown?.panes.contains(pane) != true else { return }
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
        // 保留当前聚焦窗口；容量已满时，用一个非聚焦窗口的位置接住新窗口，让出的那个回停靠栏。
        if let victim = root.panes.first(where: { $0 != focused }) ?? root.panes.first {
            self.root = root.replacing(victim, with: .pane(pane))
        }
    }

    /// 焦点落在台面上的窗口；台面空着时落在垫底的窗口，紧凑布局落在第一个窗口。
    private func focusVisiblePane() {
        let visible = root?.panes ?? []
        if let focused, visible.contains(focused) { return }
        focused = visible.first ?? (floorShown ? floor : panes.first)
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

    /// 手势层达到起拖距离后调用，布局层从第一次调用起就接管窗口排布。拖进停靠栏就是缩小，落回它自己那一格。
    func drag(_ pane: Pane, to location: CGPoint, in bounds: CGRect) {
        guard !isFixed else { return }
        guard stored.contains(pane), drag == nil || drag?.pane == pane else { return }
        pointer = location
        if drag == nil { clearPendingPreview() }
        let regions = regions(in: bounds)
        let fitted = fittedRoot
        // 接着指针最近所在的落点判断，缝里保留的也是它
        var next = pendingDrag ?? drag ?? CardDrag(pane: pane, rest: fitted?.removing(pane))
        // 按脱离后、插占位之前的排布判断落点：预览一变卡片就挪位置，按预览判断会来回跳。
        // 指针在卡片之间的缝里时保持原来的落点，出了内容区才取消
        let previous = next.spot
        if regions.dock.contains(location) {
            next.spot = .dock
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
        // 一次提交树；同一张卡片在圆和卡片之间直接动画，不留下延迟回调覆盖新拖动。
        withLayoutAnimation(.settle) {
            switch next.spot {
            case .dock:
                carriedFocus = nil
                root = next.rest
            case .edge, .beside, .canvas:
                carriedFocus = nil
                root = next.placing(.pane(next.pane), in: regions(in: bounds).canvas)
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

/// 本地文件只记录窗口 ID 和布局数值，不缓存实例或业务对象。
private struct SavedLayout: Codable {
    let root: SavedTile?
    let focused: Pane?
    let expansion: ExpansionMemory?
}

/// 展开前的排布，还原时回去，见 WindowLayout.expand。
private struct ExpansionMemory: Codable {
    let pane: Pane
    /// 期间关掉的窗口还在里面，还原时才拿掉（见 goBack）。
    let before: SavedTile?
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
}
