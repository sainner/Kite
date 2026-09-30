#if os(iOS)
import SwiftUI
import UIKit

/// iPhone 上人发的消息的正文，样子照 MessageText：原样显示，``` 围起来的一段排成等宽、衬一个圆角底色，
/// 斜杠命令的命令名在最前面、主题色。手势见 SelectableTextView。inset 是气泡的边距，放在文本视图里面，整个气泡都能点、能选字。
struct SelectableText: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: Message
    let inset: CGSize
    let showActions: () -> Void
    let dismissActions: () -> Void

    var body: some View {
        // 有代码块时底色占满整行，气泡按能给的最宽来；没有就贴着字
        let hasCode = message.segments.contains { if case .code = $0 { true } else { false } }
        SelectableTextView(text: message.attributed(colorScheme: colorScheme), inset: inset, fillsWidth: hasCode, showActions: showActions, dismissActions: dismissActions)
    }
}

/// iPhone 上 agent 说的一段话。连续的段落、标题、引用、列表项排进同一个文本视图，选字能跨着拖；
/// 代码块、表格、分隔线照旧用 SwiftUI 排（代码块要横着滚、太长折起来，表格排不进文本视图），选字跨不过它们，
/// 长按这些块也显示操作栏。样子照 MarkdownView。
struct SelectableMarkdown: View {
    @Environment(\.referenceScope) private var referenceScope
    @Environment(\.colorScheme) private var colorScheme
    let source: String
    @State private var document = MarkdownDocument()
    let showActions: () -> Void
    let dismissActions: () -> Void

    var body: some View {
        let urls = document.blocks(for: source).flatMap { ReferenceText.decorate($0.text, scope: referenceScope).runs.compactMap(\.link) }
        VStack(alignment: .leading, spacing: Metrics.markdownBlockGap) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                switch chunk {
                case .prose(let blocks):
                    SelectableTextView(text: Self.attributed(blocks, colorScheme: colorScheme, scope: referenceScope), inset: .zero, fillsWidth: true, showActions: showActions, dismissActions: dismissActions)
                case .block(let block):
                    MarkdownBlockView(block: block)
                        .contentShape(Rectangle())
                        .highPriorityGesture(LongPressGesture(minimumDuration: 0.4, maximumDistance: 8)
                            .onEnded { _ in showActions() })
                }
            }
        }
        .task(id: urls) { await ReferenceIcons.shared.load(urls) }
    }

    private enum Chunk {
        case prose([MarkdownBlock])
        case block(MarkdownBlock)
    }

    private var chunks: [Chunk] {
        var chunks: [Chunk] = []
        for block in document.blocks(for: source) {
            switch block.kind {
            case .paragraph, .heading, .quote, .listItem:
                if case .prose(let blocks) = chunks.last {
                    chunks[chunks.count - 1] = .prose(blocks + [block])
                } else {
                    chunks.append(.prose([block]))
                }
            case .code, .table, .rule:
                chunks.append(.block(block))
            }
        }
        return chunks
    }

    /// 几块拼成一段带属性的字，块和块之间空 markdownBlockGap，标题上面再多空一点，和 MarkdownBlockView 排的一样。
    private static func attributed(_ blocks: [MarkdownBlock], colorScheme: ColorScheme, scope: ReferenceScope) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = index > 0 ? Metrics.markdownBlockGap : 0
            let indent = CGFloat(max(block.depth - 1, 0)) * Metrics.listIndent
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            var font = body
            var color = UIColor.label
            var prefix = ""
            var decoration: BlockDecoration?
            switch block.kind {
            case .heading(let level):
                font = level <= 1 ? .semibold(.title2) : level == 2 ? .semibold(.title3) : .preferredFont(forTextStyle: .headline)
                style.paragraphSpacingBefore += 4
            case .quote:
                color = .secondaryLabel
                style.firstLineHeadIndent = indent + 12
                style.headIndent = indent + 12
                decoration = BlockDecoration(kind: .quoteBar(x: indent), top: style.paragraphSpacingBefore, fill: Theme.rule.resolvedCGColor(for: colorScheme))
            case .listItem(let marker):
                // 编号靠右对齐在一格里，正文从固定的位置起，折行也对齐正文
                let text = indent + Metrics.listMarker + 6
                style.tabStops = [NSTextTab(textAlignment: .right, location: indent + Metrics.listMarker), NSTextTab(textAlignment: .left, location: text)]
                style.headIndent = text
                prefix = "\t\(marker ?? "")\t"
            default:
                break
            }
            let part = NSMutableAttributedString(string: prefix, attributes: [.font: body.monospacedDigits, .foregroundColor: color])
            let linkColor = UIColor.link.resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
            part.append(inline(ReferenceText.decorate(block.text, scope: scope), font: font, color: color, linkColor: linkColor))
            part.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: part.length))
            if let decoration {
                part.addAttribute(.blockDecoration, value: decoration, range: NSRange(location: 0, length: part.length))
            }
            result.append(part)
        }
        return result
    }

    /// 行内的样式：粗体、斜体、行内代码、删除线、链接，和 SwiftUI 的 Text 认的一样。
    private static func inline(_ text: AttributedString, font: UIFont, color: UIColor, linkColor: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var previousLink: URL?
        for run in text.runs {
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
                    attributes[.backgroundColor] = UIColor(Theme.codeBackground)
                }
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if !traits.isEmpty, let descriptor = runFont.fontDescriptor.withSymbolicTraits(runFont.fontDescriptor.symbolicTraits.union(traits)) {
                    runFont = UIFont(descriptor: descriptor, size: 0)
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let url = run.link, url != previousLink {
                let image = url.scheme == "kite"
                    ? ReferenceIcons.file.withTintColor(linkColor, renderingMode: .alwaysOriginal)
                    : ReferenceIcons.shared.image(for: url) ?? ReferenceIcons.webpage
                // 间距在附件内固定留出，不受普通空格、等宽字体和断行排版影响。
                let scaled = ReferenceIcons.scaled(image, to: runFont.pointSize * Metrics.referenceIconScale,
                                                  trailingSpace: Metrics.referenceIconGap)
                let attachment = NSTextAttachment()
                attachment.image = scaled
                attachment.bounds = CGRect(origin: CGPoint(x: 0, y: Metrics.referenceIconBaselineOffset), size: scaled.size)
                let icon = NSMutableAttributedString(attachment: attachment)
                icon.addAttributes([.link: url, .font: runFont], range: NSRange(location: 0, length: icon.length))
                result.append(icon)
            }
            previousLink = run.link
            if let link = run.link { attributes[.link] = link }
            attributes[.font] = runFont
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return result
    }
}

