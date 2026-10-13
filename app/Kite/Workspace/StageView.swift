#if os(macOS)
import AppKit
import SwiftUI

#if DEBUG
/// --swiftui-stage：Mac 宽屏台面也用 SwiftUI 版（SwiftUITilesLayer），同一个构建对照新旧两版。
enum StageVariant {
    static let swiftUI = ProcessInfo.processInfo.arguments.contains("--swiftui-stage")
}
#endif

/// Mac 宽屏的台面，原生版：各张卡片、卡片之间的缝、拖动时的占位都是 AppKit 视图（StageView、CardView），拖缝改宽时
/// 每步只重算排布、按新位置摆，不经过 SwiftUI。停靠栏、空台面的画板、停靠栏上面那一层（脉冲、展开的面板）
/// 不随拖缝改尺寸，仍是 SwiftUI，各放进一个铺满台面的托管视图（StageIsland）。窗口正文也还是每张卡片一个托管视图。
/// 行为照 SwiftUI 版（SwiftUITilesLayer、CardSlot、PaneCard、WindowSurface），排布的计算共用 StagePlan。
/// 原生层报不了偏好，有没有窗口开点阵、摆在点阵上的图形、停靠栏悬停标签由这里接着往上报（见 StageReports）。
struct StageHost: View {
    let group: PaneGroup
    @Environment(\.openSidebar) private var openSidebar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // 显式读出来交给原生层：只读 context.environment 时这几项变了不一定调 updateNSView，见 StageAppearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.displayScale) private var displayScale
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dotStage) private var dotStage
    @Environment(AppModel.self) private var model
    @State private var reports = StageReports()

    var body: some View {
        StageRepresentable(group: group, model: model, reports: reports, openSidebar: openSidebar,
                           appearance: StageAppearance(colorScheme: colorScheme, activeState: activeState, reduceMotion: reduceMotion,
                                                       displayScale: displayScale, isEnabled: isEnabled,
                                                       dotStage: dotStage.map(ObjectIdentifier.init)))
            .preference(key: WindowDotsActive.self, value: reports.usesDots)
            .preference(key: DotSlots.self, value: reports.dotSlots)
            .dockHoverSource(reports.hoverTip)
    }
}

/// 原生台面报给 SwiftUI 的几项，由 StageHost 发成偏好：有没有窗口开点阵（App 背景让出静息点）、摆在点阵上的图形（换栏目时收回）、
/// 停靠栏悬停浮出的标签。
@MainActor @Observable final class StageReports {
    var usesDots = false
    var dotSlots: Set<String> = []
    var hoverTip: DockHoverTip?
}

/// 会影响托管视图外观的几项环境：变了才给各个托管视图重新交环境（rootView），其余时候托管视图自己读模型更新。
struct StageAppearance: Equatable {
    var colorScheme: ColorScheme
    var activeState: ControlActiveState
    var reduceMotion: Bool
    var displayScale: CGFloat
    var isEnabled: Bool
    var dotStage: ObjectIdentifier?
}

private struct StageRepresentable: NSViewRepresentable {
    let group: PaneGroup
    let model: AppModel
    let reports: StageReports
    let openSidebar: (@MainActor () -> Void)?
    let appearance: StageAppearance

    func makeNSView(context: Context) -> StageView {
        StageView(group: group, model: model, reports: reports)
    }

    func updateNSView(_ stage: StageView, context: Context) {
        stage.update(environment: context.environment, appearance: appearance, openSidebar: openSidebar)
    }

    /// 铺满给的地方；不给的话 SwiftUI 按 Auto Layout 量 fittingSize，整个台面的视图树塞进临时约束引擎。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleNSView(_ stage: StageView, coordinator: ()) {
        stage.dismantle()
    }
}

/// 台面的大小，和关闭途中、停靠栏里那一格先不显示的实例。停靠栏、空画板的托管视图读它，自己从排布模型算停靠栏各格：
/// 排布的改动在 SwiftUI 的事务里，岛自己读模型才接得到同一个动画（见 StagePlan.dock）；原生层不把算好的格子推进去。
@MainActor @Observable final class StageGeometry {
    var bounds: CGRect = .zero
    var retiring: Set<String> = []
}

