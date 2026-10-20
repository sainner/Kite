import SwiftUI

@Observable
final class AppModel {
    var workspaces: [WorkArea] = []
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
    /// 本机 kited 的自动更新状态（只有作为工作机的 Mac 有），侧栏的版本提示与重启以更新用，见 refreshLocalUpdate。
    var localUpdate: UpdateStatus?
    let account: KiteAccount
    /// 语音输入的录音，整个 App 共用一支麦克风。
    let voice = VoiceInput()
    private(set) var connections: [String: WorkerConnection] = [:]
    private var connectionRun: UUID?
    private let emptyConnection = UUID()
    var activeConnection: WorkerConnection? {
        if let id = current?.remote.machine.id { return connections[id] }
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
    /// 正在打开添加项目的表单。
    var addingProject = false
    /// 设备一栏在内容区显示的页面。
    var drivePage = DrivePage.accounts
    /// 资源库一栏在内容区显示的页面。
    var extensionPage = ExtensionLibrary.credentials
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
    /// 每个角色最后一次手改签名的记号，见 changeRoleEmblem。
    @ObservationIgnored var roleEmblemEdits: [String: UUID] = [:]
    /// 上次找到的 Line 工作区，见 lineArea。
    @ObservationIgnored var lineAreaHint: String?
    /// 资源库里改过还没保存的模板。
    var templateDrafts: [TemplateDraft] = []
    /// 资源库代理上下文页点可用变量弹出的变量弹窗看的变量，见 ContextVariableSheet。
    var contextVariable: ContextScene.Variable?
    /// 变量弹窗各层选过的取值对象，按层，见 contextVariableSource。
    var contextVariableChoices: [String: String] = [:]
    /// 变量弹窗里改过还没保存的文件；弹窗关掉再打开还在，保存或放弃后清掉。
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
    /// 资源库凭据的固定窗口：密钥占左边整列，右边从上到下是 Git 账号、模型 API、语音识别。
    let credentialWindows = WindowLayout(fixed: .split(Split(.horizontal, 0.5,
        .pane(Pane("secrets")),
        .split(Split(.vertical, 1.0 / 3, .pane(Pane("git")),
            .split(Split(.vertical, 0.5, .pane(Pane("api")), .pane(Pane("speech")))))))))
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
    /// 侧栏菜单发起的归档与强制接管确认，由 WorkspaceGitPresentation 呈现。
    var archiveRequest: WorkArea?
    var takeoverRequest: TakeoverRequest?
    /// 集成父工作区时还有子工作区没合回或放弃，等用户逐个处理，由 WorkspaceGitPresentation 呈现。
    var pendingChildren: PendingChildren?
    /// 侧栏里展开了子工作区的工作区；默认收起，见 WorkspaceRow 标题右边的「+x」。
    var expandedWorkspaces: Set<String> = []
    /// 菜单和页面发起的操作遇到远程要求登录，等用户就地登录，由 WorkspaceGitPresentation 呈现，见 offerGitLogin。
    var gitLogin: GitLogin?
    /// 本机新建、工作机还没列出来的工作区，见 createWorkspace。
    @ObservationIgnored private var creatingWorkspaces: [String: WorkArea] = [:]

    init(account: KiteAccount = KiteAccount()) {
        self.account = account
    }

    func connection(for area: WorkArea? = nil) -> WorkerConnection? {
        guard let area else { return activeConnection }
        return connections[area.remote.machine.id]
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
        for area in workspaces where area.remote.machine.id == id { area.definitions = values }
    }

    /// 新建窗口里选好了插件，这个窗口原地变成它（见 WorkArea.chooserWindow）：代理变成新代理的草稿；带视图的插件按这个窗口的 ID
    /// 新建实例和窗口（见 sendWindowRequest）；只在后台的插件放进停靠栏，新建窗口飞进它那一格。
    func choose(_ definition: RemotePluginDefinition, in area: WorkArea) {
        guard let window = area.chooserWindow else { return }
        if definition.agent != nil { area.chooseAgent(); return }
        if !definition.views.isEmpty {
            send(OpenWindowRequest(id: window, content: .create(definition.id, instance: UUID().uuidString.lowercased())), in: area)
            return
        }
        let request = CreatePluginInstance(id: UUID().uuidString.lowercased(), definitionId: definition.id)
        sendInstanceRequest(request, in: area)
        area.closeChooser(into: request.id)
    }

    /// 后台实例不等工作机：ID 由本机定，本机先放进停靠栏（见 WorkArea.openingInstances），工作机按同一个 ID 建好后由它的列表接上；
    /// 建不成再收回。
    private func sendInstanceRequest(_ request: CreatePluginInstance, in area: WorkArea) {
        guard let definition = area.definitions.first(where: { $0.id == request.definitionId }) else { return }
        area.windowError = nil
        area.failedInstanceRequests.removeAll { $0.id == request.id }
        area.createLocally(RemotePluginInstance(id: request.id, workspaceId: area.id, definitionId: definition.id,
                                                title: area.newInstanceTitle(definition), status: .open, presentation: .background,
                                                createdAt: Self.now))
        Task {
            let client: KitedClient
            do {
                client = try activeClient(in: area)
                guard area.remote.machine.id == client.machineID else { throw KitedError(message: "工作机已切换") }
                let _: RemotePluginInstance = try await client.request("/workspaces/\(area.id)/plugin-instances", method: "POST", body: request, as: RemotePluginInstance.self)
            } catch {
                area.settleInstance(request.id)
                if !Self.rejected(error) { area.failedInstanceRequests.append(request) }
                area.windowError = error.localizedDescription
                return
            }
            do { try await refresh(client) } catch { area.windowError = error.localizedDescription }
        }
    }

    /// 重发网络中断时没得到确认的开窗口、建实例请求，ID 不变。
    func retryRequests(in area: WorkArea) {
        let windows = area.failedWindowRequests, instances = area.failedInstanceRequests
        for request in windows { send(request, in: area) }
        for request in instances { sendInstanceRequest(request, in: area) }
    }

    /// 明确拒绝可以结束这次请求；网络中断保留同一 ID，供用户安全重试。
    private static func rejected(_ error: Error) -> Bool {
        (error as? KitedError)?.status.map { (400..<500).contains($0) } ?? false
    }

    /// 和工作机一样的毫秒时间戳，本机先建的对象用。
    private static var now: Int { Int(Date().timeIntervalSince1970 * 1000) }

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
        creatingWorkspaces = [:]
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
    }

