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
    /// 正在拖侧栏改宽：最左一列窗口每步跟着改宽，对话列表这时只量可见区附近（见 WindowLayout.anyResizing），
    /// 窗口点阵收起（见 PhoneStageView）。
    var sidebarResizing = false {
        didSet { WindowLayout.sidebarResizing = sidebarResizing }
    }
    /// iPad 上拖侧栏改宽的实时宽度，不进 SwiftUI，见 SidebarDrag。
    @ObservationIgnored let sidebarDrag = SidebarDrag()
    var sidebarCollapsed = false
    /// 侧栏底部一级导航选中的一栏。
    var sidebarSection = SidebarSection.workspaces
    var contentSize: CGSize = .zero
    /// Line 的收件箱，从 Line 所在的工作机读；标志旁的数目和收件箱窗口都用它，见 LineModel。
    var lineInboxSnapshot: LineInbox?
    /// monitor 窗口的读取版本：工作机推 monitor.changed 时加一，打开着的窗口重新读取。
    var monitorRevisions: [String: Int] = [:]
    /// 点了系统通知、要在收件箱里展开的那一项。
    var lineFocusItem: String?
    let account: KiteAccount
    /// 语音输入的录音，整个 App 共用一支麦克风。
    let voice = VoiceInput()
    private(set) var connections: [String: WorkerConnection] = [:]
    private var connectionRun: UUID?
    private let emptyConnection = UUID()
    var activeConnection: WorkerConnection? {
        if let id = current?.remote?.machine.id { return connections[id] }
        return connections.values.sorted { $0.machine.id < $1.machine.id }.first(where: { $0.connected })
    }
    var machine: RemoteMachine? { activeConnection?.machine }
    var connected: Bool { activeConnection?.connected == true }
    var connectionRevision: UUID { activeConnection?.catalog.generation ?? emptyConnection }
    var definitions: [RemotePluginDefinition] { activeConnection?.definitions ?? [] }
    var contextTemplates: ContextTemplateCatalog? {
        get { activeConnection?.templates }
        set { activeConnection?.templates = newValue }
    }
    var error: String?
    #if os(iOS)
    /// 扫码登录的进度；后台重连的错误不覆盖它。
    enum InviteState: Equatable { case joining, failed(String) }
    var invite: InviteState?
    #endif
    /// 正在打开的新建表单：添加项目或新建工作区。
    var newWorkspace: NewWorkspace.Mode?
    /// 设备一栏在内容区显示的页面。
    var drivePage = DrivePage.accounts
    /// 资源库一栏在内容区显示的页面。
    var extensionPage = ExtensionLibrary.plugins
    /// 资源库代理上下文页选中的角色或模板，见 agentContextItem。
    var selectedAgentContext: AgentContextItem?
    /// 资源库角色没保存的提示词。
    var roleDrafts: [RoleDraft] = []
    /// 资源库里还没存过的新角色，按侧栏里的先后排。
    var newRoles: [NewRole] = []
    /// 资源库角色即时生效、还没存好的修改，按先后排。
    var roleChanges: [String: [RoleChange]] = [:]
    /// 资源库角色手改、还没存好的签名；算式无效的一直留着，等改对。
    var roleEmblems: [String: EmblemDesign] = [:]
    /// 每个角色排队中的最后一次写入，见 queueRoleWrite。
    @ObservationIgnored var roleWrites: [String: Task<Void, Error>] = [:]
    /// 资源库里改过还没保存的模板。
    var templateDrafts: [TemplateDraft] = []
    /// 资源库代理上下文页的变量窗口看的变量；窗口关掉后留着，关的动画里内容不变。见 openContextVariable。
    var contextVariable: String?
    /// 变量窗口各层选过的取值对象，按层，见 contextVariableSource。
    var contextVariableChoices: [String: String] = [:]
    /// 变量窗口里改过还没保存的文件；窗口关掉再打开还在，保存或放弃后清掉。
    var contextFileDrafts: [ContextFileDraft] = []
    /// 设置一栏在内容区显示的页面。
    var settingsPage = SettingsPage.account
    var accountMachineID: String?
    let accountWindows = WindowLayout(fixed: .split(Split(.horizontal, 0.5,
        .split(Split(.vertical, 0.5, .pane(Pane("chatgpt")), .pane(Pane("claude")))),
        .pane(Pane("api")))))
    /// 资源库代理上下文的固定窗口：角色左边整列是上下文，右边上下分别是签名与初始配置；模板只有上下文。
    let roleWindows = WindowLayout(fixed: .split(Split(.horizontal, 0.6,
        .pane(Pane("context")),
        .split(Split(.vertical, 0.5, .pane(Pane("emblem")), .pane(Pane("settings")))))))
    let templateWindows = WindowLayout(fixed: .pane(Pane("context")))
    /// 正在保存提示词、恢复默认或新建的资源库角色：这期间提示词不能改，新角色的名称、签名与初始配置也不能改。
    var savingRoles: Set<String> = []

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

    /// 进入设置前所在的一栏，从设置返回时回到这里。
    private var sectionBeforeSettings = SidebarSection.workspaces

    /// 切到设置一栏。
    func openSettings(_ page: SettingsPage? = nil) {
        if sidebarSection != .settings { sectionBeforeSettings = sidebarSection }
        sidebarSection = .settings
        if let page { settingsPage = page }
    }

    /// 从设置回到进入前的一栏。
    func closeSettings() {
        sidebarSection = sectionBeforeSettings
    }
    /// 侧栏菜单发起的现场推送与归档确认，由 WorkspaceGitPresentation 呈现。
    var scenePush: WorkArea?
    var archiveRequest: WorkArea?

    init(account: KiteAccount = KiteAccount()) {
        self.account = account
    }

    func connection(for area: WorkArea? = nil) -> WorkerConnection? {
        guard let area, !area.isDraft else { return activeConnection }
        return area.remote.flatMap { connections[$0.machine.id] }
    }

    func revision(for area: WorkArea) -> UUID { connection(for: area)?.catalog.generation ?? emptyConnection }
    func isConnected(_ area: WorkArea) -> Bool { connection(for: area)?.connected == true }

    func activeClient(in area: WorkArea? = nil) throws -> KitedClient {
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
        if definition.agent != nil { area.openDraft(); return }
        if !definition.views.isEmpty { openWindow(.create(definition.id), in: area); return }
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
        accountMachineID = nil
        workspaces = []
        detached = []
        selectedProjectID = nil
        selected = ""
        roleDrafts = []
        newRoles = []
        roleChanges = [:]
        roleEmblems = [:]
        roleWrites = [:]
        selectedAgentContext = nil
        templateDrafts = []
        draftWorkspace.draftThread.role = nil
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
        // 先配置组网，各机连接一开始就能等待节点上线，不必先失败一次。
        await account.configureNetwork()
        guard connectionRun == run else { return }
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
            connection.rolesRequest?.task.cancel(); connection.rolesRequest = nil
            connection.catalog.reset(); connection.connected = false
            for area in workspaces where area.remote?.machine.id == connection.id { area.draftThread.connected = false }
        }
    }

    private func follow(_ connection: WorkerConnection) async {
        let client = connection.client
        // 刚开始或从正常连接断开后立即重试一次，之后再按间隔重试。
        var immediate = true
        while !Task.isCancelled && accepts(client) {
            let generation = connection.catalog.reset()
            do {
                // 插件定义和事件流并行请求，任一失败都按断线重连。
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.refreshDefinitions(client) }
                    group.addTask { try await self.events(client, connection: connection, generation: generation) }
                    while try await group.next() != nil {}
                }
            } catch {
                guard !Task.isCancelled, accepts(client), generation == connection.catalog.generation else { return }
                if connection.connected { immediate = true }
                connection.connected = false
                connection.error = error.localizedDescription
                TimingTrace.mark("工作机 \(connection.machine.name) 连接失败：\(error.localizedDescription)")
                for area in workspaces where area.remote?.machine.id == connection.id { area.draftThread.connected = false }
            }
            if immediate { immediate = false; continue }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    private func events(_ client: KitedClient, connection: WorkerConnection, generation: UUID) async throws {
        try await client.events { event in
            try Task.checkCancellation()
            guard self.accepts(client), generation == connection.catalog.generation else { return }
            // 额度不属于目录版本，按到达顺序直接替换；工作机缓存为空时首帧不带额度，稍后单独推送。
            if let accounts = event.modelAccounts {
                connection.modelAccounts = accounts
                connection.modelAccountsError = nil
            }
            if event.type == "model-accounts.changed" { return }
            if event.type == "line.inbox" {
                Task { await self.refreshLineInbox() }
                return
            }
            if event.type == "monitor.changed" {
                if let instance = event.instanceId { self.monitorRevisions[instance, default: 0] += 1 }
                return
            }
            if event.type == "line.notification" {
                if let notification = event.notification { LineNotifications.shared.post(notification) }
                return
            }
            if event.type == "context-templates.changed" {
                if connection.templates != nil { Task { try? await self.refreshTemplates(of: connection, fresh: true) } }
                return
            }
            if event.type == "roles.changed" {
                if connection.roles != nil { Task { try? await self.refreshRoles(of: connection, fresh: true) } }
                return
            }
            if event.type == "thread.activity" {
                // 摘要直接带着新值，不重新读取目录。
                if let workspaceId = event.workspaceId, let threadId = event.threadId, let activity = event.activity,
                   let cursor = event.cursor.flatMap(EventCursor.init),
                   let area = self.workspaces.first(where: { $0.id == workspaceId && $0.remote?.machine.id == connection.id }) {
                    area.updateActivity(threadId, activity, cursor: cursor)
                }
                return
            }
            guard ["catalog.snapshot", "checkout.changed", "workspace.changed", "thread.changed"].contains(event.type) else { return }
            guard let cursor = event.cursor.flatMap(EventCursor.init) else { throw KitedError(message: "工作区事件数据无效") }
            if event.type == "catalog.snapshot" {
                guard event.version == 1, let remote = event.workspaces else { throw KitedError(message: "工作区快照无效") }
                try self.apply(remote, from: client, cursor: cursor, generation: generation)
                // 目录流（重新）连上了：收件箱重读，关注状态再报一次（事件流断开时工作机已把这台设备移出）
                Task { await self.refreshLineInbox() }
                LineAttention.shared.report()
                // 断线期间收不到角色与模板的变化事件，重连后读过的重新读一遍
                if connection.roles != nil { Task { try? await self.refreshRoles(of: connection, fresh: true) } }
                if connection.templates != nil { Task { try? await self.refreshTemplates(of: connection, fresh: true) } }
                TimingTrace.mark("工作机 \(connection.machine.name) 目录快照已应用")
            } else if connection.catalog.needsRefresh(cursor) { try await self.refresh(client) }
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
                    area.update(value, client: client, connection: generation, cursor: cursor)
                    return area
                }
                return WorkArea(remote: value, client: client, definitions: connection.definitions, connection: generation, cursor: cursor)
            }
            replaceWorkspaces(areas, on: id)
            connection.hasLiveCatalog = true
            connection.connected = true
            connection.error = nil
        }
    }

    private func replaceWorkspaces(_ areas: [WorkArea], on machine: String) {
        // 工作区流转后同一 ID 出现在几台工作机上：epoch 最高、未冻结的是当前宿主，冻结的旧记录不另列。
        let merged = workspaces.filter { $0.remote?.machine.id != machine } + areas
        let rank = { (area: WorkArea) in (area.remote?.workspace.status == .transferred ? 0 : 1, area.remote?.workspace.epoch ?? 1) }
        var hosts: [String: WorkArea] = [:]
        for area in merged where hosts[area.id].map({ rank(area) > rank($0) }) ?? true { hosts[area.id] = area }
        workspaces = merged.filter { hosts[$0.id] === $0 }
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
    /// 克隆到工作机的默认仓库位置。
    func cloneCheckout(remote: String, machineID: String) async throws -> String {
        struct Clone: Encodable { let remote: String }
        return try await addCheckout(Clone(remote: remote.trimmingCharacters(in: .whitespaces)), machineID: machineID, timeout: 1800)
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
        let role = draftWorkspace.draftThread.role
        if let role, connection.roles?.roles.contains(where: { $0.id == role.id && $0.revision == role.revision }) != true {
            throw KitedError(message: "所选角色不属于这台工作机，请重新选择")
        }
        let area = try await client.request("/workspaces", method: "POST",
            body: CreateThreadRequest(prompt: prompt, checkout: checkout, role: role?.selection), as: RemoteWorkspace.self)
        try await refresh(client)
        guard accepts(client) else { throw KitedError(message: "工作机已切换") }
        selectWorkspace(area.id)
        draftWorkspace.draftThread.draft = ""
        draftWorkspace.draftThread.role = nil
    }

    func startThread(in area: WorkArea, message: Message, window: String) async throws {
        let client = try activeClient(in: area)
        guard area.remote?.machine.id == client.machineID else { throw KitedError(message: "工作机已切换") }
        let draft = area.draftThread
        let choice = draft.draftChoice
        _ = try await client.request("/workspaces/\(area.id)/threads", method: "POST",
            body: CreateThreadRequest(prompt: message.typed, role: newThreadRole(for: draft, in: area)?.selection, model: choice?.model,
                                      tools: choice?.tools, maxRequestsPerTurn: choice?.maxRequestsPerTurn, windowId: window,
                                      messageId: message.id), as: RemoteThread.self)
        // 读回的窗口指向新实例，草稿对象由 WorkArea.update 认领，接着当这个代理
        try await refresh(client)
        guard accepts(client) else { throw KitedError(message: "工作机已切换") }
    }

    /// 归档保留会话与数据，工作机停止执行并关闭它的全部窗口。
    func archiveInstance(_ instance: RemotePluginInstance, in area: WorkArea) async throws {
        let client = try activeClient(in: area)
        guard area.remote?.machine.id == client.machineID else { throw KitedError(message: "工作机已切换") }
        let _: JSON = try await client.request("/instances/\(instance.id)/archive", method: "POST", as: JSON.self)
        try await refresh(client)
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
        guard !area.isDraft else { return }
        if pane.id == area.draftWindow { area.closeDraft(); return }
        guard !area.changingWindows else { return }
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

/// iPad 上拖侧栏改宽：拖动中不改 AppModel.sidebarWidth（改了 SwiftUI 的整棵根每步重算，2026-10-14 iPad 真机只留外壳时每步约 9ms）。
/// 起拖时排版上侧栏只占最窄的宽（base），内容区往左伸到那里，之后每步不再排：侧栏自己按实时的宽画（MainWindow 的 SidebarLiveWidth，
/// 只有侧栏这一棵跟着重算），原生台面按实时的宽把排窗口的那块往右让（见 PhoneStageView），两者之间不露空、不叠；
/// 内容区伸出来的那段只在拖动中有，松手才把宽交给 sidebarWidth，SwiftUI 排一次。只有侧栏读 width（观察它），台面收通知。
@MainActor @Observable final class SidebarDrag {
    /// 拖动中侧栏在排版上占的宽，内容区从它右边起。
    @ObservationIgnored private(set) var base: CGFloat?
    /// 起拖前侧栏多宽：内容区往左伸出来的那段是 start - base。
    @ObservationIgnored private(set) var start: CGFloat?
    /// 侧栏这一步该有多宽。
    private(set) var width: CGFloat?
    /// 原生台面排窗口的那块，左边比内容区的左边往右多少。
    var offset: CGFloat {
        guard let base, let width else { return 0 }
        return width - base
    }
    /// 内容区比起拖前往左多伸出的一段：停靠栏、空画板这些不跟着拖的按起拖前的位置摆。
    var lead: CGFloat {
        guard let base, let start else { return 0 }
        return start - base
    }

    static let changed = Notification.Name("SidebarDragChanged")

    func move(to width: CGFloat, from start: CGFloat, base: CGFloat) {
        if self.base == nil {
            self.base = base
            self.start = start
        }
        guard width != self.width else { return }
        self.width = width
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// 拖完（或侧栏收起、展开时）：不再挪，交回 SwiftUI 按 sidebarWidth 排。返回最后的宽。
    @discardableResult
    func end() -> CGFloat? {
        let last = width
        base = nil
        start = nil
        width = nil
        NotificationCenter.default.post(name: Self.changed, object: self)
        return last
    }
}
