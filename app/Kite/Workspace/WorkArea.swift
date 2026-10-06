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
    let layout: WindowLayout
    var creatingThread = false
    var changingWindows = false
    var pendingWindowRequest: OpenWindowRequest?
    var pendingInstanceRequest: CreatePluginInstance?
    var windowError: String?
    var settingsInstance: RemotePluginInstance?
    var tint: Color { Palette.breeze }
    var title: String { remote?.workspace.name ?? "新工作区" }
    var header: PaneHeader { PaneHeader(title: title) }
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
                                  storageKey: remote.machine.id == "sample" ? nil : "KiteWindowLayout.\(remote.machine.id).\(remote.id)",
                                  reconcileOnLoad: client != nil || remote.machine.id == "sample")
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
        return .init(name: "窗口", icon: "rectangle", tint: Palette.stone)
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
        case "files": .init(name: "文件", icon: "folder", tint: Palette.sunwashed)
        case "terminal": .init(name: "终端", icon: "terminal", tint: Palette.stone)
        case "preview": .init(name: "预览", icon: "eye", tint: Palette.dewy)
        default: .init(name: "插件", icon: "puzzlepiece.extension", tint: Palette.buttercup)
        }
    }
}
