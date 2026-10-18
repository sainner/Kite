#if os(macOS)
import AppKit
import SwiftUI

/// Mac 宽屏会话窗口的外框（窄窗口是 SwiftUI 的 ThreadPane）。拖缝改宽时它每步跟着改尺寸，
/// 原生的对话列表直接挂在这里（不再经过 MacTranscript 和窗口的 SwiftUI 根），标题栏和输入区各是一个托管视图，只按宽度重摆；
/// 空会话的签名、录音时底部那一带是铺满窗口的托管视图，只在有它们时才在；调试模式的原始记录是夹在标题栏和输入区之间的托管视图，开着时代替对话。
/// 层次从下到上：签名或那一带、对话、原始记录、输入区、标题栏。
/// 标题栏的托管视图里照样用 safeAreaBar，SwiftUI 照旧给它建滚动软边的容器，对话列表登记它（见 registerPanePockets）。
/// 这个托管视图从窗口原点铺起，标题栏按正文在窗口里的位置摆进去（同 HostedContentContainer）：软边按窗口坐标比对浮在上面的控件，
/// 托管视图的原点不在窗口左上角时对不上，软边当作上面没有东西，不再模糊（2026-10-13 对照时看到字直接透出标题栏）。
/// 行为照 ThreadPane 和 PaneWindow，状态和动作共用 ThreadPaneModel；坐标照卡片正文：左上角是正文原点（点阵按 DotCarrier.space）。
final class ThreadWindowView: NSView {
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

    private let backdrop = ThreadIsland()
    private let list = TranscriptListView()
    private let raw = ThreadIsland()
    private let controls = ThreadIsland()
    private let headerIsland = ThreadIsland()
    private let controlsLink = ControlsBarLink()
    private let metrics = ThreadWindowMetrics()
    /// 窗口的范围（正文坐标），交给铺满窗口的签名，同 PaneWindow 的 paneWindowFrame。
    private let windowFrame = PaneWindowFrame()

