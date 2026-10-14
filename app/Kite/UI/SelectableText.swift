import SwiftUI

/// 用户消息的正文，整条排进一个文本视图（两端原生气泡里的 ProseTextView、PhoneProseTextView），选字能从头拖到尾。
/// 不解析 Markdown，只把 ``` 围起来的一段排成代码块卡片（附件，见 BlockAttachment），选区拖过就是整块；
/// 斜杠命令的命令名用等宽字排在最前面。字色由气泡状态决定（收到了是白字，排队中跟系统文字色）。复制给打的原文（Message.typed）。
enum SelectableText {
    #if canImport(UIKit)
    /// iPhone、iPad 上正文和代码段的字体（PhoneBubbleRowSlot）。代码是 Theme.code：等宽的 subheadline。
    static var phoneFonts: (body: UIFont, code: UIFont) {
        (UIFont.preferredFont(forTextStyle: .body),
         UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular)))
    }
    #endif

    /// 拼成气泡里的属性串，文字和代码块之间空 messageSegmentGap。两端的原生气泡（BubbleRowSlot、PhoneBubbleRowSlot）用。
    static func content(_ message: Message, color: PlatformColor, body: PlatformFont, code: PlatformFont,
                        attachments: BlockAttachments) -> TextViewContent {
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
                                        pieces: [.init(display: display, source: lines, exact: exact)]))
                separator = textAttributes
            case .code(let text, let language, let source):
                separator = attachments.embed(.userCode(text, language: language), paragraph: gap, into: result, embedded: &embedded)
                var lines = NSRange(source, in: message.text)
                lines.location += offset
                map.blocks.append(.init(display: NSRange(location: start, length: result.length - start), content: start, lines: lines))
            }
        }
        return TextViewContent(text: result, blocks: embedded, source: (message.typed, map))
    }
}
