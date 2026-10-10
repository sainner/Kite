import SwiftUI
#if os(macOS)
import AppKit
typealias ContextFont = NSFont
typealias ContextImage = NSImage
typealias ContextColor = NSColor
#else
import UIKit
import UniformTypeIdentifiers
typealias ContextFont = UIFont
typealias ContextImage = UIImage
typealias ContextColor = UIColor
#endif

/// 变量胶囊：变量菜单、条件的变量选择和段落正文里是同一个样子。正文里按一行字的高度画成图片嵌进文字。
struct ContextVariableChip: View {
    let title: String
    var missing = false
    var height: CGFloat?

    var body: some View {
        let tint = missing ? Theme.danger : Color.accentColor
        Text(title)
            .font(Theme.secondary)
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, height == nil ? 2 : 0)
            .frame(height: height)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// 段落正文：文字里嵌着变量胶囊，直接打字；胶囊整块选中、整块删除。Markdown 标记按样式显示，发给模型的仍是原文。
/// Mac 用 NSTextView，iPhone 与 iPad 用 UITextView。只有文字，底色与聚焦描边由所在的块卡片给。
struct ContextParagraphField: View {
    @Binding var parts: [ContextPart]
    let variables: [ContextScene.Variable]
    @Binding var focused: Bool
    /// 刚加的段落出现时直接放光标，放好后调 focusHandled。
    var focusRequested = false
    var focusHandled: () -> Void = {}
    @Environment(ContextEditor.self) private var editor: ContextEditor?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let style = ContextTextStyle(variables: variables, colorScheme: colorScheme, scale: displayScale, dynamicTypeSize: dynamicTypeSize)
        ContextTextView(parts: $parts, focused: $focused, style: style, editable: isEnabled, editor: editor,
                        focusRequested: focusRequested, focusHandled: focusHandled)
            .overlay(alignment: .topLeading) {
                if parts.isEmpty {
                    Text("段落文字")
                        .font(Theme.body)
                        .foregroundStyle(.tertiary)
                        .padding(ContextTextStyle.inset)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isEnabled ? 1 : 0.6)
            .typingTarget()
    }
}

/// 正文的字体、颜色与胶囊图片都由这里算；深浅外观、屏幕倍率或字号变了就重画胶囊。
struct ContextTextStyle: Equatable {
    /// 文字离卡片边的距离，与代码块正文一样。
    static let inset: CGFloat = 10

    let variables: [ContextScene.Variable]
    let colorScheme: ColorScheme
    let scale: CGFloat
    let dynamicTypeSize: DynamicTypeSize

    static func == (a: Self, b: Self) -> Bool {
        a.variables.map(\.name) == b.variables.map(\.name) && a.variables.map(\.title) == b.variables.map(\.title)
            && a.colorScheme == b.colorScheme && a.scale == b.scale && a.dynamicTypeSize == b.dynamicTypeSize
    }

    var font: ContextFont {
        #if os(macOS)
        .preferredFont(forTextStyle: .body)
        #else
        .preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize)))
        #endif
    }

    var attributes: [NSAttributedString.Key: Any] {
        #if os(macOS)
        [.font: font, .foregroundColor: NSColor.labelColor]
        #else
        [.font: font, .foregroundColor: UIColor.label]
        #endif
    }

    /// Markdown 的标记符号淡显，引用与列表符号次要色，行内代码垫一层浅底。
    var markColor: ContextColor {
        #if os(macOS)
        .tertiaryLabelColor
        #else
        .tertiaryLabel
        #endif
    }

    var secondaryColor: ContextColor {
        #if os(macOS)
        .secondaryLabelColor
        #else
        .secondaryLabel
        #endif
    }

    var codeBackground: ContextColor {
        #if os(macOS)
        NSColor.labelColor.withAlphaComponent(0.08)
        #else
        UIColor.label.withAlphaComponent(0.08)
        #endif
    }

    var code: ContextFont { .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular) }

    /// 一级、二级标题放大，三级以下与正文同号，都加粗。
    func heading(_ level: Int) -> ContextFont {
        let size = font.pointSize * (level == 1 ? 1.3 : level == 2 ? 1.15 : 1)
        #if os(macOS)
        return Self.adding(bold: true, to: NSFont(descriptor: font.fontDescriptor, size: size) ?? font)
        #else
        return Self.adding(bold: true, to: UIFont(descriptor: font.fontDescriptor, size: size))
        #endif
    }

    static func adding(bold: Bool, to font: ContextFont) -> ContextFont {
        #if os(macOS)
        let trait: NSFontDescriptor.SymbolicTraits = bold ? .bold : .italic
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait)), size: font.pointSize) ?? font
        #else
        let trait: UIFontDescriptor.SymbolicTraits = bold ? .traitBold : .traitItalic
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait)) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    private var lineHeight: CGFloat { font.ascender - font.descender }

    /// 胶囊比一行字矮 2 点，上下相邻两行的胶囊不贴在一起；底边落在字的下伸线上方 1 点。
    var chipBaseline: CGFloat { font.descender + 1 }

    func chip(_ name: String) -> ContextImage? {
        let title = variables.first { $0.name == name }?.title
        let renderer = ImageRenderer(content: ContextVariableChip(title: title ?? name, missing: title == nil, height: lineHeight - 2)
            .environment(\.colorScheme, colorScheme)
            .environment(\.dynamicTypeSize, dynamicTypeSize))
        renderer.scale = scale
        #if os(macOS)
        return renderer.nsImage
        #else
        return renderer.uiImage
        #endif
    }
}

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