/// 台面本身：最底下停靠栏和空画板两个托管视图，上面依次是缝、拖动时的占位、各张卡片，最上面是停靠栏的脉冲和展开的面板。
/// 观察排布模型（ModelTracking），变了在 layout 里重算 StagePlan、摆缝和卡片；卡片在动时由显示链接逐帧取样。
/// 过渡中（WindowLayout.transitioning）整个窗口暂停光标区域，缝、卡片、停靠栏都不接点击和悬停；指针在台面上时系统窗口不可拖。
final class StageView: NSView {
    let group: PaneGroup
    let model: AppModel
    private let reports: StageReports
    let geometry = StageGeometry()
    private(set) var environment = EnvironmentValues()
    private(set) var look: StageAppearance?
    private var openSidebar: (@MainActor () -> Void)?

    private let dockRail = StageIsland()
    private let windowless = StageIsland()
    private let placeholder = PlaceholderView()
    private let dockOverlay = StageIsland()
    private var gaps: [ObjectIdentifier: GapView] = [:]
    private var cards: [Pane: CardView] = [:]
    /// 台面上和正在退出的窗口，按加入的先后；退出动画走完才拿掉。
    private var retained: [Pane] = []
    /// 窗口指向的实例，窗口没了以后还要知道它属于哪个实例（停靠栏里那一格先不显示）。
    private var paneInstances: [Pane: String] = [:]

