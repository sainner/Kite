import CoreText
import SwiftUI

/// agent 说的一段话，整段排进一个文本视图（Mac 的 ProseTextView、iOS 的 PhoneProseTextView，都是 TextKit 2），选字能从头拖到尾。
/// 代码块、表格、分隔线各是文本里的一个附件字符，显示成卡片（BlockAttachment：iOS 托管 SwiftUI 视图，Mac 是原生卡片）：
/// 卡片要横着滚、太长折起来，表格排不进文本视图；选区拖过它们就是整块选上。复制给 Markdown 原文（TextSourceMap）。
/// 样子照 MarkdownView：正文字号跟着调用方给的字体（对话里是正文，压缩摘要和子 agent 做的事里小一号），标题字号固定。
/// 两端原生对话的行（ProseRowSlot、PhoneProseRowSlot 和压缩摘要）按这里拼属性串。
enum SelectableMarkdown {
    /// 开头是标题时，标题上方的半个块距由行视图放在文本视图外面：TextKit 不认文档第一段的 paragraphSpacingBefore，
    /// 而 MarkdownBlockView 给标题的 padding(.top) 对第一块也生效（Mac 量到开头的标题少 6 pt 上留白）。
    static func startsWithHeading(_ blocks: [MarkdownBlock]) -> Bool {
        if case .heading = blocks.first?.kind { return true }
        return false
    }

    /// 原生对话行（正文、压缩摘要）的一段：属性串和开头是标题时要让出的上边距（见 startsWithHeading）。
    /// 要看的引用图标和上次（loaded）不一样就交给 ReferenceIcons 去载；在 ModelTracking 的登记里调，图标载完由登记通知重排。
    static func prose(_ blocks: [MarkdownBlock], source: String, body: PlatformFont, color: PlatformColor, environment: EnvironmentValues,
                      attachments: BlockAttachments, loaded: inout [URL]) -> (content: TextViewContent, topInset: CGFloat) {
        let urls = blocks.flatMap { ReferenceText.decorate($0.text, scope: environment.referenceScope).runs.compactMap(\.link) }
        if urls != loaded {
            loaded = urls
            Task { await ReferenceIcons.shared.load(urls) }
        }
        var topInset = startsWithHeading(blocks) ? Metrics.markdownBlockGap(body.pointSize) / 2 : 0
        #if os(iOS)
        topInset = PhonePixel.round(topInset)
        #endif
        return (content(blocks, source: source, body: body, color: color, colorScheme: environment.colorScheme,
                        scope: environment.referenceScope, attachments: attachments), topInset)
    }

    /// 几块拼成一段带属性的字，块和块之间空 markdownBlockGap，标题上面再多空一点，和 MarkdownBlockView 排的一样。
    /// 块距、引用竖线顶边、行内代码背景高按 Mac 上与 MarkdownView 并排逐行量过的差异补偿，两端共用这一套
    /// （用户 2026-10-12 决定；量到的数值见 spikes/mac-textkit-prose/README.md「外观对照」）。
    /// 代码块、表格、分隔线各占一个附件字符、自成一段，段前空一个块距；附件按第几个复用（attachments）。
    /// body 是环境里解析出的正文字体，行距、块距、列表编号和行内代码的字号都从它推。
    static func content(_ blocks: [MarkdownBlock], source: String, body: PlatformFont, color: PlatformColor, colorScheme: ColorScheme,
                        scope: ReferenceScope, attachments: BlockAttachments) -> TextViewContent {
        let blockGap = Metrics.markdownBlockGap(body.pointSize)
        let lineSpacing = Metrics.markdownLineSpacing(body.pointSize)
        // 文件图标的颜色：Mac 用主题色，iPhone、iPad 用链接色。
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
        /// 附件那一段的属性，见 BlockAttachments.embed。
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
                attachmentAttributes = attachments.embed(.markdown(flat), paragraph: style, into: result, embedded: &embedded)
                #if os(macOS)
                // Mac 的表格卡片能选字，复制时按原文取回
                embedded.last?.attachment.markdown = source
                #endif
                if let lines = block.source?.lines {
                    map.blocks.append(.init(display: NSRange(location: start, length: result.length - start), content: start, lines: lines))
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
                // 标题上方再多半个块距；开头的标题 TextKit 不认段前距，这半个块距由行视图补，见 startsWithHeading
                if index > 0 { style.paragraphSpacingBefore += blockGap / 2 }
            case .quote:
                color = .secondaryLabel
                style.firstLineHeadIndent = indent + Metrics.quoteIndent
                style.headIndent = indent + Metrics.quoteIndent
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
    /// 只有缩短成文件名的引用要按 ReferenceOriginal 记的原长对回去，引用前插的图标算进它后面那段。Mac 的表格卡片排格子也用它。
    static func inline(_ text: AttributedString, source: MarkdownSource?, offset: Int, font: PlatformFont, color: PlatformColor,
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

private extension PlatformImage {
    /// 模板图标按给定颜色着色：附件里的图不会像 SwiftUI 的 .template 那样跟着 foregroundStyle。
    func tinted(_ color: PlatformColor) -> PlatformImage {
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
