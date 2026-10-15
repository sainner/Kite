#if os(iOS)
import SwiftUI
import UIKit

/// iPhone、iPad 会话窗口的输入区：玻璃和里面的内容，和玻璃一样大，圆角以外不接点按。原生会话窗口（PhoneThreadWindowView）
/// 和紧凑布局的外壳直接挂它，拖缝改宽时只按宽度重摆。版式同 Mac 的输入区：输入框左右留 controlInset + 8、上下 6，
/// 下面一行思考强度和按钮，放不下时隐藏按钮组。玻璃是 UIKit 的交互玻璃（UIGlassEffect，圆角 controlRadius）。
/// 逻辑共用 ThreadControlsModel；思考强度留在 SwiftUI（ThreadEffortControl），放进一个按自己大小摆的托管视图，只在它自己改宽时重排。
final class ControlsBarView: UIView {
    private let glass: UIVisualEffectView
    private let field = ComposerField.make()
    private let fadingView = FadingSnapshotView()
    private let effort = EffortHost(rootView: AnyView(EmptyView()))
    private let attach = PaneButtonView()
    private let voice = PaneButtonView()
    private let primary = PaneButtonView()
    /// 等你回应时代替输入框的卡片（WaitingResponseCard），和输入框共用这张玻璃。
    private let response = UIHostingController(rootView: AnyView(EmptyView()))
    /// 卡片正在显示的等待；没有时显示输入框。
    private var shownWaiting: String?
    private var responseKey: WaitingResponseKey?

    private var controls: ThreadControlsModel?
    private var enabled = true
    private var effortKey: EffortKey?
    /// 思考强度的理想大小，由它自己的几何报（effortResized）；换了内容、还没报过时按固有尺寸量。
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

    init(glassManagedExternally: Bool = false) {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        glass = UIVisualEffectView(effect: glassManagedExternally ? nil : effect)
        super.init(frame: .zero)
        // 交互玻璃的同心形状有高光退回胶囊的复现；玻璃用明确的圆角
        glass.cornerConfiguration = .corners(radius: .fixed(Metrics.controlRadius))
        addSubview(glass)
        let content = glass.contentView
        content.addSubview(field)
        content.addSubview(fadingView)
        content.addSubview(effort.view)
        effort.view.backgroundColor = .clear
        effort.sizingOptions = [.intrinsicContentSize]
        effort.safeAreaRegions = []
        for button in [attach, voice, primary] { content.addSubview(button) }
        response.view.backgroundColor = .clear
        response.safeAreaRegions = []
        response.sizingOptions = []
        response.view.alpha = 0
        response.view.isHidden = true
        content.addSubview(response.view)

        attach.label = .symbol("paperclip")
        attach.title = "添加附件"
        attach.isEnabled = false
        voice.action = { [weak self] in self?.toggleVoice() }
        primary.action = { [weak self] in
            guard let self, enabled else { return }
            controls?.performPrimaryAction(submit: submit)
        }
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
            for button in [attach, voice, primary] { button.environment = environment }
        }
        self.environment = environment
        fontChanged()
        let key = EffortKey(controls: controls, enabled: enabled, colorScheme: environment.colorScheme, typeSize: environment.dynamicTypeSize)
        if key != effortKey {
            effortKey = key
            // 同 Mac 的输入区：刻度展开、收起时宽由 TimelineView 逐帧变，托管视图报的大小不跟着逐帧变，框停在收着的宽时
            // 档位名被挤得换行、右边的刻度落在框外。按理想大小画、靠左，宽高由内容自己的几何报
            effort.rootView = AnyView(ThreadEffortControl(controls: controls)
                .disabled(!enabled)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] in self?.effortResized($0) }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
        for button in [attach, voice, primary] { button.setFont(body) }
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
        primary.label = .symbol(controls.primaryAction.symbol)
        primary.title = controls.primaryAction.title
        primary.fill = controls.primaryActionFill
        primary.isEnabled = enabled && controls.canPerformPrimaryAction
        showWaiting(thread.waiting, controls: controls)
        let fading = controls.state.fading
        field.alpha = fading == nil && shownWaiting == nil ? 1 : 0
        if fading == nil { shownFading = nil }
        // 失败提示
        if let error = controls.state.effortError { present("修改思考强度失败", error) { controls.state.effortError = nil } }
        if let error = controls.state.voiceError { present("无法开始语音输入", error) { controls.state.voiceError = nil } }
    }

    /// 出现审批或提问时输入框淡出、回应卡片淡入，回应后换回来；高由 contentChanged 报给外面。
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
        if entering { endTyping() }
        let composer: [UIView] = [field, effort.view, attach, voice, primary]
        response.view.isHidden = false
        for view in composer { view.isHidden = false }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.response.view.alpha = entering ? 1 : 0
            for view in composer { view.alpha = entering ? 0 : 1 }
        } completion: { [weak self] _ in
            guard let self else { return }
            response.view.isHidden = shownWaiting == nil
            for view in composer { view.isHidden = shownWaiting != nil }
            setNeedsLayout()
        }
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

    /// 玻璃的高，版式见 ComposerLayout。
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
        let fieldWidth = max(width - 2 * ComposerLayout.fieldInset, 0)
        var fieldHeight = field.height(width: fieldWidth, text: field.text)
        if let fading = controls?.state.fading { fieldHeight = max(fieldHeight, fading.height) }
        return ComposerLayout.plan(width: width, field: fieldHeight, effort: currentEffortSize)
    }

    private var currentEffortSize: CGSize {
        if let effortSize { return effortSize }
        let size = effort.view.intrinsicContentSize
        effortSize = size
        return size
    }

    /// 思考强度改了大小（刻度展开、收起时逐帧）：重摆，高变了再报。
    private func effortResized(_ size: CGSize) {
        guard size != effortSize else { return }
        effortSize = size
        contentChanged()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        place(glass, bounds)
        place(response.view, bounds)
        guard shownWaiting == nil else { return }
        let plan = plan(width: width)

        let fieldWidth = max(width - 2 * ComposerLayout.fieldInset, 0)
        let top = ComposerLayout.fieldTop
        place(field, CGRect(x: ComposerLayout.fieldInset, y: top, width: fieldWidth, height: field.height(width: fieldWidth, text: field.text)))
        place(fadingView, CGRect(x: ComposerLayout.fieldInset, y: top, width: fieldWidth, height: plan.field))

        let row = ComposerLayout.row(width: width, plan: plan)
        place(effort.view, row.effort)
        // 复用本次排版的宽度比较，只在跨过阈值时改变可见性；控件保留，effort 的手势不中断。
        for button in [attach, voice, primary] where button.isHidden != plan.hidesActions {
            button.isHidden = plan.hidesActions
        }
        guard !plan.hidesActions else { return }
        place(primary, row.primary)
        place(voice, row.voice)
        place(attach, row.attach)
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

/// 思考强度的托管视图，按里面报的理想大小摆。
private typealias EffortHost = UIHostingController<AnyView>
#endif