    private let tracking = ModelTracking()
    /// 空画板报的点阵用量，台面合起来往上报。
    private lazy var windowlessReports = StageIslandReports(stage: self)
    private var displayLink: CADisplayLink?
    /// 报给排布模型的视口，变了才报。
    private var viewport: CGSize?
    /// 台面左上角在窗口里的位置（左上角起、往下为正，同 SwiftUI 的 .global）。拖动报的窗口坐标按它换回台面坐标。
    private(set) var origin = CGPoint.zero
    private var cursorsFrozen = false
    private var wasTransitioning = false
    /// 指针在台面上（悬停跟踪区里）。
    private var pointerInside = false
    private var visibleInstances: Set<String>?
    private var escapeMonitor: Any?
    private var focusMonitor: Any?
    /// 这次按下的位置（台面坐标），松手时挪得不多才算点了一下。
    private var pressedAt: CGPoint?
    /// 正在跟手的那张卡片，拖动开始时清掉各卡片的悬停。
    private var dragging: Pane?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(group: PaneGroup, model: AppModel, reports: StageReports) {
        self.group = group
        self.model = model
        self.reports = reports
        super.init(frame: .zero)
        wantsLayer = true
        for island in [dockRail, windowless] { addSubview(island) }
        addSubview(placeholder)
        addSubview(dockOverlay)
        // 停靠栏上面那一层压在拖动、关闭中置顶的卡片上面，见 CardView.raised
        dockOverlay.wantsLayer = true
        dockOverlay.layer?.zPosition = 2
        windowless.hitRegion = { [weak self] in self?.windowlessHitRegion }
        dockRail.hitRegion = { [weak self] in self?.dockHitRegion }
        dockOverlay.hitRegion = { [weak self] in self?.overlayHitRegion }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 环境

    func update(environment: EnvironmentValues, appearance: StageAppearance, openSidebar: (@MainActor () -> Void)?) {
        self.environment = environment
        let sidebarChanged = (openSidebar == nil) != (self.openSidebar == nil)
        self.openSidebar = openSidebar
        guard appearance != look || sidebarChanged else { return }
        let rebuilds = appearance != look
        look = appearance
        if rebuilds {
            installIslands()
            for card in cards.values { card.environmentChanged() }
        }
        needsLayout = true
    }

    /// 托管视图里的 SwiftUI 环境：台面外面给的整份，加上台面自己给的几项。
    func rooted(_ view: some View) -> AnyView {
        AnyView(view
            .environment(group.layout)
            .environment(\.self, environment))
    }

    private func installIslands() {
        let layout = group.layout, geometry = geometry
        dockRail.rootView = rooted(StageDockRail(layout: layout, area: group.workspace, geometry: geometry))
        windowless.rootView = rooted(StageWindowless(layout: layout, geometry: geometry, reports: windowlessReports))
        dockOverlay.rootView = rooted(StageDockOverlay(layout: layout, area: group.workspace, geometry: geometry))
    }

    func dismantle() {
        displayLink?.invalidate()
        displayLink = nil
        removeEscapeMonitor()
        removeFocusMonitor()
        tracking.begin()
        for card in cards.values {
            card.dismantle()
            group.layout.noteSettling(card.pane, false)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { installFocusMonitor() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeFocusMonitor()
            if cursorsFrozen { window?.enableCursorRects() }
            cursorsFrozen = false
            window?.isMovable = true
            group.workspace?.noteVisible([])
            visibleInstances = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: - 排版

    override func layout() {
        super.layout()
        // 环境交过来以前不建卡片：托管的正文要从环境里取 App 模型
        guard look != nil else { return }
        // 先作废上一轮的观察：下面报视口会改排布模型，自己的改动不回头再排一遍
        tracking.begin()
        let size = bounds.size
        if viewport != size {
            viewport = size
            group.layout.updateViewport(size, presentation: .tiled)
        }
        origin = windowOrigin
        for island in [dockRail, windowless, dockOverlay] { place(island, bounds) }
        place(placeholder, bounds)
        if geometry.bounds != bounds { geometry.bounds = bounds }
        laying = true
        defer { laying = false }
        let arranged = tracking.track({ arrange() }) { [weak self] in self?.invalidateArrangement() }
        settle(arranged)
    }

    /// 排版当中（settle 里动画停下、悬停变了）改了排布读过的模型：这一轮排完 AppKit 会清掉 needsLayout，所以下一拍再标一次。
    private var laying = false

    private func invalidateArrangement() {
        needsLayout = true
        guard laying else { return }
        DispatchQueue.main.async { [weak self] in self?.needsLayout = true }
    }

    /// 台面在窗口内容里的位置，左上角起。
    private var windowOrigin: CGPoint {
        guard let content = window?.contentView else { return .zero }
        let point = convert(CGPoint.zero, to: content)
        return content.isFlipped ? point : CGPoint(x: point.x, y: content.bounds.height - point.y)
    }

    /// 这一轮读到的、要在观察之外做的事：各张卡片这一轮的排布和交给 motion 的新终点、过渡状态。
    /// 托管视图的活（换 rootView、量尺寸）都放到观察之外：SwiftUI 当场求值时读的属性会记进这里的观察（嵌套的观察合并到外层），
    /// 窗口正文里随便一项变了台面都要重排。
    private struct Arranged {
        var cards: [(CardView, CardView.Arrangement, WindowMotionKind)] = []
        var transitioning = false
        var expanded = false
        var visible: Set<String> = []
        var hoverTip: DockHoverTip?
        var drag: Pane?
    }

    /// 各张卡片报的点阵用量，排布时读（变了再排一轮），见 reportDots。
    private var cardDots: (uses: Bool, slots: Set<String>) = (false, [])

    /// 读模型、算这一轮的排布并摆好；读到的属性变了会再来一轮。卡片的终点在这里算好，交给 motion 放到观察之外（见 settle）。
    private func arrange() -> Arranged {
        let layout = group.layout, area = group.workspace
        let plan = StagePlan(layout: layout, area: area, bounds: bounds)
        var arranged = Arranged()
        arranged.transitioning = layout.transitioning
        arranged.expanded = plan.expanded
        arranged.drag = layout.drag?.pane

        for pane in layout.panes where !retained.contains(pane) { retained.append(pane) }
        if let area {
            for window in area.windows where paneInstances[Pane(window.id)] != window.target.instanceId {
                paneInstances[Pane(window.id)] = window.target.instanceId
            }
        }
        let retiring = Set(retained.filter { !layout.panes.contains($0) }.compactMap { paneInstances[$0] })
        if geometry.retiring != retiring { geometry.retiring = retiring }

        arrangeGaps(plan.tiles.gaps, blocked: layout.isFixed ? nil : layout.blocksInput)
        placeholder.show(plan.tiles.placeholder, kind: layout.motionKind, reduceMotion: look?.reduceMotion ?? false)

        let reduceMotion = look?.reduceMotion ?? false
        let resizing = layout.resizing != nil
        let blocksInput = layout.blocksInput
        let dots = layout.resizingOrReleasing
        for pane in retained {
            let card = cards[pane] ?? makeCard(pane)
            let closing = !layout.panes.contains(pane)
            let rect = plan.tiles.panes[pane]
            let placed = card.presentation.place(group: group, pane: pane, rect: rect, dockFrame: plan.dockFrame(of: pane, area: area),
                                                 fallbackSize: plan.regions.canvas.size, regions: plan.regions, closing: closing)
            let dimmed = plan.expanded && rect == nil && layout.drag?.pane != pane
            let arrangement = CardView.Arrangement(
                placed: placed, dockFrame: plan.dockFrame(of: pane, area: area), closing: closing, family: plan.familyID(of: pane),
                openSidebar: pane == plan.first ? openSidebar : nil, dimmed: dimmed,
                acceptsInput: !blocksInput && !resizing && !closing && !dimmed, dotsHidden: dots,
                dragged: layout.drag?.pane == pane, hasThread: area?.thread(in: pane) != nil, fixed: layout.isFixed,
                header: card.headerState(layout: layout, minimized: placed.minimized, width: placed.target.frame.width,
                                         hasThread: area?.thread(in: pane) != nil))
            arranged.cards.append((card, arrangement, CardPresentation.motionKind(layout: layout, pane: pane, reduceMotion: reduceMotion)))
        }
        arranged.visible = Set(plan.onStage.compactMap { area?.dockInstanceID($0) })
        cardDots = (cards.values.contains { $0.bodyReports.usesDots }, cards.values.reduce(into: Set<String>()) {
            $0.formUnion($1.bodyReports.dotSlots)
            $0.formUnion($1.bodyReports.threadSlots)
        })
        arranged.hoverTip = hoverTip(plan: plan)
        return arranged
    }

    /// 拖动、拖缝时不浮标签；家族格里的父代理是窗口卡片报上来的，按窗口找。同 SwiftUI 版的 DockOverlay。
    private func hoverTip(plan: StagePlan) -> DockHoverTip? {
        let layout = group.layout
        guard layout.drag == nil, layout.resizing == nil, let area = group.workspace, let hover = area.dockHover,
              let geometry = plan.dock else { return nil }
        let entry: DockEntry
        if let found = DockModel(agents: geometry.allCells.map(\.entry)).entry(hover.id) {
            entry = found
        } else if hover.id.hasPrefix("pane:") {
            entry = .pane(Pane(String(hover.id.dropFirst("pane:".count))))
        } else {
            return nil
        }
        return DockHoverTip(text: area.dockLabel(entry), frame: hover.frame)
    }

    /// 观察之外：把终点交给各张卡片的 motion，再按这一轮的过渡状态冻结光标、报看得见的实例和悬停标签。
    private func settle(_ arranged: Arranged) {
        for (card, arrangement, kind) in arranged.cards {
            // 卡片铺满台面，里面各层按台面坐标摆
            place(card, bounds)
            card.arrange(arrangement)
            card.move(to: arrangement.placed.target, kind: kind)
        }
        if dragging != arranged.drag {
            dragging = arranged.drag
            // 起拖时收起各卡片的悬停（窗口按钮、停靠栏标签）
            if arranged.drag != nil { for card in cards.values { card.resetHover() } }
        }
        freezeCursors(arranged.transitioning)
        if !arranged.transitioning && wasTransitioning { refreshHover() }
        wasTransitioning = arranged.transitioning
        hoverTip = arranged.hoverTip
        if arranged.expanded { installEscapeMonitor() } else { removeEscapeMonitor() }
        if visibleInstances != arranged.visible, window != nil {
            visibleInstances = arranged.visible
            let area = group.workspace, visible = arranged.visible
            // 改模型放到这一轮排版之后，同 SwiftUI 的 onChange
            Task { @MainActor in area?.noteVisible(visible) }
        }
        reportDots()
        updateDisplayLink()
    }

    private func makeCard(_ pane: Pane) -> CardView {
        let card = CardView(pane: pane, stage: self)
        cards[pane] = card
        addSubview(card, positioned: .below, relativeTo: dockOverlay)
        return card
    }

    /// 退出动画走完：拿掉这张卡片。
    func retire(_ card: CardView) {
        guard cards[card.pane] === card, card.closing, !card.motionMoving else { return }
        retained.removeAll { $0 == card.pane }
        paneInstances[card.pane] = nil
        cards[card.pane] = nil
        card.dismantle()
        card.removeFromSuperview()
        group.layout.noteSettling(card.pane, false)
        needsLayout = true
    }

    // MARK: - 缝

    /// 缝按 Gap.id 复用：排布重建时正在拖的那道缝不换视图。固定排布（设备账号、资源库上下文）没有缝；
    /// 过渡中缝不接点击，正拖着的缝照常接。
    private func arrangeGaps(_ list: [TileLayout.Gap], blocked: Bool?) {
        let shown = blocked == nil ? [] : list
        var seen = Set<ObjectIdentifier>()
        for gap in shown {
            seen.insert(gap.id)
            let view = gaps[gap.id] ?? {
                let view = GapView(stage: self)
                gaps[gap.id] = view
                addSubview(view, positioned: .below, relativeTo: placeholder)
                return view
            }()
            view.gap = gap
            view.blocked = blocked ?? false
            place(view, gap.rect)
        }
        for (id, view) in gaps where !seen.contains(id) {
            view.removeFromSuperview()
            gaps[id] = nil
        }
    }

    /// 缝报的窗口位置换成台面坐标交给排布。
    func resize(_ gap: TileLayout.Gap, to location: CGPoint) {
        group.layout.resize(gap, to: local(location))
    }

    func finishResize() {
        group.layout.finishResize()
    }

    /// 窗口坐标（左上角起）换成台面坐标。
    func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    // MARK: - 卡片的拖动、点击

    func drag(_ pane: Pane, to point: CGPoint) {
        let layout = group.layout, area = group.workspace, bounds = bounds
        area?.collapseDock()
        area?.dockHover = nil
        let regions = layout.regions(in: bounds)
        let onStage = Set(layout.shown?.panes ?? [])
        layout.drag(pane, to: local(point), in: bounds) { remaining, location in
            StagePlan.dockIndex(of: pane, among: remaining, at: location, onStage: onStage, regions: regions, area: area)
        }
    }

    func drop() {
        group.layout.drop(in: bounds)
    }

    /// 点最小化的窗口：恢复；家族格里的父代理先展开家族，展开后再点父代理才放上台面。
    func activate(_ pane: Pane, family: String?) {
        if let family { group.workspace?.toggleDock(family, depth: 0) }
        else { group.layout.restore(pane, in: bounds) }
    }

    // MARK: - 逐帧

    /// 有卡片在动时开显示链接，逐帧取样；都停了就关。
    func updateDisplayLink() {
        let moving = cards.values.contains { $0.motionMoving }
        if moving, displayLink == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = !moving
    }

    @objc private func tick(_ link: CADisplayLink) {
        // 取样按这一帧要显示的时刻，同 TimelineView 给的帧时刻
        let date = Date(timeIntervalSinceNow: link.targetTimestamp - CACurrentMediaTime())
        var moving = false
        for card in cards.values where card.motionMoving {
            card.applyPresentation(at: date)
            moving = true
        }
        if !moving { link.isPaused = true }
    }

    // MARK: - 过渡中的光标、拖动系统窗口

    /// 过渡中整个窗口不换光标：暂停窗口的光标区域，停下后恢复并按指针当前位置重设。拖动中压栈的光标不受影响，同 freezesCursor。
    private func freezeCursors(_ frozen: Bool) {
        guard frozen != cursorsFrozen, let window else { return }
        cursorsFrozen = frozen
        if frozen {
            window.disableCursorRects()
        } else {
            window.enableCursorRects()
            window.resetCursorRects()
        }
    }

    /// 两块跟踪区：指针在台面上时系统窗口不可拖（没有标题栏的窗口顶部那一条由窗口服务器直接拖，普通视图挡不住，同 disablesWindowDragging）；
    /// 跟着指针算悬停在哪张卡片上（见 refreshHover），App 不在前台时也算，同 SwiftUI 的 onHover。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
                                       userInfo: ["movable": true]))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
        refreshHover()
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea?.userInfo?["movable"] != nil { window?.isMovable = false; return }
        pointerInside = true
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea?.userInfo?["movable"] != nil { window?.isMovable = true; return }
        pointerInside = false
        for card in cards.values { card.setHovered(false) }
    }

    override func mouseMoved(with event: NSEvent) {
        hover(at: convert(event.locationInWindow, from: nil))
    }

    /// 按指针现在的位置重算悬停：动画停下、过渡结束、跟踪区重建时调，不等指针再动（指针停着时卡片挪到它下面，AppKit 不发进入）。
    func refreshHover() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        pointerInside = bounds.contains(point)
        if pointerInside { hover(at: point) } else { for card in cards.values { card.setHovered(false) } }
    }

