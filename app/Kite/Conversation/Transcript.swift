import Foundation

/// 会话记录在 App 里的样子，由统一 Kite 协议转换；App 不解析 runtime 原生记录。
/// 子调用通过 parent 关联；消息投递状态单独放在 pending，纳入请求后才进入记录。
struct Transcript {
    /// 会话的工作目录，工具参数里的绝对路径按它显示成相对路径。
    var root: String
    var records: [Record] { didSet { if !replacingRecord { items = derive() } } }
    /// 有回合在进行（kited 的 busy）。没有结果的工具调用这时算正在跑，否则算没跑完。
    var running: Bool { didSet { items = derive() } }
    /// 发出去了、agent 还没收到的消息，按发出的顺序。收到的那一刻才变成一条记录，撤回的永远不进记录。
    /// 包含服务已接收但尚未纳入模型请求的输入（人发的和代理来信），以及客户端还没收到投递确认的消息。
    var pending: [Queued]
    /// 界面上的样子。记录或 running 变了才重新派生，视图重画时直接拿。
    private(set) var items: [Item] = []
    private var replacingRecord = false
    private var locations: [Int: (item: Int, call: Int?)] = [:]

    init(root: String, records: [Record] = [], running: Bool = false, pending: [Queued] = []) {
        self.root = root
        self.records = records
        self.running = running
        self.pending = pending
        items = derive()
    }
}

struct Record {
    /// 子 agent 的记录：发起它的那次 Agent 调用的 id。主对话里为 nil。
    var parent: String?
    var block: Block
    var generation: String?
    /// 被这次压缩收起：界面上收在它的摘要下面，原文可以展开。
    var folded: String? = nil
}

/// 一次上下文压缩。id 为 nil 的来自 Claude 原生压缩，没有范围，只在原处显示分界。
struct Compaction {
    let id: String?
    let summary: String
    let automatic: Bool
}

enum Block {
    /// 人发的消息。
    case human(Message)
    /// 别的代理发来的消息。
    case agent(Message, sender: Sender)
    /// Kite 自动发给 agent 的。
    case kite(Notice)
    case text(String)
    case thinking(String)
    case toolUse(ToolUse)
    case toolResult(ToolResult)
    /// 一段对话压缩成了这份摘要。
    case compacted(Compaction)
}

/// 代理来信的发信方：名称是发信时的标题，instance 是它的实例 ID（Line 是 Line 的），画头像用。
struct Sender: Hashable {
    let name: String
    let instance: String
}

/// 排着队的一条：人发的消息，或别的代理发来的（sender 是发信方）。
struct Queued: Identifiable {
    var message: Message
    var sender: Sender? = nil
    var id: String { message.id }
}

/// Kite 自动发给 agent 的一条（子代理回报、monitor 事件、合并冲突、转交的用户回应等）。正文是写给模型的，界面上一律画成 Kite 的气泡，
/// 上面一行写种类（见 heading），默认收着、点开才看正文。
struct Notice {
    enum Kind: String {
        case report = "agent.report", workspace = "agent.workspace", monitor = "monitor.events", terminal = "terminal.exit", line = "line.monitor"
        case conflict, moved, resumed, question, secret
    }

    let text: String
    /// 没有的（Claude 原生行、工作机没标的）按正文第一行显示。
    var kind: Kind?
    var title: String
    /// 说的是哪一个：子代理、子工作区、monitor、后台命令的名称。
    var subject: String?
    /// 说的是哪个实例：子代理回报的子代理、子工作区结果里建的代理、替用户回答提问的 Line。
    var instance: String?
    /// Kite 转交的用户回应（用户自己回答提问、回应密钥请求的结果）：是用户自己做的事，图标画用户的头像（见 mark）。
    var response = false

    init(text: String, kind: Kind? = nil, title: String? = nil, subject: String? = nil, instance: String? = nil, response: Bool = false) {
        self.text = text
        self.kind = kind
        self.title = title ?? text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        self.subject = subject
        self.instance = instance
        self.response = response
    }
}

