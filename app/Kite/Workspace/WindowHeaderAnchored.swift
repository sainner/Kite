import SwiftUI

extension View {
    /// 标题栏的一侧按这一帧的外框贴边，见 WindowHeaderAnchored。
    func windowHeaderAnchor(_ edge: HorizontalEdge) -> some View {
        WindowHeaderAnchored(edge: edge, content: self)
    }
}

/// 标题两侧贴着外框：正文按终点排版，外框和它不一样大时（缩小、调整大小途中，或停着时外框比正文宽），两侧跟着外框的左右边和上边走。
/// Mac 上两侧按排版位置摆，挪动只改这一侧托管视图的图层（见 HeaderAnchorContainer），飞行中和停着都一样：标题栏看得见、停着时外框和正文一样大，
/// 不用挪；收成停靠形状停着时整块正文藏起来（见 WindowSurface）。不读 motion 的终点：排布一变，卡片随即把新终点交给 motion，
/// 读了的话两侧的托管视图要跟着再更新一轮。
/// 锚定若在正文的托管视图里逐帧改 SwiftUI 几何，整段正文跟着逐帧更新，玻璃按钮的 AppKit 视图逐帧改位置
/// （2026-10-12 Mac 实测，一个窗口占满台面时，缩小、恢复各多 25～45 毫秒主线程，缩小的丢帧约多一倍；只在绘制时平移没有用）。
/// 这一侧报的偏好值传不出它的托管视图，接着往上报，见 HeaderAnchorReports。
/// 滚动软边照样认得这一侧里的控件，位置也对（2026-10-12 Mac 实测，见 HostedContentContainer 里软边的那段）。
struct WindowHeaderAnchored<Content: View>: View {
    let edge: HorizontalEdge
    let content: Content
    #if os(macOS)
    @Environment(\.windowHeaderAnchors) private var anchors
    @State private var relay = HeaderAnchorRelay()
    #endif

    var body: some View {
        #if os(macOS)
        if let anchors {
            HeaderAnchorHost(edge: edge, link: anchors, relay: relay, size: relay.size, content: content)
                .modifier(HeaderAnchorReports(relay: relay))
        } else {
            content.modifier(WindowHeaderAnchor(edge: edge))
        }
        #else
        content.modifier(WindowHeaderAnchor(edge: edge))
        #endif
    }
}

#if os(macOS)
/// 标题一侧在自己的托管视图里报的偏好值和排出来的大小，由 WindowHeaderAnchored 接出来。
@MainActor @Observable private final class HeaderAnchorRelay {
    var statusText: String?
    var actionsWidth: CGFloat = 0
    var rects: [CGRect] = []
    /// 里面的内容排出来的大小：变了外面要重新量。
    var size = CGSize.zero
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

/// 标题一侧托管在自己的视图里。环境整份转交。
private struct HeaderAnchorHost<Content: View>: NSViewRepresentable {
    let edge: HorizontalEdge
    let link: HostedContentLink
    let relay: HeaderAnchorRelay
    /// 只用来让里面的尺寸变了时外面重新量。
    let size: CGSize
    let content: Content

    func makeNSView(context: Context) -> HeaderAnchorContainer {
        let container = HeaderAnchorContainer(edge: edge, link: link)
        container.controller.rootView = rooted(in: context, title: container.title)
        return container
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HeaderAnchorContainer, context: Context) -> CGSize? {
        nsView.measure(proposal)
    }

    func updateNSView(_ container: HeaderAnchorContainer, context: Context) {
        container.controller.rootView = rooted(in: context, title: container.title)
    }

    /// 偏好值和尺寸隔一拍交出去：里面的托管视图可能在外面这次更新当中排版，不能当场改外面的状态。
    private func rooted(in context: Context, title: WindowHeaderTitleEdge) -> AnyView {
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
                Task { @MainActor in if relay.size != size { relay.size = size } }
            }
            // 里面的控件按这一侧的左上角报范围，WindowHeaderAnchored 再换回标题栏的坐标
            .coordinateSpace(name: "pane-header")
            .environment(\.windowHeaderTitleEdge, title)
            .environment(\.windowHeaderAnchors, nil)
            .environment(\.self, context.environment))
    }
}

/// 外面按停着的位置摆；里面一层按飞行中的挪动平移，标题右边截掉的部分是这一层图层上的遮罩。
private final class HeaderAnchorContainer: NSView, WindowHeaderFollower {
    let controller = NSHostingController(rootView: AnyView(EmptyView()))
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
        // 量尺寸要理想大小（见 measure）；不另算安全区
        controller.sizingOptions = [.intrinsicContentSize]
        controller.safeAreaRegions = []
        super.init(frame: .zero)
        wantsLayer = true
        mover.wantsLayer = true
        mover.addSubview(controller.view)
        addSubview(mover)
        title.changed = { [weak self] in self?.update() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        mover.frame = bounds
        controller.view.frame = bounds
        update()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { link?.add(self) } else { link?.remove(self) }
    }

    /// 没给的方向按理想大小：标题栏的高度由里面的按钮定（2026-10-12 Mac 实测，给无限高时标题栏从 48 撑到 56）。
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

    private func update() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let dx = edge == .leading ? shift.dx : -shift.dx
        mover.layer?.sublayerTransform = CATransform3DMakeTranslation(dx, shift.dy, 0)
        if edge == .leading, titleCut > 0 {
            // 只截标题的右边，上下左都放开：按下时放大的玻璃不被切
            let margin: CGFloat = 1000
            let right = max(title.minX, bounds.width - titleCut) + dx
            var rect = CGRect(x: -margin, y: -margin, width: right + margin, height: bounds.height + 2 * margin)
            if !layer.isGeometryFlipped { rect.origin.y = bounds.height - rect.maxY }
            clip.frame = layer.bounds
            clip.path = CGPath(rect: rect, transform: nil)
            if layer.mask !== clip { layer.mask = clip }
        } else if layer.mask != nil {
            layer.mask = nil
        }
        CATransaction.commit()
    }
}
#endif
