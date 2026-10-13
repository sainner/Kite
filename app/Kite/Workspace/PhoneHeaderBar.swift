#if os(iOS)
import SwiftUI
import UIKit

/// iPhone、iPad 会话窗口的标题栏，原生版：替代 PaneHeaderBar 套 PaneHeaderPlacement 的整块 SwiftUI。窗口改宽（拖缝、拖侧栏）时
/// SwiftUI 版每步把整条标题栏重排一遍，连同两侧各自的托管视图重量，iPad 真机每步约 1.5ms 一个窗口（2026-10-14，测量版拿掉标题栏对照）；
/// 原生的只按宽度重摆：信息区（状态圆环，侧栏入口）和右组菜单各是一个按自己大小摆的岛，只挪位置；标题、副标题是 UILabel，
/// 刷新图标是原生按钮，只有它们跟着宽度截断。副标题带菜单（新代理选角色）时标题整块换成岛（PaneHeaderTitle），那时窗口不常改宽。
/// 版式照 PaneHeaderBar 和 PaneHeaderPlacement：上下左右留 paneMargin（顶上补到安全区），至少一个按钮高；信息区与标题之间一个按钮间距，
/// 单独的圆环扣掉方框里已有的空白；右组前面给窗口按钮让出宽度（PaneHeaderControlsSpace），标题区让出宽度、尾部截断。
/// 后面的渐变（topFade）和滚动软边由正文那个岛的 safeAreaBar 画，见 PhoneThreadWindowView。
/// 飞行中两侧贴着外框挪、标题右边截掉（WindowHeaderFollower，同 HeaderAnchorContainer）。
final class PhoneHeaderBar: UIView, WindowHeaderFollower {
    /// 标题栏的信息：标题、副标题、刷新、副标题菜单。外面每次读模型时交过来。
    struct Content {
        var header: PaneHeader
        var openSidebar: (@MainActor () -> Void)?
    }

    private let statusIsland = HostIsland(sizing: [.intrinsicContentSize, .preferredContentSize])
    private let actionsIsland = HostIsland(sizing: [.intrinsicContentSize, .preferredContentSize])
    private let titleIsland = HostIsland(sizing: [])
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let refresh = TitleIconButton()
    /// 左右两侧：飞行中各自平移，标题右边截掉的遮罩挂在左侧。
    private let leading = UIView()
    private let trailing = UIView()
    private let titleClip = CAShapeLayer()

