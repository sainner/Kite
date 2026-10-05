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

/// 预览中保留 effort 控件的档位定义；真实会话尚不提供动态模型配置。
enum Effort: Int, CaseIterable {
    case low, medium, high, extra, max
    var name: String { "\(self)" }
}

/// 工作机拥有窗口集合；当前设备保留布局、草稿及尚未确认的窗口操作。
@Observable
final class WorkArea: Identifiable {
    let id: String
    var remote: RemoteWorkspace?
    var threads: [WorkThread] = []
    var windows: [RemoteWorkspaceWindow] = []
    var instances: [RemotePluginInstance] = []
    var files: [String: FileBrowser] = [:]
    var definitions: [RemotePluginDefinition] = []
    private(set) var pluginClient: KitedClient?
    private(set) var pluginConnection: UUID
    let draftThread: WorkThread
    let layout: WindowLayout
    var creatingThread = false
    var changingWindows = false
    var pendingWindowRequest: OpenWindowRequest?
    var pendingInstanceRequest: CreatePluginInstance?
    var windowError: String?
    var settingsInstance: RemotePluginInstance?
    var tint: Color { .blue }
    var title: String { remote?.workspace.name ?? "新工作区" }
    var header: PaneHeader { PaneHeader(title: title, detail: .text(remote?.project.name ?? "Kite")) }
    var isDraft: Bool { remote == nil }
    var isSample: Bool { SampleWorkspace.enabled && remote?.machine.id == "sample" }

    init(remote: RemoteWorkspace? = nil, client: KitedClient? = nil, definitions: [RemotePluginDefinition] = [], connection: UUID = UUID()) {
        id = remote?.id ?? "draft-workspace"
        pluginConnection = connection
        self.remote = remote
        self.definitions = definitions
        draftThread = WorkThread(workspace: remote?.workspace.cwd ?? "", project: remote?.project.name ?? "Kite")
        if let remote {
            let openWindows = remote.windows.filter { $0.state == .open }
            windows = openWindows
            instances = remote.instances
            layout = WindowLayout(panes: openWindows.map { Pane($0.id) },
                                  storageKey: remote.machine.id == "sample" ? nil : "KiteWindowLayout.\(remote.machine.id).\(remote.id)")
        } else {
            let draft = RemoteWorkspaceWindow(id: "draft-window", workspaceId: id,
                                             target: WindowTarget(instanceId: draftThread.id, viewId: "conversation"), state: .open, createdAt: 0)
            windows = [draft]
            layout = WindowLayout(panes: [Pane(draft.id)])
        }
        if let remote, let client { update(remote, client: client, connection: connection) }
    }

    func update(_ remote: RemoteWorkspace, client: KitedClient, connection: UUID) {
        self.remote = remote
        pluginClient = client
        pluginConnection = connection
        let previous = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        let instancesByID = Dictionary(uniqueKeysWithValues: remote.instances.map { ($0.id, $0) })
        threads = remote.threads.compactMap { value in
            guard let instance = instancesByID[value.instanceId], instance.status == .open else { return nil }
            if let thread = previous[value.instanceId] { thread.title = instance.title; thread.project = remote.project.name; return thread }
            return WorkThread(remote: value, instance: instance, workspace: remote.workspace, project: remote.project.name, client: client)
        }
        instances = remote.instances
        if let settingsInstance, !instances.contains(where: { $0.id == settingsInstance.id && $0.status == .open }) {
            self.settingsInstance = nil
        }
        windows = remote.windows.filter { $0.state == .open }
        layout.reconcile(windows.map { Pane($0.id) })
        draftThread.connected = remote.workspace.status == .open
        updateFiles(client: client)
    }

    func updateFiles(client: KitedClient? = nil) {
        files = Dictionary(uniqueKeysWithValues: instances.filter { $0.definitionId == "kite.files" && $0.status == .open }.map { instance in
            let browser = files[instance.id] ?? FileBrowser(instanceID: instance.id, workspaceID: id, client: client, sample: isSample)
            browser.update(instance, client: client)
            return (instance.id, browser)
        })
    }

    func files(in pane: Pane) -> FileBrowser? {
        guard let target = windows.first(where: { $0.id == pane.id })?.target else { return nil }
        return files[target.instanceId]
    }

    func thread(in pane: Pane) -> WorkThread? {
        guard let target = windows.first(where: { $0.id == pane.id })?.target else { return nil }
        if target.instanceId == draftThread.id { return draftThread }
        guard view(in: pane)?.renderer == "conversation" else { return nil }
        return threads.first { $0.id == target.instanceId }
    }

