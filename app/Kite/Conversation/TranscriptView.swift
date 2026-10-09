import SwiftUI

extension EnvironmentValues {
    /// 会话的工作目录，工具参数里的路径按它显示成相对路径。
    @Entry var workingDirectory = ""
}

/// 一串记录排下来，排队中的消息接在最后。主对话和子 agent 做的事都用它。
struct TranscriptView: View {
    let items: [Item]
    var pending: [Message] = []
    /// 点 agent 的话弹出操作栏。主对话里是；子 agent 做的事里不是，它们的序号和主对话的会撞。
    var actionable = false
    /// 主对话给：最后一轮底下的留白（见 TranscriptStack）。发送后滚到最后一轮顶上的标记（TailSpace.marker），
    /// 这条消息正好停在可见区顶上，上一段内容刚好滚出去，回复往下面的空白里填；回复长过一屏就照常跟着最底下。
    /// 排在后面的消息（回合在跑、或者前面还排着别的时发的）不开启新的一轮：它接在那一轮后面，
    /// 顶到最上面的话 agent 接着写的内容就在屏幕外了。
    var tail: TailSpace?
    @Environment(\.selectedRow) private var selection

    var body: some View {
        let rows = rows
        TranscriptStack(spacing: Metrics.rowSpacing, tailIndex: tail == nil ? nil : rows.lastIndex(where: \.startsHumanTurn),
                        tailHeight: tail?.height) {
            ForEach(rows) { row in
                Group {
                    switch row.content {
                    case .item(let item):
                        if actionable, case .text(let text) = item.kind {
                            AgentText(id: row.id, text: text)
                        } else {
                            ItemView(item: item)
                        }
                    case .message(let message, let queued): MessageBubble(message: message, queued: queued)
                    }
                }
                .padding(.top, row.gap)
                // 开着操作栏的那一行垫在最上面：操作栏浮出这一行，压在前后的行上（自己的排版容器里也管用，实测）
                .zIndex(selection.wrappedValue == row.id ? 1 : 0)
            }
            if let tail {
                Color.clear.frame(height: 0).layoutValue(key: StackMarker.self, value: .tail).id(TailSpace.marker)
                TailEnd(tail: tail).layoutValue(key: StackMarker.self, value: .end)
            }
        }
    }

    /// 人发的消息按消息的 id 认，排队中和收到了走同一个分支：从排队中变成收到，还是同一个气泡，底色直接填进来。
    private var rows: [Row] {
        var rows: [Row] = []
        func append(_ id: RowID, _ content: Row.Content, startsTurn: Bool) {
            let humanTurn = startsTurn && content.isMessage
            guard let last = rows.last else {
                rows.append(Row(id: id, content: content, gap: 0, startsHumanTurn: humanTurn))
                return
            }
            // 人发的消息和前后的内容之间多空一样多，连着的几条消息之间不加；它开启的新一轮不再另加，上下才一样。
            // Kite 发来的、后台任务通知开启的新一轮，和上一轮之间多空一点
            let gap = if last.isMessage != content.isMessage { Metrics.messageGap }
                else if startsTurn && !content.isMessage { Metrics.turnGap }
                else { CGFloat(0) }
            rows.append(Row(id: id, content: content, gap: gap, startsHumanTurn: humanTurn))
        }
        for item in items {
            // 隐藏结束的思考，但保留派生项身份和它分隔工具组的位置。
            if case .thinking = item.kind, item.generation != "streaming" { continue }
            if case .text(let text) = item.kind, text.isEmpty { continue }
            if case .human(let message) = item.kind {
                append(.message(message.id), .message(message, queued: false), startsTurn: item.startsTurn)
            } else {
                append(.item(item.id), .item(item), startsTurn: item.startsTurn)
            }
        }
        for message in pending {
            append(.message(message.id), .message(message, queued: true), startsTurn: !message.midTurn)
        }
        return rows
    }
}

/// 对话一行一行往下排，靠左，行间空 spacing，和 VStack 一样。给了 tailHeight 时，最后一轮（从 tailIndex 那一行上面、
/// 上一行的底边算起）至少这么高，不够就在底下留白；标着 .tail 的空视图摆在最后一轮的顶上，发送后滚到它，
/// 标着 .end 的摆在最后一行的底边，用来看底下的空白露没露出来。
/// 留白要在排版里和新消息一次算出来：量出来再补会晚一次排版，发送时滚动那一刻底下还没有留白，滚不到位。
private struct TranscriptStack: Layout {
    let spacing: CGFloat
    let tailIndex: Int?
    let tailHeight: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? rows(subviews).map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let measured = arrange(width: width, subviews: subviews)
        return CGSize(width: width, height: measured.natural + extra(natural: measured.natural, tailTop: measured.tailTop))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = arrange(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (index, subview) in rows(subviews).enumerated() {
            let height = measured.heights[index]
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
        for marker in subviews {
            guard let kind = marker[StackMarker.self] else { continue }
            let at = kind == .tail ? measured.tailTop : measured.natural
            marker.place(at: CGPoint(x: bounds.minX, y: bounds.minY + at), proposal: ProposedViewSize(width: bounds.width, height: 0))
        }
    }

    private func rows(_ subviews: Subviews) -> [LayoutSubview] {
        subviews.filter { $0[StackMarker.self] == nil }
    }

    /// 内部折叠也会改变行高，不能只按宽度和行数复用上次结果。每次排版读取当前高度，子视图测量由 SwiftUI 缓存。
    private func arrange(width: CGFloat, subviews: Subviews) -> (heights: [CGFloat], natural: CGFloat, tailTop: CGFloat) {
        let heights = rows(subviews).map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        var y: CGFloat = 0
        var tailTop: CGFloat = 0
        for (index, height) in heights.enumerated() {
            if index == tailIndex { tailTop = index == 0 ? 0 : y - spacing }
            y += height + spacing
        }
        return (heights, max(y - spacing, 0), tailTop)
    }

    private func extra(natural: CGFloat, tailTop: CGFloat) -> CGFloat {
        guard tailIndex != nil, let tailHeight, tailHeight.isFinite else { return 0 }
        return max(tailTop + tailHeight - natural, 0)
    }
}

/// TranscriptStack 里不是一行、是个标记的空视图：最后一轮的顶，最后一行的底边。
private nonisolated struct StackMarker: LayoutValueKey {
    enum Kind {
        case tail
        case end
    }

    static let defaultValue: Kind? = nil
}

private struct Row: Identifiable {
    enum Content {
        case item(Item)
        case message(Message, queued: Bool)

