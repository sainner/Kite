import SwiftUI

/// 工作机拥有实例集合与各实例的当前视图；当前设备保留台面（哪些实例在台面上、怎么摆、焦点）、草稿及尚未确认的实例操作。
/// 停靠栏里一格就是一个实例，Pane 的 ID 就是实例 ID；代理草稿与新建实例的选择页是只在本机的两个特殊 pane（见 draftPane、chooserPane）。
@Observable
final class WorkArea: Identifiable {
    let id: String
    var remote: RemoteWorkspace
    var threads: [WorkThread] = []
    var instances: [RemotePluginInstance] = []
    var files: [String: FileBrowser] = [:]
    var definitions: [RemotePluginDefinition] = [] {
        // 定义比实例清单晚到时，有视图的实例这时才排得进来（见 panes(of:)）
        didSet { if pluginClient != nil { rebuild() } }
    }
    /// 这个项目的布局（配方），随项目读、library.changed 时重读，见 AppModel.refreshLayouts。
    var layouts: [ProjectLayout] = []
    private(set) var pluginClient: KitedClient?
    private(set) var pluginConnection: UUID
    /// 新代理草稿。已有工作区里的草稿只在本机打开，不同步到其他设备；关闭即丢弃，工作机上不留实例。
    /// 草稿的 ID 由本机生成，就是工作机要为这个代理建的实例 ID：发出第一条消息、工作机建好实例后，这个对象原地变成那个代理、
    /// 进入 threads，排布和卡片都不动，这里换上新的草稿对象（见 update）。
    private(set) var draftThread: WorkThread
    /// 草稿 pane 的 ID（就是 draftThread.id），没打开草稿时为 nil。
    private(set) var draftPane: String?
    /// 新建实例的选择页的 ID：台面空着时它是垫底的窗口（见 WindowLayout.floor），点添加时当场打开成普通窗口（chooserOpen）。
    /// 选好插件后原地变成那个实例，ID 不换（见 AppModel.choose），这里换一个新 ID 给下一次。同草稿一样只在本机、不同步。
    private(set) var chooserPane: String = WorkArea.newPaneID()
    /// 新建页是点添加打开的普通窗口（关掉就丢）；为 false 时它只在台面空着时垫底。
    private(set) var chooserOpen = false
    /// 新建页选了只在后台的插件、自己关掉时交给的实例：关闭的卡片飞进它在停靠栏的那一格（见 instance(of:)）。
    @ObservationIgnored private(set) var handedOff: [String: String] = [:]
    /// 换下新建页、本机先建的实例：工作机明确拒绝时换回新建页（见 settleInstance）。
    @ObservationIgnored private var replacedChooser: String?
    /// 新建页刚变成会话的草稿：会话的原生外框接上时淡入，和淡出的新建页正文交叠（见 takeFadeIn）。
    @ObservationIgnored private var fadingIn: Set<String> = []
    /// 清空上下文时接在原处的草稿：卡片在原位淡入，和原地淡出的旧代理交叠，不从停靠栏飞出来（见 takeReplacement）。
    @ObservationIgnored private var replacements: Set<String> = []
    let layout: WindowLayout
    /// 正在发出的草稿：期间输入区禁用，草稿不能关。
    var creatingInstance: String?
    /// 本机新建、工作机还没建好的实例：当场放进实例集合、放上台面（见 openLocally），正文要用工作机上的实例，等建好再出来（见 isOpening(instance:)）。
    /// 工作机按同一个 ID 建好后由它的列表接上，建不成就收回（见 AppModel.createInstance）。
    private(set) var openingInstances: [RemotePluginInstance] = []
    /// 本机关掉、工作机还没回收的实例：点下去就从台面和停靠栏去掉，关不掉再放回来（见 AppModel.closeInstance）。
    private(set) var closingInstances: Set<String> = []
    /// 本机换了视图、工作机还没确认的实例：实例 ID 到视图和那次请求，当场按它显示；请求有了结果就去掉，以工作机的实例为准（见 AppModel.showInstance）。
    @ObservationIgnored private var switchingViews: [String: (view: String, request: String)] = [:]
    /// 本机归档、工作机还没归档的实例：当场按已归档排，它的卡片一起收掉；归档不成再放回来（见 AppModel.archiveInstances）。
    private(set) var archivingInstances: Set<String> = []
    /// 在路上的关闭请求，按实例。
    @ObservationIgnored var closeRequests: [String: Task<Void, Never>] = [:]
    /// 网络中断、没得到确认的建实例请求：保留同一个 ID 重试，工作机已经建好的不会再建一份（见 AppModel.retryRequests）。
    /// show 是当初要不要放上台面：失败时本机先建的已经收回，重试时照当初的放。
    var failedInstanceRequests: [(request: CreateInstanceRequest, show: Bool)] = []
    var windowError: String?
    var archiveError: String?
    var settingsInstance: RemotePluginInstance?
    var archiveRequest: RemotePluginInstance?
    /// 要清空上下文的代理，见 ClearContextConfirmation。
    var clearRequest: RemotePluginInstance?
    /// 要归档哪个代理空闲的子代理，见 ArchiveIdleSubagentsConfirmation。
    var archiveIdleRequest: RemotePluginInstance?
    /// 代理的活动摘要，按实例 ID。目录快照与单条推送谁新用谁，见 updateActivity。
    private(set) var activities: [String: ThreadActivity] = [:]
    @ObservationIgnored private var activityCursors: [String: EventCursor] = [:]
    /// 本机看过的回合收尾时间，按实例 ID；收尾时间比它新、实例又不在本机台面上的，停靠栏标「完成待查看」。不跨设备同步。
    private(set) var seenTurns: [String: Double] = [:]
    @ObservationIgnored private var visibleInstances: Set<String> = []
    /// 为打开引用新建、工作机还没建好的文件实例：浏览器建出来就收着目录，见 AppModel.openFileReference。
    @ObservationIgnored var referencedFiles: Set<String> = []
    /// 消息里点的本机网页链接、网页地址栏里输入的路径，按预览实例 ID：网页预览打开到链接的路径。页面里的跳转按设备各自保存，这个也只在本机。
    var webLinks: [String: WebLink] = [:]
    /// 要放上台面、还没排进来的实例（instance.show 比目录快一步到，或插件定义还没读到）：一排进来就放上台面，见 show(instance:)。
    @ObservationIgnored private var pendingShow: String?
    /// 停靠栏里展开的家族格，外层在前；只在本机，不保存。
    var dockExpansion: [String] = []
    /// 指针停在停靠栏哪一格上，Mac 据此在左侧浮出名字与状态。
    var dockHover: DockHover?
    /// 停靠栏离前端滚了多远、展开的家族格里面滚了多远，由停靠栏报（见 DockBand）。台面算卡片落点时读一眼（见 StagePlan），
    /// 不观察：滚动时台面不跟着重排，收着的卡片整张透明，要飞出来时才按这一刻的位置起。
    @ObservationIgnored var dockScrollDistance: CGFloat = 0
    @ObservationIgnored var dockFamilyOffset: CGFloat = 0
    /// 停靠栏看得见的那一段多长，由停靠栏报；展开家族格时据此定它最长多长（dockFamilyLimit，展开的那一刻定下，见 toggleDock）。
    @ObservationIgnored var dockVisibleLength: CGFloat = 0
    @ObservationIgnored var dockFamilyLimit: CGFloat?
    /// 正在起名字的布局：存成新布局或改名，见 LayoutNameSheet。
    var layoutSheet: LayoutSheetRequest?
    var layoutError: String?
    /// 这个工作区的代理能加载的 skill，输入框打「/」时列候选用，这个工作区的各个会话共用；见 loadAvailableSkills。
    private(set) var availableSkills: [AvailableSkill] = []
    /// 上次读完的时候与成没成；作废后为 nil。
    @ObservationIgnored private var availableSkillsRead: (at: Date, failed: Bool)?
    /// 正在读的那一次；作废时清掉，它的结果不再要。
    @ObservationIgnored private var availableSkillsReading: UUID?
    var tint: Color { Palette.breeze }
    /// 本机改的名、工作机还没列出来：当场按它显示，工作机的列表跟上就去掉，改不成按那次请求收回（见 AppModel.nameWorkspace）。
    private(set) var pendingName: (name: String, request: UUID)?
    var title: String { pendingName?.name ?? remote.workspace.name }
    var header: PaneHeader { PaneHeader(title: title, subtitle: "工作区") }

