#if os(macOS)
import AppKit
import SwiftUI

// Mac 原生对话的行和嵌在正文里的卡片共用的几个小控件。

/// 一行字，按字形的宽排，放不下末尾截成省略号。SwiftUI 的 lineLimit(1) Text 那样从 0 起画，不像 NSTextField 两边带单元格边距。
/// 读屏时是一段静态的字（生成中的思考）；只作说明、由别处读出来的，用的地方 setAccessibilityElement(false)。
final class LineLabel: NSView {
    private var text = NSAttributedString()
    /// 不截时多大，换字时量一次：排版每次都要看宽，拖缝时每步要排好几遍（压缩分界的标签一次排版量四遍）。
    private var size = CGSize.zero
    private var font = NSFont.systemFont(ofSize: 11)
    private var truncation: NSLineBreakMode = .byTruncatingTail

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// truncation：放不下时截哪，默认截尾。
    func set(_ string: String, font: NSFont, color: NSColor, truncation: NSLineBreakMode = .byTruncatingTail) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = truncation
        text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        size = text.size()
        self.font = font
        self.truncation = truncation
        setAccessibilityValue(string)
        needsDisplay = true
    }

    /// 不截时多宽。
    var textWidth: CGFloat { ceil(size.width) }
    /// 不截时多宽，往上取到像素（SwiftUI 的 Text 就这么宽），不取整到点。
    var exactWidth: CGFloat { (size.width * 2).rounded(.up) / 2 }

    /// 一行字的高。
    var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }

    /// 放得下照常画；放不下按字截（同 SwiftUI 的 Text，不按词截），截掉的地方一个省略号，基线不变。
    override func draw(_ dirtyRect: NSRect) {
        guard size.width > bounds.width + 0.01, let context = NSGraphicsContext.current?.cgContext else {
            text.draw(with: CGRect(x: 0, y: 0, width: bounds.width, height: lineHeight),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return
        }
        let full = CTLineCreateWithAttributedString(text)
        let attributes = text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : [:]
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let type: CTLineTruncationType = truncation == .byTruncatingMiddle ? .middle : truncation == .byTruncatingHead ? .start : .end
        let line = CTLineCreateTruncatedLine(full, Double(bounds.width), type, token) ?? full
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        // 基线同照常画的那一行：离顶边上伸加半个行距，取到像素
        context.textPosition = CGPoint(x: 0, y: bounds.height - ((font.ascender + font.leading / 2) * 2).rounded(.down) / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// 只有一行字的按钮，同 SwiftUI 的 plain 按钮：不画底，按下没有反馈；停用时字淡一半、指针不变手形。
/// 换字（显示原文、收起原文）时两种字交叉淡变，宽度在两者之间，见 switchTitle。
final class TextButton: NativeButton {
    /// 直接换字，不淡变。
    var title = "" {
        didSet {
            guard title != oldValue else { return }
            previous = ""
            fraction = 1
            restyle()
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

    override init(frame: NSRect) {
        super.init(frame: frame)
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

    /// 停用时字淡一半（SwiftUI 的 plain 按钮停用时就这样，实测）。
    override func stateChanged() {
        alphaValue = isEnabled ? 1 : 0.5
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
