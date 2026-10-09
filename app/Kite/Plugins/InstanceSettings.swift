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
    private var changed: Bool { draft?.grants != saved?.grants }
    private var working: Bool { progress.working }
    private var available: Bool {
        model.isConnected(area) && area.instances.contains { $0.id == instance.id && $0.status == .open }
    }
    private var targets: [RemotePluginInstance] { area.instances.filter { $0.status == .open } }

    private var thread: WorkThread? {
        guard area.remote?.threads.contains(where: { $0.instanceId == instance.id }) == true else { return nil }
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
        CardSheet(title: "实例设置与授权", subtitle: instance.title, size: Self.size,
                  close: { if changed { discardAction = "close" } else { dismiss() } }) {
            Group {
                CardSection("实例", note: definition?.lifetime.explanation) {
                    LabeledContent("插件") { Text(definition?.title ?? instance.definitionId).foregroundStyle(.secondary) }
                    LabeledContent("工作区") { Text(area.title).foregroundStyle(.secondary) }
                    if thread != nil {
                        CardLink("会话配置") { page = .agent }.disabled(!available)
                        CardLink("执行授权") { page = .grants }.disabled(!available)
                    }
                    ForEach(definition?.views ?? []) { view in
                        Button("打开\(view.title)") {
                            model.openWindow(.open(.init(instanceId: instance.id, viewId: view.id)), in: area)
                        }.disabled(!available || area.changingWindows || area.pendingWindowRequest != nil || area.pendingInstanceRequest != nil)
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
                    CardSection("可用能力", note: "选择这个实例可以调用的能力。修改后保存，撤回对后续调用立即生效。"
                        + (definition?.agent != nil ? "撤回授权立即阻止后续调用。新增工具的生效时机见会话配置。" : ""))
                    workspaceGrants
                    ForEach(targets) { target in
                        if area.definition(of: target)?.runtime == "bun" { pluginGrants(target) }
                        else { instanceGrants(target) }
                    }
                }
            }
            .disabled(working)
        } actions: {
            CardSheetAction(title: "重新读取", systemImage: "arrow.clockwise") {
                if changed { discardAction = "reload" } else { perform { try await load() } }
            }
            .disabled(working || !available)
        } footer: {
            // 不能编辑的实例没有保存，出错时也借这里显示原因和重试
            if editable || progress.error != nil {
                CardActions(primary: "保存", enabled: editable && !working && available && changed && draft != nil, phase: $progress) {
                    perform(succeeds: true) { try await save() }
                }
            }
        }
        .interactiveDismissDisabled(working || changed)
        .modifier(ArchiveInstanceConfirmation(instance: $archiving, archived: { dismiss() }))
        .confirmationDialog("放弃未保存的授权修改？", isPresented: Binding(get: { discardAction != nil }, set: { if !$0 { discardAction = nil } }), titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) {
                let action = discardAction
                discardAction = nil
                if action == "close" { dismiss() } else { perform { try await load() } }
            }
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
            if operations.contains(where: { $0.name == "agent.list" && $0.callers.contains(caller) }) {
                let grant = OperationGrant(operation: "agent.list")
                Toggle("查询代理", isOn: selection({ $0.grants.contains(grant) }, { $0.set(grant, enabled: $1) }))
            }
            DisclosureGroup("创建代理") {
                ForEach(area.definitions.filter { $0.agent != nil }) { definition in
                    Toggle(definition.title, isOn: selection({ $0.includesDefinition(definition.id) }, { $0.setDefinition(definition.id, enabled: $1) }))
                }
            }
            DisclosureGroup("自己创建的代理") {
                ForEach(operations.filter { ["agent.send", "agent.resume", "agent.stop"].contains($0.name) }) { operation in
                    let grant = OperationGrant(operation: operation.name, targets: .init(kind: "created"))
                    Toggle(operation.title, isOn: selection({ $0.grants.contains(grant) }, { $0.set(grant, enabled: $1) }))
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
        guard available, current.machineID == area.remote?.machine.id, client == nil || client == current else {
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

    private func perform(succeeds: Bool = false, _ action: @escaping () async throws -> Void) {
        $progress.run(succeeds: succeeds, action)
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
            .confirmationDialog("归档「\(instance?.title ?? "")」？", isPresented: Binding(get: { instance != nil }, set: { if !$0 { instance = nil } }),
                                titleVisibility: .visible, presenting: instance) { target in
                Button("归档", role: .destructive) { archive(target) }
            } message: { _ in
                Text("归档会停止它正在进行的执行并关闭它的窗口，会话和数据保留在工作机上。目前还不能在界面里查看或恢复已归档的实例。")
            }
            .alert("归档失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
    }

    private func archive(_ target: RemotePluginInstance) {
        Task {
            do {
                try await model.archiveInstance(target, in: area)
                toast?.show("已归档")
                archived()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// 窗口图标和无窗口实例使用同一套实例操作。
struct InstanceActions: View {
    let instance: RemotePluginInstance
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    var body: some View {
        ForEach(area.definition(of: instance)?.views ?? []) { view in
            Button("打开\(view.title)") { model.openWindow(.open(.init(instanceId: instance.id, viewId: view.id)), in: area) }
                .disabled(area.changingWindows || area.pendingWindowRequest != nil || area.pendingInstanceRequest != nil)
        }
        Button("实例设置与授权") { area.settingsInstance = instance }
        if area.definition(of: instance)?.lifetime == .persistent {
            Button("归档…", role: .destructive) { area.archiveRequest = instance }
                .disabled(!model.isConnected(area))
        }
    }
}

struct InstanceDockButton: View {
    let instance: RemotePluginInstance
    var opened: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    private var definition: RemotePluginDefinition? { area.definition(of: instance) }
    private var appearance: WindowAppearance {
        definition?.agent != nil ? .init(name: instance.title, icon: "bubble.left.and.bubble.right", tint: Palette.breeze)
            : .renderer(definition?.views.first?.renderer ?? "")
    }
    var body: some View {
        Button {
            guard !area.changingWindows, area.pendingWindowRequest == nil, area.pendingInstanceRequest == nil else { return }
            if let definition, let view = definition.views.first(where: { $0.id == definition.defaultView }) ?? definition.views.first {
                model.openWindow(.open(.init(instanceId: instance.id, viewId: view.id)), in: area)
                opened()
            }
        } label: {
            Image(systemName: appearance.icon)
                .font(Theme.title)
                .foregroundStyle(appearance.tint)
                .frame(width: Metrics.dragBubble, height: Metrics.dragBubble)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointingPlain)
        .help(instance.title + ((definition?.views.isEmpty ?? true) ? "（后台实例）" : ""))
        .accessibilityLabel(instance.title)
        .contextMenu { InstanceActions(instance: instance) }
    }
}
