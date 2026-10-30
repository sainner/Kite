#if os(iOS)
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// iPhone、iPad 会话窗口的输入区：玻璃和里面的内容，和玻璃一样大，圆角以外不接点按。原生会话窗口（PhoneThreadWindowView）
/// 和紧凑布局的外壳直接挂它，拖缝改宽时只按宽度重摆。版式同 Mac 的输入区：输入框左右留 controlInset + 8、上下 6，
/// 下面一行思考强度和按钮，放不下时隐藏按钮组。玻璃是 UIKit 的交互玻璃（UIGlassEffect，圆角 controlRadius）。
/// 逻辑共用 ThreadControlsModel；思考强度留在 SwiftUI（ThreadEffortControl），放进一个按自己大小摆的托管视图，只在它自己改宽时重排。
final class ControlsBarView: UIView {
    private let glass: UIVisualEffectView
    private let field = ComposerField.make()
    /// 语音整理时盖在输入框上的扫掠。
    private lazy var voiceSweep = VoiceSweepView(field: field)
    private let fadingView = FadingSnapshotView()
    private let effort = EffortHost(rootView: AnyView(EmptyView()))
    private let attach = PaneButtonView()
    private let voice = PaneButtonView()
    private let primary = PaneButtonView()
    /// 提问作答时按钮行左边的上一题、下一题，占思考强度的位置（见 ThreadControlsModel.answering）。
    private let previousButton = PaneButtonView()
    private let nextButton = PaneButtonView()
    /// 审批、密钥请求时按钮行左边的拒绝和次级的决定，也占思考强度的位置（见 ThreadControlsModel.deciding）；换了一项按它的决定重建。
    private var decisionButtons: [PaneButtonView] = []
    private var decisions: [WaitingDecision] = []
    private var buttonFont = UIFont.preferredFont(forTextStyle: .body)
    /// 等你回应时摆在输入框上面的卡片（WaitingResponseCard），和输入框共用这张玻璃。按自己的高摆，
    /// 过渡途中玻璃比它矮，超出顶边的由 responseClip 裁掉。
    private let response = UIHostingController(rootView: AnyView(EmptyView()))
    /// 裁卡片的那一层和玻璃一样大：自己不接点按，卡片收起时下面的输入框照常点得中。
    private let responseClip = PassThroughView()
    /// 待发的附件那一行，在输入框上面。
    private let strip = ComposerStripHost()
    /// 打「/」时的 skill 候选那一行，在附件下面、输入框上面。
    private let skills = ComposerStripHost(height: SkillCandidateStrip.height)
    /// 照片、文件的选择器交回来的，见 AttachmentPickers。
    private lazy var pickers = AttachmentPickers { [weak self] files in self?.controls?.attach(files: files) }
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
    var effortFrame: CGRect { effort.view.isHidden ? .null : effort.view.frame }

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
        content.addSubview(voiceSweep)
        content.addSubview(fadingView)
        content.addSubview(effort.view)
        effort.view.backgroundColor = .clear
        effort.sizingOptions = [.intrinsicContentSize]
        effort.safeAreaRegions = []
        for button in [attach, voice, primary, previousButton, nextButton] { content.addSubview(button) }
        response.view.backgroundColor = .clear
        response.safeAreaRegions = []
        response.sizingOptions = []
        responseClip.clipsToBounds = true
        responseClip.alpha = 0
        responseClip.isHidden = true
        responseClip.addSubview(response.view)
        content.addSubview(responseClip)
        strip.resized = { [weak self] in self?.contentChanged() }
        content.insertSubview(strip.view, belowSubview: responseClip)
        skills.resized = { [weak self] in self?.contentChanged() }
        content.insertSubview(skills.view, belowSubview: responseClip)

