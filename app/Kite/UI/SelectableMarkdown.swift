import CoreText
import SwiftUI

/// agent 说的一段话，整段排进一个文本视图（iPhone 是 UITextView，Mac 是 NSTextView，都是 TextKit 2），选字能从头拖到尾。
/// 代码块、表格、分隔线各是文本里的一个附件字符，显示成原来的 SwiftUI 视图（BlockAttachment）：卡片要横着滚、太长折起来，
/// 表格排不进文本视图；选区拖过它们就是整块选上，卡片上盖一层选区色。复制给 Markdown 原文（TextSourceMap）。
/// 样子照 MarkdownView：正文字号跟着环境里的字体（对话里是正文，压缩摘要和子 agent 做的事里小一号），标题字号固定。
/// iPhone 上长按文本视图和卡片都显示操作栏；Mac 上右键由外层 opensActionBar 的盖层接，这里不管。
struct SelectableMarkdown: View {
    @Environment(\.referenceScope) private var referenceScope
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.font) private var font
    @Environment(\.fontResolutionContext) private var fontContext
    let source: String
    /// 正文的字色；引用一律用次要色。
    var color: PlatformColor = .label
    @State private var document = MarkdownDocument()
    @State private var attachments = BlockAttachments()
    #if os(iOS)
    var showActions: @MainActor () -> Void = {}
    var dismissActions: () -> Void = {}
    #endif

    var body: some View {
        let blocks = document.blocks(for: source)
        let urls = blocks.flatMap { ReferenceText.decorate($0.text, scope: referenceScope).runs.compactMap(\.link) }
        // SwiftUI 解析出的字体就是 Text 实际用的那一个（Mac 上八种用途与 preferredFont(forTextStyle:) 逐一核对过，见 spikes/mac-textkit-prose）
        let body = (font ?? .body).resolve(in: fontContext).ctFont as PlatformFont
        let content = Self.content(blocks, source: source, body: body, color: color, colorScheme: colorScheme, scope: referenceScope,
                                   attachments: attachments)
        // 文本视图为背景留出绘制余量，外层抵消这段边距，正文宽度与起点不变。
        // 开头是标题时，标题上方的半个块距放在视图外面：TextKit 不认文档第一段的 paragraphSpacingBefore，
        // 而 MarkdownBlockView 给标题的 padding(.top) 对第一块也生效（Mac 量到开头的标题少 6 pt 上留白）。
        textView(content)
            .padding(.horizontal, -Metrics.inlineCodePadding)
            .padding(.top, Self.startsWithHeading(blocks) ? Metrics.markdownBlockGap(body.pointSize) / 2 : 0)
            .task(id: urls) { await ReferenceIcons.shared.load(urls) }
    }

    private func textView(_ content: TextViewContent) -> some View {
        #if os(iOS)
        SelectableTextView(content: content, inset: CGSize(width: Metrics.inlineCodePadding, height: 0), fillsWidth: true,
                           showActions: showActions, dismissActions: dismissActions)
            // 卡片只在内容区接长按，标题栏按钮保留按下状态
            .environment(\.blockCardLongPress, showActions)
        #else
        SelectableTextView(content: content, inset: CGSize(width: Metrics.inlineCodePadding, height: 0), fillsWidth: true)
        #endif
    }

    private static func startsWithHeading(_ blocks: [MarkdownBlock]) -> Bool {
        if case .heading = blocks.first?.kind { return true }
        return false
    }

    /// 几块拼成一段带属性的字，块和块之间空 markdownBlockGap，标题上面再多空一点，和 MarkdownBlockView 排的一样。
    /// 块距、引用竖线顶边、行内代码背景高按 Mac 上与 SwiftUI 版并排逐行量过的差异补偿，两端共用这一套
    /// （用户 2026-10-12 决定；量到的数值见 spikes/mac-textkit-prose/README.md「外观对照」）。
    /// 代码块、表格、分隔线各占一个附件字符、自成一段，段前空一个块距；附件按第几个复用（attachments）。
    /// body 是环境里解析出的正文字体，行距、块距、列表编号和行内代码的字号都从它推。
    static func content(_ blocks: [MarkdownBlock], source: String, body: PlatformFont, color: PlatformColor, colorScheme: ColorScheme,
                        scope: ReferenceScope, attachments: BlockAttachments) -> TextViewContent {
        let blockGap = Metrics.markdownBlockGap(body.pointSize)
        let lineSpacing = Metrics.markdownLineSpacing(body.pointSize)
        // 文件图标的颜色：SwiftUI 版在 Mac 上用 .tint（主题色），iPhone 版一直用链接色，各自保持现状。
        // 链接文字的颜色不在这里定，由文本视图的 linkTextAttributes 给系统 link 色，和 SwiftUI 的 Text 一样。
        #if canImport(UIKit)
        let iconTint = PlatformColor.link.resolved(for: colorScheme)
        #else
        let iconTint = PlatformColor.controlAccentColor.resolved(for: colorScheme)
        #endif
        let codeFill = Theme.codeBackground.resolvedCGColor(for: colorScheme)
        let ruleFill = Theme.rule.resolvedCGColor(for: colorScheme)
        let result = NSMutableAttributedString()
        var embedded: [(attachment: BlockAttachment, content: EmbeddedBlock)] = []
        var map = TextSourceMap()
        var mapped = true
        /// 附件那一段的字体和段落样式，段尾的换行也用它，换行的字体不把这一行撑高。
        var attachmentAttributes: [NSAttributedString.Key: Any]?
        for (index, block) in blocks.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: attachmentAttributes)) }
            attachmentAttributes = nil
            let start = result.length
            let indent = CGFloat(max(block.depth - 1, 0)) * Metrics.listIndent
            switch block.kind {
            case .code, .table, .rule:
                // 附件一段不加行距：TextKit 把行距放在每行上方，块上面只留块距；块自己的列表缩进由段落缩进给
                let style = NSMutableParagraphStyle()
                style.paragraphSpacingBefore = index > 0 ? blockGap : 0
                style.firstLineHeadIndent = indent
                style.headIndent = indent
                var flat = block
                flat.depth = 0
                let content = EmbeddedBlock.markdown(flat)
                let attachment = attachments.attachment(embedded.count, for: content)
                embedded.append((attachment, content))
                let attributes: [NSAttributedString.Key: Any] = [.font: BlockAttachment.lineFont, .paragraphStyle: style]
                let part = NSMutableAttributedString(attachment: attachment)
                part.addAttributes(attributes, range: NSRange(location: 0, length: part.length))
                result.append(part)
                attachmentAttributes = attributes
                if let lines = block.source?.lines {
                    map.blocks.append(.init(display: NSRange(location: start, length: part.length), content: start, lines: lines))
                } else {
                    mapped = false
                }
                continue
            default:
                break
            }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            // TextKit 2 把 lineSpacing 放在每一行上方，段落第一行也有（只有文档第一行没有）；SwiftUI 的 VStack 块与块之间只有块距。
            // 段前距照搬块距时每个块边界会多出一个行距（Mac 13 pt 正文下每处 +6），所以先把它减掉。
            style.paragraphSpacingBefore = index > 0 ? blockGap - lineSpacing : 0
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            var font = body
            var color = color
            var prefix = ""
            var decoration: QuoteDecoration?
            switch block.kind {
            case .heading(let level):
                font = level <= 1 ? .semibold(.title2) : level == 2 ? .semibold(.title3) : .preferredFont(forTextStyle: .headline)
                // 标题上方再多半个块距；开头的标题 TextKit 不认段前距，这半个块距由 body 里的 padding(.top) 补
                if index > 0 { style.paragraphSpacingBefore += blockGap / 2 }
            case .quote:
                color = .secondaryLabel
                style.firstLineHeadIndent = indent + 12
                style.headIndent = indent + 12
                // 竖线从第一行字的顶边起：片段顶边在段前距之上还高出一个行距（Mac 量到竖线 −6.03…37.97 对 SwiftUI 的 0…37.5，
                // 加上行距后 −0.03…37.97）；文档第一段既没有段前距也没有这个行距。
                let top = index > 0 ? style.paragraphSpacingBefore + lineSpacing : 0
                decoration = QuoteDecoration(x: indent, top: top, fill: ruleFill)
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
            let (text, pieces) = inline(ReferenceText.decorate(block.text, scope: scope), source: block.source, offset: start + part.length,
                                        font: font, color: color, iconTint: iconTint, codeFill: codeFill)
            part.append(text)
            part.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: part.length))
            if let decoration {
                part.addAttribute(.quoteDecoration, value: decoration, range: NSRange(location: 0, length: part.length))
            }
            result.append(part)
            if let lines = block.source?.lines {
                map.blocks.append(.init(display: NSRange(location: start, length: part.length), content: start + prefix.utf16.count,
                                        lines: lines, pieces: pieces))
            } else {
                mapped = false
            }
        }
        return TextViewContent(text: result, blocks: embedded, source: mapped ? (source, map) : nil)
    }

    /// 行内的样式：粗体、斜体、行内代码、删除线、链接，和 SwiftUI 的 Text 认的一样。
    /// 同时记下每段显示的字对应原文的哪里（offset 是这段字在整个属性串里的起点）：显示的字是 block.text 依次往下，
    /// 只有缩短成文件名的引用要按 ReferenceOriginal 记的原长对回去，引用前插的图标算进它后面那段。
    private static func inline(_ text: AttributedString, source: MarkdownSource?, offset: Int, font: PlatformFont, color: PlatformColor,
                               iconTint: PlatformColor, codeFill: CGColor) -> (NSAttributedString, [TextSourceMap.Piece]) {
        let text = InlineCodeSpacing.apply(to: text)
        let result = NSMutableAttributedString()
        let codeDecoration = InlineCodeDecoration(fill: codeFill)
        var previousLink: URL?
        var pieces: [TextSourceMap.Piece] = []
        /// 显示到 block.text 的第几个字（UTF-16）了，和正在走的缩短引用。
        var original = 0
        var label: ReferenceOriginal?
        for run in text.runs {
            let displayStart = result.length
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let kern = run.swiftUI.kern { attributes[.kern] = kern }
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = InlineCodeStyle.font(relativeTo: font)
                    attributes[.inlineCodeDecoration] = codeDecoration
                }
                var traits: PlatformFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty, let styled = runFont.addingTraits(traits) {
                    runFont = styled
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let url = run.link, url != previousLink {
                let image = url.scheme == "kite"
                    ? ReferenceIcons.file.tinted(iconTint)
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
            let characters = String(text[run.range].characters)
            result.append(NSAttributedString(string: characters, attributes: attributes))
            guard let source else { continue }
            let display = NSRange(location: offset + displayStart, length: result.length - displayStart)
            if let current = run[ReferenceOriginalAttribute.self] {
                // 同一个引用被字距拆成几段时并成一段，原长只算一次
                if current == label, var last = pieces.popLast() {
                    last.display.length = NSMaxRange(display) - last.display.location
                    pieces.append(last)
                    continue
                }
                label = current
                pieces.append(source.piece(display: display, original: NSRange(location: original, length: current.length), atomic: true))
                original += current.length
            } else {
                label = nil
                pieces.append(source.piece(display: display, original: NSRange(location: original, length: characters.utf16.count),
                                           atomic: run.link != nil))
                original += characters.utf16.count
            }
        }
        return (result, pieces)
    }
}

private extension PlatformFont {
    /// 系统文本样式的半粗体，和 Theme 里标题的写法一样。
    static func semibold(_ style: TextStyle) -> PlatformFont {
        let base = PlatformFont.preferredFont(forTextStyle: style)
        let descriptor = base.fontDescriptor.addingAttributes([.traits: [PlatformFontDescriptor.TraitKey.weight: PlatformFont.Weight.semibold]])
        return PlatformFont.font(descriptor: descriptor) ?? base
    }
}

private extension ReferenceImage {
    /// 模板图标按给定颜色着色：附件里的图不会像 SwiftUI 的 .template 那样跟着 foregroundStyle。
    func tinted(_ color: PlatformColor) -> ReferenceImage {
        #if canImport(UIKit)
        withTintColor(color, renderingMode: .alwaysOriginal)
        #else
        let result = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        result.alignmentRect = alignmentRect
        return result
        #endif
    }
}
