#if os(iOS)
import CoreText
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
                    // 文本视图为背景留出绘制余量，外层抵消这段边距，正文宽度与起点不变。
                    SelectableTextView(text: Self.attributed(blocks, colorScheme: colorScheme, scope: referenceScope),
                                       inset: CGSize(width: Metrics.inlineCodePadding, height: 0), fillsWidth: true,
                                       showActions: showActions, dismissActions: dismissActions)
                        .padding(.horizontal, -Metrics.inlineCodePadding)
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
            style.lineSpacing = Metrics.markdownLineSpacing
            style.paragraphSpacingBefore = index > 0 ? Metrics.markdownBlockGap : 0
            let indent = CGFloat(max(block.depth - 1, 0)) * Metrics.listIndent
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            var font = body
            var color = UIColor.label
            var prefix = ""
            var decoration: QuoteDecoration?
            switch block.kind {
            case .heading(let level):
                font = level <= 1 ? .semibold(.title2) : level == 2 ? .semibold(.title3) : .preferredFont(forTextStyle: .headline)
                style.paragraphSpacingBefore += 4
            case .quote:
                color = .secondaryLabel
                style.firstLineHeadIndent = indent + 12
                style.headIndent = indent + 12
                decoration = QuoteDecoration(x: indent, top: style.paragraphSpacingBefore, fill: Theme.rule.resolvedCGColor(for: colorScheme))
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
            part.append(inline(ReferenceText.decorate(block.text, scope: scope), font: font, color: color, linkColor: linkColor,
                               codeFill: Theme.codeBackground.resolvedCGColor(for: colorScheme)))
            part.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: part.length))
            if let decoration {
                part.addAttribute(.quoteDecoration, value: decoration, range: NSRange(location: 0, length: part.length))
            }
            result.append(part)
        }
        return result
    }

    /// 行内的样式：粗体、斜体、行内代码、删除线、链接，和 SwiftUI 的 Text 认的一样。
    private static func inline(_ text: AttributedString, font: UIFont, color: UIColor, linkColor: UIColor, codeFill: CGColor) -> NSAttributedString {
        let text = InlineCodeSpacing.apply(to: text)
        let result = NSMutableAttributedString()
        let codeDecoration = InlineCodeDecoration(fill: codeFill)
        var previousLink: URL?
        for run in text.runs {
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let kern = run.swiftUI.kern { attributes[.kern] = kern }
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = InlineCodeStyle.font(relativeTo: font)
                    attributes[.inlineCodeDecoration] = codeDecoration
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
                icon.append(NSAttributedString(string: ReferenceIcons.nameJoiner))
                icon.addAttributes([.link: url, .font: runFont], range: NSRange(location: 0, length: icon.length))
                if run.inlinePresentationIntent?.contains(.code) == true {
                    icon.addAttribute(.inlineCodeDecoration, value: codeDecoration, range: NSRange(location: 0, length: icon.length))
                }
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

extension NSAttributedString.Key {
    fileprivate nonisolated static let quoteDecoration = NSAttributedString.Key("kite.quoteDecoration")
    fileprivate nonisolated static let inlineCodeDecoration = NSAttributedString.Key("kite.inlineCodeDecoration")
}

private nonisolated final class InlineCodeDecoration: NSObject, Sendable {
    let fill: CGColor
    init(fill: CGColor) { self.fill = fill }
}

/// 引用竖线：x 是文本容器坐标，top 是段落上方的间隔。
private nonisolated final class QuoteDecoration: NSObject, Sendable {
    let x: CGFloat
    let top: CGFloat
    let fill: CGColor

    init(x: CGFloat, top: CGFloat, fill: CGColor) {
        self.x = x
        self.top = top
        self.fill = fill
    }
}

/// 先画引用竖线和行内代码背景，再画原生文字。
/// 行内代码只覆盖系统排版返回的文字范围，每次折行分别绘制圆角。
private nonisolated final class DecoratedFragment: NSTextLayoutFragment {
    private let decoration: QuoteDecoration?
    private let hasInlineCode: Bool

    init(textElement: NSTextElement, range: NSTextRange?, decoration: QuoteDecoration?, hasInlineCode: Bool) {
        self.decoration = decoration
        self.hasInlineCode = hasInlineCode
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) { nil }

    private var box: CGRect {
        guard let decoration else { return .null }
        // 绘制原点已包含段落缩进，将容器坐标换成片段局部坐标。
        return CGRect(x: decoration.x - layoutFragmentFrame.minX, y: decoration.top,
                      width: 3, height: layoutFragmentFrame.height - decoration.top)
    }

    override var renderingSurfaceBounds: CGRect {
        let bounds = super.renderingSurfaceBounds.union(box)
        return hasInlineCode ? bounds.insetBy(dx: -Metrics.inlineCodePadding, dy: 0) : bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let decoration { drawBlock(decoration, at: point, in: context) }
        drawInlineCode(at: point, in: context)
        super.draw(at: point, in: context)
    }

    private func drawBlock(_ decoration: QuoteDecoration, at point: CGPoint, in context: CGContext) {
        let rect = box.offsetBy(dx: point.x, dy: point.y)
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.width / 2, cornerHeight: rect.width / 2, transform: nil))
        context.setFillColor(decoration.fill)
        context.fillPath()
        context.restoreGState()
    }

    private func drawInlineCode(at point: CGPoint, in context: CGContext) {
        guard hasInlineCode else { return }
        context.saveGState()
        defer { context.restoreGState() }
        for line in textLineFragments {
            // segment 是选区边界，会吸收部分 kern 和中英文间距，不能当作字形边界。
            // 沿用 TextKit 的断行，只向 CoreText 取得这一行的字形位置。
            let typesetter = CTTypesetterCreateWithAttributedString(line.attributedString)
            let range = line.characterRange
            let shaped = CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: range.length))
            var box = CGRect.null
            var fill: CGColor?
            func drawBox() {
                guard !box.isNull, let fill else { return }
                let rect = box.offsetBy(dx: point.x + line.typographicBounds.minX,
                                        dy: point.y + line.typographicBounds.minY)
                    .insetBy(dx: -Metrics.inlineCodePadding, dy: 0)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: Metrics.inlineCodeRadius,
                                       cornerHeight: Metrics.inlineCodeRadius, transform: nil))
                context.setFillColor(fill)
                context.fillPath()
            }
            for run in CTLineGetGlyphRuns(shaped) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let decoration = attributes[NSAttributedString.Key.inlineCodeDecoration.rawValue] as? InlineCodeDecoration else {
                    drawBox()
                    box = .null
                    fill = nil
                    continue
                }
                fill = decoration.fill
                let count = CTRunGetGlyphCount(run)
                var positions = [CGPoint](repeating: .zero, count: count)
                var advances = [CGSize](repeating: .zero, count: count)
                CTRunGetPositions(run, CFRange(), &positions)
                CTRunGetAdvances(run, CFRange(), &advances)
                var widths = advances
                if attributes[NSAttributedString.Key.attachment.rawValue] == nil {
                    let font = attributes[kCTFontAttributeName] as! CTFont
                    var glyphs = [CGGlyph](repeating: 0, count: count)
                    CTRunGetGlyphs(run, CFRange(), &glyphs)
                    // 字体原始宽度不含外侧 kern；附件则保留图标本身的排版宽度。
                    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &widths, count)
                }
                // 跳过 WORD JOINER 等零宽字形，不让它们撑大背景。
                for index in 0..<count where advances[index].width > 0 && widths[index].width > 0 {
                    box = box.union(CGRect(x: positions[index].x, y: 0, width: widths[index].width,
                                           height: line.typographicBounds.height))
                }
            }
            drawBox()
        }
    }
}

private extension Color {
    /// TextKit 的绘制片段只保存 CGColor，要在主线程按所在窗口的外观解析。
    func resolvedCGColor(for colorScheme: ColorScheme) -> CGColor {
        UIColor(self).resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)).cgColor
    }
}
#endif
