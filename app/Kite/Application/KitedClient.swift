import Foundation

nonisolated struct RemoteState: Decodable, Equatable, Sendable {
    nonisolated struct Outcome: Decodable, Equatable, Sendable { let kind: String; var message: String? }
    nonisolated struct Recovery: Decodable, Equatable, Sendable { let message: String }
    nonisolated struct Capabilities: Decodable, Equatable, Sendable {
        let send: Bool
        let interrupt: Bool
        let resume: Bool
        let cancel: Bool
    }
    let phase: String
    let busy: Bool
    var waitingForResume = false
    var lastOutcome: Outcome?
    var recovery: Recovery?
    var context: ContextUsage?
    let status: String
    let error: String?
    let capabilities: Capabilities
}

/// 最近一次完成请求的测量值，不把待发送文字和当前生成内容估算成 token。
nonisolated struct ContextUsage: Decodable, Equatable, Sendable {
    let requestId: String
    let inputTokens: Int
    var windowTokens: Int?
    let measuredAt: Double

    var fraction: Double? {
        guard inputTokens >= 0, let windowTokens, windowTokens > 0 else { return nil }
        return Double(inputTokens) / Double(windowTokens)
    }
}

struct RemoteInput: Codable {
    let id: String
    let text: String
    let source: String
    var midTurn: Bool? = nil
    var message: Message { Message(id: id, text: text, midTurn: midTurn ?? false) }
}

struct StopRequest: Encodable {
    let id: String
    let inputs: [RemoteInput]
}

struct StopResponse: Decodable { let returned: [RemoteInput] }

struct ThreadTitleSnapshot: Decodable {
    let title: String
    let revision: String
}

struct RemoteRecord: Decodable, Identifiable {
    struct Content: Decodable {
        let type: String
        var id: String?
        var text: String?
        var midTurn: Bool?
        var name: String?
        var input: JSON?
        var batch: String?
        var call: String?
        var output: String?
        var status: String?
        var parts: [String]?
        var arguments: String?
        var stage: String?
        var outputLimit: Int?
        var outputTruncated: Bool?
        var startedAt: Double?
        var finishedAt: Double?
        var diff: ToolDiffReference?
    }
    let id: String
    let parent: String?
    var generation: String?
    var block: Content

    var record: Record? {
        let content: Block
        switch block.type {
        case "human":
            guard let messageID = block.id, let text = block.text else { return nil }
            content = .human(Message(id: messageID, text: text, midTurn: block.midTurn ?? false))
        case "kite": content = .kite(block.text ?? "")
        case "text": content = .text(block.text ?? "")
        case "thinking": content = .thinking(block.text ?? "")
        case "error": content = .apiError(block.text ?? "")
        case "compacted": content = .compacted(block.text ?? "")
        case "interrupted": content = .interrupted
        case "tool_use":
            guard let call = block.id, let name = block.name else { return nil }
            content = .toolUse(ToolUse(id: call, name: name, input: block.input ?? .null, batch: block.batch,
                                      arguments: block.arguments, stage: block.stage, output: block.output ?? "",
                                      outputTruncated: block.outputTruncated ?? false, startedAt: block.startedAt, finishedAt: block.finishedAt))
        case "tool_result":
            guard let call = block.call else { return nil }
            content = .toolResult(ToolResult(call: call, content: [.text(block.output ?? "")],
                                             isError: block.status != "success", interrupted: block.status == "not_executed", unknown: block.status == "unknown", diff: block.diff))
        default: return nil
        }
        return Record(parent: parent, block: content, generation: generation)
    }
}

/// 增量只修改已存在的记录；断线重连始终从完整快照建立基线。
struct RemoteDelta: Decodable {
    let id: String
    let field: String
    let text: String
    var part: Int?
    var replace: Bool?
    var limit: Int?
    var input: JSON?
}

extension RemoteRecord {
    mutating func apply(_ delta: RemoteDelta) throws {
        guard delta.id == id else { throw KitedError(message: "流式记录身份不匹配") }
        switch delta.field {
        case "text" where block.type == "text" || block.type == "thinking":
            guard generation == "streaming" else { throw KitedError(message: "已结束的内容收到增量") }
            let index = delta.part ?? 0
            guard (0...1024).contains(index) else { throw KitedError(message: "流式分段序号无效") }
            var parts = block.parts ?? [block.text ?? ""]
            while parts.count <= index { parts.append("") }
            parts[index] = delta.replace == true ? delta.text : parts[index] + delta.text
            block.parts = parts
            block.text = parts.joined(separator: "\n\n")
        case "arguments" where block.type == "tool_use":
            guard generation == "streaming" else { throw KitedError(message: "已结束的参数收到增量") }
            block.arguments = delta.replace == true ? delta.text : (block.arguments ?? "") + delta.text
            // 服务端解析出的草稿字段只用于摘要，工具执行仍由后端完整参数校验决定。
            if let input = delta.input { block.input = input }
        case "output" where block.type == "tool_use":
            guard block.stage == "running", let limit = delta.limit, limit > 0 else {
                throw KitedError(message: "工具输出阶段或上限无效")
            }
            let output = (block.output ?? "") + delta.text
            let scalars = output.unicodeScalars
            block.outputTruncated = block.outputTruncated == true || scalars.count > limit
            block.output = String(String.UnicodeScalarView(scalars.suffix(limit)))
            block.outputLimit = limit
        default: throw KitedError(message: "流式字段与记录类型不匹配")
        }
    }
}

