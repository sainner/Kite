import SwiftUI

/// 工作机拥有窗口集合；当前设备保留布局、草稿及尚未确认的窗口操作。
@Observable
final class WorkArea: Identifiable {
    let id: String
    var remote: RemoteWorkspace
    var threads: [WorkThread] = []
    var windows: [RemoteWorkspaceWindow] = []
    var instances: [RemotePluginInstance] = []
    var files: [String: FileBrowser] = [:]
    var definitions: [RemotePluginDefinition] = []
    private(set) var pluginClient: KitedClient?
    private(set) var pluginConnection: UUID
    /// 新代理草稿。已有工作区里的草稿只在本机打开，不同步到其他设备；关闭即丢弃，工作机上不留实例。
    /// 发出第一条消息、工作机建好实例后，这个对象原地变成那个代理、进入 threads，这里换上新的草稿对象（见 update）。
    private(set) var draftThread: WorkThread
    /// 草稿窗口的 ID，没打开草稿时为 nil。由本机生成，就是工作机要为这个代理建的窗口 ID，建好后排布和卡片都不动。
    private(set) var draftWindow: String?
    /// 新建窗口的 ID：点添加当场打开的本机窗口，里面选插件，选好后原地变成那个插件的窗口，ID 不换（见 AppModel.choose）。
    /// 同草稿一样只在本机、不同步，关掉就丢掉；没开着时为 nil。
    private(set) var chooserWindow: String?
    /// 新建窗口选了只在后台的插件、自己关掉时交给的实例：关闭的卡片飞进它在停靠栏的那一格（见 instance(of:)）。
    @ObservationIgnored private(set) var handedOff: [String: String] = [:]
    /// 换下新建窗口、本机先开的窗口：工作机明确拒绝时换回新建窗口（见 settleOpening）。
    @ObservationIgnored private var replacedChooser: String?
    /// 新建窗口刚变成会话的窗口：会话的原生外框接上时淡入，和淡出的新建窗口正文交叠（见 takeFadeIn）。
    @ObservationIgnored private var fadingIn: Set<String> = []
    let layout: WindowLayout
    /// 正在发出的草稿窗口：期间输入区禁用，草稿不能关。
    var creatingWindow: String?
    /// 本机打开、工作机还没建好的窗口：点下去就放上台面，和工作机的窗口一起排（见 rebuildWindows）。
    /// 工作机按同一个 ID 建好后由它的列表接上，建不成就收回（见 AppModel.sendWindowRequest）。
    private(set) var openingWindows: [RemoteWorkspaceWindow] = []
    /// 本机新建、工作机还没建好的实例（新建工具窗口、后台实例）：当场放进实例集合，窗口和停靠栏先按它排；
    /// 正文要用工作机上的实例，等建好再出来（见 isOpening(instance:)）。
    private(set) var openingInstances: [RemotePluginInstance] = []
    /// 本机关掉、工作机还没关的窗口：点下去就飞回停靠栏，工作机的列表还有它也不放回来，关不掉再放回来（见 AppModel.closeWindow）。
    private(set) var closingWindows: Set<String> = []
    /// 本机换了视图、工作机还没确认的窗口：窗口 ID 到视图和那次请求，当场按它显示；请求有了结果就去掉，以工作机的列表为准（见 AppModel.sendWindowRequest）。
    @ObservationIgnored private var switchingViews: [String: (view: String, request: String)] = [:]
    /// 本机归档、工作机还没归档的实例：当场按已归档排，它的窗口一起收掉；归档不成再放回来（见 AppModel.archiveInstance）。
    private(set) var archivingInstances: Set<String> = []
    /// 在路上的关窗口请求。之后打开窗口的请求等它们回来再发：工作机先收到打开的话，会把还没关的那个窗口交回来。
    @ObservationIgnored var closeRequests: [String: Task<Void, Never>] = [:]
    /// 网络中断、没得到确认的开窗口和建实例请求：保留同一个 ID 重试，工作机已经建好的不会再建一份（见 AppModel.retryRequests）。
    var failedWindowRequests: [OpenWindowRequest] = []
    var failedInstanceRequests: [CreatePluginInstance] = []
    var windowError: String?
    var archiveError: String?
    var settingsInstance: RemotePluginInstance?
    var archiveRequest: RemotePluginInstance?
    /// 代理的活动摘要，按实例 ID。目录快照与单条推送谁新用谁，见 updateActivity。
    private(set) var activities: [String: ThreadActivity] = [:]
    @ObservationIgnored private var activityCursors: [String: EventCursor] = [:]
    /// 本机看过的回合收尾时间，按实例 ID；收尾时间比它新、窗口又不在本机台面上的，停靠栏标「完成待查看」。不跨设备同步。
    private(set) var seenTurns: [String: Double] = [:]
    @ObservationIgnored private var visibleInstances: Set<String> = []
    /// 为打开引用新建、工作机还没建好的文件实例：浏览器建出来就收着目录，见 AppModel.openFileReference。
    @ObservationIgnored var referencedFiles: Set<String> = []
    /// 消息里点的本机网页链接，按终端实例 ID：网页视图打开到链接的路径。页面里的跳转按设备各自保存，这个也只在本机。
    var webLinks: [String: WebLink] = [:]
    /// 停靠栏里展开的「更多」或家族格，外层在前；只在本机，不保存。
    var dockExpansion: [String] = []
    /// 指针停在停靠栏哪一格上，Mac 据此在左侧浮出名字与状态。
    var dockHover: DockHover?
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
        draftThread = WorkThread(workspace: remote.workspace.cwd, project: remote.project.name)
        let openWindows = remote.windows.filter { $0.state == .open }
        windows = openWindows
        instances = remote.instances
        layout = WindowLayout(panes: openWindows.map { Pane($0.id) },
                              storageKey: "KiteWindowLayout.\(remote.machine.id).\(remote.id)",
                              reconcileOnLoad: client != nil)
        seenTurns = UserDefaults.standard.dictionary(forKey: seenKey) as? [String: Double] ?? [:]
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
        // 工作机建好了草稿的窗口：窗口指向的实例就是草稿变成的代理，由草稿对象接着当，不另建
        let drafted = draftWindow.flatMap { id in remote.windows.first { $0.id == id && $0.state == .open } }?.target.instanceId
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
            draftWindow = nil
            draftThread = WorkThread(workspace: remote.workspace.cwd, project: remote.project.name)
        }
        rebuildWindows()
        if let settingsInstance, !instances.contains(where: { $0.id == settingsInstance.id && $0.status == .open }) {
            self.settingsInstance = nil
        }
        draftThread.connected = remote.workspace.status == .open
        updateFiles(client: client)
    }

    /// 文件浏览要读工作机上的实例，本机先建、还没建好的不算。
    func updateFiles(client: KitedClient? = nil) {
        let confirmed = instances.filter { $0.definitionId == "kite.files" && $0.status == .open && !isOpening(instance: $0.id) }
        files = Dictionary(uniqueKeysWithValues: confirmed.map { instance in
            let browser = files[instance.id] ?? FileBrowser(instanceID: instance.id, workspaceID: id, client: client,
                                                            showDirectory: !referencedFiles.contains(instance.id))
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

    /// 打开实例时先显示哪个视图：终端有监听的端口时是网页，其余是默认视图。
    func openingView(of instance: RemotePluginInstance) -> String? {
        guard let definition = definition(of: instance) else { return nil }
        if instance.state?.terminal?.ports?.isEmpty == false, definition.views.contains(where: { $0.id == "web" }) { return "web" }
        return (definition.views.first { $0.id == definition.defaultView } ?? definition.views.first)?.id
    }

    /// 关掉窗口后实例还在：独立存续的，或者进程还在跑的终端。
    func survivesWindowClose(_ instance: RemotePluginInstance) -> Bool {
        switch definition(of: instance)?.lifetime {
        case .persistent: true
        case .process: instance.state?.terminal?.running == true
        default: false
        }
    }

    /// 停靠栏要放下添加入口、每一格和两组之间的分隔；家族格更长，无窗口的代理每四个小头像占一格，最多两格。
    var minimumSize: CGSize {
        let content = layout.minimumSize
        let dock = DockGeometry.length(of: dockModel(docked: layout.docked, onStage: []))
        return CGSize(width: content.width, height: max(content.height, 2 * Metrics.padding + dock))
    }

    func view(in pane: Pane) -> RemotePluginDefinition.PluginView? {
        guard let target = windows.first(where: { $0.id == pane.id })?.target,
              let instance = instances.first(where: { $0.id == target.instanceId }) else { return nil }
        return definition(of: instance)?.views.first { $0.id == target.viewId }
    }

    /// 插件实例的外观：一个实例一个窗口，窗口和它在停靠栏的小头像同一个样子，不随视图换。
    func appearance(of instance: RemotePluginInstance) -> WindowAppearance {
        definition(of: instance).map(WindowAppearance.definition) ?? .renderer("")
    }

    func appearance(of pane: Pane) -> WindowAppearance {
        if pane.id == chooserWindow { return .init(name: "新建窗口", icon: "plus") }
        if let thread = thread(in: pane) { return .init(name: thread.title, icon: WindowAppearance.agentIcon, tint: thread.tint, isAgent: true) }
        if let target = windows.first(where: { $0.id == pane.id })?.target,
           let instance = instances.first(where: { $0.id == target.instanceId }) {
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

    /// 本机台面上的实例：宽屏是排布里显示的窗口，紧凑布局是当前窗口。
    func noteVisible(_ ids: Set<String>) {
        visibleInstances = ids
        markSeen()
    }

    func isVisible(instance id: String) -> Bool { visibleInstances.contains(id) }

    /// 回合收尾时窗口在台面上，或之后打开了窗口，都算看过。
    func unseen(_ id: String) -> Bool {
        guard let settled = activities[id]?.settledAt, !visibleInstances.contains(id) else { return false }
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

    /// 实例的窗口，一个实例最多一个。
    func window(of instance: String) -> RemoteWorkspaceWindow? {
        windows.first { $0.target.instanceId == instance }
    }

    /// 实例集合是工作机上的实例，本机正归档的按已归档算，加上本机正建的；窗口集合是工作机上打开的窗口，
    /// 减去本机正关的和正归档的实例的，加上本机正开的和草稿。
    private func rebuildWindows() {
        // 工作机列出了本机正开的窗口、正建的实例（开着或已经关了），就以它为准
        let listed = Set(remote.windows.map(\.id))
        if openingWindows.contains(where: { listed.contains($0.id) }) { openingWindows.removeAll { listed.contains($0.id) } }
        let known = Set(remote.instances.map(\.id))
        if openingInstances.contains(where: { known.contains($0.id) }) { openingInstances.removeAll { known.contains($0.id) } }
        // 工作机已经归档了的不再算正归档，已经关了的不再算正关
        let stillArchiving = archivingInstances.intersection(remote.instances.filter { $0.status == .open }.map(\.id))
        if stillArchiving != archivingInstances { archivingInstances = stillArchiving }
        instances = remote.instances.map { archivingInstances.contains($0.id) ? $0.archived : $0 } + openingInstances
        let open = remote.windows.filter { $0.state == .open && $0.id != draftWindow }
        let stillOpen = closingWindows.intersection(open.map(\.id))
        if stillOpen != closingWindows { closingWindows = stillOpen }
        windows = open.filter { !closingWindows.contains($0.id) && !archivingInstances.contains($0.target.instanceId) }
            .map { window in switchingViews[window.id].map { window.showing($0.view) } ?? window } + openingWindows
            + (chooserWindow.map { [Self.chooserWindow($0, workspace: id)] } ?? [])
            + (draftWindow.map { [Self.draftWindow($0, workspace: id, thread: draftThread)] } ?? [])
        layout.reconcile(windows.map { Pane($0.id) })
    }

    /// 先在本机打开窗口，当场放上台面，见 openingWindows。ID 是新建窗口的，就原地换下它（见 chooserWindow）。
    func openLocally(_ window: RemoteWorkspaceWindow) {
        let replacing = chooserWindow == window.id
        if replacing {
            chooserWindow = nil
            replacedChooser = window.id
        }
        if replacing || !windows.contains(where: { $0.id == window.id }) {
            openingWindows.append(window)
            rebuildWindows()
        }
        layout.activate(Pane(window.id))
    }

    /// 本机打开的这个窗口不再按本机的算：工作机建不成，或交回了这个实例原有的窗口。还在不在以工作机的列表为准。
    /// rejected 是工作机明确拒绝、没有建：换下新建窗口的，换回新建窗口，好另选一个。
    func settleOpening(_ id: String, rejected: Bool = false) {
        guard openingWindows.contains(where: { $0.id == id }) else { return }
        openingWindows.removeAll { $0.id == id }
        if replacedChooser == id {
            replacedChooser = nil
            if rejected, chooserWindow == nil { chooserWindow = id }
        }
        rebuildWindows()
    }

    func isOpening(_ pane: Pane) -> Bool { openingWindows.contains { $0.id == pane.id } }

    /// 先在本机给窗口换视图，见 switchingViews。
    func switchLocally(_ window: String, to view: String, request: String) {
        switchingViews[window] = (view, request)
        rebuildWindows()
    }

    /// 这次换视图的请求有了结果：之后按工作机的列表显示；后来又换了一次的，等后来那次。
    func settleSwitch(_ window: String, request: String) {
        guard switchingViews[window]?.request == request else { return }
        switchingViews[window] = nil
        rebuildWindows()
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

    /// 先在本机建实例，见 openingInstances。
    func createLocally(_ instance: RemotePluginInstance) {
        guard !instances.contains(where: { $0.id == instance.id }) else { return }
        openingInstances.append(instance)
        rebuildWindows()
    }

    /// 本机建的这个实例工作机建不成：收回。
    func settleInstance(_ id: String) {
        guard openingInstances.contains(where: { $0.id == id }) else { return }
        openingInstances.removeAll { $0.id == id }
        rebuildWindows()
    }

    func isOpening(instance id: String) -> Bool { openingInstances.contains { $0.id == id } }

    /// 本机新建实例时用的标题，和工作机起的一样：代理叫「新代理」，带窗口的按同一插件已有的标题往后编号，后台实例用插件名。
    func newInstanceTitle(_ definition: RemotePluginDefinition) -> String {
        if definition.agent != nil { return "新代理" }
        guard !definition.views.isEmpty else { return definition.title }
        let titles = Set(instances.filter { $0.definitionId == definition.id }.map(\.title))
        var number = 1
        while titles.contains("\(definition.title) \(number)") { number += 1 }
        return "\(definition.title) \(number)"
    }

    /// 先在本机归档，见 archivingInstances。
    func archiveLocally(_ id: String) {
        guard !archivingInstances.contains(id) else { return }
        archivingInstances.insert(id)
        rebuildWindows()
    }

    /// 工作机没归档：放回来。
    func restoreArchiving(_ id: String) {
        guard archivingInstances.contains(id) else { return }
        archivingInstances.remove(id)
        rebuildWindows()
    }

    /// 窗口操作都有了着落：本机先开、先关、先建、先归档的都等到了工作机的列表。
    var windowsSettled: Bool {
        openingWindows.isEmpty && closingWindows.isEmpty && openingInstances.isEmpty && archivingInstances.isEmpty
    }

    /// 先在本机关掉窗口，当场飞回停靠栏，见 closingWindows。
    func closeLocally(_ id: String) {
        guard !closingWindows.contains(id) else { return }
        closingWindows.insert(id)
        rebuildWindows()
    }

    /// 工作机没关掉：放回来。
    func reopenClosing(_ id: String) {
        guard closingWindows.contains(id) else { return }
        closingWindows.remove(id)
        rebuildWindows()
    }

    private static func newWindowID() -> String { UUID().uuidString.lowercased() }

    private static func draftWindow(_ id: String, workspace: String, thread: WorkThread) -> RemoteWorkspaceWindow {
        RemoteWorkspaceWindow(id: id, workspaceId: workspace,
                              target: WindowTarget(instanceId: thread.id, viewId: "conversation"), state: .open, createdAt: 0)
    }

    private func makeDraftThread() -> WorkThread {
        let thread = WorkThread(workspace: remote.workspace.cwd, project: remote.project.name)
        thread.draftChoice = DraftAgentChoice()
        thread.connected = remote.workspace.status == .open
        return thread
    }

    /// 添加代理时先打开本机草稿；已有草稿时沿用其中的选择。
    /// 每次新开一个草稿对象：关掉的草稿淡出时仍显示原来的模型与输入，不闪成「模型」和空输入框。
    func openDraft() {
        if draftWindow == nil {
            draftThread = makeDraftThread()
            draftWindow = Self.newWindowID()
            rebuildWindows()
        }
        if let draftWindow { layout.activate(Pane(draftWindow)) }
    }

    /// 正在发出的草稿不能关：工作机可能已经建好了代理。
    func closeDraft() {
        guard draftWindow != nil, creatingWindow == nil else { return }
        draftWindow = nil
        rebuildWindows()
    }

    /// 点添加：当场打开新建窗口，已经开着一个就调到前面，见 chooserWindow。
    func openChooser() {
        if chooserWindow == nil {
            handedOff = [:]
            chooserWindow = Self.newWindowID()
            rebuildWindows()
        }
        if let chooserWindow { layout.activate(Pane(chooserWindow)) }
    }

    /// 关掉新建窗口；instance 是刚建的后台实例，关闭的卡片飞进它那一格。
    func closeChooser(into instance: String? = nil) {
        guard let chooserWindow else { return }
        if let instance { handedOff[chooserWindow] = instance }
        self.chooserWindow = nil
        rebuildWindows()
    }

    /// 新建窗口里选了代理：原地变成新代理的草稿。已经有草稿窗口的，关掉新建窗口、调出那个草稿：一份草稿不同时摆在两个窗口里。
    func chooseAgent() {
        guard let chooser = chooserWindow else { return }
        guard draftWindow == nil else {
            closeChooser()
            openDraft()
            return
        }
        draftThread = makeDraftThread()
        chooserWindow = nil
        draftWindow = chooser
        fadingIn.insert(chooser)
        rebuildWindows()
    }

    /// 这个窗口的会话外框接上时要不要淡入，问过一次就不再算，见 fadingIn。
    func takeFadeIn(_ pane: Pane) -> Bool { fadingIn.remove(pane.id) != nil }

    /// 新建窗口还没有实例和视图，按这个固定的目标排（见 PaneBody）。
    static let chooserInstance = "new-window"

    private static func chooserWindow(_ id: String, workspace: String) -> RemoteWorkspaceWindow {
        RemoteWorkspaceWindow(id: id, workspaceId: workspace, target: WindowTarget(instanceId: chooserInstance, viewId: "chooser"),
                              state: .open, createdAt: 0)
    }
}

extension RemotePluginInstance {
    /// 本机先按已归档算的样子，见 WorkArea.archivingInstances。
    var archived: Self {
        Self(id: id, workspaceId: workspaceId, definitionId: definitionId, title: title, status: .archived, presentation: presentation,
             createdAt: createdAt, state: state, config: config, origin: origin)
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
    /// 最小化后的圆角：代理是圆，其余是圆角矩形。
    /// 工具的圆角随格子大小缩放，和停靠栏里画的一样（见 DockFace）：关进小头像时，飞到终点的卡片和接手的小头像同形。
    func minimizedCornerRadius(width: CGFloat = Metrics.dragBubble) -> CGFloat {
        isAgent ? width / 2 : Metrics.dockRadius * width / Metrics.dragBubble
    }

    static let agentIcon = "bubble.left.and.bubble.right"

    /// 还没建出实例时按定义取，同建好后的窗口：代理是对话，其余按默认视图。
    static func definition(_ definition: RemotePluginDefinition) -> Self {
        if definition.agent != nil { return .init(name: definition.title, icon: agentIcon, isAgent: true) }
        return renderer(definition.defaultRenderer ?? "")
    }

    static func renderer(_ id: String) -> Self {
        switch id {
        case "files": .init(name: "文件", icon: "folder")
        case "terminal": .init(name: "终端", icon: "terminal")
        case "preview": .init(name: "网页", icon: "globe")
        case "monitor": .init(name: "监视", icon: "tray")
        default: .init(name: "插件", icon: "puzzlepiece.extension")
        }
    }
}
