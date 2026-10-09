import SwiftUI

extension View {
    /// Debug build 带 --dock-preview 启动时换成停靠栏预览；服务连接照常建立，用来读角色签名。
    @ViewBuilder func dockPreview() -> some View {
        #if DEBUG
        if DockPreview.enabled { DockPreview() } else { self }
        #else
        self
        #endif
    }
}

#if DEBUG
/// 停靠栏预览：用真实的停靠栏组件画造出来的实例、窗口和活动，不建工作区、不发请求，也不接点击。
/// 头像签名取已连接工作机上的角色，没连上时都是默认图案。
struct DockPreview: View {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--dock-preview") }

    @Environment(AppModel.self) private var model
    @State private var scenes: DockPreviewScenes?

    var body: some View {
        let machine = model.activeConnection?.machine
        ScrollView {
            if let scenes {
                VStack(alignment: .leading, spacing: 40) {
                    header(machine: scenes.signed ? machine : nil)
                    DockPreviewStates(scene: scenes.states)
                    DockPreviewFamilies(scene: scenes.states)
                    DockPreviewTools(scene: scenes.states)
                    DockPreviewDocks(scenes: [scenes.common, scenes.crowded])
                    DockPreviewPanels(family: scenes.common, more: scenes.crowded)
                }
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .task(id: "\(machine?.id ?? "")|\(model.connected)") { await load(machine) }
    }

    private func header(machine: RemoteMachine?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("停靠栏预览").font(Theme.display)
            Text(machine.map { "头像签名取自 \($0.name) 上的角色。" } ?? "没有读到角色，头像都是默认图案。")
                .font(Theme.secondary).foregroundStyle(.secondary)
            Text("格子 \(Int(Metrics.dragBubble))pt，小头像 \(Int(DockGeometry.miniSize))pt。运行中的头像会动。")
                .font(Theme.secondary).foregroundStyle(.secondary)
        }
    }

    /// 先用默认图案排出来，读到角色后换上签名：有签名的角色排前面，各行换着用。
    private func load(_ machine: RemoteMachine?) async {
        let machine = machine ?? RemoteMachine(id: "dock-preview", name: "预览", createdAt: 0)
        let first = DockPreviewScenes(machine: machine, roles: [])
        scenes = first
        try? await model.ensureRoles(in: first.states.area)
        let roles = model.roles(in: first.states.area)?.roles ?? []
        let ids = (roles.filter { $0.emblem != nil } + roles.filter { $0.emblem == nil }).map(\.id)
        if !ids.isEmpty { scenes = DockPreviewScenes(machine: machine, roles: ids) }
    }
}

/// 预览的几组数据，每组一个造出来的工作区。
private struct DockPreviewScenes {
    let states: DockPreviewScene
    let common: DockPreviewScene
    let crowded: DockPreviewScene
    let signed: Bool

    init(machine: RemoteMachine, roles: [String]) {
        signed = !roles.isEmpty
        states = Self.states(machine: machine, roles: roles)
        common = Self.common(machine: machine, roles: roles)
        crowded = Self.crowded(machine: machine, roles: roles)
    }