private extension UIFont {
    /// 系统文本样式的半粗体，和 Theme 里标题的写法一样。
    static func semibold(_ style: TextStyle) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        let descriptor = base.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]])
        return UIFont(descriptor: descriptor, size: 0)
    }

    /// 数字等宽，列表的编号对得齐。
    var monospacedDigits: UIFont {
        let descriptor = fontDescriptor.addingAttributes([.featureSettings: [[
            UIFontDescriptor.FeatureKey.type: kNumberSpacingType, UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
        ]]])
        return UIFont(descriptor: descriptor, size: 0)
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
        // 代码块的底色、引用的竖线由自己的排版片段画，要在放字之前接上
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

        // TextKit 的回调不在主线程隔离里，要用的都跟着字放在属性里（BlockDecoration）
        nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                                           in textElement: NSTextElement) -> NSTextLayoutFragment {
            let paragraph = (textElement as? NSTextParagraph)?.attributedString
            if let paragraph, paragraph.length > 0,
               let decoration = paragraph.attribute(.blockDecoration, at: 0, effectiveRange: nil) as? BlockDecoration {
                return DecoratedFragment(textElement: textElement, range: textElement.elementRange, decoration: decoration)
            }
            return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        }
    }
}

extension NSAttributedString.Key {
    /// 这一段落要在字底下画点东西，值是 BlockDecoration。
    fileprivate nonisolated static let blockDecoration = NSAttributedString.Key("kite.blockDecoration")
}

/// 一个段落在字底下画什么：代码块的底色（占满文本区的整宽，块的第一行上面两个角、最后一行下面两个角是圆的），
/// 或者引用左边的竖线。top 是段落的框上面和前一段的间隔，从它下面画起。
private nonisolated final class BlockDecoration: NSObject, Sendable {
    enum Kind {
        case codeBox(first: Bool, last: Bool)
        /// 竖线离文本区左边多远。
        case quoteBar(x: CGFloat)
    }

    let kind: Kind
    let top: CGFloat
    let fill: CGColor

    init(kind: Kind, top: CGFloat, fill: CGColor) {
        self.kind = kind
        self.top = top
        self.fill = fill
    }
}