/// 人发的一条消息。id 由客户端给出，排队、投递确认和重连历史沿用它。代理来信也用它，id 是那条输入的 id。
struct Message: Identifiable {
    let id: String
    /// 原文。斜杠命令时是命令后面的参数。
    var text: String
    /// 斜杠命令或技能，比如 /simplify。原生记录里是正文里的 <command-name> 标签，翻译时拆出来。
    var command: String?
    var attachments: [Attachment] = []
    /// 并进了正在跑的回合：agent 做完手上这一步、下一次调用模型之前收到，没有自己的检查点。
    /// 排队中的消息上是预计：发的时候回合在跑、或者前面还排着别的，收到时就并进那一轮（见 WorkThread.send）。
    var midTurn = false

    init(id: String = UUID().uuidString, text: String, command: String? = nil, attachments: [Attachment] = [], midTurn: Bool = false) {
        self.id = id
        self.text = text
        self.command = command
        self.attachments = attachments
        self.midTurn = midTurn
    }

    /// 输入框里打的样子：斜杠命令开头的，命令名拆出来。
    init(typed: String) {
        let parts = typed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        if typed.hasPrefix("/"), let name = parts.first, name.count > 1 {
            self.init(text: parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : "", command: String(name))
        } else {
            self.init(text: typed)
        }
    }

    /// 工作机记录里的人发消息：点选了 skill 的，正文是输入框里打的原样、开头是「/名字」，命令名拆出来显示；id 沿用记录的。
    init(id: String, text: String, skill: String?, attachments: [Attachment] = [], midTurn: Bool = false) {
        if let command = skill.map({ "/" + $0 }), text.hasPrefix(command) {
            self.init(id: id, text: text.dropFirst(command.count).trimmingCharacters(in: .whitespacesAndNewlines), command: command,
                      attachments: attachments, midTurn: midTurn)
        } else {
            self.init(id: id, text: text, attachments: attachments, midTurn: midTurn)
        }
    }

    /// 放回输入框、复制时的原文：斜杠命令连同命令名。
    var typed: String {
        guard let command else { return text }
        return text.isEmpty ? command : command + " " + text
    }

    /// 只带附件、没写字：气泡上只有附件那一行，不画空气泡。
    var attachmentsOnly: Bool { text.isEmpty && command == nil && !attachments.isEmpty }
}

/// 消息带的附件：工作机上存好的那一份的描述（kited 的 AttachmentRef）。内容按 ID 从工作区的附件接口取，同一个 ID 的内容不会变。
struct Attachment: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let mediaType: String
    let size: Int
    /// 原图的尺寸，只有工作机解得开的图片才有。
    var width: Int? = nil
    var height: Int? = nil

    var isImage: Bool { width != nil && height != nil }

    var icon: String { Self.icon(forName: name) }

    /// 文件卡片上的图标，按扩展名。
    static func icon(forName name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "csv", "xlsx", "xls", "numbers": "tablecells"
        case "zip": "doc.zipper"
        default: "doc"
        }
    }
}

struct ToolUse {
    let id: String
    let name: String
    var input: JSON
    /// 同一次模型回复发起的调用属于同一批。没有批次信息时不猜测分组。
    var batch: String?
    var arguments: String?
    var stage: String?
    var output = ""
    var outputTruncated = false
    var startedAt: Double?
    var finishedAt: Double?
}

struct ToolDiffReference: Codable {
    let id: String
    let paths: [String]
}

struct ToolResult {
    /// 对应的 ToolUse 的 id。
    let call: String
    let content: [ResultPart]
    let isError: Bool
    /// 人打断回合时它还在跑。原生记录里也是一条出错的结果，翻译时标出来，界面上不算出错。
    var interrupted = false
    var unknown = false
    var diff: ToolDiffReference?

    var text: String {
        content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
    }
}

enum ResultPart {
    case text(String)
    /// 图片，比如 Read 读的截图。记录里是图片数据，假数据只有尺寸。
    case image(width: Int, height: Int)
}

