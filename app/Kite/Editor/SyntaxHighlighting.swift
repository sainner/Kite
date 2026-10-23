import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterMarkdown
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML
#if canImport(UIKit)
import UIKit
/// 两端文字存储的改动种类只差名字。
typealias TextStorageEditActions = NSTextStorage.EditActions
#else
import AppKit
typealias TextStorageEditActions = NSTextStorageEditActions
#endif

/// 代码文件的语言：tree-sitter 的语法和上色规则。规则随语法包打进 App（包名_目标名.bundle 里的 queries），
/// 按各语法仓库 tree-sitter.json 的组合拼起来，例如 TypeScript 带上 JavaScript 的；嵌在别的语言里的（HTML 里的脚本、Markdown 的行内）不上色。
struct CodeLanguage {
    let language: Language
    let highlights: Query

    /// 按文件名找；认不出的返回 nil，按纯文字编辑。建好的各语言留着复用。
    static func forPath(_ path: String) -> CodeLanguage? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        guard let spec = specs.first(where: { $0.extensions.contains(ext) || $0.names.contains(name) }) else { return nil }
        if let loaded = loaded[spec.id] { return loaded }
        let language = Language(spec.parser())
        let source = spec.queries.compactMap { bundle, file in
            Bundle.main.url(forResource: bundle, withExtension: "bundle").flatMap(Bundle.init(url:))?
                .url(forResource: file, withExtension: "scm", subdirectory: "queries").flatMap { try? Data(contentsOf: $0) }
        }
        let result = source.count == spec.queries.count ? (try? Query(language: language, data: Data(source.joined(separator: Data("\n".utf8)))))
            .map { CodeLanguage(language: language, highlights: $0) } : nil
        loaded[spec.id] = .some(result)
        return result
    }

    private static var loaded: [String: CodeLanguage?] = [:]

    private struct Spec {
        let id: String
        var extensions: Set<String> = []
        var names: Set<String> = []
        let parser: () -> OpaquePointer
        /// 规则文件：(bundle 名, 文件名)，按顺序拼，前面的规则优先。
        let queries: [(String, String)]
    }

    private static let javascript = "TreeSitterJavaScript_TreeSitterJavaScript"
    private static let typescript = "TreeSitterTypeScript_TreeSitterTypeScript"
    private static let specs: [Spec] = [
        Spec(id: "swift", extensions: ["swift"], parser: { tree_sitter_swift() }, queries: [("TreeSitterSwift_TreeSitterSwift", "highlights")]),
        Spec(id: "javascript", extensions: ["js", "mjs", "cjs", "jsx"], parser: { tree_sitter_javascript() },
             queries: [(javascript, "highlights"), (javascript, "highlights-jsx"), (javascript, "highlights-params")]),
        Spec(id: "typescript", extensions: ["ts", "mts", "cts"], parser: { tree_sitter_typescript() },
             queries: [(typescript, "highlights"), (javascript, "highlights")]),
        Spec(id: "tsx", extensions: ["tsx"], parser: { tree_sitter_tsx() },
             queries: [("TreeSitterTypeScript_TreeSitterTSX", "highlights"), (javascript, "highlights-jsx"), (javascript, "highlights")]),
        Spec(id: "python", extensions: ["py", "pyi"], parser: { tree_sitter_python() }, queries: [("TreeSitterPython_TreeSitterPython", "highlights")]),
        Spec(id: "go", extensions: ["go"], parser: { tree_sitter_go() }, queries: [("TreeSitterGo_TreeSitterGo", "highlights")]),
        Spec(id: "rust", extensions: ["rs"], parser: { tree_sitter_rust() }, queries: [("TreeSitterRust_TreeSitterRust", "highlights")]),
        Spec(id: "json", extensions: ["json", "jsonc"], parser: { tree_sitter_json() }, queries: [("TreeSitterJSON_TreeSitterJSON", "highlights")]),
        Spec(id: "html", extensions: ["html", "htm"], parser: { tree_sitter_html() }, queries: [("TreeSitterHTML_TreeSitterHTML", "highlights")]),
        Spec(id: "css", extensions: ["css"], parser: { tree_sitter_css() }, queries: [("TreeSitterCSS_TreeSitterCSS", "highlights")]),
        Spec(id: "bash", extensions: ["sh", "bash", "zsh", "command"], names: [".bashrc", ".bash_profile", ".zshrc", ".zprofile"],
             parser: { tree_sitter_bash() }, queries: [("TreeSitterBash_TreeSitterBash", "highlights")]),
        Spec(id: "yaml", extensions: ["yml", "yaml"], parser: { tree_sitter_yaml() }, queries: [("TreeSitterYAML_TreeSitterYAML", "highlights")]),
        Spec(id: "toml", extensions: ["toml"], parser: { tree_sitter_toml() }, queries: [("TreeSitterTOML_TreeSitterTOML", "highlights")]),
        Spec(id: "markdown", extensions: ["md", "markdown"], parser: { tree_sitter_markdown() },
             queries: [("TreeSitterMarkdown_TreeSitterMarkdown", "highlights")]),
    ]
}

