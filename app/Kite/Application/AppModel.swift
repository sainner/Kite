import SwiftUI

@Observable
final class AppModel {
    var workspaces: [WorkArea] = []
    let draftWorkspace = WorkArea()
    var selected = ""
    var selectedProjectID: String?
    var detached: Set<String> = []
    var pendingPlacement: CGRect?
    var sidebarWidth = Metrics.sidebarWidth
    var sidebarCollapsed = false
    /// 各订阅账号（如 ChatGPT、Claude）本周还剩多少额度；后端还没上报，目前只有预览数据填它。
    var subscriptionQuotas: [SubscriptionQuota] = []
    /// 侧栏底部一级导航选中的一栏。
    var sidebarSection = SidebarSection.workspaces
    var contentSize: CGSize = .zero
    let account: KiteAccount
    private let previewClient: KitedClient?
    private(set) var connections: [String: WorkerConnection] = [:]
    private var connectionRun: UUID?
    private let emptyConnection = UUID()
    private var sampleTemplates: ContextTemplateCatalog?
    var activeConnection: WorkerConnection? {
        if let id = current?.remote?.machine.id { return connections[id] }
        return connections.values.sorted { $0.machine.id < $1.machine.id }.first(where: { $0.connected })
    }
    var machine: RemoteMachine? { activeConnection?.machine }
    var connected: Bool { activeConnection?.connected == true }
    var connectionRevision: UUID { activeConnection?.catalog.generation ?? emptyConnection }
    var definitions: [RemotePluginDefinition] { activeConnection?.definitions ?? [] }
    var contextTemplates: ContextTemplateCatalog? {
        get { SampleWorkspace.enabled ? sampleTemplates : activeConnection?.templates }
        set { if SampleWorkspace.enabled { sampleTemplates = newValue } else { activeConnection?.templates = newValue } }
    }
    var error: String?
    #if os(iOS)
    /// 扫码登录的进度；后台重连的错误不覆盖它。
    enum InviteState: Equatable { case joining, failed(String) }
    var invite: InviteState?
    #endif
    /// 正在打开的新建表单：添加项目或开始会话。
    var newWorkspace: NewWorkspace.Mode?
    /// 扩展一栏在内容区显示的页面。
    var extensionPage = ExtensionLibrary.plugins
    /// 设置一栏在内容区显示的页面。
    var settingsPage = SettingsPage.appearance

    var selectedProject: RemoteProject? {
        guard let selectedProjectID else { return nil }
        return knownProjects.first { $0.id == selectedProjectID }
    }

    func selectProject(_ id: String) {
        sidebarSection = .workspaces
        selectedProjectID = id
    }

    func selectWorkspace(_ id: String) {
        selectedProjectID = nil
        selected = id
    }

    /// 切到设置一栏。
    func openSettings(_ page: SettingsPage? = nil) {
        sidebarSection = .settings
        if let page { settingsPage = page }
    }
    /// 侧栏菜单发起的现场推送与归档确认，由 WorkspaceGitPresentation 呈现。
    var scenePush: WorkArea?
    var archiveRequest: WorkArea?

    init(account: KiteAccount = KiteAccount(), previewClient: KitedClient? = nil) {
        self.account = account
        self.previewClient = previewClient
    }

    func connection(for area: WorkArea? = nil) -> WorkerConnection? {
        guard let area, !area.isDraft else { return activeConnection }
        return area.remote.flatMap { connections[$0.machine.id] }
    }

    func revision(for area: WorkArea) -> UUID { connection(for: area)?.catalog.generation ?? emptyConnection }
    func isConnected(_ area: WorkArea) -> Bool { area.isSample || connection(for: area)?.connected == true }

    func activeClient(in area: WorkArea? = nil) throws -> KitedClient {
        if let previewClient, (area ?? current)?.isSample == true { return previewClient }
        guard let connection = connection(for: area), connection.connected else { throw KitedError(message: "所属工作机未连接") }
        return connection.client
    }

    func accepts(_ client: KitedClient) -> Bool {
        guard let id = client.machineID else { return false }
        return connections[id]?.client == client && account.ready
    }

