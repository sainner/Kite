import Foundation

/// 会话记录在 App 里的样子，照统一格式（任务书 §5）的要点：记录按顺序只追加，块的种类跟 Claude 的消息格式
/// （text、thinking、tool_use、tool_result），子 agent 的记录挂在发起它的那次工具调用下面。
/// App 只认这个格式，不解析 runtime 的原生记录。统一格式还没定，kited 也还没给出记录，现在用 SampleTranscripts 里的假数据。
struct Transcript {
    /// 会话的工作目录，工具参数里的绝对路径按它显示成相对路径。
    var root: String
    var records: [Record] { didSet { items = derive() } }
    /// 有回合在进行（kited 的 busy）。没有结果的工具调用这时算正在跑，否则算没跑完。
    var running: Bool { didSet { items = derive() } }
    /// 界面上的样子。记录或 running 变了才重新派生，视图重画时直接拿。
    private(set) var items: [Item] = []

    init(root: String, records: [Record] = [], running: Bool = false) {
        self.root = root
        self.records = records
        self.running = running
        items = derive()
    }
}

struct Record {
    /// 子 agent 的记录：发起它的那次 Agent 调用的 id。主对话里为 nil。
    var parent: String?
    var block: Block
}

enum Block {
    /// 人发的消息。midTurn：回合进行中插的话，agent 在下一次调用模型之前收到。
    case human(String, midTurn: Bool)
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
        case human(String, midTurn: Bool)
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
            case .human(let text, let midTurn): append(.human(text, midTurn: midTurn))
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

    /// 发一条消息。现在只记下来；接上 kited 后经它投递，回合在跑时就是插话。
    mutating func send(_ text: String) {
        records.append(Record(block: .human(text, midTurn: running)))
    }

    /// 打断回合：正在跑的调用记成被打断，和 Claude Code 自己的记录一样。现在只改假数据；接上 kited 后调它的打断接口。
    mutating func interrupt() {
        guard running else { return }
        let answered = Set(records.compactMap { if case .toolResult(let result) = $0.block { result.call } else { nil } })
        var added: [Record] = []
        for record in records {
            guard case .toolUse(let use) = record.block, !answered.contains(use.id) else { continue }
            let result = ToolResult(call: use.id, content: [.text("[Request interrupted by user for tool use]")], isError: true, interrupted: true)
            added.append(Record(parent: record.parent, block: .toolResult(result)))
        }
        added.append(Record(block: .interrupted))
        records += added
        running = false
    }
}