    /// 每种状态一列：同一种样子的头像在各状态下并排。
    private static func states(machine: RemoteMachine, roles: [String]) -> DockPreviewScene {
        var b = DockPreviewBuilder(machine: machine, workspace: "dock-preview.states", roles: roles)
        var panes: [DockEntry] = [], lone: [DockEntry] = [], families: [DockEntry] = [], staged: [DockEntry] = [], minis: [DockEntry] = []
        for state in DockPreviewState.allCases {
            let agent = b.agent("窗口 · \(state.title)", role: 0, state: state, window: .docked)
            panes.append(.pane(b.pane(of: agent)!))
            lone.append(.instance(b.agent("没有窗口 · \(state.title)", role: 1, state: state)))

            let parent = b.agent("家族 · \(state.title)", role: 2, state: state, window: .docked)
            let kids = [b.agent("子代理", role: 3, parent: parent.id), b.agent("子代理", role: 4, parent: parent.id)]
            families.append(.family(DockFamily(parent: parent, pane: b.pane(of: parent), onStage: false, children: kids.map(DockEntry.instance))))

            let shown = b.agent("台面上的父代理", role: 2, window: .stage)
            let kid = b.agent("子代理 · \(state.title)", role: 3, state: state, parent: shown.id)
            let other = b.agent("子代理", role: 4, parent: shown.id)
            staged.append(.family(DockFamily(parent: shown, pane: b.pane(of: shown), onStage: true, children: [.instance(kid), .instance(other)])))

            let windowless = b.agent("没有窗口的家族 · \(state.title)", role: 2, state: state)
            let child = b.agent("子代理", role: 3, parent: windowless.id)
            minis.append(.family(DockFamily(parent: windowless, pane: nil, onStage: false, children: [.instance(child)])))
        }
        b.rows = [
            DockPreviewRow(title: "窗口缩在停靠栏", note: nil, mini: false, entries: panes),
            DockPreviewRow(title: "当前窗口", note: "窄屏底栏里正显示的窗口，不显示状态", mini: false, entries: panes, current: true),
            DockPreviewRow(title: "没有窗口", note: "停靠栏底部的小头像", mini: true, entries: lone),
            DockPreviewRow(title: "家族格", note: "父代理窗口缩在停靠栏，列是父代理的状态", mini: false, entries: families),
            DockPreviewRow(title: "家族格 · 父代理在台面上", note: "列是紧挨父代理的第一个子代理的状态", mini: false, entries: staged),
            DockPreviewRow(title: "家族 · 小头像", note: "父代理没有窗口，列是父代理的状态", mini: true, entries: minis),
        ]

        let states: [DockPreviewState] = [.idle, .waiting, .failed, .idle, .idle]
        for count in [1, 2, 3, 5] {
            let parent = b.agent("\(count) 个子代理", role: 2, state: .running, window: .docked)
            let kids = (0..<count).map { b.agent("子代理", role: 3 + $0, state: states[$0], parent: parent.id) }
            b.families.append(DockPreviewTool(title: "\(count) 个子代理", entry: .family(DockFamily(
                parent: parent, pane: b.pane(of: parent), onStage: false, children: kids.map(DockEntry.instance)))))
        }

        let files = b.tool("文件", .previewFiles, window: .docked), terminal = b.tool("终端", .previewTerminal, window: .docked)
        let web = b.tool("预览", .previewWeb, window: .docked), plugin = b.tool("插件", .previewPlugin, window: .docked)
        let current = b.tool("文件", .previewFiles, window: .docked)
        b.tools = [
            DockPreviewTool(title: "文件窗口", entry: .pane(b.pane(of: files)!)),
            DockPreviewTool(title: "终端窗口", entry: .pane(b.pane(of: terminal)!)),
            DockPreviewTool(title: "预览窗口", entry: .pane(b.pane(of: web)!)),
            DockPreviewTool(title: "插件窗口", entry: .pane(b.pane(of: plugin)!)),
            DockPreviewTool(title: "窄屏当前窗口", entry: .pane(b.pane(of: current)!), current: true),
            DockPreviewTool(title: "没有窗口的工具", entry: .instance(b.tool("文件", .previewFiles)), mini: true),
            DockPreviewTool(title: "后台实例", entry: .instance(b.tool("索引", .previewBackground)), mini: true),
        ]
        return b.build()
    }

    /// 常见的一屏：有窗口的代理、带子代理的家族、工具，和几个没有窗口的代理与工具。
    private static func common(machine: RemoteMachine, roles: [String]) -> DockPreviewScene {
        var b = DockPreviewBuilder(machine: machine, workspace: "dock-preview.common", roles: roles)
        b.title = "常见"
        b.agent("主会话", role: 0, state: .running, window: .stage)
        let parent = b.agent("重构停靠栏", role: 3, state: .waiting, window: .docked)
        b.agent("查引用", role: 4, state: .running, parent: parent.id)
        b.agent("跑检查", role: 1, state: .failed, parent: parent.id)
        b.agent("整理文档", role: 1, state: .running, window: .docked)
        b.agent("修登录", role: 2, state: .unseen, window: .docked)
        b.tool("文件", .previewFiles, window: .docked)
        b.tool("终端", .previewTerminal, window: .docked)
        b.tool("索引", .previewBackground)
        b.agent("调研", role: 2, state: .waiting)
        b.agent("写测试", role: 3, state: .failed)
        b.agent("翻译", role: 4, state: .unseen)
        return b.build()
    }

