import SwiftUI

/// 一段 Markdown，每块一个 SwiftUI Text。解析用 Foundation 自带的（AttributedString 的 full 语法），这里只按它标出的块逐块排版：
/// SwiftUI 的 Text 只认行内的粗体、斜体、代码和链接，标题、列表、代码块、引用、表格这些块它不排。
/// 对话里 agent 的话两端都改用 SelectableMarkdown（平台文本视图，能跨段选字），这里剩文件预览在用；
/// SelectableMarkdown 的样子以它为准。正文字号跟着外面：对话里是正文，展开的工具结果里小一号。
/// 源字符串变化时才解析；布局或其他消息更新引起重画时，沿用当前视图缓存。
struct MarkdownView: View {
    let source: String
    @State private var document = MarkdownDocument()
    @Environment(\.font) private var font
    @Environment(\.fontResolutionContext) private var fontContext

    init(_ source: String) {
        self.source = source
    }

    var body: some View {
        let blocks = document.blocks(for: source)
        let fontSize = (font ?? .body).resolve(in: fontContext).pointSize
        VStack(alignment: .leading, spacing: Metrics.markdownBlockGap(fontSize)) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index])
            }
        }
        .textSelection(.enabled)
    }
}

/// 每个消息视图缓存自己最近一次解析；其他消息更新或布局重画不重复解析已完成正文。
final class MarkdownDocument {
    private var source: String?
    private var parsed: [MarkdownBlock] = []

    func blocks(for source: String) -> [MarkdownBlock] {
        if self.source != source {
            parsed = MarkdownBlock.parse(source)
            self.source = source
        }
        return parsed
    }
}

struct MarkdownBlock: Equatable {
    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case code(language: String?)
        case quote
        case rule
        /// marker 是「•」或「3.」；同一项的第二段没有 marker。
        case listItem(marker: String?)
        case table(header: [AttributedString], rows: [[AttributedString]])
    }

    var kind: Kind
    var text: AttributedString
    /// 套在几层列表里。
    var depth = 0
    /// 这一块在原文里的位置，复制时按选区取回 Markdown 原文用。
    var source: MarkdownSource?

    static func parse(_ source: String) -> [MarkdownBlock] {
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        options.appliesSourcePositionAttributes = true
        guard let document = try? AttributedString(markdown: source, options: options) else {
            return [MarkdownBlock(kind: .paragraph, text: AttributedString(source), source: .whole(source))]
        }
        let locator = SourceLocator(source)
        var blocks: [MarkdownBlock] = []
        var lastListItem: Int?
        /// 正在收的表格：它的 identity、表头、各行。
        var table: (id: Int, header: [AttributedString], rows: [Int: [AttributedString]])?

        /// 正在收的表格各格在原文里的位置，合起来是整张表的行。
        var tableSpans: [NSRange] = []

        func flushTable() {
            guard let current = table else { return }
            let rows = current.rows.keys.sorted().map { current.rows[$0]! }
            blocks.append(MarkdownBlock(kind: .table(header: current.header, rows: rows), text: AttributedString(),
                                        source: locator.block(spans: tableSpans)))
            table = nil
            tableSpans = []
        }

        // 相邻的字符块标记相同就是同一块；块标记从里往外排，第一个是这块本身
        for (intent, range) in document.runs[\.presentationIntent] {
            guard let intent, let first = intent.components.first else { continue }
            let text = AttributedString(document[range])

            if let tableComponent = intent.components.first(where: { if case .table = $0.kind { true } else { false } }) {
                if table?.id != tableComponent.identity {
                    flushTable()
                    table = (tableComponent.identity, [], [:])
                }
                for component in intent.components {
                    if case .tableHeaderRow = component.kind { table?.header.append(text); break }
                    if case .tableRow(let row) = component.kind { table?.rows[row, default: []].append(text); break }
                }
                tableSpans += text.runs.compactMap { $0.markdownSourcePosition.flatMap(locator.range) }
                continue
            }
            flushTable()

            let lists = intent.components.filter {
                switch $0.kind { case .orderedList, .unorderedList: true; default: false }
            }
            var block = MarkdownBlock(kind: .paragraph, text: text, depth: lists.count)
            switch first.kind {
            case .header(let level): block.kind = .heading(level)
            case .codeBlock(let language):
                block.kind = .code(language: language)
                block.text = AttributedString(String(text.characters).trimmingCharacters(in: .newlines))
                block.source = locator.block(spans: text.runs.compactMap { $0.markdownSourcePosition.flatMap(locator.range) })
            case .blockQuote: block.kind = .quote
            case .thematicBreak: block.kind = .rule
            default:
                if intent.components.contains(where: { if case .blockQuote = $0.kind { true } else { false } }) {
                    block.kind = .quote
                }
            }
            // 列表项里的段落：这一项第一次出现才画 marker
            if case .paragraph = block.kind, let item = intent.components.first(where: { if case .listItem = $0.kind { true } else { false } }),
               case .listItem(let ordinal) = item.kind {
                let ordered = lists.first.map { if case .orderedList = $0.kind { true } else { false } } ?? false
                block.kind = .listItem(marker: lastListItem == item.identity ? nil : ordered ? "\(ordinal)." : "•")
                lastListItem = item.identity
            }
            switch block.kind {
            case .paragraph, .heading, .quote, .listItem: block.source = locator.prose(block.text)
            default: break
            }
            blocks.append(block)
        }
        flushTable()
        // 只有尚未组成语法的标记时也保留原文，结束后仍由同一解析器校正。
        if blocks.isEmpty && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [MarkdownBlock(kind: .paragraph, text: AttributedString(source), source: .whole(source))]
        }
        locator.fillGaps(&blocks)
        return blocks
    }
}