/// 一段代码的字色，见 SyntaxTree.highlights。
struct SyntaxHighlight {
    let range: NSRange
    let color: PlatformColor
}

/// 各行开头的位置（UTF-16），改动时只重算改到的那几行。语法树要的行列号、行号栏都从这里取。
struct LineIndex {
    private(set) var starts: [Int] = [0]

    init(_ text: NSString) {
        starts = [0] + Self.breaks(in: text, range: NSRange(location: 0, length: text.length))
    }

    var count: Int { starts.count }

    /// offset 落在第几行（从 0 起）。
    func line(containing offset: Int) -> Int {
        var low = 0, high = starts.count
        while high - low > 1 {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle } else { high = middle }
        }
        return low
    }

    /// tree-sitter 的行列号：列按 UTF-16 的字节数算。
    func point(_ offset: Int) -> Point {
        let row = line(containing: offset)
        return Point(row: row, column: (offset - starts[row]) * 2)
    }

    /// 文字改了以后跟上：range 是改后的范围，delta 是长度变化。
    mutating func edit(_ range: NSRange, delta: Int, in text: NSString) {
        let oldEnd = NSMaxRange(range) - delta
        // 换掉原来那段里的行首（不含改动起点本身），再把后面的整体挪 delta
        let low = firstStart(after: range.location), high = firstStart(after: oldEnd)
        let inserted = Self.breaks(in: text, range: range)
        starts.replaceSubrange(low..<high, with: inserted)
        for index in (low + inserted.count)..<starts.count { starts[index] += delta }
    }

    private func firstStart(after offset: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// range 里每个换行之后的位置。
    private static func breaks(in text: NSString, range: NSRange) -> [Int] {
        var result: [Int] = []
        var buffer = [unichar](repeating: 0, count: 4096)
        var location = range.location
        while location < NSMaxRange(range) {
            let count = min(buffer.count, NSMaxRange(range) - location)
            text.getCharacters(&buffer, range: NSRange(location: location, length: count))
            for index in 0..<count where buffer[index] == 0x0A { result.append(location + index + 1) }
            location += count
        }
        return result
    }
}

/// 一份代码的语法树：打开时整份解析一次，之后每次改动只重新解析改到的地方（tree-sitter 增量解析）。
final class SyntaxTree {
    private let parser = Parser()
    private let query: Query
    private(set) var tree: MutableTree?

    init?(language: CodeLanguage, text: NSString) {
        guard (try? parser.setLanguage(language.language)) != nil else { return nil }
        query = language.highlights
        tree = parse(text, previous: nil)
    }

    /// 文字改了以后跟上：range 是改后的范围，delta 是长度变化，oldLines 是改之前的行。返回改动以外颜色也可能变了的范围。
    func edit(_ range: NSRange, delta: Int, in text: NSString, oldLines: LineIndex, newLines: LineIndex) -> [NSRange] {
        guard let old = tree else { return [] }
        let oldEnd = NSMaxRange(range) - delta
        old.edit(InputEdit(startByte: range.location * 2, oldEndByte: oldEnd * 2, newEndByte: NSMaxRange(range) * 2,
                           startPoint: oldLines.point(range.location), oldEndPoint: oldLines.point(oldEnd),
                           newEndPoint: newLines.point(NSMaxRange(range))))
        guard let new = parse(text, previous: old) else { return [] }
        tree = new
        return old.changedRanges(from: new).map { NSRange(location: Int($0.bytes.lowerBound) / 2, length: Int($0.bytes.count) / 2) }
    }

