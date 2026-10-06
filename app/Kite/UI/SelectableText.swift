#if os(iOS)
import SwiftUI
import UIKit

/// iPhone 用户消息的一段普通文字，斜杠命令的命令名在最前面；颜色由气泡状态决定。
/// 独立代码块由 MessageText 使用共用 CodeBlock 排版。
struct SelectableText: View {
    let text: String
    let command: String?
    let color: UIColor
    let showActions: () -> Void
    let dismissActions: () -> Void

    var body: some View {
        SelectableTextView(text: attributed, inset: .zero, fillsWidth: false, showActions: showActions, dismissActions: dismissActions)
    }

    private var attributed: NSAttributedString {
        let result = NSMutableAttributedString()
        if let command {
            let code = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
            result.append(NSAttributedString(string: command, attributes: [.font: code, .foregroundColor: color]))
            if !text.isEmpty { result.append(NSAttributedString(string: " ")) }
        }
        result.append(NSAttributedString(string: text, attributes: [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: color]))
        return result
    }
}

/// UIKit 的文本视图，用来在 iPhone 上选字：SwiftUI 的 Text 在 iPhone 上只能长按整段拷贝，不告诉手指下面是第几个字，
/// 也画不了选区。点一下只处理链接与取消选区；长按不动显示操作栏；
/// 长按以后接着拖就是选字，从按下的那个字选到手指下面，开始选时轻震一下、调 dismissActions（操作栏自己收起），
/// 松手留着选区和系统的编辑菜单。长按期间对话不滚动，所以不和滚动抢。
/// 平时不开系统的选字，免得长按、双击时它自己选一个词、弹出编辑菜单。
/// fillsWidth：占满给的宽度；不然贴着字的宽度，长的折行。
struct SelectableTextView: UIViewRepresentable {
    @Environment(\.openURL) private var openURL
    let text: NSAttributedString
    let inset: CGSize
    let fillsWidth: Bool
    let showActions: () -> Void
    let dismissActions: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.linkTextAttributes = [.foregroundColor: UIColor.link]
        // 行内代码的底色、引用的竖线由自己的排版片段画，要在放字之前接上
        view.textLayoutManager?.delegate = context.coordinator
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.press(_:)))
        press.minimumPressDuration = 0.4
        press.allowableMovement = 8
        view.addGestureRecognizer(press)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: press)
        view.addGestureRecognizer(tap)
        let menu = UIEditMenuInteraction(delegate: nil)
        view.addInteraction(menu)
        context.coordinator.view = view
        context.coordinator.menu = menu
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.textContainerInset = UIEdgeInsets(top: inset.height, left: inset.width, bottom: inset.height, right: inset.width)
        let textChanged = context.coordinator.shown?.string != text.string
        // 外观变化时也换掉已经解析成 CGColor 的装饰；只换颜色时保留选区。
        if context.coordinator.shown != text || context.coordinator.colorScheme != context.environment.colorScheme {
            let selection = view.selectedRange
            let selectable = view.isSelectable
            context.coordinator.refreshingAppearance = !textChanged
            context.coordinator.shown = text
            context.coordinator.colorScheme = context.environment.colorScheme
            view.attributedText = text
            if !textChanged {
                view.isSelectable = selectable
                view.selectedRange = selection
            }
            context.coordinator.refreshingAppearance = false
        }
    }

    /// 高度照文本视图自己排出来的算。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        let most = (proposal.width ?? .greatestFiniteMagnitude) - inset.width * 2
        var width = most
        if !fillsWidth || proposal.width == nil {
            let natural = text.boundingRect(with: CGSize(width: most, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            // 多留一点，免得文本视图排出来比量的宽、多折一行
            width = min(ceil(natural.width) + 1, most)
        }
        width += inset.width * 2
        let height = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate, NSTextLayoutManagerDelegate {
        var parent: SelectableTextView?
        /// 文本视图里现在放的字。
        var shown: NSAttributedString?
        var colorScheme: ColorScheme?
        var refreshingAppearance = false
        weak var view: UITextView?
        var menu: UIEditMenuInteraction?
        /// 长按的地方和那里的字；接着拖挪过 slop 才算选字。
        private var start: CGPoint = .zero
        private var anchor: UITextPosition?
        private var selecting = false
        private static let slop: CGFloat = 8

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            parent?.dismissActions()
            // 有选区时点一下只是取消选区
            if view.selectedRange.length > 0 {
                endSelection()
                return
            }
            // 平时没开系统的选字，链接自己不响应，点在链接上由这里打开
            if let url = link(at: gesture.location(in: view)) {
                parent?.openURL(url)
                return
            }
        }

        private func link(at point: CGPoint) -> URL? {
            guard let view, let range = view.characterRange(at: point) else { return nil }
            // 按手指下的字符命中，不用最近插入点，避免点在链接末字右半边时落到下一个字符。
            // UIKit 在文字以外也可能返回最近字符，要确认点在字上。
            guard view.firstRect(for: range).insetBy(dx: -4, dy: -4).contains(point) else { return nil }
            let offset = view.offset(from: view.beginningOfDocument, to: range.start)
            guard offset >= 0, offset < view.attributedText.length else { return nil }
            return view.attributedText.attribute(.link, at: offset, effectiveRange: nil) as? URL
        }

        @objc func press(_ gesture: UILongPressGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            switch gesture.state {
            case .began:
                endSelection()
                start = point
                anchor = view.closestPosition(to: point)
                selecting = false
                parent?.showActions()
            case .changed:
                if !selecting {
                    guard hypot(point.x - start.x, point.y - start.y) > Self.slop else { return }
                    selecting = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    parent?.dismissActions()
                    view.isSelectable = true
                    view.becomeFirstResponder()
                }
                guard let anchor, let current = view.closestPosition(to: point) else { return }
                let forward = view.compare(anchor, to: current) != .orderedDescending
                view.selectedTextRange = view.textRange(from: forward ? anchor : current, to: forward ? current : anchor)
            case .ended:
                // 松手留着选区，弹出系统的编辑菜单（拷贝、全选这些）
                if selecting, view.selectedRange.length > 0 {
                    menu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
                } else if selecting {
                    endSelection()
                }
                selecting = false
                anchor = nil
            default:
                parent?.dismissActions()
                if selecting { endSelection() }
                selecting = false
                anchor = nil
            }
        }

        /// 系统自己把选区清掉了（点了别处、拷贝完），关回平时的样子
        func textViewDidChangeSelection(_ view: UITextView) {
            guard !refreshingAppearance else { return }
            if !selecting, view.isSelectable, view.selectedRange.length == 0 { endSelection() }
        }

        private func endSelection() {
            guard let view, view.isSelectable else { return }
            view.selectedTextRange = nil
            view.isSelectable = false
            view.resignFirstResponder()
        }

        // TextKit 的回调不在主线程隔离里，绘制参数都跟着字放在不可变属性里。
        nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                                           in textElement: NSTextElement) -> NSTextLayoutFragment {
            let paragraph = (textElement as? NSTextParagraph)?.attributedString
            if let paragraph, paragraph.length > 0 {
                let decoration = paragraph.attribute(.quoteDecoration, at: 0, effectiveRange: nil) as? QuoteDecoration
                var hasInlineCode = false
                paragraph.enumerateAttribute(.inlineCodeDecoration, in: NSRange(location: 0, length: paragraph.length)) { value, _, stop in
                    if value is InlineCodeDecoration {
                        hasInlineCode = true
                        stop.pointee = true
                    }
                }
                if decoration != nil || hasInlineCode {
                    return DecoratedFragment(textElement: textElement, range: textElement.elementRange,
                                             decoration: decoration, hasInlineCode: hasInlineCode)
                }
            }
            return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
    }
}
#endif