    private let tracking = ModelTracking()
    private let rowsTracking = ModelTracking()
    private var rowsDirty = true
    private var laying = false
    /// 底栏玻璃在这个视图里的范围，输入区的托管视图只在这里面接点击。
    private var glass = CGRect.zero
    /// 这个视图左上角在窗口里的位置（左上角起），卡片按正文停着的位置给；标题栏的托管视图按它对齐窗口原点。
    var windowOrigin = CGPoint.zero {
        didSet { if windowOrigin != oldValue { needsLayout = true } }
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

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
        list.pocketScope = headerIsland
        for view in [backdrop, list, raw, controls, headerIsland] as [NSView] { addSubview(view) }
        backdrop.isHidden = true
        list.isHidden = true
        raw.isHidden = true
        headerIsland.hitRegion = { [weak self] in self.map { CGRect(x: 0, y: 0, width: $0.bounds.width, height: $0.headerHeight) } }
        headerIsland.hitSpace = self
        controls.hitRegion = { [weak self] in self?.glass }
        controls.hitRadius = Metrics.controlRadius
        controlsLink.changed = { [weak self] in self?.invalidate() }
        installIslands()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 环境变了（外观、屏幕倍数、减少动态效果、字号、引用跳转的范围……）或窗口组换了：几个托管视图重新交环境，对话的行也换上新环境。
    func environmentChanged(_ environment: EnvironmentValues, group: PaneGroup) {
        self.environment = environment
        self.group = group
        installIslands()
        rowsDirty = true
        needsLayout = true
    }

    private func installIslands() {
        let roots = ThreadIslandEnvironment(group: group, pane: paneID, header: header, model: pane)
        headerIsland.rootView = rooted(ThreadHeaderRoot(pane: pane, header: header, regions: regions, motion: motion) { [weak self] in
            self?.endTyping()
        }.modifier(roots).modifier(ThreadHeaderPlacement(metrics: metrics)))
        controls.rootView = rooted(ThreadControlsRoot(pane: pane, link: controlsLink).modifier(roots))
        backdrop.rootView = rooted(ThreadBackdropRoot(pane: pane, metrics: metrics, windowFrame: windowFrame, reports: reports).modifier(roots))
        raw.rootView = rooted(ThreadRawRoot().modifier(roots))
    }

    private func rooted(_ view: some View) -> AnyView {
        AnyView(view
            .containerShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
            .environment(\.self, environment))
    }

    func dismantle() {
        tracking.cancel()
        rowsTracking.cancel()
        controlsLink.changed = nil
        for island in [headerIsland, controls, backdrop, raw] {
            island.hitRegion = nil
            island.rootView = AnyView(EmptyView())
        }
        if pane.scroll.list === list { pane.scroll.list = nil }
    }

    // MARK: - 对话的行

    /// 读会话记录、选中的行、刚发出的消息，变了标记重排；在排版里读，交给列表在观察之外，见 layout。
    /// 通知在属性改之前，不能当场读；也不能下一拍再读：排版可能抢在那一拍前头，把旧的行交给列表。
    /// 空会话发第一条时就是这样，列表的版本先变了，发送的那一下没等到新消息就滑，气泡不浮入。
    private func readRows() -> [TranscriptRow] {
        let thread = thread, pane = pane
        return rowsTracking.track({ pane.transcriptRows(of: thread) }) { [weak self] in
            self?.rowsDirty = true
            self?.invalidate()
        }
    }

    /// 行看到的环境，同 MacThreadTranscript 交给 MacTranscript 的。
    private var rowContext: TranscriptRowContext { pane.rowContext(environment: environment, thread: thread) }

    // MARK: - 排版

    private struct State {
        var initial: Bool
        var empty: Bool
        var listening: Bool
        var raw: Bool
        var headerHeight: CGFloat
    }

    /// 标题栏报上来的高；还没报时按一个按钮高加上下留白先摆。
    private var headerHeight: CGFloat {
        header.height > 0 ? header.height : Metrics.paneHeaderButton + 2 * Metrics.paneMargin
    }

    override func layout() {
        super.layout()
        laying = true
        defer { laying = false }
        let state = tracking.track({
            State(initial: thread.isInitial, empty: !thread.hasTranscript, listening: pane.listening(model), raw: thread.raw != nil,
                  headerHeight: headerHeight)
        }) { [weak self] in self?.invalidate() }
        let width = bounds.width, height = bounds.height

        // 输入区：同 MacControlsBar，左右、底各留 paneMargin，玻璃最宽 transcriptWidth 居中；高按宽度原生量
        let margin = Metrics.paneMargin
        let glassWidth = max(min(Metrics.transcriptWidth, width - 2 * margin), 0)
        let glassHeight = controlsLink.view?.height(forWidth: glassWidth) ?? Metrics.paneToolbarHeight + 2 * Metrics.controlInset
        let barHeight = glassHeight + margin
        place(controls, CGRect(x: 0, y: height - barHeight, width: width, height: barHeight))
        glass = CGRect(x: (width - glassWidth) / 2, y: height - barHeight, width: glassWidth, height: glassHeight)
        if metrics.controlsHeight != barHeight { metrics.controlsHeight = barHeight }

        // 从窗口原点铺到标题栏的右下角，标题栏摆在正文的位置上
        let origin = windowOrigin
        place(headerIsland, CGRect(x: -origin.x, y: -origin.y, width: max(origin.x + width, 0), height: max(origin.y + state.headerHeight, 0)))
        let placement = ThreadWindowMetrics.Header(origin: origin, size: CGSize(width: width, height: state.headerHeight))
        if metrics.header != placement { metrics.header = placement }
        let window = CGRect(origin: .zero, size: bounds.size)
        if windowFrame.rect != window { windowFrame.rect = window }

        // 空会话的签名、录音时底部那一带：有它们时才铺满窗口
        let backdropShown = (state.initial && !state.raw) || (state.listening && !state.empty)
        backdrop.isHidden = !backdropShown
        if backdropShown { place(backdrop, bounds) }

        // 原始记录不从标题栏、输入区后面滚过：它在另一个托管视图里，标题栏的滚动软边管不到它
        raw.isHidden = !state.raw
        if state.raw { place(raw, CGRect(x: 0, y: state.headerHeight, width: width, height: max(height - state.headerHeight - barHeight, 0))) }

        list.isHidden = state.empty || state.raw
        place(list, bounds)
        // 标题栏的托管视图排在列表后面，列表头几次排版时它还没建好软边的那一条；标题栏报上高以后这里再排，让列表接着登记
        if !list.pocketsRegistered { list.needsLayout = true }
        // 空会话也交：列表藏着时照样排版，见 TranscriptListView.setInsets
        list.setInsets(NSEdgeInsets(top: state.headerHeight, left: 0, bottom: barHeight, right: 0))
        if rowsDirty, !state.empty {
            rowsDirty = false
            list.update(readRows(), context: rowContext)
        }
    }

    /// 排版当中改了读过的模型：这一轮排完 AppKit 会清掉 needsLayout，下一拍再标一次（同 StageView）。
    private func invalidate() {
        needsLayout = true
        guard laying else { return }
        DispatchQueue.main.async { [weak self] in self?.needsLayout = true }
    }

    private func place(_ view: NSView, _ frame: CGRect) {
        if view.frame != frame { view.frame = frame }
    }

    /// 标题栏的侧栏按钮先收起输入：输入框在打字时交出焦点，同 PaneWindow 的 typing。
    private func endTyping() {
        guard let window, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView, field.isDescendant(of: controls) else { return }
        window.makeFirstResponder(nil)
    }

    // MARK: - 读屏

    /// 读屏顺序按看的顺序：标题栏、（空会话的说明）、对话或原始记录、输入区；子视图的叠放是反过来的。
    override func accessibilityChildren() -> [Any]? {
        [headerIsland, backdrop, list, raw, controls].filter { !$0.isHidden }
    }

    // MARK: - 指针

    /// 指针在整个窗口里移动（含标题栏、输入区），空会话的签名都跟着，同 ThreadPane 的 onContinuousHover：位置用窗口坐标。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseEntered(with event: NSEvent) { pointer(event) }

    override func mouseExited(with event: NSEvent) {
        environment.dotStage?.patternPointer(nil, slot: pane.patternSlot)
    }

    private func pointer(_ event: NSEvent) {
        guard let content = window?.contentView else { return }
        var point = content.convert(event.locationInWindow, from: nil)
        if !content.isFlipped { point.y = content.bounds.height - point.y }
        environment.dotStage?.patternPointer(point, slot: pane.patternSlot)
    }
}

/// 窗口里铺满或按宽度摆的托管视图（标题栏、输入区、空会话的签名）。只在 hitRegion 里接点击，其余的点落到下面的对话上。
final class ThreadIsland: NSHostingView<AnyView> {
    /// 接点击的范围，在 hitSpace（不给就是上一层）的坐标里。
    var hitRegion: (() -> CGRect?)?
    weak var hitSpace: NSView?
    /// 接点击的范围按圆角算（输入区的玻璃）。
    var hitRadius: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(rootView: AnyView(EmptyView()))
        sizingOptions = []
        safeAreaRegions = []
    }

