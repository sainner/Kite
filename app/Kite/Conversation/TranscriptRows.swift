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
            // Kite 发来的、后台任务通知开启的新一轮，和上一轮之间多空一点
            let gap = if last.isMessage != content.isMessage { Metrics.messageGap }
                else if startsTurn && !content.isMessage { Metrics.turnGap }
                else { CGFloat(0) }
            rows.append(TranscriptRow(id: id, content: content, gap: gap, startsHumanTurn: humanTurn))
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

    /// 读屏读的这一行：原生列表里屏外还没建视图的行由代理元素读它（见 PhoneTranscriptView.accessibilityRows）。
    var accessibilitySummary: String {
        switch content {
        case .message(let message, let queued): queued ? "排队中：\(message.typed)" : message.typed
        case .item(let item):
            switch item.kind {
            case .human(let message): message.typed
            case .kite(let text): "Kite 发给 agent：\(text)"
            case .notification(let text), .text(let text), .apiError(let text): text
            case .thinking(let text): text.isEmpty ? "思考中" : text
            case .work(let work): work.accessibilitySummary
            case .interrupted: "已打断"
            case .compacted(let compaction, _): compaction.dividerTitle
            }
        }
    }

    /// 排出来多高取决于的内容，只取便宜的：种类、字数、几步工具和各步状态。字数不变的改字不算（记录只追加，不会这样改）。
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

/// 一轮：开启它的那一行和后面跟着的行。id 是第一行的 id，后面接着来的行不改变它。
struct TranscriptTurn: Identifiable {
    var rows: [TranscriptRow]

    var id: RowID { rows[0].id }
    var startsHumanTurn: Bool { rows[0].startsHumanTurn }

    /// 从每一条开启新一轮的人发的消息起另开一组。
    static func group(_ rows: [TranscriptRow]) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        for row in rows {
            if turns.isEmpty || row.startsHumanTurn {
                turns.append(TranscriptTurn(rows: [row]))
            } else {
                turns[turns.count - 1].rows.append(row)
            }
        }
        return turns
    }
}

private extension Item.Kind {
    func shape(into hasher: inout Hasher) {
        switch self {
        case .human(let message): message.shape(into: &hasher)
        case .kite(let text): hasher.combine(1); hasher.combine(text.utf8.count)
        case .notification(let text): hasher.combine(2); hasher.combine(text.utf8.count)
        case .text(let text): hasher.combine(3); hasher.combine(text.utf8.count)
        case .thinking(let text): hasher.combine(4); hasher.combine(text.utf8.count)
        case .work(let work):
            hasher.combine(5)
            for call in work.calls {
                hasher.combine(call.state)
                hasher.combine(call.result != nil)
                hasher.combine(call.children.count)
            }
        case .interrupted: hasher.combine(6)
        case .compacted(let compaction, let children):
            hasher.combine(7)
            hasher.combine(compaction.summary.utf8.count)
            hasher.combine(children.count)
        case .apiError(let text): hasher.combine(8); hasher.combine(text.utf8.count)
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
        case .kite, .notification: true
        default: false
        }
    }
}
