import SwiftUI

extension View {
    /// 标题栏的一侧按这一帧的外框贴边，见 WindowHeaderAnchored。
    func windowHeaderAnchor(_ edge: HorizontalEdge) -> some View {
        WindowHeaderAnchored(edge: edge, content: self)
    }
}

/// 标题两侧贴着外框：台面上的窗口正文按终点排版，外框和它不一样大时（缩小、调整大小途中，或停着时外框比正文宽），两侧跟着外框的左右边和上边走。
/// 两侧按排版位置摆，挪动只改这一侧托管视图的图层（见 HeaderAnchorContainer），飞行中和停着都一样：标题栏看得见、停着时外框和正文一样大，
/// 不用挪；收成停靠形状停着时整块正文藏起来（见 HostedContentContainer）。不读 motion 的终点：排布一变，卡片随即把新终点交给 motion，
/// 读了的话两侧的托管视图要跟着再更新一轮。不在台面的托管视图里（紧凑布局、单页）时外框和正文一样大，两侧照常排。
/// 锚定若在正文的托管视图里逐帧改 SwiftUI 几何，整段正文跟着逐帧更新，玻璃按钮的 AppKit 视图逐帧改位置
/// （2026-10-12 Mac 实测，一个窗口占满台面时，缩小、恢复各多 25～45 毫秒主线程，缩小的丢帧约多一倍；只在绘制时平移没有用）。
/// 这一侧报的偏好值传不出它的托管视图，接着往上报，见 HeaderAnchorReports。
/// 滚动软边照样认得这一侧里的控件，位置也对（2026-10-12 Mac 实测，见 HostedContentContainer 里软边的那段）。
struct WindowHeaderAnchored<Content: View>: View {
    let edge: HorizontalEdge
    let content: Content
    @Environment(\.windowHeaderAnchors) private var anchors
    @State private var relay = HeaderAnchorRelay()

    var body: some View {
        if let anchors {
            HeaderAnchorHost(edge: edge, link: anchors, relay: relay, content: content)
                .modifier(HeaderAnchorReports(relay: relay))
        } else {
            content
        }
    }
}

/// 标题一侧在自己的托管视图里报的偏好值，由 WindowHeaderAnchored 接出来；尺寸变化直接通知原生容器。
@MainActor @Observable private final class HeaderAnchorRelay {
    @ObservationIgnored weak var container: HeaderAnchorContainer?
    var statusText: String?
    var actionsWidth: CGFloat = 0
    var rects: [CGRect] = []
}

/// 标题一侧报的偏好值传不出它的托管视图，在这里接着往上报，控件的范围换回标题栏的坐标。
/// 只在这一层读：这一侧挪了位置（如窗口按钮露出来时让位）、报的值变了，这一侧的托管视图不跟着更新。
private struct HeaderAnchorReports: ViewModifier {
    let relay: HeaderAnchorRelay
    @State private var origin = CGPoint.zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .named("pane-header")).origin } action: { origin = $0 }
            .preference(key: PaneHeaderStatusText.self, value: relay.statusText)
            .preference(key: PaneHeaderActionsWidth.self, value: relay.actionsWidth)
            .preference(key: PaneHeaderInteractiveRects.self, value: relay.rects.map { $0.offsetBy(dx: origin.x, dy: origin.y) })
    }
}

/// 标题一侧交给里面托管视图的内容。托管视图的 rootView 只在建的时候给一次，之后的内容经这里转交：
/// 重赋 rootView 送进去的变化，里面按 id 换视图的过渡不做（标题的 blurReplace 当场换字，只剩刷新图标的位移），
/// 经观察送进去的照常做（2026-10-16 Mac 实测，逐帧比过图层的模糊、缩放和透明度）。
@MainActor @Observable private final class HeaderAnchorContent {
    var view = AnyView(EmptyView())
}

private struct HeaderAnchorRoot: View {
    let content: HeaderAnchorContent

    var body: some View { content.view }
}

/// 标题一侧托管在自己的视图里。环境整份转交。
private struct HeaderAnchorHost<Content: View> {
    let edge: HorizontalEdge
    let link: HostedContentLink
    let relay: HeaderAnchorRelay
    let content: Content

