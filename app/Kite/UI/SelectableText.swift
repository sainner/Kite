import SwiftUI

/// 用户消息的正文，整条排进一个文本视图，选字能从头拖到尾：iPhone 上长按再拖，Mac 上左键拖。
/// 不解析 Markdown，只把 ``` 围起来的一段排成代码块卡片（附件，见 BlockAttachment），选区拖过就是整块；
/// 斜杠命令的命令名用等宽字排在最前面。字色由气泡状态决定（收到了是白字，排队中跟系统文字色）。复制给打的原文（Message.typed）。
struct SelectableText: View {
    @Environment(\.fontResolutionContext) private var fontContext
    let message: Message
    let color: PlatformColor
    @State private var attachments = BlockAttachments()
    #if os(iOS)
    let showActions: () -> Void
    let dismissActions: () -> Void
    #endif

    var body: some View {
        let content = content
        // 有代码块时占满气泡能给的宽度，和原来代码块卡片把气泡撑满一样；只有字时贴着字
        #if os(iOS)
        SelectableTextView(content: content, inset: .zero, fillsWidth: !content.blocks.isEmpty, showActions: showActions,
                           dismissActions: dismissActions)
        #else
        SelectableTextView(content: content, inset: .zero, fillsWidth: !content.blocks.isEmpty)
        #endif
    }

    /// 文字和代码块之间空 messageSegmentGap，和原来一段一个视图竖着排的间距一样。
    private var content: TextViewContent {
        #if canImport(UIKit)
        let body = UIFont.preferredFont(forTextStyle: .body)
        // Theme.code：等宽的 subheadline
        let code = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
        #else
        // 直接取 SwiftUI 解析出的字体，和原来 Text 用的是同一个：Theme.code 解析出的 SF Mono 带 leading，
        // monospacedSystemFont 不带，只有命令名的一行会差 1 pt 行高
        let body = Theme.body.resolve(in: fontContext).ctFont as NSFont
        let code = Theme.code.resolve(in: fontContext).ctFont as NSFont
        #endif
        let typed = message.typed as NSString
        // 正文在 typed 里从哪起：斜杠命令时前面是命令名和一个空格
        let offset = message.command.map { $0.utf16.count + (message.text.isEmpty ? 0 : 1) } ?? 0
        let textAttributes: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: color]
        let result = NSMutableAttributedString()
        var embedded: [(attachment: BlockAttachment, content: EmbeddedBlock)] = []
        var map = TextSourceMap()
        var separator = textAttributes
        for (index, segment) in message.segments.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: separator)) }
            let start = result.length
            let gap = NSMutableParagraphStyle()
            gap.paragraphSpacingBefore = index > 0 ? Metrics.messageSegmentGap : 0
            switch segment {
            case .text(let text, let source):
                var lines = NSRange(source, in: message.text)
                lines.location += offset
                if index == 0, let command = message.command {
                    result.append(NSAttributedString(string: command, attributes: [.font: code, .foregroundColor: color]))
                    // 命令名和正文之间的空格按正文排，没有字体属性的字会落到文本视图的默认字体上
                    if !text.isEmpty { result.append(NSAttributedString(string: " ", attributes: textAttributes)) }
                    lines = NSRange(location: 0, length: NSMaxRange(lines))
                }
                result.append(NSAttributedString(string: text, attributes: textAttributes))
                // 段前距只给这段的第一行，段里的换行照常
                let first = (result.string as NSString).paragraphRange(for: NSRange(location: start, length: 0))
                result.addAttribute(.paragraphStyle, value: gap, range: first)
                let display = NSRange(location: start, length: result.length - start)
                let exact = NSMaxRange(lines) <= typed.length && typed.substring(with: lines) == (result.string as NSString).substring(with: display)
                map.blocks.append(.init(display: display, content: start, lines: lines,
                                        pieces: [.init(display: display, source: lines, outer: lines, exact: exact)]))
                separator = textAttributes
            case .code(let text, let language, let source):
                let content = EmbeddedBlock.userCode(text, language: language)
                let attachment = attachments.attachment(embedded.count, for: content)
                embedded.append((attachment, content))
                let attributes: [NSAttributedString.Key: Any] = [.font: BlockAttachment.lineFont, .paragraphStyle: gap]
                let part = NSMutableAttributedString(attachment: attachment)
                part.addAttributes(attributes, range: NSRange(location: 0, length: part.length))
                result.append(part)
                var lines = NSRange(source, in: message.text)
                lines.location += offset
                map.blocks.append(.init(display: NSRange(location: start, length: part.length), content: start, lines: lines))
                separator = attributes
            }
        }
        return TextViewContent(text: result, blocks: embedded, source: (message.typed, map))
    }
}