        var isMessage: Bool {
            if case .message = self { true } else { false }
        }
    }

    let id: RowID
    let content: Content
    /// 和上一行之间在 VStack 的间距之外多空多少。
    let gap: CGFloat
    /// 人发的消息开启新的一轮（不是并进正在跑的这一轮的插话）。
    let startsHumanTurn: Bool

    var isMessage: Bool { content.isMessage }
}

private extension Item {
    var startsTurn: Bool {
        switch kind {
        case .human(let message): !message.midTurn
        case .kite, .notification: true
        default: false
        }
    }
}

/// agent 说的一段话，铺满这一栏。iPhone 上长按、Mac 上右键，在左下方弹出操作栏：复制、翻译、从这里分叉（翻译、分叉还没做）。
/// iPhone 上长按以后接着拖是选字（SelectableMarkdown），Mac 上左键选字。
private struct AgentText: View {
    let id: RowID
    let text: String
    @Environment(\.selectedRow) private var selection
    @Environment(\.toast) private var toast

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .actionBar(id, side: .leading) { actions }
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        SelectableMarkdown(source: text, showActions: { selection.show(id) }, dismissActions: { selection.close() })
        #else
        MarkdownView(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opensActionBar(id)
        #endif
    }

    @ViewBuilder
    private var actions: some View {
        ActionButton("复制", icon: "doc.on.doc") {
            copyToPasteboard(text, toast: toast)
            selection.close()
        }
        // 翻译成另一种语言，还没做
        ActionButton("翻译", icon: "translate") { selection.close() }.disabled(true)
        // 分出一个新会话，从这段话之后接着说；还没做
        ActionButton("从这里分叉", icon: "arrow.triangle.branch") { selection.close() }.disabled(true)
    }
}

private struct ItemView: View {
    let item: Item

    var body: some View {
        switch item.kind {
        case .human:
            // 人发的消息由 TranscriptView 直接排，和排队中的走同一个分支
            EmptyView()
        case .kite(let text):
            VStack(alignment: .leading, spacing: 6) {
                Label("Kite 发给 agent", systemImage: "arrow.triangle.merge").font(Theme.secondary)
                Text(text).font(Theme.body).textSelection(.enabled)
            }
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: Metrics.contentRadius, style: .continuous).strokeBorder(Theme.rule))
        case .notification(let text):
            EventLabel(text: text, icon: "bell")
        case .text(let text):
            MarkdownView(text)
        case .thinking(let text):
            ThinkingRow(text: text)
        case .work(let work):
            WorkRow(work: work)
        case .interrupted:
            EventLabel(text: "已打断", icon: "hand.raised")
        case .compacted(let compaction, let children):
            CompactedDivider(compaction: compaction, children: children)
        case .apiError(let message):
            EventLabel(text: message, icon: "exclamationmark.triangle", tint: Theme.danger)
        }
    }
}

/// 会话里发生的事，不是谁说的话：后台任务结束、打断、出错。
private struct EventLabel: View {
    let text: String
    let icon: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: icon)
            .font(Theme.secondary)
            .foregroundStyle(tint)
            .textSelection(.enabled)
    }
}

/// 压缩的分界：一段对话收成了摘要，点开看摘要；被收起的原文可以展开，Kite 的压缩还能撤销。
private struct CompactedDivider: View {
    let compaction: Compaction
    let children: [Item]
    @Environment(WorkThread.self) private var thread
    @State private var expanded = false
    @State private var original = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Rectangle().fill(Theme.rule).frame(height: 1)
                    Text(expanded ? "收起摘要" : compaction.automatic || compaction.id == nil ? "之前的对话已压缩成摘要" : "这段对话已压缩成摘要").fixedSize()
                    Rectangle().fill(Theme.rule).frame(height: 1)
                }
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pointingPlain)
            if expanded {
                MarkdownView(compaction.summary).font(Theme.secondary).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    if !children.isEmpty {
                        Button(original ? "收起原文" : "显示原文") { withAnimation(.snappy) { original.toggle() } }
                    }
                    if let id = compaction.id {
                        Button("撤销压缩") { thread.revertCompaction(id) }.disabled(!thread.canCompact)
                    }
                }
                .font(Theme.secondary)
                .buttonStyle(.pointingPlain)
                .foregroundStyle(Color.accentColor)
            }
            if expanded && original {
                TranscriptView(items: children)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.rule).frame(width: 1) }
            }
        }
    }
}
