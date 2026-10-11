import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 正文里 Markdown 的显示样式：只改字体和颜色，不动文字。逐行认标题、引用、列表和代码围栏，行内认粗体、斜体与行内代码。
private enum ContextMarkdown {
    private static let heading = regex("^(#{1,6})[ \\t]+")
    private static let quote = regex("^>[ \\t]?")
    private static let list = regex("^[ \\t]*([-*+]|\\d{1,3}[.)])[ \\t]+")
    private static let bold = regex("\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*")
    private static let italic = regex("(?<![*\\w])\\*(?=[^\\s*])(.+?)(?<=[^\\s*])\\*(?![*\\w])")
    private static let code = regex("`[^`\\n]+`")

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    static func highlight(_ storage: NSTextStorage, style: ContextTextStyle) {
        let text = storage.string
        let string = text as NSString
        let full = NSRange(location: 0, length: string.length)
        storage.beginEditing()
        // 不能整体 setAttributes，那会把变量胶囊的附件也抹掉。
        storage.addAttributes(style.attributes, range: full)
        storage.removeAttribute(.backgroundColor, range: full)
        var fenced = false
        string.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            if string.substring(with: line).hasPrefix("```") {
                fenced.toggle()
                storage.addAttributes([.font: style.code, .foregroundColor: style.markColor], range: line)
                return
            }
            if fenced {
                storage.addAttribute(.font, value: style.code, range: line)
                return
            }
            if let match = heading.firstMatch(in: text, range: line) {
                storage.addAttribute(.font, value: style.heading(match.range(at: 1).length), range: line)
                storage.addAttribute(.foregroundColor, value: style.markColor, range: match.range)
            } else if let match = quote.firstMatch(in: text, range: line) {
                storage.addAttribute(.foregroundColor, value: style.secondaryColor, range: line)
                storage.addAttribute(.foregroundColor, value: style.markColor, range: match.range)
            } else if let match = list.firstMatch(in: text, range: line) {
                storage.addAttribute(.foregroundColor, value: style.secondaryColor, range: match.range(at: 1))
            }
            for match in bold.matches(in: text, range: line) {
                trait(storage, bold: true, range: match.range(at: 1))
                mark(storage, style, NSRange(location: match.range.location, length: 2), NSRange(location: NSMaxRange(match.range) - 2, length: 2))
            }
            for match in italic.matches(in: text, range: line) {
                trait(storage, bold: false, range: match.range(at: 1))
                mark(storage, style, NSRange(location: match.range.location, length: 1), NSRange(location: NSMaxRange(match.range) - 1, length: 1))
            }
            for match in code.matches(in: text, range: line) {
                storage.addAttributes([.font: style.code, .backgroundColor: style.codeBackground], range: match.range)
                mark(storage, style, NSRange(location: match.range.location, length: 1), NSRange(location: NSMaxRange(match.range) - 1, length: 1))
            }
        }
        storage.endEditing()
    }

    private static func trait(_ storage: NSTextStorage, bold: Bool, range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            if let font = value as? ContextFont { storage.addAttribute(.font, value: ContextTextStyle.adding(bold: bold, to: font), range: run) }
        }
    }

    private static func mark(_ storage: NSTextStorage, _ style: ContextTextStyle, _ ranges: NSRange...) {
        for range in ranges { storage.addAttribute(.foregroundColor, value: style.markColor, range: range) }
    }
}

/// 工具栏里的格式操作，都是改 Markdown 标记：行内的套上或去掉成对符号，整行的加上或去掉行首标记。
enum ContextFormat {
    case bold, italic, code, heading(Int), bullet, numbered, quote
}

extension [ContextPart] {
    /// 相邻文字并成一段、去掉空文字；判断两份正文是否一样都先这样整理。
    var normalized: [ContextPart] {
        reduce(into: []) { result, part in
            guard part.type == "text" else { return result.append(part) }
            guard let text = part.text, !text.isEmpty else { return }
            if let last = result.last, last.type == "text" {
                result[result.count - 1].text = (last.text ?? "") + text
            } else {
                result.append(.text(text))
            }
        }
    }

    /// 拷到别处时的纯文字，变量写成 {变量标识}。
    var plainText: String {
        map { $0.type == "variable" ? "{\($0.name ?? "")}" : $0.text ?? "" }.joined()
    }

    /// 写死的文字，不含变量；字数和 token 都只数它。
    var literalText: String {
        compactMap { $0.type == "text" ? $0.text : nil }.joined()
    }
}

