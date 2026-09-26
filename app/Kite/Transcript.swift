import Foundation

/// 会话记录在 App 里的样子，由统一 Kite 协议转换；App 不解析 runtime 原生记录。
/// 子调用通过 parent 关联；消息投递状态单独放在 pending，纳入请求后才进入记录。
struct Transcript {
    /// 会话的工作目录，工具参数里的绝对路径按它显示成相对路径。
    var root: String
    var records: [Record] { didSet { items = derive() } }
    /// 有回合在进行（kited 的 busy）。没有结果的工具调用这时算正在跑，否则算没跑完。
    var running: Bool { didSet { items = derive() } }
    /// 发出去了、agent 还没收到的消息，按发出的顺序。收到的那一刻才变成一条记录，撤回的永远不进记录。
    /// 包含服务已接收但尚未纳入模型请求的输入，以及客户端还没收到投递确认的消息。
    var pending: [Message]
    /// 界面上的样子。记录或 running 变了才重新派生，视图重画时直接拿。
    private(set) var items: [Item] = []

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
    /// 排队中的消息上是预计：发的时候回合在跑、或者前面还排着别的，收到时就并进那一轮（见 Session.send）。
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
    let input: JSON
}

struct ToolResult {
    /// 对应的 ToolUse 的 id。
    let call: String
    let content: [ResultPart]
    let isError: Bool
    /// 人打断回合时它还在跑。原生记录里也是一条出错的结果，翻译时标出来，界面上不算出错。
    var interrupted = false

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
enum JSON: Equatable {
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

/// 界面上的一项。记录按顺序排下来，连续的工具调用和思考折成一项 Work，工具结果并到它的调用上。
/// 记录只追加，所以序号就是稳定的 id。
struct Item: Identifiable {
    let id: Int
    var kind: Kind

    enum Kind {
        case human(Message)
        case kite(String)
        case notification(String)
        case text(String)
        case work(Work)
        case interrupted
        case compacted(String)
        case apiError(String)
    }
}

/// 两段话之间 agent 做的事：一串工具调用和思考。
struct Work {
    var steps: [Step]

    var calls: [Call] {
        steps.compactMap { if case .call(let call) = $0 { call } else { nil } }
    }
}

enum Step {
    case thinking(String)
    case call(Call)
}

struct Call {
    let use: ToolUse
    var result: ToolResult?
    var state: State
    /// Agent 调用里子 agent 做的事。
    var children: [Item]

    enum State {
        case running, done, failed, interrupted
        /// 没有结果，也没有回合在跑：进程在工具跑到一半时没了。
        case unfinished
    }
}

extension Transcript {
    private func derive() -> [Item] {
        let byParent = Dictionary(grouping: records, by: \.parent)
        return derive(under: nil, byParent)
    }

    private func derive(under parent: String?, _ byParent: [String?: [Record]]) -> [Item] {
        var list: [Item] = []
        /// 调用的 id → 在第几项的第几步，结果来了按它找回去。
        var positions: [String: (item: Int, step: Int)] = [:]

        func append(_ kind: Item.Kind) {
            list.append(Item(id: list.count, kind: kind))
        }

        /// 接到上一项 Work 后面，上一项不是 Work 就另起一项。
        func add(_ step: Step) -> (item: Int, step: Int) {
            guard case .work(var work) = list.last?.kind else {
                append(.work(Work(steps: [step])))
                return (list.count - 1, 0)
            }
            work.steps.append(step)
            list[list.count - 1].kind = .work(work)
            return (list.count - 1, work.steps.count - 1)
        }

        for record in byParent[parent] ?? [] {
            switch record.block {
            case .human(let message): append(.human(message))
            case .kite(let text): append(.kite(text))
            case .notification(let text): append(.notification(text))
            case .text(let text): append(.text(text))
            case .interrupted: append(.interrupted)
            case .compacted(let summary): append(.compacted(summary))
            case .apiError(let message): append(.apiError(message))
            case .thinking(let text): _ = add(.thinking(text))
            case .toolUse(let use):
                let call = Call(use: use, state: running ? .running : .unfinished, children: derive(under: use.id, byParent))
                positions[use.id] = add(.call(call))
            case .toolResult(let result):
                guard let at = positions[result.call], case .work(var work) = list[at.item].kind,
                      case .call(var call) = work.steps[at.step] else { continue }
                call.result = result
                call.state = result.interrupted ? .interrupted : result.isError ? .failed : .done
                work.steps[at.step] = .call(call)
                list[at.item].kind = .work(work)
            }
        }
        return list
    }
}
