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

private extension Color {
    /// TextKit 的绘制片段只保存 CGColor，要在主线程按所在窗口的外观解析。
    func resolvedCGColor(for colorScheme: ColorScheme) -> CGColor {
        UIColor(self).resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)).cgColor
    }
}
#endif