/// 文本视图与正文的往返：外面的正文变了才重新载入，打字只写回整理后的正文，不回头改文本视图，光标和输入法都不受打扰。
final class ContextTextCoordinator: NSObject {
    let storage = NSTextStorage()
    var parts: Binding<[ContextPart]>
    var focused: Binding<Bool>
    var editor: ContextEditor?
    private(set) var style: ContextTextStyle
    #if os(macOS)
    weak var view: ContextNSTextView?
    #else
    weak var view: ContextUITextView?
    #endif
    /// 文本视图里现在的正文。
    private var shown: [ContextPart] = []
    private var chips: [String: ContextImage] = [:]
    /// 量高度用的另一套排版，挂在同一份文字上，不动输入框自己的排版。UITextView 自己量一次要把排版宽度改过去再改回来，
    /// 整段重排两遍；窄屏拉侧栏、底栏时整列每帧重新布局，每帧都会来问高度。量过的宽度记着，文字或样式变了才清。
    private let measuring = NSLayoutManager()
    private let measuringContainer = NSTextContainer(size: CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
    private var heights: [CGFloat: CGFloat] = [:]

    init(parts: Binding<[ContextPart]>, focused: Binding<Bool>, style: ContextTextStyle) {
        self.parts = parts
        self.focused = focused
        self.style = style
        measuringContainer.lineFragmentPadding = 0
        measuring.addTextContainer(measuringContainer)
        storage.addLayoutManager(measuring)
    }

    /// 排版宽度 width 下文字的高度，不含上下留白。
    func height(for width: CGFloat) -> CGFloat {
        let width = max((width * 2).rounded() / 2, 1)
        if let height = heights[width] { return height }
        if heights.count >= 8 { heights = [:] }
        measuringContainer.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        measuring.ensureLayout(for: measuringContainer)
        #if os(macOS)
        let line = measuring.defaultLineHeight(for: style.font)
        #else
        let line = style.font.lineHeight
        #endif
        let height = ceil(max(measuring.usedRect(for: measuringContainer).height, line))
        heights[width] = height
        return height
    }

    /// 文字或样式变了：清掉量过的高度，让外面重新问。
    private func remeasure() {
        heights = [:]
        view?.invalidateIntrinsicContentSize()
    }

    func update(parts: Binding<[ContextPart]>, focused: Binding<Bool>, style: ContextTextStyle, editor: ContextEditor?) {
        self.parts = parts
        self.focused = focused
        if editor !== self.editor {
            if self.editor?.target === self { self.editor?.target = nil }
            self.editor = editor
        }
        if style != self.style {
            self.style = style
            chips = [:]
            restyle()
        }
        if parts.wrappedValue.normalized != shown { load() }
    }

    func dismantle() {
        if editor?.target === self { editor?.target = nil }
    }

    /// 按绑定的正文重新载入。外部替换了内容，原来的撤销记录对不上了，一并清掉。
    func load() {
        let selection = selectedRange
        shown = parts.wrappedValue.normalized
        storage.setAttributedString(attributed(shown))
        ContextMarkdown.highlight(storage, style: style)
        view?.undoManager?.removeAllActions()
        selectedRange = NSRange(location: min(selection.location, storage.length), length: 0)
        remeasure()
    }

    /// 只换字体和胶囊图片，不动文字，撤销记录仍然有效。
    private func restyle() {
        let range = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.attachment, in: range) { value, _, _ in
            if let attachment = value as? ContextVariableAttachment { attachment.show(chip(attachment.name), style: style) }
        }
        ContextMarkdown.highlight(storage, style: style)
        view?.typingAttributes = style.attributes
        remeasure()
    }

    /// 用户改了文字：整理成正文写回绑定，重排 Markdown 样式。输入法还在拼写时不动样式，拼完会再来一次。
    func changed() {
        let value = Self.parts(of: storage)
        shown = value
        if value != parts.wrappedValue.normalized { parts.wrappedValue = value }
        if !composing { ContextMarkdown.highlight(storage, style: style) }
        remeasure()
    }

    private var composing: Bool {
        #if os(macOS)
        view?.hasMarkedText() ?? false
        #else
        view?.markedTextRange != nil
        #endif
    }

    func focus(_ focused: Bool) {
        if self.focused.wrappedValue != focused { self.focused.wrappedValue = focused }
        if focused { editor?.target = self }
    }

    func attributed(_ parts: [ContextPart]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for part in parts {
            if part.type == "variable", let name = part.name {
                let attachment = ContextVariableAttachment(name: name)
                attachment.show(chip(name), style: style)
                result.append(NSAttributedString(attachment: attachment))
            } else {
                result.append(NSAttributedString(string: part.text ?? ""))
            }
        }
        result.addAttributes(style.attributes, range: NSRange(location: 0, length: result.length))
        return result
    }

