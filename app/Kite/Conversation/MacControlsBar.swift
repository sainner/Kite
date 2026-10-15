#if os(macOS)
import AppKit
import SwiftUI

/// Mac 宽屏会话窗口（ThreadWindowView）的底栏：玻璃里是原生的输入框和按钮（ControlsBarView），拖缝改宽时只按宽度重摆
/// （整块 SwiftUI 子树每步约 2.2ms 一个窗口，2026-10-13 测量）。版式同 Mac 窄窗口的 ThreadControls：输入框左右留 controlInset + 8、
/// 上下 6，下面一行思考强度和按钮，放不下时隐藏按钮组；逻辑共用 ThreadControlsModel。
/// 思考强度控件留在 SwiftUI（ThreadEffortControl），放进一个按自己大小摆的托管视图，只在它自己改宽时重排。
struct MacControlsBar: View {
    var typing: FocusState<Bool>.Binding
    /// 发一条消息；第二个参数和对话往上滑在同一次更新里调。
    let send: (Message, _ alongside: @escaping () -> Void) -> Void
    /// 这个窗口录语音时的标识，见 VoiceInput.owner。
    let voiceOwner: String
    /// 原生的会话窗口外框（ThreadWindowView）从这里拿到底栏，按宽度原生量高、知道里面变高变矮。
    var link: ControlsBarLink?
    @Environment(WorkThread.self) private var thread
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.paneInstance) private var instance
    @Environment(\.dotStage) private var stage
    @Environment(\.dotScope) private var dotScope
    // 显式读出来交给原生视图：只读 context.environment 时这几项变了不一定调 updateNSView
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var state = ThreadControlsState()

    /// 玻璃仍用 SwiftUI 的 glassEffect，原生的只是玻璃里的内容。2026-10-13 对照过 NSGlassEffectView（带不带容器、可不可按压）：
    /// 它改宽时 AppKit 在里面另跑一张 SwiftUI 图，两窗拖缝每步比这样多约 1ms；玻璃里的字也被它另做一层处理，和现版逐像素对不上，
    /// 这样包着则只剩图标的抗锯齿差别。macOS 26 上按下也有玻璃反馈。
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
        GlassEffectContainer(spacing: Metrics.paneButtonGap) {
            ControlsBarHost(controls: ThreadControlsModel(thread: thread, model: model, area: area, instance: instance, stage: stage,
                                                          scope: dotScope, voiceOwner: voiceOwner, state: state, send: send),
                            enabled: isEnabled, colorScheme: colorScheme, link: link)
                // 输入框有没有焦点照样记在窗口的 typing 上：原生输入框成为第一响应者时为真，窗口把它设成假时交出焦点（2026-10-13 实测）。
                // 宽屏上只有标题栏的侧栏按钮用它先收起输入；点别处、Esc 都是 AppKit 的第一响应者照常处理
                .focused(typing)
                // 交互玻璃的同心形状有高光退回胶囊的复现，玻璃与交互轮廓统一用明确圆角
                .contentShape(.interaction, shape)
                .glassEffect(.regular.interactive(), in: shape)
                .frame(maxWidth: Metrics.transcriptWidth)
        }
        // 左右、底各留 paneMargin，玻璃最宽 transcriptWidth 居中（同 PaneControlsBar 在宽屏上的样子），玻璃以外不接点击
        .padding(.horizontal, Metrics.paneMargin)
        .padding(.bottom, Metrics.paneMargin)
        .frame(maxWidth: .infinity)
        .alert("修改思考强度失败", isPresented: Binding(get: { state.effortError != nil }, set: { if !$0 { state.effortError = nil } })) {
            Button("好", role: .cancel) { state.effortError = nil }
        } message: { Text(state.effortError ?? "") }
        .alert("无法开始语音输入", isPresented: Binding(get: { state.voiceError != nil }, set: { if !$0 { state.voiceError = nil } })) {
            Button("好", role: .cancel) { state.voiceError = nil }
        } message: { Text(state.voiceError ?? "") }
    }
}

/// 原生外框和底栏之间的联系：底栏建好后交出来，里面变高变矮时通知。
@MainActor final class ControlsBarLink {
    fileprivate(set) weak var view: ControlsBarView?
    var changed: (() -> Void)?
}

private struct ControlsBarHost: NSViewRepresentable {
    let controls: ThreadControlsModel
    let enabled: Bool
    let colorScheme: ColorScheme
    let link: ControlsBarLink?

