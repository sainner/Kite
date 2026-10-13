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
    let controls = ControlsBarView()
    /// 对话列表，和它上面给滚动软边占位的标题栏（safeAreaBar，透明，高同标题栏）。
    private let surface = HostIsland()
    /// 标题栏，原生的，压在对话上面。
    let headerBar = PhoneHeaderBar()
    /// 紧凑布局：标题栏和输入区交给外壳，见 compactInsets。
    let compact: Bool
    /// 紧凑布局里外壳让出的距离：上面是状态栏连同标题栏，下面是输入区连同 Home 条或键盘，左右是横屏时的安全区。
    var compactInsets = EdgeInsets() {
        didSet { if compactInsets != oldValue { setNeedsLayout() } }
    }

    /// 紧凑布局里标题栏、输入区的高变了：外壳重摆。
    var chromeChanged: (() -> Void)?
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
        super.init(frame: .zero)
        pane.scroll.list = list
        for view in (compact ? [backdrop, surface] : [backdrop, surface, headerBar, controls]) as [UIView] { addSubview(view) }
        headerBar.controlsSpace = header
        headerBar.changed = { [weak self] in self?.headerChanged() }
        headerBar.tapped = { [weak self] in self?.controls.endTyping() }
        backdrop.isHidden = true
        list.isHidden = true
        controls.heightChanged = { [weak self] in
            guard let self else { return }
            if compact { chromeChanged?() } else { invalidate() }
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
        let roots = ThreadIslandEnvironment(group: group, pane: paneID, header: header, model: pane)
        surface.rootView = rooted(PhoneTranscriptSurface(list: list, metrics: metrics, compact: compact))
        headerBar.install(status: rooted(ThreadHeaderStatusRoot(openSidebar: sidebarAction).modifier(roots)),
                          actions: rooted(ThreadHeaderActions().fixedSize().modifier(roots)), environment: environment)
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
        rowsTracking.cancel()
        controlsTracking.cancel()
        controls.heightChanged = nil
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
            pane.header(thread: thread, model: model, area: area, initial: pane.initial(thread))
        }) { [weak self] in
            Task { @MainActor in self?.refreshHeader() }
        }
        let roots = ThreadIslandEnvironment(group: group, pane: paneID, header: self.header, model: pane)
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
        rows = rowsTracking.track({
            _ = pane.selected
            _ = pane.arriving.ids
            return TranscriptRow.rows(items: thread.transcript.items, pending: thread.transcript.pending)
        }) { [weak self] in
            // 通知在属性改之前，下一拍再读
            Task { @MainActor in self?.refreshRows() }
        }
        rowsDirty = true
        setNeedsLayout()
    }

    /// 行看到的环境：窗口的环境加上正文字号、刚发出的消息、选中的行、工作目录。
    private var rowContext: TranscriptRowContext {
        var environment = environment
        environment.font = Theme.body
        environment.arrivingMessages = pane.arriving.ids
        let pane = pane
        let selection = Binding<RowID?>(get: { pane.selected }, set: { pane.selected = $0 })
        environment.selectedRow = selection
        environment.workingDirectory = thread.transcriptRoot
        return TranscriptRowContext(environment: environment, actionable: true, toggleActions: { selection.toggle($0) })
    }

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
            State(initial: pane.initial(thread), empty: !thread.hasTranscript, listening: pane.listening(model), headerHeight: headerHeight,
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
        place(headerBar, CGRect(x: 0, y: 0, width: width, height: state.headerHeight))
        headerBar.setNeedsLayout()
        headerBar.layoutIfNeeded()
        reportRegions()
        let placement = ThreadWindowMetrics.Header(origin: .zero, size: CGSize(width: width, height: state.headerHeight))
        if metrics.header != placement { metrics.header = placement }
        let window = CGRect(origin: .zero, size: bounds.size)
        if windowFrame.rect != window { windowFrame.rect = window }

        // 空会话的签名、录音时底部那一带：有它们时才铺满窗口
        let backdropShown = state.initial || (state.listening && !state.empty)
        backdrop.isHidden = !backdropShown
        if backdropShown { place(backdrop, bounds) }

        list.isHidden = state.empty
        let insets = EdgeInsets(top: state.headerHeight, leading: 0, bottom: barHeight, trailing: 0)
        if insets != self.insets {
            self.insets = insets
            list.setInsets(insets)
        }
        if rowsDirty, !state.empty {
            rowsDirty = false
            list.update(rows, context: rowContext, presence: environment.panePresence)
        }
    }

    /// 紧凑布局：对话铺满，上下让出外壳给的距离；标题栏后面的渐变、滚动软边从窗口顶边铺到标题栏底边。
    private func layoutCompact() {
        let state = tracking.track({
            State(initial: pane.initial(thread), empty: !thread.hasTranscript, listening: pane.listening(model), headerHeight: 0, controlsInset: 0)
        }) { [weak self] in self?.invalidate() }
        let insets = compactInsets
        if metrics.controlsHeight != insets.bottom { metrics.controlsHeight = insets.bottom }
        place(surface, bounds)
        let placement = ThreadWindowMetrics.Header(origin: .zero, size: CGSize(width: bounds.width, height: insets.top))
        if metrics.header != placement { metrics.header = placement }
        let window = CGRect(origin: .zero, size: bounds.size)
        if windowFrame.rect != window { windowFrame.rect = window }
        let backdropShown = state.initial || (state.listening && !state.empty)
        backdrop.isHidden = !backdropShown
        if backdropShown { place(backdrop, bounds) }
        list.isHidden = state.empty
        // 键盘升降时外壳在键盘的动画块里排版：对话一次到位（那时列表拿到的就是终点的让位），不让新露出来的行从原点飞进来
        UIView.performWithoutAnimation {
            if insets != self.insets {
                self.insets = insets
                list.setInsets(insets)
            }
            if rowsDirty, !state.empty {
                rowsDirty = false
                list.update(rows, context: rowContext, presence: environment.panePresence)
            }
            list.layoutIfNeeded()
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
                    // 标题栏后面的渐变也在这里画（同 PaneHeaderPlacement 的 topFade）：透明的一条 SwiftUI 不把它当滚动软边的元素
                    Color.clear.frame(height: metrics.header.size.height)
                        .background { PaneTopFade() }
                        .allowsHitTesting(false)
                }
                // 同 PaneWindow：标题栏后面是系统滚动软边，底边不要
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectHidden(true, for: .bottom)
        }
    }
}

/// 原生标题栏的信息区：会话的状态圆环，所属工作机的连接提示优先于会话自己的错误，提示出现时虚化盖住。
private struct ThreadHeaderStatusRoot: View {
    let openSidebar: (@MainActor () -> Void)?
    @Environment(WorkThread.self) private var thread
    @Environment(\.paneConnectionNotice) private var connectionNotice

    var body: some View {
        PhoneHeaderStatusRoot(status: ThreadStatusRing().environment(\.paneNotice, connectionNotice ?? thread.problem.map(PaneNotice.failure)),
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
