#if os(macOS)
import AppKit
import SwiftUI

/// 会话里发生的事，不是谁说的话：图标连着一段次要字号的字，后台任务的通知、打断、调用模型出错（红）。字能选，复制给原文。
final class EventRowSlot: TranscriptRowSlot {
    private let container = SymbolTextView()

    override var hasView: Bool { true }
    override var view: NSView { container }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext) {
        super.update(row, context: context)
        guard case .item(let item) = row.content else { return }
        let environment = context.environment
        let font = Theme.secondary.resolve(in: environment.fontResolutionContext).ctFont as NSFont
        let secondary = NSColor.secondaryLabelColor
        switch item.kind {
        case .notification(let text):
            container.show(text, symbol: "bell", font: font, color: secondary, label: TranscriptSpeech.notification)
        case .interrupted:
            container.show(TranscriptSpeech.interrupted, symbol: "hand.raised", font: font, color: secondary, label: nil)
        case .apiError(let text):
            let danger = NSColor(cgColor: Theme.danger.resolve(in: environment).cgColor) ?? .systemRed
            container.show(text, symbol: "exclamationmark.triangle", font: font, color: danger, label: TranscriptSpeech.apiError)
        default:
            break
        }
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        let height = container.height(width: width)
        measured = (width, height)
        return height
    }
}

/// Kite 发给 agent 的消息：圆角描边的框，里面上面一行「Kite 发给 agent」带图标，下面正文（能选），都是次要色。
final class KiteRowSlot: TranscriptRowSlot {
    private let container = KiteRowView()

    override var hasView: Bool { true }
    override var view: NSView { container }

    override func update(_ row: TranscriptRow, context: TranscriptRowContext) {
        super.update(row, context: context)
        guard case .item(let item) = row.content, case .kite(let text) = item.kind else { return }
        container.show(text, environment: context.environment)
    }

    override func height(width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        let height = container.height(width: width)
        measured = (width, height)
        return height
    }
}

/// Kite 发来的消息的框：12 的内边距，标签和正文之间 6，描边按 contentRadius 的连续圆角画在边框以内（strokeBorder）。
final class KiteRowView: NSView {
    private let border = CAShapeLayer()
    private let header = SymbolLineView()
    private let text = ProseTextView.makeReadOnly()
    private var borderColor: Color = Theme.rule

    private static let padding: CGFloat = 12
    private static let spacing: CGFloat = 6

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        border.fillColor = nil
        border.lineWidth = 1
        layer?.addSublayer(border)
        addSubview(header)
        addSubview(text)
        // 标签只是说明，读屏时由正文读出来（见 SymbolLineView）
        text.setAccessibilityLabel(TranscriptSpeech.kite)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ string: String, environment: EnvironmentValues) {
        let context = environment.fontResolutionContext
        let secondary = NSColor.secondaryLabelColor
        header.show(TranscriptSpeech.kite, symbol: "arrow.triangle.merge",
                    font: Theme.secondary.resolve(in: context).ctFont as NSFont, color: secondary)
        text.showPlain(string, font: Theme.body.resolve(in: context).ctFont as NSFont, color: secondary)
        border.strokeColor = Theme.rule.resolve(in: environment).cgColor
        needsLayout = true
    }

    /// 正文按 SwiftUI 的 Text 那样取到像素（不往上取整到点），不然一行字多出零点几点。
    func height(width: CGFloat) -> CGFloat {
        let inner = max(width - Self.padding * 2, 0)
        return Self.padding * 2 + header.height + Self.spacing + text.measurePixel(lineWidth: inner)
    }

    override func layout() {
        super.layout()
        let inner = max(bounds.width - Self.padding * 2, 0)
        header.frame = CGRect(x: Self.padding, y: Self.padding, width: inner, height: header.height)
        let top = header.frame.maxY + Self.spacing
        text.frame = CGRect(x: Self.padding, y: top, width: inner, height: max(bounds.height - Self.padding - top, 0))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = bounds
        // strokeBorder 把形状往里缩半个线宽，圆角跟着小半个线宽
        border.path = RoundedRectangle(cornerRadius: Metrics.contentRadius, style: .continuous).inset(by: 0.5)
            .path(in: bounds).cgPath
        CATransaction.commit()
    }
}