    /// 没有窗口的超过八个：前七个排开，其余收进「更多」。
    private static func crowded(machine: RemoteMachine, roles: [String]) -> DockPreviewScene {
        var b = DockPreviewBuilder(machine: machine, workspace: "dock-preview.crowded", roles: roles)
        b.title = "小头像排满"
        b.agent("主会话", role: 0, window: .stage)
        b.agent("整理文档", role: 1, state: .running, window: .docked)
        let states: [DockPreviewState] = [.idle, .running, .waiting, .idle, .failed, .unseen, .idle, .running, .idle, .finishing]
        for (index, state) in states.enumerated() {
            let agent = b.agent("后台 \(index + 1)", role: index, state: state)
            if index == 3 { b.agent("子代理", role: index + 1, state: .running, parent: agent.id) }
        }
        return b.build()
    }
}

/// 一组造出来的实例和窗口。docked 是停靠栏里的窗口，按停靠顺序；onStage 是台面上的。
private struct DockPreviewScene {
    let title: String
    let area: WorkArea
    let docked: [Pane]
    let onStage: Set<Pane>
    let rows: [DockPreviewRow]
    let tools: [DockPreviewTool]
    let families: [DockPreviewTool]

    var model: DockModel { area.dockModel(docked: docked, onStage: onStage) }
}

private struct DockPreviewRow: Identifiable {
    let title: String
    let note: String?
    let mini: Bool
    let entries: [DockEntry]
    var current = false
    var id: String { title }
}

private struct DockPreviewTool: Identifiable {
    let title: String
    let entry: DockEntry
    var mini = false
    var current = false
    var id: String { entry.id }
}

private extension DockEntry {
    var pane: Pane? { if case .pane(let pane) = self { pane } else { nil } }
}

private enum DockPreviewState: CaseIterable {
    case idle, running, stopping, finishing, waiting, failed, unseen

    var title: String {
        switch self {
        case .idle: "空闲"
        case .running: "运行中"
        case .stopping: "正在停止"
        case .finishing: "正在收尾"
        case .waiting: "等待继续"
        case .failed: "失败"
        case .unseen: "完成未查看"
        }
    }

    /// 完成未查看要有比本机已读记录新的收尾时间，按现在算。
    var activity: ThreadActivity {
        let now = Date().timeIntervalSince1970 * 1000
        return switch self {
        case .idle: ThreadActivity(phase: "idle", waitingForResume: false)
        case .running: ThreadActivity(phase: "running", waitingForResume: false)
        case .stopping: ThreadActivity(phase: "stopping", waitingForResume: false)
        case .finishing: ThreadActivity(phase: "finishing", waitingForResume: false)
        case .waiting: ThreadActivity(phase: "idle", waitingForResume: true)
        case .failed: ThreadActivity(phase: "idle", waitingForResume: false, outcome: "failed", settledAt: now)
        case .unseen: ThreadActivity(phase: "idle", waitingForResume: false, outcome: "completed", settledAt: now)
        }
    }
}

private extension RemotePluginDefinition {
    static let previewAgent = RemotePluginDefinition(id: "preview.agent", title: "代理", lifetime: .persistent,
                                                     views: [.init(id: "conversation", title: "对话", renderer: "conversation")],
                                                     defaultView: "conversation", agent: .init(runtime: .harness))
    static let previewFiles = previewTool("preview.files", renderer: "files")
    static let previewTerminal = previewTool("preview.terminal", renderer: "terminal")
    static let previewWeb = previewTool("preview.web", renderer: "preview")
    static let previewPlugin = previewTool("preview.plugin", renderer: "custom")
    static let previewBackground = RemotePluginDefinition(id: "preview.background", title: "后台", lifetime: .persistent,
                                                          views: [], defaultView: "", agent: nil)
    static let previewAll = [previewAgent, previewFiles, previewTerminal, previewWeb, previewPlugin, previewBackground]

    private static func previewTool(_ id: String, renderer: String) -> RemotePluginDefinition {
        RemotePluginDefinition(id: id, title: renderer, lifetime: .persistent, views: [.init(id: "main", title: renderer, renderer: renderer)],
                               defaultView: "main", agent: nil)
    }
}

/// 按创建先后造实例；agent 的 role 是角色列表里的序号，循环着用。
private struct DockPreviewBuilder {
    enum Window { case none, docked, stage }

    let machine: RemoteMachine
    let workspace: String
    let roles: [String]
    var title = ""
    var rows: [DockPreviewRow] = []
    var families: [DockPreviewTool] = []
    var tools: [DockPreviewTool] = []
    private var instances: [RemotePluginInstance] = []
    private var windows: [RemoteWorkspaceWindow] = []
    private var activities: [String: ThreadActivity] = [:]
    private var docked: [Pane] = []
    private var onStage: Set<Pane> = []

    init(machine: RemoteMachine, workspace: String, roles: [String]) {
        self.machine = machine
        self.workspace = workspace
        self.roles = roles
    }

