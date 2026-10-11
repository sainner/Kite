import SwiftUI

/// 用户消息的一段普通文字，斜杠命令的命令名用等宽字排在最前面；颜色由气泡状态决定（收到了是白字，排队中跟系统文字色）。
/// 排进文本视图是为了选字：iPhone 上长按再拖，Mac 上左键拖。独立代码块由 MessageText 使用共用 CodeBlock 排版。
struct SelectableText: View {
    @Environment(\.fontResolutionContext) private var fontContext
    let text: String
    let command: String?
    let color: PlatformColor
    #if os(iOS)
    let showActions: () -> Void
    let dismissActions: () -> Void
    #endif

    var body: some View {
        #if os(iOS)
        SelectableTextView(text: attributed, inset: .zero, fillsWidth: false, showActions: showActions, dismissActions: dismissActions)
        #else
        SelectableTextView(text: attributed, inset: .zero, fillsWidth: false)
        #endif
    }

    private var attributed: NSAttributedString {
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
        let result = NSMutableAttributedString()
        if let command {
            result.append(NSAttributedString(string: command, attributes: [.font: code, .foregroundColor: color]))
            // 命令名和正文之间的空格按正文排，没有字体属性的字会落到文本视图的默认字体上
            if !text.isEmpty { result.append(NSAttributedString(string: " ", attributes: [.font: body, .foregroundColor: color])) }
        }
        result.append(NSAttributedString(string: text, attributes: [.font: body, .foregroundColor: color]))
        return result
    }
}