    private var content: Content?
    private var environment = EnvironmentValues()
    /// 顶上状态栏让出的高（紧凑布局里窗口铺满屏幕时），标题栏只补到 paneMargin。
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { changed?() ; setNeedsLayout() } }
    }
    /// 给窗口按钮让出的地方（卡片的窗口按钮露出来时），见 PaneHeaderControlsSpace。
    weak var controlsSpace: PaneCardHeader?
    /// 高变了、可点的范围变了：外面重排、报给卡片。
    var changed: (() -> Void)?
    /// 点标题栏空白处：打字时收起键盘。
    var tapped: (() -> Void)?
    private weak var link: HostedContentLink?
    private var shift = CGVector.zero
    private var titleCut: CGFloat = 0
    private var flightMask = false
    /// 字体按环境（动态字体）解析。
    private var titleFont = UIFont.preferredFont(forTextStyle: .subheadline)
    private var subtitleFont = UIFont.preferredFont(forTextStyle: .footnote)

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(leading)
        addSubview(trailing)
        leading.addSubview(statusIsland)
        leading.addSubview(titleLabel)
        leading.addSubview(subtitleLabel)
        leading.addSubview(refresh)
        leading.addSubview(titleIsland)
        trailing.addSubview(actionsIsland)
        for label in [titleLabel, subtitleLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.numberOfLines = 1
        }
        titleLabel.textColor = .label
        subtitleLabel.textColor = .secondaryLabel
        titleIsland.isHidden = true
        statusIsland.sizeChanged = { [weak self] in self?.sizeChanged() }
        actionsIsland.sizeChanged = { [weak self] in self?.sizeChanged() }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 两个岛里放的：信息区（圆环、侧栏入口，提示出现时虚化盖住）和右组菜单。身份、外观类的环境变了才换。
    func install(status: AnyView, actions: AnyView, environment: EnvironmentValues) {
        self.environment = environment
        statusIsland.rootView = status
        actionsIsland.rootView = actions
        titleFont = (Theme.secondary.weight(.semibold).resolve(in: environment.fontResolutionContext).ctFont as UIFont)
        subtitleFont = (Theme.caption.resolve(in: environment.fontResolutionContext).ctFont as UIFont)
        titleLabel.font = titleFont
        subtitleLabel.font = subtitleFont
        refresh.font = titleFont
        refresh.environment = environment
        link = environment.windowHeaderAnchors
        if window != nil { link?.add(self) }
        sizeChanged()
    }

    /// 标题、副标题、刷新：模型变了交一遍。副标题带菜单（选角色）时标题整块是岛，其余都原生。
    func update(_ content: Content, titleRoot: () -> AnyView) {
        let previous = self.content
        self.content = content
        let header = content.header
        let island = header.subtitleMenu != nil || header.badge != nil || header.titleEdit != nil
        if island {
            titleIsland.rootView = titleRoot()
        }
        titleIsland.isHidden = !island
        for view in [titleLabel, subtitleLabel] as [UIView] { view.isHidden = island }
        if previous?.header.title != header.title, previous != nil, !island {
            // 标题换字：同 SwiftUI 的 blurReplace 跟 snappy 走，这里淡入淡出
            UIView.transition(with: titleLabel, duration: 0.35, options: .transitionCrossDissolve) { self.titleLabel.text = header.title }
        } else {
            titleLabel.text = header.title
        }
        titleLabel.accessibilityLabel = header.title
        if previous?.header.subtitle != header.subtitle, previous != nil, !island {
            UIView.transition(with: subtitleLabel, duration: 0.35, options: .transitionCrossDissolve) { self.subtitleLabel.text = header.subtitle }
        } else {
            subtitleLabel.text = header.subtitle
        }
        if let action = header.titleRefresh, !island {
            refresh.isHidden = false
            refresh.configure(action, title: header.title, reduceMotion: environment.accessibilityReduceMotion)
        } else {
            refresh.isHidden = true
        }
        setNeedsLayout()
        changed?()
    }

    private func sizeChanged() {
        setNeedsLayout()
        changed?()
    }

    // MARK: - 排版

    /// 一行的高：至少一个按钮高（窗口按钮藏着时也为它留高），信息区、菜单、标题里最高的。
    private var rowHeight: CGFloat {
        let title = titleIsland.isHidden ? titleBlockHeight : titleIsland.idealSize.height
        return max(Metrics.paneHeaderButton, controlsSpace?.minHeight ?? 0, statusIsland.idealSize.height, actionsIsland.idealSize.height, title)
    }

    private var titleBlockHeight: CGFloat {
        let title = ceil(titleFont.lineHeight)
        guard subtitleLabel.text?.isEmpty == false else { return title }
        return title + 2 + ceil(subtitleFont.lineHeight)
    }

    /// 标题栏连同上下留白多高（同 PaneHeaderPlacement：顶上补到 paneMargin，底下 paneMargin）。
    var height: CGFloat {
        max(Metrics.paneMargin, topInset) - topInset + rowHeight + Metrics.paneMargin
    }

    /// 标题栏里可点的范围（这一层的坐标）：信息区、刷新图标、右组菜单，卡片拖动层在这些地方挖空。
    var interactiveRects: [CGRect] {
        var rects = [statusIsland.frame.offsetBy(dx: leading.frame.minX, dy: 0), actionsIsland.frame.offsetBy(dx: trailing.frame.minX, dy: 0)]
        if !refresh.isHidden { rects.append(refresh.frame.insetBy(dx: -Metrics.titleRefreshOutset, dy: -Metrics.titleRefreshOutset)) }
        if !titleIsland.isHidden { rects.append(titleIsland.frame) }
        return rects
    }

    /// 右组菜单多宽，给卡片的拖动层让出。
    var menuWidth: CGFloat { actionsIsland.idealSize.width }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let top = max(Metrics.paneMargin, topInset) - topInset
        let row = rowHeight
        let center = top + row / 2
        leading.frame = bounds
        trailing.frame = bounds
        // 右组：贴着右边留 paneMargin，前面给窗口按钮让出宽度
        let actions = actionsIsland.idealSize
        let actionsX = width - Metrics.paneMargin - actions.width
        place(actionsIsland, CGRect(x: actionsX, y: center - actions.height / 2, width: actions.width, height: actions.height))
        let trailingEdge = actionsX - (controlsSpace?.inset ?? 0) - (actions.width > 0 ? Metrics.paneButtonGap : 0)
        // 信息区
        let status = statusIsland.idealSize
        place(statusIsland, CGRect(x: Metrics.paneMargin, y: center - status.height / 2, width: status.width, height: status.height))
        // 标题前统一留一个按钮间距；单独显示的圆环按方框计算，扣掉方框里已有的空白
        let grouped = content?.openSidebar != nil
        let titleX = statusIsland.frame.maxX + (status.width == 0 || grouped ? Metrics.paneButtonGap : Metrics.paneButtonGap - Metrics.statusRingMargin)
        let available = max(trailingEdge - titleX, 0)
        if !titleIsland.isHidden {
            place(titleIsland, CGRect(x: titleX, y: top, width: available, height: row))
        } else {
            let titleHeight = ceil(titleFont.lineHeight), subtitleHeight = ceil(subtitleFont.lineHeight)
            let block = titleBlockHeight
            let blockTop = center - block / 2
            let refreshSize = refresh.isHidden ? .zero : refresh.intrinsicContentSize
            let refreshRoom = refresh.isHidden ? 0 : refreshSize.width + Metrics.titleRefreshGap
            // 截断时标题只占截断后的字那么宽，刷新图标紧跟在省略号后面（同 SwiftUI 的 Text 在 HStack 里）
            let titleRoom = max(available - refreshRoom, 0)
            let titleWidth = min(ceil(titleLabel.textRect(forBounds: CGRect(x: 0, y: 0, width: titleRoom, height: .greatestFiniteMagnitude),
                                                         limitedToNumberOfLines: 1).width), titleRoom)
            place(titleLabel, CGRect(x: titleX, y: blockTop, width: titleWidth, height: titleHeight))
            if !refresh.isHidden {
                place(refresh, CGRect(x: titleX + titleWidth + Metrics.titleRefreshGap, y: blockTop + (titleHeight - refreshSize.height) / 2,
                                      width: refreshSize.width, height: refreshSize.height))
            }
            place(subtitleLabel, CGRect(x: titleX, y: blockTop + titleHeight + 2, width: available, height: subtitleHeight))
        }
        applyFollow(shift: shift, titleCut: titleCut)
    }

    private func place(_ view: UIView, _ frame: CGRect) {
        if view.frame != frame { view.frame = frame }
    }

    // MARK: - 命中

    /// 标题栏整条都接点按（同 SwiftUI 版的 contentShape）：空白处点了收起键盘，不落到后面的对话上。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point) else { return nil }
        let hit = super.hitTest(point, with: event)
        return hit === leading || hit === trailing || hit == nil ? self : hit
    }

    @objc private func tap(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended { tapped?() }
    }

    // MARK: - 飞行中跟着外框

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { link?.add(self) } else { link?.remove(self) }
    }

    func follow(shift: CGVector, titleCut: CGFloat) {
        guard shift != self.shift || titleCut != self.titleCut else { return }
        self.shift = shift
        self.titleCut = titleCut
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stopFlight()
        applyFollow(shift: shift, titleCut: titleCut)
        CATransaction.commit()
    }

    func follow(_ frames: [(shift: CGVector, titleCut: CGFloat)], duration: TimeInterval) {
        guard let last = frames.last else { return }
        shift = last.shift
        titleCut = last.titleCut
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stopFlight()
        flightMask = frames.contains { $0.titleCut > 0 }
        applyFollow(shift: last.shift, titleCut: last.titleCut)
        leading.layer.add(StageKeyframes.make("transform", frames.map { NSValue(caTransform3D: translation($0.shift, leading: true)) },
                                              duration: duration), forKey: "flight")
        trailing.layer.add(StageKeyframes.make("transform", frames.map { NSValue(caTransform3D: translation($0.shift, leading: false)) },
                                               duration: duration), forKey: "flight")
        if leading.layer.mask === titleClip {
            titleClip.add(StageKeyframes.make("path", frames.map { clipPath($0.titleCut) }, duration: duration), forKey: "flight")
        }
        CATransaction.commit()
    }

    func settleFlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stopFlight()
        flightMask = false
        applyFollow(shift: shift, titleCut: titleCut)
        CATransaction.commit()
    }

    private func stopFlight() {
        leading.layer.removeAnimation(forKey: "flight")
        trailing.layer.removeAnimation(forKey: "flight")
        titleClip.removeAnimation(forKey: "flight")
    }

    private func applyFollow(shift: CGVector, titleCut: CGFloat) {
        leading.layer.transform = translation(shift, leading: true)
        trailing.layer.transform = translation(shift, leading: false)
        if titleCut > 0 || flightMask {
            titleClip.frame = leading.bounds
            titleClip.path = clipPath(titleCut)
            if leading.layer.mask !== titleClip { leading.layer.mask = titleClip }
        } else if leading.layer.mask != nil {
            leading.layer.mask = nil
        }
    }

    private func translation(_ shift: CGVector, leading: Bool) -> CATransform3D {
        CATransform3DMakeTranslation(leading ? shift.dx : -shift.dx, shift.dy, 0)
    }

    /// 只截标题的右边，上下左都放开：截得再多也不截到标题前面的信息区。
    private func clipPath(_ titleCut: CGFloat) -> CGPath {
        let margin: CGFloat = 1000
        let titleStart = statusIsland.frame.maxX
        let right = titleCut > 0 ? max(titleStart, bounds.width - titleCut) : bounds.width + margin
        return CGPath(rect: CGRect(x: -margin, y: -margin, width: right + margin, height: bounds.height + 2 * margin), transform: nil)
    }

    // MARK: - 读屏

    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = [statusIsland]
            if titleIsland.isHidden {
                elements.append(titleLabel)
                if !refresh.isHidden { elements.append(refresh) }
                if subtitleLabel.text?.isEmpty == false { elements.append(subtitleLabel) }
            } else {
                elements.append(titleIsland)
            }
            elements.append(actionsIsland)
            return elements
        }
        set {}
    }
}