    static func parts(of text: NSAttributedString) -> [ContextPart] {
        var result: [ContextPart] = []
        let string = text.string as NSString
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let attachment = value as? ContextVariableAttachment {
                result += Array(repeating: .variable(attachment.name), count: range.length)
            } else {
                // 别处粘进来的图片等附件不是正文，丢掉占位符。
                result.append(.text(string.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")))
            }
        }
        return result.normalized
    }

    private func chip(_ name: String) -> ContextImage? {
        if let image = chips[name] { return image }
        let image = style.chip(name)
        chips[name] = image
        return image
    }

    private var selectedRange: NSRange {
        get {
            #if os(macOS)
            view?.selectedRange() ?? NSRange(location: storage.length, length: 0)
            #else
            view?.selectedRange ?? NSRange(location: storage.length, length: 0)
            #endif
        }
        set {
            #if os(macOS)
            view?.setSelectedRange(newValue)
            #else
            view?.selectedRange = newValue
            #endif
        }
    }

    func becomeFocused() {
        #if os(macOS)
        view?.window?.makeFirstResponder(view)
        #else
        view?.becomeFirstResponder()
        #endif
    }

    /// 替换一段文字并选中 selecting。Mac 走正常的输入路径，撤销照常；UITextView 没有插入带附件文字的输入接口，直接改文字存储，撤销记录随之作废。
    private func replace(_ range: NSRange, with text: NSAttributedString, selecting: NSRange) {
        guard let view else { return }
        becomeFocused()
        #if os(macOS)
        view.insertText(text, replacementRange: range)
        view.setSelectedRange(selecting)
        #else
        storage.replaceCharacters(in: range, with: text)
        view.selectedRange = selecting
        view.typingAttributes = style.attributes
        view.undoManager?.removeAllActions()
        changed()
        #endif
    }

    /// 插入一个变量到光标处，替换选中的文字。
    func insert(variable name: String) {
        let range = selectedRange
        replace(range, with: attributed([.variable(name)]), selecting: NSRange(location: range.location + 1, length: 0))
    }

    func insert(parts: [ContextPart]) {
        let range = selectedRange
        let text = attributed(parts)
        replace(range, with: text, selecting: NSRange(location: range.location + text.length, length: 0))
    }

    func apply(_ format: ContextFormat) {
        switch format {
        case .bold: wrap("**")
        case .italic: wrap("*")
        case .code: wrap("`")
        case .heading(let level): prefixLines { _ in String(repeating: "#", count: level) + " " }
        case .bullet: prefixLines { _ in "- " }
        case .numbered: prefixLines { "\($0 + 1). " }
        case .quote: prefixLines { _ in "> " }
        }
    }

    /// 选中的文字两边已经有这对符号就去掉，没有就套上；没选中时插入一对，光标放中间。
    private func wrap(_ marker: String) {
        let string = storage.string as NSString
        let range = selectedRange
        let count = (marker as NSString).length
        let before = NSRange(location: range.location - count, length: count)
        let after = NSRange(location: NSMaxRange(range), length: count)
        if range.location >= count, NSMaxRange(after) <= string.length,
           string.substring(with: before) == marker, string.substring(with: after) == marker {
            let inner = storage.attributedSubstring(from: range)
            replace(NSRange(location: before.location, length: NSMaxRange(after) - before.location), with: inner,
                    selecting: NSRange(location: before.location, length: range.length))
            return
        }
        let result = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        result.insert(NSAttributedString(string: marker, attributes: style.attributes), at: 0)
        result.append(NSAttributedString(string: marker, attributes: style.attributes))
        replace(range, with: result, selecting: NSRange(location: range.location + count, length: range.length))
    }

    /// 选中范围所在的各行换成同一种行首标记；已经全是这种标记时去掉。空行不加，只有一行空行时照加，方便接着打字。
    private func prefixLines(_ prefix: (Int) -> String) {
        let string = storage.string as NSString
        var range = string.lineRange(for: selectedRange)
        // 最后一行的换行不算进来，不然会多出一个空行。
        if range.length > 0, string.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
        let lines = string.substring(with: range).components(separatedBy: "\n")
        let targets = lines.indices.filter { !lines[$0].isEmpty || lines.count == 1 }
        let off = targets.enumerated().allSatisfy { number, index in lines[index].hasPrefix(prefix(number)) }
        let existing = try! NSRegularExpression(pattern: "^(#{1,6}[ \\t]+|>[ \\t]?|[ \\t]*(?:[-*+]|\\d{1,3}[.)])[ \\t]+)")
        let result = NSMutableAttributedString()
        var location = range.location
        for (index, line) in lines.enumerated() {
            let length = (line as NSString).length
            let piece = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: NSRange(location: location, length: length)))
            if let number = targets.firstIndex(of: index) {
                if let match = existing.firstMatch(in: line, range: NSRange(location: 0, length: length)) { piece.deleteCharacters(in: match.range) }
                if !off { piece.insert(NSAttributedString(string: prefix(number), attributes: style.attributes), at: 0) }
            }
            result.append(piece)
            if index < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: style.attributes)) }
            location += length + 1
        }
        replace(range, with: result, selecting: NSRange(location: range.location, length: result.length))
    }
}