    func refreshDefinitions(_ client: KitedClient) async throws {
        guard let id = client.machineID, let connection = connections[id] else { return }
        let revision = connection.catalog.generation
        let request = UUID()
        connection.definitionsRequest = request
        let values = try await client.request("/plugin-definitions", as: [RemotePluginDefinition].self)
        try Task.checkCancellation()
        guard accepts(client), revision == connection.catalog.generation, connection.definitionsRequest == request else { return }
        connection.definitions = values
        for area in workspaces where area.remote?.machine.id == id { area.definitions = values }
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
                let client = try activeClient(in: area)
                guard area.remote?.machine.id == client.machineID else { throw KitedError(message: "工作机已切换") }
                let _: RemotePluginInstance = try await client.request("/workspaces/\(area.id)/plugin-instances", method: "POST", body: request, as: RemotePluginInstance.self)
                try await refresh(client)
                guard accepts(client) else { return }
                area.pendingInstanceRequest = nil
            } catch {
                if let status = (error as? KitedError)?.status, (400..<500).contains(status) { area.pendingInstanceRequest = nil }
                area.windowError = error.localizedDescription
            }
        }
    }

    #if os(iOS)
    /// iPhone 扫描已登录设备显示的二维码，获得独立账号会话并入网。
    func acceptInvite(_ url: URL) async {
        guard url.scheme == "kite", url.host() == "join", invite != .joining else { return }
        invite = .joining
        do {
            try await account.accept(url)
            try await account.join(role: "controller", name: Self.deviceName)
            invite = nil
        } catch { invite = .failed(error.localizedDescription) }
    }
    #endif

    #if os(macOS)
    static var deviceName: String { Host.current().localizedName ?? "Mac" }
    #else
    static var deviceName: String { UIDevice.current.name }
    #endif

    func clearAccountConnections() {
        connectionRun = nil
        stopConnections()
        connections = [:]
        workspaces = []
        detached = []
        selectedProjectID = nil
        selected = ""
        draftWorkspace.draftThread.contextTemplate = nil
        draftWorkspace.draftThread.connected = false
    }

    var checkouts: [RemoteCheckout] {
        var seen = Set<String>()
        return workspaces.compactMap(\.remote?.checkout).filter { seen.insert($0.id).inserted }
    }
    var knownProjects: [RemoteProject] {
        var seen = Set<String>()
        return (account.catalogs.flatMap { $0.snapshot?.projects ?? [] } + workspaces.compactMap(\.remote?.project))
            .filter { seen.insert($0.id).inserted }
    }
    var availableWorkers: [WorkerConnection] { connections.values.filter(\.connected).sorted { $0.machine.name < $1.machine.name } }

    func projectLabel(_ project: RemoteProject) -> String {
        knownProjects.filter { $0.name == project.name }.count > 1 ? "\(project.name)（\(project.id.prefix(8))）" : project.name
    }

    /// 账号目录决定设备集合；各机事件流、错误与游标独立存续。
    func connect() async {
        guard account.ready else { return }
        let run = UUID()
        connectionRun = run
        mergeDirectory()
        startConnections()
        defer { if connectionRun == run { stopConnections(); connectionRun = nil } }
        while !Task.isCancelled && account.ready && connectionRun == run {
            do { try await account.resume() }
            catch { account.error = error.localizedDescription }
            guard !Task.isCancelled, account.ready, connectionRun == run else { return }
            mergeDirectory()
            startConnections()
            let unknown = account.workers.filter { device in !connections.values.contains { $0.deviceID == device.id } }
            await withTaskGroup(of: Void.self) { group in
                for device in unknown {
                    group.addTask { await self.discover(device) }
                }
            }
            guard !Task.isCancelled, account.ready, connectionRun == run else { return }
            startConnections()
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
        }
    }

    func startConnections() {
        for connection in connections.values where connection.task == nil {
            connection.task = Task { await self.follow(connection) }
        }
    }

    private func address(_ device: AccountDevice) -> String? {
        device.id == account.deviceID && account.role == "worker" ? "http://127.0.0.1:5483" : device.address
    }

    private func discover(_ device: AccountDevice) async {
        guard let address = address(device) else { return }
        do {
            let machine = try await KitedClient(address: address).request("/machine", timeout: 10, as: RemoteMachine.self)
            try Task.checkCancellation()
            guard account.workers.contains(where: { $0.id == device.id }), connections[machine.id] == nil else { return }
            connections[machine.id] = WorkerConnection(deviceID: device.id, machine: machine, address: address)
            startConnections()
        } catch { /* 单台工作机暂不可达不阻塞其他设备的目录。 */ }
    }

    func mergeDirectory() {
        let devices = Set(account.devices.map(\.id))
        for (id, connection) in connections where !devices.contains(connection.deviceID) {
            connection.task?.cancel()
            connection.catalog.reset()
            connections.removeValue(forKey: id)
            workspaces.removeAll { $0.remote?.machine.id == id }
        }
        for entry in account.catalogs {
            guard let snapshot = entry.snapshot, let address = address(entry.device) else { continue }
            let connection = connections[entry.machineId] ?? WorkerConnection(deviceID: entry.device.id, machine: snapshot.machine, address: address)
            if connection.client.address != address {
                connection.task?.cancel(); connection.task = nil
                connection.catalog.reset(); connection.connected = false
                connection.client = KitedClient(address: address, machineID: entry.machineId)
            }
            connections[entry.machineId] = connection
            connection.updatedAt = entry.updatedAt
            if !connection.hasLiveCatalog {
                let previous = Dictionary(uniqueKeysWithValues: workspaces.filter { $0.remote?.machine.id == entry.machineId }.map { ($0.id, $0) })
                let summaries = snapshot.summaries.filter { $0.workspace.status != .archived }
                let areas = summaries.map { remote -> WorkArea in
                    let area = previous[remote.id] ?? WorkArea(remote: remote)
                    area.remote = remote
                    area.draftThread.connected = false
                    return area
                }
                replaceWorkspaces(areas, on: entry.machineId)
            }
        }
        detached.formIntersection(Set(workspaces.map(\.id)))
        if workspace(selected) == nil { selected = workspaces.first?.id ?? "" }
    }

    private func stopConnections() {
        for connection in connections.values {
            connection.task?.cancel(); connection.task = nil
            connection.templatesRequest?.task.cancel(); connection.templatesRequest = nil
            connection.catalog.reset(); connection.connected = false
            for area in workspaces where area.remote?.machine.id == connection.id { area.draftThread.connected = false }
        }
    }

    private func follow(_ connection: WorkerConnection) async {
        let client = connection.client
        while !Task.isCancelled && accepts(client) {
            let generation = connection.catalog.reset()
            do {
                try await refreshDefinitions(client)
                try await client.events { event in
                    try Task.checkCancellation()
                    guard self.accepts(client), generation == connection.catalog.generation else { return }
                    guard ["catalog.snapshot", "checkout.changed", "workspace.changed", "thread.changed"].contains(event.type) else { return }
                    guard let cursor = event.cursor.flatMap(EventCursor.init) else { throw KitedError(message: "工作区事件数据无效") }
                    if event.type == "catalog.snapshot" {
                        guard event.version == 1, let remote = event.workspaces else { throw KitedError(message: "工作区快照无效") }
                        try self.apply(remote, from: client, cursor: cursor, generation: generation)
                    } else if connection.catalog.needsRefresh(cursor) { try await self.refresh(client) }
                }
            } catch {
                guard !Task.isCancelled, accepts(client), generation == connection.catalog.generation else { return }
                connection.connected = false
                connection.error = error.localizedDescription
                for area in workspaces where area.remote?.machine.id == connection.id { area.draftThread.connected = false }
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    func refresh(_ client: KitedClient) async throws {
        guard let id = client.machineID, let connection = connections[id], accepts(client) else { return }
        let generation = connection.catalog.generation
        let result = try await client.requestWithCursor("/workspaces", as: [RemoteWorkspace].self)
        guard let cursor = result.cursor.flatMap(EventCursor.init) else { throw KitedError(message: "工作区列表响应无效") }
        try apply(result.value, from: client, cursor: cursor, generation: generation)
    }

    private func apply(_ remote: [RemoteWorkspace], from client: KitedClient, cursor: EventCursor, generation: UUID) throws {
        try Task.checkCancellation()
        guard let id = client.machineID, let connection = connections[id], accepts(client) else { return }
        guard remote.allSatisfy({ $0.machine.id == id && $0.checkout.machineId == id }) else { throw KitedError(message: "工作区所属机器不匹配") }
        try connection.catalog.apply(cursor, generation: generation) {
            let previous = Dictionary(uniqueKeysWithValues: workspaces.filter { $0.remote?.machine.id == id }.map { ($0.id, $0) })
            let areas = remote.filter { $0.workspace.status != .archived }.reversed().map { value in
                if let area = previous[value.id] {
                    area.definitions = connection.definitions
                    area.update(value, client: client, connection: generation)
                    return area
                }
                return WorkArea(remote: value, client: client, definitions: connection.definitions, connection: generation)
            }
            replaceWorkspaces(areas, on: id)
            connection.hasLiveCatalog = true
            connection.connected = true
            connection.error = nil
        }
    }

    private func replaceWorkspaces(_ areas: [WorkArea], on machine: String) {
        workspaces = workspaces.filter { $0.remote?.machine.id != machine } + areas
        workspaces.sort {
            let left = $0.remote?.workspace.createdAt ?? 0, right = $1.remote?.workspace.createdAt ?? 0
            return left == right ? $0.id < $1.id : left > right
        }
        detached.formIntersection(Set(workspaces.map(\.id)))
        if workspace(selected) == nil { selected = workspaces.first?.id ?? "" }
    }

    /// 项目由工作机按目录的远程登记；没有远程的目录由工作机建托管远程。
    func registerCheckout(path: String, machineID: String) async throws -> String {
        struct Registration: Encodable { let path: String }
        return try await addCheckout(Registration(path: path), machineID: machineID, timeout: 120)
    }

    /// 在工作机上 clone 远程并登记；path 为空时放在工作机的 ~/code/域名/owner/repo。
    func cloneCheckout(remote: String, path: String?, machineID: String) async throws -> String {
        struct Clone: Encodable { let remote: String; let path: String? }
        return try await addCheckout(Clone(remote: remote.trimmingCharacters(in: .whitespaces), path: path), machineID: machineID, timeout: 1800)
    }

    private func addCheckout(_ body: any Encodable, machineID: String, timeout: TimeInterval) async throws -> String {
        guard let connection = connections[machineID], connection.connected else { throw KitedError(message: "工作机未连接") }
        let client = connection.client
        let result = try await client.request("/checkouts", method: "POST", body: body, timeout: timeout, as: RemoteWorkspace.self)
        try await refresh(client)
        guard accepts(client) else { throw KitedError(message: "工作机已切换") }
        return result.checkout.id
    }

    func create(checkout: String, prompt: String) async throws {
        guard let machine = checkouts.first(where: { $0.id == checkout })?.machineId,
              let connection = connections[machine], connection.connected else { throw KitedError(message: "检出所属工作机未连接") }
        let client = connection.client
        let template = draftWorkspace.draftThread.contextTemplate
        if let template, connection.templates?.templates.contains(where: { $0.id == template.id && $0.revision == template.revision }) != true {
            throw KitedError(message: "所选上下文模板不属于这台工作机，请重新选择")
        }
        let area = try await client.request("/workspaces", method: "POST",
            body: CreateThreadRequest(prompt: prompt, checkout: checkout, contextTemplate: template?.selection), as: RemoteWorkspace.self)
        try await refresh(client)
        guard accepts(client) else { throw KitedError(message: "工作机已切换") }
        selectWorkspace(area.id)
        draftWorkspace.draftThread.draft = ""
        draftWorkspace.draftThread.contextTemplate = nil
    }

    func startThread(in area: WorkArea, prompt: String) async throws {
        let client = try activeClient(in: area)
        guard area.remote?.machine.id == client.machineID else { throw KitedError(message: "工作机已切换") }
        let thread = try await client.request("/workspaces/\(area.id)/threads", method: "POST",
            body: CreateThreadRequest(prompt: prompt, contextTemplate: area.draftThread.contextTemplate?.selection), as: RemoteThread.self)
        try await refresh(client)
        guard accepts(client) else { throw KitedError(message: "工作机已切换") }
        area.activateWindow(for: WindowTarget(instanceId: thread.instanceId, viewId: "conversation"))
        area.draftThread.draft = ""
        area.draftThread.contextTemplate = nil
    }

    func openWindow(_ content: OpenWindowRequest.Content, in area: WorkArea) {
        if area.isDraft { newWorkspace = .session; return }
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
                let client = try activeClient(in: area)
                guard area.remote?.machine.id == client.machineID else { throw KitedError(message: "工作机已切换") }
                let window = try await client.request("/workspaces/\(area.id)/windows", method: "POST", body: request, as: RemoteWorkspaceWindow.self)
                try await refresh(client)
                guard accepts(client) else { return }
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
        let client = try activeClient(in: area)
        guard area.remote?.machine.id == client.machineID else { throw KitedError(message: "工作机已切换") }
        do {
            let window = try await client.request("/workspaces/\(area.id)/windows", method: "POST", body: request, as: RemoteWorkspaceWindow.self)
            try await refresh(client)
            guard accepts(client) else { throw KitedError(message: "工作机已切换") }
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
                let client = try activeClient(in: area)
                guard area.remote?.machine.id == client.machineID else { throw KitedError(message: "工作机已切换") }
                struct Closed: Decodable { let ok: Bool }
                _ = try await client.request("/workspaces/\(area.id)/windows/\(pane.id)", method: "DELETE", as: Closed.self)
                try await refresh(client)
            } catch { area.windowError = error.localizedDescription }
        }
    }

    func workspace(_ id: String) -> WorkArea? { id == draftWorkspace.id ? draftWorkspace : workspaces.first { $0.id == id } }
    var current: WorkArea? {
        guard selectedProject == nil else { return nil }
        if !detached.contains(selected), let area = workspace(selected) { return area }
        return workspaces.first { !detached.contains($0.id) }
    }
}

/// 一个订阅账号本周剩余的额度，0...1。
struct SubscriptionQuota: Identifiable {
    let provider: String
    let remaining: Double
    var id: String { provider }
}
