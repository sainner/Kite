#if os(iOS)
import SwiftUI
import UIKit

/// iPad 宽屏的台面：各张卡片、卡片之间的缝、拖动时的占位都是 UIKit 视图（PhoneStageView、PhoneCardView），拖缝改宽时
/// 每步只重算排布、按新位置摆，不经过 SwiftUI。停靠栏、空画板、停靠栏上面那一层（脉冲、展开的面板）不随拖缝改尺寸，仍是 SwiftUI，
/// 各放进一个铺满台面的岛（HostIsland）。行为和结构照 Mac 的台面（StageView），排布的计算共用 StagePlan。原生层报不了偏好，有没有窗口开点阵、摆在点阵上的图形、停靠栏悬停标签由这里接着往上报。
struct PhoneStageHost: View {
    let group: PaneGroup
    @Environment(\.openSidebar) private var openSidebar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // 显式读出来交给原生层：只读 context.environment 时这几项变了不一定调 updateUIView，见 StageAppearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dotStage) private var dotStage
    @Environment(AppModel.self) private var model
    @State private var reports = StageReports()

    var body: some View {
        PhoneStageRepresentable(group: group, model: model, reports: reports, openSidebar: openSidebar,
                                appearance: StageAppearance(colorScheme: colorScheme, typeSize: typeSize, reduceMotion: reduceMotion,
                                                            displayScale: displayScale, isEnabled: isEnabled,
                                                            dotStage: dotStage.map(ObjectIdentifier.init)))
            .preference(key: WindowDotsActive.self, value: reports.usesDots)
            .preference(key: DotSlots.self, value: reports.dotSlots)
            .dockHoverSource(reports.hoverTip)
    }
}

private struct PhoneStageRepresentable: UIViewRepresentable {
    let group: PaneGroup
    let model: AppModel
    let reports: StageReports
    let openSidebar: (@MainActor () -> Void)?
    let appearance: StageAppearance

    func makeUIView(context: Context) -> PhoneStageView {
        PhoneStageView(group: group, model: model, reports: reports)
    }

    func updateUIView(_ stage: PhoneStageView, context: Context) {
        stage.update(group: group, environment: context.environment, appearance: appearance, openSidebar: openSidebar)
    }

    /// 铺满给的地方；不给的话 SwiftUI 按 Auto Layout 量。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PhoneStageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleUIView(_ stage: PhoneStageView, coordinator: ()) {
        stage.dismantle()
    }
}

/// 台面本身：最底下停靠栏和空画板两个岛，上面依次是缝、拖动时的占位、各张卡片，最上面是停靠栏的脉冲和展开的面板。
/// 观察排布模型（ModelTracking），变了在 layoutSubviews 里重算 StagePlan、摆缝和卡片；排布动画由各张卡片整段交给 Core Animation，
/// 只有跟手拖动的那张由显示链接逐帧取样。过渡中（WindowLayout.transitioning）缝、卡片、停靠栏都不接点按。
final class PhoneStageView: UIView, StageDotsReporting {
    /// 资源库里同一类换一项（角色、模板）时台面不重建（.id 只按类别），这里换成新的一项，正文跟着换，见 update。
    private(set) var group: PaneGroup
    let model: AppModel
    private let reports: StageReports
    let geometry = StageGeometry()
    /// 空画板的台面大小：拖侧栏时停靠栏定住不排（geometry 定住），空画板照常跟着台面排。
    private let windowlessGeometry = StageGeometry()
    private(set) var environment = EnvironmentValues()
    private(set) var look: StageAppearance?
    private var openSidebar: (@MainActor () -> Void)?

    private let dockRail = HostIsland()
    private let windowless = HostIsland()
    private let placeholder = StagePlaceholderView()
    private let dockOverlay = HostIsland()
    private var gaps: [ObjectIdentifier: StageGapView] = [:]
    private var cards: [Pane: PhoneCardView] = [:]
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
    /// 台面左上角在窗口里的位置（同 SwiftUI 的 .global）。拖动报的窗口坐标按它换回台面坐标。
    private(set) var origin = CGPoint.zero
    private var wasTransitioning = false
    private var visibleInstances: Set<String>?
    /// 正在跟手的那张卡片，拖动开始时清掉各卡片的悬停。
    private var dragging: Pane?
    /// iPad 指针在台面上的位置（悬停）。
    private var pointer: CGPoint?

