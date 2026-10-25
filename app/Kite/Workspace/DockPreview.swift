import SwiftUI

extension View {
    /// Debug build 带 --dock-preview 启动时换成停靠栏预览；服务连接照常建立，用来读角色签名。
    @ViewBuilder func dockPreview() -> some View {
        #if DEBUG
        if DockPreview.enabled { if DockStagePreview.enabled { DockStagePreview() } else { DockPreview() } } else { self }
        #else
        self
        #endif
    }
}

#if DEBUG
import os

/// 停靠栏预览的台面：`--dock-preview --dock-stage` 用真实的原生台面（StageHost）摆一个造出来的工作区，卡片、停靠栏、过渡都和平时一样，
/// 不发请求，正文是占位；再加 `--dock-crowded` 实例多到停靠栏放不下。带 `--dock-script` 时按固定的顺序自己动：缩小、从停靠栏打开、新建、
/// 关掉新建页、从停靠栏拖出来放上台面、打开布局、展开收起家族格，各隔几秒，每一步记一条日志（kite.probe），配合 `--slow=N` 放慢动画逐帧截图核对。
/// 参数都写成以 -- 开头的一个：单独的词会被系统当成启动时要打开的文件，App 就不开窗口了。
struct DockStagePreview: View {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--dock-stage") }
    private static var crowded: Bool { ProcessInfo.processInfo.arguments.contains("--dock-crowded") }
    private static var scripted: Bool { ProcessInfo.processInfo.arguments.contains("--dock-script") }
    private static let log = Logger(subsystem: "kite.probe", category: "dock")

    @Environment(AppModel.self) private var model
    @State private var scene: DockPreviewScene?
    @State private var size = CGSize.zero

    var body: some View {
        // 先有底：空的 Group 上的修饰不生效，task 也不会跑
        ZStack {
            Theme.background.ignoresSafeArea()
            if let scene {
                TilesLayer(group: .workspace(scene.area))
                    .environment(scene.area)
                    .environment(scene.area.layout)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                    .padding(Metrics.padding)
            }
        }
        .dockHoverHost()
        .task { await run() }
    }

    private func run() async {
        let machine = model.activeConnection?.machine ?? RemoteMachine(id: "dock-preview", name: "预览", createdAt: 0)
        var b = DockPreviewBuilder(machine: machine, workspace: Self.crowded ? "dock-stage.crowded" : "dock-stage", roles: [])
        b.title = "台面"
        b.layout("对话和终端", members: [.agent(role: b.role(1)), .plugin(definition: RemotePluginDefinition.previewTerminal.id),
                                    .plugin(definition: RemotePluginDefinition.previewFiles.id)])
        b.layout("评审", members: [.agent(role: b.role(1)), .files(page: nil), .preview(target: "app", device: nil)])
        let main = b.agent("主会话", role: 0, state: .running, onStage: true)
        let parent = b.agent("重构停靠栏", role: 3, state: .waiting)
        b.agent("查引用", role: 4, state: .running, parent: parent.id)
        b.agent("跑检查", role: 1, state: .failed, parent: parent.id)
        let docs = b.agent("整理文档", role: 1, state: .unseen)
        if Self.crowded {
            for index in 0..<16 { b.agent("后台 \(index + 1)", role: index, state: index % 3 == 0 ? .running : .idle) }
        }
        let files = b.tool("文件", .previewFiles, onStage: true)
        b.tool("终端", .previewTerminal)
        b.tool("索引", .previewBackground)
        let scene = b.build()
        self.scene = scene
        guard Self.scripted else { return }
        let area = scene.area, layout = area.layout
        func step(_ name: String, after seconds: Double, _ action: () -> Void) async {
            try? await Task.sleep(for: .seconds(seconds))
            Self.log.notice("step \(name, privacy: .public) at \(Date().timeIntervalSince1970, privacy: .public)")
            action()
        }
        let pause = 2.5 * WindowMotionKind.slowdown / 4 + 2
        await step("minimize", after: 4) { layout.minimize(Pane(main.id)) }
        await step("restore", after: pause) { layout.activate(Pane(main.id)) }
        await step("open-docs", after: pause) { layout.activate(Pane(docs.id)) }
        await step("new", after: pause) { area.openChooser() }
        await step("close-new", after: pause) { area.closeChooser() }
        // 从停靠栏拖出「文件」以外的一格放到台面中间，再拖回停靠栏
        await step("minimize-files", after: pause) { layout.minimize(Pane(files.id)) }
        try? await Task.sleep(for: .seconds(pause))
        // 台面的范围就是这一块：Mac 的台面往右多排的那一段在外面（见 StageView.trailingOverflow）
        let bounds = CGRect(origin: .zero, size: size)
        if let cell = StagePlan.dock(layout: layout, area: area, bounds: bounds).dock.slot(of: Pane(files.id))?.frame {
            let target = CGPoint(x: bounds.width * 0.4, y: bounds.height * 0.5)
            Self.log.notice("step drag-out at \(Date().timeIntervalSince1970, privacy: .public)")
            for index in 0...40 {
                let t = CGFloat(index) / 40
                layout.drag(Pane(files.id), to: CGPoint(x: cell.midX + (target.x - cell.midX) * t, y: cell.midY + (target.y - cell.midY) * t), in: bounds)
                try? await Task.sleep(for: .milliseconds(25))
            }
            try? await Task.sleep(for: .seconds(1))
            layout.drop(in: bounds)
        }
        await step("open-layout", after: pause) { if let first = area.layouts.first { area.openLayout(first, model: model) } }
        await step("expand-family", after: pause) { area.toggleDock(DockEntry.familyID(parent.id), depth: 0) }
        await step("collapse-family", after: pause) { area.collapseDock() }
        Self.log.notice("step done at \(Date().timeIntervalSince1970, privacy: .public)")
    }
}