    @MainActor required init(rootView: AnyView) { fatalError("init(rootView:) has not been implemented") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 里面的原生视图（输入区的输入框、按钮）的光标：cursorUpdate 交给的是托管视图里面 SwiftUI 的视图，往外传经过这里，见 NativeCursor。
    override func cursorUpdate(with event: NSEvent) {
        if let cursor = nativeCursorUnderPointer() { cursor.set() } else { super.cursorUpdate(with: event) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        if let hitRegion {
            guard let region = hitRegion(), let space = hitSpace ?? self.superview else { return nil }
            let local = space.convert(point, from: superview)
            guard NSBezierPath(roundedRect: region, xRadius: hitRadius, yRadius: hitRadius).contains(local) else { return nil }
        }
        return super.hitTest(point)
    }
}

/// 调试模式的原始记录，见 RawTranscript。
private struct ThreadRawRoot: View {
    @Environment(WorkThread.self) private var thread

    var body: some View {
        if let raw = thread.raw { RawTranscriptView(raw: raw) }
    }
}

/// 输入区：Mac 宽屏的原生输入区（MacControlsBar），贴着窗口底边。建草稿窗口中、配置模板中整块禁用。
private struct ThreadControlsRoot: View {
    let pane: ThreadPaneModel
    let link: ControlsBarLink
    @Environment(WorkThread.self) private var thread
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @FocusState private var typing: Bool

    var body: some View {
        MacControlsBar(typing: $typing, send: { message, alongside in
            pane.send(message, thread: thread, model: model, area: area, alongside: alongside)
        }, voiceOwner: pane.patternSlot, link: link)
        .disabled(area.creatingWindow != nil || thread.configuringTemplate)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

#endif