    init(group: PaneGroup, model: AppModel, reports: StageReports) {
        self.group = group
        self.model = model
        self.reports = reports
        super.init(frame: .zero)
        for island in [dockRail, windowless] { addSubview(island) }
        addSubview(placeholder)
        addSubview(dockOverlay)
        // 停靠栏上面那一层压在拖动、关闭中置顶的卡片上面，见 PhoneCardView.raised
        dockOverlay.layer.zPosition = 2
        windowless.hitRegion = { [weak self] in self?.windowlessHitRegion }
        dockRail.hitRegion = { [weak self] in self?.dockHitRegion }
        dockOverlay.hitRegion = { [weak self] in self?.overlayHitRegion }
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)
        NotificationCenter.default.addObserver(self, selector: #selector(sidebarDragged), name: SidebarDrag.changed, object: model.sidebarDrag)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 环境

    func update(group: PaneGroup, environment: EnvironmentValues, appearance: StageAppearance, openSidebar: (@MainActor () -> Void)?) {
        self.environment = environment
        let groupChanged = GroupKey(group) != GroupKey(self.group)
        self.group = group
        let sidebarChanged = (openSidebar == nil) != (self.openSidebar == nil)
        self.openSidebar = openSidebar
        guard appearance != look || sidebarChanged || groupChanged else { return }
        let rebuilds = appearance != look || groupChanged
        look = appearance
        if rebuilds {
            installIslands()
            placeholder.environment = environment
            for card in cards.values { card.environmentChanged() }
        }
        setNeedsLayout()
    }

    /// 窗口组是哪一个：工作区、设备账号，或资源库里选中的哪一项（同一类共用一套排布）。
    private struct GroupKey: Equatable {
        let layout: ObjectIdentifier
        let workspace: ObjectIdentifier?
        let item: AgentContextItem?

        init(_ group: PaneGroup) {
            layout = ObjectIdentifier(group.layout)
            workspace = group.workspace.map(ObjectIdentifier.init)
            if case .agentContext(let item, _) = group { self.item = item } else { item = nil }
        }
    }

    /// 岛里的 SwiftUI 环境：台面外面给的整份，加上台面自己给的几项。
    func rooted(_ view: some View) -> AnyView {
        AnyView(view
            .environment(group.layout)
            .environment(\.self, environment))
    }

    private func installIslands() {
        let layout = group.layout, geometry = geometry
        dockRail.rootView = rooted(StageDockRail(layout: layout, area: group.workspace, geometry: geometry))
        windowless.rootView = rooted(StageWindowless(layout: layout, geometry: windowlessGeometry, reports: windowlessReports))
        dockOverlay.rootView = rooted(StageDockOverlay(layout: layout, area: group.workspace, geometry: geometry))
    }

    /// 台面拆掉（换工作区、离开这一栏）：停掉显示链接，不再跟模型，卡片、缝和岛里的东西都清掉。
    func dismantle() {
        displayLink?.invalidate()
        displayLink = nil
        tracking.cancel()
        for card in cards.values {
            card.dismantle()
            card.removeFromSuperview()
            group.layout.noteSettling(card.pane, false)
        }
        cards = [:]
        retained = []
        for gap in gaps.values { gap.removeFromSuperview() }
        gaps = [:]
        for island in [dockRail, windowless, dockOverlay] {
            island.hitRegion = nil
            island.rootView = AnyView(EmptyView())
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            group.workspace?.noteVisible([])
            visibleInstances = nil
        }
        super.willMove(toWindow: newWindow)
    }

    // MARK: - 排版

    override func layoutSubviews() {
        super.layoutSubviews()
        // 环境交过来以前不建卡片：托管的正文要从环境里取 App 模型
        guard look != nil else { return }
        origin = window.map { convert(CGPoint.zero, to: $0) } ?? .zero
        laying = true
        defer { laying = false }
        let sidebarResizing = tracking.track({ model.sidebarResizing }) { [weak self] in self?.invalidateArrangement() }
        // 拖侧栏改宽时 SwiftUI 按开始拖时的宽摆着台面，台面自己把左边挪到侧栏实时的右边，见 SidebarDrag
        let shift = model.sidebarDrag.offset
        stageRect = CGRect(x: shift, y: 0, width: max(bounds.width - shift, 0), height: bounds.height)
        let size = stageRect.size
        if viewport != size {
            viewport = size
            // 报视口会改排布模型，自己的改动不回头再排一遍。台面左边在哪交给排布：侧栏改宽时只由最左一列吸收
            tracking.quietly { group.layout.updateViewport(size, presentation: .tiled, leading: origin.x + shift) }
        }
        for island in [dockRail, windowless, dockOverlay] { place(island, bounds) }
        place(placeholder, bounds)
        // 停靠栏贴着台面右边，侧栏改宽时不动，按整个台面排；空画板拖侧栏时不跟着挪（没有窗口时才露出来），松手再排
        if geometry.bounds != bounds { geometry.bounds = bounds }
        if windowlessGeometry.bounds != bounds { windowlessGeometry.bounds = bounds }
        let arranged = tracking.track({ arrange(dotsHidden: sidebarResizing) }) { [weak self] in self?.invalidateArrangement() }
        settle(arranged)
    }

    /// 台面上排窗口的那一块（台面坐标）：平时是整个台面，拖侧栏改宽时左边挪到侧栏实时的右边。
    private(set) var stageRect = CGRect.zero

    @objc private func sidebarDragged() { setNeedsLayout() }

    /// 排版当中改了排布读过的模型：这一轮排完 UIKit 会清掉待排，所以下一拍再标一次。
    private var laying = false

    private func invalidateArrangement() {
        setNeedsLayout()
        guard laying else { return }
        DispatchQueue.main.async { [weak self] in self?.setNeedsLayout() }
    }

    /// 这一轮读到的、要在观察之外做的事：各张卡片这一轮的排布和交给 motion 的新终点、过渡状态。
    /// 岛的活（换 rootView、量尺寸）都放到观察之外：SwiftUI 当场求值时读的属性会记进这里的观察。
    private struct Arranged {
        var cards: [(PhoneCardView, PhoneCardView.Arrangement, WindowMotionKind)] = []
        var transitioning = false
        var visible: Set<String> = []
        var hoverTip: DockHoverTip?
        var drag: Pane?
    }

    /// 各张卡片报的点阵用量，排布时读（变了再排一轮），见 reportDots。
    private var cardDots: (uses: Bool, slots: Set<String>) = (false, [])

    /// 读模型、算这一轮的排布；读到的属性变了会再来一轮。卡片的终点在这里算好，交给 motion 放到观察之外（见 settle）。
    private func arrange(dotsHidden: Bool) -> Arranged {
        let layout = group.layout, area = group.workspace
        let plan = StagePlan(layout: layout, area: area, bounds: stageRect)
        var arranged = Arranged()
        arranged.transitioning = layout.transitioning
        arranged.drag = layout.drag?.pane

        for pane in layout.panes where !retained.contains(pane) { retained.append(pane) }
        if let area {
            for window in area.windows where paneInstances[Pane(window.id)] != window.target.instanceId {
                paneInstances[Pane(window.id)] = window.target.instanceId
            }
        }
        let retiring = Set(retained.filter { !layout.panes.contains($0) }.compactMap { paneInstances[$0] })
        if geometry.retiring != retiring { geometry.retiring = retiring }
        if windowlessGeometry.retiring != retiring { windowlessGeometry.retiring = retiring }

        arrangeGaps(plan.tiles.gaps, blocked: layout.isFixed ? nil : layout.blocksInput)
        placeholder.show(plan.tiles.placeholder, kind: layout.motionKind, reduceMotion: look?.reduceMotion ?? false)

        let reduceMotion = look?.reduceMotion ?? false
        let resizing = layout.resizing != nil
        let blocksInput = layout.blocksInput
        for pane in retained {
            let card = cards[pane] ?? makeCard(pane)
            let closing = !layout.panes.contains(pane)
            let rect = plan.tiles.panes[pane]
            let placed = card.presentation.place(group: group, pane: pane, rect: rect, dockFrame: plan.dockFrame(of: pane, area: area),
                                                 fallbackSize: plan.regions.canvas.size, regions: plan.regions, closing: closing)
            let dimmed = plan.expanded && rect == nil && layout.drag?.pane != pane
            let dragged = layout.drag?.pane == pane
            let hasThread = area?.thread(in: pane) != nil
            // 被拖的卡片照常接：跟手拖动是它标题栏上的手势，中途设成不接会把拖动取消
            let accepts = (!blocksInput || dragged) && !resizing && !closing && !dimmed
            let arrangement = PhoneCardView.Arrangement(
                placed: placed, dockFrame: plan.dockFrame(of: pane, area: area), closing: closing, family: plan.familyID(of: pane),
                openSidebar: pane == plan.first ? openSidebar : nil, dimmed: dimmed, acceptsInput: accepts, dotsHidden: resizing || dotsHidden,
                dragged: dragged, hasThread: hasThread, fixed: layout.isFixed,
                header: card.headerState(layout: layout, minimized: placed.minimized, width: placed.target.frame.width, hasThread: hasThread))
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

    /// 拖动、拖缝时不浮标签；家族格里的父代理是窗口卡片报上来的，按窗口找。
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

    /// 观察之外：把终点交给各张卡片的 motion，再按这一轮的过渡状态报看得见的实例和悬停标签。
    private func settle(_ arranged: Arranged) {
        for (card, arrangement, kind) in arranged.cards {
            // 卡片铺满台面，里面各层按台面坐标摆
            place(card, bounds)
            card.arrange(arrangement)
            card.move(to: arrangement.placed.target, kind: kind)
        }
        if dragging != arranged.drag {
            dragging = arranged.drag
            // 起拖时收起各卡片的悬停（停靠栏标签）
            if arranged.drag != nil { for card in cards.values { card.resetHover() } }
        }
        if !arranged.transitioning && wasTransitioning { refreshHover() }
        wasTransitioning = arranged.transitioning
        hoverTip = arranged.hoverTip
        if visibleInstances != arranged.visible, window != nil {
            visibleInstances = arranged.visible
            let area = group.workspace, visible = arranged.visible
            // 改模型放到这一轮排版之后，同 SwiftUI 的 onChange
            Task { @MainActor in area?.noteVisible(visible) }
        }
        reportDots()
        updateDisplayLink()
    }

    private func makeCard(_ pane: Pane) -> PhoneCardView {
        let card = PhoneCardView(pane: pane, stage: self)
        cards[pane] = card
        insertSubview(card, belowSubview: dockOverlay)
        return card
    }

    /// 退出动画走完：拿掉这张卡片。
    func retire(_ card: PhoneCardView) {
        guard cards[card.pane] === card, card.closing, !card.motionMoving else { return }
        retained.removeAll { $0 == card.pane }
        paneInstances[card.pane] = nil
        cards[card.pane] = nil
        card.dismantle()
        card.removeFromSuperview()
        group.layout.noteSettling(card.pane, false)
        setNeedsLayout()
    }

    // MARK: - 缝

    /// 缝按 Gap.id 复用：排布重建时正在拖的那道缝不换视图。固定排布（设备账号、资源库上下文）没有缝；
    /// 过渡中缝不接点按，正拖着的缝照常接。
    private func arrangeGaps(_ list: [TileLayout.Gap], blocked: Bool?) {
        let shown = blocked == nil ? [] : list
        var seen = Set<ObjectIdentifier>()
        for gap in shown {
            seen.insert(gap.id)
            let view = gaps[gap.id] ?? {
                let view = StageGapView(stage: self)
                gaps[gap.id] = view
                insertSubview(view, belowSubview: placeholder)
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

    /// 窗口坐标换成台面坐标。
    func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    /// 台面坐标换成窗口坐标，同拖动报的。
    func windowPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + origin.x, y: point.y + origin.y)
    }

    // MARK: - 卡片的拖动、点按

    func drag(_ pane: Pane, to point: CGPoint) {
        let layout = group.layout, area = group.workspace, bounds = stageRect
        area?.collapseDock()
        area?.dockHover = nil
        let regions = layout.regions(in: bounds)
        let onStage = Set(layout.shown?.panes ?? [])
        layout.drag(pane, to: local(point), in: bounds) { remaining, location in
            StagePlan.dockIndex(of: pane, among: remaining, at: location, onStage: onStage, regions: regions, area: area)
        }
    }

    func drop() {
        group.layout.drop(in: stageRect)
    }

    func cancelDrag() {
        group.layout.cancelDrag()
    }

    /// 点最小化的窗口：恢复；家族格里的父代理先展开家族，展开后再点父代理才放上台面。
    func activate(_ pane: Pane, family: String?) {
        if let family { group.workspace?.toggleDock(family, depth: 0) }
        else { group.layout.restore(pane, in: stageRect) }
    }

    // MARK: - 逐帧

    /// 有卡片在跟手拖动时开显示链接，逐帧取样；别的排布动画整段交给 Core Animation（见 PhoneCardView.flightStarted）。
    func updateDisplayLink() {
        let moving = cards.values.contains { $0.needsFrames }
        if moving, displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = !moving
    }

    @objc private func tick(_ link: CADisplayLink) {
        // 取样按这一帧要显示的时刻，同 TimelineView 给的帧时刻
        let date = Date(timeIntervalSinceNow: link.targetTimestamp - CACurrentMediaTime())
        var moving = false
        for card in cards.values where card.needsFrames {
            card.applyPresentation(at: date)
            moving = true
        }
        if !moving { link.isPaused = true }
    }

    // MARK: - 悬停（iPad 指针）

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            pointer = recognizer.location(in: self)
            hover(at: pointer!)
        default:
            pointer = nil
            for card in cards.values { card.setHovered(false) }
        }
    }

    /// 按指针现在的位置重算悬停：动画停下、过渡结束时调，不等指针再动。
    func refreshHover() {
        if let pointer { hover(at: pointer) } else { for card in cards.values { card.setHovered(false) } }
    }

    /// 悬停在最上面那张接输入、停着的卡片上。
    private func hover(at point: CGPoint) {
        let found = subviews.sorted { $0.layer.zPosition < $1.layer.zPosition }.reversed().lazy
            .compactMap { $0 as? PhoneCardView }.first { $0.contains(point) }
        for card in cards.values where card !== found { card.setHovered(false) }
        found?.setHovered(true)
    }

    // MARK: - 命中

    private var regions: WindowRegions { group.layout.regions(in: stageRect) }

    /// 停靠栏只在停靠栏那一列接点按；过渡中不接，同 PausedInTransition。
    private var dockHitRegion: CGRect? {
        group.layout.transitioning || group.workspace == nil ? nil : regions.dock
    }

    /// 台面上没有窗口、也没在拖窗口时空画板接，只在显示着时接。
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

    /// 各张卡片和空画板报的点阵用量、停靠栏悬停标签交给 PhoneStageHost。外面的 SwiftUI 正在排版（台面就排在它里面），隔一拍再改它读的值。
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

    private func place(_ view: UIView, _ frame: CGRect) {
        if view.frame != frame { view.frame = frame }
    }

    // MARK: - 读屏

    /// 读屏按看的顺序：卡片（按位置从上到下、从左到右）、停靠栏、空画板、停靠栏上面那一层。
    override var accessibilityElements: [Any]? {
        get {
            let shown = cards.values.filter { !$0.closing }.sorted {
                let a = $0.accessibilityOrder, b = $1.accessibilityOrder
                return (a.minY, a.minX) < (b.minY, b.minX)
            }
            return shown + [dockRail, windowless, dockOverlay]
        }
        set {}
    }
}

/// 两张卡片之间的缝：按住拖动改这一刀的比例（挪过 4 点才算，同 SwiftUI 的 DragGesture）。过渡中不接（正拖着的照常接）。
private final class StageGapView: UIView {
    var gap: TileLayout.Gap?
    var blocked = false
    private weak var stage: PhoneStageView?
    private let drag = ThresholdDrag()

    init(stage: PhoneStageView) {
        self.stage = stage
        super.init(frame: .zero)
        drag.addTarget(self, action: #selector(dragged(_:)))
        addGestureRecognizer(drag)
        isAccessibilityElement = true
        accessibilityLabel = "调整窗口大小"
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 正拖着的照常接：UIKit 把拖动交给按下时的视图，这里只挡新的按下
        blocked && drag.state == .possible ? nil : super.hitTest(point, with: event)
    }

    @objc private func dragged(_ recognizer: ThresholdDrag) {
        guard let gap, let stage else { return }
        switch recognizer.state {
        case .began, .changed: stage.resize(gap, to: recognizer.location)
        default: stage.finishResize()
        }
    }

    // 读屏：左右（上下）各挪一个模块

    override var accessibilityValue: String? {
        get { gap.map { "\(Int(($0.split.ratio * 100).rounded()))%" } }
        set {}
    }

    override func accessibilityIncrement() { nudge(DotMetrics.module) }
    override func accessibilityDecrement() { nudge(-DotMetrics.module) }

    private func nudge(_ distance: CGFloat) {
        guard let gap, let stage else { return }
        let horizontal = gap.split.axis == .horizontal
        let center = CGPoint(x: frame.midX + (horizontal ? distance : 0), y: frame.midY + (horizontal ? 0 : distance))
        stage.resize(gap, to: stage.windowPoint(center))
        stage.finishResize()
    }
}

/// 拖动卡片时预览它放下后的位置：圆角 cardRadius（continuous，同 SwiftUI 的 RoundedRectangle），主题色 8% 填充、2 点主题色描边（画在里面，
/// 同 strokeBorder），出现、移动、消失跟着预览的动画走。用图层的圆角和边框，不用路径：Core Animation 自己插值位置、大小。
private final class StagePlaceholderView: UIView {
    private let shape = CALayer()
    private var shown: CGRect?

    /// 解析主题色用的环境，台面交过来。
    var environment = EnvironmentValues() {
        didSet { updateColors() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        shape.borderWidth = 2
        shape.cornerRadius = Metrics.cardRadius
        shape.cornerCurve = .continuous
        shape.opacity = 0
        layer.addSublayer(shape)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.updateColors() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 主题色 8% 填充、描边，按这个视图的外观解析。
    private func updateColors() {
        let accent = resolved(.accentColor, traits: traitCollection, in: environment)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.backgroundColor = accent.withAlphaComponent(accent.cgColor.alpha * 0.08).cgColor
        shape.borderColor = accent.cgColor
        CATransaction.commit()
    }

    /// 占位跟着预览插值位置和大小，出现、消失淡入淡出，和窗口同曲线同时长。
    func show(_ rect: CGRect?, kind: WindowMotionKind, reduceMotion: Bool) {
        guard rect != shown else { return }
        let previous = shown
        shown = rect
        let duration = reduceMotion ? 0 : kind.duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let rect {
            let fromBounds = shape.presentation()?.bounds ?? shape.bounds
            let fromPosition = shape.presentation()?.position ?? shape.position
            shape.bounds = CGRect(origin: .zero, size: rect.size)
            shape.position = CGPoint(x: rect.midX, y: rect.midY)
            if previous != nil, duration > 0 {
                shape.add(StageAnimation.basic("bounds", from: fromBounds, to: shape.bounds, duration: duration), forKey: "bounds")
                shape.add(StageAnimation.basic("position", from: fromPosition, to: shape.position, duration: duration), forKey: "position")
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
#endif