    private func make(environment: EnvironmentValues) -> HeaderAnchorContainer {
        let container = HeaderAnchorContainer(edge: edge, link: link)
        relay.container = container
        container.content.view = rooted(environment, title: container.title)
        return container
    }

    private func update(_ container: HeaderAnchorContainer, environment: EnvironmentValues) {
        container.content.view = rooted(environment, title: container.title)
    }

    /// 偏好值和尺寸隔一拍交出去：里面的托管视图可能在外面这次更新当中排版，不能当场改外面的状态。
    private func rooted(_ environment: EnvironmentValues, title: WindowHeaderTitleEdge) -> AnyView {
        let relay = relay
        return AnyView(content
            .onPreferenceChange(PaneHeaderStatusText.self) { text in
                Task { @MainActor in if relay.statusText != text { relay.statusText = text } }
            }
            .onPreferenceChange(PaneHeaderActionsWidth.self) { width in
                Task { @MainActor in if relay.actionsWidth != width { relay.actionsWidth = width } }
            }
            .onPreferenceChange(PaneHeaderInteractiveRects.self) { rects in
                Task { @MainActor in if relay.rects != rects { relay.rects = rects } }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                Task { @MainActor in
                    // 外面刚分配的尺寸不用再报回去；只有标题内部改了尺寸，才让 SwiftUI 重新量。
                    // 走原生尺寸失效，避免仅仅改宽就重赋整个标题的 rootView。
                    if let container = relay.container, container.bounds.size != size {
                        container.invalidateIntrinsicContentSize()
                    }
                }
            }
            // 里面的控件按这一侧的左上角报范围，WindowHeaderAnchored 再换回标题栏的坐标
            .coordinateSpace(name: "pane-header")
            .environment(\.windowHeaderTitleEdge, title)
            .environment(\.windowHeaderAnchors, nil)
            .environment(\.self, environment))
    }
}

#if os(macOS)
extension HeaderAnchorHost: NSViewRepresentable {
    func makeNSView(context: Context) -> HeaderAnchorContainer { make(environment: context.environment) }
    func updateNSView(_ container: HeaderAnchorContainer, context: Context) { update(container, environment: context.environment) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HeaderAnchorContainer, context: Context) -> CGSize? {
        nsView.measure(proposal)
    }
}
#else
extension HeaderAnchorHost: UIViewRepresentable {
    func makeUIView(context: Context) -> HeaderAnchorContainer { make(environment: context.environment) }
    func updateUIView(_ container: HeaderAnchorContainer, context: Context) { update(container, environment: context.environment) }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: HeaderAnchorContainer, context: Context) -> CGSize? {
        uiView.measure(proposal)
    }
}
#endif

#if os(macOS)

/// 外面按停着的位置摆；里面一层按飞行中的挪动平移，标题右边截掉的部分是这一层图层上的遮罩。
private final class HeaderAnchorContainer: NSView, WindowHeaderFollower {
    let content = HeaderAnchorContent()
    let controller: NSHostingController<AnyView>
    let title = WindowHeaderTitleEdge()
    private let edge: HorizontalEdge
    private weak var link: HostedContentLink?
    private let mover = FlippedView()
    private let clip = CAShapeLayer()
    private var shift = CGVector.zero
    private var titleCut: CGFloat = 0