    /// range 里配了颜色的各段代码，按上色的先后排好，后上的盖前面的：外面的大范围先上、套在里面的后上；
    /// 同一范围几条规则都命中时，规则里写在前面的算数（tree-sitter 上色的约定），没配颜色的不参与。
    func highlights(in range: NSRange, text: NSString) -> [SyntaxHighlight] {
        guard let tree else { return [] }
        let cursor = query.execute(in: tree)
        cursor.setRange(range)
        let context = Predicate.Context { range, _ in
            NSMaxRange(range) <= text.length ? text.substring(with: range) : nil
        }
        var captures: [(capture: QueryCapture, color: PlatformColor)] = []
        for match in cursor.resolve(with: context) {
            captures += match.captures.compactMap { capture in capture.name.flatMap(SyntaxPalette.color(for:)).map { (capture, $0) } }
        }
        captures.sort { a, b in
            if a.capture.range.location != b.capture.range.location { return a.capture.range.location < b.capture.range.location }
            if a.capture.range.length != b.capture.range.length { return a.capture.range.length > b.capture.range.length }
            return a.capture.patternIndex > b.capture.patternIndex
        }
        return captures.map { SyntaxHighlight(range: $0.capture.range, color: $0.color) }
    }

    private func parse(_ text: NSString, previous: MutableTree?) -> MutableTree? {
        let length = text.length
        return parser.parse(tree: previous) { byte, _ in
            let start = byte / 2
            guard start < length else { return nil }
            var buffer = [unichar](repeating: 0, count: min(4096, length - start))
            text.getCharacters(&buffer, range: NSRange(location: start, length: buffer.count))
            return buffer.withUnsafeBytes { Data($0) }
        }
    }
}

/// 上色规则里的名字（keyword.function、string 这类）对应的字色，取自对话代码块用的 highlight.js 主题 github / github-dark，
/// 两处的代码看起来一样。没列的（变量、标点）用正文字色。
enum SyntaxPalette {
    static func color(for name: String) -> PlatformColor? {
        let parts = name.split(separator: ".")
        let second = parts.dropFirst().first
        switch parts.first {
        case "keyword", "boolean", "conditional", "repeat", "include", "exception": return keyword
        // CSS 的 @media、@import 这类规则
        case "media", "import", "charset", "keyframes", "supports": return keyword
        case "string" where second == "escape" || second == "regexp": return escape
        case "string" where second == "special" && parts.dropFirst(2).first == "key": return constant
        case "string", "character": return string
        case "escape": return escape
        case "comment": return comment
        case "function", "method", "constructor": return function
        case "type", "namespace": return type
        case "number", "float", "constant", "property", "attribute", "label": return constant
        case "tag" where second == nil: return tag
        case "variable" where second == "builtin": return keyword
        case "punctuation" where second == "special": return keyword
        // Markdown：标题、行内代码、链接
        case "text" where second == "title": return constant
        case "text" where second == "literal": return string
        case "text" where second == "uri" || second == "reference": return tag
        default: return nil
        }
    }