struct RemoteEvent: Decodable {
    let type: String
    var version: Int?
    var threadId: String?
    var workspaces: [RemoteWorkspace]?
    var cursor: String?
    var records: [RemoteRecord]?
    var record: RemoteRecord?
    var delta: RemoteDelta?
    var pending: [RemoteInput]?
    var state: RemoteState?
    var message: String?
}

enum KitedEventScope {
    case catalog
    case thread(String)
}

struct KitedError: LocalizedError {
    let message: String
    var status: Int? = nil
    var errorDescription: String? { message }
}

/// 地址来自账号目录；每个连接实例拥有身份，旧账号的迟到响应不能被新连接接收。
struct KitedClient: Equatable {
    let identity = UUID()
    let address: String
    var machineID: String? = nil
    var transport: HTTPTransport? = nil

    private func url(_ path: String) throws -> URL {
        guard let base = URL(string: address), ["http", "https"].contains(base.scheme), base.host != nil,
              let url = URL(string: path, relativeTo: base) else {
            throw KitedError(message: "请输入完整的服务地址，例如 http://127.0.0.1:5483")
        }
        return url
    }

    func request<T: Decodable>(_ path: String, method: String = "GET", body: (any Encodable)? = nil,
                               timeout: TimeInterval = 30, as type: T.Type) async throws -> T {
        try await requestWithCursor(path, method: method, body: body, timeout: timeout, as: type).value
    }

    func requestWithCursor<T: Decodable>(_ path: String, method: String = "GET", body: (any Encodable)? = nil,
                                       timeout: TimeInterval = 30, as type: T.Type) async throws -> (value: T, cursor: String?) {
        var request = URLRequest(url: try url(path))
        if path != "/machine" && path != "/pair" {
            guard let machineID else { throw KitedError(message: "请先连接工作机") }
            request.setValue(machineID, forHTTPHeaderField: "X-Kite-Machine")
        }
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response): (Data, URLResponse)
        if let transport { (data, response) = try await transport.send(request) }
        else {
            let session = Tailnet.covers(address) ? try await Tailnet.shared.urlSession() : URLSession.shared
            (data, response) = try await session.data(for: request)
        }
        try validate(response, data: data)
        return (try JSONDecoder().decode(T.self, from: data),
                (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Kite-Cursor"))
    }

    func post(_ path: String, body: [String: String]? = nil) async throws {
        let _: JSON = try await request(path, method: "POST", body: body, as: JSON.self)
    }

    /// 首帧包含所选范围的完整快照；取消任务时关闭 URLSession。
    func events(scope: KitedEventScope = .catalog, receive: (RemoteEvent) async throws -> Void) async throws {
        guard transport == nil else { throw KitedError(message: "此连接不提供实时事件流") }
        guard let machineID else { throw KitedError(message: "请先连接工作机") }
        // 组网会话的配置带着节点的代理设置。
        let connection = URLSession(configuration: Tailnet.covers(address) ? try await Tailnet.shared.urlSession().configuration : .ephemeral)
        defer { connection.invalidateAndCancel() }
        var components = URLComponents(url: try url("/events"), resolvingAgainstBaseURL: true)!
        switch scope {
        case .catalog: break
        case .thread(let id): components.queryItems = [URLQueryItem(name: "thread", value: id)]
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 60
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(machineID, forHTTPHeaderField: "X-Kite-Machine")
        let (bytes, response) = try await connection.bytes(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 409: throw KitedError(message: "连接地址对应的工作机已改变，请重新连接", status: 409)
        case 401: throw KitedError(message: "这台设备的授权已失效，请重新登录 Kite", status: 401)
        default: break
        }
        try validate(response)
        // kited 每个事件固定用一条 data 行，正文换行已由 JSON 转义。
        // AsyncBytes.lines 会略过空行，不能拿空行当它的事件结束标记。
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let event = try JSONDecoder().decode(RemoteEvent.self, from: Data(line.dropFirst(5).utf8))
            try await receive(event)
        }
        throw KitedError(message: "连接已断开，正在重连")
    }

    private func validate(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else { throw KitedError(message: "服务响应无效") }
        guard (200..<300).contains(http.statusCode) else {
            let error = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0)["error"] }
            throw KitedError(message: error ?? "服务返回 \(http.statusCode)", status: http.statusCode)
        }
    }
}

extension JSON: Codable {
    nonisolated func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([JSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSON].self)) }
    }
}