        attach.label = .symbol("paperclip")
        attach.title = "添加附件"
        attach.isEnabled = false
        attach.showsMenuAsPrimaryAction = true
        attach.menu = UIMenu(children: [
            UIAction(title: "照片", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in self?.choose(photos: true) },
            UIAction(title: "文件", image: UIImage(systemName: "folder")) { [weak self] _ in self?.choose(photos: false) },
        ])
        field.pasteImage = { [weak self] data in self?.controls?.attach(data: data, name: "图片.png") }
        previousButton.label = .symbol("arrow.left")
        previousButton.title = "上一题"
        previousButton.action = { [weak self] in self?.controls?.answering?.back() }
        nextButton.label = .symbol("arrow.right")
        nextButton.title = "下一题"
        nextButton.action = { [weak self] in self?.controls?.answering?.forward() }
        // 和审批、密钥请求的次级决定一样带灰底
        for button in [previousButton, nextButton] { button.secondary = true }
        voice.action = { [weak self] in self?.toggleVoice() }
        primary.action = { [weak self] in
            guard let self, enabled else { return }
            controls?.performPrimaryAction(submit: submit)
        }
        field.textChanged = { [weak self] text in
            guard let self else { return }
            controls?.setFieldText(text)
            contentChanged()
        }
        field.intercept = { [weak self] in self?.controls?.keyAction($0) }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in self.fontChanged() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(controls: ThreadControlsModel, enabled: Bool, environment: EnvironmentValues) {
        self.controls = controls
        self.enabled = enabled
        if self.environment?.colorScheme != environment.colorScheme || self.environment == nil {
            for button in [attach, voice, primary, previousButton, nextButton] + decisionButtons { button.environment = environment }
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
        buttonFont = body
        for button in [attach, voice, primary, previousButton, nextButton] + decisionButtons { button.setFont(body) }
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
        field.setText(controls.fieldText)
        let voiceStyle = controls.voiceStyle
        field.setVoiceStyle(voiceStyle)
        voiceSweep.update(voiceStyle)
        field.isEditable = enabled
        field.isUserInteractionEnabled = enabled
        let listening = controls.listening
        voice.label = .symbol(listening ? "mic.fill" : "mic")
        voice.foreground = listening ? .accentColor : .secondary
        voice.title = listening ? "结束语音输入" : "语音输入"
        voice.isEnabled = enabled
        attach.isEnabled = enabled && controls.canAttach
        field.acceptsImages = enabled && controls.canAttach
        strip.show(thread, items: thread.draftAttachments.map(\.id), environment: environment) {
            DraftAttachmentStrip(thread: thread).fixedSize(horizontal: false, vertical: true)
        }
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
            endTyping()
        }
        showWaiting(thread.waiting, controls: controls)
        let fading = controls.state.fading
        applyPose(fading: fading)
        if fading == nil { shownFading = nil }
        // 失败提示
        if let failure = controls.state.failure { present(failure.title, failure.message) { controls.state.failure = nil } }
    }