    init(edge: HorizontalEdge, link: HostedContentLink) {
        self.edge = edge
        self.link = link
        controller = .init(rootView: AnyView(HeaderAnchorRoot(content: content)))
        // 量尺寸要理想大小（见 measure）；不另算安全区
        controller.sizingOptions = [.intrinsicContentSize]
        controller.safeAreaRegions = []
        super.init(frame: .zero)
        wantsLayer = true
        mover.wantsLayer = true
        mover.addSubview(controller.view)
        addSubview(mover)
        title.changed = { [weak self] in self?.place() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        mover.frame = bounds
        controller.view.frame = bounds
        place()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { link?.add(self) } else { link?.remove(self) }
    }

    /// 没给的方向按理想大小：标题栏的高度由里面的按钮定（2026-10-12 Mac 实测，给无限高时标题栏从 48 撑到 56）。
    func measure(_ proposal: ProposedViewSize) -> CGSize {
        // 两个方向都给了就不用先量理想大小：拖缝改宽时标题那一侧每步都要量
        if let width = proposal.width, let height = proposal.height {
            return controller.sizeThatFits(in: CGSize(width: width, height: height))
        }
        let ideal = controller.view.intrinsicContentSize
        return controller.sizeThatFits(in: CGSize(width: proposal.width ?? ideal.width, height: proposal.height ?? ideal.height))
    }

    func follow(shift: CGVector, titleCut: CGFloat) {
        guard shift != self.shift || titleCut != self.titleCut else { return }
        self.shift = shift
        self.titleCut = titleCut
        update()
    }

    /// 整段交给 Core Animation（Mac 原生台面的窗口动画，见 HostedContentLink.animate）：平移和标题右边的截法按每一帧走，停在最后一帧。
    /// 有哪一帧要截，遮罩就整段挂着，不截的那几帧遮罩放开到整个宽度。
    func follow(_ frames: [(shift: CGVector, titleCut: CGFloat)], duration: TimeInterval) {
        guard let last = frames.last, let layer, let moverLayer = mover.layer else { return }
        shift = last.shift
        titleCut = last.titleCut
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        moverLayer.removeAnimation(forKey: "flight")
        clip.removeAnimation(forKey: "flight")
        flightMask = frames.contains { $0.titleCut > 0 }
        update(shift: last.shift, titleCut: last.titleCut)
        moverLayer.add(StageKeyframes.make("sublayerTransform", frames.map { NSValue(caTransform3D: translation($0.shift)) }, duration: duration),
                       forKey: "flight")
        if edge == .leading, layer.mask === clip {
            clip.add(StageKeyframes.make("path", frames.map { clipPath(shift: $0.shift, titleCut: $0.titleCut, in: layer) }, duration: duration),
                     forKey: "flight")
        }
        CATransaction.commit()
    }

    /// 交给 Core Animation 的那一段里有要截标题的帧，遮罩整段挂着（见 follow(_:duration:)）。
    private var flightMask = false

    func settleFlight() {
        update()
    }

    /// 挪到新的位置：交给 Core Animation 的那一段（有的话）收掉。
    private func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mover.layer?.removeAnimation(forKey: "flight")
        clip.removeAnimation(forKey: "flight")
        flightMask = false
        update(shift: shift, titleCut: titleCut)
        CATransaction.commit()
    }

    /// 排版、标题左边挪了：只补摆模型值，不收进行中的那一段。
    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        update(shift: shift, titleCut: titleCut)
        CATransaction.commit()
    }

    private func update(shift: CGVector, titleCut: CGFloat) {
        guard let layer else { return }
        mover.layer?.sublayerTransform = translation(shift)
        if edge == .leading, titleCut > 0 || flightMask {
            clip.frame = layer.bounds
            clip.path = clipPath(shift: shift, titleCut: titleCut, in: layer)
            if layer.mask !== clip { layer.mask = clip }
        } else if layer.mask != nil {
            layer.mask = nil
        }
    }

    private func translation(_ shift: CGVector) -> CATransform3D {
        CATransform3DMakeTranslation(edge == .leading ? shift.dx : -shift.dx, shift.dy, 0)
    }

    /// 只截标题的右边，上下左都放开：按下时放大的玻璃不被切。不截时放开到整个宽度，路径的形状不变（同一个矩形）。
    private func clipPath(shift: CGVector, titleCut: CGFloat, in layer: CALayer) -> CGPath {
        let margin: CGFloat = 1000
        let dx = edge == .leading ? shift.dx : -shift.dx
        let right = titleCut > 0 ? max(title.minX, bounds.width - titleCut) + dx : bounds.width + margin
        var rect = CGRect(x: -margin, y: -margin, width: right + margin, height: bounds.height + 2 * margin)
        if !layer.contentsAreFlipped() { rect.origin.y = bounds.height - rect.maxY }
        return CGPath(rect: rect, transform: nil)
    }
}
#endif

#if os(iOS)
/// 外面按停着的位置摆；里面一层按飞行中的挪动平移，标题右边截掉的部分是这一层图层上的遮罩。同 Mac 版。
private final class HeaderAnchorContainer: UIView, WindowHeaderFollower {
    let content = HeaderAnchorContent()
    let controller: UIHostingController<AnyView>
    let title = WindowHeaderTitleEdge()
    private let edge: HorizontalEdge
    private weak var link: HostedContentLink?
    private let mover = UIView()
    private let clip = CAShapeLayer()
    private var shift = CGVector.zero
    private var titleCut: CGFloat = 0