    @discardableResult
    mutating func agent(_ title: String, role: Int, state: DockPreviewState = .idle, window: Window = .none, parent: String? = nil) -> RemotePluginInstance {
        let config = InstanceAgentConfig(role: roles.isEmpty ? nil : .init(id: roles[role % roles.count]))
        let instance = add(title, definition: .previewAgent, config: config, parent: parent, window: window)
        activities[instance.id] = state.activity
        return instance
    }

    @discardableResult
    mutating func tool(_ title: String, _ definition: RemotePluginDefinition, window: Window = .none) -> RemotePluginInstance {
        add(title, definition: definition, config: nil, parent: nil, window: window)
    }

    func pane(of instance: RemotePluginInstance) -> Pane? {
        windows.first { $0.target.instanceId == instance.id }.map { Pane($0.id) }
    }

    private mutating func add(_ title: String, definition: RemotePluginDefinition, config: InstanceAgentConfig?, parent: String?,
                              window: Window) -> RemotePluginInstance {
        let instance = RemotePluginInstance(id: "\(workspace).\(instances.count)", workspaceId: workspace, definitionId: definition.id,
                                            title: title, status: .open, presentation: .background, createdAt: instances.count,
                                            config: config, origin: parent.map { .init(instanceId: $0) })
        instances.append(instance)
        if let view = definition.views.first, window != .none {
            let pane = Pane("window.\(instance.id)")
            windows.append(RemoteWorkspaceWindow(id: pane.id, workspaceId: workspace, target: .init(instanceId: instance.id, viewId: view.id),
                                                 state: .open, createdAt: windows.count))
            if window == .docked { docked.append(pane) } else { onStage.insert(pane) }
        }
        return instance
    }

    func build() -> DockPreviewScene {
        let project = RemoteProject(id: "dock-preview", name: "停靠栏预览", remote: "preview/dock", createdAt: 0)
        let checkout = RemoteCheckout(id: "dock-preview", projectId: project.id, machineId: machine.id, path: "/", remote: project.remote, createdAt: 0)
        let info = WorkspaceInfo(id: workspace, checkoutId: checkout.id, name: title, cwd: "/", kind: .root, branch: nil, base: nil,
                                 status: .open, createdAt: 0)
        let area = WorkArea(remote: RemoteWorkspace(machine: machine, project: project, checkout: checkout, workspace: info,
                                                    threads: [], instances: instances, windows: windows),
                            definitions: RemotePluginDefinition.previewAll)
        // 上次预览留下的排布里可能有这次没有的窗口
        area.layout.reconcile(windows.map { Pane($0.id) })
        area.setPreviewActivities(activities)
        return DockPreviewScene(title: title, area: area, docked: docked, onStage: onStage, rows: rows, tools: tools, families: families)
    }
}

/// 头像各状态的对照表。
private struct DockPreviewStates: View {
    let scene: DockPreviewScene

    var body: some View {
        DockPreviewSection(title: "头像状态", note: "进行中从头像向外扩散实心脉冲；需要处理时头像本色换成状态色，同时只显示一个：失败 > 等待继续 > 完成未查看。大小头像一样。") {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 12) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    ForEach(DockPreviewState.allCases, id: \.self) { state in
                        Text(state.title).font(Theme.status).foregroundStyle(.secondary)
                            .frame(width: 72)
                    }
                }
                ForEach(scene.rows) { row in
                    GridRow {
                        DockPreviewLabel(title: row.title, note: row.note)
                        ForEach(row.entries) { entry in
                            DockPreviewCell(entry: entry, mini: row.mini).frame(width: 72).padding(.vertical, 6)
                                .environment(\.dockCurrentPane, row.current ? entry.pane : nil)
                        }
                    }
                }
            }
        }
        .environment(scene.area)
    }
}

/// 子代理个数不同的家族格：宽屏竖排、底部小头像、窄屏横排。
private struct DockPreviewFamilies: View {
    let scene: DockPreviewScene

    var body: some View {
        DockPreviewSection(title: "家族格", note: "子代理叠在父代理后面，各露出一截，最多露三个；子代理依次是空闲、等待继续、失败。") {
            HStack(alignment: .top, spacing: 32) {
                ForEach(scene.families) { family in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(family.title).font(Theme.status).foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 16) {
                            DockPreviewCell(entry: family.entry)
                            DockPreviewCell(entry: family.entry, mini: true)
                        }
                        DockPreviewCell(entry: family.entry, axis: .horizontal)
                    }
                }
            }
        }
        .environment(scene.area)
    }
}

private struct DockPreviewTools: View {
    let scene: DockPreviewScene

