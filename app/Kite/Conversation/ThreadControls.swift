import SwiftUI

/// 会话窗口的控制区：输入框与服务支持的操作。发送、打断、继续由真实状态控制，未接通的入口禁用。
/// 发出去的字在输入框里模糊、淡掉，同时气泡在对话里从下往上浮进来（见 ThreadPane.send）。
struct ThreadControls: View {
    var typing: FocusState<Bool>.Binding
    /// 发一条消息；第二个参数和对话往上滑在同一次更新里调。
    let send: (Message, _ alongside: @escaping () -> Void) -> Void
    /// 这个窗口录语音时的标识，见 VoiceInput.owner。
    let voiceOwner: String
    @Environment(WorkThread.self) private var thread
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.paneInstance) private var instance
    @Environment(\.dotStage) private var stage
    @Environment(\.dotScope) private var dotScope
    /// 控制区在窗口坐标中的位置，发送时点阵的波从这里推开。
    @State private var frame: CGRect = .zero
    /// 刚发出去、正在淡掉的字。控制区里由 SwiftUI 逐帧驱动的动画会和对话滑动抢同一帧，发送时掉帧（2026-10-11 Mac 实测，
    /// 字的模糊淡出和发送键的淡出各自都会）：输入框先藏起来，字画成图盖在原处交给 Core Animation 淡掉（见 FadingSnapshot），
    /// 发送键直接消失。
    @State private var fading: FadingText?
    /// 输入框的高度，发送时记进 FadingText。
    @State private var fieldHeight: CGFloat = 0
    @State private var effortDraft: Effort?
    @State private var savingEffort = false
    @State private var effortError: String?
    @State private var voiceError: String?

    var body: some View {
        @Bindable var thread = thread
        let running = thread.transcriptRunning
        let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
        VStack(spacing: 2) {
            TextField(running ? "插话，agent 做完手上这一步就会看到" : "回复", text: $thread.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .lineLimit(1...8)
                .focused(typing)
                .scrollsOnlyWhileTyping(typing.wrappedValue)
                .onSubmit(submit)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldHeight = $0 }
                .frame(minHeight: fading?.height, alignment: .top)
                .opacity(fading == nil ? 1 : 0)
                .overlay { FadingSnapshot(fading: fading) }
                .padding(.horizontal, Metrics.controlInset + 8)
                .padding(.vertical, 6)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Metrics.paneButtonGap) {
                    effortControl.fixedSize()
                    Spacer(minLength: 0)
                    actionButtons.fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    effortControl
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        actionButtons
                    }
                }
            }
            .padding(.horizontal, Metrics.controlButtonInset)
        }
        .padding(.top, Metrics.controlInset)
        .padding(.bottom, Metrics.controlButtonInset)
        // 交互玻璃的同心形状有高光退回胶囊的复现；玻璃与交互轮廓统一使用明确圆角。
        .contentShape(.interaction, shape)
        #if os(iOS)
        .contentShape(.hoverEffect, shape)
        #endif
        .glassEffect(.regular.interactive(), in: shape)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .alert("修改思考强度失败", isPresented: Binding(get: { effortError != nil }, set: { if !$0 { effortError = nil } })) {
            Button("好", role: .cancel) { effortError = nil }
        } message: { Text(effortError ?? "") }
        .alert("无法开始语音输入", isPresented: Binding(get: { voiceError != nil }, set: { if !$0 { voiceError = nil } })) {
            Button("好", role: .cancel) { voiceError = nil }
        } message: { Text(voiceError ?? "") }
    }

    @ViewBuilder
    private var effortControl: some View {
        if let effort = Effort.allCases.first(where: { $0.name == reasoning }) {
            EffortPicker(effort: Binding(get: { effortDraft ?? effort }, set: { effortDraft = $0 }),
                         allowed: availableEfforts, commit: saveEffort, cancel: { effortDraft = nil })
                .allowsHitTesting(canChangeEffort)
                .help(thread.agentCapabilities?.explanation ?? "正在读取模型能力")
        } else {
            Menu {
                ForEach(availableEfforts, id: \.self) { value in
                    Button(value.name) { effortDraft = value; saveEffort() }
                }
            } label: { Text(reasoning == "default" ? "自动" : reasoning).font(Theme.secondary).foregroundStyle(.secondary).padding(.horizontal, 8) }
                .disabled(!canChangeEffort)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: Self.actionGap) {
            HStack(spacing: 0) {
                Button {} label: { Image(systemName: "paperclip") }
                    .buttonStyle(PaneButtonStyle())
                    .disabled(true).accessibilityLabel("添加附件")
                Button(action: toggleVoice) { Image(systemName: listening ? "mic.fill" : "mic") }
                    .buttonStyle(PaneButtonStyle(foreground: listening ? .accentColor : .secondary))
                    .accessibilityLabel(listening ? "结束语音输入" : "语音输入")
            }
            if thread.showStop {
                Button {
                    thread.stop()
                } label: { Image(systemName: "stop.fill") }
                .buttonStyle(PaneButtonStyle(fill: Theme.strongPlaceholder))
                .disabled(!thread.canStop)
                .accessibilityLabel("停止")
            }
            if thread.state?.capabilities.resume == true {
                Button("继续") { thread.control("resume") }
                    .buttonStyle(PaneButtonStyle(text: true))
                    .disabled(!thread.canResume)
                    .accessibilityLabel("继续")
            }
            if !blank && fading == nil {
                Button(action: submit) { Image(systemName: "arrow.up") }
                    .buttonStyle(PaneButtonStyle(fill: .accentColor))
                    .disabled(!thread.canSend)
                    .accessibilityLabel("发送")
            }
        }
    }

    private var listening: Bool { model.voice.owner == voiceOwner }

    private func toggleVoice() {
        if listening {
            model.voice.stop()
            return
        }
        // 识别出的字接在开录时的草稿后面，每次都是到目前为止的全文
        let base = thread.draft
        let thread = thread, voice = model.voice, owner = voiceOwner
        Task {
            do {
                let client = try thread.client ?? model.activeClient(in: area)
                try await voice.start(owner: owner, target: VoiceTarget(client: client, thread: thread.isDraft ? nil : thread.id)) { text in
                    switch text {
                    case .partial(let value), .final(let value): thread.draft = base + value
                    case .failed(let message):
                        voice.stop(owner: owner)
                        voiceError = message
                    }
                }
                #if os(iOS)
                // 收起键盘，窗口底部随声音起伏的签名才露得出来
                typing.wrappedValue = false
                #endif
            } catch {
                voiceError = error.localizedDescription
            }
        }
    }

    private var blank: Bool {
        thread.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 草稿还没有实例，思考强度改的是本机选择，随第一条消息一起提交。
    private var choice: DraftAgentChoice? { instance == nil ? thread.draftChoice : nil }
    private var agentModel: AgentModelConfiguration? { model.agentModel(for: thread, instance: instance, in: area) }
    private var reasoning: String { agentModel?.reasoning ?? "medium" }
    private var availableEfforts: [Effort] {
        let levels = thread.agentCapabilities?.model(agentModel?.model ?? "")?.reasoning ?? []
        return Effort.allCases.filter { levels.contains($0.name) }
    }
    private var canChangeEffort: Bool {
        if choice != nil { return agentModel != nil && !availableEfforts.isEmpty && model.isConnected(area) }
        return instance != nil && !savingEffort && !availableEfforts.isEmpty
            && model.isConnected(area) && thread.agentCapabilities?.canEdit(thread.state) == true
    }
    private func saveEffort() {
        if choice != nil {
            if canChangeEffort, let effortDraft, var selected = agentModel {
                selected.reasoning = effortDraft.name
                thread.draftChoice?.model = selected
            }
            self.effortDraft = nil
            return
        }
        guard canChangeEffort, let effortDraft, effortDraft.name != reasoning, let instance else { self.effortDraft = nil; return }
        savingEffort = true
        Task {
            defer { savingEffort = false; self.effortDraft = nil }
            do {
                try await model.updateAgent(in: area, id: instance.id) { $0.model.reasoning = effortDraft.name }
            } catch { effortError = error.localizedDescription }
        }
    }

    /// 发送时从控制区推开的波：弓形，中间先走，和对话往上滑同一条弹簧朝窗口顶边走，像把对话推上去；
    /// 从窄到宽、越走越淡，到窗口上部已经很淡。
    private static func sendWave(from frame: CGRect, reach: CGFloat) -> DotWave.Parameters {
        DotWave.Parameters(spring: .glide, width: 24, widthEnd: 144, reach: reach, bow: frame.width * 0.75, fadeEnd: 0.85)
    }

    private func submit() {
        guard !blank, fading == nil, thread.canSend else { return }
        let sent = thread.draft
        // 波只画在窗口里，朝窗口顶边走，和对话往上滑同一次更新起步
        let frame = frame, stage = stage, scope = dotScope
        let reach = frame.minY - (scope?.frame.minY ?? frame.minY)
        send(Message(typed: sent.trimmingCharacters(in: .whitespacesAndNewlines))) {
            stage?.emitWave(from: frame, parameters: Self.sendWave(from: frame, reach: reach), in: scope)
        }
        // 新工作区先选择项目；关闭选择窗口时仍保留原输入。
        guard !area.isDraft else { return }
        // 发送时就清空，输入框撑着原来的高度淡完再变矮。清空时键盘处理、输入框重排要几十毫秒（2026-10-11 iPhone 实测），
        // 放在对话刚起步的时候，不落在滑得最快的时候
        fading = FadingText(text: sent, height: fieldHeight)
        thread.draft = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDuration) { fading = nil }
    }

    /// 附件、语音这组按钮与后面停止、继续、发送键的间距，比通用的按钮间距紧，发送键贴着左边的按钮组。
    private static let actionGap: CGFloat = 4

    /// 发出去的字 0.3 秒 easeOut 模糊到 6、透明度到 0。
    fileprivate static let fadeDuration = 0.3
    fileprivate static let fadeBlur: CGFloat = 6
}

