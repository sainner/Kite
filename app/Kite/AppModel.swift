import SwiftUI

/// 一个真实会话和它的窗口组；显示记录的事实来自 kited，本地只保留草稿与尚未确认的发送。
@Observable
final class Session: Identifiable {
    let id: String
    let tint: Color
    var title: String
    var project: String
    let workspace = Workspace(.oneAndTwo)
    var transcript: Transcript
    var draft = ""
    var state: RemoteState?
    var connected = false
    var error: String?
    var context: Double?
    var changes: (added: Int, removed: Int) = (0, 0)
    private let client: KitedClient?
    // 未识别的块保留位置，后续同 id 的记录替换仍沿用服务端顺序。
    private var records: [Record?] = []
    private var positions: [String: Int] = [:]
    private var received: Set<String> = []
    private var pending: [RemoteInput] = []
    private var outbox: [Message] = []
    private(set) var failed: Set<String> = []
    private var sending: Set<String> = []

    var header: PaneHeader { PaneHeader(title: title, detail: project) }
    var isDraft: Bool { client == nil }
    var canSend: Bool { connected && (isDraft || state?.capabilities.send == true) }
    var canCancel: Bool { connected && state?.capabilities.cancel == true }
    var statusLabel: String {
        if let error { return error }
        guard connected else { return "正在连接" }
        if let error = state?.error { return error }
        switch state?.status {
        case "preparing": return "正在准备工作区"
        case "prepare_failed": return "工作区准备失败"
        case "archived": return "已归档"
        default: break
        }
        switch state?.phase {
        case "running": return "正在工作"
        case "stopping", "finishing": return "正在收尾"
        case "paused": return "已暂停"
        case "needs_recovery": return "需要在工作机确认恢复"
        default: return "空闲"
        }
    }

    init(remote: RemoteSession, project: String, client: KitedClient) {
        id = remote.id
        tint = .blue
        title = remote.title
        self.project = project
        self.client = client
        transcript = Transcript(root: remote.worktree)
    }

    /// 尚未创建的会话沿用同一套工作区，只保存草稿，不制造后端记录。
    init() {
        id = "draft"
        tint = .blue
        title = "新会话"
        project = "Kite"
        client = nil
        transcript = Transcript(root: "")
    }