/// 工具参数：模型给的 JSON 原样保留，显示时按工具取需要的字段。
nonisolated enum JSON: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSON])
    case object([String: JSON])

    subscript(key: String) -> JSON? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var bool: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    /// 给人看的样子：字符串原样，其余按 JSON 写。
    var display: String {
        switch self {
        case .string(let value): value
        case .number(let value): value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        case .null: "null"
        case .array(let values): "[" + values.map(\.quoted).joined(separator: ", ") + "]"
        case .object(let object): "{" + object.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.quoted)" }.joined(separator: ", ") + "}"
        }
    }

    private var quoted: String {
        if case .string(let value) = self { "\"\(value)\"" } else { display }
    }
}

extension JSON: ExpressibleByStringInterpolation, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements) { _, last in last })
    }
}

// MARK: - 界面上的样子

/// 界面上的一项。连续的工具调用折成一项 Work，工具结果并到它的调用上。思考只在生成时出现：
/// 接在工具组后面的由这组的汇总行暂时说它，否则单独一行。记录只追加，所以序号就是稳定的 id。
struct Item: Identifiable {
    let id: Int
    var kind: Kind
    var generation: String?

    enum Kind {
        case human(Message)
        case agent(Message, sender: Sender)
        case kite(Notice)
        case text(String)
        case thinking(String)
        case work(Work)
        /// 压缩的摘要；children 是被收起的原文。
        case compacted(Compaction, children: [Item])
    }
}

/// 连续的工具调用。正文、消息等会分开前后的工具组；结束的思考和空正文不出现，也不分开。
struct Work {
    var calls: [Call]
    /// 接在这组后面正在生成的思考，汇总行先说它；又有调用并进来时清掉。
    var thinking: String? = nil
    /// 回合在跑、这组是主对话的最后一项：agent 还在这组里做事，汇总行一直扫掠，不看各步的状态。
    var active = false
}

struct Call {
    var use: ToolUse
    var result: ToolResult?
    var state: State
    /// Agent 调用里子 agent 做的事。
    var children: [Item]

    enum State {
        case generating, queued, running, done, failed, interrupted, unknown
        /// 没有结果，也没有回合在跑：进程在工具跑到一半时没了。
        case unfinished
    }
}

extension Transcript {
    private mutating func derive() -> [Item] {
        locations = [:]
        let byParent = Dictionary(grouping: Array(records.enumerated()), by: { $0.element.parent })
        var compactions: [String: Compaction] = [:]
        for record in records {
            if case .compacted(let compaction) = record.block, let id = compaction.id { compactions[id] = compaction }
        }
        var items = derive(byParent[nil] ?? [], parent: nil, byParent, compactions: compactions)
        if running, let last = items.indices.last, case .work(var work) = items[last].kind {
            work.active = true
            items[last].kind = .work(work)
        }
        return items
    }

    private mutating func derive(under parent: String, _ byParent: [String?: [(offset: Int, element: Record)]]) -> [Item] {
        derive(byParent[parent] ?? [], parent: parent, byParent)
    }