    /// 悬停在最上面那张接输入、停着的卡片上，同 SwiftUI 版正文和收成停靠形状时垫的那一层的 onHover。
    private func hover(at point: CGPoint) {
        let found = subviews.reversed().lazy.compactMap { $0 as? CardView }.first { $0.contains(point) }
        for card in cards.values where card !== found { card.setHovered(false) }
        found?.setHovered(true)
    }

    /// Esc 收起停靠栏展开的面板。
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, event.window === window, let area = group.workspace, !area.dockExpansion.isEmpty
            else { return event }
            area.collapseDock()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    /// 点窗口任何地方（正文、标题栏、输入区、对话里的字）都聚焦它，同 SwiftUI 版正文上的 paneFocus：按下松手挪得不多才算点了一下。
    /// 原生的会话窗口外框里点到的多是 AppKit 视图，SwiftUI 的点按手势收不到，所以在台面这一层看。
    private func installFocusMonitor() {
        guard focusMonitor == nil else { return }
        focusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.focusClick(event)
            return event
        }
    }

    private func removeFocusMonitor() {
        if let focusMonitor { NSEvent.removeMonitor(focusMonitor) }
        focusMonitor = nil
    }

    private func focusClick(_ event: NSEvent) {
        guard event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard event.type == .leftMouseUp else {
            pressedAt = point
            return
        }
        defer { pressedAt = nil }
        guard let pressedAt, hypot(point.x - pressedAt.x, point.y - pressedAt.y) < Metrics.dragThreshold,
              let card = subviews.reversed().lazy.compactMap({ $0 as? CardView }).first(where: { $0.showsContent(at: point) })
        else { return }
        group.layout.focus(card.pane)
    }

    // MARK: - 命中

    private var regions: WindowRegions { group.layout.regions(in: bounds) }

    /// 停靠栏只在停靠栏那一列接点击；过渡中不接，同 PausedInTransition。
    private var dockHitRegion: CGRect? {
        group.layout.transitioning || group.workspace == nil ? nil : regions.dock
    }

    /// 台面上没有窗口、也没在拖窗口时空画板接，同它在 SwiftUI 版里只在显示着时接。
    private var windowlessHitRegion: CGRect? {
        let layout = group.layout
        return (layout.shown?.panes.isEmpty ?? true) && layout.drag == nil && !layout.transitioning ? regions.canvas : nil
    }

    /// 停靠栏展开时铺满台面接点空白收起；收着时上面只有脉冲，不接。
    private var overlayHitRegion: CGRect? {
        guard let area = group.workspace, !area.dockExpansion.isEmpty, !group.layout.transitioning else { return nil }
        return bounds
    }

    // MARK: - 点阵

    private var hoverTip: DockHoverTip?
    private var reporting = false

    /// 各张卡片和空画板报的点阵用量、停靠栏悬停标签交给 StageHost。外面的 SwiftUI 正在排版（台面就排在它里面），隔一拍再改它读的值。
    func reportDots() {
        guard !reporting else { return }
        reporting = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reporting = false
            let uses = windowlessReports.usesDots || cardDots.uses
            let slots = windowlessReports.slots.union(cardDots.slots)
            if reports.usesDots != uses { reports.usesDots = uses }
            if reports.dotSlots != slots { reports.dotSlots = slots }
            if reports.hoverTip != hoverTip { reports.hoverTip = hoverTip }
        }
    }

    private func place(_ view: NSView, _ frame: CGRect) {
        if view.frame != frame { view.frame = frame }
    }
}