    /// 新建中的工作区在工作机还没有检出时带着空 ID 的占位检出，不算。
    var checkouts: [RemoteCheckout] {
        var seen = Set<String>()
        return workspaces.map(\.remote.checkout).filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }
    var knownProjects: [RemoteProject] {
        var seen = Set<String>()
        return (account.registeredProjects.map(\.project) + account.catalogs.flatMap(\.snapshot.projects) + workspaces.map(\.remote.project))
            .filter { seen.insert($0.id).inserted }
    }
    var availableWorkers: [WorkerConnection] { connections.values.filter(\.connected).sorted { $0.machine.name < $1.machine.name } }

    /// 新工作区、添加项目默认用哪台工作机，各处都从这里取：这台设备是工作机时用它，其次是空闲的（没有正在跑的代理），
    /// 再次是任一台连着的；同一档里已有这个项目检出的优先，省得再 clone。
    func preferredWorker(for projectID: String? = nil) -> WorkerConnection? {
        let holders = Set(checkouts.filter { $0.projectId == projectID }.map(\.machineId))
        let busy = Set(workspaces.filter { $0.activities.keys.contains(where: $0.isRunning) }.map(\.remote.machine.id))
        func rank(_ connection: WorkerConnection) -> (Int, Int) {
            let id = connection.machine.id
            return (connection.client.isLocal ? 0 : busy.contains(id) ? 2 : 1, holders.contains(id) ? 0 : 1)
        }
        return availableWorkers.min { rank($0) < rank($1) }
    }

    func projectLabel(_ project: RemoteProject) -> String { projectLabels()(project) }

    /// 一次算好各项目的显示名，同名的几个后面带 ID 前 8 位；列表里逐个取名时用它，不必每个都重算项目目录。
    func projectLabels() -> (RemoteProject) -> String {
        let counts = Dictionary(knownProjects.map { ($0.name, 1) }, uniquingKeysWith: +)
        return { counts[$0.name, default: 0] > 1 ? "\($0.name)（\($0.id.prefix(8))）" : $0.name }
    }