    /// 按顺序把记录排成界面上的项。主对话里被同一次压缩收起的记录连成一段，换成一项摘要摆在这段开头，
    /// 压缩记录本身不再单独出现；收起的原文作为这一项的 children，不登记流式刷新位置。
    private mutating func derive(_ entries: [(offset: Int, element: Record)], parent: String?,
                                 _ byParent: [String?: [(offset: Int, element: Record)]],
                                 compactions: [String: Compaction] = [:], top: Bool = true) -> [Item] {
        var list: [Item] = []
        /// 调用的 id → 在第几项的第几步，结果来了按它找回去。
        var positions: [String: (item: Int, step: Int)] = [:]
        let folds = Set(entries.compactMap { entry in entry.element.folded.flatMap { compactions[$0] == nil ? nil : $0 } })

        func append(_ kind: Item.Kind) {
            list.append(Item(id: list.count, kind: kind))
        }

        /// 接到上一项 Work 后面，上一项不是 Work 就另起一项。
        func add(_ call: Call) -> (item: Int, step: Int) {
            guard case .work(var work) = list.last?.kind else {
                append(.work(Work(calls: [call])))
                return (list.count - 1, 0)
            }
            work.calls.append(call)
            work.thinking = nil
            list[list.count - 1].kind = .work(work)
            return (list.count - 1, work.calls.count - 1)
        }

        var index = 0
        while index < entries.count {
            let (recordIndex, record) = entries[index]
            index += 1
            if let fold = record.folded, let compaction = compactions[fold] {
                var end = index
                while end < entries.count, entries[end].element.folded == fold { end += 1 }
                let children = derive(Array(entries[(index - 1)..<end]), parent: parent, byParent, top: false)
                append(.compacted(compaction, children: children))
                index = end
                continue
            }
            let before = list.count
            switch record.block {
            case .human(let message): append(.human(message))
            case .agent(let message, let sender): append(.agent(message, sender: sender))
            case .kite(let notice): append(.kite(notice))
            case .text(let text):
                // 开了头没写出字的草稿
                if text.isEmpty { continue }
                append(.text(text))
            case .compacted(let compaction):
                if let id = compaction.id, folds.contains(id) { continue }
                append(.compacted(compaction, children: []))
            case .thinking(let text):
                // 结束的思考不显示，完整摘要仍在记录里
                guard record.generation == "streaming" else { continue }
                if case .work(var work) = list.last?.kind {
                    work.thinking = text
                    list[list.count - 1].kind = .work(work)
                    if parent == nil && top { locations[recordIndex] = (list.count - 1, nil) }
                } else {
                    append(.thinking(text))
                }
            case .toolUse(let use):
                let call = Call(use: use, state: Self.callState(use, result: nil, running: running), children: derive(under: use.id, byParent))
                let at = add(call)
                positions[use.id] = at
                if parent == nil && top { locations[recordIndex] = (at.item, at.step) }
            case .toolResult(let result):
                guard let at = positions[result.call], case .work(var work) = list[at.item].kind else { continue }
                var call = work.calls[at.step]
                call.result = result
                call.state = Self.callState(call.use, result: result, running: running)
                work.calls[at.step] = call
                list[at.item].kind = .work(work)
            }
            if list.count > before {
                list[list.count - 1].generation = record.generation
                if parent == nil, top, locations[recordIndex] == nil { locations[recordIndex] = (list.count - 1, nil) }
            }
        }
        return list
    }

    /// 同种记录只刷新对应行；归属、种类或工具分组变化、思考结束时重新派生。
    mutating func replaceRecord(at index: Int, with record: Record) {
        guard records.indices.contains(index) else { return }
        let previous = records[index]
        replacingRecord = true
        records[index] = record
        replacingRecord = false
        guard record.parent == nil, previous.parent == nil, let at = locations[index] else { items = derive(); return }
        switch (previous.block, record.block) {
        case (.text, .text(let text)) where !text.isEmpty: items[at.item].kind = .text(text)
        case (.thinking, .thinking(let text)) where record.generation == "streaming":
            switch items[at.item].kind {
            case .thinking: items[at.item].kind = .thinking(text)
            case .work(var work) where work.thinking != nil:
                // 说的是工具组，组的生成状态不跟着思考
                work.thinking = text
                items[at.item].kind = .work(work)
                return
            default: items = derive(); return
            }
        case (.toolUse(let old), .toolUse(let use)) where old.id == use.id && old.batch == use.batch:
            guard let step = at.call, case .work(var work) = items[at.item].kind else { items = derive(); return }
            work.calls[step].use = use
            work.calls[step].state = Self.callState(use, result: work.calls[step].result, running: running)
            items[at.item].kind = .work(work)
        default: items = derive(); return
        }
        items[at.item].generation = record.generation
    }

    private static func callState(_ use: ToolUse, result: ToolResult?, running: Bool) -> Call.State {
        if let result { return result.unknown ? .unknown : result.interrupted ? .interrupted : result.isError ? .failed : .done }
        switch use.stage {
        case "generating": return .generating
        case "queued": return .queued
        case "running", "finished": return .running
        case "not_executed": return .interrupted
        case "unfinished": return .unfinished
        default: return running ? .running : .unfinished
        }
    }
}