/// 台面里铺满台面的托管视图（停靠栏、空画板、停靠栏上面那一层）：坐标和台面一样，里面的 SwiftUI 按台面坐标摆。
/// 只在 hitRegion 里接点击，其余的点落到下面；读屏照常。
final class StageIsland: NSHostingView<AnyView> {
    var hitRegion: (() -> CGRect?)?

    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(rootView: AnyView(EmptyView()))
        sizingOptions = []
        safeAreaRegions = []
    }

    @MainActor required init(rootView: AnyView) { fatalError("init(rootView:) has not been implemented") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, let region = hitRegion?(), region.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

/// 两张卡片之间的缝：按住拖动改这一刀的比例，光标是左右或上下调整。过渡中不接点击（正拖着的照常接，AppKit 把拖动交给按下时的视图）。
private final class GapView: PressDragView {
    var gap: TileLayout.Gap?
    var blocked = false
    private weak var stage: StageView?
    private var dragging = false

    init(stage: StageView) {
        self.stage = stage
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private var cursor: NSCursor { gap?.split.axis == .vertical ? .rowResize : .columnResize }

    override func hitTest(_ point: NSPoint) -> NSView? {
        blocked ? nil : super.hitTest(point)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressedAt != nil, let gap else { return }
        dragging = true
        stage?.resize(gap, to: windowPoint(event.locationInWindow))
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { stage?.finishResize() }
        dragging = false
        super.mouseUp(with: event)
    }

    override func isAccessibilityElement() -> Bool { false }
}

/// 拖动卡片时预览它放下后的位置：圆角 cardRadius，主题色 8% 填充、2 点主题色描边，出现、移动、消失跟着预览的动画走。
private final class PlaceholderView: NSView {
    private let shape = CAShapeLayer()
    private var shown: CGRect?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shape.lineWidth = 2
        shape.opacity = 0
        layer?.addSublayer(shape)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            shape.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            shape.strokeColor = NSColor.controlAccentColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        shape.frame = bounds
    }

    /// 同 SwiftUI 版：占位在预览的事务里插值位置和大小，出现、消失是默认的淡入淡出，同曲线同时长。
    func show(_ rect: CGRect?, kind: WindowMotionKind, reduceMotion: Bool) {
        guard rect != shown else { return }
        let previous = shown
        shown = rect
        let duration = reduceMotion ? 0 : kind.duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let rect {
            // strokeBorder：描边画在里面，形状内缩半个线宽，圆角跟着小半个线宽
            let path = RoundedRectangle(cornerRadius: Metrics.cardRadius - 1).path(in: rect.insetBy(dx: 1, dy: 1)).cgPath
            let from = shape.presentation()?.path ?? shape.path
            shape.path = path
            if previous != nil, duration > 0, let from {
                shape.add(StageAnimation.basic("path", from: from, to: path, duration: duration), forKey: "path")
            }
        }
        let opacity: Float = rect == nil ? 0 : 1
        let fromOpacity = shape.presentation()?.opacity ?? shape.opacity
        shape.opacity = opacity
        if duration > 0, fromOpacity != opacity {
            shape.add(StageAnimation.basic("opacity", from: fromOpacity, to: opacity, duration: duration), forKey: "opacity")
        }
        CATransaction.commit()
    }
}

/// 台面上的图层动画：曲线与时长同 WindowMotionKind（cubic-bezier(0.2, 0, 0, 1)）；SwiftUI 的弹簧按同样的参数逐帧取样成关键帧。
enum StageAnimation {
    static let timing = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)

    static func spring(_ keyPath: String, from: Double, to: Double, spring: Spring) -> CAKeyframeAnimation {
        let duration = spring.settlingDuration
        let steps = max(Int(duration * 120), 1)
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = (0...steps).map { step in
            from + (to - from) * spring.value(target: 1.0, time: duration * Double(step) / Double(steps))
        }
        animation.duration = duration
        animation.calculationMode = .linear
        return animation
    }

    static func basic(_ keyPath: String, from: Any, to: Any, duration: TimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing
        return animation
    }
}

