import CoreGraphics
import Foundation

/// 对话里的一行：一条人发的消息，或者记录派生出来的一项。主对话和子 agent 做的事都这样排。
/// 人发的消息按消息的 id 认，排队中和收到了走同一个分支：从排队中变成收到，还是同一个气泡，底色直接填进来。
struct TranscriptRow: Identifiable {
    enum Content {
        case item(Item)
        case message(Message, queued: Bool)

        var isMessage: Bool {
            if case .message = self { true } else { false }
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
    static func rows(items: [Item], pending: [Message]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        func append(_ id: RowID, _ content: Content, startsTurn: Bool) {
            let humanTurn = startsTurn && content.isMessage
            guard let last = rows.last else {
                rows.append(TranscriptRow(id: id, content: content, gap: 0, startsHumanTurn: humanTurn))
                return
            }
            // 人发的消息和前后的内容之间多空一样多，连着的几条消息之间不加；它开启的新一轮不再另加，上下才一样。
            // Kite 发来的消息开启的新一轮，和上一轮之间多空一点
            let gap = if last.isMessage != content.isMessage { Metrics.messageGap }
                else if startsTurn && !content.isMessage { Metrics.turnGap }
                else { CGFloat(0) }
            rows.append(TranscriptRow(id: id, content: content, gap: gap, startsHumanTurn: humanTurn))
        }
        for item in items {
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

    /// 排出来多高、显示什么取决于的内容，只取便宜的：种类、字数、几步工具和各步状态，展开后看得到的参数原文、跑着的输出和子 agent 做的事。
    /// 字数不变的改字不算（记录只追加，不会这样改）。
    func shape(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(gap)
        switch content {
        case .item(let item): item.kind.shape(into: &hasher)
        case .message(let message, let queued):
            hasher.combine(queued)
            message.shape(into: &hasher)
        }
    }
}

private extension Item.Kind {
    func shape(into hasher: inout Hasher) {
        switch self {
        case .human(let message): message.shape(into: &hasher)
        case .kite(let text, let sender): hasher.combine(1); hasher.combine(text.utf8.count); hasher.combine(sender)
        case .text(let text): hasher.combine(3); hasher.combine(text.utf8.count)
        case .thinking(let text): hasher.combine(4); hasher.combine(text.utf8.count)
        case .work(let work):
            hasher.combine(5)
            hasher.combine(work.thinking?.utf8.count)
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

private extension Item {
    var startsTurn: Bool {
        switch kind {
        case .human(let message): !message.midTurn
        case .kite: true
        default: false
        }
    }
}
