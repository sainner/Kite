import SwiftUI

extension EnvironmentValues {
    /// 会话的工作目录，工具参数里的路径按它显示成相对路径。
    @Entry var workingDirectory = ""
}

/// 一串记录排下来，排队中的消息接在最后。主对话和子 agent 做的事都用它。
/// 按人开启的每一轮分组，一组里的行竖着排。主对话按需排版，只排可见区附近的几组：长会话改窗口宽度时只重排看得见的，
/// 没排到的组等滚到附近再按当时的宽度排。一行从出现起就待在同一组里，后面又开了一轮也不换组，展开收起这些状态不会丢。
struct TranscriptView: View {
    let items: [Item]
    var pending: [Message] = []
    /// 点 agent 的话弹出操作栏。主对话里是；子 agent 做的事里不是，它们的序号和主对话的会撞。
    var actionable = false
    /// 主对话按需排版。嵌在一行里的（压缩前的原文、子 agent 做的事）跟着那一行整个排。
    var lazy = false
    /// 主对话给：最后一轮底下的留白。最后一轮就是最后一组，它至少 tail.height 高（从上一组的底边算起），不够就在底下留白；
    /// 留白是这一组的最小高度，和新消息同一次排版算出来，量出来再补会晚一次排版，发送时滚动那一刻底下还没有留白，滚不到位。
    /// 发送后滑到最底下（见 TranscriptScroll.send），这条消息停在可见区顶上，上一段内容滚出去，回复往下面的空白里填；
    /// 回复长过一屏就照常跟着最底下。
    /// 排在后面的消息（回合在跑、或者前面还排着别的时发的）不开启新的一轮：它接在那一轮后面，
    /// 顶到最上面的话 agent 接着写的内容就在屏幕外了。最后一行的底边放一个 TailEnd，用来看底下的空白露没露出来。
    var tail: TailSpace?
    @Environment(\.selectedRow) private var selection

    var body: some View {
        let turns = turns
        if lazy {
            LazyVStack(alignment: .leading, spacing: 0) { content(turns) }
        } else {
            VStack(alignment: .leading, spacing: 0) { content(turns) }
        }
    }

    private func content(_ turns: [Turn]) -> some View {
        ForEach(turns) { turn in
            let last = turn.id == turns.last?.id
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                ForEach(turn.rows) { row in
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
            }
            .overlay(alignment: .bottomLeading) {
                if last, let tail { TailEnd(tail: tail) }
            }
            // 组和组之间的行距算在后一组顶上，最后一组的顶就是上一组的底边，最小高度从这里算
            .padding(.top, turn.id == turns.first?.id ? 0 : Metrics.rowSpacing)
            // 改最小高度不换分支：这一组不再是最后一组时还是同一个视图
            .frame(maxWidth: .infinity, minHeight: last && turn.startsHumanTurn ? tail?.minimum : nil, alignment: .topLeading)
            // 操作栏也要压在后面几组上
            .zIndex(turn.rows.contains { $0.id == selection.wrappedValue } ? 1 : 0)
        }
    }

    /// 从每一条开启新一轮的人发的消息起另开一组。
    private var turns: [Turn] {
        var turns: [Turn] = []
        for row in rows {
            if turns.isEmpty || row.startsHumanTurn {
                turns.append(Turn(rows: [row]))
            } else {
                turns[turns.count - 1].rows.append(row)
            }
        }
        return turns
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

/// 一轮：开启它的那一行和后面跟着的行。id 是第一行的 id，后面接着来的行不改变它。
private struct Turn: Identifiable {
    var rows: [Row]

    var id: RowID { rows[0].id }
    var startsHumanTurn: Bool { rows[0].startsHumanTurn }
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
