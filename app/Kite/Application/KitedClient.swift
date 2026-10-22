import Foundation

nonisolated struct RemoteState: Decodable, Equatable, Sendable {
    nonisolated struct Outcome: Decodable, Equatable, Sendable { let kind: String; var message: String? }
    nonisolated struct Recovery: Decodable, Equatable, Sendable { let message: String }
    nonisolated struct Capabilities: Decodable, Equatable, Sendable {
        let send: Bool
        let interrupt: Bool
        let resume: Bool
        let cancel: Bool
        var switchRuntime: Bool? = nil
        var compact: Bool? = nil
    }
    let phase: String
    let busy: Bool
    var compacting: Bool?
    var waitingForResume = false
    var lastOutcome: Outcome?
    var recovery: Recovery?
    /// 回合卡在审批上等人批准；phase 仍是 running。
    var waiting: RemoteWaiting?
    /// 没回应的提问与密钥请求，按发出的先后；不阻塞回合。
    var asks: [RemoteWaiting]?
    var context: ContextUsage?
    let status: String
    let error: String?
    let capabilities: Capabilities
}

/// 等人回应的对象（docs/工具审批与提问.md）：卡着回合的审批带工具、目标与原因，必问的不能「允许并记住」；不阻塞的提问带问题与选项；
/// 密钥请求带一次要的几项，每项是名称（或环境变量文件与变量名）、用途、代理给的值，以及同名的是否已存在。
nonisolated struct RemoteWaiting: Decodable, Equatable, Sendable {
    nonisolated struct Option: Decodable, Equatable, Sendable {
        let label: String
        let description: String
    }
    nonisolated struct Question: Decodable, Equatable, Sendable {
        let question: String
        let options: [Option]
        let multiSelect: Bool
    }
    var id: String
    /// question、approval 或 secret。
    let kind: String
    let since: Double
    var questions: [Question]?
    var tool: String?
    var target: String?
    var reason: String?
    var mustAsk: Bool?
    /// 代理申请在沙箱外运行命令：target 是命令原文，reason 是代理写的用途。
    var outside: Bool?
    /// 出沙箱的命令绑定的密钥引用，如 {project.ssh_pw}。
    var secretReferences: [String]?
    /// 代理起与主线不一致的预置脚本（tool 为 terminal_run，target 是脚本名）：脚本的内容。
    var script: String?
    /// 密钥请求一次要的几项，用户在同一张卡片里填，填了几项存几项。
    var secrets: [Secret]?

    var isQuestion: Bool { kind == "question" }
    var isSecret: Bool { kind == "secret" }
    /// 密钥请求里有独立的密钥（能存为账号共享；环境变量文件里的项只能项目专用）。
    var hasStandaloneSecret: Bool { secrets?.contains { $0.file == nil } == true }

    /// 等的是什么：标题栏圆环、停靠栏与回应卡片共用。
    static func title(of kind: String) -> String {
        switch kind {
        case "question": "等待回答"
        case "secret": "等待密钥"
        default: "等待批准"
        }
    }

    /// 密钥请求里的一项：一条独立的密钥（name，类型 secretKind 为 text 或 file），或环境变量文件 file 里的变量 key。
    nonisolated struct Secret: Decodable, Equatable, Sendable {
        let reason: String
        var name: String?
        var secretKind: String?
        var file: String?
        var key: String?
        /// 代理自己给的值，卡片预先填好。
        var value: String?
        /// 默认目标已经存在，保存是替换。
        var exists: Bool?

        /// 要的那一项：环境变量文件里的变量，或一条独立的密钥。
        var title: String {
            if let file, let key { return "\(file) 里的 \(key)" }
            return name ?? "密钥"
        }
    }
}

