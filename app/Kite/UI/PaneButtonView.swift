#if os(macOS)
import AppKit
import SwiftUI

/// 控制区和工具条按钮的原生版，照 PaneButtonStyle 与 PaneButtonHover：图标占 paneButton 见方，文字按字宽加左右 paneToolbarInset、
/// 至少 paneButton 宽；比按钮四边各缩 2 的胶囊在悬停时垫 0.10 灰、按下时 0.20 灰，按下时整个按钮 0.7 透明；
/// 实心的（发送、停止）胶囊填色，内容白色粗体，悬停、按下的灰盖在填色和内容上面（PaneButtonHover 有填色时反馈在 overlay 里）。
/// 悬停、按下、停用、手形指针、键盘、读屏和命中范围（整个按钮大小的胶囊）都是公共底子 HighlightButton 的，这里只管样子。
/// 玻璃由所在容器提供。
final class PaneButtonView: HighlightButton {
    enum Label: Equatable {
        case symbol(String)
        case text(String)
    }

    var label: Label = .symbol("circle") {
        didSet { if label != oldValue { labelChanged() } }
    }
    /// 实心按钮的填色；nil 是普通按钮。
    var fill: Color? {
        didSet {
            guard fill != oldValue else { return }
            highlightsOverContent = fill != nil || secondary
            labelChanged()
        }
    }
    /// 次级按钮：半透明灰底，字仍按 foreground、不加粗，同 PaneButtonStyle 的 secondary（审批、密钥请求的拒绝和次级的决定）。
    var secondary = false {
        didSet {
            guard secondary != oldValue else { return }
            highlightsOverContent = fill != nil || secondary
            applyColors()
        }
    }
    /// 内容色，实心按钮不用（白色）。
    var foreground: Color = .secondary {
        didSet { if foreground != oldValue { applyColors() } }
    }
    /// 解析颜色用的 SwiftUI 环境（主题色等从这里来），外观按这个视图自己的。
    var environment = EnvironmentValues() {
        didSet { applyColors() }
    }
    /// 读屏念的名字。
    var title = "" {
        didSet { setAccessibilityLabel(title) }
    }

    /// 实心按钮的填色，在最下面。
    private let fillLayer = CALayer()
    private let image = NSImageView()
    private let text = PaneButtonText()
    private var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    init() {
        super.init(frame: .zero)
        fillLayer.actions = ["backgroundColor": NSNull(), "position": NSNull(), "bounds": NSNull(), "cornerRadius": NSNull()]
        layer?.insertSublayer(fillLayer, at: 0)
        image.imageScaling = .scaleNone
        image.isEditable = false
        image.refusesFirstResponder = true
        image.hideFromAccessibility()
        addSubview(image)
        addSubview(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 正文字号；实心按钮加粗。字体随环境变时由外面再设一次。
    func setFont(_ font: NSFont) {
        guard font != self.font else { return }
        self.font = font
        labelChanged()
    }

    /// 按内容的宽：图标是 paneButton 见方，文字按字宽加两边留白，至少 paneButton。字宽在标签、字体变了时量一次，
    /// 拖缝时底栏每步都要排，不再每次量字。
    var width: CGFloat {
        switch label {
        case .symbol: Metrics.paneButton
        case .text: max(text.textWidth + 2 * Metrics.paneToolbarInset, Metrics.paneButton)
        }
    }

    private var weightedFont: NSFont {
        fill == nil ? font : NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private func labelChanged() {
        switch label {
        case .symbol(let name):
            // 实心按钮（发送、停止）的图标比普通按钮小一号，填色圆里留出更多边距。
            let size = fill == nil ? font.pointSize : font.pointSize - 3
            let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: fill == nil ? .regular : .bold, scale: .medium)
            image.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            image.isHidden = false
            text.isHidden = true
            text.set("", font: weightedFont)
        case .text(let string):
            image.image = nil
            image.isHidden = true
            text.isHidden = false
            text.set(string, font: weightedFont)
        }
        applyColors()
        needsLayout = true
    }

    private func applyColors() {
        let content = fill == nil ? resolved(foreground) : .white
        image.contentTintColor = content
        text.color = content
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.backgroundColor = (fill ?? (secondary ? PaneButtonStyle.secondaryFill : nil)).map { resolved($0).cgColor }
        CATransaction.commit()
    }

    /// 颜色按这个视图当前的外观解析成 SwiftUI 里同样的值。
    private func resolved(_ color: Color) -> NSColor {
        var environment = environment
        environment.colorScheme = effectiveAppearance.isDark ? .dark : .light
        return NSColor(cgColor: color.resolve(in: environment).cgColor) ?? .secondaryLabelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = highlight.frame
        fillLayer.cornerRadius = highlight.cornerRadius
        CATransaction.commit()
        text.frame = bounds
        if let symbol = image.image {
            // 横向按字形的对齐范围居中、取整到像素（同 SwiftUI：mic 图宽 14、对齐宽 13.5，SwiftUI 画在 7.5，按图宽居中是 7，2026-10-13 逐像素比过）
            let size = symbol.size, alignment = symbol.alignmentRect
            let scale = window?.backingScaleFactor ?? 2
            let x = (((bounds.width - alignment.width) / 2 - alignment.minX) * scale).rounded() / scale
            image.frame = CGRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        }
    }
}

/// 文字按钮的字：同 SwiftUI 的 Text，一行的高（不取整到点）居中，位置和高都取整到像素（2026-10-13 逐像素比过）。
private final class PaneButtonText: NSView {
    private var string = ""
    private var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    /// 字宽，取整到点；标签、字体变了时量一次。
    private(set) var textWidth: CGFloat = 0
    var color = NSColor.labelColor {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    func set(_ string: String, font: NSFont) {
        guard string != self.string || font != self.font else { return }
        self.string = string
        self.font = font
        textWidth = string.isEmpty ? 0 : ceil(NSAttributedString(string: string, attributes: [.font: font]).size().width)
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard !string.isEmpty else { return }
        let line = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let scale = window?.backingScaleFactor ?? 2
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let height = pixel(font.ascender - font.descender + font.leading)
        line.draw(with: CGRect(x: (bounds.width - textWidth) / 2, y: pixel((bounds.height - height) / 2), width: textWidth, height: height),
                  options: [.usesLineFragmentOrigin])
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
#endif
