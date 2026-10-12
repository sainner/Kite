#if os(iOS)
import SwiftUI
import UIKit

/// UIKit 的文本视图，用来在 iPhone 上选字：SwiftUI 的 Text 在 iPhone 上只能长按整段拷贝，不告诉手指下面是第几个字，
/// 也画不了选区。点一下只处理链接与取消选区；长按不动显示操作栏；
/// 长按以后接着拖就是选字，从按下的那个字选到手指下面，开始选时轻震一下、调 dismissActions（操作栏自己收起），
/// 松手留着选区和系统的编辑菜单。长按期间对话不滚动，所以不和滚动抢。
/// 平时不开系统的选字，免得长按、双击时它自己选一个词、弹出编辑菜单。
/// 代码块、表格这类是附件（BlockAttachment）：在卡片上长按、点按、横滑都归卡片自己（长按弹操作栏），选字从正文拖起能拖过卡片；
/// 拷贝给原文（TextSourceMap）。
/// fillsWidth：占满给的宽度；不然贴着字的宽度，长的折行。
struct SelectableTextView: UIViewRepresentable {
    @Environment(\.openURL) private var openURL
    let content: TextViewContent
    let inset: CGSize
    let fillsWidth: Bool
    let showActions: () -> Void
    let dismissActions: () -> Void

    private var text: NSAttributedString { content.text }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let view = ProseTextView(usingTextLayoutManager: true)
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
        press.delegate = context.coordinator
        view.addGestureRecognizer(press)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: press)
        tap.delegate = context.coordinator
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
        (view as? ProseTextView)?.source = content.source
        // 附件先换好内容再放字：放字时 TextKit 就会量附件的高
        context.coordinator.update(content.blocks, environment: EmbeddedEnvironment(context.environment))
        guard context.coordinator.shown != text || context.coordinator.colorScheme != context.environment.colorScheme else { return }
        // 流式回复每 33 毫秒长一截，每次整段重设 attributedText 会让 TextKit 2 把整段从头重排，真机上卡几百毫秒
        // （2026-10-11 iPhone Time Profiler）。新串只是旧串原样接着往后长、外观也没变时，只往 textStorage 末尾补字，
        // TextKit 2 从编辑处起重排；选区在前面的字上，不动它和 isSelectable。
        // 前缀用 isEqual 连属性一起比：装饰按值比，但引用图标的 NSTextAttachment 按身份比，带图标的段落会落到下面的整段路径，接受。
        // 只能碰 textStorage，读 layoutManager 会让视图退回 TextKit 1。
        if let old = context.coordinator.shown, context.coordinator.colorScheme == context.environment.colorScheme,
           text.length > old.length,
           text.attributedSubstring(from: NSRange(location: 0, length: old.length)).isEqual(to: old) {
            let added = text.attributedSubstring(from: NSRange(location: old.length, length: text.length - old.length))
            view.textStorage.replaceCharacters(in: NSRange(location: old.length, length: 0), with: added)
            context.coordinator.shown = text
            return
        }
        // 外观变化时也换掉已经解析成 CGColor 的装饰；只换颜色时保留选区。
        let textChanged = context.coordinator.shown?.string != text.string
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

    /// 高度照文本视图自己排出来的算。量过的按给的宽度记下：文本视图每量一次都把字从头排一遍，SwiftUI 一次排版会用几种宽度
    /// 把每段字各量几遍，对话一重排（发送、收到回复）就把所有消息重排几遍，主线程卡几百毫秒（2026-10-11 iPhone 实测）。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        let key = SizeKey(text: text, inset: inset, typeSize: context.environment.dynamicTypeSize,
                          weight: context.environment.legibilityWeight, blocks: context.coordinator.blocksVersion)
        if context.coordinator.sizedFor != key {
            context.coordinator.sizedFor = key
            context.coordinator.sizes = [:]
        }
        if let size = context.coordinator.sizes[proposal.width] { return size }
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
        let size = CGSize(width: width, height: height)
        context.coordinator.sizes[proposal.width] = size
        return size
    }

    /// 拷贝给原文：有对照时选区换成原文放进剪贴板，只放纯文本。
    private final class ProseTextView: UITextView {
        var source: (text: String, map: TextSourceMap)?

        override func copy(_ sender: Any?) {
            guard let source, let text = source.map.text(for: selectedRange, in: source.text) else { return super.copy(sender) }
            UIPasteboard.general.string = text
        }
    }

    /// 量出的尺寸取决于这些；变了就重新量。blocks 是附件高变了的次数。
    struct SizeKey: Equatable {
        let text: NSAttributedString
        let inset: CGSize
        let typeSize: DynamicTypeSize
        let weight: LegibilityWeight?
        let blocks: Int
    }

    final class Coordinator: NSObject, UITextViewDelegate, NSTextLayoutManagerDelegate, UIGestureRecognizerDelegate {
        var parent: SelectableTextView?
        /// 附件的高变了一次加一，量过的尺寸跟着作废。
        private(set) var blocksVersion = 0

        /// 把内容和环境交给附件。附件的高可能变了（流式时代码越来越长）就重排那一块：字没变时只有这一步，
        /// 后面接着补了字的，只补末尾的排版不会回头重排前面的附件。
        func update(_ blocks: [(attachment: BlockAttachment, content: EmbeddedBlock)], environment: EmbeddedEnvironment) {
            var changed: [BlockAttachment] = []
            for (attachment, content) in blocks {
                attachment.resized = { [weak self] in self?.relayout([$0]) }
                if attachment.update(content, environment: environment) { changed.append(attachment) }
            }
            if !changed.isEmpty, shown != nil { relayout(changed) }
        }

        /// 附件的高变了：重排它所在的那一段，作废量过的尺寸，请 SwiftUI 再量一次。
        private func relayout(_ changed: [BlockAttachment]) {
            blocksVersion += 1
            guard let view, let layout = view.textLayoutManager else { return }
            let storage = view.textStorage
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let attachment = value as? BlockAttachment, changed.contains(where: { $0 === attachment }),
                      let start = layout.location(layout.documentRange.location, offsetBy: range.location),
                      let end = layout.location(start, offsetBy: range.length),
                      let textRange = NSTextRange(location: start, end: end) else { return }
                layout.invalidateLayout(for: textRange)
            }
            view.setNeedsLayout()
            view.invalidateIntrinsicContentSize()
        }

        /// 卡片上的触摸归卡片自己：横滑、按钮、长按弹操作栏都在 SwiftUI 里，这里的点按和长按选字不接。
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var current = touch.view
            while let candidate = current, candidate !== view {
                if candidate is EmbeddedContainerView { return false }
                current = candidate.superview
            }
            return true
        }

        /// 文本视图里现在放的字。
        var shown: NSAttributedString?
        var colorScheme: ColorScheme?
        /// 量过的尺寸，按给的宽度记。
        var sizedFor: SizeKey?
        var sizes: [CGFloat?: CGSize] = [:]
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

        nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                                           in textElement: NSTextElement) -> NSTextLayoutFragment {
            DecoratedFragment.fragment(for: textElement)
        }
    }
}
#endif