/// 标题尾部的刷新图标，同 PaneTitleRefreshButton 和 PaneTitleIconButtonStyle：小号图标、次要色，悬停垫灰、按下 0.7、停用 0.45；
/// 命中和悬停范围往外扩 titleRefreshOutset，不改排版；生成标题期间图标转（减少动态效果时不转）。
private final class TitleIconButton: HighlightButton {
    private let image = UIImageView()
    private var spinning = false
    var font = UIFont.preferredFont(forTextStyle: .subheadline) {
        didSet { if font != oldValue { updateImage() } }
    }
    var environment: EnvironmentValues?

    init() {
        super.init(frame: .zero)
        inset = .zero
        image.isUserInteractionEnabled = false
        image.contentMode = .center
        addSubview(image)
        updateImage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateImage() {
        let configuration = UIImage.SymbolConfiguration(font: font, scale: .small)
        image.image = UIImage(systemName: "arrow.clockwise", withConfiguration: configuration)
        image.tintColor = .secondaryLabel
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize { image.image?.size ?? .zero }

    func configure(_ refresh: PaneHeader.TitleRefresh, title: String, reduceMotion: Bool) {
        action = refresh.action
        isEnabled = refresh.enabled
        accessibilityLabel = refresh.actionLabel
        accessibilityValue = title
        let spin = refresh.isRefreshing && !reduceMotion
        guard spin != spinning else { return }
        spinning = spin
        if spin { image.addSymbolEffect(.rotate, options: .repeating) } else { image.removeAllSymbolEffects() }
    }

    /// 灰底和命中往外扩一圈。
    override func contains(_ point: CGPoint) -> Bool {
        bounds.insetBy(dx: -Metrics.titleRefreshOutset, dy: -Metrics.titleRefreshOutset).contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        image.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let area = bounds.insetBy(dx: -Metrics.titleRefreshOutset, dy: -Metrics.titleRefreshOutset)
        highlight.frame = area
        highlight.cornerRadius = min(area.width, area.height) / 2
        CATransaction.commit()
    }
}

/// 原生标题栏的信息区岛：状态圆环（提示出现时虚化盖住），左上角的窗口在侧栏收起时连同侧栏入口一块玻璃。
/// 长按、悬停说明照 PaneHeaderBar（PaneHeaderStatus）。
struct PhoneHeaderStatusRoot<Status: View>: View {
    let status: Status
    let openSidebar: (@MainActor () -> Void)?
    @Environment(\.workspacePresentation) private var presentation
    @State private var statusText: String?
    @State private var showsStatusText = false

    var body: some View {
        let statusOpensSidebar = presentation.isCompactTouch
        Group(subviews: status.environment(\.paneHeaderStatusGrouped, openSidebar != nil && !statusOpensSidebar)) { statusViews in
            HStack(spacing: 0) {
                PaneHeaderStatus(statusViews: statusViews, openSidebar: openSidebar, statusOpensSidebar: statusOpensSidebar,
                                 statusText: statusText, showsStatusText: $showsStatusText)
            }
        }
        .fixedSize()
        .onPreferenceChange(PaneHeaderStatusText.self) { statusText = $0 }
    }
}
#endif
