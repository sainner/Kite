import SwiftUI

extension EnvironmentValues {
    /// 会话的工作目录，工具参数里的路径按它显示成相对路径。
    @Entry var workingDirectory = ""
}

/// 一串记录排下来，排队中的消息接在最后。iPhone 的主对话和两端子 agent 做的事、压缩前的原文都用它；Mac 的主对话是原生列表（TranscriptListView）。
/// 按人开启的每一轮分组，一组里的行竖着排。一行从出现起就待在同一组里，后面又开了一轮也不换组，展开收起这些状态不会丢。
struct TranscriptView: View {
    let items: [Item]
    var pending: [Message] = []
    /// 点 agent 的话弹出操作栏。主对话里是；子 agent 做的事里不是，它们的序号和主对话的会撞。
    var actionable = false
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
        VStack(alignment: .leading, spacing: 0) {
            ForEach(turns) { turn in
                let last = turn.id == turns.last?.id
                let first = turn.id == turns.first?.id
                let selected = turn.rows.contains { $0.id == selection.wrappedValue }
                group(turn, last: last, first: first)
                    // 操作栏也要压在后面几组上
                    .zIndex(selected ? 1 : 0)
            }
        }
    }

    private func group(_ turn: TranscriptTurn, last: Bool, first: Bool) -> some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            ForEach(turn.rows) { row in
                TranscriptRowView(row: row, actionable: actionable)
                    .padding(.top, row.gap)
                    // 开着操作栏的那一行垫在最上面：操作栏浮出这一行，压在前后的行上（自己的排版容器里也管用，实测）
                    .zIndex(selection.wrappedValue == row.id ? 1 : 0)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if last, let tail { TailEnd(tail: tail) }
        }
        // 组和组之间的行距算在后一组顶上，最后一组的顶就是上一组的底边，最小高度从这里算
        .padding(.top, first ? 0 : Metrics.rowSpacing)
        // 改最小高度不换分支：这一组不再是最后一组时还是同一个视图
        .frame(maxWidth: .infinity, minHeight: last && turn.startsHumanTurn ? tail?.minimum(first: first) : nil,
               alignment: .topLeading)
    }

    private var rows: [TranscriptRow] { TranscriptRow.rows(items: items, pending: pending) }
    private var turns: [TranscriptTurn] { TranscriptTurn.group(rows) }
}


/// 对话里的一行显示成什么。Mac 主对话的原生列表里还没原生化的行也托管它。
struct TranscriptRowView: View {
    let row: TranscriptRow
    /// 点 agent 的话弹出操作栏，见 TranscriptView.actionable。
    let actionable: Bool

    var body: some View {
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
}

/// agent 说的一段话，铺满这一栏。iPhone 上长按、Mac 上右键，在左下方弹出操作栏：复制、翻译、从这里分叉（翻译、分叉还没做）。
/// 两端都用 SelectableMarkdown 排：iPhone 上长按以后接着拖是选字，Mac 上左键选字，右键由盖层接（opensActionBar）。
private struct AgentText: View {
    let id: RowID
    let text: String
    @Environment(\.selectedRow) private var selection

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .actionBar(id, side: .leading) { AgentTextActions(text: text) }
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        SelectableMarkdown(source: text, showActions: { selection.show(id) }, dismissActions: { selection.close() })
        #else
        SelectableMarkdown(source: text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opensActionBar(id)
        #endif
    }
}

/// agent 说的一段话的操作栏：复制、翻译、从这里分叉（翻译、分叉还没做）。Mac 主对话的原生列表也用它。
struct AgentTextActions: View {
    let text: String
    @Environment(\.selectedRow) private var selection
    @Environment(\.toast) private var toast

    var body: some View {
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
            // 子 agent 做的事、压缩前的原文里 agent 说的话：没有操作栏，照样能选字
            SelectableMarkdown(source: text)
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
                SelectableMarkdown(source: compaction.summary, color: .secondaryLabel).font(Theme.secondary).foregroundStyle(.secondary)
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
