#if os(iOS)
import SwiftUI
import UIKit

/// iPhone、iPad 会话窗口的外框。拖缝改宽时它每步跟着改尺寸，
/// 输入区（ControlsBarView）直接挂在这里，只按宽度重摆；原生的对话列表（PhoneTranscriptView）和标题栏放在同一个岛里
/// （标题栏用 safeAreaBar，列表在它下面，SwiftUI 照旧给它们建滚动软边的容器，见 ThreadHeaderRoot），改宽时这个岛只排标题那一截
/// 和列表的大小，列表里面照旧自己排；标题栏两侧各在自己的托管视图里（见 WindowHeaderAnchored）。空会话的签名、录音时底部那一带
/// 是铺满窗口的岛，只在有它们时才在。层次从下到上：签名或那一带、标题栏和对话、输入区。
/// 状态和动作共用 ThreadPaneModel；结构照 Mac 的 ThreadWindowView。坐标照卡片正文：左上角是正文原点。
/// 紧凑布局里（compact）标题栏和输入区由外壳统一摆（换窗口时原地淡入淡出，见 CompactRowView），这里只剩对话和签名，让出的距离由外壳给。
final class PhoneThreadWindowView: UIView, UIGestureRecognizerDelegate {
    let thread: WorkThread
    let pane: ThreadPaneModel
    private(set) var environment: EnvironmentValues
    private var group: PaneGroup
    private let paneID: Pane
    private let model: AppModel
    private let header: PaneCardHeader
    private let regions: HeaderRegions
    private let reports: PaneCardBodyReports
    private let motion: WindowMotion

    private let backdrop = HostIsland()
    private let list = PhoneTranscriptView()
    let controls: ControlsBarView
    private let compactComposer: CompactComposerState
    private(set) var compactChrome: CompactPaneHeader?
    /// 对话列表，和它上面给滚动软边占位的标题栏（safeAreaBar，透明，高同标题栏）。
    private let surface = HostIsland()
    /// 标题栏，原生的，压在对话上面。
    let headerBar = PhoneHeaderBar()
    /// 宽屏标题栏后面的渐变，原生画：改宽时只改图层大小，不像 SwiftUI 的渐变那样每步重画。紧凑布局的在外壳上（CompactRowView）。
    private let fade = TopFadeView()
    /// 紧凑布局：标题栏和输入区交给外壳，见 compactInsets。
    let compact: Bool
    /// 紧凑布局里外壳让出的距离：上面是状态栏连同标题栏，下面是输入区连同 Home 条或键盘，左右是横屏时的安全区。
    var compactInsets = EdgeInsets() {
        didSet { if compactInsets != oldValue { setNeedsLayout() } }
    }

    /// 紧凑布局里标题栏换了内容（compactChrome）：外壳重新交给共用的标题栏、控制区。
    var chromeChanged: (() -> Void)?
    /// 紧凑布局里输入区变高变矮了：外壳重摆，对话的让位按输入区当场算（见 CompactRowView.layoutChrome）。标题栏没变，不重交。
    var controlsResized: (() -> Void)?
    private let headerTracking = ModelTracking()
    private let metrics = ThreadWindowMetrics()
    /// 窗口的范围（正文坐标），交给铺满窗口的签名，同 PaneWindow 的 paneWindowFrame。
    private let windowFrame = PaneWindowFrame()
    /// 输入区的状态（发送淡出、思考强度的草稿、失败提示），窗口在就一直是同一份。
    private let controlsState = ThreadControlsState()

    private let tracking = ModelTracking()
    private let rowsTracking = ModelTracking()
    private let controlsTracking = ModelTracking()
    private var rows: [TranscriptRow] = []
    private var rowsDirty = true
    private var insets = EdgeInsets()
    private var laying = false