    func observe() async {
        guard let client else { return }
        defer { connected = false }
        while !Task.isCancelled {
            do {
                try await client.events(session: id) { event in try self.apply(event) }
            } catch {
                if Task.isCancelled { return }
                connected = false
                self.error = "连接中断，正在重连：\(error.localizedDescription)"
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    private func apply(_ event: RemoteEvent) throws {
        switch event.type {
        case "history":
            guard event.version == 1 else { throw KitedError(message: "会话协议版本不兼容") }
            let history = event.records ?? []
            records = history.map(\.record)
            positions = Dictionary(uniqueKeysWithValues: history.enumerated().map { ($0.element.id, $0.offset) })
            received = Set(history.compactMap { $0.block.type == "human" ? $0.block.id : nil })
            pending = event.pending ?? []
            state = event.state
            connected = true
            error = nil
        case "record":
            guard let record = event.record else { return }
            if let index = positions[record.id] { records[index] = record.record }
            else { positions[record.id] = records.count; records.append(record.record) }
            if record.block.type == "human", let id = record.block.id {
                received.insert(id)
                pending.removeAll { $0.id == id }
            }
        case "pending": pending = event.pending ?? []
        case "state": state = event.state
        case "error": error = event.message
        default: return
        }
        let pendingIDs = Set(pending.map(\.id))
        let confirmed = Set(outbox.map(\.id)).union(failed).filter { received.contains($0) || pendingIDs.contains($0) }
        outbox.removeAll { confirmed.contains($0.id) }
        if !failed.isDisjoint(with: confirmed) { error = nil }
        failed.subtract(confirmed)
        render(recordsChanged: event.type == "history" || event.type == "record")
    }

    private func render(recordsChanged: Bool = false) {
        let running = state?.busy == true && ["running", "stopping", "finishing"].contains(state?.phase ?? "")
        let messages = pending.filter { $0.source == "human" }.map(\.message) + outbox
        if recordsChanged {
            transcript = Transcript(root: transcript.root, records: records.compactMap { $0 }, running: running, pending: messages)
        } else {
            if transcript.running != running { transcript.running = running }
            transcript.pending = messages
        }
    }

    func send(_ message: Message) -> Bool {
        guard !isDraft, canSend else { return false }
        let startsTurn = !transcript.running && transcript.pending.isEmpty
        var queued = message
        queued.midTurn = !startsTurn
        outbox.append(queued)
        render()
        deliver(message)
        return startsTurn
    }

    func retry(_ message: Message) { deliver(message) }

    private func deliver(_ message: Message) {
        guard let client, !sending.contains(message.id) else { return }
        sending.insert(message.id)
        failed.remove(message.id)
        error = nil
        Task {
            defer { sending.remove(message.id) }
            do { try await client.post("/sessions/\(id)/messages", body: ["id": message.id, "text": message.typed]) }
            catch { failed.insert(message.id); self.error = "发送未确认，点消息重试：\(error.localizedDescription)" }
        }
    }

    func cancel(_ message: Message, editing: Bool = false) {
        guard let client, canCancel, !sending.contains(message.id) else { return }
        Task {
            do {
                // HTTP 返回失败也可能已经落盘，先由服务核查是否仍能撤回。
                try await client.post("/sessions/\(id)/messages/\(message.id)/cancel")
                outbox.removeAll { $0.id == message.id }
                pending.removeAll { $0.id == message.id }
                failed.remove(message.id)
                if editing { draft = message.typed + (draft.isEmpty ? "" : "\n" + draft) }
                error = nil
                render()
            } catch { self.error = error.localizedDescription }
        }
    }

    func control(_ action: String) {
        guard let client else { return }
        Task {
            do { try await client.post("/sessions/\(id)/\(action)"); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// 预览中保留 effort 控件的档位定义；真实会话尚不提供动态模型配置。
enum Effort: Int, CaseIterable {
    case low, medium, high, extra, max
    var name: String { "\(self)" }
}

@Observable
final class AppModel {
    var sessions: [Session] = []
    let draftSession = Session()
    var projects: [RemoteProject] = []
    var selected = ""
    var detached: Set<String> = []
    var pendingPlacement: CGRect?
    var sidebarWidth = Metrics.sidebarWidth
    var sidebarCollapsed = false
    var contentSize: CGSize = .zero
    var serverAddress = UserDefaults.standard.string(forKey: "KitedURL") ?? "http://127.0.0.1:5483"
    var connected = false
    private var connectedAddress: String?
    var error: String?
    var showConnection = false
    var showNewSession = false
    var client: KitedClient { KitedClient(address: serverAddress) }

    func connect() async {
        if connectedAddress != serverAddress {
            sessions = []
            projects = []
            detached = []
            connectedAddress = serverAddress
        }
        connected = false
        draftSession.connected = false
        let client = client
        UserDefaults.standard.set(serverAddress, forKey: "KitedURL")
        while !Task.isCancelled {
            do {
                try await client.events { event in
                    if ["ready", "status"].contains(event.type) { try await self.refresh(client) }
                }
            } catch {
                if Task.isCancelled { return }
                connected = false
                self.error = "连不上 kited：\(error.localizedDescription)"
                draftSession.connected = false
                draftSession.error = self.error
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    func refresh(_ client: KitedClient) async throws {
        async let projectRequest = client.request("/projects", as: [RemoteProject].self)
        async let sessionRequest = client.request("/sessions", as: [RemoteSession].self)
        let (projects, remote) = try await (projectRequest, sessionRequest)
        try Task.checkCancellation()
        self.projects = projects
        let names = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
        sessions = remote.reversed().map { value in
            if let existing = session(value.id) { existing.title = value.title; return existing }
            return Session(remote: value, project: names[value.projectId] ?? value.projectId, client: client)
        }
        if session(selected) == nil { selected = sessions.first?.id ?? "" }
        connected = true
        error = nil
        draftSession.connected = true
        draftSession.error = nil
    }

    func register(path: String) async throws {
        try await client.post("/projects", body: ["path": path])
        try await refresh(client)
    }

    func create(project: String, prompt: String) async throws {
        let session = try await client.request("/sessions", method: "POST", body: ["project": project, "prompt": prompt], as: RemoteSession.self)
        try await refresh(client)
        selected = session.id
        draftSession.draft = ""
    }

    var listedSessions: [Session] { sessions.isEmpty ? [draftSession] : sessions }

    func session(_ id: String) -> Session? { id == draftSession.id ? draftSession : sessions.first { $0.id == id } }
    var current: Session? {
        if sessions.isEmpty { return draftSession }
        if !detached.contains(selected), let session = session(selected) { return session }
        return sessions.first { !detached.contains($0.id) }
    }
}
