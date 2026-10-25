import CryptoKit
import Foundation

nonisolated struct RemoteState: Decodable, Equatable, Sendable {
    nonisolated struct Outcome: Decodable, Equatable, Sendable { let kind: String; var message: String? }
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
    /// 代理起与主线不一致的预置脚本（tool 为 preview_open 时 target 是目标名，为 check 时是 .kite/check）：脚本的内容。
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
    /// 开头 /名字 点选的 skill 的名字，工作机收下时认出的；App 用它拆出命令显示。
    var skill: String? = nil
    var message: Message { Message(id: id, text: text, skill: skill, attachments: attachments ?? [], midTurn: midTurn ?? false) }

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
        /// human 块：开头 /名字 点选并已随消息交给模型的 skill。
        var skill: String?
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
            content = .human(Message(id: messageID, text: text, skill: block.skill, attachments: block.attachments ?? [], midTurn: block.midTurn ?? false))
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
    /// monitor.changed、instance.show 的实例。
    var instanceId: String?
    /// library.changed 变了的那一类目录，见 LibraryList；kind 为 layout 时另带 projectId。
    var kind: String?
    var projectId: String?
    /// line.notification 带的系统通知。
    var notification: LineNotificationPayload?
    /// mcp.changed：为真是服务清单本身变了，不只是连接状态。
    var catalog: Bool?
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
    /// 一个工作区的管理事件流（/events?workspace=）：App 只从这里收代理请用户看某个实例的 instance.show，别的事件由目录流处理。
    case workspace(String)
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
    /// Debug 构建带 `--kited http://127.0.0.1:5484` 启动时换成给的地址：验证时对着临时目录里跑的开发版 kited，不碰用户装着的服务。
    static let local: String = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--kited"), arguments.indices.contains(index + 1) { return arguments[index + 1] }
        #endif
        return "http://127.0.0.1:5483"
    }()
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
        var thread: String?, workspace: String?
        switch scope {
        case .catalog: break
        case .thread(let id): thread = id
        case .workspace(let id): workspace = id
        }
        // 目录流带上这台设备：连着 Line 所在的工作机时，App 报的关注状态才算数（见 LineAttention）
        let (connection, stream) = try await streamRequest("/events", thread: thread, device: thread == nil && workspace == nil ? LineAttention.deviceID : nil,
                                                           extra: workspace.map { [URLQueryItem(name: "workspace", value: $0)] } ?? [])
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

    /// 接到预览画面的 WebSocket，协议见 kited 的 preview/previews.ts；带上窗口放得下的逻辑尺寸与实时还是逐帧，并排的一格另带浏览器与视口尺寸。
    func previewSocket(instance: String, width: Int, height: Int, live: Bool, cell: PreviewCell? = nil) async throws -> (URLSession, URLSessionWebSocketTask) {
        var query = [URLQueryItem(name: "width", value: String(width)), URLQueryItem(name: "height", value: String(height)),
                     URLQueryItem(name: "mode", value: live ? "live" : "step")]
        if let cell {
            query += [URLQueryItem(name: "browser", value: cell.browser.rawValue), URLQueryItem(name: "viewportWidth", value: String(cell.width)),
                      URLQueryItem(name: "viewportHeight", value: String(cell.height))]
        }
        let (session, request) = try await streamRequest("/instances/\(instance)/preview", thread: nil, webSocket: true, extra: query)
        return (session, session.webSocketTask(with: request))
    }

    /// 按字节取文件，下载到临时文件，调用方挪走或删掉。304 时没有新内容，调用方用自己缓存的那一版。
    /// progress 拿到下载任务的进度对象；method 为 HEAD 时只取大小、类型和修改时间，不返回文件。
    /// segmented 给支持 Range 的接口用：不是本机时按段取，见 segmentedDownload。
    func download(_ path: String, method: String = "GET", headers: [String: String] = [:], segmented: Bool = false,
                  progress: (@Sendable (Progress) -> Void)? = nil) async throws -> (file: URL?, response: HTTPURLResponse) {
        guard let machineID else { throw KitedError(message: "请先连接工作机") }
        var request = URLRequest(url: try url(path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(machineID, forHTTPHeaderField: "X-Kite-Machine")
        let plain = request
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let session = Tailnet.covers(address) ? try await Tailnet.shared.urlSession() : URLSession.shared
        if segmented, method == "GET", !isLocal,
           let result = try await segmentedDownload(first: request, rest: plain, session: session, progress: progress) {
            return result
        }
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

    /// 组网上按段取：一段 1 MiB、4 路同时取；一段 2 秒没有新数据就换个请求重取，同一段最多试 8 次。
    nonisolated private static let segmentSize = 1 << 20
    nonisolated private static let segmentWorkers = 4
    nonisolated private static let segmentStall: TimeInterval = 2
    nonisolated private static let segmentAttempts = 8

    /// 组网上一条连接遇上丢包后可能一直慢下去，路径恢复了也不回来；分段几路同时取、卡住的段换个请求，
    /// 实测把最慢的情况从几分钟压到几秒，见 docs/research/2026-10-22-组网传输速度.md。
    /// 取的过程中文件被改了就整份重来，最多三遍。返回 nil 时这个文件按段取不了（空文件回 416），由调用方整份取。
    ///
    /// 段请求的超时从任务开始算，在 URLSession 里排队等连接的时间也算进去；所以这次下载用自己的会话，
    /// 每主机连接数正好是同时取的段数，段请求不排队，也不与别的请求抢连接，2 秒只量真正的卡顿。
    private func segmentedDownload(first: URLRequest, rest: URLRequest, session: URLSession,
                                   progress: (@Sendable (Progress) -> Void)?) async throws -> (file: URL?, response: HTTPURLResponse)? {
        let configuration = session.configuration
        configuration.httpMaximumConnectionsPerHost = Self.segmentWorkers
        let own = URLSession(configuration: configuration)
        defer { own.invalidateAndCancel() }
        var attempt = 1
        while true {
            do {
                let (file, response, body) = try await Self.fetchSegments(first: first, rest: rest, session: own, progress: progress)
                if response.statusCode == 416 { return nil }
                if response.statusCode == 304 { return (nil, response) }
                try validate(response, data: body)
                return (file, response)
            } catch is FileChanged {
                guard attempt < 3 else { throw KitedError(message: "文件在下载时一直在变，请稍后再打开") }
                attempt += 1
            }
        }
    }

    /// 先取第一段，带调用方的头（如 If-None-Match），从回应里拿到整份大小与版本；其余各段几路同时取，写进同一个临时文件的对应位置。
    /// 第一段的回应不是 206 时原样交回：200 是接口给了整份（已写进临时文件），304、416 与错误由调用方处理，body 是错误说明。
    nonisolated private static func fetchSegments(first: URLRequest, rest: URLRequest, session: URLSession,
                                                  progress: (@Sendable (Progress) -> Void)?)
        async throws -> (file: URL?, response: HTTPURLResponse, body: Data) {
        let overall = Progress(totalUnitCount: -1)
        progress?(overall)
        let (head, response) = try await segment(first, session: session, from: 0, to: segmentSize - 1)
        guard response.statusCode == 206 else {
            guard response.statusCode == 200 else { return (nil, response, head) }
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try head.write(to: file)
            return (file, response, Data())
        }
        guard let total = response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap({ Int($0) }),
              head.count == min(segmentSize, total) else { throw URLError(.badServerResponse) }
        let version = response.value(forHTTPHeaderField: "ETag")
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try head.write(to: file)
            overall.totalUnitCount = Int64(total)
            overall.completedUnitCount = Int64(head.count)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var pending = Array(stride(from: head.count, to: total, by: segmentSize))
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                var running = 0
                repeat {
                    while running < segmentWorkers, !pending.isEmpty {
                        let start = pending.removeFirst(), end = min(start + segmentSize, total) - 1
                        group.addTask {
                            let (data, response) = try await Self.segment(rest, session: session, from: start, to: end)
                            guard response.statusCode == 206, response.value(forHTTPHeaderField: "ETag") == version,
                                  data.count == end - start + 1 else { throw FileChanged() }
                            return (start, data)
                        }
                        running += 1
                    }
                    guard let next = try await group.next() else { break }
                    running -= 1
                    try handle.seek(toOffset: UInt64(next.0))
                    try handle.write(contentsOf: next.1)
                    overall.completedUnitCount += Int64(next.1.count)
                } while running > 0
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return (file, whole(response, url: first.url!, total: total), Data())
    }

    /// 取一段。URLRequest 的超时从任务开始算、每收到数据重新计时：建连或两次收到数据之间超过 2 秒，就当这条连接卡住了，
    /// 换个请求重取这一段。前提是任务不在会话里排队，见 segmentedDownload。
    nonisolated private static func segment(_ base: URLRequest, session: URLSession, from start: Int, to end: Int) async throws
        -> (Data, HTTPURLResponse) {
        var request = base
        request.timeoutInterval = segmentStall
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        var attempt = 1
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                return (data, http)
            } catch let error as URLError where [.timedOut, .networkConnectionLost].contains(error.code) && attempt < segmentAttempts {
                attempt += 1
            }
        }
    }

    /// 按段取完的文件当作一份整的回应交给调用方：去掉分段范围，长度写整份的；类型、版本、修改时间与有没有进快照照第一段的。
    nonisolated private static func whole(_ response: HTTPURLResponse, url: URL, total: Int) -> HTTPURLResponse {
        var fields: [String: String] = [:]
        for case let (key as String, value as String) in response.allHeaderFields
            where !["content-range", "content-length"].contains(key.lowercased()) { fields[key] = value }
        fields["Content-Length"] = String(total)
        return HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: fields)!
    }

    /// 把本机文件原样传上去（附件），返回解码后的响应；progress 报已发出的比例，在 URLSession 的队列上调。
    /// segmented 给有分段上传接口的地址用：不是本机时按段传，见 segmentedUpload。
    func upload<T: Decodable>(_ path: String, file: URL, as type: T.Type, segmented: Bool = false,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> T {
        guard let machineID else { throw KitedError(message: "请先连接工作机") }
        var request = URLRequest(url: try url(path))
        request.httpMethod = "PUT"
        request.setValue(machineID, forHTTPHeaderField: "X-Kite-Machine")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let trace = TimingTrace.span("PUT \(path)")
        let session = Tailnet.covers(address) ? try await Tailnet.shared.urlSession() : URLSession.shared
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        let data: Data, response: URLResponse
        do {
            if segmented, !isLocal, size > 0 {
                (data, response) = try await segmentedUpload(path, file: file, size: size, machineID: machineID, session: session, progress: progress)
            } else {
                (data, response) = try await session.upload(for: request, fromFile: file, delegate: progress.map(UploadProgress.init))
            }
        } catch { trace("失败：\(error.localizedDescription)"); throw error }
        trace("\((response as? HTTPURLResponse)?.statusCode ?? 0)")
        try validate(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// 组网上按段传，段的大小、路数与卡住的判断同按段取（segmentSize 等）：各段 PUT 到 path/parts/<位置>，几路同时传，
    /// 卡住的段换个请求重传；传完 POST path/parts，工作机核对整份的大小与 SHA-256 后收下，交回这个回应。path 可带查询，原样给最后一步。
    /// 同 segmentedDownload，这次上传用自己的会话，段请求不在会话里排队。
    private func segmentedUpload(_ path: String, file: URL, size: Int, machineID: String, session: URLSession,
                                 progress: (@Sendable (Double) -> Void)?) async throws -> (Data, URLResponse) {
        guard let components = URLComponents(string: path) else { throw KitedError(message: "上传地址无效") }
        let base = components.percentEncodedPath
        let sha256 = try await Self.sha256(of: file)
        let configuration = session.configuration
        configuration.httpMaximumConnectionsPerHost = Self.segmentWorkers
        let own = URLSession(configuration: configuration)
        defer { own.invalidateAndCancel() }
        let sent = SentBytes(total: size, report: progress)
        var pending = Array(stride(from: 0, to: size, by: Self.segmentSize))
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            var running = 0
            repeat {
                while running < Self.segmentWorkers, !pending.isEmpty {
                    let start = pending.removeFirst()
                    var request = URLRequest(url: try url("\(base)/parts/\(start)?size=\(size)"))
                    request.httpMethod = "PUT"
                    request.setValue(machineID, forHTTPHeaderField: "X-Kite-Machine")
                    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                    let sending = request
                    group.addTask {
                        try await Self.part(sending, file: file, start: start, length: min(Self.segmentSize, size - start), session: own, sent: sent)
                    }
                    running += 1
                }
                guard let done = try await group.next() else { break }
                running -= 1
                try validate(done.1, data: done.0)
            } while running > 0
        }
        var request = URLRequest(url: try url("\(base)/parts\(components.percentEncodedQuery.map { "?\($0)" } ?? "")"))
        request.httpMethod = "POST"
        request.setValue(machineID, forHTTPHeaderField: "X-Kite-Machine")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["size": size, "sha256": sha256])
        return try await own.data(for: request)
    }

    /// 传一段：从文件读出这一段再发。URLRequest 的超时量的是两次收发数据之间的空档，超过 2 秒就当这条连接卡住了，换个请求重传。
    nonisolated private static func part(_ base: URLRequest, file: URL, start: Int, length: Int, session: URLSession,
                                         sent: SentBytes) async throws -> (Data, URLResponse) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start))
        let body = try handle.read(upToCount: length) ?? Data()
        guard body.count == length else { throw KitedError(message: "上传时文件变了") }
        var request = base
        request.timeoutInterval = segmentStall
        var attempt = 1
        while true {
            do { return try await session.upload(for: request, from: body, delegate: PartProgress(start: start, sent: sent)) }
            catch let error as URLError where [.timedOut, .networkConnectionLost].contains(error.code) && attempt < segmentAttempts {
                sent.update(start, 0)
                attempt += 1
            }
        }
    }

    nonisolated private static func sha256(of file: URL) async throws -> String {
        try await Task.detached {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: Self.segmentSize), !chunk.isEmpty { hash.update(data: chunk) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
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

/// 实例与布局的几个请求，接口见 docs/kited.md。
extension KitedClient {
    /// 新建实例，响应是实例（带当前视图）。同一 id 同内容重试返回同一个实例；预览的同一目标与设备已经在跑时返回那个实例。
    func createInstance(workspace: String, id: String, definitionId: String, title: String? = nil, command: String? = nil,
                        preview: PreviewSpec? = nil, page: BrowsePage? = nil) async throws -> RemotePluginInstance {
        try await request("/workspaces/\(workspace.pathComponent)/instances", method: "POST",
                          body: CreateInstanceRequest(id: id, definitionId: definitionId, title: title, command: command, preview: preview, page: page),
                          as: RemotePluginInstance.self)
    }

    /// 换实例当前显示的视图，各端同步；返回实例。
    func switchView(instance: String, viewId: String) async throws -> RemotePluginInstance {
        struct Body: Encodable { let viewId: String }
        return try await request("/instances/\(instance.pathComponent)/view", method: "PUT", body: Body(viewId: viewId), as: RemotePluginInstance.self)
    }

    /// 关闭实例：closable 的回收，process 的先停进程再回收。已经不存在（404）当成功：迟到的重试不会复活实例。
    func closeInstance(id: String) async throws {
        do { let _: JSON = try await request("/instances/\(id.pathComponent)", method: "DELETE", as: JSON.self) }
        catch let error as KitedError where error.status == 404 {}
    }

    /// 项目的布局。
    func layouts(project: String) async throws -> [ProjectLayout] {
        struct Body: Decodable { let layouts: [ProjectLayout] }
        return try await request("/project-registry/\(project.pathComponent)/layouts", as: Body.self).layouts
    }

    /// 新建（不带 expectedRevision）或整体替换一个布局，版本不符 409。
    func putLayout(project: String, id: String, expectedRevision: String?, layout: ProjectLayout.Recipe) async throws -> ProjectLayout {
        struct Body: Encodable { let expectedRevision: String?; let layout: ProjectLayout.Recipe }
        return try await request("/project-registry/\(project.pathComponent)/layouts/\(id.pathComponent)", method: "PUT",
                                 body: Body(expectedRevision: expectedRevision, layout: layout), as: ProjectLayout.self)
    }

    func deleteLayout(project: String, id: String, expectedRevision: String) async throws {
        let query = expectedRevision.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? expectedRevision
        let _: JSON = try await request("/project-registry/\(project.pathComponent)/layouts/\(id.pathComponent)?expectedRevision=\(query)",
                                        method: "DELETE", as: JSON.self)
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

/// 分段上传的进度：各段已发出的字节合起来报比例，一段重传时从零算起。
nonisolated private final class SentBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [Int: Int64] = [:]
    private let total: Int
    private let report: (@Sendable (Double) -> Void)?
    init(total: Int, report: (@Sendable (Double) -> Void)?) { self.total = total; self.report = report }

    func update(_ start: Int, _ bytes: Int64) {
        guard let report else { return }
        let sum = lock.withLock { parts[start] = bytes; return parts.values.reduce(0, +) }
        report(Double(sum) / Double(max(total, 1)))
    }
}

/// 一段的发送进度交给 SentBytes。
nonisolated private final class PartProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let start: Int
    let sent: SentBytes
    init(start: Int, sent: SentBytes) { self.start = start; self.sent = sent }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        sent.update(start, totalBytesSent)
    }
}

/// 按段取的过程中文件被改了：后面几段的版本与第一段对不上，整份重来；三遍都这样时换成 KitedError 交给调用方。
nonisolated private struct FileChanged: Error {}

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