    func definition(of instance: RemotePluginInstance) -> RemotePluginDefinition? {
        definitions.first { $0.id == instance.definitionId }
    }

    var windowlessInstances: [RemotePluginInstance] {
        let shown = Set(windows.map { $0.target.instanceId })
        return instances.filter { $0.status == .open && !shown.contains($0.id) }
    }

    var minimumSize: CGSize {
        let content = layout.minimumSize
        let entries = layout.docked.count + windowlessInstances.count + 1
        return CGSize(width: content.width, height: max(content.height,
            2 * Metrics.padding + CGFloat(entries) * (Metrics.dragBubble + Metrics.gap) - Metrics.gap))
    }

    func view(in pane: Pane) -> RemotePluginDefinition.PluginView? {
        guard let target = windows.first(where: { $0.id == pane.id })?.target,
              let instance = instances.first(where: { $0.id == target.instanceId }) else { return nil }
        return definition(of: instance)?.views.first { $0.id == target.viewId }
    }

    func appearance(of pane: Pane) -> WindowAppearance {
        if let thread = thread(in: pane) { return .init(name: thread.title, icon: "bubble.left.and.bubble.right", tint: thread.tint, isAgent: true) }
        if let target = windows.first(where: { $0.id == pane.id })?.target,
           let instance = instances.first(where: { $0.id == target.instanceId }) {
            let view = view(in: pane)
            var result = WindowAppearance.renderer(view?.renderer ?? "")
            result.name = instance.title + (target.viewId == definition(of: instance)?.defaultView ? "" : " · " + (view?.title ?? target.viewId))
            return result
        }
        return .init(name: "窗口", icon: "rectangle", tint: .gray)
    }

    func activateWindow(for target: WindowTarget) {
        if let window = windows.first(where: { $0.target == target }) { layout.activate(Pane(window.id)) }
    }
}

struct WindowAppearance {
    var name: String
    let icon: String
    let tint: Color
    var isAgent = false
    var minimizedCornerRadius: CGFloat { isAgent ? Metrics.dragBubble / 2 : Metrics.dockRadius }

    static func renderer(_ id: String) -> Self {
        switch id {
        case "files": .init(name: "文件", icon: "folder", tint: .green)
        case "terminal": .init(name: "终端", icon: "terminal", tint: .gray)
        case "preview": .init(name: "预览", icon: "eye", tint: .orange)
        default: .init(name: "插件", icon: "puzzlepiece.extension", tint: .purple)
        }
    }
}

@Observable
final class AppModel {
    var workspaces: [WorkArea] = []
    var definitions: [RemotePluginDefinition] = []
    var contextTemplates: ContextTemplateCatalog?
    @ObservationIgnored var contextTemplatesRequest: (connection: UUID, task: Task<Void, Error>)?
    let draftWorkspace = WorkArea()
    var selected = ""
    var detached: Set<String> = []
    var pendingPlacement: CGRect?
    var sidebarWidth = Metrics.sidebarWidth
    var sidebarCollapsed = false
    var contentSize: CGSize = .zero
    private(set) var connections = MachineConnections.load()
    private(set) var connectionRevision = UUID()
    var serverAddress: String { connections.selected?.address ?? "http://127.0.0.1:5483" }
    var machine: RemoteMachine? { connections.selected?.machine }
    var connected = false
    var error: String?
    var showConnection = false
    var showNewWorkspace = false
    private let catalogRefresh = CatalogRefresh()
    private var definitionsRequest = UUID()
    private var client: KitedClient? {
        connections.selected.map { KitedClient(address: $0.address, machineID: $0.machine.id) }
    }

    func activeClient() throws -> KitedClient {
        guard let client else { throw KitedError(message: "请先连接工作机") }
        return client
    }

    func refreshDefinitions(_ client: KitedClient) async throws {
        let revision = connectionRevision
        let request = UUID()
        definitionsRequest = request
        let values = try await client.request("/plugin-definitions", as: [RemotePluginDefinition].self)
        try Task.checkCancellation()
        guard client == self.client, revision == connectionRevision else { throw KitedError(message: "工作机已切换") }
        guard request == definitionsRequest else { return }
        definitions = values
        for area in workspaces { area.definitions = values }
    }

    func createInstance(_ definition: RemotePluginDefinition, in area: WorkArea) {
        if !definition.views.isEmpty { openWindow(.create(definition.id), in: area); return }
        if area.isSample {
            SampleWorkspace.openWindow(.init(id: UUID().uuidString, content: .create(definition.id)), in: area)
            return
        }
        guard !area.changingWindows, area.pendingWindowRequest == nil, area.pendingInstanceRequest == nil else { return }
        area.pendingInstanceRequest = CreatePluginInstance(id: UUID().uuidString.lowercased(), definitionId: definition.id)
        retryCreateInstance(in: area)
    }

