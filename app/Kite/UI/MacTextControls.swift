#if os(macOS)
import AppKit

// Mac 原生对话的行和嵌在正文里的卡片共用的几个小控件。

/// 一行字，按字形的宽排，放不下末尾截成省略号。SwiftUI 的 lineLimit(1) Text 那样从 0 起画，不像 NSTextField 两边带单元格边距。
/// 读屏时是一段静态的字（生成中的思考）；只作说明、由别处读出来的，用的地方 setAccessibilityElement(false)。
final class LineLabel: NSView {
    private var text = NSAttributedString()
    private var font = NSFont.systemFont(ofSize: 11)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(_ string: String, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        self.font = font
        setAccessibilityValue(string)
        needsDisplay = true
    }

    /// 不截时多宽。
    var textWidth: CGFloat { ceil(text.size().width) }
    /// 不截时多宽，往上取到像素（SwiftUI 的 Text 就这么宽），不取整到点。
    var exactWidth: CGFloat { (text.size().width * 2).rounded(.up) / 2 }

    /// 一行字的高。
    var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }

    override func draw(_ dirtyRect: NSRect) {
        text.draw(with: CGRect(x: 0, y: 0, width: bounds.width, height: lineHeight),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// 只有一行字的按钮，同 SwiftUI 的 plain 按钮：不画底，按下没有反馈；停用时字淡一半、指针不变手形。
/// 换字（显示原文、收起原文）时两种字交叉淡变，宽度在两者之间，见 switchTitle。
final class TextButton: NSView {
    var action: (() -> Void)?
    /// 直接换字，不淡变。
    var title = "" {
        didSet {
            guard title != oldValue else { return }
            previous = ""
            fraction = 1
            restyle()
        }
    }
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            alphaValue = isEnabled ? 1 : 0.5
            window?.invalidateCursorRects(for: self)
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }
    /// 换字换到了哪：0 是旧字，1 是新字。外面跟着动画给。
    var fraction: CGFloat = 1 {
        didSet {
            guard fraction != oldValue else { return }
            if fraction >= 1 { previous = "" }
            superview?.needsLayout = true
            needsLayout = true
        }
    }
    private let current = LineLabel()
    private let old = LineLabel()
    private var previous = ""
    private var font = NSFont.systemFont(ofSize: 11)
    private var color = NSColor.controlAccentColor

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        addSubview(old)
        addSubview(current)
        for label in [old, current] { label.setAccessibilityElement(false) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func style(font: NSFont, color: NSColor) {
        self.font = font
        self.color = color
        restyle()
    }

    /// 换成新字，从旧字淡变过去：fraction 从 0 走到 1。
    func switchTitle(to title: String) {
        let from = self.title
        self.title = title
        previous = from
        fraction = 0
        restyle()
    }

    private func restyle() {
        current.set(title, font: font, color: color)
        old.set(previous, font: font, color: color)
        setAccessibilityLabel(title)
        superview?.needsLayout = true
        needsLayout = true
    }

    var lineHeight: CGFloat { current.lineHeight }

    /// 眼下多宽：换字途中在两种字的宽之间。
    var width: CGFloat {
        previous.isEmpty ? current.textWidth : old.textWidth + (current.textWidth - old.textWidth) * fraction
    }

    override func layout() {
        super.layout()
        current.frame = CGRect(x: 0, y: 0, width: current.textWidth, height: bounds.height)
        old.frame = CGRect(x: 0, y: 0, width: old.textWidth, height: bounds.height)
        current.alphaValue = previous.isEmpty ? 1 : fraction
        old.alphaValue = previous.isEmpty ? 0 : 1 - fraction
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action?()
        return true
    }
}

extension NSImageView {
    /// 只作装饰的图标，读屏不读：图片视图的读屏元素是它的单元格，要一起关掉。
    func hideFromAccessibility() {
        setAccessibilityElement(false)
        cell?.setAccessibilityElement(false)
    }
}

/// 翻转坐标、带图层的视图：截住正文、横着滚的内容这类用。
final class FlippedLayerView: NSView {
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
#endif