    override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    init(thread: WorkThread, pane: ThreadPaneModel, environment: EnvironmentValues, group: PaneGroup, paneID: Pane, model: AppModel,
         header: PaneCardHeader, regions: HeaderRegions, reports: PaneCardBodyReports, motion: WindowMotion, compact: Bool = false) {
        self.thread = thread
        self.pane = pane
        self.environment = environment
        self.group = group
        self.paneID = paneID
        self.model = model
        self.header = header
        self.regions = regions
        self.reports = reports
        self.motion = motion
        self.compact = compact
        controls = ControlsBarView(glassManagedExternally: compact)
        compactComposer = CompactComposerState(bar: controls)
        super.init(frame: .zero)
        pane.scroll.list = list
        for view in (compact ? [backdrop, surface] : [backdrop, surface, fade, headerBar, controls]) as [UIView] { addSubview(view) }
        headerBar.controlsSpace = header
        headerBar.changed = { [weak self] in self?.headerChanged() }
        headerBar.tapped = { [weak self] in self?.controls.endTyping() }
        backdrop.isHidden = true
        list.isHidden = true
        controls.heightChanged = { [weak self] in
            guard let self else { return }
            if compact {
                compactComposer.sizeRevision += 1
                controlsResized?()
            } else { invalidate() }
        }
        if compact {
            controls.focusChanged = { [weak self] typing in self?.compactComposer.typing = typing }
        }
        installIslands()
        refreshRows()
        refreshControls()
        refreshHeader()

        // 点窗口任何地方都聚焦它，打字时点输入区以外收起键盘；和窗口里原有的点按同时生效，不抢它们（同 paneFocus、endsTyping）
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 环境变了（外观、屏幕倍数、减少动态效果、字号、引用跳转的范围……）或窗口组换了：几个岛重新交环境，对话的行也换上新环境。
    func environmentChanged(_ environment: EnvironmentValues, group: PaneGroup) {
        self.environment = environment
        self.group = group
        installIslands()
        rowsDirty = true
        refreshControls()
        refreshHeader()
        setNeedsLayout()
    }

    private func installIslands() {
        fade.environment = environment
        let roots = ThreadIslandEnvironment(group: group, pane: paneID, header: header, model: pane)
        surface.rootView = rooted(PhoneTranscriptSurface(list: list, metrics: metrics, compact: compact))
        if !compact {
            headerBar.install(status: rooted(ThreadHeaderStatusRoot(openSidebar: sidebarAction).modifier(roots)),
                              actions: rooted(ThreadHeaderActions().fixedSize().modifier(roots)), environment: environment)
        }
        backdrop.rootView = rooted(ThreadBackdropRoot(pane: pane, metrics: metrics, windowFrame: windowFrame, reports: reports).modifier(roots))
    }

    private func rooted(_ view: some View) -> AnyView {
        AnyView(view
            .containerShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
            .environment(\.self, environment))
    }

    func dismantle() {
        tracking.cancel()
        headerTracking.cancel()
        headerBar.changed = nil
        headerBar.tapped = nil
        chromeChanged = nil
        controlsResized = nil
        rowsTracking.cancel()
        controlsTracking.cancel()
        controls.heightChanged = nil
        controls.focusChanged = nil
        compactChrome = nil
        for island in [surface, backdrop] {
            island.hitRegion = nil
            island.rootView = AnyView(EmptyView())
        }
        if pane.scroll.list === list { pane.scroll.list = nil }
    }

    // MARK: - 标题栏

    /// 标题栏左边的侧栏入口（左上角的窗口、侧栏收起时）：先收起输入，再拉开侧边栏。
    private var sidebarAction: (@MainActor () -> Void)? {
        guard let openSidebar = environment.openSidebar else { return nil }
        return { [weak self] in
            self?.controls.endTyping()
            openSidebar()
        }
    }

    /// 标题、副标题、刷新、副标题菜单：读会话和 App 模型，变了交一遍（同 ThreadPane 交给 PaneWindow 的 header）。
    private func refreshHeader() {
        guard let area = group.workspace else { return }
        let thread = thread, pane = pane, model = model
        let header = headerTracking.track({
            pane.header(thread: thread, model: model, area: area, initial: thread.isInitial)
        }) { [weak self] in
            Task { @MainActor in self?.refreshHeader() }
        }
        let roots = ThreadIslandEnvironment(group: group, pane: paneID, header: self.header, model: pane)
        if compact {
            compactChrome = CompactPaneHeader(pane: paneID, header: header,
                status: AnyView(CompactThreadStatus()),
                // 同 PaneWindow 画的右组一种视图，换窗口时原地更新（见 PaneHeaderActions）
                actions: AnyView(PaneHeaderActions(menus: AnyView(ThreadHeaderActions().modifier(roots)))),
                controls: AnyView(CompactNativeControls(bar: controls, state: compactComposer)), hasControls: true,
                environment: environment, openSidebar: sidebarAction, endTyping: { [weak self] in self?.controls.endTyping() })
            chromeChanged?()
            return
        }
        headerBar.update(.init(header: header, openSidebar: sidebarAction)) {
            rooted(PaneHeaderTitle(header: header).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).clipped().modifier(roots))
        }
    }