    init(edge: HorizontalEdge, link: HostedContentLink) {
        self.edge = edge
        self.link = link
        controller = .init(rootView: AnyView(HeaderAnchorRoot(content: content)))
        // 量尺寸要理想大小（见 measure）；不另算安全区
        controller.sizingOptions = [.intrinsicContentSize]
        controller.safeAreaRegions = []
        super.init(frame: .zero)
        controller.view.backgroundColor = .clear
        mover.addSubview(controller.view)
        addSubview(mover)
        title.changed = { [weak self] in self?.place() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        mover.frame = bounds
        controller.view.frame = bounds
        place()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { link?.add(self) } else { link?.remove(self) }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === mover ? nil : hit
    }

    /// 没给的方向按理想大小：标题栏的高度由里面的按钮定。
    func measure(_ proposal: ProposedViewSize) -> CGSize {
        let ideal = controller.view.intrinsicContentSize
        return controller.sizeThatFits(in: CGSize(width: proposal.width ?? ideal.width, height: proposal.height ?? ideal.height))
    }

    func follow(shift: CGVector, titleCut: CGFloat) {
        guard shift != self.shift || titleCut != self.titleCut else { return }
        self.shift = shift
        self.titleCut = titleCut
        update()
    }

    /// 整段交给 Core Animation（原生台面的窗口动画，见 HostedContentLink.animate）：平移和标题右边的截法按每一帧走，停在最后一帧。
    func follow(_ frames: [(shift: CGVector, titleCut: CGFloat)], duration: TimeInterval) {
        guard let last = frames.last else { return }
        shift = last.shift
        titleCut = last.titleCut
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mover.layer.removeAnimation(forKey: "flight")
        clip.removeAnimation(forKey: "flight")
        flightMask = frames.contains { $0.titleCut > 0 }
        update(shift: last.shift, titleCut: last.titleCut)
        mover.layer.add(StageKeyframes.make("sublayerTransform", frames.map { NSValue(caTransform3D: translation($0.shift)) }, duration: duration),
                        forKey: "flight")
        if edge == .leading, layer.mask === clip {
            clip.add(StageKeyframes.make("path", frames.map { clipPath(shift: $0.shift, titleCut: $0.titleCut) }, duration: duration),
                     forKey: "flight")
        }
        CATransaction.commit()
    }

    /// 交给 Core Animation 的那一段里有要截标题的帧，遮罩整段挂着。
    private var flightMask = false

    func settleFlight() {
        update()
    }

    private func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mover.layer.removeAnimation(forKey: "flight")
        clip.removeAnimation(forKey: "flight")
        flightMask = false
        update(shift: shift, titleCut: titleCut)
        CATransaction.commit()
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        update(shift: shift, titleCut: titleCut)
        CATransaction.commit()
    }

    private func update(shift: CGVector, titleCut: CGFloat) {
        mover.layer.sublayerTransform = translation(shift)
        if edge == .leading, titleCut > 0 || flightMask {
            clip.frame = layer.bounds
            clip.path = clipPath(shift: shift, titleCut: titleCut)
            if layer.mask !== clip { layer.mask = clip }
        } else if layer.mask != nil {
            layer.mask = nil
        }
    }

    private func translation(_ shift: CGVector) -> CATransform3D {
        CATransform3DMakeTranslation(edge == .leading ? shift.dx : -shift.dx, shift.dy, 0)
    }

    /// 只截标题的右边，上下左都放开：按下时放大的玻璃不被切。不截时放开到整个宽度，路径的形状不变（同一个矩形）。
    private func clipPath(shift: CGVector, titleCut: CGFloat) -> CGPath {
        let margin: CGFloat = 1000
        let dx = edge == .leading ? shift.dx : -shift.dx
        let right = titleCut > 0 ? max(title.minX, bounds.width - titleCut) + dx : bounds.width + margin
        return CGPath(rect: CGRect(x: -margin, y: -margin, width: right + margin, height: bounds.height + 2 * margin), transform: nil)
    }
}
#endif