extension MarkdownBlock {
    /// 表格各格（表头在前，再逐行）在原文 source 里的位置：lines 是这一格的字连同标记占的那一段，不是整行。
    /// 表格以外的块、对不上原文的格给 nil。Mac 的表格卡片能选字，复制时按它取回原文。
    func tableCellSources(in source: String) -> [[MarkdownSource?]] {
        guard case .table(let header, let rows) = kind else { return [] }
        let locator = SourceLocator(source)
        return ([header] + rows).map { cells in
            cells.map { cell in
                guard var found = locator.prose(cell), let first = found.runs.first else { return nil }
                let lower = found.runs.map(\.outer.location).min() ?? first.outer.location
                let upper = found.runs.map { NSMaxRange($0.outer) }.max() ?? NSMaxRange(first.outer)
                found.lines = NSRange(location: lower, length: upper - lower)
                return found
            }
        }
    }
}

/// 一块 Markdown 在原文里的位置。下标都是 UTF-16 的，和 NSString、NSRange 一致。
struct MarkdownSource: Equatable {
    /// 这一块占的整行：从第一行行首（含列表符号、引用的 >、标题的 #）到最后一行行尾，不含行尾换行。
    var lines: NSRange
    /// 正文（MarkdownBlock.text）里依次每一段字在原文里的位置；代码块、表格、分隔线整块复制，没有。
    var runs: [Run] = []

    struct Run: Equatable {
        /// 在 text 里从哪起、多长。
        var start: Int
        var length: Int
        /// 这段字本身在原文里的位置，不含粗体、代码、链接的标记。
        var span: NSRange
        /// 连标记在内：粗体、代码、链接这类往两边扩到标记外；普通字等于 span。
        var outer: NSRange
        /// 和原文逐字相同（没有转义、实体、软换行），可以从中间截。
        var exact: Bool
        var styled: Bool
    }

    /// 解析不出结构时整段当一个逐字对应的段落。
    static func whole(_ source: String) -> MarkdownSource {
        let range = NSRange(location: 0, length: source.utf16.count)
        return MarkdownSource(lines: range, runs: [Run(start: 0, length: range.length, span: range, outer: range, exact: true, styled: false)])
    }
}

/// Foundation 给的源位置是第几行、第几个 UTF-8 字节，都从 1 起，结束列含这个字节；这里换成原文里的 UTF-16 下标。
private struct SourceLocator {
    let source: String
    let text: NSString
    /// 每一行行首的 UTF-8 下标。
    private let lineStarts: [String.Index]

    init(_ source: String) {
        self.source = source
        text = source as NSString
        var starts = [source.utf8.startIndex]
        var index = source.utf8.startIndex
        while index < source.utf8.endIndex {
            let next = source.utf8.index(after: index)
            if source.utf8[index] == UInt8(ascii: "\n") { starts.append(next) }
            index = next
        }
        lineStarts = starts
    }