/// 停靠栏预览：用真实的停靠栏组件（DockBand、DockGroup、DockLayoutFolder）画造出来的实例、布局和活动，不建工作区、不发请求，也不接点击。
/// 头像签名取已连接工作机上的角色，没连上时都是默认图案。一屏摆下：左边是各种格子，中间是竖排的整条停靠栏，右边是横排的。
struct DockPreview: View {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--dock-preview") }

    @Environment(AppModel.self) private var model
    @State private var scenes: DockPreviewScenes?

    var body: some View {
        let machine = model.activeConnection?.machine
        ScrollView([.vertical, .horizontal]) {
            if let scenes {
                VStack(alignment: .leading, spacing: 20) {
                    header(machine: scenes.signed ? machine : nil)
                    HStack(alignment: .top, spacing: 40) {
                        VStack(alignment: .leading, spacing: 24) {
                            DockPreviewStates(scene: scenes.states)
                            DockPreviewFamilies(scene: scenes.states)
                            DockPreviewFolders(scene: scenes.states)
                        }
                        DockPreviewRails(scenes: scenes)
                        DockPreviewBars(scenes: scenes)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .task(id: "\(machine?.id ?? "")|\(model.connected)") { await load(machine) }
    }

    private func header(machine: RemoteMachine?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("停靠栏预览").font(Theme.display)
            Text((machine.map { "头像签名取自 \($0.name) 上的角色。" } ?? "没有读到角色，头像都是默认图案。")
                 + "格子 \(Int(Metrics.dragBubble))pt，运行中的头像会动。")
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
    let expanded: DockPreviewScene
    let signed: Bool

    init(machine: RemoteMachine, roles: [String]) {
        signed = !roles.isEmpty
        states = Self.states(machine: machine, roles: roles)
        common = Self.common(machine: machine, roles: roles)
        crowded = Self.crowded(machine: machine, roles: roles)
        expanded = Self.expanded(machine: machine, roles: roles)
    }

    /// 每种状态一列：同一种样子的头像在各状态下并排；子代理个数不同的家族格；成员数不同的布局文件夹；工具。
    private static func states(machine: RemoteMachine, roles: [String]) -> DockPreviewScene {
        var b = DockPreviewBuilder(machine: machine, workspace: "dock-preview.states", roles: roles)
        var panes: [DockEntry] = []
        for state in DockPreviewState.allCases {
            panes.append(.pane(Pane(b.agent("代理 · \(state.title)", role: 0, state: state).id)))
        }
        b.rows = [
            DockPreviewRow(title: "不在台面上", note: "状态画在格子上", entries: panes),
            DockPreviewRow(title: "在台面上", note: "宽屏：模糊、指向台面，不显示状态", entries: panes, look: .staged),
            DockPreviewRow(title: "当前窗口", note: "窄屏底栏里正显示的", entries: panes, look: .current),
        ]

        let states: [DockPreviewState] = [.idle, .waiting, .failed, .idle, .idle]
        for count in [1, 2, 3, 5] {
            let parent = b.agent("\(count) 个子代理", role: 2, state: .running)
            let kids = (0..<count).map { b.agent("子代理", role: 3 + $0, state: states[$0], parent: parent.id) }
            b.families.append(DockPreviewTool(title: "\(count) 个子代理", entry: .family(DockFamily(
                parent: parent, pane: Pane(parent.id), onStage: false, children: kids.map(DockEntry.instance)))))
        }

        let files = b.tool("文件", .previewFiles), terminal = b.tool("终端", .previewTerminal)
        let web = b.tool("预览", .previewWeb), plugin = b.tool("插件", .previewPlugin)
        b.tools = [
            DockPreviewTool(title: "浏览", entry: .pane(Pane(files.id))),
            DockPreviewTool(title: "终端", entry: .pane(Pane(terminal.id))),
            DockPreviewTool(title: "预览", entry: .pane(Pane(web.id))),
            DockPreviewTool(title: "插件", entry: .pane(Pane(plugin.id))),
            DockPreviewTool(title: "后台实例", entry: .instance(b.tool("索引", .previewBackground))),
        ]
        let members: [LayoutMember] = [.agent(role: b.role(0)), .files(page: nil), .agent(role: b.role(2)), .terminal, .preview(target: "app", device: nil)]
        for count in 1...4 {
            b.layout("\(count) 个成员", members: Array(members.prefix(count)))
        }
        return b.build()
    }

    /// 常见的一屏：布局两个，台面上的代理、带子代理的家族、工具，和几个不在台面上的代理与后台实例。
    private static func common(machine: RemoteMachine, roles: [String]) -> DockPreviewScene {
        var b = DockPreviewBuilder(machine: machine, workspace: "dock-preview.common", roles: roles)
        b.title = "常见"
        b.layout("写代码", members: [.agent(role: b.role(0)), .files(page: nil), .terminal])
        b.layout("评审", members: [.agent(role: b.role(1)), .agent(role: b.role(3)), .files(page: nil), .preview(target: "app", device: nil)])
        b.agent("主会话", role: 0, state: .running, onStage: true)
        let parent = b.agent("重构停靠栏", role: 3, state: .waiting)
        b.agent("查引用", role: 4, state: .running, parent: parent.id)
        b.agent("跑检查", role: 1, state: .failed, parent: parent.id)
        b.agent("整理文档", role: 1, state: .running)
        b.agent("修登录", role: 2, state: .unseen)
        b.tool("文件", .previewFiles, onStage: true)
        b.tool("终端", .previewTerminal)
        b.tool("索引", .previewBackground)
        return b.build()
    }

    /// 实例多到放不下：靠前端的照原间距，溢出的一头叠进末端、越靠后越透明。
    private static func crowded(machine: RemoteMachine, roles: [String]) -> DockPreviewScene {
        var b = DockPreviewBuilder(machine: machine, workspace: "dock-preview.crowded", roles: roles)
        b.title = "放不下"
        b.layout("写代码", members: [.agent(role: b.role(0)), .files(page: nil), .terminal])
        b.agent("主会话", role: 0, onStage: true)
        b.agent("整理文档", role: 1, state: .running)
        let states: [DockPreviewState] = [.idle, .running, .waiting, .idle, .failed, .unseen, .idle, .running, .idle, .finishing, .idle, .idle]
        for (index, state) in states.enumerated() {
            let agent = b.agent("后台 \(index + 1)", role: index, state: state)
            if index == 3 { b.agent("子代理", role: index + 1, state: .running, parent: agent.id) }
        }
        b.tool("文件", .previewFiles)
        b.tool("终端", .previewTerminal)
        return b.build()
    }

    /// 家族格展开着：原地拉开成一排，后面的让开，别的格子模糊淡出；子代理多到超过上限时里面也照停靠栏堆叠。
    private static func expanded(machine: RemoteMachine, roles: [String]) -> DockPreviewScene {
        var b = DockPreviewBuilder(machine: machine, workspace: "dock-preview.expanded", roles: roles)
        b.title = "展开家族格"
        b.layout("写代码", members: [.agent(role: b.role(0)), .files(page: nil), .terminal])
        b.agent("主会话", role: 0, onStage: true)
        let parent = b.agent("重构停靠栏", role: 3, state: .running)
        let states: [DockPreviewState] = [.running, .waiting, .failed, .idle, .unseen, .idle, .running, .idle, .idle, .idle]
        for (index, state) in states.enumerated() { b.agent("子代理 \(index + 1)", role: 4 + index, state: state, parent: parent.id) }
        b.agent("整理文档", role: 1, state: .running)
        b.tool("文件", .previewFiles)
        b.expanded = [DockEntry.familyID(parent.id)]
        return b.build()
    }
}

/// 一组造出来的实例。onStage 是台面上的。
struct DockPreviewScene {
    let title: String
    let area: WorkArea
    let onStage: Set<String>
    let rows: [DockPreviewRow]
    let tools: [DockPreviewTool]
    let families: [DockPreviewTool]
}

struct DockPreviewRow: Identifiable {
    enum Look { case docked, staged, current }

    let title: String
    let note: String?
    let entries: [DockEntry]
    var look = Look.docked
    var id: String { title }
}

struct DockPreviewTool: Identifiable {
    let title: String
    let entry: DockEntry
    var id: String { entry.id }
}

private extension DockEntry {
    var pane: Pane? { if case .pane(let pane) = self { pane } else { nil } }
}

enum DockPreviewState: CaseIterable {
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

extension RemotePluginDefinition {
    static let previewAgent = RemotePluginDefinition(id: "preview.agent", title: "代理", lifetime: .persistent,
                                                     views: [.init(id: "conversation", title: "对话", renderer: "conversation")],
                                                     defaultView: "conversation", agent: .init(runtime: .harness))
    static let previewFiles = previewTool("preview.files", renderer: "files", lifetime: .closable)
    static let previewTerminal = previewTool("preview.terminal", renderer: "terminal", lifetime: .process)
    static let previewWeb = previewTool("preview.web", renderer: "preview", lifetime: .process)
    static let previewPlugin = previewTool("preview.plugin", renderer: "custom", lifetime: .persistent)
    static let previewBackground = RemotePluginDefinition(id: "preview.background", title: "后台", lifetime: .persistent,
                                                          views: [], defaultView: "", agent: nil)
    static let previewAll = [previewAgent, previewFiles, previewTerminal, previewWeb, previewPlugin, previewBackground]

    private static func previewTool(_ id: String, renderer: String, lifetime: PluginLifetime) -> RemotePluginDefinition {
        RemotePluginDefinition(id: id, title: renderer, lifetime: lifetime, views: [.init(id: "main", title: renderer, renderer: renderer)],
                               defaultView: "main", agent: nil)
    }
}

/// 按创建先后造实例与布局；agent 的 role 是角色列表里的序号，循环着用。onStage 的放上台面。
struct DockPreviewBuilder {
    let machine: RemoteMachine
    let workspace: String
    let roles: [String]
    var title = ""
    var rows: [DockPreviewRow] = []
    var families: [DockPreviewTool] = []
    var tools: [DockPreviewTool] = []
    /// 展开着的家族格，见 WorkArea.dockExpansion。
    var expanded: [String] = []
    private var instances: [RemotePluginInstance] = []
    private var layouts: [ProjectLayout] = []
    private var activities: [String: ThreadActivity] = [:]
    private var onStage: Set<String> = []

    init(machine: RemoteMachine, workspace: String, roles: [String]) {
        self.machine = machine
        self.workspace = workspace
        self.roles = roles
    }

    /// 角色列表里第 index 个角色的 ID，没读到角色时是个不存在的 ID（画默认图案）。
    func role(_ index: Int) -> String {
        roles.isEmpty ? "preview.role.\(index)" : roles[index % roles.count]
    }

    @discardableResult
    mutating func agent(_ title: String, role: Int, state: DockPreviewState = .idle, onStage: Bool = false, parent: String? = nil) -> RemotePluginInstance {
        let config = InstanceAgentConfig(role: .init(id: self.role(role)))
        let instance = add(title, definition: .previewAgent, config: config, parent: parent, onStage: onStage)
        activities[instance.id] = state.activity
        return instance
    }

    @discardableResult
    mutating func tool(_ title: String, _ definition: RemotePluginDefinition, onStage: Bool = false) -> RemotePluginInstance {
        add(title, definition: definition, config: nil, parent: nil, onStage: onStage)
    }

    /// 一个布局：成员按先后排成一列。
    mutating func layout(_ name: String, members: [LayoutMember]) {
        let arrangement = members.indices.dropFirst().reduce(LayoutArrangement.member(0)) { tile, index in
            .split(axis: .horizontal, ratio: 0.5, first: tile, second: .member(index))
        }
        layouts.append(ProjectLayout(id: "\(workspace).layout.\(layouts.count)", name: name, members: members, arrangement: arrangement, revision: "1"))
    }

    private mutating func add(_ title: String, definition: RemotePluginDefinition, config: InstanceAgentConfig?, parent: String?,
                              onStage: Bool) -> RemotePluginInstance {
        let instance = RemotePluginInstance(id: "\(workspace).\(instances.count)", workspaceId: workspace, definitionId: definition.id,
                                            title: title, status: .open, createdAt: instances.count, view: definition.views.first?.id,
                                            config: config, origin: parent.map { .init(instanceId: $0) })
        instances.append(instance)
        if onStage, !definition.views.isEmpty { self.onStage.insert(instance.id) }
        return instance
    }

    func build() -> DockPreviewScene {
        let project = RemoteProject(id: "dock-preview", name: "停靠栏预览", remote: "preview/dock", createdAt: 0)
        let checkout = RemoteCheckout(id: "dock-preview", projectId: project.id, machineId: machine.id, path: "/", remote: project.remote, createdAt: 0)
        let info = WorkspaceInfo(id: workspace, epoch: 1, checkoutId: checkout.id, name: title, cwd: "/", branch: nil, base: nil,
                                 status: .open, createdAt: 0)
        let area = WorkArea(remote: RemoteWorkspace(machine: machine, project: project, checkout: checkout, workspace: info,
                                                    threads: [], instances: instances),
                            definitions: RemotePluginDefinition.previewAll)
        // 上次预览留下的排布里可能有这次没有的实例；台面上只放这次指定的
        area.layout.reconcile(area.layout.panes)
        for pane in area.layout.shown?.panes ?? [] where !onStage.contains(pane.id) { area.layout.minimize(pane) }
        for id in onStage { area.layout.activate(Pane(id)) }
        area.setPreviewActivities(activities)
        area.layouts = layouts
        area.dockExpansion = expanded
        return DockPreviewScene(title: title, area: area, onStage: onStage, rows: rows, tools: tools, families: families)
    }
}

/// 头像各状态的对照表：不在台面上、在台面上、窄屏当前窗口。
private struct DockPreviewStates: View {
    let scene: DockPreviewScene

    var body: some View {
        DockPreviewSection(title: "头像状态", note: "进行中从头像向外扩散实心脉冲；需要处理时头像本色换成状态色：失败 > 等待继续 > 完成未查看。") {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 10) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    ForEach(DockPreviewState.allCases, id: \.self) { state in
                        Text(state.title).font(Theme.status).foregroundStyle(.secondary).frame(width: 56)
                    }
                }
                ForEach(scene.rows) { row in
                    GridRow {
                        DockPreviewLabel(title: row.title, note: row.note)
                        ForEach(row.entries) { entry in
                            DockPreviewCell(entry: entry).frame(width: 56)
                                .environment(\.dockCurrentPane, row.look == .current ? entry.pane : nil)
                                .environment(\.dockOnStage, row.look == .staged ? Set(entry.pane.map { [$0.id] } ?? []) : [])
                        }
                    }
                }
            }
        }
        .environment(scene.area)
    }
}

/// 子代理个数不同的家族格（竖排、横排），收着最多露三个、往后渐隐；展开后排成一排。
private struct DockPreviewFamilies: View {
    let scene: DockPreviewScene

    var body: some View {
        DockPreviewSection(title: "家族格", note: "子代理叠在父代理后面，各露出一截，最多露三个、往后渐隐；点开原地排成一排。") {
            HStack(alignment: .top, spacing: 22) {
                ForEach(scene.families) { family in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(family.title).font(Theme.status).foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 10) {
                            DockGroup(entry: family.entry, depth: 0)
                            DockGroup(entry: family.entry, depth: 0).environment(\.dockAxis, .horizontal)
                        }
                    }
                }
                if let entry = scene.families.dropFirst(2).first?.entry {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("展开").font(Theme.status).foregroundStyle(.secondary)
                        DockGroup(entry: entry, depth: 0, expanded: true, openness: 1).environment(\.dockAxis, .horizontal)
                    }
                }
            }
        }
        .environment(scene.area)
    }
}