    init(remote: RemoteWorkspace, client: KitedClient? = nil, definitions: [RemotePluginDefinition] = [], connection: UUID = UUID(), cursor: EventCursor? = nil) {
        id = remote.id
        pluginConnection = connection
        self.remote = remote
        self.definitions = definitions
        draftThread = WorkThread(workspace: remote.workspace.cwd, workspaceID: remote.id, project: remote.project.name, id: Self.newPaneID())
        instances = remote.instances
        layout = WindowLayout(panes: Self.panes(of: remote.instances, definitions: definitions, draft: nil, chooser: nil),
                              storageKey: "KiteWindowLayout.\(remote.machine.id).\(remote.id)")
        layout.floor = Pane(chooserPane)
        seenTurns = UserDefaults.standard.dictionary(forKey: seenKey) as? [String: Double] ?? [:]
        layout.replaced = { [weak self] old, new in self?.followReplacement(old, new) }
        if let client { update(remote, client: client, connection: connection, cursor: cursor) }
    }

    func update(_ remote: RemoteWorkspace, client: KitedClient, connection: UUID, cursor: EventCursor? = nil) {
        self.remote = remote
        if pendingName?.name == remote.workspace.name { pendingName = nil }
        updateActivities(remote.threads, cursor: cursor)
        pluginClient = client
        pluginConnection = connection
        let previous = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        let instancesByID = Dictionary(uniqueKeysWithValues: remote.instances.map { ($0.id, $0) })
        // 工作机建好了草稿的代理（同一个 ID）：由草稿对象接着当，不另建
        let drafted = draftPane.flatMap { id in instancesByID[id]?.status == .open ? id : nil }
        threads = remote.threads.compactMap { value in
            guard let instance = instancesByID[value.instanceId], instance.status == .open else { return nil }
            if let thread = previous[value.instanceId] ?? (value.instanceId == drafted ? draftThread : nil) {
                if thread === draftThread { thread.adopt(instance: value.instanceId, root: remote.workspace.cwd) }
                thread.title = instance.title; thread.project = remote.project.name
                thread.use(client)
                return thread
            }
            return WorkThread(remote: value, instance: instance, workspace: remote.workspace, project: remote.project.name, client: client)
        }
        // 草稿已经变成代理，留一个新的草稿对象，免得之后按草稿改它的连接状态
        if drafted != nil, !draftThread.isDraft {
            draftPane = nil
            draftThread = WorkThread(workspace: remote.workspace.cwd, workspaceID: remote.id, project: remote.project.name, id: Self.newPaneID())
        }
        rebuild()
        if let settingsInstance, !instances.contains(where: { $0.id == settingsInstance.id && $0.status == .open }) {
            self.settingsInstance = nil
        }
        draftThread.connected = remote.workspace.status == .open
        updateFiles(client: client)
    }