    private func offset(line: Int, column: Int) -> Int? {
        guard line >= 1, line <= lineStarts.count, column >= 1,
              let index = source.utf8.index(lineStarts[line - 1], offsetBy: column - 1, limitedBy: source.utf8.endIndex) else { return nil }
        return index.utf16Offset(in: source)
    }

    func range(_ position: AttributedString.MarkdownSourcePosition) -> NSRange? {
        guard let start = offset(line: position.startLine, column: position.startColumn),
              let end = offset(line: position.endLine, column: position.endColumn + 1), end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// 把几段字所在的行连起来：第一段所在行的行首到最后一段所在行的行尾。
    func block(spans: [NSRange]) -> MarkdownSource? {
        guard let first = spans.map(\.location).min(), let last = spans.map(NSMaxRange).max() else { return nil }
        let start = text.lineRange(for: NSRange(location: first, length: 0)).location
        var end = 0
        text.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: max(last - 1, first), length: 0))
        return MarkdownSource(lines: NSRange(location: start, length: max(end, last) - start))
    }

    /// 段落、标题、引用、列表项：整行之外还记下正文里每段字的位置。没有位置的（软换行）取前后两段之间的原文。
    func prose(_ value: AttributedString) -> MarkdownSource? {
        var runs: [MarkdownSource.Run] = []
        var gaps: [Int] = []
        var start = 0
        for run in value.runs {
            let characters = String(value[run.range].characters)
            let length = characters.utf16.count
            let intent = run.inlinePresentationIntent ?? []
            let styled = run.link != nil || !intent.isDisjoint(with: [.code, .emphasized, .stronglyEmphasized, .strikethrough])
            if let span = run.markdownSourcePosition.flatMap(range) {
                runs.append(.init(start: start, length: length, span: span, outer: span,
                                  exact: text.substring(with: span) == characters, styled: styled))
            } else {
                gaps.append(runs.count)
                runs.append(.init(start: start, length: length, span: NSRange(location: NSNotFound, length: 0),
                                  outer: NSRange(location: NSNotFound, length: 0), exact: false, styled: false))
            }
            start += length
        }
        guard var block = block(spans: runs.map(\.span).filter { $0.location != NSNotFound }) else { return nil }
        for index in gaps {
            let before = runs[..<index].last { $0.span.location != NSNotFound }.map { NSMaxRange($0.span) } ?? block.lines.location
            let after = runs[(index + 1)...].first { $0.span.location != NSNotFound }?.span.location ?? NSMaxRange(block.lines)
            let gap = NSRange(location: before, length: max(after - before, 0))
            runs[index].span = gap
            runs[index].outer = gap
        }
        for index in runs.indices where runs[index].styled {
            runs[index].outer = markers(around: runs[index].span, within: block.lines)
        }
        block.runs = runs
        return block
    }

    /// 粗体、斜体、删除线、代码的标记和链接的方括号、尖括号、目标，从字的两边往外扩。
    private func markers(around span: NSRange, within lines: NSRange) -> NSRange {
        func character(_ index: Int) -> Character? {
            guard index >= lines.location, index < NSMaxRange(lines), let scalar = Unicode.Scalar(text.character(at: index)) else { return nil }
            return Character(scalar)
        }
        var lower = span.location
        while let c = character(lower - 1), "*_~`[<!".contains(c) { lower -= 1 }
        var upper = NSMaxRange(span)
        while let c = character(upper) {
            if "*_~`>".contains(c) {
                upper += 1
            } else if c == "]" {
                upper += 1
                // [文字](目标) 或 [文字][引用]：扩到配对的右括号
                guard let open = character(upper), open == "(" || open == "[" else { continue }
                let close: Character = open == "(" ? ")" : "]"
                var depth = 0
                while let next = character(upper) {
                    upper += 1
                    if next == open { depth += 1 } else if next == close { depth -= 1; if depth == 0 { break } }
                }
            } else {
                break
            }
        }
        return NSRange(location: lower, length: upper - lower)
    }

    /// 分隔线没有源位置：取前后两块之间那些不空的行。
    func fillGaps(_ blocks: inout [MarkdownBlock]) {
        for index in blocks.indices where blocks[index].source == nil {
            let before = blocks[..<index].last { $0.source != nil }.map { NSMaxRange($0.source!.lines) } ?? 0
            let after = blocks[(index + 1)...].first { $0.source != nil }?.source!.lines.location ?? text.length
            guard after > before else { continue }
            let between = text.substring(with: NSRange(location: before, length: after - before))
            let trimmed = between.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let found = (between as NSString).range(of: trimmed)
            blocks[index].source = block(spans: [NSRange(location: before + found.location, length: found.length)])
        }
    }
}