    /// 标题栏的高、菜单宽、可点的范围报给卡片（同 PaneHeaderReports）：卡片的拖动层按它们让位、挖空，窗口按钮按高居中。
    private func headerChanged() {
        if compact {
            chromeChanged?()
            return
        }
        let height = headerBar.height
        if header.height != height { header.height = height }
        let width = headerBar.menuWidth
        if header.menuWidth != width { header.menuWidth = width }
        setNeedsLayout()
    }

    private func reportRegions() {
        let rects = headerBar.interactiveRects
        regions.rects = rects
        if !motion.moving, regions.settled != rects { regions.settled = rects }
    }

    // MARK: - 输入区

    /// 输入区读的模型：会话、实例、能不能输入（建草稿窗口中、配置模板中整块禁用），变了交一遍。
    private func refreshControls() {
        guard let area = group.workspace else { return }
        let thread = thread, pane = pane, model = model, paneID = paneID
        let enabled = controlsTracking.track({
            environment.isEnabled && area.creatingWindow == nil && !thread.configuringTemplate
        }) { [weak self] in
            Task { @MainActor in self?.refreshControls() }
        }
        let instance = area.windows.first(where: { $0.id == paneID.id }).flatMap { window in
            area.instances.first { $0.id == window.target.instanceId }
        }
        let controlsModel = ThreadControlsModel(thread: thread, model: model, area: area, instance: instance, stage: environment.dotStage,
                                                scope: environment.dotScope, voiceOwner: pane.patternSlot, state: controlsState) { message, alongside in
            pane.send(message, thread: thread, model: model, area: area, alongside: alongside)
        }
        var environment = environment
        environment.paneInstance = instance
        controls.update(controls: controlsModel, enabled: enabled, environment: environment)
    }

    // MARK: - 对话的行

    /// 读会话记录、选中的行、刚发出的消息，变了换一遍行；行交给列表放在排版里（观察之外），见 layoutSubviews。
    private func refreshRows() {
        let thread = thread, pane = pane
        rows = rowsTracking.track({ pane.transcriptRows(of: thread) }) { [weak self] in
            // 通知在属性改之前，下一拍再读
            Task { @MainActor in self?.refreshRows() }
        }
        rowsDirty = true
        setNeedsLayout()
    }

    private var rowContext: TranscriptRowContext { pane.rowContext(environment: environment, thread: thread) }

    // MARK: - 排版

    private struct State {
        var initial: Bool
        var empty: Bool
        var listening: Bool
        var headerHeight: CGFloat
        /// 给窗口按钮让出的宽（随卡片的悬停、宽度变）。
        var controlsInset: CGFloat
    }