    /// 浏览要读工作机上的实例，本机先建、还没建好的不算。
    func updateFiles(client: KitedClient? = nil) {
        let confirmed = instances.filter { $0.definitionId == AppModel.filesDefinition && $0.status == .open && !isOpening(instance: $0.id) }
        files = Dictionary(uniqueKeysWithValues: confirmed.map { instance in
            // 为引用或网页打开的实例一出来就是内容，目录收着
            let browser = files[instance.id] ?? FileBrowser(instanceID: instance.id, workspaceID: id, client: client,
                                                            showDirectory: !referencedFiles.contains(instance.id) && instance.state?.selection.showsPage != true)
            browser.update(instance, client: client)
            return (instance.id, browser)
        })
    }

    /// 要列 skill 候选时调，读取在 Task 里，视图更新中也能调。读过的一分钟内不重读（项目里的 skill 文件可能变了，没有事件），
    /// 失败的隔几秒再试；资源库的 skill 变了或重连后由 invalidateAvailableSkills 作废，下次调时重读。
    func loadAvailableSkills(client: KitedClient) {
        guard availableSkillsReading == nil else { return }
        if let read = availableSkillsRead, Date().timeIntervalSince(read.at) < (read.failed ? 5 : 60) { return }
        let reading = UUID()
        availableSkillsReading = reading
        Task {
            let result = try? await client.request("/workspaces/\(id)/skills", as: AvailableSkills.self)
            guard availableSkillsReading == reading else { return }
            availableSkillsReading = nil
            availableSkillsRead = (Date(), result == nil)
            if let result, result.skills != availableSkills { availableSkills = result.skills }
        }
    }

    func invalidateAvailableSkills() {
        availableSkillsRead = nil
        availableSkillsReading = nil
    }

    func files(in pane: Pane) -> FileBrowser? { files[pane.id] }

    func thread(in pane: Pane) -> WorkThread? {
        if pane.id == draftThread.id { return draftThread }
        guard view(in: pane)?.renderer == "conversation" else { return nil }
        return threads.first { $0.id == pane.id }
    }