    /// 回形针菜单里选了照片或文件：从最上面那一层弹出选择器。
    private func choose(photos: Bool) {
        guard controls?.canAttach == true, var host = window?.rootViewController else { return }
        while let top = host.presentedViewController { host = top }
        host.present(photos ? pickers.photos() : pickers.files(), animated: true)
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
                button.environment = environment
                button.action = { [weak self] in self?.controls?.decide(decision) }
                glass.contentView.insertSubview(button, belowSubview: responseClip)
                return button
            }
        }
        for (button, decision) in zip(decisionButtons, decisions) { button.isEnabled = enabled && controls.canDecide(decision) }
    }

    /// 出现审批或提问时卡片从输入区上方长出来，回应后收回去；过渡见 ComposerMotion，高由 contentChanged 报给外面。
    private func showWaiting(_ waiting: RemoteWaiting?, controls: ThreadControlsModel) {
        if let waiting {
            let thread = controls.thread
            let delegate = controls.delegate
            let key = WaitingResponseKey(waiting: waiting, delegable: delegate != nil,
                                         colorScheme: environment?.colorScheme, dynamicTypeSize: environment?.dynamicTypeSize)
            if key != responseKey {
                responseKey = key
                cardSize = nil
                response.rootView = AnyView(WaitingResponseCard(waiting: waiting, respond: { try await thread.respond(waiting, $0) },
                                                                delegate: delegate, answers: thread.answers)
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

    override func didMoveToWindow() {
        super.didMoveToWindow()
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

    /// 卡片的不透明度跟着这一刻的样子；发送淡出时输入框藏着，见 FadingSnapshotView。显隐在 layoutSubviews 里定。
    private func applyPose(fading: FadingText?) {
        responseClip.alpha = currentPose(width: nil).card
        field.alpha = fading == nil ? 1 : 0
    }

    /// 这一刻的样子，见 ComposerMotion；width 为空时只要不透明度，不量高。
    private func currentPose(width: CGFloat?) -> ComposerMotion.Pose {
        let composer = width.map { plan(width: $0).height } ?? 0
        let card = shownWaiting == nil ? nil : width.map { cardHeight(width: $0) } ?? 0
        return motion.pose(toward: ComposerMotion.target(composer: composer, card: card))
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
        let fieldWidth = max(width - 2 * ComposerLayout.fieldInset, 0)
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
        let pose = currentPose(width: width)
        self.pose = pose
        let plan = plan(width: width)
        // 收回去以后藏起来，不接点按
        if responseClip.isHidden != (pose.card == 0) { responseClip.isHidden = pose.card == 0 }
        place(responseClip, bounds)
        if pose.card > 0 {
            let height = cardHeight(width: width)
            let top = motion.cardTop(glass: bounds.height, card: height, composer: plan.height)
            place(response.view, CGRect(x: 0, y: top, width: width, height: height))
        }
        // 有卡片时输入区贴着底边
        let dy = pose.card > 0 ? bounds.height - plan.height : 0

        for (view, frame) in zip([strip.view, skills.view], plan.strips) where frame.height > 0 { place(view, frame.offsetBy(dx: 0, dy: dy)) }
        let fieldWidth = max(width - 2 * ComposerLayout.fieldInset, 0)
        let top = plan.fieldTop + dy
        place(field, CGRect(x: ComposerLayout.fieldInset, y: top, width: fieldWidth, height: field.height(width: fieldWidth, text: field.text)))
        place(voiceSweep, field.frame)
        place(fadingView, CGRect(x: ComposerLayout.fieldInset, y: top, width: fieldWidth, height: plan.field))

        let row = ComposerLayout.row(width: width, plan: plan)
        let left = row.effort.offsetBy(dx: 0, dy: dy)
        let responding = controls?.responding == true, navigating = controls?.questionSteps == true
        if effort.view.isHidden != responding { effort.view.isHidden = responding }
        if !responding { place(effort.view, left) }
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
        guard let reported, currentPose(width: reported.width).height != reported.height else { return }
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

/// 回形针菜单里的两个选择器：照片（只要图片，可以多选）和文件（拷一份过来，可以多选）。选好的先拷进临时目录再交出去：
/// 照片给的文件在回调结束后就没了。交出去以后由输入框那边再拷进它自己的暂存目录，这里的随即删掉。
private final class AttachmentPickers: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
    private let picked: @MainActor ([URL]) -> Void

    init(picked: @escaping @MainActor ([URL]) -> Void) { self.picked = picked }

    func photos() -> UIViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = WorkThread.maxAttachments
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        return picker
    }

    func files() -> UIViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        return picker
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        let directory = FileManager.default.temporaryDirectory.appending(path: "KitePicked/\(UUID().uuidString)")
        let group = DispatchGroup()
        let collected = Collected()
        for (index, result) in results.enumerated() {
            let provider = result.itemProvider
            guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { continue }
            // 名字用照片的名字，没有时按序号起
            let name = provider.suggestedName ?? "照片 \(index + 1)"
            group.enter()
            // 在后台回调，回调返回以后这个文件就被删了，当场拷走
            provider.loadFileRepresentation(forTypeIdentifier: type) { @Sendable url, _ in
                defer { group.leave() }
                if let url, let kept = Self.keep(url, name: name, in: directory.appending(path: "\(index)")) { collected.add(index, kept) }
            }
        }
        group.notify(queue: .main) { [picked] in
            MainActor.assumeIsolated { picked(collected.files) }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    nonisolated private static func keep(_ url: URL, name: String, in directory: URL) -> URL? {
        let target = directory.appending(path: name + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch { return nil }
    }

    /// 几张照片各自在后台拷完，按选的先后排。
    private nonisolated final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(Int, URL)] = []
        func add(_ index: Int, _ url: URL) { lock.withLock { entries.append((index, url)) } }
        var files: [URL] { lock.withLock { entries.sorted { $0.0 < $1.0 }.map(\.1) } }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        MainActor.assumeIsolated { picked(urls) }
    }
}
#endif
