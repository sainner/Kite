import SwiftUI

/// 一个真实线程；显示记录的事实来自 kited，本地只保留草稿与尚未确认的发送。
@Observable
final class WorkThread: Identifiable {
    let id: String
    let tint: Color
    var title: String
    var project: String
    var transcript: Transcript
    var draft = ""
    var contextTemplate: ContextTemplate?
    var configuringTemplate = false
    var isStreamingPreview = false
    var previewRun = 0
    var state: RemoteState?
    var agentCapabilities: AgentCapabilities?
    var connected = false
    var error: String?
    private(set) var regeneratingTitle = false
    private let client: KitedClient?
    // 未识别的块保留位置，后续同 id 的记录替换仍沿用服务端顺序。
    private var remoteRecords: [RemoteRecord] = []
    private var visiblePositions: [Int: Int] = [:]
    private var streamingChanges: Set<Int> = []
    private var streamingRefresh: Task<Void, Never>?
    private var positions: [String: Int] = [:]
    private var received: Set<String> = []
    private var pending: [RemoteInput] = []
    private var outbox: [Message] = []
    private(set) var failed: Set<String> = []
    private var sending: Set<String> = []
    private var returned: Set<String> = []
    private var stopRequest: StopRequest?
    private(set) var stopping = false
    private var submittedDraft: (id: UUID, text: String)?

    var isDraft: Bool { client == nil }
    var canSend: Bool { stopRequest == nil && connected && (state?.capabilities.send ?? isDraft) }
    var canResume: Bool { stopRequest == nil && connected && state?.capabilities.resume == true }
    var canStop: Bool { connected && !stopping && showStop }
    var hasUnconfirmedStop: Bool { stopRequest != nil }
    var showStop: Bool { stopRequest != nil || !outbox.isEmpty || state?.capabilities.interrupt == true }
    var canCancel: Bool { stopRequest == nil && connected && state?.capabilities.cancel == true }
    var canRegenerateTitle: Bool { !isDraft && connected && state?.status == "open" && !regeneratingTitle }
    var statusPhase: String { stopping ? "stopping" : state?.phase ?? "idle" }
    var statusLabel: String {
        if let error { return error }
        if isDraft && state == nil { return "空闲" }
        guard connected else { return "正在连接" }
        if stopping { return "正在停止" }
        if let recovery = state?.recovery { return recovery.message }
        if let error = state?.error { return error }
        switch state?.status {
        case "preparing": return "正在准备工作区"
        case "failed": return "工作区准备失败"
        case "archived": return "已归档"
        default: break
        }
        switch state?.phase {
        case "running": return "运行中"
        case "stopping": return "正在停止"
        case "finishing": return "正在收尾"
        default:
            if state?.lastOutcome?.kind == "failed" { return state?.lastOutcome?.message ?? "本轮失败" }
            if state?.lastOutcome?.kind == "interrupted" { return "已停止" }
            if state?.lastOutcome?.kind == "completed" { return "已完成" }
            if state?.waitingForResume == true { return "等待继续" }
            return "空闲"
        }
    }

    init(remote: RemoteThread, instance: RemotePluginInstance, workspace: WorkspaceInfo, project: String, client: KitedClient) {
        id = remote.instanceId
        tint = .blue
        title = instance.title
        self.project = project
        self.client = client
        transcript = Transcript(root: workspace.cwd)
    }

    /// 尚未创建的会话沿用同一套工作区，只保存草稿，不制造后端记录。
    init(workspace: String = "", project: String = "Kite") {
        id = "draft-" + workspace
        tint = .blue
        title = "新会话"
        self.project = project
        client = nil
        transcript = Transcript(root: workspace)
    }