    /// 标题栏的高，按给窗口按钮留的高（PaneCardHeader.minHeight）和里面的岛量。
    private var headerHeight: CGFloat {
        _ = header.minHeight
        return headerBar.height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        laying = true
        defer { laying = false }
        if compact {
            layoutCompact()
            return
        }
        let state = tracking.track({
            State(initial: thread.isInitial, empty: !thread.hasTranscript, listening: pane.listening(model), headerHeight: headerHeight,
                  controlsInset: header.inset)
        }) { [weak self] in self?.invalidate() }
        let width = bounds.width, height = bounds.height

        // 输入区：同宽屏的 PaneControlsBar，左右、底各留 paneMargin，玻璃最宽 transcriptWidth 居中；高按宽度原生量
        let margin = Metrics.paneMargin
        let glassWidth = max(min(Metrics.transcriptWidth, width - 2 * margin), 0)
        let glassHeight = controls.height(forWidth: glassWidth)
        let barHeight = glassHeight + margin
        place(controls, CGRect(x: (width - glassWidth) / 2, y: height - barHeight, width: glassWidth, height: glassHeight))
        if metrics.controlsHeight != barHeight { metrics.controlsHeight = barHeight }

        place(surface, bounds)
        place(fade, CGRect(x: 0, y: 0, width: width, height: state.headerHeight + Metrics.topFadeOverhang))
        place(headerBar, CGRect(x: 0, y: 0, width: width, height: state.headerHeight))
        headerBar.layoutIfNeeded()
        reportRegions()
        placeTranscript(state, headerHeight: state.headerHeight,
                        insets: EdgeInsets(top: state.headerHeight, leading: 0, bottom: barHeight, trailing: 0))
    }

    /// 紧凑布局：对话铺满，上下让出外壳给的距离；标题栏后面的渐变、滚动软边从窗口顶边铺到标题栏底边。
    private func layoutCompact() {
        let state = tracking.track({
            State(initial: thread.isInitial, empty: !thread.hasTranscript, listening: pane.listening(model), headerHeight: 0, controlsInset: 0)
        }) { [weak self] in self?.invalidate() }
        let insets = compactInsets
        if metrics.controlsHeight != insets.bottom { metrics.controlsHeight = insets.bottom }
        place(surface, bounds)
        // 键盘升降时外壳在键盘的动画块里排版：对话当场排、滚动位置跟着键盘的曲线走（iOS 的惯例），新露出来的行不带动画放进去（见 PhoneTranscriptView.realize）
        placeTranscript(state, headerHeight: insets.top, insets: insets, rowsWithoutAnimation: true)
        list.layoutIfNeeded()
    }

    /// 两种布局共用的后半段：报标题栏的位置和窗口的框；空会话的签名、录音时底部那一带有它们时才铺满窗口；对话让出上下的距离，行变了换行。
    private func placeTranscript(_ state: State, headerHeight: CGFloat, insets: EdgeInsets, rowsWithoutAnimation: Bool = false) {
        let placement = ThreadWindowMetrics.Header(origin: .zero, size: CGSize(width: bounds.width, height: headerHeight))
        if metrics.header != placement { metrics.header = placement }
        let window = CGRect(origin: .zero, size: bounds.size)
        if windowFrame.rect != window { windowFrame.rect = window }
        let backdropShown = state.initial || (state.listening && !state.empty)
        backdrop.isHidden = !backdropShown
        if backdropShown { place(backdrop, bounds) }
        list.isHidden = state.empty
        if insets != self.insets {
            self.insets = insets
            list.setInsets(insets)
        }
        guard rowsDirty, !state.empty else { return }
        rowsDirty = false
        if rowsWithoutAnimation {
            UIView.performWithoutAnimation { list.update(rows, context: rowContext, presence: environment.panePresence) }
        } else {
            list.update(rows, context: rowContext, presence: environment.panePresence)
        }
    }

    /// 排版当中改了读过的模型：这一轮排完 UIKit 会清掉待排，下一拍再标一次（同 PhoneStageView）。
    private func invalidate() {
        setNeedsLayout()
        guard laying else { return }
        DispatchQueue.main.async { [weak self] in self?.setNeedsLayout() }
    }

    private func place(_ view: UIView, _ frame: CGRect) {
        if view.frame != frame { view.frame = frame }
    }

