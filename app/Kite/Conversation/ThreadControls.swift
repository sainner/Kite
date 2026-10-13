import SwiftUI

#if os(macOS)
/// Mac 窄窗口（紧凑布局）会话窗口的控制区：输入框与服务支持的操作。发送、打断、继续由真实状态控制，未接通的入口禁用。
/// 发出去的字在输入框里模糊、淡掉，同时气泡在对话里从下往上浮进来（见 ThreadPaneModel.send）。
/// 逻辑在 ThreadControlsModel，和宽屏的原生输入区（MacControlsBar）、iPhone、iPad 的 ControlsBarView 共用。
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
    @State private var state = ThreadControlsState()
    /// 控制区在窗口坐标中的位置，发送时点阵的波从这里推开。
    @State private var frame: CGRect = .zero
    /// 输入框的高度，发送时记进 FadingText。
    @State private var fieldHeight: CGFloat = 0

    private var controls: ThreadControlsModel {
        ThreadControlsModel(thread: thread, model: model, area: area, instance: instance, stage: stage, scope: dotScope,
                            voiceOwner: voiceOwner, state: state, send: send)
    }

    var body: some View {
        @Bindable var thread = thread
        let controls = controls
        let fading = state.fading
        let shape = RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
        VStack(spacing: 2) {
            TextField(controls.placeholder, text: $thread.draft, axis: .vertical)
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
                    ThreadEffortControl(controls: controls).fixedSize()
                    Spacer(minLength: 0)
                    actionButtons(controls).fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    ThreadEffortControl(controls: controls)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        actionButtons(controls)
                    }
                }
            }
            .padding(.horizontal, Metrics.controlButtonInset)
        }
        .padding(.top, Metrics.controlInset)
        .padding(.bottom, Metrics.controlButtonInset)
        // 交互玻璃的同心形状有高光退回胶囊的复现；玻璃与交互轮廓统一使用明确圆角。
        .contentShape(.interaction, shape)
        .glassEffect(.regular.interactive(), in: shape)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .alert("修改思考强度失败", isPresented: Binding(get: { state.effortError != nil }, set: { if !$0 { state.effortError = nil } })) {
            Button("好", role: .cancel) { state.effortError = nil }
        } message: { Text(state.effortError ?? "") }
        .alert("无法开始语音输入", isPresented: Binding(get: { state.voiceError != nil }, set: { if !$0 { state.voiceError = nil } })) {
            Button("好", role: .cancel) { state.voiceError = nil }
        } message: { Text(state.voiceError ?? "") }
    }

    private func actionButtons(_ controls: ThreadControlsModel) -> some View {
        let listening = controls.listening
        return HStack(spacing: ThreadControlsModel.actionGap) {
            HStack(spacing: 0) {
                Button {} label: { Image(systemName: "paperclip") }
                    .buttonStyle(PaneButtonStyle())
                    .disabled(true).accessibilityLabel("添加附件")
                Button(action: toggleVoice) { Image(systemName: listening ? "mic.fill" : "mic") }
                    .buttonStyle(PaneButtonStyle(foreground: listening ? .accentColor : .secondary))
                    .accessibilityLabel(listening ? "结束语音输入" : "语音输入")
            }
            if controls.showsStop {
                Button(action: controls.stop) { Image(systemName: "stop.fill") }
                    .buttonStyle(PaneButtonStyle(fill: Theme.strongPlaceholder))
                    .disabled(!thread.canStop)
                    .accessibilityLabel("停止")
            }
            if controls.showsResume {
                Button("继续", action: controls.resume)
                    .buttonStyle(PaneButtonStyle(text: true))
                    .disabled(!thread.canResume)
                    .accessibilityLabel("继续")
            }
            if controls.showsSend {
                Button(action: submit) { Image(systemName: "arrow.up") }
                    .buttonStyle(PaneButtonStyle(fill: .accentColor))
                    .disabled(!thread.canSend)
                    .accessibilityLabel("发送")
            }
        }
    }

    private func toggleVoice() {
        controls.toggleVoice()
    }

    private func submit() {
        controls.submit(from: frame, fieldHeight: fieldHeight)
    }
}

/// 发出去的字画成图盖在输入框原处，在 Core Animation 里模糊、淡掉，由渲染服务驱动，主线程不逐帧更新。
/// 图和输入框里的字逐像素重合，折行也一样（2026-10-11 实测）。
private struct FadingSnapshot: NSViewRepresentable {
    let fading: FadingText?

    func makeNSView(context: Context) -> FadingSnapshotView { FadingSnapshotView() }

    func updateNSView(_ view: FadingSnapshotView, context: Context) {
        guard let fading, !view.isShowing(fading) else { return }
        view.fade(fading, image: Self.render(fading.text, width: view.bounds.width, colorScheme: context.environment.colorScheme,
                                             scale: context.environment.displayScale), scale: context.environment.displayScale)
    }

    /// 按输入框的字体和宽度用 SwiftUI 的 Text 画，和 Mac 输入框的排法一样。
    private static func render(_ text: String, width: CGFloat, colorScheme: ColorScheme, scale: CGFloat) -> CGImage? {
        guard width > 0 else { return nil }
        let renderer = ImageRenderer(content: Text(text).font(Theme.body).lineLimit(8)
            .frame(width: width, alignment: .leading)
            .padding(FadingText.bleed)
            .environment(\.colorScheme, colorScheme))
        renderer.scale = scale
        return renderer.cgImage
    }
}

/// 发出去的字的图（四周带 FadingText.bleed 的边）盖在输入框原处，0.3 秒 easeOut 模糊、淡掉。
/// 窄窗口的图用 Text 画（见 FadingSnapshot），宽屏的原生输入区直接画输入框自己的字（见 ComposerField.snapshot）。
final class FadingSnapshotView: NSView {
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

    func isShowing(_ fading: FadingText) -> Bool { fading.id == shown }

    func fade(_ fading: FadingText, image: CGImage?, scale: CGFloat) {
        guard fading.id != shown else { return }
        shown = fading.id
        guard let image else { return }
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.name = "blur"
        blur?.setValue(0, forKey: kCIInputRadiusKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contents = image
        content.contentsScale = scale
        content.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        content.position = CGPoint(x: -FadingText.bleed, y: -FadingText.bleed)
        content.filters = blur.map { [$0] }
        content.opacity = 0
        CATransaction.commit()
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1
        opacity.toValue = 0
        let radius = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        radius.fromValue = 0
        radius.toValue = FadingText.blur
        let group = CAAnimationGroup()
        group.animations = [opacity, radius]
        group.duration = FadingText.duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        content.add(group, forKey: "fade")
    }
}
#else
/// 发出去的字的图盖在输入框原处淡掉，iPhone、iPad 的输入区（ControlsBarView）用。iOS 的图层不支持 Core Image 滤镜，
/// 模糊不能逐帧加大：模糊到头的那张事先画好垫在清晰的下面，整体淡掉的同时清晰的淡出、模糊的淡入。
final class FadingSnapshotView: UIView {
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
        let renderer = ImageRenderer(content: Image(decorative: image, scale: scale).blur(radius: FadingText.blur))
        renderer.scale = scale
        guard let blurredImage = renderer.cgImage else { return }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.bounds = bounds
        content.position = CGPoint(x: -FadingText.bleed, y: -FadingText.bleed)
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
            let bleed = FadingText.bleed
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
        animation.duration = FadingText.duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return animation
    }
}
#endif