    func definition(of instance: RemotePluginInstance) -> RemotePluginDefinition? {
        definitions.first { $0.id == instance.definitionId }
    }

    /// 实例当前显示的视图：本机刚换、工作机还没确认的先按本机的；没有视图的实例为 nil。
    func currentView(of instance: RemotePluginInstance) -> String? {
        guard let definition = definition(of: instance), !definition.views.isEmpty else { return nil }
        let id = switchingViews[instance.id]?.view ?? instance.view ?? definition.defaultView
        return (definition.views.first { $0.id == id } ?? definition.views.first)?.id
    }

    /// 本工作区运行中终端与预览监听的端口，按端口号排；同一个端口在几个实例里时算一个，能用 HTTP 打开的那个为准。
    var workspacePortStatus: [TerminalStatus.Port] {
        let all = instances.filter { $0.status == .open && $0.state?.terminal?.running == true }.flatMap { $0.state?.terminal?.ports ?? [] }
        return Dictionary(grouping: all, by: \.port).map { port, items in TerminalStatus.Port(port: port, http: items.contains(where: \.http)) }
            .sorted { $0.port < $1.port }
    }

    /// 本工作区运行中终端与预览监听的端口：浏览只能开这些本机网页；设备打开着这个工作区期间都开着转发（见 PortForwarding）。
    var workspacePorts: [Int] { workspacePortStatus.map(\.port) }

    /// 端口还在被本工作区监听才打开；服务停了窗口留着，同一端口再被监听时接着显示。
    func livePort(_ port: Int?) -> Int? { port.flatMap { workspacePorts.contains($0) ? $0 : nil } }

    /// 消息里点的链接（见 AppModel.openLocalPort），端口对得上才在这个实例的网页里打开到它的路径。
    func webLink(for instance: String, port: Int?) -> WebLink? { webLinks[instance].flatMap { $0.target.port == port ? $0 : nil } }

    /// 实例看的端口换了：换到别的端口就从首页看起，回到原来的端口也不再停在之前点的链接上。
    func portChanged(_ instance: String, to port: Int?) {
        if webLinks[instance]?.target.port != port { webLinks[instance] = nil }
    }

    /// 符合条件、打开着的实例，台面上的优先：消息里的链接和引用找实例打开时用。
    func preferredInstance(where matches: (RemotePluginInstance) -> Bool) -> RemotePluginInstance? {
        let candidates = instances.filter { $0.status == .open && matches($0) }
        return candidates.first { isOnStage($0.id) } ?? candidates.first
    }

    /// 实例在本机台面上（宽屏的排布里、紧凑布局是当前窗口）。
    func isOnStage(_ instance: String) -> Bool {
        layout.presentation == .compact ? layout.focused?.id == instance : layout.shown?.panes.contains(Pane(instance)) == true
    }

    /// 预览实例的画面；不是预览时为 nil。
    func previewStatus(of instance: RemotePluginInstance) -> PreviewStatus? {
        instance.definitionId == AppModel.previewDefinition ? instance.state?.preview ?? PreviewStatus() : nil
    }

    /// 本工作区里同一目标与设备的预览（运行中或已结束、还没回收的），同工作机的查找。
    func preview(for spec: PreviewSpec) -> RemotePluginInstance? {
        instances.first { $0.status == .open && $0.definitionId == AppModel.previewDefinition && $0.config?.preview == spec }
    }

    /// 「名字 N」里还没用过的最小编号，同工作机的 numberedTitle。
    private static func numbered(_ name: String, among titles: Set<String>) -> String {
        var number = 1
        while titles.contains("\(name) \(number)") { number += 1 }
        return "\(name) \(number)"
    }

    /// 停下终端或预览的进程就是关闭这个实例（进程实例的存续方式，见 docs/台面与停靠栏.md）：先在本机去掉，关不掉再放回来，失败交给 report。
    func stop(_ instance: RemotePluginInstance, model: AppModel, report: @escaping (String?) -> Void) {
        report(nil)
        model.closeInstance(instance.id, in: self)
    }

    /// 实例的存续方式：关闭即回收、归档，还是进程结束后留到关闭；定义没读到时按归档的算，免得把实例关掉。
    func lifetime(of instance: RemotePluginInstance) -> PluginLifetime {
        definition(of: instance)?.lifetime ?? .persistent
    }