    var body: some View {
        DockPreviewSection(title: "工具", note: "工具没有活动状态；没有窗口的和代理一样缩成底部小头像，按有没有视图分成「没有窗口」和「后台」。") {
            HStack(alignment: .top, spacing: 8) {
                ForEach(scene.tools) { tool in
                    VStack(spacing: 8) {
                        DockPreviewCell(entry: tool.entry, mini: tool.mini).frame(height: 48)
                            .environment(\.dockCurrentPane, tool.current ? tool.entry.pane : nil)
                        Text(tool.title).font(Theme.status).foregroundStyle(.secondary)
                    }
                    .frame(width: 88)
                }
            }
        }
        .environment(scene.area)
    }
}

/// 整条停靠栏：宽屏竖排在一张窗口右边，窄屏横排在手机宽度里。
private struct DockPreviewDocks: View {
    let scenes: [DockPreviewScene]

    var body: some View {
        DockPreviewSection(title: "停靠栏", note: "左边灰色是台面上的窗口，用来看小头像和窗口底边对齐；窄屏底栏里垫底色、画向上箭头的是当前窗口。") {
            HStack(alignment: .top, spacing: 48) {
                ForEach(scenes, id: \.title) { scene in
                    VStack(alignment: .leading, spacing: 16) {
                        Text(scene.title).font(Theme.secondary)
                        DockPreviewRail(scene: scene, height: 456)
                        CompactDockBar(open: .constant(nil))
                            .frame(width: 358, height: Metrics.tabBar)
                            .environment(scene.area)
                    }
                }
            }
        }
    }
}

/// 展开后的家族与「更多」，宽屏竖排、窄屏横排。
private struct DockPreviewPanels: View {
    let family: DockPreviewScene
    let more: DockPreviewScene

    var body: some View {
        DockPreviewSection(title: "展开", note: "点家族格或「更多」后原地拉开的面板。") {
            HStack(alignment: .top, spacing: 48) {
                if let entry = family.model.agents.first(where: \.expands) { panels(entry, in: family) }
                if let entry = more.model.minis.last?.entry, entry.expands { panels(entry, in: more) }
            }
        }
    }

    private func panels(_ entry: DockEntry, in scene: DockPreviewScene) -> some View {
        HStack(alignment: .top, spacing: 24) {
            DockPanel(entry: entry, depth: 0, axis: .vertical) { _ in }
            DockPanel(entry: entry, depth: 0, axis: .horizontal) { _ in }
        }
        .environment(scene.area)
    }
}

/// 宽屏停靠栏，按真实的格子位置摆；最小化的窗口在 App 里由窗口卡片画，这里直接画头像。
private struct DockPreviewRail: View {
    let scene: DockPreviewScene
    let height: CGFloat

    var body: some View {
        let regions = WindowRegions(in: CGRect(x: 0, y: 0, width: 132, height: height))
        let geometry = DockGeometry(model: scene.model, regions: regions)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Theme.card)
                .placed(regions.canvas)
            AddWindowButton().placed(geometry.add)
            ForEach(geometry.cells, id: \.entry.id) { cell in
                DockPreviewCell(entry: cell.entry).placed(cell.frame)
            }
            ForEach(geometry.minis, id: \.entry.id) { cell in
                DockPreviewCell(entry: cell.entry, mini: true).placed(cell.frame)
            }
            if let divider = geometry.divider { DockDivider(x: geometry.add.midX, y: divider) }
        }
        .frame(width: regions.dock.maxX, height: regions.dock.maxY, alignment: .topLeading)
        .environment(scene.area)
    }
}

/// 一格：最小化的窗口画头像，其余和停靠栏里一样。
private struct DockPreviewCell: View {
    let entry: DockEntry
    var mini = false
    var axis: Axis = .vertical

    var body: some View {
        let size = DockGeometry.cellSize(entry, mini: mini, axis: axis)
        Group {
            if case .pane(let pane) = entry { DockEntryFace(subject: .pane(pane)) } else { DockCell(entry: entry, mini: mini) }
        }
        .frame(width: size.width, height: size.height)
        .environment(\.dockAxis, axis)
    }
}

private struct DockPreviewLabel: View {
    let title: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.secondary)
            if let note { Text(note).font(Theme.status).foregroundStyle(.secondary) }
        }
        .frame(width: 200, alignment: .leading)
    }
}

private struct DockPreviewSection<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.title)
                Text(note).font(Theme.caption).foregroundStyle(.secondary)
            }
            content
        }
    }
}
#endif
