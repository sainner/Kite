import SwiftUI

struct InstanceSettings: View {
    /// 实例设置和两个子页面共用的弹窗尺寸。
    static let size = CGSize(width: 560, height: 640)

    let instance: RemotePluginInstance
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.dismiss) private var dismiss
    @State private var client: KitedClient?
    @State private var saved: InstanceGrants?
    @State private var draft: PluginGrantDraft?
    @State private var operations: [RemoteOperation] = []
    @State private var tools: [String: [RemotePluginTool]] = [:]
    @State private var toolErrors: [String: String] = [:]
    @State private var loadingTools: Set<String> = []
    @State private var phase: String?
    @State private var progress = CardPhase.idle
    @State private var discardAction: String?
    @State private var archiving: RemotePluginInstance?
    /// 弹窗里当前的子页面，nil 是实例设置本身。
    @State private var page: Page?

    private enum Page { case agent, grants }

    private var definition: RemotePluginDefinition? { area.definition(of: instance) }
    private var caller: String { definition?.agent == nil ? "plugin" : "model" }
    private var editable: Bool { definition?.runtime == "bun" || definition?.agent != nil }
    private var changed: Bool { draft?.grants != saved?.grants || draft?.scope != saved?.scope }
    private var working: Bool { progress.working }
    private var available: Bool {
        model.isConnected(area) && area.instances.contains { $0.id == instance.id && $0.status == .open }
    }
    private var targets: [RemotePluginInstance] { area.instances.filter { $0.status == .open } }

    private var thread: WorkThread? {
        guard area.remote.threads.contains(where: { $0.instanceId == instance.id }) else { return nil }
        return area.threads.first { $0.id == instance.id }
    }

    var body: some View {
        Group {
            switch page {
            case .agent?:
                if let thread { AgentSettings(instance: instance, thread: thread, back: { page = nil }) }
            case .grants?:
                if let thread { ExecutionGrantSettings(instance: instance, thread: thread, back: { page = nil }) }
            case nil:
                main
            }
        }
        .animation(.snappy, value: page)
        // 挂在外层：从子页面返回时不重新读取，主页的草稿保留
        .task { perform { try await load() } }
    }

    private var main: some View {
        CardSheet(title: "配置", subtitle: "管理实例的运行与协作授权", error: progress.error, size: Self.size,
                  close: { if changed { discardAction = "close" } else { dismiss() } }) {
            Group {
                CardSection("实例", note: definition?.lifetime.explanation) {
                    LabeledContent("插件") { Text(definition?.title ?? instance.definitionId).foregroundStyle(.secondary) }
                    LabeledContent("工作区") { Text(area.title).foregroundStyle(.secondary) }
                    if thread != nil {
                        CardLink("代理配置") { page = .agent }.disabled(!available)
                        CardLink("执行授权") { page = .grants }.disabled(!available)
                    }
                    ForEach(definition?.views ?? []) { view in
                        Button("打开\(view.title)") {
                            model.openWindow(.open(.init(instanceId: instance.id, viewId: view.id)), in: area)
                        }.disabled(!available)
                    }
                }
                if definition?.runtime == "bun" {
                    CardSection("进程", note: "停止进程保留实例和数据，后续调用会按需启动。") {
                        LabeledContent("状态") { Text(processLabel).foregroundStyle(.secondary) }
                        Button("刷新状态") { perform { try await readProcess() } }
                        Button("停止进程") {
                            perform {
                                let client = try boundClient()
                                let _: JSON = try await client.request("/instances/\(instance.id)/plugin/process", method: "DELETE", as: JSON.self)
                                try await readProcess()
                            }
                        }.disabled(!available || phase == nil || phase == "stopped")
                    }
                }
                if definition?.lifetime == .persistent {
                    CardSection("归档", note: "停止执行并关闭窗口，会话和数据保留在工作机上。") {
                        Button("归档实例…", role: .destructive) { archiving = instance }.disabled(!available)
                    }
                }
                if editable, draft != nil {
                    CardSection("协作授权", note: (definition?.agent != nil
                        ? "协作范围决定这个代理能对准哪些代理、monitor 和终端：仅后代是它建的以及再往下建的，同工作区是工作区里的全部；超出后代范围时，停下别人的、经权限比它大的代理做事都要先经你批准。插件工具在下面逐项授予，新授权的何时生效见代理配置。"
                        : "这个插件能经宿主调用工作区里的哪些实例和操作；默认都没有。")
                        + "修改后保存，撤回对后续调用立即生效。")
                    workspaceGrants
                    ForEach(targets) { target in
                        if area.definition(of: target)?.runtime == "bun" { pluginGrants(target) }
                        // 代理对其他实例的操作按协作范围，不逐个授权。
                        else if caller == "plugin" { instanceGrants(target) }
                    }
                }
            }
            .disabled(working)
        } actions: {
            CardSheetAction(title: "重新读取", systemImage: "arrow.clockwise") {
                if changed { discardAction = "reload" } else { perform { try await load() } }
            }
            .disabled(working || !available)
            // 不能编辑的实例没有保存
            if editable {
                CardSheetAction(title: "保存", busy: working) { perform { try await save() } }
                    .disabled(working || !available || !changed || draft == nil)
            }
        }
        .interactiveDismissDisabled(working || changed)
        .modifier(ArchiveInstanceConfirmation(instance: $archiving, archived: { dismiss() }))
        .discardAlert("放弃未保存的授权修改？", item: $discardAction) { action in
            if action == "close" { dismiss() } else { perform { try await load() } }
        }
    }

    private var processLabel: String {
        switch phase {
        case "running": "运行中"
        case "stopped": "已停止"
        case "blocked": "上次进程尚未确认退出"
        default: "未读取"
        }
    }

    @ViewBuilder private var workspaceGrants: some View {
        CardSection("工作区") {
            if let scope = draft?.scope {
                LabeledContent("协作范围") {
                    Picker("协作范围", selection: Binding(get: { scope }, set: { value in draft?.scope = value })) {
                        Text("仅后代").tag("descendants")
                        Text("同工作区").tag("workspace")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().clickPointer()
                }
            }
            if caller == "plugin", operations.contains(where: { $0.name == "agent.list" && $0.callers.contains(caller) }) {
                let grant = OperationGrant(operation: "agent.list")
                Toggle("查询代理", isOn: selection({ $0.grants.contains(grant) }, { $0.set(grant, enabled: $1) }))
            }
            DisclosureGroup("按角色创建代理") {
                ForEach(model.roles(in: area)?.roles ?? []) { role in
                    Toggle(role.role.title, isOn: selection({ $0.includesRole(role.id) }, { $0.setRole(role.id, enabled: $1) }))
                }
            }
            if caller == "plugin" {
                DisclosureGroup("自己创建的代理") {
                    ForEach(operations.filter { ["agent.send", "agent.resume", "agent.stop"].contains($0.name) }) { operation in
                        let grant = OperationGrant(operation: operation.name, targets: .init(kind: "created"))
                        Toggle(operation.title, isOn: selection({ $0.grants.contains(grant) }, { $0.set(grant, enabled: $1) }))
                    }
                }
            }
        }.disabled(!available)
    }

    @ViewBuilder private func instanceGrants(_ target: RemotePluginInstance) -> some View {
        let allowed = operations.filter {
            $0.callers.contains(caller) && (area.definition(of: target)?.operations.contains($0.name) ?? false)
                && !(target.id == instance.id && $0.name.hasPrefix("agent."))
        }
        if !allowed.isEmpty {
            CardSection(target.title) {
                ForEach(allowed) { operation in
                    Toggle(operation.title, isOn: selection({ $0.includesTarget(operation: operation.name, instanceID: target.id) },
                        { $0.setTarget(operation: operation.name, instanceID: target.id, enabled: $1) }))
                        .help(operation.description)
                }
            }.disabled(!available)
        }
    }

    private func pluginGrants(_ target: RemotePluginInstance) -> some View {
        let existing = draft?.grants.filter { $0.operation == "plugin.call" && $0.instanceId == target.id }.flatMap { $0.tools ?? [] } ?? []
        let discovered = tools[target.id] ?? []
        let names = Set(existing + discovered.filter(\.canGrant).map(\.name)).sorted()
        return CardSection(target.title) {
            ForEach(names, id: \.self) { name in
                let tool = discovered.first { $0.name == name }
                Toggle(isOn: selection({ $0.includesTool(instanceID: target.id, name: name) }, { $0.setTool(instanceID: target.id, name: name, enabled: $1) })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tool?.title ?? name)
                        if let description = tool?.description { Text(description).font(Theme.caption).foregroundStyle(.secondary) }
                    }
                }.disabled(!available || (tool?.canGrant != true && draft?.includesTool(instanceID: target.id, name: name) != true))
            }
            Button(loadingTools.contains(target.id) ? "正在读取…" : "读取可用工具") { Task { await readTools(target.id) } }
                .disabled(!available || loadingTools.contains(target.id))
            if let message = toolErrors[target.id] { Text(message).font(Theme.caption).foregroundStyle(Theme.danger) }
            if tools[target.id] != nil && names.isEmpty { Text("没有可授予的工具").foregroundStyle(.secondary) }
        }
    }

    private func selection(_ read: @escaping (PluginGrantDraft) -> Bool, _ write: @escaping (inout PluginGrantDraft, Bool) -> Void) -> Binding<Bool> {
        Binding(get: { draft.map(read) ?? false }, set: { value in
            guard var next = draft else { return }
            write(&next, value)
            draft = next
        })
    }

    private func boundClient() throws -> KitedClient {
        let current = try model.activeClient(in: area)
        guard available, current.machineID == area.remote.machine.id, client == nil || client == current else {
            throw KitedError(message: "工作机或实例已变化，请重新打开实例设置")
        }
        return current
    }

    private func load() async throws {
        let client = try boundClient()
        self.client = client
        if editable {
            async let snapshot = client.request("/instances/\(instance.id)/operation-grants", as: InstanceGrants.self)
            async let catalog = client.request("/operations", as: [RemoteOperation].self)
            let (value, definitions) = try await (snapshot, catalog)
            _ = try boundClient()
            saved = value
            draft = PluginGrantDraft(snapshot: value)
            operations = definitions
            // 「按角色创建代理」列出的是工作机上的角色。
            try await model.ensureRoles(in: area)
        }
        if definition?.runtime == "bun" { try await readProcess() }
    }

    private func save() async throws {
        guard let draft else { return }
        let client = try boundClient()
        let value = try await client.request("/instances/\(instance.id)/operation-grants", method: "PUT", body: draft.request, as: InstanceGrants.self)
        _ = try boundClient()
        saved = value
        self.draft = PluginGrantDraft(snapshot: value)
        try await model.refresh(client)
    }

    private func readProcess() async throws {
        struct Process: Decodable { let phase: String }
        let value = try await boundClient().request("/instances/\(instance.id)/plugin/process", as: Process.self)
        _ = try boundClient()
        phase = value.phase
    }

    private func readTools(_ id: String) async {
        guard !loadingTools.contains(id) else { return }
        loadingTools.insert(id)
        toolErrors[id] = nil
        defer { loadingTools.remove(id) }
        do {
            struct Tools: Decodable { let tools: [RemotePluginTool] }
            let value = try await boundClient().request("/instances/\(id)/plugin/tools", as: Tools.self)
            _ = try boundClient()
            tools[id] = value.tools
        } catch { toolErrors[id] = error.localizedDescription }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        $progress.run(action)
    }
}