/// 正文里的一个变量，占一个字符。
nonisolated final class ContextVariableAttachment: NSTextAttachment {
    let name: String

    init(name: String) {
        self.name = name
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) { nil }

    @MainActor func show(_ image: ContextImage?, style: ContextTextStyle) {
        guard let image else { return }
        #if os(macOS)
        attachmentCell = ContextChipCell(image: image, baseline: style.chipBaseline)
        #else
        self.image = image
        bounds = CGRect(origin: CGPoint(x: 0, y: style.chipBaseline), size: image.size)
        #endif
    }
}

#if os(macOS)
/// Mac 的 TextKit 1 按单元格排附件：尺寸取图片，底边按 baseline 下移。
private final class ContextChipCell: NSTextAttachmentCell {
    private nonisolated let size: NSSize
    private nonisolated let baseline: CGFloat

    init(image: NSImage, baseline: CGFloat) {
        size = image.size
        self.baseline = baseline
        super.init(imageCell: image)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    nonisolated override func cellSize() -> NSSize { size }
    nonisolated override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: baseline) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        image?.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
#endif

/// 在 Kite 的正文之间拷贝时保留变量；拷到别处是纯文字。
private let contextPartsType = "app.kite.context-parts"

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

    func endEditing() {
        #if os(macOS)
        if view?.window?.firstResponder === view { view?.window?.makeFirstResponder(nil) }
        #else
        view?.resignFirstResponder()
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

private struct ContextTextView {
    @Binding var parts: [ContextPart]
    @Binding var focused: Bool
    let style: ContextTextStyle
    let editable: Bool
    let editor: ContextEditor?
    let focusRequested: Bool
    let focusHandled: () -> Void

    func makeCoordinator() -> ContextTextCoordinator {
        ContextTextCoordinator(parts: $parts, focused: $focused, style: style)
    }

    /// 新加的段落等视图放进窗口后再放光标。
    fileprivate func requestFocus(_ coordinator: ContextTextCoordinator) {
        guard focusRequested else { return }
        Task { @MainActor in
            coordinator.becomeFocused()
            focusHandled()
        }
    }
}

#if os(macOS)
extension ContextTextView: NSViewRepresentable {
    func makeNSView(context: Context) -> ContextNSTextView {
        let coordinator = context.coordinator
        let layout = NSLayoutManager()
        coordinator.storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = ContextNSTextView(frame: .zero, textContainer: container)
        view.coordinator = coordinator
        view.delegate = coordinator
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.focusRingType = .none
        view.usesFontPanel = false
        view.usesRuler = false
        // 提示词按原样交给模型，不替换引号、破折号，也不自动改字。
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.textContainerInset = NSSize(width: ContextTextStyle.inset, height: ContextTextStyle.inset)
        view.typingAttributes = style.attributes
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        coordinator.view = view
        coordinator.editor = editor
        coordinator.load()
        return view
    }

    func updateNSView(_ view: ContextNSTextView, context: Context) {
        view.isEditable = editable
        view.isSelectable = true
        context.coordinator.update(parts: $parts, focused: $focused, style: style, editor: editor)
        requestFocus(context.coordinator)
    }

    static func dismantleNSView(_ view: ContextNSTextView, coordinator: ContextTextCoordinator) {
        coordinator.dismantle()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ContextNSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let inset = view.textContainerInset
        return CGSize(width: width, height: context.coordinator.height(for: width - inset.width * 2) + inset.height * 2)
    }
}

/// 不带滚动的多行文本视图，高度随内容；Tab 换到下一个输入框，Esc 收起光标。
final class ContextNSTextView: NSTextView {
    weak var coordinator: ContextTextCoordinator?
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { coordinator?.focus(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { coordinator?.focus(false) }
        return resigned
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.init(contextPartsType), .string] }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.init(contextPartsType), .string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let textStorage else { return false }
        let parts = ContextTextCoordinator.parts(of: textStorage.attributedSubstring(from: selectedRange()))
        switch type {
        case .init(contextPartsType):
            guard let data = try? JSONEncoder().encode(parts) else { return false }
            return pboard.setData(data, forType: type)
        case .string:
            return pboard.setString(parts.plainText, forType: .string)
        default:
            return super.writeSelection(to: pboard, type: type)
        }
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == .init(contextPartsType), let coordinator, let data = pboard.data(forType: type),
           let parts = try? JSONDecoder().decode([ContextPart].self, from: data) {
            insertText(coordinator.attributed(parts), replacementRange: selectedRange())
            return true
        }
        return super.readSelection(from: pboard, type: type)
    }
}

extension ContextTextCoordinator: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) { changed() }

    func textViewDidChangeSelection(_ notification: Notification) {
        // 光标停在胶囊后面时，接着打的字不要继承附件；输入法还在拼写时不动。
        if let view, !view.hasMarkedText() { view.typingAttributes = style.attributes }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)): textView.window?.selectNextKeyView(nil)
        case #selector(NSResponder.insertBacktab(_:)): textView.window?.selectPreviousKeyView(nil)
        case #selector(NSResponder.cancelOperation(_:)): textView.window?.makeFirstResponder(nil)
        default: return false
        }
        return true
    }
}
#else
extension ContextTextView: UIViewRepresentable {
    func makeUIView(context: Context) -> ContextUITextView {
        let coordinator = context.coordinator
        let layout = NSLayoutManager()
        coordinator.storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = ContextUITextView(frame: .zero, textContainer: container)
        view.coordinator = coordinator
        view.delegate = coordinator
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.allowsEditingTextAttributes = false
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.autocapitalizationType = .none
        view.textContainerInset = UIEdgeInsets(top: ContextTextStyle.inset, left: ContextTextStyle.inset,
                                               bottom: ContextTextStyle.inset, right: ContextTextStyle.inset)
        view.typingAttributes = style.attributes
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        coordinator.view = view
        coordinator.editor = editor
        coordinator.load()
        return view
    }

