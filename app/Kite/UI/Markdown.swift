import SwiftUI

/// agent 回复的 Markdown。解析用 Foundation 自带的（AttributedString 的 full 语法），这里只按它标出的块逐块排版：
/// SwiftUI 的 Text 只认行内的粗体、斜体、代码和链接，标题、列表、代码块、引用、表格这些块它不排。
/// 正文字号跟着外面：对话里是正文，展开的工具结果里小一号。
/// 源字符串变化时才解析；布局或其他消息更新引起重画时，沿用当前视图缓存。
struct MarkdownView: View {
    let source: String
    @State private var document = MarkdownDocument()

    init(_ source: String) {
        self.source = source
    }

    var body: some View {
        let blocks = document.blocks(for: source)
        VStack(alignment: .leading, spacing: Metrics.markdownBlockGap) {
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

struct MarkdownBlock {
    enum Kind {
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
            case .codeBlock(let language):
                block.kind = .code(language: language)
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
        // 只有尚未组成语法的标记时也保留原文，结束后仍由同一解析器校正。
        if blocks.isEmpty && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [MarkdownBlock(kind: .paragraph, text: AttributedString(source))]
        }
        return blocks
    }
}

/// 一块 Markdown。iPhone 上 agent 的话里，代码块、表格、分隔线也用它排（见 SelectableMarkdown）。
struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        content
            .lineSpacing(Metrics.markdownLineSpacing)
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
                .padding(.top, 4)
        case .code(let language):
            CodeBlock(text: String(block.text.characters), language: language).lineSpacing(0)
        case .quote:
            ReferenceLabel(block.text)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
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

private struct MarkdownTable: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]
    @Environment(\.font) private var font
    @Environment(\.fontResolutionContext) private var fontContext
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some View {
        let base = (font ?? .body).resolve(in: fontContext)
        let serif = Font.system(size: base.pointSize, weight: base.weight, design: .serif)
        let tableFont = base.isItalic ? serif.italic() : serif
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(header.indices, id: \.self) { cell(header[$0], font: tableFont.weight(.semibold)) }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(rows[row].indices, id: \.self) { cell(rows[row][$0], font: tableFont) }
                    }
                }
            }
        }
        .padding(.vertical, 12)
        #if os(iOS)
        .task(id: scenePhase) {
            if scenePhase == .active { TableFont.shared.prepare() }
        }
        #endif
    }

    private func cell(_ text: AttributedString, font: Font) -> some View {
        #if os(iOS)
        let text = TableFont.shared.applying(to: text, font: font, in: fontContext)
        #endif
        // 只设置基础字体，行内代码仍可用自己的等宽字体覆盖。
        return ReferenceLabel(text).font(font)
    }
}

/// 等宽的一段，比如命令、输出、代码。太长的先只显示开头几行，点了再展开；太宽的横着滚。
struct CodeBlock: View {
    let text: String
    var language: String?
    var maxLines: Int? = 14
    var background: Color = Theme.codeBackground
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fontResolutionContext) private var fontContext
    @Environment(\.toast) private var toast
    @Namespace private var cardSpace
    @State private var cardSize: CGSize = .zero
    @State private var copyButtonFrame: CGRect = .zero
    @State private var pressLocation = UnitPoint.center
    @State private var pressSequence = 0

    private var languageLabel: String {
        language?.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "text"
    }

    private var isShell: Bool {
        ["bash", "sh", "shell", "zsh", "ksh", "fish"].contains(languageLabel.lowercased())
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.codeBlockRadius, style: .continuous)
        let iconSize = Theme.body.resolve(in: fontContext).pointSize
        let tiltX = Double((0.5 - pressLocation.y) * 5)
        let tiltY = Double((pressLocation.x - 0.5) * 5)
        let pressAnchor = pressLocation
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.paneButtonGap) {
                Text(languageLabel)
                    .font(.system(.caption, design: .monospaced))
                Spacer(minLength: 12)
                HStack(spacing: 0) {
                    if isShell {
                        Button {} label: {
                            CodeHeaderIcon("CodeTerminal", size: iconSize)
                        }
                        .disabled(true)
                        .help("在终端中执行（尚未接入）")
                        .accessibilityLabel("在终端中执行")
                    }
                    Button(action: copy) {
                        CodeHeaderIcon("CodeCopy", size: iconSize)
                    }
                    .help("复制代码")
                    .accessibilityLabel("复制代码")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(cardSpace)) } action: {
                        copyButtonFrame = $0
                    }
                }
                .buttonStyle(PaneButtonStyle())
            }
            .foregroundStyle(.secondary)
            .padding(.leading, (Metrics.paneButton - iconSize) / 2 + Metrics.codeHeaderInset)
            .padding(.trailing, Metrics.paneToolbarInset)
            .padding(.vertical, Metrics.codeHeaderInset)
            .overlay(alignment: .bottom) { Divider() }
            CodeBlockContent(text: text, language: language, maxLines: maxLines).equatable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: shape)
        .clipShape(shape)
        .buttonStyle(.pointingPlain)
        .coordinateSpace(name: cardSpace)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
        .keyframeAnimator(initialValue: CGFloat.zero, trigger: pressSequence) { content, amount in
            content
                .rotation3DEffect(.degrees(tiltX * amount), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
                .rotation3DEffect(.degrees(tiltY * amount), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
                .scaleEffect(1 - amount * 0.012, anchor: pressAnchor)
        } keyframes: { _ in
            CubicKeyframe(1, duration: 0.1)
            SpringKeyframe(0, duration: 0.35, spring: .smooth)
        }
    }

    private func press(at point: CGPoint) {
        guard !reduceMotion, cardSize.width > 0, cardSize.height > 0 else { return }
        pressLocation = UnitPoint(x: min(1, max(0, point.x / cardSize.width)),
                                  y: min(1, max(0, point.y / cardSize.height)))
        pressSequence += 1
    }

    private func copy() {
        copyToPasteboard(text, toast: toast)
        // 复制和动效共用原生按钮动作，避免另加手势抢占点击。
        press(at: CGPoint(x: copyButtonFrame.midX, y: copyButtonFrame.midY))
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
        }
    }
}

/// 代码块图标跟随正文字号，点击范围由统一按钮样式提供。
private struct CodeHeaderIcon: View {
    let asset: String
    let size: CGFloat

    init(_ asset: String, size: CGFloat) {
        self.asset = asset
        self.size = size
    }

    var body: some View {
        Image(asset)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
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
