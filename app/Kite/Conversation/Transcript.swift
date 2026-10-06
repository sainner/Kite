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
    /// 包含服务已接收但尚未纳入模型请求的输入，以及客户端还没收到投递确认的消息。
    var pending: [Message]
    /// 界面上的样子。记录或 running 变了才重新派生，视图重画时直接拿。
    private(set) var items: [Item] = []
    private var replacingRecord = false
    private var locations: [Int: (item: Int, call: Int?)] = [:]

    init(root: String, records: [Record] = [], running: Bool = false, pending: [Message] = []) {
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
}

enum Block {
    /// 人发的消息。
    case human(Message)
    /// Kite 发给 agent 的消息，比如合并冲突的说明。
    case kite(String)
    /// 后台任务结束的通知，它开启新的一轮。
    case notification(String)
    case text(String)
    case thinking(String)
    case toolUse(ToolUse)
    case toolResult(ToolResult)
    /// 人打断了回合。
    case interrupted
    /// 之前的对话压缩成了这段摘要。
    case compacted(String)
    /// 调用模型出错。
    case apiError(String)
}

/// 人发的一条消息。id 由客户端给出，排队、投递确认和重连历史沿用它。
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

    /// 放回输入框、复制时的原文：斜杠命令连同命令名。
    var typed: String {
        guard let command else { return text }
        return text.isEmpty ? command : command + " " + text
    }
}

/// 消息带的附件。
enum Attachment {
    /// 图片。记录里是图片数据，假数据只有名字和尺寸。
    case image(name: String, width: Int, height: Int)
    /// 其他文件，比如 PDF、表格。
    case file(name: String)
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

/// 界面上的一项。思考独立保留，连续的工具调用折成一项 Work，工具结果并到它的调用上。
/// 记录只追加，所以序号就是稳定的 id。
struct Item: Identifiable {
    let id: Int
    var kind: Kind
    var generation: String?

    enum Kind {
        case human(Message)
        case kite(String)
        case notification(String)
        case text(String)
        case thinking(String)
        case work(Work)
        case interrupted
        case compacted(String)
        case apiError(String)
    }
}

/// 连续的工具调用；思考与正文都会分开前后的工具组。
struct Work {
    var calls: [Call]
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
        return derive(under: nil, byParent)
    }

    private mutating func derive(under parent: String?, _ byParent: [String?: [(offset: Int, element: Record)]]) -> [Item] {
        var list: [Item] = []
        /// 调用的 id → 在第几项的第几步，结果来了按它找回去。
        var positions: [String: (item: Int, step: Int)] = [:]

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
            list[list.count - 1].kind = .work(work)
            return (list.count - 1, work.calls.count - 1)
        }

        for (recordIndex, record) in byParent[parent] ?? [] {
            let before = list.count
            switch record.block {
            case .human(let message): append(.human(message))
            case .kite(let text): append(.kite(text))
            case .notification(let text): append(.notification(text))
            case .text(let text): append(.text(text))
            case .interrupted: append(.interrupted)
            case .compacted(let summary): append(.compacted(summary))
            case .apiError(let message): append(.apiError(message))
            case .thinking(let text): append(.thinking(text))
            case .toolUse(let use):
                let call = Call(use: use, state: Self.callState(use, result: nil, running: running), children: derive(under: use.id, byParent))
                let at = add(call)
                positions[use.id] = at
                if parent == nil { locations[recordIndex] = (at.item, at.step) }
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
                if parent == nil, locations[recordIndex] == nil { locations[recordIndex] = (list.count - 1, nil) }
            }
        }
        return list
    }

    /// 同种记录只刷新对应行；归属、种类或工具分组变化时重新派生。
    mutating func replaceRecord(at index: Int, with record: Record) {
        guard records.indices.contains(index) else { return }
        let previous = records[index]
        replacingRecord = true
        records[index] = record
        replacingRecord = false
        guard record.parent == nil, previous.parent == nil, let at = locations[index] else { items = derive(); return }
        switch (previous.block, record.block) {
        case (.text, .text(let text)): items[at.item].kind = .text(text)
        case (.thinking, .thinking(let text)): items[at.item].kind = .thinking(text)
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
