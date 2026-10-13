#if os(iOS)
import SwiftUI
import UIKit

/// iPhone、iPad 会话窗口的外框，原生版：替代 PaneWindow 套 ThreadPane 的整块 SwiftUI。拖缝改宽时它每步跟着改尺寸，
/// 输入区（ControlsBarView）直接挂在这里，只按宽度重摆；原生的对话列表（PhoneTranscriptView）和标题栏放在同一个岛里
/// （标题栏用 safeAreaBar，列表在它下面，SwiftUI 照旧给它们建滚动软边的容器，见 ThreadHeaderRoot），改宽时这个岛只排标题那一截
/// 和列表的大小，列表里面照旧自己排；标题栏两侧各在自己的托管视图里（见 WindowHeaderAnchored）。空会话的签名、录音时底部那一带
/// 是铺满窗口的岛，只在有它们时才在。层次从下到上：签名或那一带、标题栏和对话、输入区。
/// 行为照 ThreadPane 和 PaneWindow，状态和动作共用 ThreadPaneModel；结构照 Mac 的 ThreadWindowView。坐标照卡片正文：左上角是正文原点。
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
    /// 标题栏和它下面的对话列表。
    private let surface = HostIsland()
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
         header: PaneCardHeader, regions: HeaderRegions, reports: PaneCardBodyReports, motion: WindowMotion) {
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
        super.init(frame: .zero)
        pane.scroll.list = list
        for view in [backdrop, surface, controls] as [UIView] { addSubview(view) }
        backdrop.isHidden = true
        list.isHidden = true
        controls.heightChanged = { [weak self] in self?.invalidate() }
        installIslands()
        refreshRows()
        refreshControls()

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
        setNeedsLayout()
    }

    private func installIslands() {
        let roots = ThreadIslandEnvironment(group: group, pane: paneID, header: header, model: pane)
        surface.rootView = rooted(ThreadHeaderRoot(pane: pane, header: header, regions: regions, motion: motion,
                                                   below: AnyView(PhoneTranscriptSlot(list: list).ignoresSafeArea())) { [weak self] in
            self?.controls.endTyping()
        }.modifier(roots))
        backdrop.rootView = rooted(ThreadBackdropRoot(pane: pane, metrics: metrics, windowFrame: windowFrame, reports: reports).modifier(roots))
    }

    private func rooted(_ view: some View) -> AnyView {
        AnyView(view
            .containerShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
            .environment(\.self, environment))
    }

    func dismantle() {
        tracking.cancel()
        rowsTracking.cancel()
        controlsTracking.cancel()
        controls.heightChanged = nil
        for island in [surface, backdrop] {
            island.hitRegion = nil
            island.rootView = AnyView(EmptyView())
        }
        if pane.scroll.list === list { pane.scroll.list = nil }
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

    /// 行看到的环境：窗口的环境加上正文字号、刚发出的消息、选中的行、工作目录，同 PhoneThreadTranscript 交给 PhoneTranscript 的。
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
    }

    /// 标题栏报上来的高；还没报时按一个按钮高加上下留白先摆。
    private var headerHeight: CGFloat {
        header.height > 0 ? header.height : Metrics.paneHeaderButton + 2 * Metrics.paneMargin
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        laying = true
        defer { laying = false }
        let state = tracking.track({
            State(initial: pane.initial(thread), empty: !thread.hasTranscript, listening: pane.listening(model), headerHeight: headerHeight)
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
        if controls.typing, !controls.frame.contains(point) { controls.endTyping() }
        group.layout.focus(paneID)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: - 读屏

    /// 读屏顺序按看的顺序：标题栏和对话、（空会话的说明）、输入区。
    override var accessibilityElements: [Any]? {
        get { [surface, backdrop, controls].filter { !$0.isHidden } }
        set {}
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