// MARK: - 托管的 SwiftUI

/// 停靠栏：自己从排布模型算停靠栏各格（不读拖缝的比例），排布改动的动画照常落在格子上。
private struct StageDockRail: View {
    let layout: WindowLayout
    let area: WorkArea?
    let geometry: StageGeometry

    var body: some View {
        if let area {
            let dock = StagePlan.dock(layout: layout, area: area, bounds: geometry.bounds).dock
            DockRail(geometry: dock, hiddenInstances: geometry.retiring)
                .environment(area)
                .modifier(PausedInTransition(layout: layout))
                .frame(width: geometry.bounds.width, height: geometry.bounds.height, alignment: .topLeading)
                .coordinateSpace(.named(DockSpace.name))
                .environment(\.dockCardsDrawPanes, true)
        }
    }
}

/// 停靠栏上面那一层：最小化窗口的脉冲、展开的面板。点了面板里父代理的窗口：在台面上就聚焦，否则放上台面。
private struct StageDockOverlay: View {
    let layout: WindowLayout
    let area: WorkArea?
    let geometry: StageGeometry

    var body: some View {
        if let area {
            let bounds = geometry.bounds
            let (regions, dock) = StagePlan.dock(layout: layout, area: area, bounds: bounds)
            DockOverlay(geometry: dock, bounds: bounds, regions: regions) { pane in
                if layout.shown?.panes.contains(pane) == true { layout.focus(pane) }
                else { layout.restore(pane, in: bounds) }
            }
            .environment(area)
            .modifier(PausedInTransition(layout: layout))
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .coordinateSpace(.named(DockSpace.name))
            .environment(\.dockCardsDrawPanes, true)
        }
    }
}