    func retryCreateInstance(in area: WorkArea) {
        guard let request = area.pendingInstanceRequest, !area.changingWindows else { return }
        area.changingWindows = true
        area.windowError = nil
        Task {
            defer { area.changingWindows = false }
            do {
                let client = try activeClient()
                guard area.remote?.machine.id == client.machineID else { throw KitedError(message: "工作机已切换") }
                let _: RemotePluginInstance = try await client.request("/workspaces/\(area.id)/plugin-instances", method: "POST", body: request, as: RemotePluginInstance.self)
                try await refresh(client)
                guard client == self.client else { return }
                area.pendingInstanceRequest = nil
            } catch {
                if let status = (error as? KitedError)?.status, (400..<500).contains(status) { area.pendingInstanceRequest = nil }
                area.windowError = error.localizedDescription
            }
        }
    }

    private func use(_ saved: MachineConnections) throws {
        let changed = saved.selected != connections.selected
        try saved.save()
        connections = saved
        guard changed else { return }
        catalogRefresh.reset()
        connected = false
        error = nil
        workspaces = []
        definitions = []
        contextTemplates = nil
        contextTemplatesRequest?.task.cancel()
        contextTemplatesRequest = nil
        draftWorkspace.draftThread.contextTemplate = nil
        detached = []
        selected = ""
        draftWorkspace.draftThread.connected = false
        connectionRevision = UUID()
    }