    /// 标题栏上这个 pane 有没有「关闭」：closable、process 的实例有，persistent 的只有归档（放菜单里）；草稿有，新建页打开着（没垫底）时有。
    func hasClose(_ pane: Pane) -> Bool {
        if pane.id == draftPane { return true }
        if pane.id == chooserPane { return chooserOpen && !chooserIsFloor }
        guard let instance = instance(of: pane) else { return false }
        return lifetime(of: instance) != .persistent
    }

    /// 此刻能不能关：正在发出的草稿、本机先建还没建好的实例要等。
    func canClose(_ pane: Pane) -> Bool {
        guard hasClose(pane) else { return false }
        if pane.id == draftPane { return creatingInstance == nil }
        return !isOpening(instance: pane.id)
    }

    /// 新建页此刻是台面的底：台面上没有别的实例（紧凑布局是没有别的窗口），它关不掉。
    var chooserIsFloor: Bool {
        let others = layout.panes.filter { $0.id != chooserPane }
        if layout.presentation == .compact { return others.isEmpty }
        return (layout.root?.panes ?? []).allSatisfy { $0.id == chooserPane }
    }

    /// 停靠栏放不下时堆叠（见 DockBand），不再撑高窗口。
    var minimumSize: CGSize { layout.minimumSize }

    /// 新建页此刻垫在台面底下：它的标题栏上没有缩小、展开、关闭（见 CardButtons）。
    func isFloor(_ pane: Pane) -> Bool { isChooser(pane) && chooserIsFloor }

    func view(in pane: Pane) -> RemotePluginDefinition.PluginView? {
        guard let instance = instance(of: pane), let current = currentView(of: instance) else { return nil }
        return definition(of: instance)?.views.first { $0.id == current }
    }

    /// 插件实例的外观：一个实例一张卡片，卡片和它在停靠栏的头像同一个样子，不随视图换。预览按画面是网页、模拟器还是 App 窗口。
    func appearance(of instance: RemotePluginInstance) -> WindowAppearance {
        switch previewStatus(of: instance)?.screen {
        case .simulator: return .init(name: "模拟器", icon: "iphone")
        case .app: return .init(name: "App 窗口", icon: "macwindow")
        case .web: return .init(name: "网页", icon: "globe")
        case .some(.none), nil: break
        }
        return definition(of: instance).map(WindowAppearance.definition) ?? .renderer("")
    }

    func appearance(of pane: Pane) -> WindowAppearance {
        if pane.id == chooserPane { return .init(name: "新建窗口", icon: "plus") }
        if let thread = thread(in: pane) { return .init(name: thread.title, icon: WindowAppearance.agentIcon, tint: thread.tint, isAgent: true) }
        if let instance = instance(of: pane) {
            var result = appearance(of: instance)
            result.name = instance.title
            return result
        }
        return .init(name: "窗口", icon: "rectangle")
    }

    /// 快照里的摘要只在比已收到的推送新时采用；工作机重启后游标换了一轮，以快照为准。
    private func updateActivities(_ threads: [RemoteThread], cursor: EventCursor?) {
        var next: [String: ThreadActivity] = [:]
        var cursors: [String: EventCursor] = [:]
        for thread in threads {
            let id = thread.instanceId
            if let known = activityCursors[id], cursor.map({ known.covers($0) && known != $0 }) ?? true {
                next[id] = activities[id]
                cursors[id] = known
            } else {
                next[id] = thread.activity
                if let cursor { cursors[id] = cursor }
            }
        }
        if next != activities { activities = next }
        activityCursors = cursors
        markSeen()
    }

    func updateActivity(_ id: String, _ activity: ThreadActivity, cursor: EventCursor) {
        if let known = activityCursors[id], known.covers(cursor) { return }
        activityCursors[id] = cursor
        if activities[id] != activity { activities[id] = activity }
        markSeen()
    }

    /// 本机台面上的实例：宽屏是排布里显示的，紧凑布局是当前窗口。
    func noteVisible(_ ids: Set<String>) {
        visibleInstances = ids
        markSeen()
    }

    func isVisible(instance id: String) -> Bool { visibleInstances.contains(id) }

    /// 回合收尾时实例在台面上，或之后放上了台面，都算看过。子代理不算未查看：交代给它的回合结束时会回报给父代理。
    func unseen(_ id: String) -> Bool {
        guard let settled = activities[id]?.settledAt, !visibleInstances.contains(id), !isSubagent(id) else { return false }
        return settled > seenTurns[id] ?? 0
    }