    private static let keyword = dynamic(0xD73A49, 0xFF7B72)
    private static let string = dynamic(0x032F62, 0xA5D6FF)
    private static let escape = dynamic(0x22863A, 0x7EE787)
    private static let comment = dynamic(0x6A737D, 0x8B949E)
    private static let function = dynamic(0x6F42C1, 0xD2A8FF)
    private static let type = dynamic(0xE36209, 0xFFA657)
    private static let constant = dynamic(0x005CC5, 0x79C0FF)
    private static let tag = dynamic(0x22863A, 0x7EE787)

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> PlatformColor {
        #if canImport(UIKit)
        UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) }
        #else
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light) }
        #endif
    }

    private static func rgb(_ value: UInt32) -> PlatformColor {
        PlatformColor(red: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                      blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// 把语法树的颜色交给 TextKit 2：内容存储生成段落时按语法树加上字色（textParagraphWith），文字存储里不放颜色，撤销、复制都不带。
/// 打字时在文字存储处理这次改动时同步增量解析，改到的段落随即重新生成、带上新颜色；
/// 语法树说别处的颜色也变了（打了 /* 这类），在这一轮事件末尾、画出来之前让那些段落重新生成。
/// 没用显示属性（rendering attributes）：改了排好的段落的显示属性，TextKit 不重画，打字时它还会把已有的挪错位（2026-10-23 Mac 实测）。
final class SyntaxStyler: NSObject, NSTextStorageDelegate, NSTextContentStorageDelegate {
    private let contentStorage: NSTextContentStorage
    let syntax: SyntaxTree?
    private(set) var lines: LineIndex
    /// 改动以外颜色也变了、等着重新生成的范围。
    private var recolor = IndexSet()
    private var scheduled = false
    /// 文字改了（同步，在文字存储处理改动时）。
    var edited: (() -> Void)?
    /// 一次改动处理完以后调，例如行号栏重画。
    var changed: (() -> Void)?

    init?(layoutManager: NSTextLayoutManager, language: CodeLanguage?) {
        guard let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              let storage = contentStorage.textStorage else { return nil }
        self.contentStorage = contentStorage
        lines = LineIndex(storage.mutableString)
        syntax = language.flatMap { SyntaxTree(language: $0, text: storage.mutableString) }
        super.init()
        storage.delegate = self
        contentStorage.delegate = self
    }

    nonisolated func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        // 内容存储只在主线程上生成段落，交出去的段落不再改
        nonisolated(unsafe) var result: NSTextParagraph?
        MainActor.assumeIsolated { result = paragraph(range) }
        return result
    }

    /// 带字色的一段；没有语言时交给内容存储照原样生成。
    func paragraph(_ range: NSRange) -> NSTextParagraph? {
        guard let syntax, let storage = contentStorage.textStorage else { return nil }
        let styled = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        for highlight in syntax.highlights(in: range, text: storage.mutableString) {
            let clipped = NSIntersectionRange(highlight.range, range)
            guard clipped.length > 0 else { continue }
            styled.addAttribute(.foregroundColor, value: highlight.color, range: NSRange(location: clipped.location - range.location, length: clipped.length))
        }
        return NSTextParagraph(attributedString: styled)
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: TextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // 文本视图的文字存储只在主线程上改
        nonisolated(unsafe) let storage = textStorage
        MainActor.assumeIsolated {
            let text = storage.mutableString
            let old = lines
            lines.edit(editedRange, delta: delta, in: text)
            recolor.shift(startingAt: NSMaxRange(editedRange) - delta, by: delta)
            for range in syntax?.edit(editedRange, delta: delta, in: text, oldLines: old, newLines: lines) ?? [] {
                if let range = Range(range) { recolor.insert(integersIn: range) }
            }
            edited?()
            guard !scheduled else { return }
            scheduled = true
            // 排在这一轮事件处理完之后、画出来之前
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
                MainActor.assumeIsolated { self?.flush() }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    /// 一次改动处理完：别处颜色变了的段落重新生成，再告诉文本视图。
    private func flush() {
        scheduled = false
        if let storage = contentStorage.textStorage, !recolor.isEmpty {
            let ranges = recolor.rangeView.map { NSRange(location: $0.lowerBound, length: min($0.count, storage.length - $0.lowerBound)) }
            recolor = []
            storage.beginEditing()
            for range in ranges where range.length > 0 { storage.edited(.editedAttributes, range: range, changeInLength: 0) }
            storage.endEditing()
        }
        changed?()
    }

    func nsRange(_ textRange: NSTextRange) -> NSRange? {
        let start = contentStorage.documentRange.location
        let location = contentStorage.offset(from: start, to: textRange.location)
        let length = contentStorage.offset(from: textRange.location, to: textRange.endLocation)
        guard location != NSNotFound, length != NSNotFound else { return nil }
        return NSRange(location: location, length: length)
    }
}