    // MARK: - 点按

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: self)
        if controls.typing, !controls.convert(controls.bounds, to: self).contains(point) { controls.endTyping() }
        group.layout.focus(paneID)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: - 读屏

    /// 读屏顺序按看的顺序：标题栏、对话、（空会话的说明）、输入区。
    override var accessibilityElements: [Any]? {
        get { (compact ? [surface, backdrop] : [headerBar, surface, backdrop, controls]).filter { !$0.isHidden } }
        set {}
    }
}
/// 对话列表那个岛：列表铺满，顶上一条 safeAreaBar 和标题栏一样高，只画标题栏后面的渐变。UIKit 的滚动软边只认同一个 SwiftUI 软边容器里的
/// 滚动视图（UIScrollEdgeElementContainerInteraction 在 SwiftUI 托管的窗口里连不上，2026-10-14 iPad 真机导过：软边高 0），
/// 所以软边照旧由 SwiftUI 建，标题栏本身是原生的、压在上面。
/// 紧凑布局里（compact）标题栏、渐变在外壳上（CompactRowView，开合时跟着标题栏补位），这里只放一条看不出来的 safeAreaBar 撑起滚动软边。
/// 软边的高按这一条里元素的底边再往下伸一截：这一条到外壳标题栏按钮的底边为止（标题栏底下的 paneMargin 之上），
/// 不按整条标题栏的高（2026-10-14 iPhone 真机导过：这样软边 150，按整条标题栏高是 164，多出一截）。
private struct PhoneTranscriptSurface: View {
    let list: PhoneTranscriptView
    let metrics: ThreadWindowMetrics
    let compact: Bool

    var body: some View {
        if compact {
            PhoneTranscriptSlot(list: list)
                .ignoresSafeArea()
                .safeAreaBar(edge: .top, spacing: 0) {
                    // 全透明的一条 SwiftUI 不当软边的元素（软边就只剩滚动视图自己那条，高度不随标题栏），垫一层看不出来的底
                    Color.black.opacity(0.001).frame(height: max(metrics.header.size.height - Metrics.paneMargin, 0)).allowsHitTesting(false)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectHidden(true, for: .bottom)
        } else {
            PhoneTranscriptSlot(list: list)
                .ignoresSafeArea()
                .safeAreaBar(edge: .top, spacing: 0) {
                    // 标题栏后面的渐变是原生的（TopFadeView），这一条只撑起滚动软边：全透明的一条 SwiftUI 不当软边的元素，垫一层看不出来的底
                    Color.black.opacity(0.001).frame(height: metrics.header.size.height)
                        .allowsHitTesting(false)
                }
                // 同 PaneWindow：标题栏后面是系统滚动软边，底边不要
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectHidden(true, for: .bottom)
        }
    }
}

/// 标题栏后面的渐变，同 PaneTopFade：卡片底色从顶上不透明到底下透明，11 个色标按 1 − h²，伸过标题栏底边 topFadeOverhang（视图的高已含）。
final class TopFadeView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradient: CAGradientLayer { layer as! CAGradientLayer }
    var environment: EnvironmentValues? {
        didSet { updateColors() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        gradient.locations = (0...10).map { NSNumber(value: Double($0) / 10) }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.updateColors() }
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateColors() {
        let card = resolved(Theme.card, traits: traitCollection, in: environment)
        var alpha: CGFloat = 0
        card.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        gradient.colors = (0...10).map { i in
            let h = CGFloat(i) / 10
            return card.withAlphaComponent(alpha * (1 - h * h)).cgColor
        }
    }
}

/// 原生标题栏的信息区：会话的状态圆环，所属工作机的连接提示优先于会话自己的提示，提示出现时虚化盖住。
private struct ThreadHeaderStatusRoot: View {
    let openSidebar: (@MainActor () -> Void)?
    @Environment(WorkThread.self) private var thread
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.paneConnectionNotice) private var connectionNotice

    var body: some View {
        PhoneHeaderStatusRoot(status: ThreadStatusRing().environment(\.paneNotice, connectionNotice ?? model.threadNotice(thread, in: area)),
                              openSidebar: openSidebar)
    }
}

/// 原生的对话列表放进标题栏那个岛的 SwiftUI 里：同一个列表对象，建好不换，尺寸由岛给。
private struct PhoneTranscriptSlot: UIViewRepresentable {
    let list: PhoneTranscriptView

    func makeUIView(context: Context) -> PhoneTranscriptView { list }
    func updateUIView(_ list: PhoneTranscriptView, context: Context) {}

    /// 铺满给的地方；不给的话 SwiftUI 按 Auto Layout 量。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PhoneTranscriptView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
#endif