    /// 账号的设备列表决定设备集合，目录摘要从一台连着的工作机读；各机事件流、错误与游标独立存续。
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
            let unknown = account.workers.filter { device in device.online && !connections.values.contains { $0.deviceID == device.id } }
            await withTaskGroup(of: Void.self) { group in
                for device in unknown {
                    group.addTask { await self.discover(device) }
                }
            }
            guard !Task.isCancelled, account.ready, connectionRun == run else { return }
            startConnections()
            // 目录摘要要等一台工作机连上才读得到：每轮先读一次，没读到就每秒再试，读到后等满这一轮。
            var directory = false
            for _ in 0..<15 {
                if !directory, await refreshDirectory() {
                    directory = true
                    guard connectionRun == run else { return }
                    mergeDirectory()
                    startConnections()
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func startConnections() {
        for connection in connections.values where connection.task == nil {
            connection.task = Task { await self.follow(connection) }
        }
    }

    private func address(_ device: AccountDevice) -> String? {
        device.id == account.deviceID && account.role == "worker" ? KitedClient.local : device.address
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
            workspaces.removeAll { $0.remote.machine.id == id }
        }
        for entry in account.catalogs {
            let snapshot = entry.snapshot
            guard let address = address(entry.device) else { continue }
            let connection = connections[entry.machineId] ?? WorkerConnection(deviceID: entry.device.id, machine: snapshot.machine, address: address)
            if connection.client.address != address {
                connection.task?.cancel(); connection.task = nil
                connection.catalog.reset(); connection.connected = false
                connection.client = KitedClient(address: address, machineID: entry.machineId)
            }
            connections[entry.machineId] = connection
            connection.updatedAt = entry.updatedAt
            if !connection.hasLiveCatalog {
                let previous = Dictionary(uniqueKeysWithValues: workspaces.filter { $0.remote.machine.id == entry.machineId }.map { ($0.id, $0) })
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
            for area in workspaces where area.remote.machine.id == connection.id { area.draftThread.connected = false }
        }
    }

    private func follow(_ connection: WorkerConnection) async {
        let client = connection.client
        // 刚开始或从正常连接断开后立即重试一次，之后再按间隔重试。
        var immediate = true
        while !Task.isCancelled && accepts(client) {
            // 组网确知离线的工作机不去连：连不上只是白等超时，发给它的包还会在组网库里排队等握手。
            // 设备列表随 run 的每一轮刷新，这里隔两秒看一次，上线后接着连。
            if account.devices.first(where: { $0.id == connection.deviceID })?.online == false {
                connection.connected = false
                connection.outdated = nil
                connection.error = "上线后自动连接"
                for area in workspaces where area.remote.machine.id == connection.id { area.draftThread.connected = false }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                continue
            }
            let generation = connection.catalog.reset()
            do {
                // 先核对版本：协议号与 App 不同就不连，锁定为待更新；工作机可能正在自动更新，隔一阵再看。
                let machine = try await client.request("/machine", timeout: 10, as: RemoteMachine.self)
                guard accepts(client) else { return }
                connection.version = machine.version
                connection.outdated = VersionMismatch(machine.version)
                if connection.outdated != nil {
                    connection.connected = false
                    connection.error = nil
                    for area in workspaces where area.remote.machine.id == connection.id { area.draftThread.connected = false }
                    // 本机 kited 换了新版而 App 还旧时，它备好的新 App 就在更新状态里。
                    await refreshLocalUpdate(connection)
                    try await Task.sleep(for: .seconds(30))
                    continue
                }
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
                // 读不到版本时不再沿用上次的待更新，显示真实的连接错误。
                connection.outdated = nil
                connection.error = error.localizedDescription
                TimingTrace.mark("工作机 \(connection.machine.name) 连接失败：\(error.localizedDescription)")
                for area in workspaces where area.remote.machine.id == connection.id { area.draftThread.connected = false }
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
            if event.type == "update.changed" {
                connection.updateRevision += 1
                Task { await self.refreshLocalUpdate(connection) }
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
                   let area = self.workspaces.first(where: { $0.id == workspaceId && $0.remote.machine.id == connection.id }) {
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
                Task { await self.refreshLocalUpdate(connection) }
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
            let previous = Dictionary(uniqueKeysWithValues: workspaces.filter { $0.remote.machine.id == id }.map { ($0.id, $0) })
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
        // 本机正新建、工作机还没列出来的留着，见 create
        let listed = Set(areas.map(\.id))
        let creating = creatingWorkspaces.values.filter { $0.remote.machine.id == machine && !listed.contains($0.id) }
        // 工作区流转后同一 ID 出现在几台工作机上：epoch 最高、未冻结的是当前宿主，冻结的旧记录不另列。
        let merged = workspaces.filter { $0.remote.machine.id != machine } + areas + creating
        let rank = { (area: WorkArea) in (area.remote.workspace.status == .transferred ? 0 : 1, area.remote.workspace.epoch ?? 1) }
        var hosts: [String: WorkArea] = [:]
        for area in merged where hosts[area.id].map({ rank(area) > rank($0) }) ?? true { hosts[area.id] = area }
        workspaces = merged.filter { hosts[$0.id] === $0 }
        workspaces.sort {
            let left = $0.remote.workspace.createdAt, right = $1.remote.workspace.createdAt
            return left == right ? $0.id < $1.id : left > right
        }
        detached.formIntersection(Set(workspaces.map(\.id)))
        if workspace(selected) == nil { selected = workspaces.first?.id ?? "" }
    }

    /// 新建工作区不弹表单、不等工作机：工作区 ID 由本机定，本机先按它建好、选中，开一个新代理的草稿窗口，第一条消息在那里写，工作区随它起名；
    /// 工作机建好后目录接上同一个工作区对象。工作机上还没有这个项目的检出时由它先 clone。没指定工作机时用 preferredWorker。
    /// 建不成就收回、回到原来的选中，原因用 toast 报；clone 时远程要求登录的，请用户就地登录，绑好令牌后在同一台工作机上再建。
    func createWorkspace(in projectID: String, on machineID: String? = nil, toast: ToastCenter?) {
        let fail = { (message: String) -> Void in toast?.show(message, systemImage: "exclamationmark.triangle") }
        guard let project = knownProjects.first(where: { $0.id == projectID }) else { return fail("项目已不存在") }
        let connection = if let machineID { connections[machineID] } else { preferredWorker(for: projectID) }
        guard let connection, connection.connected else { return fail(machineID == nil ? "没有连上的工作机" : "这台工作机未连接") }
        let id = UUID().uuidString.lowercased()
        // 工作机上还没有检出时先占个位，目录接上后换成工作机给的。
        let checkout = checkouts.first { $0.projectId == project.id && $0.machineId == connection.machine.id }
            ?? RemoteCheckout(id: "", projectId: project.id, machineId: connection.machine.id, path: "", remote: project.remote, createdAt: Self.now)
        let info = WorkspaceInfo(id: id, epoch: 1, checkoutId: checkout.id, name: "新工作区", cwd: "",
                                 branch: "kite/\(id)", base: nil, status: .preparing, createdAt: Self.now)
        let area = WorkArea(remote: RemoteWorkspace(machine: connection.machine, project: project, checkout: checkout, workspace: info,
                                                    threads: [], instances: [], windows: []))
        area.openDraft()
        let before = (selected, selectedProjectID)
        creatingWorkspaces[id] = area
        workspaces.insert(area, at: 0)
        selectWorkspace(id)
        Task {
            defer { creatingWorkspaces[id] = nil }
            do {
                _ = try await connection.client.request("/workspaces", method: "POST", body: CreateWorkspaceRequest(project: project.id, id: id),
                                                        timeout: 1800, as: RemoteWorkspace.self)
            } catch {
                // 目录已经接上的（请求其实到了）留着
                guard area.pluginClient == nil else { return }
                workspaces.removeAll { $0 === area }
                if selected == id { (selected, selectedProjectID) = before }
                let machine = connection.machine.id
                if offerGitLogin(error, retry: { self.createWorkspace(in: projectID, on: machine, toast: toast) }) { return }
                return fail(error.localizedDescription)
            }
            try? await refresh(connection.client)
        }
    }

    func startThread(in area: WorkArea, message: Message, window: String) async throws {
        let client = try activeClient(in: area)
        guard area.remote.machine.id == client.machineID else { throw KitedError(message: "工作机已切换") }
        let draft = area.draftThread
        let choice = draft.draftChoice
        _ = try await client.request("/workspaces/\(area.id)/threads", method: "POST",
            body: CreateThreadRequest(prompt: message.typed, role: newThreadRole(for: draft, in: area)?.selection, model: choice?.model,
                                      tools: choice?.tools, maxRequestsPerTurn: choice?.maxRequestsPerTurn, approval: choice?.approval, windowId: window,
                                      messageId: message.id), as: RemoteThread.self)
        // 读回的窗口指向新实例，草稿对象由 WorkArea.update 认领，接着当这个代理
        try await refresh(client)
        guard accepts(client) else { throw KitedError(message: "工作机已切换") }
    }

    /// 归档不等工作机：本机先按已归档算，停靠栏里那一格和它的窗口当场收掉（见 WorkArea.archivingInstances）；工作机归档不成再放回来，
    /// 报在归档失败的提示里。归档保留会话与数据，工作机停止执行并关闭它的全部窗口。
    func archiveInstance(_ instance: RemotePluginInstance, in area: WorkArea) throws {
        let client = try activeClient(in: area)
        guard area.remote.machine.id == client.machineID else { throw KitedError(message: "工作机已切换") }
        area.archiveError = nil
        area.archiveLocally(instance.id)
        Task {
            do {
                let _: JSON = try await client.request("/instances/\(instance.id)/archive", method: "POST", as: JSON.self)
            } catch {
                area.restoreArchiving(instance.id)
                area.archiveError = error.localizedDescription
                return
            }
            do { try await refresh(client) } catch { area.windowError = error.localizedDescription }
        }
    }

    /// 实例已有窗口时不另开：已经是要的视图，或者本机先开、工作机还没建好（等建好再换），只调到前面；否则原地换过去（见 sendWindowRequest）。
    func openWindow(_ content: OpenWindowRequest.Content, in area: WorkArea) {
        if case .open(let target) = content, let window = area.window(of: target.instanceId),
           window.target.viewId == target.viewId || area.isOpening(Pane(window.id)) {
            area.layout.activate(Pane(window.id))
            return
        }
        send(OpenWindowRequest(id: UUID().uuidString.lowercased(), content: content), in: area)
    }

    /// 发出开窗口请求，失败报在窗口操作的提示里。
    private func send(_ request: OpenWindowRequest, in area: WorkArea) {
        let task = sendWindowRequest(request, in: area)
        Task { if case .failure(let error) = await task.result { area.windowError = error.localizedDescription } }
    }

    /// 开窗口不等工作机：工作机用请求 ID 作新窗口的 ID、用请求里的实例 ID 建新实例（见 kited 的 openWindow），本机先按这两个 ID
    /// 建好、放上台面（见 WorkArea.openingWindows、openingInstances），工作机建好后由它的列表接上，卡片不换；建不成再收回。
    /// 实例已有窗口时工作机不另开，把那个窗口换到请求的视图：本机也先换（见 WorkArea.switchingViews），有了结果以工作机的列表为准。
    /// 几个请求可以同时在路上。返回工作机确认的窗口。
    private func sendWindowRequest(_ request: OpenWindowRequest, in area: WorkArea) -> Task<RemoteWorkspaceWindow, Error> {
        area.windowError = nil
        area.failedWindowRequests.removeAll { $0.id == request.id }
        var local: WindowTarget?
        var created: String?
        var switching: String?
        switch request.content {
        case .open(let target):
            if let window = area.window(of: target.instanceId) {
                switching = window.id
                area.switchLocally(window.id, to: target.viewId, request: request.id)
                area.layout.activate(Pane(window.id))
            } else {
                local = target
            }
        case .create(let definitionId, let instanceId, let title, _):
            if let definition = area.definitions.first(where: { $0.id == definitionId }) {
                area.createLocally(RemotePluginInstance(id: instanceId, workspaceId: area.id, definitionId: definitionId,
                                                        title: title ?? area.newInstanceTitle(definition), status: .open, presentation: .window,
                                                        createdAt: Self.now))
                created = instanceId
                local = WindowTarget(instanceId: instanceId, viewId: definition.defaultView)
            }
        }
        if let local { area.openLocally(RemoteWorkspaceWindow(id: request.id, workspaceId: area.id, target: local, state: .open, createdAt: 0)) }
        let closing = Array(area.closeRequests.values)
        return Task {
            let window: RemoteWorkspaceWindow, client: KitedClient
            do {
                for close in closing { await close.value }
                client = try activeClient(in: area)
                guard area.remote.machine.id == client.machineID else { throw KitedError(message: "工作机已切换") }
                window = try await client.request("/workspaces/\(area.id)/windows", method: "POST", body: request, as: RemoteWorkspaceWindow.self)
            } catch {
                area.settleOpening(request.id, rejected: Self.rejected(error))
                if let created { area.settleInstance(created) }
                if let switching { area.settleSwitch(switching, request: request.id) }
                if !Self.rejected(error) { area.failedWindowRequests.append(request) }
                throw error
            }
            do { try await refresh(client) } catch { area.windowError = error.localizedDescription }
            if let switching { area.settleSwitch(switching, request: request.id) }
            if accepts(client), switching == nil, local == nil || window.id != request.id {
                // 本机没先开，或工作机交回了这个实例原有的窗口：本机先开的那个换成它
                area.settleOpening(request.id)
                area.layout.activate(Pane(window.id))
            }
            return window
        }
    }

    /// 消息里的 localhost:端口 链接在所属工作区内解析：端口属于本工作区运行中的终端时，选中这个端口、打开那个终端的网页视图
    /// 并到链接的路径，否则报错（docs/成果查看与位置.md「运行中的网页」）。打开到哪里只在本机，见 WorkArea.webLinks。
    func openLocalPort(_ target: LocalPort, in area: WorkArea) async throws {
        guard let instance = area.instances.first(where: { instance in
            instance.status == .open && instance.state?.terminal?.running == true
                && instance.state?.terminal?.ports?.contains(where: { $0.port == target.port }) == true
        }) else { throw KitedError(message: "localhost:\(target.port) 不是这个工作区里运行中的终端在监听的端口") }
        // 先记下再选端口：网页视图换到这个端口时直接打开到链接的路径，不先开一次首页
        area.webLinks[instance.id] = WebLink(target: target)
        if instance.state?.terminal?.webPort != target.port { try await selectTerminalPort(target.port, of: instance.id, in: area) }
        openWindow(.open(.init(instanceId: instance.id, viewId: "web")), in: area)
    }

    /// 停终端：先挂断 shell，等不到退出再停整个进程组；工作机确认进程结束才返回。
    func stopTerminal(_ instance: String, in area: WorkArea) async throws {
        struct Stop: Encodable { let operationId: String; let instanceId: String }
        struct Stopped: Decodable { let ok: Bool }
        let client = try activeClient(in: area)
        _ = try await client.request("/workspaces/\(area.id)/operations/terminal.stop", method: "POST",
                                     body: Stop(operationId: UUID().uuidString, instanceId: instance), as: Stopped.self)
    }

    /// 代码块的「在终端中执行」：新开一个以命令第一行为名的终端，工作机等 shell 起好后把命令打进去执行。
    func runInTerminal(_ command: String, in area: WorkArea) {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        let title = String(firstLine(command).trimmingCharacters(in: .whitespaces).prefix(60))
        openWindow(.create("kite.terminal", instance: UUID().uuidString.lowercased(), title: title, command: command), in: area)
    }

    /// 菜单里的停止终端：不等结果，失败报在窗口提示里。
    func stopTerminal(_ instance: RemotePluginInstance, in area: WorkArea) {
        Task {
            do { try await stopTerminal(instance.id, in: area) }
            catch { area.windowError = error.localizedDescription }
        }
    }

    /// 选终端网页视图打开的端口，各设备共用；nil 换回默认。
    func selectTerminalPort(_ port: Int?, of instance: String, in area: WorkArea) async throws {
        struct Select: Encodable { let operationId: String; let instanceId: String; let port: Int? }
        struct Selected: Decodable { let port: Int? }
        let client = try activeClient(in: area)
        _ = try await client.request("/workspaces/\(area.id)/operations/terminal.select", method: "POST",
                                     body: Select(operationId: UUID().uuidString, instanceId: instance, port: port), as: Selected.self)
        try await refresh(client)
    }

    /// 引用只选择资源；窗口身份仍按现有实例与视图复用。窗口先在本机打开（见 sendWindowRequest），再选文件；
    /// 还没有文件实例的，等工作机建好实例才能选。
    /// 窗口不在台面上时目录先收起、不带动画，窗口打开出来就是文件：等选好文件再收（见 navigate），目录会在窗口展开时划走。
    /// 可能是目录的引用不收，读得出目录就展开到它。
    func openFileReference(_ reference: FileReference, in area: WorkArea) async throws {
        let browsing = area.windows.first { area.files[$0.target.instanceId] != nil }?.target.instanceId
            ?? area.instances.first { $0.status == .open && area.files[$0.id] != nil }?.id
        guard let instanceID = browsing else {
            let instanceID = UUID().uuidString.lowercased()
            if !reference.mayBeDirectory { area.referencedFiles.insert(instanceID) }
            defer { area.referencedFiles.remove(instanceID) }
            let request = OpenWindowRequest(id: UUID().uuidString.lowercased(), content: .create("kite.files", instance: instanceID))
            let window = try await sendWindowRequest(request, in: area).value
            guard let browser = area.files[window.target.instanceId] else { throw KitedError(message: "文件窗口尚未就绪") }
            try await browser.open(reference)
            return
        }
        guard let browser = area.files[instanceID] else { throw KitedError(message: "文件窗口尚未就绪") }
        if !area.isVisible(instance: instanceID), !reference.mayBeDirectory {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { browser.showDirectory = false }
        }
        let target = WindowTarget(instanceId: instanceID, viewId: "files")
        var opening: Task<RemoteWorkspaceWindow, Error>?
        if let window = area.window(of: instanceID) { area.layout.activate(Pane(window.id)) }
        else { opening = sendWindowRequest(OpenWindowRequest(id: UUID().uuidString.lowercased(), content: .open(target)), in: area) }
        try await browser.open(reference)
        _ = try await opening?.value
    }

    /// 关窗口不等工作机：本机先关掉、飞回停靠栏（见 WorkArea.closingWindows），工作机关不掉再放回来。
    /// 本机先开、工作机还没建好的窗口要等建好才能关。
    func closeWindow(_ pane: Pane, in area: WorkArea) {
        if pane.id == area.draftWindow { area.closeDraft(); return }
        if pane.id == area.chooserWindow { area.closeChooser(); return }
        guard area.windows.contains(where: { $0.id == pane.id }), !area.isOpening(pane), area.closeRequests[pane.id] == nil else { return }
        area.windowError = nil
        // 父代理关窗口：子代理收着的窗口一起关，台面上的留着
        let descendants = area.descendantPanesClosing(with: pane)
        area.closeLocally(pane.id)
        for child in descendants { closeWindow(child, in: area) }
        area.closeRequests[pane.id] = Task {
            defer { area.closeRequests[pane.id] = nil }
            let client: KitedClient
            do {
                client = try activeClient(in: area)
                guard area.remote.machine.id == client.machineID else { throw KitedError(message: "工作机已切换") }
                struct Closed: Decodable { let ok: Bool }
                _ = try await client.request("/workspaces/\(area.id)/windows/\(pane.id)", method: "DELETE", as: Closed.self)
            } catch {
                area.reopenClosing(pane.id)
                area.windowError = error.localizedDescription
                return
            }
            do { try await refresh(client) } catch { area.windowError = error.localizedDescription }
        }
    }

    func workspace(_ id: String) -> WorkArea? { workspaces.first { $0.id == id } }
    /// 内容区的工作区：选中的那个；没选时默认侧栏里第一个项目的第一个工作区（即列表里第一个不是 Line 的），只有 Line 时是 Line。
    var current: WorkArea? {
        guard selectedProject == nil else { return nil }
        if !detached.contains(selected), let area = workspace(selected) { return area }
        let line = lineArea?.id
        return workspaces.first { !detached.contains($0.id) && $0.id != line } ?? workspaces.first { !detached.contains($0.id) }
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
