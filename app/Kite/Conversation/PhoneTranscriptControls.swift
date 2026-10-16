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
        // 按 touchUpInside 接：直接继承 UIControl 的按 primaryActionTriggered 注册时，iPhone 上按下变淡、松手不触发
        // （2026-10-16：工具行汇总行、展开全文都点不开）；UIButton（NativeButton）不受影响
        addTarget(self, action: #selector(triggered), for: .touchUpInside)
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
    /// 量过的不折时多宽、按某个宽折成几行：拖缝时每步都要问，每问一次都要排一遍字。换了字作废。
    private var natural: CGFloat?
    private var counted: (width: CGFloat, count: Int)?
    /// 拖缝中折了行的先不按新宽重新断行（见 wrapWidth），由用的一方把量的高记作不准、停下后重量。
    var defersRewrap = false
    /// 拖缝中照旧按哪个宽断行、画；平常 nil，按框的宽。
    private(set) var keptWidth: CGFloat?
    /// 上次画的时候按多宽断的行。
    private var drawnWidth: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        // 改尺寸时不自动重画：放得下的字宽变了画出来也一样，拖缝时每步都在改宽，见 bounds
        contentMode = .topLeft
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 宽变了才可能要重画：两个宽都放得下不折不截的字（单行，或每段都放得下）时画出来一样，不画。
    override var bounds: CGRect {
        didSet { redrawIfNeeded(from: oldValue.size) }
    }

    override var frame: CGRect {
        didSet { redrawIfNeeded(from: oldValue.size) }
    }

    private func redrawIfNeeded(from old: CGSize) {
        let size = bounds.size
        let rewrapped = size.width != old.width && min(size.width, old.width) < naturalWidth
        if rewrapped && keptWidth == nil || size.height > old.height { setNeedsDisplay() }
    }

    func set(_ string: String, font: UIFont, color: UIColor) {
        keptWidth = nil
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        style.lineBreakStrategy = .standard
        text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        self.font = font
        natural = nil
        counted = nil
        setNeedsDisplay()
    }

    /// 不折、不截时多宽。
    var naturalWidth: CGFloat {
        if let natural { return natural }
        let width = PhonePixel.ceil(text.size().width)
        natural = width
        return width
    }

    /// 一行的高。
    var lineHeight: CGFloat { PhonePixel.ceil(font.lineHeight) }

    /// 第一行的基线离顶边多远：行高往上取整多出来的在上面，同 Text。
    var firstBaseline: CGFloat { lineHeight - font.lineHeight + font.ascender }

    /// 按 width 断出几行：TextKit 每行占行高加行距。
    private func count(width: CGFloat) -> Int {
        if let counted, counted.width == width { return counted.count }
        // 不折时放得下就是一行，不用再排
        if !text.string.contains("\n"), naturalWidth <= width { return 1 }
        let bound = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let count = max(Int((bound.height / (font.lineHeight + font.leading)).rounded()), 1)
        counted = (width, count)
        return count
    }

    /// 按 width 排出来多高。
    func height(width: CGFloat) -> CGFloat {
        guard lines != 1 else { return lineHeight }
        let count = count(width: wrapWidth(for: width))
        return PhonePixel.ceil(CGFloat(count) * font.lineHeight + CGFloat(count - 1) * font.leading)
    }

    /// 按多宽断行：平常按给的宽。拖缝中（defersRewrap）折了行的、和上次量准的宽差得不多时照旧按那个宽，不重新断行、不重画
    /// （同 PhoneProseRowSlot.keptHeight：变宽时右边空出一截，变窄时字伸进右边的留白一点）；停下后再按给的宽。
    private func wrapWidth(for width: CGFloat) -> CGFloat {
        var kept: CGFloat?
        if defersRewrap, WindowLayout.anyResizing, let counted, counted.count > 1, counted.width != width,
           rewrap.keeps(laid: counted.width, width: width) {
            kept = counted.width
        }
        if kept != keptWidth {
            keptWidth = kept
            // 停下或差得多了：按框的宽重画
            if kept == nil, let drawnWidth, drawnWidth != bounds.width { setNeedsDisplay() }
        }
        return kept ?? width
    }

    private lazy var rewrap = ResizeRewrap(self)

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
        let wrap = keptWidth ?? bounds.width
        drawnWidth = wrap
        let count = CGFloat(count(width: wrap))
        let spaced = NSMutableAttributedString(attributedString: text)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineBreakStrategy = .standard
        style.lineSpacing = pitch - font.lineHeight - font.leading
        spaced.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: spaced.length))
        let block = (count - 1) * pitch + font.lineHeight
        // 给够高：最后一行底下没有行距，不给够的话最后一行放不下、不画
        spaced.draw(with: CGRect(x: 0, y: bounds.height - block, width: wrap, height: count * pitch),
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