/// 一块 Markdown。agent 的话里，代码块、表格、分隔线也用它排，嵌在文本视图里（见 BlockAttachment）。
struct MarkdownBlockView: View {
    let block: MarkdownBlock
    @Environment(\.font) private var font
    @Environment(\.fontResolutionContext) private var fontContext

    private var fontSize: CGFloat { (font ?? .body).resolve(in: fontContext).pointSize }

    var body: some View {
        content
            .lineSpacing(Metrics.markdownLineSpacing(fontSize))
            .padding(.leading, CGFloat(max(block.depth - 1, 0)) * Metrics.listIndent)
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .paragraph:
            ReferenceLabel(block.text).fixedSize(horizontal: false, vertical: true)
        case .heading(let level):
            ReferenceLabel(block.text)
                .font(level <= 1 ? Theme.heading1 : level == 2 ? Theme.heading2 : Theme.heading3)
                .padding(.top, Metrics.markdownBlockGap(fontSize) / 2)
        case .code(let language):
            CodeBlock(text: String(block.text.characters), language: language).lineSpacing(0)
        case .quote:
            ReferenceLabel(block.text)
                .foregroundStyle(.secondary)
                .padding(.leading, Metrics.quoteIndent)
                .overlay(alignment: .leading) { Capsule().fill(Theme.rule).frame(width: 3) }
        case .rule:
            Divider()
        case .listItem(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker ?? "").monospacedDigit().frame(minWidth: Metrics.listMarker, alignment: .trailing)
                ReferenceLabel(block.text).fixedSize(horizontal: false, vertical: true)
            }
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)
        }
    }
}

/// 等宽的一段，比如命令、输出、代码。太长的先只显示开头几行，点了再展开；太宽的横着滚。
struct CodeBlock: View {
    let text: String
    var language: String?
    var maxLines: Int? = 14
    var background: Color = Theme.codeBackground
    var radius: CGFloat = Metrics.contentRadius
    @Environment(\.toast) private var toast

    private var languageLabel: String {
        language?.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "text"
    }

    private var isShell: Bool {
        ["bash", "sh", "shell", "zsh", "ksh", "fish"].contains(languageLabel.lowercased())
    }

    var body: some View {
        BlockCard(label: languageLabel, copyLabel: "复制代码", background: background, radius: radius) {
            copyToPasteboard(text, toast: toast)
        } actions: { _ in
            if isShell {
                Button {} label: {
                    BlockCardIcon("CodeTerminal")
                }
                .disabled(true)
                .help("在终端中执行（尚未接入）")
                .accessibilityLabel("在终端中执行")
            }
        } content: {
            CodeBlockContent(text: text, language: language, maxLines: maxLines).equatable()
        }
    }
}

/// 几何与按压状态不影响代码正文；输入没变时不重新拆行、拼接。
private struct CodeBlockContent: View, Equatable {
    let text: String
    let language: String?
    let maxLines: Int?

    var body: some View {
        Folded(lines: splitLines(text), limit: maxLines) { shown in
            ScrollView(.horizontal, showsIndicators: false) {
                HighlightedCode(text: shown.joined(separator: "\n"), language: language)
                    .font(Theme.code)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(10)
            }
            .hintsScrollOverflow(.horizontal)
        }
    }
}

/// 太长的先只显示开头 limit 行，点「显示全部」再展开。只多出几行的不折，省得点一下只多看两行。
struct Folded<Line, Content: View>: View {
    let lines: [Line]
    let limit: Int?
    @ViewBuilder let content: ([Line]) -> Content
    @State private var expanded = false

    var body: some View {
        let limit = limit ?? lines.count
        let folded = !expanded && lines.count > limit + 4
        VStack(alignment: .leading, spacing: 0) {
            content(folded ? Array(lines.prefix(limit)) : lines)
            if folded {
                Button("显示全部 \(lines.count) 行") { expanded = true }
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom], 10)
            }
        }
    }
}