/// SwiftUI 的 Label 排法：符号图标在前，后面跟一行字（不选、不折，放不下截掉）。
final class SymbolLineView: NSView {
    private let icon = NSImageView()
    private let label = LineLabel()
    private var font = NSFont.systemFont(ofSize: 11)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        addSubview(icon)
        addSubview(label)
        // 读屏由这一行的正文带着读，标签本身不读
        icon.hideFromAccessibility()
        label.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ text: String, symbol: String, font: NSFont, color: NSColor) {
        self.font = font
        icon.image = SymbolLabelMetrics.image(symbol, font: font)
        icon.contentTintColor = color
        label.set(text, font: font, color: color)
        needsLayout = true
    }

    var height: CGFloat { label.lineHeight }

    override func layout() {
        super.layout()
        let metrics = SymbolLabelMetrics(font: font, image: icon.image)
        icon.frame = metrics.iconFrame(lineTop: 0)
        label.frame = CGRect(x: metrics.textX, y: 0, width: max(bounds.width - metrics.textX, 0), height: bounds.height)
    }
}

/// 同上，但字能选、能折行，事件那一行用：图标对着第一行。
final class SymbolTextView: NSView {
    private let icon = NSImageView()
    let text = ProseTextView.makeReadOnly()
    private var font = NSFont.systemFont(ofSize: 11)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        addSubview(icon)
        addSubview(text)
        icon.hideFromAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// label：读屏时正文前面读的说明，正文本身就说清楚了的给 nil。
    func show(_ string: String, symbol: String, font: NSFont, color: NSColor, label: String?) {
        self.font = font
        icon.image = SymbolLabelMetrics.image(symbol, font: font)
        icon.contentTintColor = color
        text.showPlain(string, font: font, color: color)
        text.setAccessibilityLabel(label)
        needsLayout = true
    }

    func height(width: CGFloat) -> CGFloat {
        let metrics = SymbolLabelMetrics(font: font, image: icon.image)
        return text.measure(lineWidth: max(width - metrics.textX, 0))
    }

    override func layout() {
        super.layout()
        let metrics = SymbolLabelMetrics(font: font, image: icon.image)
        icon.frame = metrics.iconFrame(lineTop: 0)
        text.frame = CGRect(x: metrics.textX, y: 0, width: max(bounds.width - metrics.textX, 0), height: bounds.height)
    }
}

/// SwiftUI 的 Label 在 Mac 上怎么摆图标和字（2026-10-13 与 SwiftUI 逐像素对过，铃铛、举手、三角、合并四种图标）：
/// 字从图标的对齐宽度（NSImage.alignmentRect，SwiftUI 的图标就这么宽）后面 8 pt 起；图标和字按基线对齐，
/// 图标的基线在它对齐框的底边（离图片底边 alignmentRect.minY），整张图往上取到像素。
/// 举手这种比字高的图标，SwiftUI 会把整行撑高零点几点、字往下挪，这里不撑：图标照样按基线对齐，往上多画一点，字和行高不变。
struct SymbolLabelMetrics {
    let font: NSFont
    let image: NSImage?

    static func image(_ name: String, font: NSFont) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular, scale: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    /// 字从哪起。
    var textX: CGFloat { (image?.alignmentRect.width ?? 0) + 8 }

    /// 一行字的高。
    var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }

    /// 图标的位置：lineTop 是第一行字的顶边。
    func iconFrame(lineTop: CGFloat) -> CGRect {
        guard let image else { return .zero }
        let baseline = font.ascender + font.leading / 2
        let top = ((baseline + image.alignmentRect.minY - image.size.height) * 2).rounded(.down) / 2
        return CGRect(x: 0, y: lineTop + top, width: image.size.width, height: image.size.height)
    }
}

#endif
