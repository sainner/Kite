#if os(macOS)
import AppKit
import SwiftUI

/// 操作栏上的一个按钮：名字（不显示，悬停提示、读屏读）、图标、是不是危险操作（红）、能不能按、按了做什么。
struct ActionItem {
    let title: String
    let icon: String
    var destructive = false
    var enabled = true
    let perform: @MainActor () -> Void
}

/// 原生行给列表的操作栏：和这一行的哪一边对齐、上面的按钮。没有操作栏给 nil。
@MainActor protocol ActionBarProviding: AnyObject {
    func actionItems() -> (side: HorizontalEdge, items: [ActionItem])?
}

/// Mac 原生对话的操作栏，照 ActionBar 和 PaneHeaderButtonGroup：一排只有图标的按钮包在一块可交互的玻璃胶囊里，
/// 按钮 16 pt 见方的图标左右各留半个按钮间距（共 28 宽、36 高），两端再留 paneHeaderGroupInset；悬停垫灰圆（上下缩 4、左右不缩，相邻两圆挨着），
/// 按下深一点，停用淡到 0.45，危险操作是红色。
/// 出现时整条从贴着这一行、靠 side 那边的角等比放大（0.3 起，弹簧 0.35 秒、回弹 0.3），边放大边淡显；收起时缩回那个角（snappy 0.2 秒），
/// 边缩边淡出。和 ActionBar 一样只改整体的缩放，不改尺寸，玻璃和按钮当一整层放大，里面不重排。
final class ActionBarView: NSView {
    private let glass = NSGlassEffectView()
    private let row = FlippedLayerView()
    private var buttons: [ActionBarButton] = []
    /// 贴着这一行的那个角（视图坐标）。
    private var corner = CGPoint.zero

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        glass.style = .regular
        if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
        glass.contentView = row
        addSubview(glass)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(TranscriptSpeech.actions)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 一个按钮多宽：图标的宽加左右各半个按钮间距。
    private static var buttonWidth: CGFloat { InputMode.current.labelExtent + Metrics.paneHeaderButtonGap }

    /// 换上按钮。只是能不能按、按了做什么变了时留着原来的按钮（悬停、按下状态不丢）。
    func show(_ items: [ActionItem]) {
        if buttons.map(\.title) != items.map(\.title) || buttons.map(\.icon) != items.map(\.icon) {
            for button in buttons { button.removeFromSuperview() }
            buttons = items.map { _ in ActionBarButton() }
            for button in buttons { row.addSubview(button) }
        }
        for (button, item) in zip(buttons, items) { button.configure(item) }
        let size = fittingSize
        setFrameSize(size)
        needsLayout = true
    }

    override var fittingSize: NSSize {
        NSSize(width: Metrics.paneHeaderGroupInset * 2 + Self.buttonWidth * CGFloat(buttons.count), height: Metrics.paneHeaderButton)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        glass.cornerRadius = bounds.height / 2
        row.frame = glass.bounds
        var x = Metrics.paneHeaderGroupInset
        for button in buttons {
            button.frame = CGRect(x: x, y: 0, width: Self.buttonWidth, height: Metrics.paneHeaderButton)
            x += Self.buttonWidth
        }
    }

    /// 从 side、from 那个角放大出来。
    func appear(side: HorizontalEdge, from: VerticalEdge) {
        corner = CGPoint(x: side == .leading ? 0 : bounds.width, y: from == .top ? 0 : bounds.height)
        animate(scale: 1, opacity: 1, from: (0.3, 0), spring: CASpringAnimation(perceptualDuration: 0.35, bounce: 0.3))
    }

    /// 缩回角上，播完调 done。
    func disappear(_ done: @escaping () -> Void) {
        let current = layer?.presentation()
        let scale = current.map { CGFloat(($0.value(forKeyPath: "transform.scale.x") as? NSNumber)?.doubleValue ?? 1) } ?? 1
        let opacity = CGFloat(current?.opacity ?? 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        animate(scale: 0.3, opacity: 0, from: (scale, opacity), spring: CASpringAnimation(perceptualDuration: 0.2, bounce: 0.15))
        CATransaction.commit()
    }

    /// 绕 corner 缩放：翻转坐标的视图，图层坐标同视图坐标、锚点在左上（同 BubbleView）。
    private func transform(scale: CGFloat) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(-corner.x, -corner.y, 0)
        transform = CATransform3DConcat(transform, CATransform3DMakeScale(scale, scale, 1))
        return CATransform3DConcat(transform, CATransform3DMakeTranslation(corner.x, corner.y, 0))
    }

    private func animate(scale: CGFloat, opacity: CGFloat, from: (scale: CGFloat, opacity: CGFloat), spring: CASpringAnimation) {
        guard let layer else { return }
        let target = transform(scale: scale)
        let scaling = spring.copy() as! CASpringAnimation
        scaling.keyPath = "transform"
        scaling.fromValue = transform(scale: from.scale)
        scaling.toValue = target
        scaling.duration = scaling.settlingDuration
        let fading = spring.copy() as! CASpringAnimation
        fading.keyPath = "opacity"
        fading.fromValue = from.opacity
        fading.toValue = opacity
        fading.duration = fading.settlingDuration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = target
        layer.opacity = Float(opacity)
        layer.add(scaling, forKey: "transform")
        layer.add(fading, forKey: "opacity")
        CATransaction.commit()
    }
}

/// 操作栏上的一个按钮，照 PaneHeaderButtonStyle 和 PaneHeaderButtonLabel：图标按正文字号、放在 16 pt 见方的格子正中，
/// 悬停、按下垫灰圆（见 Metrics.paneHeaderHighlightInset），停用整体淡到 0.45，按下不变淡。
final class ActionBarButton: HighlightButton {
    private let image = NSImageView()
    private(set) var title = ""
    private(set) var icon = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        inset = CGSize(width: Metrics.paneHeaderHighlightSideInset, height: Metrics.paneHeaderHighlightInset)
        pressedOpacity = 1
        image.imageScaling = .scaleNone
        image.hideFromAccessibility()
        addSubview(image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: ActionItem) {
        if title != item.title || icon != item.icon {
            title = item.title
            icon = item.icon
            toolTip = item.title
            let font = Theme.body.resolve(in: EnvironmentValues().fontResolutionContext).ctFont as NSFont
            let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
            image.image = NSImage(systemSymbolName: item.icon, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            needsLayout = true
        }
        // 玻璃上的 Color.primary 是不透明的文字色（逐像素对过），不是带透明度的 labelColor
        image.contentTintColor = item.destructive ? NSColor(named: "Danger") ?? .systemRed : .textColor
        isEnabled = item.enabled
        action = item.perform
    }

    /// 图标在 16 pt 见方的格子里居中，格子在按钮正中。横向按图标的对齐宽度居中、取到像素（SwiftUI 的符号图片就这么宽，图片的尺寸是往上取整的），逐像素对过。
    override func layout() {
        super.layout()
        let size = image.image?.size ?? .zero
        let width = image.image?.alignmentRect.width ?? size.width
        let box = InputMode.current.labelExtent
        let boxOrigin = CGPoint(x: (bounds.width - box) / 2, y: (bounds.height - box) / 2)
        let x = ((boxOrigin.x + (box - width) / 2) * 2).rounded() / 2
        image.frame = CGRect(x: x, y: boxOrigin.y + (box - size.height) / 2, width: size.width, height: size.height)
    }

    override func accessibilityLabel() -> String? { title }
}
#endif