    private func markSeen() {
        var next = seenTurns.filter { id, _ in instances.contains { $0.id == id && $0.status == .open } }
        for id in visibleInstances {
            if let settled = activities[id]?.settledAt, settled > next[id] ?? 0 { next[id] = settled }
        }
        guard next != seenTurns else { return }
        seenTurns = next
        UserDefaults.standard.set(next, forKey: seenKey)
    }

    private var seenKey: String { "KiteSeenTurns.\(remote.machine.id).\(remote.id)" }

    /// 实例集合是工作机上的实例，减去本机正关的，本机正归档的按已归档算，加上本机正建的；排布里的窗口随之重算。
    private func rebuild() {
        // 工作机列出了本机正建的实例（开着或已经归档），就以它为准
        let known = Set(remote.instances.map(\.id))
        if openingInstances.contains(where: { known.contains($0.id) }) {
            openingInstances.removeAll { known.contains($0.id) }
            replacedChooser = nil
        }
        // 工作机已经归档了的不再算正归档，已经回收了的不再算正关
        let open = remote.instances.filter { $0.status == .open }.map(\.id)
        let stillArchiving = archivingInstances.intersection(open)
        if stillArchiving != archivingInstances { archivingInstances = stillArchiving }
        let stillClosing = closingInstances.intersection(open)
        if stillClosing != closingInstances { closingInstances = stillClosing }
        instances = remote.instances.filter { !closingInstances.contains($0.id) }
            .map { archivingInstances.contains($0.id) ? $0.archived : $0 } + openingInstances
        // 插件定义和实例清单并行读：认得出每个开着的实例有没有视图，清单才算完整，不然冷启动时定义还没到，台面会被清空
        let classified = instances.allSatisfy { $0.status != .open || definition(of: $0) != nil }
        layout.reconcile(Self.panes(of: instances, definitions: definitions, draft: draftPane, chooser: chooserOpen ? chooserPane : nil),
                         complete: pluginClient != nil && classified)
        if let pendingShow, layout.panes.contains(Pane(pendingShow)) {
            self.pendingShow = nil
            layout.activate(Pane(pendingShow))
        }
    }

    /// 把实例放上台面；还没排进来的等它一到，见 pendingShow。
    func show(instance id: String) {
        if layout.panes.contains(Pane(id)) { layout.activate(Pane(id)) } else { pendingShow = id }
    }

    /// 打开布局时先建的实例、草稿都放进排布，再一起摆（见 openLayout）。
    func rebuildForLayout() { rebuild() }

    /// 停靠栏的顺序，就是排布知道的全部窗口：代理在前（含子代理）、工具在后，各按创建先后；草稿排在代理末尾，打开着的新建页排在最后。
    /// 没有视图的实例只在停靠栏占格（见 DockModel），不进排布。
    private static func panes(of instances: [RemotePluginInstance], definitions: [RemotePluginDefinition], draft: String?, chooser: String?) -> [Pane] {
        func definition(_ instance: RemotePluginInstance) -> RemotePluginDefinition? { definitions.first { $0.id == instance.definitionId } }
        let open = instances.filter { $0.status == .open && !(definition($0)?.views.isEmpty ?? true) }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        let agents = open.filter { definition($0)?.agent != nil }, tools = open.filter { definition($0)?.agent == nil }
        return agents.map { Pane($0.id) } + (draft.map { [Pane($0)] } ?? []) + tools.map { Pane($0.id) } + (chooser.map { [Pane($0)] } ?? [])
    }

    /// 先在本机建实例并放上台面，见 openingInstances。ID 是新建页的，就原地换下它（卡片不换），新建页换一个新 ID 给下一次。
    func openLocally(_ instance: RemotePluginInstance) {
        let replacing = chooserPane == instance.id
        if !instances.contains(where: { $0.id == instance.id }) {
            openingInstances.append(instance)
            if replacing {
                replacedChooser = instance.id
                chooserOpen = false
            }
            rebuild()
        }
        layout.activate(Pane(instance.id))
        if replacing { renewChooser() }
    }

    /// 新建页变成了实例或草稿、或者关掉了：下一次新建页用一个新 ID。放在那个窗口接上以后调，台面空着时垫底的才换成新的。
    private func renewChooser() {
        chooserPane = Self.newPaneID()
        layout.floor = Pane(chooserPane)
    }

