import SwiftUI

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
