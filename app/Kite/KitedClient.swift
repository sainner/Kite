import Foundation

struct RemoteProject: Decodable, Identifiable {
    let id: String
    let path: String
    var name: String { (path as NSString).lastPathComponent }
}

struct RemoteSession: Decodable, Identifiable {
    let id: String
    let projectId: String
    let title: String
    let worktree: String
    let status: String
}

struct RemoteState: Decodable {
    struct Capabilities: Decodable {
        let send: Bool
        let interrupt: Bool
        let resume: Bool
        let cancel: Bool
    }
    let phase: String
    let busy: Bool
    let status: String
    let error: String?
    let capabilities: Capabilities
}

struct RemoteInput: Decodable {
    let id: String
    let text: String
    let source: String
    let midTurn: Bool
    var message: Message { Message(id: id, text: text, midTurn: midTurn) }
}

struct RemoteRecord: Decodable, Identifiable {
    struct Content: Decodable {
        let type: String
        var id: String?
        var text: String?
        var midTurn: Bool?
        var name: String?
        var input: JSON?
        var call: String?
        var output: String?
        var status: String?
    }
    let id: String
    let parent: String?
    let block: Content

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
            content = .toolUse(ToolUse(id: call, name: name, input: block.input ?? .null))
        case "tool_result":
            guard let call = block.call else { return nil }
            content = .toolResult(ToolResult(call: call, content: [.text(block.output ?? "")],
                                             isError: block.status != "success", interrupted: block.status == "not_executed"))
        default: return nil
        }
        return Record(parent: parent, block: content)
    }
}

struct RemoteEvent: Decodable {
    let type: String
    var version: Int?
    var session: String?
    var cursor: String?
    var records: [RemoteRecord]?
    var record: RemoteRecord?
    var pending: [RemoteInput]?
    var state: RemoteState?
    var message: String?
}

struct KitedError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Mac 和模拟器默认连工作机本地服务；地址由连接面板保存。网络层只处理 Kite 协议。
struct KitedClient {
    let address: String

    private func url(_ path: String) throws -> URL {
        guard let base = URL(string: address), ["http", "https"].contains(base.scheme), base.host != nil,
              let url = URL(string: path, relativeTo: base) else {
            throw KitedError(message: "请输入完整的服务地址，例如 http://127.0.0.1:5483")
        }
        return url
    }

    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: String]? = nil, as type: T.Type) async throws -> T {
        var request = URLRequest(url: try url(path))
        request.httpMethod = method
        request.timeoutInterval = 30
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func post(_ path: String, body: [String: String]? = nil) async throws {
        let _: JSON = try await request(path, method: "POST", body: body, as: JSON.self)
    }

    /// 每次连接的首帧是完整 history；取消任务时关闭 URLSession，避免切会话留下流连接。
    func events(session: String? = nil, receive: (RemoteEvent) async throws -> Void) async throws {
        let connection = URLSession(configuration: .ephemeral)
        defer { connection.invalidateAndCancel() }
        var request = URLRequest(url: try url(session.map { "/events?session=\($0)" } ?? "/events"))
        request.timeoutInterval = 60
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await connection.bytes(for: request)
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
            throw KitedError(message: error ?? "服务返回 \(http.statusCode)")
        }
    }
}

extension JSON: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([JSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSON].self)) }
    }
}
