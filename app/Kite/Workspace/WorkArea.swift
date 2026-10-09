import SwiftUI

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
    /// 已有工作区里的新代理草稿只在本机打开，不同步到其他设备；关闭即丢弃，工作机上不留实例。
    private(set) var draftOpen = false
    static let draftWindowID = "draft-window"
    let layout: WindowLayout
    /// 草稿发出后将换成的窗口，ID 由本机生成。结果返回前它先不进排布，由 finishDraft 放到草稿的位置，
    /// 不先收进停靠栏再展开；请求失败时再照常收进停靠栏。其他新窗口不受影响。
    var creatingWindow: String? {
        didSet { if creatingWindow == nil { layout.reconcile(windows.map { Pane($0.id) }) } }
    }
    var changingWindows = false
    var pendingWindowRequest: OpenWindowRequest?
    var pendingInstanceRequest: CreatePluginInstance?
    var windowError: String?
    var settingsInstance: RemotePluginInstance?
    var archiveRequest: RemotePluginInstance?
    /// 代理的活动摘要，按实例 ID。目录快照与单条推送谁新用谁，见 updateActivity。
    private(set) var activities: [String: ThreadActivity] = [:]
    @ObservationIgnored private var activityCursors: [String: EventCursor] = [:]
    /// 本机看过的回合收尾时间，按实例 ID；收尾时间比它新、窗口又不在本机台面上的，停靠栏标「完成待查看」。不跨设备同步。
    private(set) var seenTurns: [String: Double] = [:]
    @ObservationIgnored private var visibleInstances: Set<String> = []
    /// 停靠栏里展开的文件夹或家族格，外层在前；只在本机，不保存。
    var dockExpansion: [String] = []
    /// 指针停在停靠栏哪一格上，Mac 据此在左侧浮出名字与状态。
    var dockHover: DockHover?
    var tint: Color { Palette.breeze }
    var title: String { remote?.workspace.name ?? "新工作区" }
    var header: PaneHeader { PaneHeader(title: title, subtitle: "工作区") }
    var isDraft: Bool { remote == nil }

    init(remote: RemoteWorkspace? = nil, client: KitedClient? = nil, definitions: [RemotePluginDefinition] = [], connection: UUID = UUID(), cursor: EventCursor? = nil) {
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
                                  storageKey: "KiteWindowLayout.\(remote.machine.id).\(remote.id)",
                                  reconcileOnLoad: client != nil)
        } else {
            let draft = Self.draftWindow(workspace: id, thread: draftThread)
            windows = [draft]
            layout = WindowLayout(panes: [Pane(draft.id)])
        }
        if let remote {
            seenTurns = UserDefaults.standard.dictionary(forKey: seenKey(remote)) as? [String: Double] ?? [:]
            if let client { update(remote, client: client, connection: connection, cursor: cursor) }
        }
    }

    func update(_ remote: RemoteWorkspace, client: KitedClient, connection: UUID, cursor: EventCursor? = nil) {
        self.remote = remote
        updateActivities(remote.threads, cursor: cursor)
        pluginClient = client
        pluginConnection = connection
        let previous = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        let instancesByID = Dictionary(uniqueKeysWithValues: remote.instances.map { ($0.id, $0) })
        threads = remote.threads.compactMap { value in
            guard let instance = instancesByID[value.instanceId], instance.status == .open else { return nil }
            if let thread = previous[value.instanceId] {
                thread.title = instance.title; thread.project = remote.project.name
                thread.use(client)
                return thread
            }
            return WorkThread(remote: value, instance: instance, workspace: remote.workspace, project: remote.project.name, client: client)
        }
        instances = remote.instances
        if let settingsInstance, !instances.contains(where: { $0.id == settingsInstance.id && $0.status == .open }) {
            self.settingsInstance = nil
        }
        windows = remote.windows.filter { $0.state == .open } + (draftOpen ? [Self.draftWindow(workspace: id, thread: draftThread)] : [])
        layout.reconcile(windows.map { Pane($0.id) }.filter { $0.id != creatingWindow || layout.panes.contains($0) })
        draftThread.connected = remote.workspace.status == .open
        updateFiles(client: client)
    }

    func updateFiles(client: KitedClient? = nil) {
        files = Dictionary(uniqueKeysWithValues: instances.filter { $0.definitionId == "kite.files" && $0.status == .open }.map { instance in
            let browser = files[instance.id] ?? FileBrowser(instanceID: instance.id, workspaceID: id, client: client)
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

    /// 停靠栏要放下添加入口、每一格和两组之间的分隔；无窗口的代理都收在文件夹里，只占一格。
    var minimumSize: CGSize {
        let content = layout.minimumSize
        let dock = dockModel(docked: layout.docked, onStage: [])
        let cells = 1 + dock.agents.count + dock.tools.count
        let divider = dock.agents.isEmpty || dock.tools.isEmpty ? 0 : DockGeometry.dividerExtra
        return CGSize(width: content.width, height: max(content.height,
            2 * Metrics.padding + CGFloat(cells) * (Metrics.dragBubble + Metrics.gap) - Metrics.gap + divider))
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
        return .init(name: "窗口", icon: "rectangle", tint: Palette.stone)
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

    /// 回合收尾时窗口在台面上，或之后打开了窗口，都算看过。
    func unseen(_ id: String) -> Bool {
        guard let settled = activities[id]?.settledAt, !visibleInstances.contains(id) else { return false }
        return settled > seenTurns[id] ?? 0
    }

    private func markSeen() {
        guard let remote else { return }
        var next = seenTurns.filter { id, _ in instances.contains { $0.id == id && $0.status == .open } }
        for id in visibleInstances {
            if let settled = activities[id]?.settledAt, settled > next[id] ?? 0 { next[id] = settled }
        }
        guard next != seenTurns else { return }
        seenTurns = next
        UserDefaults.standard.set(next, forKey: seenKey(remote))
    }

    private func seenKey(_ remote: RemoteWorkspace) -> String { "KiteSeenTurns.\(remote.machine.id).\(remote.id)" }

    func activateWindow(for target: WindowTarget) {
        if let window = windows.first(where: { $0.target == target }) { layout.activate(Pane(window.id)) }
    }

    private static func draftWindow(workspace: String, thread: WorkThread) -> RemoteWorkspaceWindow {
        RemoteWorkspaceWindow(id: draftWindowID, workspaceId: workspace,
                              target: WindowTarget(instanceId: thread.id, viewId: "conversation"), state: .open, createdAt: 0)
    }

    /// 添加代理时先打开本机草稿；已有草稿时沿用其中的选择。
    func openDraft() {
        guard !isDraft else { return }
        if !draftOpen {
            draftThread.draft = ""
            draftThread.role = nil
            draftThread.draftChoice = DraftAgentChoice()
            draftThread.agentCapabilities = nil
            draftThread.agentOptions = nil
            draftThread.error = nil
            draftOpen = true
            windows.append(Self.draftWindow(workspace: id, thread: draftThread))
            layout.reconcile(windows.map { Pane($0.id) })
        }
        layout.activate(Pane(Self.draftWindowID))
    }

    func closeDraft() {
        guard draftOpen else { return }
        layout.reconcile(dropDraft().map { Pane($0.id) })
    }

    /// 草稿发出后由新建的真实窗口接替原来的位置和焦点。
    func finishDraft(into id: String) {
        guard windows.contains(where: { $0.id == id }) else { return }
        let draft = Pane(Self.draftWindowID)
        if layout.panes.contains(draft) { layout.replace(draft, with: Pane(id)) }
        else { layout.activate(Pane(id)) }
        layout.reconcile(dropDraft().map { Pane($0.id) })
    }

    /// 草稿的内容留到下次 openDraft 再清：窗口淡出时仍显示原来的模型与输入，不闪成「模型」和空输入框。
    private func dropDraft() -> [RemoteWorkspaceWindow] {
        draftOpen = false
        windows.removeAll { $0.id == Self.draftWindowID }
        return windows
    }
}

struct WindowAppearance {
    var name: String
    let icon: String
    let tint: Color
    var isAgent = false
    /// 最小化后的圆角：代理是圆，其余是圆角矩形。
    func minimizedCornerRadius(width: CGFloat = Metrics.dragBubble) -> CGFloat { isAgent ? width / 2 : Metrics.dockRadius }

    static func renderer(_ id: String) -> Self {
        switch id {
        case "files": .init(name: "文件", icon: "folder", tint: Palette.sunwashed)
        case "terminal": .init(name: "终端", icon: "terminal", tint: Palette.stone)
        case "preview": .init(name: "预览", icon: "eye", tint: Palette.dewy)
        default: .init(name: "插件", icon: "puzzlepiece.extension", tint: Palette.buttercup)
        }
    }
}