struct InstanceSettingsPresentation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    func body(content: Content) -> some View {
        @Bindable var area = area
        content.sheet(item: $area.settingsInstance) { instance in
            InstanceSettings(instance: instance).environment(model).environment(area).toastHost().appAppearance()
        }
        .modifier(ArchiveInstanceConfirmation(instance: $area.archiveRequest))
        // 归档先在本机生效、弹窗当场关掉，工作机归档不成时报在这里
        .alert("归档失败", isPresented: Binding(get: { area.archiveError != nil }, set: { if !$0 { area.archiveError = nil } })) {
            Button("好", role: .cancel) { area.archiveError = nil }
        } message: { Text(area.archiveError ?? "") }
        .onChange(of: model.revision(for: area)) { area.settingsInstance = nil; area.archiveRequest = nil }
    }
}

/// 归档确认：窗口菜单、停靠栏和实例设置共用同一段说明与请求。
struct ArchiveInstanceConfirmation: ViewModifier {
    @Binding var instance: RemotePluginInstance?
    var archived: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.toast) private var toast
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .alert("归档「\(instance?.title ?? "")」？", isPresented: Binding(get: { instance != nil }, set: { if !$0 { instance = nil } }),
                   presenting: instance) { target in
                Button("归档", role: .destructive) { archive(target) }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text("归档会停止它正在进行的执行并关闭它的窗口，会话和数据保留在工作机上。目前还不能在界面里查看或恢复已归档的实例。")
            }
            .alert("归档失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
    }

    /// 归档当场生效（见 AppModel.archiveInstance），这里只报发不出去的原因；工作机归档不成报在工作区一层。
    private func archive(_ target: RemotePluginInstance) {
        do {
            try model.archiveInstance(target, in: area)
            toast?.show("已归档")
            archived()
        } catch { self.error = error.localizedDescription }
    }
}