/// 回应等你的那一项：提问按问题顺序给出选中的选项或「其他」，审批给出 once、remember 或 deny，
/// 密钥请求按顺序逐项给出填的值（没填的为 null）与范围（project 或 account），拒绝同样是 decision 的 deny。
nonisolated enum WaitingReply: Encodable, Sendable {
    nonisolated struct Answer: Encodable, Sendable {
        var selected: [String]?
        var other: String?
    }
    nonisolated struct Secret: Encodable, Sendable {
        let values: [String?]
        let scope: String
    }
    case answers([Answer])
    case decision(String)
    case secret(Secret)

    private enum Keys: String, CodingKey { case answers, decision, secret }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .answers(let answers): try container.encode(answers, forKey: .answers)
        case .decision(let decision): try container.encode(decision, forKey: .decision)
        case .secret(let secret): try container.encode(secret, forKey: .secret)
        }
    }
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
    /// 代理来信的发信方（kited 的 InputSender）：代理带标题；Line 自己的话以它的经由为发信方，没有标题。
    var from: From? = nil
    /// 人发的消息带的附件。
    var attachments: [Attachment]? = nil
    var message: Message { Message(id: id, text: text, attachments: attachments ?? [], midTurn: midTurn ?? false) }

    struct From: Codable {
        let kind: String
        let instance: String
        var title: String? = nil
    }

    /// 排队中画出来的：人发的消息和代理来信；Kite 的通知不画。来信的名称同记录里的 sender（kited 的 senderName）。
    var queued: Queued? {
        switch source {
        case "human": Queued(message: message)
        case "agent": from.map { Queued(message: message, sender: Sender(name: $0.kind == "line" ? "Line" : $0.title ?? "", instance: $0.instance)) }
        default: nil
        }
    }
}

struct StopRequest: Encodable {
    let id: String
    let inputs: [RemoteInput]
    /// 每次发出时按当时有没有恢复阻塞填，见 WorkThread.confirmsRecovery。
    var confirmRecovery: Bool?
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
        /// human 块带的附件。
        var attachments: [Attachment]?
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
        var from: String?
        var through: String?
        var automatic: Bool?
        var reverted: Bool?
        /// agent 块的发信方。
        var sender: RemoteSender?
        /// kite 块：哪种通知、给人看的那一句；response 是转交的用户回应。
        var notice: RemoteNotice?
        var response: Bool?
    }
    struct RemoteSender: Decodable {
        let name: String
        let instance: String
    }
    struct RemoteNotice: Decodable {
        let kind: String
        let title: String
        var subject: String?
        var instance: String?
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
            content = .human(Message(id: messageID, text: text, attachments: block.attachments ?? [], midTurn: block.midTurn ?? false))
        case "agent":
            guard let messageID = block.id, let text = block.text, let sender = block.sender else { return nil }
            content = .agent(Message(id: messageID, text: text), sender: Sender(name: sender.name, instance: sender.instance))
        case "kite":
            let notice = block.notice
            content = .kite(Notice(text: block.text ?? "", kind: notice.flatMap { Notice.Kind(rawValue: $0.kind) }, title: notice?.title,
                                   subject: notice?.subject, instance: notice?.instance, response: block.response ?? false))
        case "text": content = .text(block.text ?? "")
        case "thinking": content = .thinking(block.text ?? "")
        case "compacted":
            // 撤销后范围照原样显示，摘要不再出现。
            if block.reverted == true { return nil }
            content = .compacted(Compaction(id: block.id, summary: block.text ?? "", automatic: block.automatic ?? false))
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
    var workspaceId: String?
    var activity: ThreadActivity?
    var workspaces: [RemoteWorkspace]?
    var cursor: String?
    var records: [RemoteRecord]?
    var record: RemoteRecord?
    var delta: RemoteDelta?
    var pending: [RemoteInput]?
    var state: RemoteState?
    var message: String?
    var modelAccounts: ModelAccountsSnapshot?
    /// monitor.changed 的实例。
    var instanceId: String?
    /// line.notification 带的系统通知。
    var notification: LineNotificationPayload?
}

/// Line 所在的工作机推来的系统通知（line.notification）：点开是收件箱里的 item。
nonisolated struct LineNotificationPayload: Decodable, Sendable {
    let id: String
    let title: String
    let body: String
    var item: String?
}

enum KitedEventScope {
    case catalog
    case thread(String)
}

struct KitedError: LocalizedError {
    let message: String
    var status: Int? = nil
    /// 访问的 Git 平台要求登录（或拒绝了令牌）：它的主机，界面据此让用户就地绑定访问令牌，见 GitLogin。
    var gitLogin: String? = nil
    /// 出错的那台工作机：请求发给的那台；它转交另一台工作机时出的登录问题（错误体的 gitLoginMachine）是那一台。
    /// 令牌写到这里，重试时马上能用。
    var machineID: String? = nil
    /// 集成父工作区时还没合回或放弃的子工作区，见 PendingChildren。
    var children: [Child]? = nil
    var errorDescription: String? { message }

