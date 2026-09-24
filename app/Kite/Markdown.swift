import SwiftUI

/// agent 回复的 Markdown。解析用 Foundation 自带的（AttributedString 的 full 语法），这里只按它标出的块逐块排版：
/// SwiftUI 的 Text 只认行内的粗体、斜体、代码和链接，标题、列表、代码块、引用、表格这些块它不排。
/// 正文字号跟着外面：对话里是正文，展开的工具结果里小一号。
/// 在 body 里解析、不在 init 里：视图只存源字符串，字符串没变 SwiftUI 就不重算 body，外面重画不会跟着重新解析。
struct MarkdownView: View {
    let source: String

    init(_ source: String) {
        self.source = source
    }

    var body: some View {
        let blocks = MarkdownBlock.parse(source)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index])
            }
        }
        .textSelection(.enabled)
    }
}

struct MarkdownBlock {
    enum Kind {
        case paragraph
        case heading(Int)
        case code
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

    static func parse(_ source: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let document = try? AttributedString(markdown: source, options: options) else {
            return [MarkdownBlock(kind: .paragraph, text: AttributedString(source))]
        }
        var blocks: [MarkdownBlock] = []
        var lastListItem: Int?
        /// 正在收的表格：它的 identity、表头、各行。
        var table: (id: Int, header: [AttributedString], rows: [Int: [AttributedString]])?

        func flushTable() {
            guard let current = table else { return }
            let rows = current.rows.keys.sorted().map { current.rows[$0]! }
            blocks.append(MarkdownBlock(kind: .table(header: current.header, rows: rows), text: AttributedString()))
            table = nil
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
                continue
            }
            flushTable()

            let lists = intent.components.filter {
                switch $0.kind { case .orderedList, .unorderedList: true; default: false }
            }
            var block = MarkdownBlock(kind: .paragraph, text: text, depth: lists.count)
            switch first.kind {
            case .header(let level): block.kind = .heading(level)
            case .codeBlock:
                block.kind = .code
                block.text = AttributedString(String(text.characters).trimmingCharacters(in: .newlines))
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
            blocks.append(block)
        }
        flushTable()
        return blocks
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        content.padding(.leading, CGFloat(max(block.depth - 1, 0)) * 18)
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .paragraph:
            Text(block.text).fixedSize(horizontal: false, vertical: true)
        case .heading(let level):
            Text(block.text)
                .font(level <= 1 ? Theme.heading1 : level == 2 ? Theme.heading2 : Theme.heading3)
                .padding(.top, 4)
        case .code:
            CodeBlock(text: String(block.text.characters))
        case .quote:
            Text(block.text)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Capsule().fill(Theme.rule).frame(width: 3) }
        case .rule:
            Divider()
        case .listItem(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker ?? "").monospacedDigit().frame(minWidth: 14, alignment: .trailing)
                Text(block.text).fixedSize(horizontal: false, vertical: true)
            }
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)
        }
    }
}

private struct MarkdownTable: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(header.indices, id: \.self) { Text(header[$0]).fontWeight(.semibold) }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(rows[row].indices, id: \.self) { Text(rows[row][$0]) }
                    }
                }
            }
            .padding(12)
        }
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 等宽的一段，比如命令、输出、代码。太长的先只显示开头几行，点了再展开；太宽的横着滚。
struct CodeBlock: View {
    let text: String
    var tint: Color?
    var maxLines = 14

    var body: some View {
        Folded(lines: splitLines(text), limit: maxLines) { shown in
            ScrollView(.horizontal, showsIndicators: false) {
                Text(shown.joined(separator: "\n"))
                    .font(Theme.code)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint?.opacity(0.08) ?? Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 太长的先只显示开头 limit 行，点「显示全部」再展开。只多出几行的不折，省得点一下只多看两行。
struct Folded<Line, Content: View>: View {
    let lines: [Line]
    let limit: Int
    @ViewBuilder let content: ([Line]) -> Content
    @State private var expanded = false

    var body: some View {
        let folded = !expanded && lines.count > limit + 4
        VStack(alignment: .leading, spacing: 0) {
            content(folded ? Array(lines.prefix(limit)) : lines)
            if folded {
                Button("显示全部 \(lines.count) 行") { expanded = true }
                    .buttonStyle(.plain)
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom], 10)
            }
        }
    }
}
