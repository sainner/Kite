#if os(iOS)
import CoreText
import SwiftUI
import UIKit

/// iPhone 上 agent 说的一段话。连续的段落、标题、引用、列表项排进同一个文本视图，选字能跨着拖；
/// 代码块、表格、分隔线照旧用 SwiftUI 排（代码块要横着滚、太长折起来，表格排不进文本视图），选字跨不过它们，
/// 长按这些块也显示操作栏。样子照 MarkdownView。
struct SelectableMarkdown: View {
    @Environment(\.referenceScope) private var referenceScope
    @Environment(\.colorScheme) private var colorScheme
    let source: String
    @State private var document = MarkdownDocument()
    let showActions: @MainActor () -> Void
    let dismissActions: () -> Void

    var body: some View {
        let urls = document.blocks(for: source).flatMap { ReferenceText.decorate($0.text, scope: referenceScope).runs.compactMap(\.link) }
        let blockGap = Metrics.markdownBlockGap(UIFont.preferredFont(forTextStyle: .body).pointSize)
        VStack(alignment: .leading, spacing: blockGap) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                switch chunk {
                case .prose(let blocks):
                    // 文本视图为背景留出绘制余量，外层抵消这段边距，正文宽度与起点不变。
                    // 开头是标题时，标题上方的半个块距放在视图外面：TextKit 不认文档第一段的 paragraphSpacingBefore，
                    // 而 MarkdownBlockView 给标题的 padding(.top) 对第一块也生效（Mac 量到开头的标题少 6 pt 上留白）。
                    SelectableTextView(text: Self.attributed(blocks, colorScheme: colorScheme, scope: referenceScope),
                                       inset: CGSize(width: Metrics.inlineCodePadding, height: 0), fillsWidth: true,
                                       showActions: showActions, dismissActions: dismissActions)
                        .padding(.horizontal, -Metrics.inlineCodePadding)
                        .padding(.top, Self.startsWithHeading(blocks) ? blockGap / 2 : 0)
                case .block(let block):
                    switch block.kind {
                    case .code, .table:
                        // 卡片只在内容区接长按，标题栏按钮保留按下状态
                        MarkdownBlockView(block: block)
                            .environment(\.blockCardLongPress, showActions)
                    default:
                        MarkdownBlockView(block: block)
                            .contentShape(Rectangle())
                            .highPriorityGesture(LongPressGesture(minimumDuration: 0.4, maximumDistance: 8)
                                .onEnded { _ in showActions() })
                    }
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

    private static func startsWithHeading(_ blocks: [MarkdownBlock]) -> Bool {
        if case .heading = blocks.first?.kind { return true }
        return false
    }

    /// 几块拼成一段带属性的字，块和块之间空 markdownBlockGap，标题上面再多空一点，和 MarkdownBlockView 排的一样。
    /// 块距、引用竖线顶边、行内代码背景高按 Mac 上与 SwiftUI 版并排逐行量过的差异补偿，两端共用这一套
    /// （用户 2026-10-12 决定；量到的数值见 spikes/mac-textkit-prose/README.md「外观对照」）。
    private static func attributed(_ blocks: [MarkdownBlock], colorScheme: ColorScheme, scope: ReferenceScope) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let blockGap = Metrics.markdownBlockGap(body.pointSize)
        let lineSpacing = Metrics.markdownLineSpacing(body.pointSize)
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            // TextKit 2 把 lineSpacing 放在每一行上方，段落第一行也有（只有文档第一行没有）；SwiftUI 的 VStack 块与块之间只有块距。
            // 段前距照搬块距时每个块边界会多出一个行距（Mac 13 pt 正文下每处 +6），所以先把它减掉。
            style.paragraphSpacingBefore = index > 0 ? blockGap - lineSpacing : 0
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
                // 标题上方再多半个块距；开头的标题 TextKit 不认段前距，这半个块距由 body 里的 padding(.top) 补
                if index > 0 { style.paragraphSpacingBefore += blockGap / 2 }
            case .quote:
                color = .secondaryLabel
                style.firstLineHeadIndent = indent + 12
                style.headIndent = indent + 12
                // 竖线从第一行字的顶边起：片段顶边在段前距之上还高出一个行距（Mac 量到竖线 −6.03…37.97 对 SwiftUI 的 0…37.5，
                // 加上行距后 −0.03…37.97）；文档第一段既没有段前距也没有这个行距。
                let top = index > 0 ? style.paragraphSpacingBefore + lineSpacing : 0
                decoration = QuoteDecoration(x: indent, top: top, fill: Theme.rule.resolvedCGColor(for: colorScheme))
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

private extension Color {
    /// TextKit 的绘制片段只保存 CGColor，要在主线程按所在窗口的外观解析。
    func resolvedCGColor(for colorScheme: ColorScheme) -> CGColor {
        UIColor(self).resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)).cgColor
    }
}
#endif
