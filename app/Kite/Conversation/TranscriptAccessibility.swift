import Foundation

/// 对话里各行给读屏的文案，两端原生列表共用（Mac 的 TranscriptListView，iOS 的原生对话照同一套读）。
/// 正文由文本视图自己读，这里给它前面那句「是什么」、按钮名、展开收起的状态和动作名。
/// 远处还没建视图的行由列表给代理元素，按 summary 读整行。
enum TranscriptSpeech {
    /// 打开这一行的操作栏：读屏的自定义动作名。Mac 上「显示菜单」（VO-Shift-M，等同右键）也打开它。
    static let actions = "操作"

    /// 人发的消息：正文前面读的说明。
    static func message(queued: Bool) -> String { queued ? "排队中的消息" : "我发的消息" }
    /// 折起来的长消息下面的按钮，和看到的字一样。
    static func fold(expanded: Bool) -> String { expanded ? "收起" : "展开全文" }

    static let kite = "Kite 发给 agent"

    /// 压缩分界：不管展开没有都读这一句，展开收起由状态读出。
    static func compaction(_ compaction: Compaction) -> String {
        compaction.automatic || compaction.id == nil ? "之前的对话已压缩成摘要" : "这段对话已压缩成摘要"
    }
    static let compactionSummary = "压缩摘要"
    static func original(shown: Bool) -> String { shown ? "收起原文" : "显示原文" }
    static let revertCompaction = "撤销压缩"
    /// 被收起的原文那一栏。
    static let originalTranscript = "压缩前的原文"

    /// 展开收起的状态：iOS 的 UIKit 没有展开状态的属性，作为值读（Mac 用 isAccessibilityExpanded）。
    static func expanded(_ expanded: Bool) -> String { expanded ? "已展开" : "已收起" }

    /// 工具组汇总行：汇总行说的（见 Work.headline），连同没跑完的步数。
    static func work(_ work: Work) -> String {
        let unfinished = work.count(.unfinished)
        var parts = [work.headline]
        if unfinished > 0 { parts.append("\(unfinished) 步没跑完") }
        return parts.joined(separator: "，")
    }

    /// 工具组里的一步：名字连同摘要，值是阶段（跑完了读「成功」）；提示是点了会怎样（callHint）。
    static func call(_ call: Call, summary: String) -> (label: String, value: String) {
        (call.use.displayName + " " + summary, call.stageLabel.isEmpty ? "成功" : call.stageLabel)
    }
    static func callHint(expanded: Bool) -> String { expanded ? "收起参数与结果" : "展开参数与结果" }
    static func patchLines(_ value: String) -> String { "补丁行数 \(value)" }
    static func duration(_ value: String) -> String { "运行时间 \(value)" }

    /// 思考只占一行：ChatGPT 的推理摘要每段以 `**小标题**` 开头，后面几段接着往下写，取最后一段的小标题（还在生成的没有收尾的星号）；
    /// 没有小标题的换行当空格。加粗的星号都不显示。
    static func thinking(_ text: String) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let heading = lines.last { line in
            guard line.hasPrefix("**") else { return false }
            let rest = line.dropFirst(2)
            return !(rest.hasSuffix("**") ? rest.dropLast(2) : rest).contains("**")
        }
        let shown = (heading ?? lines.joined(separator: " ")).replacingOccurrences(of: "**", with: "")
        return shown.isEmpty ? "思考中" : shown
    }

    /// 消息上面的附件。
    static func imageAttachment(_ name: String) -> String { "图片，\(name)" }
    static func fileAttachment(_ name: String) -> String { "文件，\(name)" }

    /// 嵌在正文里的卡片。
    static func code(language: String) -> String { "代码，\(language)" }
    static let table = "表格"

    /// 整行读成一句：远处还没建视图的行由列表的代理元素读它。
    static func summary(_ row: TranscriptRow) -> String {
        switch row.content {
        case .message(let message, let queued):
            return self.message(queued: queued) + "，" + message.typed
        case .item(let item):
            switch item.kind {
            case .human(let message): return self.message(queued: false) + "，" + message.typed
            case .text(let text): return text
            case .kite(let text): return kite + "，" + text
            case .thinking(let text): return thinking(text)
            case .work(let work): return self.work(work)
            case .compacted(let compaction, _): return self.compaction(compaction)
            }
        }
    }
}