    struct Child: Decodable, Identifiable, Equatable, Sendable {
        let id: String
        let name: String
    }
}

extension String {
    /// 作为请求路径里的一段，ID 中的斜杠等字符一并转义。
    nonisolated var pathComponent: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
    }
}

/// 地址来自工作机目录；每个连接实例拥有身份，旧账号的迟到响应不能被新连接接收。
struct KitedClient: Equatable {
    /// 本机 kited 的地址：作为工作机的 Mac 直接访问它，不经组网。
    static let local = "http://127.0.0.1:5483"
    let identity = UUID()
    let address: String
    var machineID: String? = nil

    var isLocal: Bool { address == Self.local }

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
        let trace = TimingTrace.span("\(method) \(path)")
        let session = Tailnet.covers(address) ? try await Tailnet.shared.urlSession() : URLSession.shared
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { trace("失败：\(error.localizedDescription)"); throw error }
        trace("\((response as? HTTPURLResponse)?.statusCode ?? 0)")
        try validate(response, data: data)
        return (try JSONDecoder().decode(T.self, from: data),
                (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Kite-Cursor"))
    }

    func post(_ path: String, body: (any Encodable)? = nil) async throws {
        let _: JSON = try await request(path, method: "POST", body: body, as: JSON.self)
    }

    /// 首帧包含所选范围的完整快照；取消任务时关闭 URLSession。
    func events(scope: KitedEventScope = .catalog, receive: (RemoteEvent) async throws -> Void) async throws {
        let thread: String? = switch scope {
        case .catalog: nil
        case .thread(let id): id
        }
        // 目录流带上这台设备：连着 Line 所在的工作机时，App 报的关注状态才算数（见 LineAttention）
        let (connection, stream) = try await streamRequest("/events", thread: thread, device: thread == nil ? LineAttention.deviceID : nil)
        defer { connection.invalidateAndCancel() }
        var request = stream
        request.timeoutInterval = 60
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let trace = TimingTrace.span("事件流 \(request.url?.query ?? "目录")")
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await connection.bytes(for: request) }
        catch { trace("失败：\(error.localizedDescription)"); throw error }
        trace("已建立 \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        var first = true
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
            if first { first = false; TimingTrace.mark("事件流 \(request.url?.query ?? "目录") 首帧") }
            let event = try JSONDecoder().decode(RemoteEvent.self, from: Data(line.dropFirst(5).utf8))
            try await receive(event)
        }
        throw KitedError(message: "连接已断开，正在重连")
    }

    /// 语音输入的 WebSocket，协议见 kited 的 voice/sessions.ts；thread 是正在输入的会话，新会话不带。
    func voiceSocket(thread: String?) async throws -> (URLSession, URLSessionWebSocketTask) {
        let (session, request) = try await streamRequest("/voice", thread: thread, webSocket: true)
        return (session, session.webSocketTask(with: request))
    }

    /// 接到终端的 WebSocket，协议见 kited 的 terminal/terminals.ts；带上窗口放得下的尺寸，工作机按它出画面。
    func terminalSocket(instance: String, cols: Int, rows: Int) async throws -> (URLSession, URLSessionWebSocketTask) {
        let (session, request) = try await streamRequest("/instances/\(instance)/terminal", thread: nil, webSocket: true,
                                                         extra: [URLQueryItem(name: "cols", value: String(cols)), URLQueryItem(name: "rows", value: String(rows))])
        return (session, session.webSocketTask(with: request))
    }