/// 布局文件夹（1～4 个成员）、两个添加入口、工具和后台实例。
private struct DockPreviewFolders: View {
    let scene: DockPreviewScene

    var body: some View {
        DockPreviewSection(title: "布局与工具", note: "文件夹里是成员的角色头像与工具图标；添加布局在布局组第一个，添加实例在实例组最后。") {
            HStack(alignment: .top, spacing: 14) {
                ForEach(scene.area.layouts) { layout in
                    item(layout.name) { DockLayoutFolder(layout: layout) }
                }
                item("添加布局") { AddLayoutButton() }
                item("添加实例") { AddWindowButton() }
                ForEach(scene.tools) { tool in
                    item(tool.title) { DockPreviewCell(entry: tool.entry) }
                }
            }
        }
        .environment(scene.area)
    }

    private func item(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 8) {
            content().frame(height: Metrics.dragBubble)
            Text(title).font(Theme.status).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 56)
    }
}

/// 竖排的整条停靠栏（宽屏台面右边那一列）：常见、放不下（在前端、滚到中间）、展开家族格。台面上的画「看得到」的样子。
private struct DockPreviewRails: View {
    let scenes: DockPreviewScenes

    var body: some View {
        DockPreviewSection(title: "竖排", note: "宽屏，从上到下；台面上的指向台面。") {
            HStack(alignment: .top, spacing: 28) {
                rail(scenes.common, title: "常见", height: 600)
                rail(scenes.crowded, title: "放不下", height: 420)
                rail(scenes.crowded, title: "滚到中间", height: 420, distance: 240)
                rail(scenes.expanded, title: "展开", height: 600)
            }
        }
    }