    func updateUIView(_ view: ContextUITextView, context: Context) {
        view.isEditable = editable
        context.coordinator.update(parts: $parts, focused: $focused, style: style, editor: editor)
        requestFocus(context.coordinator)
    }

    static func dismantleUIView(_ view: ContextUITextView, coordinator: ContextTextCoordinator) {
        coordinator.dismantle()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: ContextUITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let inset = view.textContainerInset
        return CGSize(width: width, height: context.coordinator.height(for: width - inset.left - inset.right) + inset.top + inset.bottom)
    }
}

final class ContextUITextView: UITextView {
    weak var coordinator: ContextTextCoordinator?
    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0 else { return super.copy(sender) }
        let parts = ContextTextCoordinator.parts(of: textStorage.attributedSubstring(from: selectedRange))
        guard let data = try? JSONEncoder().encode(parts) else { return super.copy(sender) }
        UIPasteboard.general.setItems([[contextPartsType: data, UTType.utf8PlainText.identifier: parts.plainText]])
    }

    override func cut(_ sender: Any?) {
        guard selectedRange.length > 0 else { return super.cut(sender) }
        copy(sender)
        deleteBackward()
    }

    override func paste(_ sender: Any?) {
        guard let coordinator, let data = UIPasteboard.general.data(forPasteboardType: contextPartsType),
              let parts = try? JSONDecoder().decode([ContextPart].self, from: data) else { return super.paste(sender) }
        coordinator.insert(parts: parts)
    }
}

extension ContextTextCoordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) { changed() }
    func textViewDidBeginEditing(_ textView: UITextView) { focus(true) }
    func textViewDidEndEditing(_ textView: UITextView) { focus(false) }
    func textViewDidChangeSelection(_ textView: UITextView) {
        if textView.markedTextRange == nil { textView.typingAttributes = style.attributes }
    }
}
#endif
