#if os(iOS)
import SwiftUI
import UIKit

/// iPad 宽屏的台面：各张卡片、卡片之间的缝、拖动时的占位都是 UIKit 视图（PhoneStageView、PhoneCardView），拖缝改宽时
/// 每步只重算排布、按新位置摆，不经过 SwiftUI。停靠栏和它上面那一层（展开家族格时点空白收起）不随拖缝改尺寸，仍是 SwiftUI，
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
            .dockHoverSource(reports.hoverTips)
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

/// 台面本身：最底下停靠栏的岛，上面依次是缝、拖动时的占位、各张卡片，最上面是展开家族格时点空白收起的那一层。
/// 停靠栏里的头像由停靠栏画，卡片停在停靠栏的格子里时整张透明（见 CardPresentation）。
/// 观察排布模型（ModelTracking），变了在 layoutSubviews 里重算 StagePlan、摆缝和卡片；排布动画由各张卡片整段交给 Core Animation，
/// 只有跟手拖动的那张由显示链接逐帧取样。过渡中（WindowLayout.transitioning）缝、卡片、停靠栏都不接点按。
final class PhoneStageView: UIView, StageDotsReporting {
    /// 资源库里同一类换一项（角色、模板）时台面不重建（.id 只按类别），这里换成新的一项，正文跟着换，见 update。
    private(set) var group: PaneGroup
    let model: AppModel
    private let reports: StageReports
    let geometry = StageGeometry()
    /// 上一轮排版时侧栏收没收起，认出侧栏收起、展开的那一轮（见 layoutSubviews）。
    private var sidebarCollapsed: Bool?
    private(set) var environment = EnvironmentValues()
    private(set) var look: StageAppearance?
    private var openSidebar: (@MainActor () -> Void)?

    private let dockRail = HostIsland()
    private let placeholder = StagePlaceholderView()
    private let dockOverlay = HostIsland()
    private var gaps: [ObjectIdentifier: StageGapView] = [:]
    private var cards: [Pane: PhoneCardView] = [:]
    /// 台面上和正在退出的窗口，按加入的先后；退出动画走完才拿掉。
    private var retained: [Pane] = []
    /// pane 对应的实例（见 WorkArea.dockInstanceID），pane 没了以后还要知道它飞向哪个实例的格子（那一格先不显示）。
    private var paneInstances: [Pane: String] = [:]
    /// 排过一轮了：之后才有的卡片是新打开的窗口，要动着出来（见 CardPresentation.place 的 appearing）。
    private var populated = false
    /// 上一轮停靠栏的添加入口在哪，新建的窗口从这里长出来（见 CardPresentation.place 的 addStart）。
    private var lastAdd: CGRect?