    /// 先在本机建实例、只放进停靠栏（后台实例，不放上台面），见 openingInstances。
    func createLocally(_ instance: RemotePluginInstance) {
        guard !instances.contains(where: { $0.id == instance.id }) else { return }
        openingInstances.append(instance)
        rebuild()
    }

    /// 本机建的这个实例不再按本机的算：工作机建不成，或建的是别的实例（预览认出同一目标与设备）。还在不在以工作机的列表为准。
    /// rejected 是工作机明确拒绝、没有建：换下新建页的，换回新建页（同一个 ID，卡片不动），好另选一个。
    func settleInstance(_ id: String, rejected: Bool = false) {
        guard openingInstances.contains(where: { $0.id == id }) else { return }
        openingInstances.removeAll { $0.id == id }
        if replacedChooser == id {
            replacedChooser = nil
            if rejected, !chooserOpen {
                chooserPane = id
                chooserOpen = true
                layout.floor = Pane(id)
            }
        }
        rebuild()
        if rejected, chooserOpen, chooserPane == id { layout.activate(Pane(id)) }
    }

    func isOpening(instance id: String) -> Bool { openingInstances.contains { $0.id == id } }

    /// 先在本机给实例换视图，见 switchingViews。
    func switchLocally(_ instance: String, to view: String, request: String) {
        switchingViews[instance] = (view, request)
        rebuild()
    }

    /// 这次换视图的请求有了结果：之后按工作机的实例显示；后来又换了一次的，等后来那次。
    func settleSwitch(_ instance: String, request: String) {
        guard switchingViews[instance]?.request == request else { return }
        switchingViews[instance] = nil
        rebuild()
    }

    /// 先在本机改名，见 pendingName。
    func renameLocally(_ name: String) -> UUID {
        let request = UUID()
        pendingName = (name, request)
        return request
    }

    /// 改名没成：退回工作机上的名字；后来又改了一次的，等后来那次。
    func settleRename(_ request: UUID) {
        if pendingName?.request == request { pendingName = nil }
    }

    /// 本机新建实例时用的标题，和工作机起的一样：代理叫「新代理」，别的按同一插件已有的标题往后编号。
    func newInstanceTitle(_ definition: RemotePluginDefinition) -> String {
        if definition.agent != nil { return "新代理" }
        return Self.numbered(definition.title, among: Set(instances.filter { $0.definitionId == definition.id }.map(\.title)))
    }

    /// 先在本机归档，见 archivingInstances。
    func archiveLocally(_ ids: [String]) {
        guard !archivingInstances.isSuperset(of: ids) else { return }
        archivingInstances.formUnion(ids)
        rebuild()
    }

    /// 工作机没归档：放回来。
    func restoreArchiving(_ ids: [String]) {
        guard !archivingInstances.isDisjoint(with: ids) else { return }
        archivingInstances.subtract(ids)
        rebuild()
    }

    /// 实例操作都有了着落：本机先建、先关、先归档的都等到了工作机的列表。
    var instancesSettled: Bool {
        openingInstances.isEmpty && closingInstances.isEmpty && archivingInstances.isEmpty
    }

    /// 先在本机关掉实例，当场从台面和停靠栏去掉，见 closingInstances。
    func closeLocally(_ id: String) {
        guard !closingInstances.contains(id) else { return }
        closingInstances.insert(id)
        rebuild()
    }

    /// 工作机没关掉：放回来。
    func reopenClosing(_ id: String) {
        guard closingInstances.contains(id) else { return }
        closingInstances.remove(id)
        rebuild()
    }

    static func newPaneID() -> String { UUID().uuidString.lowercased() }

    private func makeDraftThread(id: String) -> WorkThread {
        let thread = WorkThread(workspace: remote.workspace.cwd, workspaceID: remote.id, project: remote.project.name, id: id)
        thread.draftChoice = DraftAgentChoice()
        thread.connected = remote.workspace.status == .open
        return thread
    }

    /// 添加代理时先打开本机草稿；已有草稿时沿用其中的选择。
    /// 每次新开一个草稿对象：关掉的草稿淡出时仍显示原来的模型与输入，不闪成「模型」和空输入框。
    func openDraft() {
        if draftPane == nil {
            draftThread = makeDraftThread(id: Self.newPaneID())
            draftPane = draftThread.id
            rebuild()
        }
        if let draftPane { layout.activate(Pane(draftPane)) }
    }