/// 先画 BlockDecoration 再画字。段落前后的间距算在片段的框里，片段自己只到字的末尾宽（实测）：
/// 所以底色从 top 画到框底、宽度取文本区的整宽；代码块几行的底色上下接在一起，成一个框。
private nonisolated final class DecoratedFragment: NSTextLayoutFragment {
    private let decoration: BlockDecoration

    init(textElement: NSTextElement, range: NSTextRange?, decoration: BlockDecoration) {
        self.decoration = decoration
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) { nil }

    private var box: CGRect {
        let top = decoration.top
        switch decoration.kind {
        case .codeBox:
            let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
            return CGRect(x: 0, y: top, width: width, height: layoutFragmentFrame.height - top)
        case .quoteBar(let x):
            return CGRect(x: x, y: top, width: 3, height: layoutFragmentFrame.height - top)
        }
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(box)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let rect = box.offsetBy(dx: point.x, dy: point.y)
        let path: UIBezierPath
        switch decoration.kind {
        case .codeBox(let first, let last):
            var corners: UIRectCorner = []
            if first { corners.formUnion([.topLeft, .topRight]) }
            if last { corners.formUnion([.bottomLeft, .bottomRight]) }
            path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: 8, height: 8))
        case .quoteBar:
            path = UIBezierPath(roundedRect: rect, cornerRadius: rect.width / 2)
        }
        context.saveGState()
        context.addPath(path.cgPath)
        context.setFillColor(decoration.fill)
        context.fillPath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

private extension Message {
    /// 拼成一段带属性的字：文字用正文字号，代码用等宽的小一号、左右缩进留出框里的边距，斜杠命令的命令名用主题色等宽。
    /// 段和段之间空 messageSegmentGap，代码块的上下留白用段落间距撑出来。
    func attributed(colorScheme: ColorScheme) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let code = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
        let fill = Theme.codeBackground.resolvedCGColor(for: colorScheme)
        let result = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let gap = index > 0 ? Metrics.messageSegmentGap : 0
            switch segment {
            case .text(let text):
                let part = NSMutableAttributedString()
                if index == 0, let command {
                    part.append(NSAttributedString(string: command, attributes: [.font: code, .foregroundColor: UIColor.tintColor]))
                    if !text.isEmpty { part.append(NSAttributedString(string: " ")) }
                }
                part.append(NSAttributedString(string: text, attributes: [.font: body, .foregroundColor: UIColor.label]))
                // 这一段的第一个段落前面空 gap，后面接着的段落不再空
                let first = NSMutableParagraphStyle()
                first.paragraphSpacingBefore = gap
                let firstLength = (part.string as NSString).range(of: "\n").location
                part.addAttribute(.paragraphStyle, value: first,
                                  range: NSRange(location: 0, length: firstLength == NSNotFound ? part.length : firstLength + 1))
                result.append(part)
            case .code(let text):
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                for (number, content) in lines.enumerated() {
                    let first = number == 0
                    let last = number == lines.count - 1
                    let decoration = BlockDecoration(kind: .codeBox(first: first, last: last), top: first ? gap : 0, fill: fill)
                    let style = NSMutableParagraphStyle()
                    style.firstLineHeadIndent = Metrics.codePadding
                    style.headIndent = Metrics.codePadding
                    style.tailIndent = -Metrics.codePadding
                    style.paragraphSpacingBefore = first ? gap + Metrics.codePadding : 0
                    style.paragraphSpacing = last ? Metrics.codePadding : 0
                    result.append(NSAttributedString(string: String(content) + (last ? "" : "\n"), attributes: [
                        .font: code, .foregroundColor: UIColor.label, .paragraphStyle: style, .blockDecoration: decoration,
                    ]))
                }
            }
        }
        return result
    }
}

private extension Color {
    /// TextKit 的绘制片段只保存 CGColor，要在主线程按所在窗口的外观解析。
    func resolvedCGColor(for colorScheme: ColorScheme) -> CGColor {
        UIColor(self).resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)).cgColor
    }
}
#endif