    private func rail(_ scene: DockPreviewScene, title: String, height: CGFloat, distance: CGFloat = 0) -> some View {
        VStack(alignment: .center, spacing: 10) {
            Text(title).font(Theme.status).foregroundStyle(.secondary)
            DockBand(axis: .vertical, show: { _ in }, startDistance: distance)
                .environment(\.dockOnStage, scene.onStage)
                .frame(width: Metrics.dragBubble, height: height)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Theme.card.opacity(0.6)))
                .environment(scene.area)
        }
    }
}

/// 横排的整条停靠栏（窄屏底栏）：从右往左，当前窗口垫底色、画向上的箭头。
private struct DockPreviewBars: View {
    let scenes: DockPreviewScenes

    var body: some View {
        DockPreviewSection(title: "横排", note: "窄屏底栏，从右往左；当前窗口垫底色、指向上方。") {
            VStack(alignment: .leading, spacing: 18) {
                bar(scenes.common, title: "常见")
                bar(scenes.crowded, title: "放不下")
                bar(scenes.crowded, title: "滚到中间", distance: 260)
                bar(scenes.expanded, title: "展开")
            }
        }
    }

    private func bar(_ scene: DockPreviewScene, title: String, distance: CGFloat = 0) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.status).foregroundStyle(.secondary)
            DockBand(axis: .horizontal, show: { _ in }, startDistance: distance)
                .environment(\.dockCurrentPane, scene.area.layout.focused)
                .frame(width: 358, height: Metrics.tabBar)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Theme.card.opacity(0.6)))
                .environment(scene.area)
        }
    }
}

/// 一格：实例的 pane 画头像，其余和停靠栏里一样。
private struct DockPreviewCell: View {
    let entry: DockEntry

    var body: some View {
        Group {
            switch entry {
            case .pane(let pane): DockEntryFace(subject: .pane(pane))
            case .instance: DockCellButton(entry: entry, depth: 0, veiled: true)
            case .family: DockGroup(entry: entry, depth: 0)
            }
        }
        .frame(width: Metrics.dragBubble, height: Metrics.dragBubble)
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
        .frame(width: 150, alignment: .leading)
    }
}

private struct DockPreviewSection<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.title)
                Text(note).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}
#endif