/// 一段正在淡掉的发出去的字，和发送时输入框的高度。
private struct FadingText {
    let id = UUID()
    let text: String
    let height: CGFloat
}

/// 发出去的字画成图盖在输入框原处，在 Core Animation 里模糊、淡掉，由渲染服务驱动，主线程不逐帧更新。
/// 图和输入框里的字逐像素重合，折行也一样（2026-10-11 实测；iOS 含深色和大字号）。
private struct FadingSnapshot {
    let fading: FadingText?
    /// 图四周留出的边，容下模糊溢出的部分；盖回去时往左上让开同样的距离。
    static let bleed: CGFloat = 12
}

#if os(macOS)
extension FadingSnapshot: NSViewRepresentable {
    func makeNSView(context: Context) -> FadingSnapshotView { FadingSnapshotView() }

    func updateNSView(_ view: FadingSnapshotView, context: Context) {
        if let fading { view.fade(fading, colorScheme: context.environment.colorScheme, scale: context.environment.displayScale) }
    }
}

private final class FadingSnapshotView: NSView {
    private let content = CALayer()
    private var shown: UUID?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        content.anchorPoint = .zero
        content.opacity = 0
        layer?.addSublayer(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func fade(_ fading: FadingText, colorScheme: ColorScheme, scale: CGFloat) {
        guard fading.id != shown else { return }
        shown = fading.id
        guard let image = render(fading.text, colorScheme: colorScheme, scale: scale) else { return }
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.name = "blur"
        blur?.setValue(0, forKey: kCIInputRadiusKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contents = image
        content.contentsScale = scale
        content.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        content.position = CGPoint(x: -FadingSnapshot.bleed, y: -FadingSnapshot.bleed)
        content.filters = blur.map { [$0] }
        content.opacity = 0
        CATransaction.commit()
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1
        opacity.toValue = 0
        let radius = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        radius.fromValue = 0
        radius.toValue = ThreadControls.fadeBlur
        let group = CAAnimationGroup()
        group.animations = [opacity, radius]
        group.duration = ThreadControls.fadeDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        content.add(group, forKey: "fade")
    }

    /// 按输入框的字体和宽度用 SwiftUI 的 Text 画，和 Mac 输入框的排法一样。
    private func render(_ text: String, colorScheme: ColorScheme, scale: CGFloat) -> CGImage? {
        guard bounds.width > 0 else { return nil }
        let renderer = ImageRenderer(content: Text(text).font(Theme.body).lineLimit(8)
            .frame(width: bounds.width, alignment: .leading)
            .padding(FadingSnapshot.bleed)
            .environment(\.colorScheme, colorScheme))
        renderer.scale = scale
        return renderer.cgImage
    }
}
#else
extension FadingSnapshot: UIViewRepresentable {
    func makeUIView(context: Context) -> FadingSnapshotView { FadingSnapshotView() }

    func updateUIView(_ view: FadingSnapshotView, context: Context) {
        if let fading { view.fade(fading) }
    }
}

/// iOS 的图层不支持 Core Image 滤镜，模糊不能逐帧加大：模糊到头的那张事先画好垫在清晰的下面，
/// 整体淡掉的同时清晰的淡出、模糊的淡入。
private final class FadingSnapshotView: UIView {
    private let content = CALayer()
    private let sharp = CALayer()
    private let blurred = CALayer()
    private var shown: UUID?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        content.anchorPoint = .zero
        content.opacity = 0
        for part in [blurred, sharp] {
            part.anchorPoint = .zero
            content.addSublayer(part)
        }
        layer.addSublayer(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func fade(_ fading: FadingText) {
        guard fading.id != shown else { return }
        shown = fading.id
        let scale = traitCollection.displayScale
        guard let image = render(fading.text) else { return }
        let renderer = ImageRenderer(content: Image(decorative: image, scale: scale).blur(radius: ThreadControls.fadeBlur))
        renderer.scale = scale
        guard let blurredImage = renderer.cgImage else { return }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.bounds = bounds
        content.position = CGPoint(x: -FadingSnapshot.bleed, y: -FadingSnapshot.bleed)
        for (part, image) in [(sharp, image), (blurred, blurredImage)] {
            part.contents = image
            part.contentsScale = scale
            part.bounds = bounds
            part.position = .zero
        }
        content.opacity = 0
        sharp.opacity = 0
        blurred.opacity = 1
        CATransaction.commit()
        content.add(Self.opacity(from: 1, to: 0), forKey: "fade")
        sharp.add(Self.opacity(from: 1, to: 0), forKey: "fade")
        blurred.add(Self.opacity(from: 0, to: 1), forKey: "fade")
    }

    /// iOS 的输入框是 TextKit 2 的 UITextView，折行和 SwiftUI 的 Text 不同（实测长句末尾会差一个字），按它的排法画：
    /// 正文字体（Theme.body）、无内边距、折行策略只有 hangulWordPriority，颜色和字号跟着自己的 traitCollection。
    /// 超出输入框高度的行不画，和输入框一样只露出前面几行。
    private func render(_ text: String) -> CGImage? {
        guard bounds.width > 0 else { return nil }
        let style = NSMutableParagraphStyle()
        style.lineBreakStrategy = .hangulWordPriority
        let storage = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        storage.addTextLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: bounds.width, height: 0))
        container.lineFragmentPadding = 0
        layout.textContainer = container
        var image: UIImage?
        traitCollection.performAsCurrent {
            storage.attributedString = NSAttributedString(string: text, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection),
                .foregroundColor: UIColor.label, .paragraphStyle: style])
            var fragments: [NSTextLayoutFragment] = []
            layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: .ensuresLayout) {
                fragments.append($0)
                return true
            }
            guard let last = fragments.last else { return }
            let bleed = FadingSnapshot.bleed
            let size = CGSize(width: bounds.width + bleed * 2, height: min(last.layoutFragmentFrame.maxY, bounds.height) + bleed * 2)
            image = UIGraphicsImageRenderer(size: size, format: UIGraphicsImageRendererFormat(for: traitCollection)).image { context in
                for fragment in fragments {
                    let origin = fragment.layoutFragmentFrame.origin
                    fragment.draw(at: CGPoint(x: origin.x + bleed, y: origin.y + bleed), in: context.cgContext)
                }
            }
        }
        return image?.cgImage
    }

    private static func opacity(from: Float, to: Float) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = ThreadControls.fadeDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return animation
    }
}
#endif