    /// 打开布局时要一个这个角色的草稿：没有草稿就新开一个，有就换上这个角色；不放上台面，整组一起摆。返回草稿 pane 的 ID。
    func prepareDraft(role: AgentRole) -> String {
        if draftPane == nil {
            draftThread = makeDraftThread(id: Self.newPaneID())
            draftPane = draftThread.id
        }
        draftThread.role = role
        return draftThread.id
    }

    /// 清空上下文：台面上 pane 的位置原地换成新代理的草稿（已有草稿就挪过来用这一份，一份草稿不同时摆在两个窗口里），返回草稿。
    /// 旧代理随后归档，见 AppModel.clearContext。
    func replaceWithDraft(_ pane: Pane) -> WorkThread {
        if draftPane == nil {
            draftThread = makeDraftThread(id: Self.newPaneID())
            draftPane = draftThread.id
            replacements.insert(draftThread.id)
            rebuild()
        }
        layout.replace(pane, with: Pane(draftThread.id))
        return draftThread
    }

    /// 这张卡片是不是清空上下文时接在原处的草稿，问过一次就不再算，见 replacements。
    func takeReplacement(_ pane: Pane) -> Bool { replacements.remove(pane.id) != nil }

    /// 正在发出的草稿不能关：工作机可能已经建好了代理。
    func closeDraft() {
        guard draftPane != nil, creatingInstance == nil else { return }
        draftPane = nil
        rebuild()
    }

    /// 点添加：当场打开新建页，已经开着一个（或垫着底）就调到前面，见 chooserPane。
    func openChooser() {
        if !chooserOpen {
            handedOff = [:]
            chooserOpen = true
            rebuild()
        }
        layout.activate(Pane(chooserPane))
    }

    /// 关掉新建页；垫底的关不掉。instance 是刚建的后台实例，关闭的卡片飞进它那一格。
    func closeChooser(into instance: String? = nil) {
        guard chooserOpen, instance != nil || !chooserIsFloor else { return }
        if let instance { handedOff[chooserPane] = instance }
        chooserOpen = false
        renewChooser()
        rebuild()
    }

    /// 新建页里选了代理：原地变成新代理的草稿，草稿的 ID 就是新建页的。已经有草稿的，关掉新建页、调出那个草稿：一份草稿不同时摆在两个窗口里。
    func chooseAgent() {
        let chooser = chooserPane
        guard draftPane == nil else {
            closeChooser()
            openDraft()
            return
        }
        draftThread = makeDraftThread(id: chooser)
        draftPane = chooser
        chooserOpen = false
        fadingIn.insert(chooser)
        rebuild()
        layout.activate(Pane(chooser))
        renewChooser()
    }

    /// 这个窗口的会话外框接上时要不要淡入，问过一次就不再算，见 fadingIn。
    func takeFadeIn(_ pane: Pane) -> Bool { fadingIn.remove(pane.id) != nil }

    func isChooser(_ pane: Pane) -> Bool { pane.id == chooserPane }
}

extension RemotePluginInstance {
    /// 本机先按已归档算的样子，见 WorkArea.archivingInstances。
    var archived: Self {
        Self(id: id, workspaceId: workspaceId, definitionId: definitionId, title: title, status: .archived,
             createdAt: createdAt, view: view, state: state, config: config, origin: origin)
    }
}

#if DEBUG
extension WorkArea {
    /// 停靠栏预览直接给出各代理的活动摘要，不经工作机。
    func setPreviewActivities(_ value: [String: ThreadActivity]) { activities = value }
}
#endif

struct WindowAppearance {
    var name: String
    let icon: String
    /// 颜色留给代理的状态，代理以外的窗口都用同一种中性色。
    var tint = Palette.stone
    var isAgent = false

    static let agentIcon = "bubble.left.and.bubble.right"

    /// 还没建出实例时按定义取，同建好后的窗口：代理是对话，其余按默认视图。
    static func definition(_ definition: RemotePluginDefinition) -> Self {
        if definition.agent != nil { return .init(name: definition.title, icon: agentIcon, isAgent: true) }
        return renderer(definition.defaultRenderer ?? "")
    }

    static func renderer(_ id: String) -> Self {
        switch id {
        case "files": .init(name: "浏览", icon: "globe")
        case "terminal": .init(name: "终端", icon: "terminal")
        case "preview": .init(name: "预览", icon: "play.rectangle")
        case "preview-grid": .init(name: "并排", icon: "square.grid.2x2")
        case "monitor": .init(name: "监视", icon: "tray")
        default: .init(name: "插件", icon: "puzzlepiece.extension")
        }
    }
}