/// 空台面的画板：台面上没有窗口、也没在拖窗口时出现。它报的偏好传不出托管视图，交给台面合起来往上报。
private struct StageWindowless: View {
    let layout: WindowLayout
    let geometry: StageGeometry
    let reports: StageIslandReports

    var body: some View {
        let canvas = layout.regions(in: geometry.bounds).canvas
        SettledWindowlessStage(layout: layout, canvas: canvas, wanted: (layout.shown?.panes.isEmpty ?? true) && layout.drag == nil)
            .frame(width: geometry.bounds.width, height: geometry.bounds.height, alignment: .topLeading)
            // 隔一拍交出去：托管视图可能在台面这次排版当中更新
            .onPreferenceChange(WindowDotsActive.self) { uses in Task { @MainActor in reports.update(uses: uses) } }
            .onPreferenceChange(DotSlots.self) { slots in Task { @MainActor in reports.update(slots: slots) } }
    }
}

/// 托管视图报上来的点阵用量。
@MainActor final class StageIslandReports {
    private weak var stage: StageView?
    private(set) var usesDots = false
    private(set) var slots: Set<String> = []

    init(stage: StageView) { self.stage = stage }

    func update(uses: Bool? = nil, slots: Set<String>? = nil) {
        if let uses { usesDots = uses }
        if let slots { self.slots = slots }
        stage?.reportDots()
    }
}
#endif
