import CoreGraphics
import Foundation

/// 对话里的一行：一条人发的消息或代理来信，或者记录派生出来的一项。主对话和子 agent 做的事都这样排。
/// 消息和来信按 id 认，排队中和收到了走同一个分支：从排队中变成收到，还是同一个气泡，底色直接填进来。
struct TranscriptRow: Identifiable {
    enum Content {
        case item(Item)
        /// sender 是代理来信的发信方，人发的为 nil。
        case message(Message, queued: Bool, sender: Sender? = nil)

        /// 人发的消息。代理来信虽然也按消息认，间距和轮次同工具行。
        var isMessage: Bool {
            if case .message(_, _, .none) = self { true } else { false }
        }
    }

    let id: RowID
    let content: Content
    /// 和上一行之间在行距之外多空多少。
    let gap: CGFloat
    /// 人发的消息开启新的一轮（不是并进正在跑的这一轮的插话）。
    let startsHumanTurn: Bool

    var isMessage: Bool { content.isMessage }

    /// 一串记录排成的行，排队中的消息接在最后。
    static func rows(items: [Item], pending: [Queued]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        func append(_ id: RowID, _ content: Content, startsTurn: Bool = false) {
            let humanTurn = startsTurn && content.isMessage
            guard let last = rows.last else {
                rows.append(TranscriptRow(id: id, content: content, gap: 0, startsHumanTurn: humanTurn))
                return
            }
            // 人发的消息和前后的内容之间多空一样多，连着的几条之间不加；代理来信、Kite 的通知虽然也画成气泡，间距同工具行
            let gap = last.content.isMessage != content.isMessage ? Metrics.messageGap : 0
            rows.append(TranscriptRow(id: id, content: content, gap: gap, startsHumanTurn: humanTurn))
        }
        for item in items {
            switch item.kind {
            case .human(let message): append(.message(message.id), .message(message, queued: false), startsTurn: !message.midTurn)
            case .agent(let letter, let sender): append(.message(letter.id), .message(letter, queued: false, sender: sender))
            default: append(.item(item.id), .item(item))
            }
        }
        for queued in pending {
            append(.message(queued.id), .message(queued.message, queued: true, sender: queued.sender), startsTurn: !queued.message.midTurn)
        }
        return rows
    }

    /// 排出来多高、显示什么取决于的内容，只取便宜的：种类、字数、几步工具和各步状态，展开后看得到的参数原文、跑着的输出和子 agent 做的事。
    /// 字数不变的改字不算（记录只追加，不会这样改）。
    func shape(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(gap)
        switch content {
        case .item(let item): item.kind.shape(into: &hasher)
        case .message(let message, let queued, let sender):
            hasher.combine(queued)
            hasher.combine(sender)
            message.shape(into: &hasher)
        }
    }
}

private extension Item.Kind {
    func shape(into hasher: inout Hasher) {
        switch self {
        case .human(let message): message.shape(into: &hasher)
        case .agent(let message, let sender): hasher.combine(2); message.shape(into: &hasher); hasher.combine(sender)
        case .kite(let notice):
            hasher.combine(1)
            hasher.combine(notice.text.utf8.count)
            hasher.combine(notice.title)
            hasher.combine(notice.response)
        case .text(let text): hasher.combine(3); hasher.combine(text.utf8.count)
        case .thinking(let text): hasher.combine(4); hasher.combine(text.utf8.count)
        case .work(let work):
            hasher.combine(5)
            hasher.combine(work.thinking?.utf8.count)
            hasher.combine(work.active)
            hasher.combine(work.compacting)
            for call in work.calls {
                hasher.combine(call.state)
                hasher.combine(call.result != nil)
                hasher.combine(call.use.arguments?.utf8.count)
                hasher.combine(call.use.output.utf8.count)
                hasher.combine(call.use.outputTruncated)
                hasher.combine(call.children.count)
                for child in call.children {
                    hasher.combine(child.id)
                    hasher.combine(child.generation)
                    child.kind.shape(into: &hasher)
                }
            }
        case .compacted(let compaction, let children):
            hasher.combine(7)
            hasher.combine(compaction.summary.utf8.count)
            hasher.combine(children.count)
        case .compacting: hasher.combine(8)
        }
    }
}

private extension Message {
    func shape(into hasher: inout Hasher) {
        hasher.combine(0)
        hasher.combine(text.utf8.count)
        hasher.combine(command)
        hasher.combine(attachments.count)
    }
}
