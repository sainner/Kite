#if os(macOS)
import AppKit
import SwiftUI

/// Mac 宽屏会话窗口的底栏，原生版：替代 PaneControlsBar 套 ThreadControls 的整块 SwiftUI。拖缝改宽时它每帧跟着改尺寸，
/// 整块 SwiftUI 子树每步约 2.2ms 一个窗口（2026-10-13 测量，两窗换成空白帧间隔中位就到 16.7ms），原生的只按宽度重摆。
/// 外观、行为逐项照 SwiftUI 版（ThreadControls、PaneControlsBar、PaneButtonStyle），逻辑共用 ThreadControlsModel；
/// 思考强度控件留在 SwiftUI（ThreadEffortControl），放进一个按自己大小摆的托管视图，只在它自己改宽时重排。
/// iPhone、iPad 和 Mac 窄窗口（紧凑布局，底栏由外壳统一显示）仍用 SwiftUI 版。
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
                // 宽屏上只有标题栏的侧栏按钮用它先收起输入；点别处、Esc 都是 AppKit 的第一响应者照常处理，SwiftUI 版的输入框也是 NSTextField
                .focused(typing)
                // 同 ThreadControls：交互玻璃的同心形状有高光退回胶囊的复现，玻璃与交互轮廓统一用明确圆角
                .contentShape(.interaction, shape)
                .glassEffect(Self.glass, in: shape)
                .frame(maxWidth: Metrics.transcriptWidth)
        }
        // 同 PaneControlsBar 在宽屏上的样子：左右、底各留 paneMargin，玻璃最宽 transcriptWidth 居中，玻璃以外不接点击
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

    private static var glass: Glass {
        #if DEBUG
        if ControlsBarVariant.noGlass { return .identity }
        #endif
        return .regular.interactive()
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

    /// 高按给的宽当场原生量；里面变高变矮（多一行、横排换竖排、思考强度改宽）时 ControlsBarView 让 SwiftUI 重新量。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ControlsBarView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

/// 玻璃里的内容，和玻璃一样大，圆角以外不接点击。照 ThreadControls 的版式：输入框左右留 controlInset + 8、上下 6，
/// 下面一行思考强度和按钮，放不下时思考强度单独一行。在空白处按下不拖窗口。
final class ControlsBarView: NSView {
    private let field = ComposerField()
    private let fadingView = FadingSnapshotView()
    private let effort = EffortIsland(rootView: AnyView(EmptyView()))
    private let attach = PaneButtonView()
    private let voice = PaneButtonView()
    private let stop = PaneButtonView()
    private let resume = PaneButtonView()
    private let send = PaneButtonView()

    private var controls: ThreadControlsModel?
    private var enabled = true
    private var effortKey: EffortKey?
    /// 思考强度的理想大小，托管视图报大小变了再量。
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
        for button in [attach, voice, stop, resume, send] { addSubview(button) }
        effort.sizingOptions = [.intrinsicContentSize]
        effort.sizeChanged = { [weak self] in
            self?.effortSize = nil
            self?.contentChanged()
        }

        attach.label = .symbol("paperclip")
        attach.title = "添加附件"
        attach.isEnabled = false
        stop.label = .symbol("stop.fill")
        stop.fill = Theme.strongPlaceholder
        stop.title = "停止"
        resume.label = .text("继续")
        resume.title = "继续"
        send.label = .symbol("arrow.up")
        send.fill = .accentColor
        send.title = "发送"
        voice.action = { [weak self] in self?.controls?.toggleVoice() }
        stop.action = { [weak self] in self?.controls?.stop() }
        resume.action = { [weak self] in self?.controls?.resume() }
        send.action = { [weak self] in self?.submit() }
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
        let body = Theme.body.resolve(in: environment.fontResolutionContext).ctFont as NSFont
        if field.font != body { field.font = body }
        for button in [attach, voice, stop, resume, send] { button.setFont(body) }
        if buttonsEnvironment != environment.colorScheme {
            buttonsEnvironment = environment.colorScheme
            for button in [attach, voice, stop, resume, send] { button.environment = environment }
        }
        let key = EffortKey(controls: controls, enabled: enabled, colorScheme: environment.colorScheme)
        if key != effortKey {
            effortKey = key
            effort.rootView = AnyView(ThreadEffortControl(controls: controls).environment(\.self, environment))
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
        stop.isHidden = !controls.showsStop
        stop.isEnabled = enabled && thread.canStop
        resume.isHidden = !controls.showsResume
        resume.isEnabled = enabled && thread.canResume
        send.isHidden = !controls.showsSend
        send.isEnabled = enabled && thread.canSend
        let fading = controls.state.fading
        field.alphaValue = fading == nil ? 1 : 0
        if fading == nil { shownFading = nil }
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
    /// 按视图层级换算，和 SwiftUI 版在托管正文里取的 .global 一样：正文的托管视图摆在窗口原点上（见 HostedContentContainer），
    /// 飞行中的缩放平移只在图层上，换算按停着的位置。窗口的内容视图没翻转时上下翻过来，同 MouseDragArea。
    private var glassFrameInWindow: CGRect {
        guard let root = window?.contentView else { return .zero }
        var frame = convert(bounds, to: root)
        if !root.isFlipped { frame.origin.y = root.bounds.height - frame.maxY }
        return frame
    }

    // MARK: - 排版

    /// 版式常量，照 ThreadControls：输入框左右 controlInset + 8、上下 6；输入框和按钮行之间 2；按钮行左右、底 controlButtonInset；
    /// 顶 controlInset。附件、语音一组间距 0，和后面的停止、继续、发送间距 4；横排时思考强度和按钮组之间至少两个按钮间距。
    private static let fieldInset = Metrics.controlInset + 8
    private static let fieldPadding: CGFloat = 6
    private static let rowSpacing: CGFloat = 2

    private struct Plan {
        var height: CGFloat
        var field: CGFloat
        var effort: CGSize
        var stacked: Bool
    }

    /// 给 SwiftUI 的高：玻璃的高。
    func height(forWidth width: CGFloat) -> CGFloat {
        let height = plan(width: width).height
        reported = (width, height)
        return height
    }

    private func plan(width: CGFloat) -> Plan {
        let width = max(width, 0)
        let fieldWidth = max(width - 2 * Self.fieldInset, 0) + 2 * ComposerField.fieldInset
        var fieldHeight = field.height(width: fieldWidth, text: field.text)
        if let fading = controls?.state.fading { fieldHeight = max(fieldHeight, fading.height) }
        let effortSize = currentEffortSize
        let rowWidth = width - 2 * Metrics.controlButtonInset
        let stacked = effortSize.width + 2 * Metrics.paneButtonGap + buttonsWidth > rowWidth
        let row = stacked ? effortSize.height + Self.rowSpacing + Metrics.paneButton : max(effortSize.height, Metrics.paneButton)
        let height = Metrics.controlInset + 2 * Self.fieldPadding + fieldHeight + Self.rowSpacing + row + Metrics.controlButtonInset
        return Plan(height: height, field: fieldHeight, effort: effortSize, stacked: stacked)
    }

    private var currentEffortSize: CGSize {
        if let effortSize { return effortSize }
        let size = effort.intrinsicContentSize
        effortSize = size
        return size
    }

    private var shownButtons: [PaneButtonView] { [stop, resume, send].filter { !$0.isHidden } }

    private var buttonsWidth: CGFloat {
        2 * Metrics.paneButton + shownButtons.reduce(0) { $0 + ThreadControls.actionGap + $1.width }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let plan = plan(width: width)

        let fieldWidth = max(width - 2 * Self.fieldInset, 0)
        let top = Metrics.controlInset + Self.fieldPadding
        place(field, CGRect(x: Self.fieldInset - ComposerField.fieldInset, y: top, width: fieldWidth + 2 * ComposerField.fieldInset,
                            height: field.drawHeight(width: fieldWidth + 2 * ComposerField.fieldInset, text: field.text)))
        place(fadingView, CGRect(x: field.frame.minX, y: top, width: field.frame.width, height: plan.field))

        var rowTop = top + plan.field + Self.fieldPadding + Self.rowSpacing
        let inset = Metrics.controlButtonInset
        let buttonsHeight = Metrics.paneButton
        if plan.stacked {
            place(effort, CGRect(x: inset, y: rowTop, width: plan.effort.width, height: plan.effort.height))
            rowTop += plan.effort.height + Self.rowSpacing
        } else {
            let row = max(plan.effort.height, buttonsHeight)
            place(effort, CGRect(x: inset, y: rowTop + (row - plan.effort.height) / 2, width: plan.effort.width, height: plan.effort.height))
            rowTop += (row - buttonsHeight) / 2
        }
        var x = width - inset
        for button in shownButtons.reversed() {
            x -= button.width
            place(button, CGRect(x: x, y: rowTop, width: button.width, height: buttonsHeight))
            x -= ThreadControls.actionGap
        }
        for button in [voice, attach] {
            x -= Metrics.paneButton
            place(button, CGRect(x: x, y: rowTop, width: Metrics.paneButton, height: buttonsHeight))
        }
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

/// 思考强度的托管视图，按自己的理想大小摆；刻度展开、收起时自己改宽，通知底栏重排。
private final class EffortIsland: NSHostingView<AnyView> {
    var sizeChanged: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        sizeChanged?()
    }
}
#endif
