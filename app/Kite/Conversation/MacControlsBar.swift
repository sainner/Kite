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
    /// 提问作答时按钮行左边的上一题、下一题，占思考强度的位置（见 ThreadControlsModel.answering）。
    private let previousButton = PaneButtonView()
    private let nextButton = PaneButtonView()
    /// 审批、密钥请求时按钮行左边的拒绝和次级的决定，也占思考强度的位置（见 ThreadControlsModel.deciding）；换了一项按它的决定重建。
    private var decisionButtons: [PaneButtonView] = []
    private var decisions: [WaitingDecision] = []
    private var buttonFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    /// 等你回应时摆在输入框上面的卡片（WaitingResponseCard），和输入框共用这张玻璃。按自己的高摆，
    /// 过渡途中玻璃比它矮，超出顶边的由 responseClip 裁掉。
    private let response = NSHostingController(rootView: AnyView(EmptyView()))
    private let responseClip = ResponseClip()
    /// 待发的附件那一行，在输入框上面。
    private let strip = ComposerStripHost()
    /// 打「/」时的 skill 候选那一行，在附件下面、输入框上面。
    private let skills = ComposerStripHost(height: SkillCandidateStrip.height)
    /// 卡片正在显示的等待；没有时只有输入区。
    private var shownWaiting: String?
    private var responseKey: WaitingResponseKey?
    /// 卡片按宽量出的高，内容换了或它自己报了新高时作废。
    private var cardSize: (width: CGFloat, height: CGFloat)?
    /// 输入框在答哪一项提问的「其他」；换了就交出焦点，免得打着的字换成另一段。
    private var answeringShown: String?
    private var motion = ComposerMotion()
    /// 上一次排出来的样子，过渡从这里起。
    private var pose: ComposerMotion.Pose?
    /// motion 在走时逐帧取样。
    private let motionTicker = FrameTicker()
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
        #if DEBUG
        CursorProbe.install()
        #endif
        addSubview(field)
        addSubview(fadingView)
        addSubview(effort)
        for button in [attach, voice, primary, previousButton, nextButton] { addSubview(button) }
        effort.sizingOptions = [.intrinsicContentSize]
        response.sizingOptions = []
        responseClip.clipsToBounds = true
        responseClip.alphaValue = 0
        responseClip.isHidden = true
        responseClip.addSubview(response.view)
        addSubview(responseClip)
        strip.resized = { [weak self] in self?.contentChanged() }
        addSubview(strip.view, positioned: .below, relativeTo: responseClip)
        skills.resized = { [weak self] in self?.contentChanged() }
        addSubview(skills.view, positioned: .below, relativeTo: responseClip)
        registerForDraggedTypes([.fileURL])

        attach.label = .symbol("paperclip")
        attach.title = "添加附件"
        attach.isEnabled = false
        attach.action = { [weak self] in self?.controls?.chooseFiles(in: self?.window) }
        field.attachments = { [weak self] in self?.controls?.attach(from: $0) ?? false }
        previousButton.label = .symbol("arrow.left")
        previousButton.title = "上一题"
        previousButton.action = { [weak self] in self?.controls?.answering?.back() }
        nextButton.label = .symbol("arrow.right")
        nextButton.title = "下一题"
        nextButton.action = { [weak self] in self?.controls?.answering?.forward() }
        // 和审批、密钥请求的次级决定一样带灰底
        for button in [previousButton, nextButton] { button.secondary = true }
        voice.action = { [weak self] in self?.controls?.toggleVoice() }
        primary.action = { [weak self] in
            guard let self, enabled else { return }
            controls?.performPrimaryAction(submit: submit)
        }
        field.submit = { [weak self] in self?.submit() }
        field.intercept = { [weak self] in self?.controls?.skillKeyAction($0) }
        field.textChanged = { [weak self] text in
            guard let self else { return }
            controls?.setFieldText(text)
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
        buttonFont = body
        for button in [attach, voice, primary, previousButton, nextButton] + decisionButtons { button.setFont(body) }
        if buttonsEnvironment != environment.colorScheme {
            buttonsEnvironment = environment.colorScheme
            for button in [attach, voice, primary, previousButton, nextButton] + decisionButtons { button.environment = environment }
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
        field.setText(controls.fieldText)
        field.isEnabled = enabled
        let listening = controls.listening
        voice.label = .symbol(listening ? "mic.fill" : "mic")
        voice.foreground = listening ? .accentColor : .secondary
        voice.title = listening ? "结束语音输入" : "语音输入"
        voice.isEnabled = enabled
        attach.isEnabled = enabled && controls.canAttach
        strip.show(thread, items: thread.draftAttachments.map(\.id), environment: environment) {
            DraftAttachmentStrip(thread: thread).fixedSize(horizontal: false, vertical: true)
        }
        // 打了「/」才读这个工作区能加载的 skill，刚读过的不重读
        controls.loadSkillsIfNeeded()
        skills.show(thread, items: controls.skillCandidates.map(\.name), environment: environment) { SkillCandidateStrip(controls: controls) }
        primary.label = .symbol(controls.primaryAction.symbol)
        primary.title = controls.primaryAction.title
        primary.fill = controls.primaryActionFill
        primary.isEnabled = enabled && controls.canPerformPrimaryAction
        previousButton.isEnabled = enabled && controls.answering?.canGoBack == true
        nextButton.isEnabled = enabled && controls.answering?.canGoForward == true
        showDecisions(controls)
        let answering = controls.answering?.waiting?.id
        if answering != answeringShown {
            answeringShown = answering
            if field.currentEditor() != nil { window?.makeFirstResponder(nil) }
        }
        showWaiting(thread.waiting, controls: controls)
        let fading = controls.state.fading
        applyPose(fading: fading)
        if fading == nil { shownFading = nil }
    }

    // MARK: - 拖进来的文件

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controls?.canAttach == true && enabled && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard enabled else { return false }
        return controls?.attach(from: sender.draggingPasteboard) ?? false
    }

    /// 审批、密钥请求展开时按钮行左边的决定：换了一项（决定不同）才重建；回应途中都按不了，要存密钥的没填好值时按不了。
    private func showDecisions(_ controls: ThreadControlsModel) {
        let decisions = controls.deciding.map(WaitingDecision.others(for:)) ?? []
        if decisions != self.decisions {
            self.decisions = decisions
            for button in decisionButtons { button.removeFromSuperview() }
            decisionButtons = decisions.map { decision in
                let button = PaneButtonView()
                button.label = .text(decision.title)
                button.title = decision.title
                button.fill = decision.fill
                button.secondary = decision.secondary
                button.foreground = decision.foreground
                button.setFont(buttonFont)
                if let environment { button.environment = environment }
                button.action = { [weak self] in self?.controls?.decide(decision) }
                addSubview(button, positioned: .below, relativeTo: responseClip)
                return button
            }
        }
        for (button, decision) in zip(decisionButtons, decisions) { button.isEnabled = enabled && controls.canDecide(decision) }
    }

    /// 出现审批或提问时卡片从输入区上方长出来，回应后收回去；过渡见 ComposerMotion，高由 contentChanged 报给外框。
    private func showWaiting(_ waiting: RemoteWaiting?, controls: ThreadControlsModel) {
        if let waiting {
            let thread = controls.thread
            let delegate = controls.delegate
            let key = WaitingResponseKey(waiting: waiting, delegable: delegate != nil,
                                         colorScheme: environment?.colorScheme, dynamicTypeSize: environment?.dynamicTypeSize)
            if key != responseKey {
                responseKey = key
                cardSize = nil
                responseClip.resetHover()
                response.rootView = AnyView(WaitingResponseCard(waiting: waiting, respond: { try await thread.respond(waiting, $0) },
                                                                delegate: delegate, answers: thread.answers)
                    .environment(\.clickPointerHover) { [weak clip = responseClip] in clip?.hover($0) }
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] _ in self?.cardResized() }
                    .environment(\.self, environment ?? EnvironmentValues()))
            }
        } else {
            responseKey = nil
        }
        guard waiting?.id != shownWaiting else { return }
        let entering = shownWaiting == nil, leaving = waiting == nil
        shownWaiting = waiting?.id
        // 出现、消失贴着输入区；换成另一项等待时卡片原地换内容，贴着顶边
        begin(cardOnTop: !(entering || leaving))
    }

    /// 卡片自己变高变矮了（收起、展开、换题）：玻璃跟着平滑变，卡片贴着顶边；出现、消失的途中按当时的高跟着。
    private func cardResized() {
        let old = cardSize
        cardSize = nil
        if shownWaiting != nil, let old, cardHeight(width: old.width) != old.height, !(motion.moving && !motion.cardOnTop) {
            begin(cardOnTop: true)
        }
        contentChanged()
    }

    /// 从上一次排出来的样子往新的目标过渡；还没排过、不在窗口里的（打开时就在等）当场换好。
    private func begin(cardOnTop: Bool) {
        let now = window != nil && pose != nil ? CACurrentMediaTime() : nil
        motion.begin(from: pose ?? ComposerMotion.target(composer: 0, card: nil), cardOnTop: cardOnTop, at: now)
        guard motion.moving, !motionTicker.running else { return }
        motionTicker.start(in: self) { [weak self] in self?.motionTick(at: $0) ?? false }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil, motionTicker.running else { return }
        motionTicker.stop()
        motion.finish()
        applyPose(fading: controls?.state.fading)
        contentChanged()
    }

    private func motionTick(at time: CFTimeInterval) -> Bool {
        let moving = motion.sample(at: time)
        applyPose(fading: controls?.state.fading)
        contentChanged()
        return moving
    }

    /// 卡片的不透明度跟着这一刻的样子；发送淡出时输入框藏着，见 FadingSnapshotView。显隐在 layout 里定。
    private func applyPose(fading: FadingText?) {
        responseClip.alphaValue = currentPose(width: nil).card
        field.alphaValue = fading == nil ? 1 : 0
    }

    /// 这一刻的样子，见 ComposerMotion；width 为空时只要不透明度，不量高。
    private func currentPose(width: CGFloat?) -> ComposerMotion.Pose {
        let composer = width.map { plan(width: $0).height } ?? 0
        let card = shownWaiting == nil ? nil : width.map { cardHeight(width: $0) } ?? 0
        return motion.pose(toward: ComposerMotion.target(composer: composer, card: card))
    }

    private func submit() {
        guard let controls, enabled else { return }
        if controls.answering != nil { return controls.advanceAnswer() }
        guard controls.canSubmit else { return }
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
        let pose = currentPose(width: width)
        self.pose = pose
        reported = (width, pose.height)
        return pose.height
    }

    private func cardHeight(width: CGFloat) -> CGFloat {
        let width = max(width, 0)
        if let cardSize, cardSize.width == width { return cardSize.height }
        let height = response.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        cardSize = (width, height)
        return height
    }

    /// 输入框这一边的版式。
    private func plan(width: CGFloat) -> ComposerLayout.Plan {
        let width = max(width, 0)
        let fieldWidth = max(width - 2 * ComposerLayout.fieldInset, 0) + 2 * ComposerField.fieldInset
        var fieldHeight = field.height(width: fieldWidth, text: field.text)
        if let fading = controls?.state.fading { fieldHeight = max(fieldHeight, fading.height) }
        return ComposerLayout.plan(width: width, field: fieldHeight, effort: leftSize, strips: [strip.height(width: width), skills.height(width: width)])
    }

    /// 按钮行左边那一格：平常是思考强度；作答时多题是上一题、下一题，一题时空着；审批、密钥请求时是它们的决定。
    private var leftSize: CGSize {
        guard let controls, controls.responding else { return currentEffortSize }
        if controls.deciding != nil { return ComposerLayout.decisionRow(decisionButtons.map(\.width)).size }
        return !controls.questionSteps ? .zero : CGSize(width: 2 * Metrics.paneButton, height: Metrics.paneButton)
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
        let pose = currentPose(width: width)
        self.pose = pose
        let plan = plan(width: width)
        // 收回去以后藏起来，不接点击
        if responseClip.isHidden != (pose.card == 0) { responseClip.isHidden = pose.card == 0 }
        place(responseClip, bounds)
        if pose.card > 0 {
            let height = cardHeight(width: width)
            let top = motion.cardTop(glass: bounds.height, card: height, composer: plan.height)
            // clip 没翻转
            place(response.view, CGRect(x: 0, y: bounds.height - top - height, width: width, height: height))
        }
        // 有卡片时输入区贴着底边
        let dy = pose.card > 0 ? bounds.height - plan.height : 0

        for (view, frame) in zip([strip.view, skills.view], plan.strips) where frame.height > 0 { place(view, frame.offsetBy(dx: 0, dy: dy)) }
        let fieldWidth = max(width - 2 * ComposerLayout.fieldInset, 0)
        let top = plan.fieldTop + dy
        place(field, CGRect(x: ComposerLayout.fieldInset - ComposerField.fieldInset, y: top, width: fieldWidth + 2 * ComposerField.fieldInset,
                            height: field.drawHeight(width: fieldWidth + 2 * ComposerField.fieldInset, text: field.text)))
        place(fadingView, CGRect(x: field.frame.minX, y: top, width: field.frame.width, height: plan.field))

        let row = ComposerLayout.row(width: width, plan: plan)
        let left = row.effort.offsetBy(dx: 0, dy: dy)
        let responding = controls?.responding == true, navigating = controls?.questionSteps == true
        if effort.isHidden != responding { effort.isHidden = responding }
        if !responding { place(effort, left) }
        for button in [previousButton, nextButton] where button.isHidden != !navigating { button.isHidden = !navigating }
        if navigating {
            let size = Metrics.paneButton
            place(previousButton, CGRect(x: left.minX, y: left.minY, width: size, height: size))
            place(nextButton, CGRect(x: left.minX + size, y: left.minY, width: size, height: size))
        }
        let decisionRow = ComposerLayout.decisionRow(decisionButtons.map(\.width))
        for (button, x) in zip(decisionButtons, decisionRow.offsets) {
            place(button, CGRect(x: left.minX + x, y: left.minY, width: button.width, height: Metrics.paneButton))
        }
        // 复用本次排版的宽度比较，只在跨过阈值时改变可见性；控件保留，effort 的手势不中断。
        for button in [attach, voice, primary] where button.isHidden != plan.hidesActions {
            button.isHidden = plan.hidesActions
        }
        guard !plan.hidesActions else { return }
        place(primary, row.primary.offsetBy(dx: 0, dy: dy))
        place(voice, row.voice.offsetBy(dx: 0, dy: dy))
        place(attach, row.attach.offsetBy(dx: 0, dy: dy))
    }

    /// 和现在一样就不设：拖缝时每步都排，多数子视图只有横向位置在变。
    private func place(_ view: NSView, _ frame: CGRect) {
        if view.frame != frame { view.frame = frame }
    }

    /// 里面变了（行数、按钮、思考强度的宽）：高变了让 SwiftUI 和原生外框重新量，没变只重摆。
    private func contentChanged() {
        needsLayout = true
        guard let reported, currentPose(width: reported.width).height != reported.height else { return }
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

/// 裁卡片的那一层和玻璃一样大：自己不接点击、不挡光标，卡片收起时下面的输入框照常点得中。
/// 卡片里可点的控件的手形也由它给：托管的 SwiftUI 的 pointerStyle 轮不到（见 clickPointerHover），指针在控件上时按 NativeCursor 给手形。
private final class ResponseClip: NSView, NativeCursor {
    /// 指针正停在几个可点的控件上（进出成对报，相邻的两个可能先进后出）。
    private var hovered = 0

    var nativeCursor: NSCursor? { hovered > 0 ? .pointingHand : nil }

    /// 离开控件时按指针下面的设：移到卡片里的输入框上是文字光标（见 nativeCursorUnderPointer），不一律设回箭头。
    func hover(_ entered: Bool) {
        hovered = max(hovered + (entered ? 1 : -1), 0)
        (nativeCursor ?? nativeCursorUnderPointer() ?? .arrow).set()
    }

    func resetHover() { hovered = 0 }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// 思考强度的托管视图，按里面报的理想大小摆。
private final class EffortIsland: NSHostingView<AnyView> {
    override var mouseDownCanMoveWindow: Bool { false }
}
#endif
