import SwiftUI

struct InstanceSettings: View {
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
    @State private var working = false
    @State private var error: String?
    @State private var discardAction: String?

    private var definition: RemotePluginDefinition? { area.definition(of: instance) }
    private var caller: String { definition?.agent == nil ? "plugin" : "model" }
    private var editable: Bool { definition?.runtime == "bun" || definition?.agent != nil }
    private var changed: Bool { draft?.grants != saved?.grants }
    private var available: Bool {
        model.isConnected(area) && area.instances.contains { $0.id == instance.id && $0.status == .open }
    }
    private var targets: [RemotePluginInstance] { area.instances.filter { $0.status == .open } }

    var body: some View {
        NavigationStack {
            Form {
                Section("实例") {
                    LabeledContent("名称", value: instance.title)
                    LabeledContent("插件", value: definition?.title ?? instance.definitionId)
                    LabeledContent("工作区", value: area.title)
                    if let definition {
                        Text(definition.lifetime.explanation).font(.footnote).foregroundStyle(.secondary)
                    }
                    if area.remote?.threads.contains(where: { $0.instanceId == instance.id }) == true,
                       let thread = area.threads.first(where: { $0.id == instance.id }) {
                        NavigationLink("会话配置") {
                            AgentSettings(instance: instance, thread: thread)
                        }.disabled(!available)
                        NavigationLink("执行授权") {
                            ExecutionGrantSettings(instance: instance, thread: thread)
                        }.disabled(!available)
                    }
                    ForEach(definition?.views ?? []) { view in
                        Button("打开\(view.title)") {
                            model.openWindow(.open(.init(instanceId: instance.id, viewId: view.id)), in: area)
                        }.disabled(!available || area.changingWindows || area.pendingWindowRequest != nil || area.pendingInstanceRequest != nil)
                    }
                    if definition?.runtime == "bun" {
                        LabeledContent("进程", value: processLabel)
                        Button("刷新状态") { perform { try await readProcess() } }
                        Button("停止进程") {
                            perform {
                                let client = try boundClient()
                                let _: JSON = try await client.request("/instances/\(instance.id)/plugin/process", method: "DELETE", as: JSON.self)
                                try await readProcess()
                            }
                        }.disabled(!available || phase == nil || phase == "stopped")
                        Text("停止进程保留实例和数据，后续调用会按需启动。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if editable, draft != nil {
                    Section {
                        Text("选择这个实例可以调用的能力。修改后保存，撤回对后续调用立即生效。")
                        if definition?.agent != nil {
                            Text("撤回授权立即阻止后续调用。新增工具的生效时机见会话配置。")
                        }
                    } header: { Text("可用能力") }
                        .font(.footnote).foregroundStyle(.secondary)
                    workspaceGrants
                    ForEach(targets) { target in
                        if area.definition(of: target)?.runtime == "bun" { pluginGrants(target) }
                        else { instanceGrants(target) }
                    }
                }
                if let error { Text(error).foregroundStyle(Theme.danger).textSelection(.enabled) }
                if working { ProgressView() }
            }
            .formStyle(.grouped)
            .disabled(working)
            .navigationTitle("实例设置与授权")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { if changed { discardAction = "close" } else { dismiss() } }.disabled(working)
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("重新读取") {
                        if changed { discardAction = "reload" } else { perform { try await load() } }
                    }.disabled(working || !available)
                    if editable {
                        Button("保存") { perform { try await save() } }
                            .disabled(working || !available || !changed || draft == nil)
                    }
                }
            }
        }
        .interactiveDismissDisabled(working || changed)
        .confirmationDialog("放弃未保存的授权修改？", isPresented: Binding(get: { discardAction != nil }, set: { if !$0 { discardAction = nil } }), titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) {
                let action = discardAction
                discardAction = nil
                if action == "close" { dismiss() } else { perform { try await load() } }
            }
        }
        .task { perform { try await load() } }
        #if os(macOS)
        .frame(width: 560, height: 640)
        #endif
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
        Section("工作区") {
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
            Section(target.title) {
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
        return Section(target.title) {
            ForEach(names, id: \.self) { name in
                let tool = discovered.first { $0.name == name }
                Toggle(isOn: selection({ $0.includesTool(instanceID: target.id, name: name) }, { $0.setTool(instanceID: target.id, name: name, enabled: $1) })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tool?.title ?? name)
                        if let description = tool?.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                    }
                }.disabled(!available || (tool?.canGrant != true && draft?.includesTool(instanceID: target.id, name: name) != true))
            }
            Button(loadingTools.contains(target.id) ? "正在读取…" : "读取可用工具") { Task { await readTools(target.id) } }
                .disabled(!available || loadingTools.contains(target.id))
            if let message = toolErrors[target.id] { Text(message).font(.caption).foregroundStyle(Theme.danger) }
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

    private func perform(_ action: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
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
        .onChange(of: model.revision(for: area)) { area.settingsInstance = nil }
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
        Button("实例设置与授权") { area.settingsInstance = instance }.disabled(area.isSample)
    }
}

struct InstanceDockButton: View {
    let instance: RemotePluginInstance
    var opened: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    private var definition: RemotePluginDefinition? { area.definition(of: instance) }
    private var appearance: WindowAppearance {
        definition?.agent != nil ? .init(name: instance.title, kind: "代理", icon: "bubble.left.and.bubble.right", tint: Palette.breeze)
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
