import SwiftUI
import Highlighter
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 每个代码块保存当前着色结果；流式文本或外观改变时才重新请求。
struct HighlightedCode: View {
    let text: String
    let language: String?
    @Environment(\.colorScheme) private var colorScheme
    @State private var result: (request: Request, text: AttributedString)?

    private struct Request: Equatable {
        let text: String
        let language: String?
        let dark: Bool
    }

    var body: some View {
        let request = Request(text: text, language: language, dark: colorScheme == .dark)
        Text(result?.request == request ? result!.text : AttributedString(text))
            .task(id: request) {
                let highlighted = await CodeHighlighter.shared.highlight(text, language: language, dark: request.dark)
                guard !Task.isCancelled else { return }
                result = (request, highlighted)
            }
    }
}

/// 串行复用 JavaScriptCore 实例，解析不占用主线程；库只提供颜色，不改变原生排版。
actor CodeHighlighter {
    static let shared = CodeHighlighter()
    private lazy var engine = Highlighter()

    func highlight(_ text: String, language: String?, dark: Bool) -> AttributedString {
        let plain = AttributedString(text)
        guard !Task.isCancelled, !text.isEmpty,
              let language = language?.split(whereSeparator: \.isWhitespace).first?.lowercased(),
              let engine else { return plain }
        let theme = dark ? "github-dark" : "github"
        if engine.theme.name != theme { engine.setTheme(theme) }
        engine.ignoreIllegals = true
        guard let highlighted = engine.highlight(text, as: language), highlighted.string == text else { return plain }
        let styled = NSMutableAttributedString(attributedString: highlighted)
        let range = NSRange(location: 0, length: styled.length)
        for key: NSAttributedString.Key in [.font, .paragraphStyle, .backgroundColor] {
            styled.removeAttribute(key, range: range)
        }
        #if os(macOS)
        let native = (try? AttributedString(styled, including: \.appKit)) ?? plain
        #else
        let native = (try? AttributedString(styled, including: \.uiKit)) ?? plain
        #endif
        var result = native
        // Text 不读取平台颜色，且 scope 转换不会自动桥接，必须显式转为 SwiftUI.Color。
        for run in native.runs {
            #if os(macOS)
            if let color = run.appKit.foregroundColor {
                result[run.range].swiftUI.foregroundColor = Color(nsColor: color)
            }
            #else
            if let color = run.uiKit.foregroundColor {
                result[run.range].swiftUI.foregroundColor = Color(uiColor: color)
            }
            #endif
        }
        return result
    }
}