    func makeNSView(context: Context) -> ControlsBarView {
        let view = ControlsBarView()
        view.link = link
        link?.view = view
        // 外框先按估的高摆，建好了按实际的再量一次
        DispatchQueue.main.async { [weak link] in link?.changed?() }
        return view
    }

    func updateNSView(_ view: ControlsBarView, context: Context) {
        view.update(controls: controls, enabled: enabled, environment: context.environment)
    }

    /// 高按给的宽当场原生量；输入框行数改变时 ControlsBarView 让 SwiftUI 重新量。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ControlsBarView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

/// 玻璃里的内容，和玻璃一样大，圆角以外不接点击。照 ThreadControls 的版式：输入框左右留 controlInset + 8、上下 6，
/// 下面一行思考强度和按钮，放不下时隐藏按钮组。在空白处按下不拖窗口。
/// 思考强度的托管视图、输入框更新时不让外面的 SwiftUI 重量这一块（见 RepresentedRoot），高变了由 contentChanged 报。
final class ControlsBarView: RepresentedRoot {
    private let field = ComposerField()
    private let fadingView = FadingSnapshotView()
    private let effort = EffortIsland(rootView: AnyView(EmptyView()))
    private let attach = PaneButtonView()
    private let voice = PaneButtonView()
    private let primary = PaneButtonView()
    /// 等你回应时代替输入框的卡片（WaitingResponseCard），和输入框共用这张玻璃。
    private let response = NSHostingController(rootView: AnyView(EmptyView()))
    /// 卡片正在显示的等待；没有时显示输入框。
    private var shownWaiting: String?
    private var responseKey: WaitingResponseKey?
    private var environment: EnvironmentValues?

    private var controls: ThreadControlsModel?
    private var enabled = true
    private var effortKey: EffortKey?
    /// 思考强度的理想大小，由它自己的几何报（effortResized）；换了内容、还没报过时按固有尺寸量。
    private var effortSize: CGSize?
    /// 交给按钮解析颜色的环境，外观变了再换。
    private var buttonsEnvironment: ColorScheme?
    /// 跟着会话、App 模型和 state 变，见 refresh。
    private let tracking = ModelTracking()
    /// 正在播的发送淡出。
    private var shownFading: UUID?
    /// 上次报给 SwiftUI 的高，按宽记：里面变了才让它重新量。
    private var reported: (width: CGFloat, height: CGFloat)?
    fileprivate weak var link: ControlsBarLink?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: .zero)
        addSubview(field)
        addSubview(fadingView)
        addSubview(effort)
        for button in [attach, voice, primary] { addSubview(button) }
        effort.sizingOptions = [.intrinsicContentSize]
        response.sizingOptions = []
        response.view.alphaValue = 0
        response.view.isHidden = true
        addSubview(response.view)

