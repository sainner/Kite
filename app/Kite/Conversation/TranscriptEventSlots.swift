#if os(macOS)
import AppKit
import SwiftUI

/// 来信（代理来信、Kite 的通知）气泡上面那一行：图标（头像大小，见 Notice.mark：Kite 的是 agentBubble 底色的圆、中间次要色的铃铛，还没有 Kite 自己的图标，先用它；
/// 用户、代理和 Line 的是头像）、间距 6、那一句（通知的种类、来信的发信方，放不下截掉）、间距 8、小号箭头，竖着居中，字和箭头是次要色。
/// 宽是内容的宽，整块可点，指针是手形；读屏读成展开收起的三角。
final class LetterHeaderView: NativeButton {
    /// 和下面的气泡之间。
    static let gap: CGFloat = 8
    /// 箭头转了多少：0 朝右，1 朝下。
    var turn: CGFloat {
        get { chevron.turn }
        set { chevron.turn = newValue }
    }
    var expanded = false {
        didSet { if expanded != oldValue { NSAccessibility.post(element: self, notification: .valueChanged) } }
    }
    private let icon = NSImageView()
    private let badge = CALayer()
    private let title = LineLabel()
    private let chevron = TurningChevron()
    /// 图标那个圆的直径。
    private var diameter: CGFloat = 0
    private var shown: (mark: Notice.Mark, environment: EnvironmentValues)?
    private var speech = ""

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(badge)
        addSubview(icon)
        addSubview(title)
        addSubview(chevron)
        icon.hideFromAccessibility()
        chevron.hideFromAccessibility()
        title.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// environment：画图标用的环境。
    func show(_ heading: LetterHeading, font: NSFont, environment: EnvironmentValues) {
        let secondary = NSColor.secondaryLabelColor
        speech = heading.speech
        title.set(heading.title, font: font, color: secondary)
        diameter = AgentAvatar.inlineDiameter(font: font.pointSize)
        shown = (heading.mark, environment)
        drawMark()
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular, scale: .small)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        chevron.contentTintColor = secondary
        needsLayout = true
    }

    /// 铃铛是圆底上的符号，头像按屏幕的倍率画成位图放进圆那层。
    private func drawMark() {
        guard let shown else { return }
        let scale = window?.backingScaleFactor ?? 2
        let environment = shown.environment
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badge.contentsScale = scale
        switch shown.mark {
        case .kite:
            badge.contents = nil
            badge.backgroundColor = Theme.agentBubble.resolve(in: environment).cgColor
            let symbol = NSImage.SymbolConfiguration(pointSize: (diameter * 0.5).rounded(), weight: .medium)
            icon.image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?.withSymbolConfiguration(symbol)
            icon.contentTintColor = .secondaryLabelColor
        case .user:
            badge.contents = SidebarAvatar.still(environment: environment, diameter: diameter, scale: scale)
            badge.backgroundColor = nil
            icon.image = nil
        case .agent(let instance):
            badge.contents = AgentAvatar.still(design: AgentAvatar.design(for: instance, environment: environment), instance: instance,
                                               diameter: diameter, scale: scale, environment: environment)
            badge.backgroundColor = nil
            icon.image = nil
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawMark()
    }

    /// 那一句从哪起。
    private var textX: CGFloat { diameter + 6 }
    var height: CGFloat { max(title.lineHeight, diameter) }
    /// 内容的宽：图标、那一句、箭头。
    var width: CGFloat { textX + title.textWidth + 8 + (chevron.image?.size.width ?? 0) }

    override func layout() {
        super.layout()
        let line = title.lineHeight
        let circle = CGRect(x: 0, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badge.frame = circle
        badge.cornerRadius = diameter / 2
        CATransaction.commit()
        icon.frame = circle
        let imageSize = chevron.image?.size ?? .zero
        let titleWidth = min(title.textWidth, max(bounds.width - textX - 8 - imageSize.width, 0))
        title.frame = CGRect(x: textX, y: (bounds.height - line) / 2, width: titleWidth, height: line)
        chevron.place(CGRect(x: textX + titleWidth + 8, y: (bounds.height - imageSize.height) / 2, width: imageSize.width, height: imageSize.height))
    }

    override func drawFocusRingMask() { bounds.fill() }

    override func accessibilityRole() -> NSAccessibility.Role? { .disclosureTriangle }
    override func accessibilityLabel() -> String? { speech }
    override func accessibilityValue() -> Any? { expanded ? 1 : 0 }
    override func isAccessibilityExpanded() -> Bool { expanded }
}

#endif