    func observe() async {
        guard let client else { return }
        defer { flushStreaming(); connected = false }
        while !Task.isCancelled {
            do {
                try await client.events(scope: .thread(id)) { event in try self.apply(event) }
            } catch {
                if Task.isCancelled { return }
                flushStreaming()
                connected = false
                self.error = "连接中断，正在重连：\(error.localizedDescription)"
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    func apply(_ event: RemoteEvent) throws {
        guard event.threadId == id else { return }
        if event.type != "thread.record.delta" { flushStreaming() }
        var recordsChanged = false
        switch event.type {
        case "thread.history":
            guard event.version == 1 else { throw KitedError(message: "会话协议版本不兼容") }
            let history = event.records ?? []
            remoteRecords = history
            positions = Dictionary(uniqueKeysWithValues: history.enumerated().map { ($0.element.id, $0.offset) })
            received = Set(history.compactMap { $0.block.type == "human" ? $0.block.id : nil })
            pending = event.pending ?? []
            state = event.state
            connected = true
            error = nil
            recordsChanged = true
        case "thread.record":
            guard let record = event.record else { return }
            if let index = positions[record.id] {
                remoteRecords[index] = record
                if let visibleIndex = visiblePositions[index], let visible = record.record {
                    transcript.replaceRecord(at: visibleIndex, with: visible)
                } else {
                    recordsChanged = true
                }
            } else {
                positions[record.id] = remoteRecords.count
                remoteRecords.append(record)
                recordsChanged = true
            }
            if record.block.type == "human", let id = record.block.id {
                received.insert(id)
                pending.removeAll { $0.id == id }
            }
        case "thread.record.delta":
            guard let delta = event.delta, let index = positions[delta.id] else {
                throw KitedError(message: "流式记录缺失，重新同步")
            }
            try remoteRecords[index].apply(delta)
            streamingChanges.insert(index)
            if streamingRefresh == nil {
                streamingRefresh = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                    self?.flushStreaming()
                }
            }
            return
        case "thread.pending": pending = event.pending ?? []
        case "thread.state": state = event.state
        case "thread.error": error = event.message
        default: return
        }
        pending.removeAll { returned.contains($0.id) }
        let pendingIDs = Set(pending.map(\.id))
        let confirmed = Set(outbox.map(\.id)).union(failed).filter { received.contains($0) || pendingIDs.contains($0) }
        outbox.removeAll { confirmed.contains($0.id) }
        if !failed.isDisjoint(with: confirmed) { error = nil }
        failed.subtract(confirmed)
        render(recordsChanged: recordsChanged)
    }

    private func flushStreaming() {
        streamingRefresh?.cancel()
        streamingRefresh = nil
        for index in streamingChanges.sorted() {
            guard let visibleIndex = visiblePositions[index], let record = remoteRecords[index].record else { continue }
            transcript.replaceRecord(at: visibleIndex, with: record)
        }
        streamingChanges.removeAll(keepingCapacity: true)
    }

    private func render(recordsChanged: Bool = false) {
        let running = state?.busy == true && ["running", "stopping", "finishing"].contains(state?.phase ?? "")
        let messages = pending.filter { $0.source == "human" }.map(\.message) + outbox
        if recordsChanged {
            var records: [Record] = []
            visiblePositions.removeAll(keepingCapacity: true)
            for (index, remote) in remoteRecords.enumerated() {
                guard let record = remote.record else { continue }
                visiblePositions[index] = records.count
                records.append(record)
            }
            transcript = Transcript(root: transcript.root, records: records, running: running, pending: messages)
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
        guard let client, stopRequest == nil, !returned.contains(message.id), !sending.contains(message.id) else { return }
        sending.insert(message.id)
        failed.remove(message.id)
        error = nil
        Task {
            defer { sending.remove(message.id) }
            do { try await client.post("/threads/\(id)/messages", body: ["id": message.id, "text": message.typed]) }
            catch {
                guard !returned.contains(message.id), !received.contains(message.id),
                      !pending.contains(where: { $0.id == message.id }) else { return }
                failed.insert(message.id); self.error = "发送未确认，点消息重试：\(error.localizedDescription)"
            }
        }
    }

    func cancel(_ message: Message, editing: Bool = false) {
        guard let client, canCancel, !sending.contains(message.id) else { return }
        Task {
            do {
                // HTTP 返回失败也可能已经落盘，先由服务核查是否仍能撤回。
                try await client.post("/threads/\(id)/messages/\(message.id)/cancel")
                outbox.removeAll { $0.id == message.id }
                pending.removeAll { $0.id == message.id }
                failed.remove(message.id)
                if editing { restoreDraft([message.typed]) }
                error = nil
                render()
            } catch { self.error = error.localizedDescription }
        }
    }

    /// 淡出动画尚未结束时停止，也必须先扣除已提交部分，再恢复队列。
    func beginDraftSubmission() -> UUID {
        let token = UUID()
        submittedDraft = (token, draft)
        return token
    }

    func finishDraftSubmission(_ token: UUID) {
        guard let submission = submittedDraft, submission.id == token else { return }
        if draft.hasPrefix(submission.text) { draft.removeFirst(submission.text.count) }
        submittedDraft = nil
    }

    private func restoreDraft(_ texts: [String]) {
        if let submission = submittedDraft { finishDraftSubmission(submission.id) }
        draft = (texts + (draft.isEmpty ? [] : [draft])).joined(separator: "\n\n")
    }

    func stop() {
        guard canStop else { return }
        _ = try? startStop()
    }

    /// 设置页也能停止没有展开窗口的会话，沿用同一收据与队列退回逻辑。
    func stopAndWait() async throws {
        try await startStop().value
    }

    private func startStop() throws -> Task<Void, Error> {
        guard let client, !stopping else { throw KitedError(message: "会话尚不可停止，请刷新状态后重试") }
        let request = stopRequest ?? StopRequest(id: UUID().uuidString, inputs: outbox.map {
            RemoteInput(id: $0.id, text: $0.typed, source: "human")
        })
        // 同步冻结收据，点击停止后立即阻止继续发送或重复停止。
        stopRequest = request
        stopping = true
        return Task {
            defer { stopping = false }
            do {
                let response = try await client.request("/threads/\(id)/interrupt", method: "POST", body: request, as: StopResponse.self)
                let fresh = response.returned.filter { !returned.contains($0.id) }
                returned.formUnion(fresh.map(\.id))
                outbox.removeAll { returned.contains($0.id) }
                pending.removeAll { returned.contains($0.id) }
                failed.subtract(returned)
                restoreDraft(fresh.map(\.text))
                stopRequest = nil
                error = nil
                render()
            } catch {
                self.error = "停止尚未确认，请再次点停止重试：\(error.localizedDescription)"
                throw error
            }
        }
    }

    func regenerateTitle() async throws {
        guard let client, canRegenerateTitle else { return }
        regeneratingTitle = true
        defer { regeneratingTitle = false }
        let path = "/threads/\(id)/title"
        let snapshot = try await client.request(path, as: ThreadTitleSnapshot.self)
        guard connected, state?.status == "open" else { throw KitedError(message: "会话连接或状态已变化，请重试") }
        // 标题正文沿目录事件同步，避免迟到的 HTTP 响应覆盖更新的远端标题。
        let _: ThreadTitleSnapshot = try await client.request(path + "/regenerate", method: "POST",
            body: ["expectedRevision": snapshot.revision], timeout: 120, as: ThreadTitleSnapshot.self)
    }

    func control(_ action: String) {
        guard let client else { return }
        Task {
            do { try await client.post("/threads/\(id)/\(action)"); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// 控件的刻度顺序；可选档位由服务端模型能力筛选。
enum Effort: Int, CaseIterable {
    case low, medium, high, extra, max
    var name: String { self == .extra ? "xhigh" : "\(self)" }
}
