#if os(iOS)
import SwiftUI
import UIKit

/// 原生对话行里的按钮，照 SwiftUI 的 plain 按钮（pointingPlain）：整块可点，按下变淡、松手淡回来，iPad 指针停上去有系统的悬停效果。
/// 正文上的点按不接按钮上的点（见 gestureRecognizerShouldBegin），从按钮上拖起来照样滚对话（见 PhoneTranscriptScrollView）。
/// 折叠按钮、工具行的汇总行、压缩分界都用它；字和图标放进 content，按下时一起变淡。
class PhonePlainControl: UIControl, UIPointerInteractionDelegate {
    var action: (() -> Void)?
    let content = UIView()

    init() {
        super.init(frame: .zero)
        content.isUserInteractionEnabled = false
        addSubview(content)
        addTarget(self, action: #selector(triggered), for: .primaryActionTriggered)
        addInteraction(UIPointerInteraction(delegate: self))
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        content.frame = bounds
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            if isHighlighted {
                content.alpha = 0.2
            } else {
                UIView.animate(withDuration: 0.2) { self.content.alpha = 1 }
            }
        }
    }

    @objc private func triggered() {
        action?()
    }

    /// 正文上的点按（取消选区、点链接）不接按钮上的点：不然点按一识别就把按钮的触摸取消了，按钮收不到松手。长按照样接。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UITapGestureRecognizer, gestureRecognizer.view !== self { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(effect: .automatic(UITargetedPreview(view: self)))
    }
}

/// 一段字，排法同 SwiftUI 的 Text：断行按系统标准的策略（.standard，中文不把一个词拆到两行，Text 也是这样；
/// CoreText 和不设策略的 TextKit 会拆，iPad 上并排截屏对过），一行高是字体的行高，多行时基线隔行高加行距，
/// 整段高往上取到像素（模拟器里量过 SwiftUI 的 Text）；从左上角画，lines 为 1 时放不下末尾截成省略号。
final class PhoneTextLine: UIView {
    private(set) var text = NSAttributedString()
    private var font = UIFont.preferredFont(forTextStyle: .subheadline)
    var lines = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(_ string: String, font: UIFont, color: UIColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        style.lineBreakStrategy = .standard
        text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        self.font = font
        setNeedsDisplay()
    }

    /// 不折、不截时多宽。
    var naturalWidth: CGFloat { PhonePixel.ceil(text.size().width) }

    /// 一行的高。
    var lineHeight: CGFloat { PhonePixel.ceil(font.lineHeight) }

    /// 第一行的基线离顶边多远：行高往上取整多出来的在上面，同 Text。
    var firstBaseline: CGFloat { lineHeight - font.lineHeight + font.ascender }

    /// 按 width 断出几行：TextKit 每行占行高加行距。
    private func count(width: CGFloat) -> Int {
        let bound = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return max(Int((bound.height / (font.lineHeight + font.leading)).rounded()), 1)
    }

    /// 按 width 排出来多高。
    func height(width: CGFloat) -> CGFloat {
        guard lines != 1 else { return lineHeight }
        let count = count(width: width)
        return PhonePixel.ceil(CGFloat(count) * font.lineHeight + CGFloat(count - 1) * font.leading)
    }

    /// 多行时相邻两行基线隔多远：行高加行距往上取到像素，同 Text（iPad 上并排截屏对过，第二行起差半点）。
    private var pitch: CGFloat { PhonePixel.ceil(font.lineHeight + font.leading) }

    override func draw(_ rect: CGRect) {
        guard lines != 1 else {
            // 一行：行高往上取整多出来的在上面
            text.draw(with: CGRect(x: 0, y: lineHeight - font.lineHeight, width: bounds.width, height: font.lineHeight),
                      options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
            return
        }
        // 多行：行与行按 pitch 隔开，整块贴着框的底边（框高按行高、行距算，比整块矮的那点伸到框上面），同 Text
        let count = CGFloat(count(width: bounds.width))
        let spaced = NSMutableAttributedString(attributedString: text)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineBreakStrategy = .standard
        style.lineSpacing = pitch - font.lineHeight - font.leading
        spaced.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: spaced.length))
        let block = (count - 1) * pitch + font.lineHeight
        // 给够高：最后一行底下没有行距，不给够的话最后一行放不下、不画
        spaced.draw(with: CGRect(x: 0, y: bounds.height - block, width: bounds.width, height: count * pitch),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }
}

/// 一行事件的样子，照 SwiftUI Label 的默认样式：图标按自己的大小，和字之间空 8，两者按第一行字的基线对齐（模拟器里量过）。
/// 图标是 SF Symbol，跟着字的文本样式。
final class PhoneIconLabel: UIView {
    let icon = UIImageView()
    let title = PhoneTextLine()
    private var image: UIImage?

    init(lines: Int) {
        super.init(frame: .zero)
        title.lines = lines
        addSubview(icon)
        addSubview(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(_ text: String, systemImage: String, font: UIFont, color: UIColor) {
        image = UIImage(systemName: systemImage, withConfiguration: UIImage.SymbolConfiguration(font: font))
        icon.image = image
        icon.tintColor = color
        title.set(text, font: font, color: color)
        setNeedsLayout()
    }

    private static let spacing: CGFloat = 8

    private var iconSize: CGSize { image?.size ?? .zero }
    /// 图标的基线离图标顶边多远。
    private var iconBaseline: CGFloat { iconSize.height - (image?.baselineOffsetFromBottom ?? 0) }

    /// 按 width 排出来多高：图标和字按基线对齐以后上下各伸到哪。
    func height(width: CGFloat) -> CGFloat {
        let (iconTop, titleTop) = tops
        let titleHeight = title.height(width: max(width - iconSize.width - Self.spacing, 0))
        return max(iconTop + iconSize.height, titleTop + titleHeight)
    }

    /// 图标、字的顶边：基线对齐，高出来的那个顶着 0。
    private var tops: (icon: CGFloat, title: CGFloat) {
        let shift = iconBaseline - title.firstBaseline
        return shift > 0 ? (0, shift) : (-shift, 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let (iconTop, titleTop) = tops
        let size = iconSize
        // 位置对到像素，同 SwiftUI 画的时候
        icon.frame = PhonePixel.align(CGRect(x: 0, y: iconTop, width: size.width, height: size.height))
        let x = size.width + Self.spacing
        let width = max(bounds.width - x, 0)
        title.frame = PhonePixel.align(CGRect(x: x, y: titleTop, width: width, height: title.height(width: width)))
    }
}

/// 长按一段字弹出拷贝、共享，同 SwiftUI Text 的 textSelection(.enabled)：事件、Kite 发来的话用。
@MainActor final class PhoneCopyMenu: NSObject, UIContextMenuInteractionDelegate {
    var text: () -> String = { "" }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        let text = text()
        guard !text.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: "拷贝", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = text },
                UIAction(title: "共享…", image: UIImage(systemName: "square.and.arrow.up")) { [weak interaction] _ in
                    guard let view = interaction?.view else { return }
                    var responder: UIResponder? = view
                    while let current = responder, !(current is UIViewController) { responder = current.next }
                    let share = UIActivityViewController(activityItems: [text], applicationActivities: nil)
                    share.popoverPresentationController?.sourceView = view
                    (responder as? UIViewController)?.present(share, animated: true)
                },
            ])
        }
    }
}
#endif
