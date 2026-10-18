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
        // 查找时每块有几个匹配；表格和分隔线不找
        let counts = highlight.map { highlight in
            blocks.map { $0.searchableText.map { TextSearch.ranges(of: highlight.query, in: $0).count } ?? 0 }
        }
        let firsts = counts?.reduce(into: [0]) { $0.append($0.last! + $1) }
        VStack(alignment: .leading, spacing: Metrics.markdownBlockGap(fontSize)) {
            ForEach(blocks.indices, id: \.self) { index in
                Group {
                    if let images, let parts = MarkdownImagePart.split(blocks[index]) {
                        ForEach(parts.indices, id: \.self) { part in
                            switch parts[part] {
                            case .text(let block): MarkdownBlockView(block: block)
                            case .image(let source, let alt): MarkdownImage(source: source, alt: alt, loader: images)
                            }
                        }
                    } else {
                        MarkdownBlockView(block: blocks[index])
                    }
                }
                .environment(\.searchHighlight, counts.flatMap { counts in
                    guard let highlight, let firsts, counts[index] > 0 else { return nil }
                    let current = highlight.current.map { $0 - firsts[index] }
                    return SearchHighlight(query: highlight.query, current: current.flatMap { (0..<counts[index]).contains($0) ? $0 : nil })
                })
                .id(Self.blockID(index))
            }
        }
        .textSelection(.enabled)
        .preference(key: MarkdownMatches.self, value: counts.map { counts in
            counts.indices.flatMap { Array(repeating: $0, count: counts[$0]) }
        } ?? [])
    }

    /// 第 index 块的视图 id，查找时滚到当前匹配所在的块用。
    static func blockID(_ index: Int) -> String { "markdown-block-\(index)" }

    @Environment(\.markdownImages) private var images
    /// 查找的关键字，current 是在整篇里第几个。
    @Environment(\.searchHighlight) private var highlight
}

/// 查找时每个匹配在第几块，按先后；用的地方据此数个数、滚到当前那个。
struct MarkdownMatches: PreferenceKey {
    static let defaultValue: [Int] = []
    static func reduce(value: inout [Int], nextValue: () -> [Int]) { value += nextValue() }
}

/// 文件预览里的 Markdown 显示图片：按原文里写的地址（相对路径或网址）取图。环境里没有时，图片只显示替代文字。
/// id 相同就当作同一个取图方式，免得每次重画都换掉环境。
struct MarkdownImageLoader: Equatable {
    let id: String
    let load: (String) async throws -> PlatformImage

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

extension EnvironmentValues {
    @Entry var markdownImages: MarkdownImageLoader? = nil
}

/// 段落里的图片单独成块，前后的字仍是段落。
private enum MarkdownImagePart {
    case text(MarkdownBlock)
    case image(source: String, alt: String)

    static func split(_ block: MarkdownBlock) -> [Self]? {
        guard case .paragraph = block.kind, block.text.runs.contains(where: { $0.imageURL != nil }) else { return nil }
        var parts: [Self] = []
        for (url, range) in block.text.runs[\.imageURL] {
            let text = AttributedString(block.text[range])
            if let url {
                parts.append(.image(source: url.relativeString, alt: String(text.characters)))
            } else if !String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(.text(MarkdownBlock(kind: .paragraph, text: text, depth: block.depth)))
            }
        }
        return parts
    }
}

private struct MarkdownImage: View {
    let source: String
    let alt: String
    let loader: MarkdownImageLoader
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                #if os(macOS)
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: image.size.width)
                #else
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: image.size.width)
                #endif
            } else if failed {
                Label(alt.isEmpty ? source : alt, systemImage: "photo").foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .accessibilityLabel(alt)
        .task(id: source) {
            do { image = try await loader.load(source) } catch { failed = true }
        }
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

    /// 查找时在这一块里找的字；表格和分隔线是 nil。
    var searchableText: String? {
        switch kind {
        case .paragraph, .heading, .code, .quote, .listItem: String(text.characters)
        case .rule, .table: nil
        }
    }

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
    @Environment(\.searchHighlight) private var highlight

    /// 查找时标出匹配的字。
    private var text: AttributedString { highlight?.apply(to: block.text) ?? block.text }

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
            ReferenceLabel(text).fixedSize(horizontal: false, vertical: true)
        case .heading(let level):
            ReferenceLabel(text)
                .font(level <= 1 ? Theme.heading1 : level == 2 ? Theme.heading2 : Theme.heading3)
                .padding(.top, Metrics.markdownBlockGap(fontSize) / 2)
        case .code(let language):
            // 有匹配时整段展开，折起来的部分里的匹配也看得见；高亮由代码块的语法高亮叠上
            CodeBlock(text: String(block.text.characters), language: language, maxLines: highlight == nil ? 14 : nil).lineSpacing(0)
        case .quote:
            ReferenceLabel(text)
                .foregroundStyle(.secondary)
                .padding(.leading, Metrics.quoteIndent)
                .overlay(alignment: .leading) { Capsule().fill(Theme.rule).frame(width: 3) }
        case .rule:
            Divider()
        case .listItem(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker ?? "").monospacedDigit().frame(minWidth: Metrics.listMarker, alignment: .trailing)
                ReferenceLabel(text).fixedSize(horizontal: false, vertical: true)
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
    /// shell 代码的标题栏放「在终端中执行」；审批卡片里的命令不放。
    var terminal = true
    /// 代码区最高多高，再长在里面竖着滚；nil 不限。
    var maxHeight: CGFloat?
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
            if terminal && isShell {
                Button {} label: {
                    BlockCardIcon("CodeTerminal")
                }
                .disabled(true)
                .help("在终端中执行（尚未接入）")
                .accessibilityLabel("在终端中执行")
            }
        } content: {
            CodeBlockContent(text: text, language: language, maxLines: maxLines, maxHeight: maxHeight).equatable()
        }
    }
}

/// 几何与按压状态不影响代码正文；输入没变时不重新拆行、拼接。
private struct CodeBlockContent: View, Equatable {
    let text: String
    let language: String?
    let maxLines: Int?
    let maxHeight: CGFloat?

    var body: some View {
        Folded(lines: splitLines(text), limit: maxLines) { shown in
            let code = HighlightedCode(text: shown.joined(separator: "\n"), language: language)
                .font(Theme.code)
                .textSelection(.enabled)
                .fixedSize()
                .padding(10)
            if let maxHeight {
                // 横竖用同一个滚动视图：竖向的里面再套横向的，Mac 上横向的那个接下竖向的滑动、不往外传，外面的滚不动
                HeightLimit(limit: maxHeight) {
                    ScrollView([.horizontal, .vertical]) { code }
                        .scrollIndicators(.hidden, axes: .horizontal)
                        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                        .hintsScrollOverflow(.horizontal)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) { code }
                    .hintsScrollOverflow(.horizontal)
            }
        }
    }
}

/// 只摆一个子视图：按给的宽量它不限高时多高，最高 limit，子视图就摆这么高（里面是滚动视图时超出的在里面滚）。
struct HeightLimit: Layout {
    var limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: min(size.height, limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
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
