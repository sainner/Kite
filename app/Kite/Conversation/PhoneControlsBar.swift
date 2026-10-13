#if os(iOS)
import SwiftUI
import UIKit

/// iPhone、iPad 会话窗口的输入区：玻璃和里面的内容，和玻璃一样大，圆角以外不接点按。原生会话窗口（PhoneThreadWindowView）
/// 和紧凑布局的外壳直接挂它，拖缝改宽时只按宽度重摆。版式同 Mac 的输入区：输入框左右留 controlInset + 8、上下 6，
/// 下面一行思考强度和按钮，放不下时思考强度单独一行。玻璃是 UIKit 的交互玻璃（UIGlassEffect，圆角 controlRadius）。
/// 逻辑共用 ThreadControlsModel；思考强度留在 SwiftUI（ThreadEffortControl），放进一个按自己大小摆的托管视图，只在它自己改宽时重排。
final class ControlsBarView: UIView {
    private let glass: UIVisualEffectView
    private let field = ComposerField.make()
    private let fadingView = FadingSnapshotView()
    private let effort = EffortHost(rootView: AnyView(EmptyView()))
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
    /// 跟着会话、App 模型和 state 变，见 refresh。
    private let tracking = ModelTracking()
    /// 正在播的发送淡出。
    private var shownFading: UUID?
    /// 上次报出去的高，按宽记：里面变了才让外面重新量。
    private var reported: (width: CGFloat, height: CGFloat)?
    /// 里面变高变矮了，外面重新量、重摆。
    var heightChanged: (() -> Void)?
    /// 输入框成为、交出第一响应者。
    var focusChanged: ((Bool) -> Void)? {
        get { field.focusChanged }
        set { field.focusChanged = newValue }
    }
    /// 正在打字（输入框是第一响应者）。
    var typing: Bool { field.isFirstResponder }
    /// 思考强度占的地方（本视图坐标）：紧凑布局里从这里起手的横拖留给它自己调档，不切窗口（同 reservesPaneSwipe）。
    var effortFrame: CGRect { effort.view.frame }

    init() {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        glass = UIVisualEffectView(effect: effect)
        super.init(frame: .zero)
        // 交互玻璃的同心形状有高光退回胶囊的复现；玻璃用明确的圆角
        glass.cornerConfiguration = .corners(radius: .fixed(Metrics.controlRadius))
        addSubview(glass)
        let content = glass.contentView
        content.addSubview(field)
        content.addSubview(fadingView)
        content.addSubview(effort.view)
        effort.view.backgroundColor = .clear
        effort.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
        effort.safeAreaRegions = []
        effort.sizeChanged = { [weak self] in
            self?.effortSize = nil
            self?.contentChanged()
        }
        for button in [attach, voice, stop, resume, send] { content.addSubview(button) }

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
        voice.action = { [weak self] in self?.toggleVoice() }
        stop.action = { [weak self] in self?.controls?.stop() }
        resume.action = { [weak self] in self?.controls?.resume() }
        send.action = { [weak self] in self?.submit() }
        field.textChanged = { [weak self] text in
            guard let self, let thread = controls?.thread else { return }
            if thread.draft != text { thread.draft = text }
            contentChanged()
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in self.fontChanged() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(controls: ThreadControlsModel, enabled: Bool, environment: EnvironmentValues) {
        self.controls = controls
        self.enabled = enabled
        if self.environment?.colorScheme != environment.colorScheme || self.environment == nil {
            for button in [attach, voice, stop, resume, send] { button.environment = environment }
        }
        self.environment = environment
        fontChanged()
        let key = EffortKey(controls: controls, enabled: enabled, colorScheme: environment.colorScheme, typeSize: environment.dynamicTypeSize)
        if key != effortKey {
            effortKey = key
            effort.rootView = AnyView(ThreadEffortControl(controls: controls)
                .disabled(!enabled)
                .environment(\.self, environment))
            effortSize = nil
        }
        refresh()
    }

    /// 字体跟着环境里的正文字号（动态字体）。
    private var environment: EnvironmentValues?

    private func fontChanged() {
        let body = environment.map { Theme.body.resolve(in: $0.fontResolutionContext).ctFont as UIFont }
            ?? UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        field.applyFont(body)
        for button in [attach, voice, stop, resume, send] { button.setFont(body) }
        contentChanged()
    }

    /// 窗口把打字设成假：交出焦点，键盘收起。
    func endTyping() {
        if field.isFirstResponder { _ = field.resignFirstResponder() }
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
        field.setText(thread.draft)
        field.isEditable = enabled
        field.isUserInteractionEnabled = enabled
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
        field.alpha = fading == nil ? 1 : 0
        if fading == nil { shownFading = nil }
        // 失败提示
        if let error = controls.state.effortError { present("修改思考强度失败", error) { controls.state.effortError = nil } }
        if let error = controls.state.voiceError { present("无法开始语音输入", error) { controls.state.voiceError = nil } }
    }

    /// 弹出的提示，同一条不弹两次。
    private var presenting: String?

    private func present(_ title: String, _ message: String, dismissed: @escaping @MainActor () -> Void) {
        guard presenting == nil else { return }
        presenting = title
        // 不在这次排版、观察的回调里弹
        DispatchQueue.main.async { [weak self] in
            guard let self, var host = window?.rootViewController else {
                self?.presenting = nil
                dismissed()
                return
            }
            while let top = host.presentedViewController { host = top }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .cancel) { [weak self] _ in
                self?.presenting = nil
                dismissed()
            })
            host.present(alert, animated: true)
        }
    }