        attach.label = .symbol("paperclip")
        attach.title = "添加附件"
        attach.isEnabled = false
        voice.action = { [weak self] in self?.controls?.toggleVoice() }
        primary.action = { [weak self] in
            guard let self, enabled else { return }
            controls?.performPrimaryAction(submit: submit)
        }
        field.submit = { [weak self] in self?.submit() }
        field.textChanged = { [weak self] text in
            guard let self, let thread = controls?.thread else { return }
            if thread.draft != text { thread.draft = text }
            contentChanged()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(controls: ThreadControlsModel, enabled: Bool, environment: EnvironmentValues) {
        self.controls = controls
        self.enabled = enabled
        self.environment = environment
        let body = Theme.body.resolve(in: environment.fontResolutionContext).ctFont as NSFont
        if field.font != body { field.font = body }
        for button in [attach, voice, primary] { button.setFont(body) }
        if buttonsEnvironment != environment.colorScheme {
            buttonsEnvironment = environment.colorScheme
            for button in [attach, voice, primary] { button.environment = environment }
        }
        let key = EffortKey(controls: controls, enabled: enabled, colorScheme: environment.colorScheme)
        if key != effortKey {
            effortKey = key
            // 刻度展开、收起时宽由 TimelineView 逐帧变，托管视图的固有尺寸不跟着逐帧报：框停在收着的宽，内容在框里居中、
            // 档位名被挤得换行，右边的刻度落在框外，指针移过去算移开（2026-10-14 Mac 实测）。按理想大小画、靠左，宽高由内容自己的几何报
            effort.rootView = AnyView(ThreadEffortControl(controls: controls)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] in self?.effortResized($0) }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .environment(\.self, environment))
            effortSize = nil
        }
        refresh()
    }

    /// 按模型摆一遍，读过的可观察属性变了再来一遍（同一时刻只挂一条登记，见 ModelTracking）。
    private func refresh() {
        guard let controls else { return }
        tracking.track({ apply(controls) }) { [weak self] in
            // 在属性改之前通知，到下一拍再读
            Task { @MainActor in self?.refresh() }
        }
        // 量高时托管的思考强度会跑 SwiftUI，不放在登记里面
        contentChanged()
    }

    private func apply(_ controls: ThreadControlsModel) {
        let thread = controls.thread
        field.placeholder = controls.placeholder
        // 读屏念的名字是占位文字，同 SwiftUI 的 TextField 以占位作标题
        if field.accessibilityLabel() != controls.placeholder { field.setAccessibilityLabel(controls.placeholder) }
        field.setText(thread.draft)
        field.isEnabled = enabled
        let listening = controls.listening
        voice.label = .symbol(listening ? "mic.fill" : "mic")
        voice.foreground = listening ? .accentColor : .secondary
        voice.title = listening ? "结束语音输入" : "语音输入"
        voice.isEnabled = enabled
        primary.label = .symbol(controls.primaryAction.symbol)
        primary.title = controls.primaryAction.title
        primary.fill = controls.primaryActionFill
        primary.isEnabled = enabled && controls.canPerformPrimaryAction
        showWaiting(thread.waiting, controls: controls)
        let fading = controls.state.fading
        field.alphaValue = fading == nil && shownWaiting == nil ? 1 : 0
        if fading == nil { shownFading = nil }
    }

    /// 出现审批或提问时输入框淡出、回应卡片淡入，回应后换回来；高由 contentChanged 报给外框。
    private func showWaiting(_ waiting: RemoteWaiting?, controls: ThreadControlsModel) {
        if let waiting {
            let thread = controls.thread
            let delegate = controls.delegate
            let key = WaitingResponseKey(waiting: waiting, canStop: thread.canStop, delegable: delegate != nil,
                                         colorScheme: environment?.colorScheme, dynamicTypeSize: environment?.dynamicTypeSize)
            if key != responseKey {
                responseKey = key
                response.rootView = AnyView(WaitingResponseCard(waiting: waiting, respond: { try await thread.respond(waiting, $0) },
                                                                stop: { thread.stop() }, canStop: thread.canStop, delegate: delegate)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] _ in self?.contentChanged() }
                    .environment(\.self, environment ?? EnvironmentValues()))
            }
        } else {
            responseKey = nil
        }
        guard waiting?.id != shownWaiting else { return }
        let entering = shownWaiting == nil
        shownWaiting = waiting?.id
        guard entering || waiting == nil else { return }
        if entering, field.currentEditor() != nil { window?.makeFirstResponder(nil) }
        let composer: [NSView] = [field, effort, attach, voice, primary]
        response.view.isHidden = false
        for view in composer { view.isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            response.view.animator().alphaValue = entering ? 1 : 0
            for view in composer { view.animator().alphaValue = entering ? 0 : 1 }
        }, completionHandler: { [weak self] in
            guard let self else { return }
            response.view.isHidden = shownWaiting == nil
            for view in composer { view.isHidden = shownWaiting != nil }
            needsLayout = true
        })
    }

    private func submit() {
        guard let controls, controls.canSubmit, enabled else { return }
        // 发送会清空草稿：先把字画下来，淡出时盖在原处
        let image = field.snapshot()
        controls.submit(from: glassFrameInWindow, fieldHeight: field.height(width: field.frame.width, text: field.text))
        guard let fading = controls.state.fading, fading.id != shownFading else { return }
        shownFading = fading.id
        fadingView.fade(fading, image: image, scale: window?.backingScaleFactor ?? 2)
        apply(controls)
        contentChanged()
    }

    /// 玻璃在窗口坐标（SwiftUI 的 .global：左上角起、往下为正）中的位置，发送时点阵的波从这里推开，DotScope.frame 也是这个坐标。
    /// 按视图层级换算，和 SwiftUI 在托管正文里取的 .global 一样：正文的托管视图摆在窗口原点上（见 HostedContentContainer），
    /// 飞行中的缩放平移只在图层上，换算按停着的位置。窗口的内容视图没翻转时上下翻过来，同 MouseDragArea。
    private var glassFrameInWindow: CGRect {
        guard let root = window?.contentView else { return .zero }
        var frame = convert(bounds, to: root)
        if !root.isFlipped { frame.origin.y = root.bounds.height - frame.maxY }
        return frame
    }

    // MARK: - 排版

    /// 版式见 ComposerLayout。给 SwiftUI 的高：玻璃的高。
    func height(forWidth width: CGFloat) -> CGFloat {
        let height = plan(width: width).height
        reported = (width, height)
        return height
    }

    private func plan(width: CGFloat) -> ComposerLayout.Plan {
        let width = max(width, 0)
        if shownWaiting != nil {
            let height = response.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
            return ComposerLayout.Plan(height: height, field: 0, effort: .zero, hidesActions: true)
        }
        let fieldWidth = max(width - 2 * ComposerLayout.fieldInset, 0) + 2 * ComposerField.fieldInset
        var fieldHeight = field.height(width: fieldWidth, text: field.text)
        if let fading = controls?.state.fading { fieldHeight = max(fieldHeight, fading.height) }
        return ComposerLayout.plan(width: width, field: fieldHeight, effort: currentEffortSize)
    }

    private var currentEffortSize: CGSize {
        if let effortSize { return effortSize }
        let size = effort.intrinsicContentSize
        effortSize = size
        return size
    }

    /// 思考强度改了大小（刻度展开、收起时逐帧）：重摆，高变了再报。
    private func effortResized(_ size: CGSize) {
        guard size != effortSize else { return }
        effortSize = size
        contentChanged()
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        place(response.view, bounds)
        guard shownWaiting == nil else { return }
        let plan = plan(width: width)

        let fieldWidth = max(width - 2 * ComposerLayout.fieldInset, 0)
        let top = ComposerLayout.fieldTop
        place(field, CGRect(x: ComposerLayout.fieldInset - ComposerField.fieldInset, y: top, width: fieldWidth + 2 * ComposerField.fieldInset,
                            height: field.drawHeight(width: fieldWidth + 2 * ComposerField.fieldInset, text: field.text)))
        place(fadingView, CGRect(x: field.frame.minX, y: top, width: field.frame.width, height: plan.field))

        let row = ComposerLayout.row(width: width, plan: plan)
        place(effort, row.effort)
        // 复用本次排版的宽度比较，只在跨过阈值时改变可见性；控件保留，effort 的手势不中断。
        for button in [attach, voice, primary] where button.isHidden != plan.hidesActions {
            button.isHidden = plan.hidesActions
        }
        guard !plan.hidesActions else { return }
        place(primary, row.primary)
        place(voice, row.voice)
        place(attach, row.attach)
    }

    /// 和现在一样就不设：拖缝时每步都排，多数子视图只有横向位置在变。
    private func place(_ view: NSView, _ frame: CGRect) {
        if view.frame != frame { view.frame = frame }
    }

    /// 里面变了（行数、按钮、思考强度的宽）：高变了让 SwiftUI 和原生外框重新量，没变只重摆。
    private func contentChanged() {
        needsLayout = true
        guard let reported, plan(width: reported.width).height != reported.height else { return }
        invalidateIntrinsicContentSize()
        link?.changed?()
    }

    /// 玻璃的圆角以外不接点击，后面的内容照常可点。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        let path = NSBezierPath(roundedRect: bounds, xRadius: Metrics.controlRadius, yRadius: Metrics.controlRadius)
        guard path.contains(local) else { return nil }
        return super.hitTest(point)
    }

    /// 思考强度的托管视图里放的东西：实例的模型配置、能不能改、外观变了才换。
    private struct EffortKey: Equatable {
        let instance: String?
        let model: AgentModelConfiguration?
        let enabled: Bool
        let colorScheme: ColorScheme

        init(controls: ThreadControlsModel, enabled: Bool, colorScheme: ColorScheme) {
            instance = controls.instance?.id
            model = controls.instance?.config?.agent?.model
            self.enabled = enabled
            self.colorScheme = colorScheme
        }
    }
}

/// 思考强度的托管视图，按里面报的理想大小摆。
private final class EffortIsland: NSHostingView<AnyView> {
    override var mouseDownCanMoveWindow: Bool { false }
}
#endif