    private let tracking = ModelTracking()
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
        addSubview(dockRail)
        addSubview(placeholder)
        addSubview(dockOverlay)
        // 停靠栏上面那一层压在拖动、关闭中置顶的卡片上面，见 PhoneCardView.raised
        dockOverlay.layer.zPosition = 2
        dockRail.hitRegion = { [weak self] in self?.dockHitRegion }
        dockOverlay.hitRegion = { [weak self] in self?.overlayHitRegion }
        // 停靠栏的格子拖出去：手指长按、指针按住挪动
        DockTouchDrag.install(on: dockRail, stage: self)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)
        NotificationCenter.default.addObserver(self, selector: #selector(sidebarDragged), name: SidebarDrag.changed, object: model.sidebarDrag)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            guard let look = self.look else { return }
            self.update(group: self.group, environment: self.environment, appearance: look, openSidebar: self.openSidebar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 环境

    /// 颜色模式以台面自己的 UIKit 外观为准，外观变了再交一遍，同 CompactShellView.update。
    func update(group: PaneGroup, environment: EnvironmentValues, appearance: StageAppearance, openSidebar: (@MainActor () -> Void)?) {
        var environment = environment, appearance = appearance
        environment.colorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        appearance.colorScheme = environment.colorScheme
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
        dockOverlay.rootView = rooted(StageDockOverlay(layout: layout, area: group.workspace, geometry: geometry))
    }

    /// 台面拆掉（换工作区、离开这一栏）：停掉显示链接，不再跟模型，卡片、缝和岛里的东西都清掉。
    func dismantle() {
        warming?.cancel()
        warming = nil
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
        for island in [dockRail, dockOverlay] {
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
        let previous = origin
        origin = window.map { convert(CGPoint.zero, to: $0) } ?? .zero
        // 台面在窗口里挪了（侧栏收起、展开；拖侧栏起手、松手时内容区往左伸、缩回，见 SidebarDrag）：摆着的卡片在台面坐标里反着挪，
        // 窗口里看着不动，再从那里按这一轮的排布走
        let offset = viewport == nil ? .zero : CGVector(dx: previous.x - origin.x, dy: previous.y - origin.y)
        if offset != .zero { for card in cards.values { card.shift(by: offset) } }
        // 侧栏收起、展开：台面一下子换到终点（SwiftUI 不逐帧改它的大小，见 TilesLayer），窗口照排布动画飞过去，正文只按终点排一次。
        // 只认台面跟着挪了的那一轮，同 Mac 的 StageView.layout
        let collapsed = model.sidebarCollapsed
        let toggled = sidebarCollapsed.map { $0 != collapsed } == true && offset != .zero
        sidebarCollapsed = collapsed
        laying = true
        defer { laying = false }
        // 拖侧栏改宽时内容区从侧栏最窄的宽起，台面自己把排窗口的那块让到侧栏实时的右边，见 SidebarDrag
        let shift = model.sidebarDrag.offset
        stageRect = CGRect(x: shift, y: 0, width: max(bounds.width - shift, 0), height: bounds.height)
        let size = stageRect.size
        if viewport != size {
            viewport = size
            // 报视口会改排布模型，自己的改动不回头再排一遍。台面左边在哪交给排布：侧栏改宽时只由最左一列吸收
            tracking.quietly { group.layout.updateViewport(size, presentation: .tiled, leading: origin.x + shift, animated: toggled) }
        }
        for island in [dockRail, dockOverlay] { place(island, bounds) }
        place(placeholder, bounds)
        // 停靠栏贴着台面右边，侧栏改宽时不动，按整个台面排
        if geometry.bounds != bounds { geometry.bounds = bounds }
        // 拖侧栏改宽（sidebarResizing）和排布读在同一条登记里：ModelTracking 同一时刻只留一条，分开读的话后一条不登记
        let arranged = tracking.track({ arrange(dotsHidden: model.sidebarResizing) }) { [weak self] in self?.invalidateArrangement() }
        // 别的挪动（拖侧栏起手、松手）当场摆过去，不走动画
        settle(arranged, immediate: offset != .zero && !toggled)
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
        var hoverTips: [DockHoverTip] = []
        var drag: Pane?
        /// 停靠栏里各格这一刻谁画头像，见 StageGeometry。
        var airborne: Set<String> = []
        var staged: Set<String> = []
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
            // 新建页交给了后台实例：飞进那一格，飞到之前那一格先不显示
            for pane in retained where paneInstances[pane] != area.dockInstanceID(pane) { paneInstances[pane] = area.dockInstanceID(pane) }
        }

        arrangeGaps(plan.tiles.gaps, blocked: layout.isFixed ? nil : layout.blocksInput)
        placeholder.show(plan.tiles.placeholder, kind: layout.motionKind, reduceMotion: look?.reduceMotion ?? false)

        let reduceMotion = look?.reduceMotion ?? false
        let resizing = layout.resizing != nil
        let blocksInput = layout.blocksInput
        // 拖动、拖缝、拖侧栏改宽（dotsHidden）时每步都来一轮，展开、还原按钮要等卡片停下才换（updateExpands）：
        // 沿用上一轮算的，松手那一轮（这几样都在观察里）再算
        let keepsExpansion = layout.drag != nil || resizing || dotsHidden
        let appearing = populated
        populated = true
        for pane in retained {
            let fresh = cards[pane] == nil
            let card = cards[pane] ?? makeCard(pane)
            let closing = !layout.panes.contains(pane)
            let rect = plan.tiles.panes[pane]
            let instance = paneInstances[pane], slot = plan.dockSlot(of: pane, instance: instance)
            let placed = card.presentation.place(group: group, pane: pane, rect: rect, dock: slot,
                                                 fallbackSize: plan.regions.canvas.size, regions: plan.regions, closing: closing,
                                                 appearing: appearing && fresh, addButton: plan.dock?.add, addStart: lastAdd,
                                                 tucked: plan.tucked(instance))
            switch placed.facing {
            case .card: arranged.airborne.insert(instance ?? pane.id)
            case .stage: arranged.staged.insert(instance ?? pane.id)
            case .cell: break
            }
            // 停在停靠栏里的卡片整张透明，不压暗（压暗的模糊挂在铺满台面的图层上）
            let dimmed = plan.expanded && rect == nil && layout.drag?.pane != pane && !placed.hidden
            let dragged = layout.drag?.pane == pane
            let hasThread = area?.thread(in: pane) != nil
            // 被拖的卡片照常接：跟手拖动是它标题栏上的手势，中途设成不接会把拖动取消
            let accepts = (!blocksInput || dragged) && !resizing && !closing && !dimmed && !placed.hidden
            let arrangement = PhoneCardView.Arrangement(
                placed: placed, closing: closing,
                openSidebar: pane == plan.first ? openSidebar : nil, dimmed: dimmed, acceptsInput: accepts, dotsHidden: resizing || dotsHidden,
                dragged: dragged, hasThread: hasThread, fixed: layout.isFixed,
                header: card.headerState(layout: layout, minimized: placed.minimized, width: placed.target.frame.width, hasThread: hasThread),
                expansion: (keepsExpansion ? card.arrangement?.expansion : nil) ?? layout.expansion(of: pane))
            arranged.cards.append((card, arrangement, CardPresentation.motionKind(layout: layout, pane: pane, reduceMotion: reduceMotion)))
        }
        lastAdd = plan.dock?.add
        arranged.visible = Set(plan.onStage.map(\.id))
        cardDots = (cards.values.contains { $0.bodyReports.usesDots }, cards.values.reduce(into: Set<String>()) {
            $0.formUnion($1.bodyReports.dotSlots)
            $0.formUnion($1.bodyReports.threadSlots)
        })
        arranged.hoverTips = hoverTips(plan: plan)
        return arranged
    }

    /// 拖动、拖缝时不浮标签。
    private func hoverTips(plan: StagePlan) -> [DockHoverTip] {
        let layout = group.layout
        guard layout.drag == nil, layout.resizing == nil, let area = group.workspace, let geometry = plan.dock else { return [] }
        return area.dockHoverTips(in: geometry, numbered: model.shortcutHint == .dock)
    }

    /// 观察之外：把终点交给各张卡片的 motion，再按这一轮的过渡状态报看得见的实例和悬停标签。
    private func settle(_ arranged: Arranged, immediate: Bool) {
        var unsettled = false
        for (card, arrangement, kind) in arranged.cards {
            let placed = arrangement.placed, kind = immediate || placed.immediate ? .immediate : kind
            // 卡片铺满台面，里面各层按台面坐标摆
            place(card, bounds)
            card.arrange(arrangement, kind: kind)
            if let snap = placed.snap { card.move(to: snap, kind: .immediate) }
            card.move(to: placed.target, kind: kind)
            if placed.unsettled || placed.awaitsRest && !placed.motion.moving { unsettled = true }
        }
        if geometry.airborne != arranged.airborne { geometry.airborne = arranged.airborne }
        if geometry.staged != arranged.staged { geometry.staged = arranged.staged }
        // 落进格子还差一步、没有动画就到了的：下一拍再排一轮，同 Mac 的 StageView.settle
        if unsettled { DispatchQueue.main.async { [weak self] in self?.setNeedsLayout() } }
        if dragging != arranged.drag {
            dragging = arranged.drag
            // 起拖时收起各卡片的悬停（停靠栏标签）
            if arranged.drag != nil { for card in cards.values { card.resetHover() } }
        }
        if !arranged.transitioning && wasTransitioning { refreshHover() }
        wasTransitioning = arranged.transitioning
        hoverTips = arranged.hoverTips
        if visibleInstances != arranged.visible, window != nil {
            visibleInstances = arranged.visible
            let area = group.workspace, visible = arranged.visible
            // 改模型放到这一轮排版之后，同 SwiftUI 的 onChange
            Task { @MainActor in area?.noteVisible(visible) }
        }
        reportDots()
        updateDisplayLink()
        warmUp()
    }

    /// 停靠栏里正文还没建的卡片（见 PhoneCardView.bodyDeferred），空闲时由先到后一张张建，同 Mac 的 StageView.warmUp。
    private var warming: Task<Void, Never>?

    private func warmUp() {
        guard warming == nil, cards.values.contains(where: { $0.bodyDeferred && !$0.closing }) else { return }
        warming = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
                while true {
                    while WindowLayout.anyTransitioning { try await Task.sleep(for: .milliseconds(100)) }
                    guard let self else { return }
                    guard let card = retained.lazy.compactMap({ self.cards[$0] }).first(where: { $0.bodyDeferred && !$0.closing }) else { break }
                    card.buildBody()
                    try await Task.sleep(for: .milliseconds(250))
                }
            } catch {}
            self?.warming = nil
        }
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
        let layout = group.layout, area = group.workspace
        area?.collapseDock()
        area?.dockHover = nil
        layout.drag(pane, to: local(point), in: stageRect)
    }

    func drop() {
        group.layout.drop(in: stageRect)
    }

    func cancelDrag() {
        group.layout.cancelDrag()
    }

    /// 读屏在缩成停靠形状的卡片上要展开：放上台面。
    func activate(_ pane: Pane) {
        group.layout.restore(pane, in: stageRect)
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

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 展开着家族格时，停靠栏那一列在点空白收起的那一层上面
        if group.workspace?.dockExpansion.isEmpty == false, self.point(inside: point, with: event), dockHitRegion?.contains(point) == true,
           let hit = dockRail.hitTest(convert(point, to: dockRail), with: event) {
            return hit
        }
        return super.hitTest(point, with: event)
    }

    private var regions: WindowRegions { group.layout.regions(in: stageRect) }

    /// 停靠栏只在停靠栏那一列接点按，左右多让出展开的家族格比格子宽的那一点；过渡中不接，同 PausedInTransition。
    private var dockHitRegion: CGRect? {
        group.layout.transitioning || group.workspace == nil ? nil : regions.dock.insetBy(dx: -DockGroup.padding, dy: 0)
    }

    /// 停靠栏展开时铺满台面接点空白收起；收着时上面只有脉冲，不接。
    private var overlayHitRegion: CGRect? {
        guard let area = group.workspace, !area.dockExpansion.isEmpty, !group.layout.transitioning else { return nil }
        return bounds
    }

    // MARK: - 点阵

    private var hoverTips: [DockHoverTip] = []
    private var reporting = false

    /// 各张卡片报的点阵用量、停靠栏悬停标签交给 PhoneStageHost。外面的 SwiftUI 正在排版（台面就排在它里面），隔一拍再改它读的值。
    func reportDots() {
        guard !reporting else { return }
        reporting = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reporting = false
            let uses = cardDots.uses
            let slots = cardDots.slots
            if reports.usesDots != uses { reports.usesDots = uses }
            if reports.dotSlots != slots { reports.dotSlots = slots }
            if reports.hoverTips != hoverTips { reports.hoverTips = hoverTips }
        }
    }

    private func place(_ view: UIView, _ frame: CGRect) {
        if view.frame != frame { view.frame = frame }
    }

    // MARK: - 读屏

    /// 读屏按看的顺序：卡片（按位置从上到下、从左到右）、停靠栏、停靠栏上面那一层。
    override var accessibilityElements: [Any]? {
        get {
            let shown = cards.values.filter { !$0.closing }.sorted {
                let a = $0.accessibilityOrder, b = $1.accessibilityOrder
                return (a.minY, a.minX) < (b.minY, b.minX)
            }
            let layers: [UIView] = [dockRail, dockOverlay]
            return shown as [UIView] + layers
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