    private func toggleVoice() {
        // 收起键盘，窗口底部随声音起伏的签名才露得出来
        controls?.toggleVoice { [weak self] in self?.endTyping() }
    }

    private func submit() {
        guard let controls, controls.canSubmit, enabled else { return }
        controls.submit(from: glassFrameInWindow, fieldHeight: field.frame.height)
        guard let fading = controls.state.fading, fading.id != shownFading else { return }
        shownFading = fading.id
        fadingView.fade(fading)
        apply(controls)
        contentChanged()
    }

    /// 玻璃在窗口坐标（SwiftUI 的 .global）中的位置，发送时点阵的波从这里推开，DotScope.frame 也是这个坐标。
    private var glassFrameInWindow: CGRect {
        guard let window else { return .zero }
        return glass.convert(glass.bounds, to: window)
    }

    // MARK: - 排版

    /// 版式常量：输入框左右 controlInset + 8、上下 6；输入框和按钮行之间 2；按钮行左右、底 controlButtonInset；
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

    /// 玻璃的高。
    func height(forWidth width: CGFloat) -> CGFloat {
        let height = plan(width: width).height
        reported = (width, height)
        return height
    }

    private func plan(width: CGFloat) -> Plan {
        let width = max(width, 0)
        let fieldWidth = max(width - 2 * Self.fieldInset, 0)
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
        let size = effort.view.intrinsicContentSize
        effortSize = size
        return size
    }

    private var shownButtons: [PaneButtonView] { [stop, resume, send].filter { !$0.isHidden } }

    private var buttonsWidth: CGFloat {
        2 * Metrics.paneButton + shownButtons.reduce(0) { $0 + ThreadControlsModel.actionGap + $1.width }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let plan = plan(width: width)
        place(glass, bounds)

        let fieldWidth = max(width - 2 * Self.fieldInset, 0)
        let top = Metrics.controlInset + Self.fieldPadding
        place(field, CGRect(x: Self.fieldInset, y: top, width: fieldWidth, height: field.height(width: fieldWidth, text: field.text)))
        place(fadingView, CGRect(x: Self.fieldInset, y: top, width: fieldWidth, height: plan.field))

        var rowTop = top + plan.field + Self.fieldPadding + Self.rowSpacing
        let inset = Metrics.controlButtonInset
        let buttonsHeight = Metrics.paneButton
        if plan.stacked {
            place(effort.view, CGRect(x: inset, y: rowTop, width: plan.effort.width, height: plan.effort.height))
            rowTop += plan.effort.height + Self.rowSpacing
        } else {
            let row = max(plan.effort.height, buttonsHeight)
            place(effort.view, CGRect(x: inset, y: rowTop + (row - plan.effort.height) / 2, width: plan.effort.width, height: plan.effort.height))
            rowTop += (row - buttonsHeight) / 2
        }
        var x = width - inset
        for button in shownButtons.reversed() {
            x -= button.width
            place(button, CGRect(x: x, y: rowTop, width: button.width, height: buttonsHeight))
            x -= ThreadControlsModel.actionGap
        }
        for button in [voice, attach] {
            x -= Metrics.paneButton
            place(button, CGRect(x: x, y: rowTop, width: Metrics.paneButton, height: buttonsHeight))
        }
    }

    /// 四边取整到像素再摆，同 SwiftUI（输入框 8 行以上时高带小数）；和现在一样就不设：拖缝时每步都排，多数子视图只有横向位置在变。
    private func place(_ view: UIView, _ frame: CGRect) {
        let scale = max(traitCollection.displayScale, 1)
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let minX = pixel(frame.minX), minY = pixel(frame.minY)
        let rounded = CGRect(x: minX, y: minY, width: pixel(frame.maxX) - minX, height: pixel(frame.maxY) - minY)
        if view.frame != rounded { view.frame = rounded }
    }

    /// 里面变了（行数、按钮、思考强度的宽）：高变了让外面重新量，没变只重摆。
    private func contentChanged() {
        setNeedsLayout()
        guard let reported, plan(width: reported.width).height != reported.height else { return }
        heightChanged?()
    }

    /// 玻璃的圆角以外不接点按，后面的内容照常可点。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        UIBezierPath(roundedRect: bounds, cornerRadius: Metrics.controlRadius).contains(point)
    }

    /// 思考强度的托管视图里放的东西：实例的模型配置、能不能改、外观变了才换。
    private struct EffortKey: Equatable {
        let instance: String?
        let model: AgentModelConfiguration?
        let enabled: Bool
        let colorScheme: ColorScheme
        let typeSize: DynamicTypeSize

        init(controls: ThreadControlsModel, enabled: Bool, colorScheme: ColorScheme, typeSize: DynamicTypeSize) {
            instance = controls.instance?.id
            model = controls.instance?.config?.agent?.model
            self.enabled = enabled
            self.colorScheme = colorScheme
            self.typeSize = typeSize
        }
    }
}

/// 思考强度的托管视图，按自己的理想大小摆；刻度展开、收起时自己改宽，通知底栏重排。
private final class EffortHost: UIHostingController<AnyView> {
    var sizeChanged: (() -> Void)?

    override var preferredContentSize: CGSize {
        didSet { if preferredContentSize != oldValue { sizeChanged?() } }
    }
}
#endif