/// 窗口图标和无窗口实例使用同一套实例操作；给了窗口时带关闭窗口。
struct InstanceActions: View {
    let instance: RemotePluginInstance
    var pane: Pane?
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    var body: some View {
        ForEach(Array(InstanceAction.all(for: instance, in: area, model: model, pane: pane).enumerated()), id: \.offset) { _, action in
            MenuButton(action.title, role: action.destructive ? .destructive : nil, action: action.perform)
                .disabled(!action.enabled)
        }
    }
}

/// 一项实例操作。实例操作只有这一份：停靠栏的菜单（含缩成停靠形状的窗口）和会话窗口的更多菜单都从这里出；结束性的（停止、归档）用危险色。
struct InstanceAction {
    let title: String
    let symbol: String
    var enabled = true
    var destructive = false
    let perform: @MainActor () -> Void

    /// 打开它的各个视图，再是 managing 那几项；给了窗口时最后是关闭窗口。
    @MainActor static func all(for instance: RemotePluginInstance, in area: WorkArea, model: AppModel, pane: Pane? = nil) -> [InstanceAction] {
        var actions = (area.definition(of: instance)?.views ?? []).map { view in
            InstanceAction(title: "打开\(view.title)", symbol: "macwindow") {
                model.openWindow(.open(.init(instanceId: instance.id, viewId: view.id)), in: area)
            }
        }
        actions += managing(instance, in: area, model: model)
        if let pane {
            actions.append(InstanceAction(title: "关闭窗口", symbol: "xmark") { model.closeWindow(pane, in: area) })
        }
        return actions
    }

    /// 实例本身的：配置；终端在跑时能停止，独立存续的能归档。窗口自己的更多菜单只列这些，打开、关闭由窗口管。
    @MainActor static func managing(_ instance: RemotePluginInstance, in area: WorkArea, model: AppModel) -> [InstanceAction] {
        var actions = [InstanceAction(title: "配置", symbol: "slider.horizontal.3") { area.settingsInstance = instance }]
        if instance.state?.terminal?.running == true {
            actions.append(InstanceAction(title: "停止终端", symbol: "stop.fill", enabled: model.isConnected(area), destructive: true) {
                model.stopTerminal(instance, in: area)
            })
        }
        if area.definition(of: instance)?.lifetime == .persistent {
            actions.append(InstanceAction(title: "归档", symbol: "archivebox", enabled: model.isConnected(area), destructive: true) { area.archiveRequest = instance })
        }
        return actions
    }
}