    /// 接到预览画面的 WebSocket，协议见 kited 的 preview/previews.ts；带上窗口放得下的逻辑尺寸与实时还是逐帧。
    func previewSocket(instance: String, width: Int, height: Int, live: Bool) async throws -> (URLSession, URLSessionWebSocketTask) {
        let (session, request) = try await streamRequest("/instances/\(instance)/preview", thread: nil, webSocket: true, extra: [
            URLQueryItem(name: "width", value: String(width)), URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "mode", value: live ? "live" : "step"),
        ])
        return (session, session.webSocketTask(with: request))
    }

    /// 按字节取文件，下载到临时文件，调用方挪走或删掉。304 时没有新内容，调用方用自己缓存的那一版。
    /// progress 拿到下载任务的进度对象；method 为 HEAD 时只取大小、类型和修改时间，不返回文件。
    func download(_ path: String, method: String = "GET", headers: [String: String] = [:],
                  progress: (@Sendable (Progress) -> Void)? = nil) async throws -> (file: URL?, response: HTTPURLResponse) {
        guard let machineID else { throw KitedError(message: "请先连接工作机") }
        var request = URLRequest(url: try url(path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(machineID, forHTTPHeaderField: "X-Kite-Machine")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let session = Tailnet.covers(address) ? try await Tailnet.shared.urlSession() : URLSession.shared
        if method == "HEAD" {
            let (_, response) = try await session.data(for: request)
            try validate(response)
            return (nil, response as! HTTPURLResponse)
        }
        let (file, response) = try await session.download(for: request, delegate: progress.map(DownloadProgress.init))
        guard let http = response as? HTTPURLResponse, http.statusCode != 304 else {
            try? FileManager.default.removeItem(at: file)
            return (nil, response as! HTTPURLResponse)
        }
        if !(200..<300).contains(http.statusCode) {
            let data = try? Data(contentsOf: file)
            try? FileManager.default.removeItem(at: file)
            try validate(response, data: data)
        }
        return (file, http)
    }

    /// 把本机文件原样传上去（附件），返回解码后的响应；progress 报已发出的比例，在 URLSession 的队列上调。
    func upload<T: Decodable>(_ path: String, file: URL, as type: T.Type, progress: (@Sendable (Double) -> Void)? = nil) async throws -> T {
        guard let machineID else { throw KitedError(message: "请先连接工作机") }
        var request = URLRequest(url: try url(path))
        request.httpMethod = "PUT"
        request.setValue(machineID, forHTTPHeaderField: "X-Kite-Machine")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let trace = TimingTrace.span("PUT \(path)")
        let session = Tailnet.covers(address) ? try await Tailnet.shared.urlSession() : URLSession.shared
        let data: Data, response: URLResponse
        do { (data, response) = try await session.upload(for: request, fromFile: file, delegate: progress.map(UploadProgress.init)) }
        catch { trace("失败：\(error.localizedDescription)"); throw error }
        trace("\((response as? HTTPURLResponse)?.statusCode ?? 0)")
        try validate(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// 长连接（事件流、语音）用的独立会话和带工作机校验的请求；thread 给出时只关于这个会话。组网会话的配置带着节点的代理设置。
    func streamRequest(_ path: String, thread: String?, device: String? = nil, webSocket: Bool = false,
                               extra: [URLQueryItem] = []) async throws -> (URLSession, URLRequest) {
        guard let machineID else { throw KitedError(message: "请先连接工作机") }
        var components = URLComponents(url: try url(path), resolvingAgainstBaseURL: true)!
        if webSocket { components.scheme = components.scheme == "https" ? "wss" : "ws" }
        var query: [URLQueryItem] = []
        if let thread { query.append(URLQueryItem(name: "thread", value: thread)) }
        if let device { query.append(URLQueryItem(name: "device", value: device)) }
        query += extra
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue(machineID, forHTTPHeaderField: "X-Kite-Machine")
        let session = URLSession(configuration: Tailnet.covers(address) ? try await Tailnet.shared.urlSession().configuration : .ephemeral)
        return (session, request)
    }

    private func validate(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else { throw KitedError(message: "服务响应无效") }
        guard (200..<300).contains(http.statusCode) else {
            struct Body: Decodable { let error: String?; let gitLogin: String?; let gitLoginMachine: String?; let children: [KitedError.Child]? }
            let body = data.flatMap { try? JSONDecoder().decode(Body.self, from: $0) }
            throw KitedError(message: body?.error ?? "服务返回 \(http.statusCode)", status: http.statusCode, gitLogin: body?.gitLogin,
                             machineID: body?.gitLoginMachine ?? machineID, children: body?.children)
        }
    }
}

/// 上传时报已发出的比例。
private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                                totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

/// 下载任务建好时交出它的进度对象，界面直接观察。
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Progress) -> Void
    init(_ report: @escaping @Sendable (Progress) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) { report(task.progress) }
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