    func addConnection(address: String) async throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let machine = try await KitedClient(address: address).request("/machine", as: RemoteMachine.self)
        try Task.checkCancellation()
        var saved = connections
        saved.remember(machine, address: address)
        try use(saved)
    }

    func selectConnection(_ id: String) throws {
        var saved = connections
        saved.select(id)
        try use(saved)
    }
    var checkouts: [RemoteCheckout] {
        var seen = Set<String>()
        return workspaces.compactMap(\.remote?.checkout).filter { seen.insert($0.id).inserted }
    }
    var knownProjects: [RemoteProject] { connections.knownProjects }

    func projectLabel(_ project: RemoteProject) -> String {
        let machines = connections.entries.filter { $0.projects.contains { $0.id == project.id } }.map(\.machine.name)
        let name = knownProjects.filter { $0.name == project.name }.count > 1
            ? "\(project.name)（\(project.id.prefix(8))）" : project.name
        return ([name] + machines).joined(separator: " · ")
    }

    func connect() async {
        let revision = connectionRevision
        connected = false
        while !Task.isCancelled && revision == connectionRevision {
            let generation = catalogRefresh.reset()
            do {
                if client == nil {
                    let address = serverAddress
                    let machine = try await KitedClient(address: address).request("/machine", as: RemoteMachine.self)
                    try Task.checkCancellation()
                    guard revision == connectionRevision else { return }
                    var saved = connections
                    saved.remember(machine, address: address)
                    try saved.save()
                    connections = saved
                }
                let client = try activeClient()
                try await refreshDefinitions(client)
                guard revision == connectionRevision, generation == catalogRefresh.generation else { return }
                try await client.events { event in
                    try Task.checkCancellation()
                    guard revision == self.connectionRevision, generation == self.catalogRefresh.generation else { return }
                    guard ["catalog.snapshot", "checkout.changed", "workspace.changed", "thread.changed"].contains(event.type) else { return }
                    guard let cursor = event.cursor.flatMap(EventCursor.init) else {
                        throw KitedError(message: "工作区事件数据无效")
                    }
                    if event.type == "catalog.snapshot" {
                        guard event.version == 1, let remote = event.workspaces else {
                            throw KitedError(message: "工作区快照无效")
                        }
                        try self.apply(remote, from: client, cursor: cursor, generation: generation)
                    } else if self.catalogRefresh.needsRefresh(cursor) {
                        try await self.refresh(client)
                    }
                }
            } catch {
                if generation == catalogRefresh.generation { catalogRefresh.reset() }
                if Task.isCancelled || revision != connectionRevision { return }
                connected = false
                self.error = "连不上 kited：\(error.localizedDescription)"
                for workspace in workspaces { workspace.draftThread.connected = false }
                draftWorkspace.draftThread.connected = false
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    func refresh(_ client: KitedClient) async throws {
        guard client == self.client else { return }
        let generation = catalogRefresh.generation
        let result = try await client.requestWithCursor("/workspaces", as: [RemoteWorkspace].self)
        guard let cursor = result.cursor.flatMap(EventCursor.init) else {
            throw KitedError(message: "工作区列表响应无效")
        }
        try apply(result.value, from: client, cursor: cursor, generation: generation)
    }

    private func apply(_ remote: [RemoteWorkspace], from client: KitedClient, cursor: EventCursor, generation: UUID) throws {
        try Task.checkCancellation()
        guard client == self.client else { return }
        try catalogRefresh.apply(cursor, generation: generation) {
            var seenProjects = Set<String>()
            let projects = remote.map(\.project).filter { seenProjects.insert($0.id).inserted }
            if let machineID = client.machineID, connections.selected?.projects != projects {
                var saved = connections
                saved.updateProjects(projects, on: machineID)
                try saved.save()
                connections = saved
            }
            let previous = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
            workspaces = remote.filter { $0.workspace.status != .archived }.reversed().map { value in
                if let area = previous[value.id] { area.definitions = definitions; area.update(value, client: client, connection: generation); return area }
                return WorkArea(remote: value, client: client, definitions: definitions, connection: generation)
            }
            detached.formIntersection(Set(workspaces.map(\.id)))
            if workspace(selected) == nil { selected = workspaces.first?.id ?? "" }
            connected = true
            error = nil
            draftWorkspace.draftThread.connected = true
        }
    }

    func registerCheckout(path: String, projectID: String) async throws -> String {
        struct Registration: Encodable {
            let path: String
            let project: RemoteProject?
        }
        let client = try activeClient()
        let project = knownProjects.first { $0.id == projectID }
        if !projectID.isEmpty && project == nil { throw KitedError(message: "找不到选中的项目，请重新选择") }
        let result = try await client.request("/checkouts", method: "POST", body: Registration(path: path, project: project), as: RemoteWorkspace.self)
        try await refresh(client)
        guard client == self.client else { throw KitedError(message: "工作机已切换") }
        return result.checkout.id
    }

    func create(checkout: String, prompt: String) async throws {
        let client = try activeClient()
        let area = try await client.request("/workspaces", method: "POST",
            body: CreateThreadRequest(prompt: prompt, checkout: checkout, contextTemplate: draftWorkspace.draftThread.contextTemplate?.selection), as: RemoteWorkspace.self)
        try await refresh(client)
        guard client == self.client else { throw KitedError(message: "工作机已切换") }
        selected = area.id
        draftWorkspace.draftThread.draft = ""
        draftWorkspace.draftThread.contextTemplate = nil
    }

    func startThread(in area: WorkArea, prompt: String) async throws {
        let client = try activeClient()
        guard area.remote?.machine.id == client.machineID else { throw KitedError(message: "工作机已切换") }
        let thread = try await client.request("/workspaces/\(area.id)/threads", method: "POST",
            body: CreateThreadRequest(prompt: prompt, contextTemplate: area.draftThread.contextTemplate?.selection), as: RemoteThread.self)
        try await refresh(client)
        guard client == self.client else { throw KitedError(message: "工作机已切换") }
        area.activateWindow(for: WindowTarget(instanceId: thread.instanceId, viewId: "conversation"))
        area.draftThread.draft = ""
        area.draftThread.contextTemplate = nil
    }

    func openWindow(_ content: OpenWindowRequest.Content, in area: WorkArea) {
        if area.isDraft { showNewWorkspace = true; return }
        guard !area.changingWindows else { return }
        if case .open(let target) = content, area.windows.contains(where: { $0.target == target }) {
            area.activateWindow(for: target)
            return
        }
        guard area.pendingWindowRequest == nil, area.pendingInstanceRequest == nil else {
            area.windowError = "请先重试并确认上一次创建操作"
            return
        }
        area.pendingWindowRequest = OpenWindowRequest(id: UUID().uuidString.lowercased(), content: content)
        retryOpenWindow(in: area)
    }

    func retryOpenWindow(in area: WorkArea) {
        guard let request = area.pendingWindowRequest, !area.changingWindows else { return }
        if area.isSample {
            SampleWorkspace.openWindow(request, in: area)
            area.pendingWindowRequest = nil
            return
        }
        area.changingWindows = true
        area.windowError = nil
        Task {
            defer { area.changingWindows = false }
            do {
                let client = try activeClient()
                guard area.remote?.machine.id == client.machineID else { throw KitedError(message: "工作机已切换") }
                let window = try await client.request("/workspaces/\(area.id)/windows", method: "POST", body: request, as: RemoteWorkspaceWindow.self)
                try await refresh(client)
                guard client == self.client else { return }
                area.layout.activate(Pane(window.id))
                area.pendingWindowRequest = nil
            } catch {
                // 明确拒绝可以结束这次请求；网络中断保留同一 ID，供用户安全重试。
                if let status = (error as? KitedError)?.status, (400..<500).contains(status) {
                    area.pendingWindowRequest = nil
                }
                area.windowError = error.localizedDescription
            }
        }
    }

    /// 引用只选择资源；窗口身份仍按现有实例与视图复用。
    func openFileReference(_ reference: FileReference, in area: WorkArea) async throws {
        guard !area.changingWindows else { throw KitedError(message: "窗口正在更新，请稍后重试") }
        guard area.pendingInstanceRequest == nil else { throw KitedError(message: "请先重试并确认上一次创建操作") }
        guard !area.isDraft else { throw KitedError(message: "请先创建工作区") }
        area.changingWindows = true
        defer { area.changingWindows = false }
        let openFile = area.windows.first { area.files[$0.target.instanceId] != nil }
        let instanceID = openFile?.target.instanceId ?? area.instances.first { $0.definitionId == "kite.files" && $0.status == .open }?.id
        let target: WindowTarget
        if let instanceID { target = WindowTarget(instanceId: instanceID, viewId: "files") }
        else {
            let request = area.pendingWindowRequest ?? OpenWindowRequest(id: UUID().uuidString, content: .create("kite.files"))
            guard case .create("kite.files") = request.content else { throw KitedError(message: "请先完成上一次窗口操作") }
            area.pendingWindowRequest = request
            let window = try await openReferenceWindow(request, in: area)
            area.pendingWindowRequest = nil
            target = window.target
        }
        guard let browser = area.files[target.instanceId] else { throw KitedError(message: "文件窗口尚未就绪") }
        try await browser.navigate(reference)
        if area.windows.contains(where: { $0.target == target }) { area.activateWindow(for: target) }
        else {
            let request = area.pendingWindowRequest ?? OpenWindowRequest(id: UUID().uuidString, content: .open(target))
            guard case .open(let pending) = request.content, pending == target else { throw KitedError(message: "请先完成上一次窗口操作") }
            area.pendingWindowRequest = request
            _ = try await openReferenceWindow(request, in: area)
            area.pendingWindowRequest = nil
        }
    }

    private func openReferenceWindow(_ request: OpenWindowRequest, in area: WorkArea) async throws -> RemoteWorkspaceWindow {
        if area.isSample {
            SampleWorkspace.openWindow(request, in: area)
            guard let window = area.windows.first(where: { $0.id == request.id }) else { throw KitedError(message: "无法打开样本文件窗口") }
            return window
        }
        let client = try activeClient()
        guard area.remote?.machine.id == client.machineID else { throw KitedError(message: "工作机已切换") }
        do {
            let window = try await client.request("/workspaces/\(area.id)/windows", method: "POST", body: request, as: RemoteWorkspaceWindow.self)
            try await refresh(client)
            guard client == self.client else { throw KitedError(message: "工作机已切换") }
            area.layout.activate(Pane(window.id))
            return window
        } catch {
            if let status = (error as? KitedError)?.status, (400..<500).contains(status) { area.pendingWindowRequest = nil }
            throw error
        }
    }

    func closeWindow(_ pane: Pane, in area: WorkArea) {
        guard !area.isDraft, !area.changingWindows else { return }
        if area.isSample {
            SampleWorkspace.closeWindow(pane, in: area)
            return
        }
        area.changingWindows = true
        area.windowError = nil
        Task {
            defer { area.changingWindows = false }
            do {
                let client = try activeClient()
                guard area.remote?.machine.id == client.machineID else { throw KitedError(message: "工作机已切换") }
                struct Closed: Decodable { let ok: Bool }
                _ = try await client.request("/workspaces/\(area.id)/windows/\(pane.id)", method: "DELETE", as: Closed.self)
                try await refresh(client)
            } catch { area.windowError = error.localizedDescription }
        }
    }

    var listedWorkspaces: [WorkArea] { workspaces.isEmpty ? [draftWorkspace] : workspaces }
    func workspace(_ id: String) -> WorkArea? { id == draftWorkspace.id ? draftWorkspace : workspaces.first { $0.id == id } }
    var current: WorkArea? {
        if workspaces.isEmpty { return draftWorkspace }
        if !detached.contains(selected), let area = workspace(selected) { return area }
        return workspaces.first { !detached.contains($0.id) }
    }
}
