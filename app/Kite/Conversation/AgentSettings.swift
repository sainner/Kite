import SwiftUI

/// 保留完整配置草稿和读取版本，冲突时由用户选择重新载入，不覆盖另一端的修改。
struct AgentSettings: View {
    let instance: RemotePluginInstance
    let thread: WorkThread
    /// 回到实例设置。
    let back: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @State private var client: KitedClient?
    @State private var saved: AgentConfigurationSnapshot?
    @State private var draft: AgentConfiguration?
    @State private var capabilities: AgentCapabilities?
    @State private var phase = CardPhase.idle
    @State private var discard: String?
    @FocusState private var editingLimit: Bool

    private var changed: Bool { draft != saved?.instance.config.agent }
    private var available: Bool {
        model.isConnected(area) && area.remote?.workspace.status == .open
            && area.instances.contains { $0.id == instance.id && $0.status == .open }
    }
    private var working: Bool { phase.working }
    private var levels: [String] { capabilities?.model(draft?.model.model ?? "")?.reasoning ?? [] }

    private var canSave: Bool {
        !working && available && changed && (draft?.maxRequestsPerTurn ?? 0) >= 1
            && capabilities?.canEdit(thread.state) == true && !thread.hasUnconfirmedStop
    }

    var body: some View {
        CardSheet(title: "代理配置", subtitle: instance.title, typing: editingLimit, back: true, size: InstanceSettings.size,
                  close: { if changed { discard = "back" } else { back() } }) {
            Group {
                if draft != nil, let capabilities {
                    CardSection("模型", note: capabilities.explanation
                        + (capabilities.toolCatalogBoundary == "idle" ? "新增插件工具在下次执行时加入。" : "首次请求后工具目录固定；新增插件工具需要新代理。")) {
                        LabeledContent("模型") {
                            Picker("模型", selection: Binding(get: { draft!.model.model }, set: { id in
                                draft?.model.selectModel(id, supportedReasoning: capabilities.model(id)?.reasoning ?? [])
                            })) {
                                if let current = draft?.model.model, !capabilities.models.contains(where: { $0.id == current }) {
                                    Text(current).tag(current)
                                }
                                ForEach(capabilities.vendors) { vendor in
                                    Section(vendor.title) {
                                        ForEach(capabilities.models.filter { $0.vendor == vendor.id }) { entry in Text(entry.title).tag(entry.id) }
                                    }
                                }
                            }
                            .labelsHidden().fixedSize()
                        }
                        LabeledContent("思考强度") {
                            Picker("思考强度", selection: Binding(get: { draft!.model.reasoning }, set: { draft?.model.reasoning = $0 })) {
                                if levels.isEmpty || draft?.model.reasoning == "default" { Text("自动").tag("default") }
                                if let current = draft?.model.reasoning, current != "default", !levels.contains(current) { Text(current).tag(current) }
                                ForEach(levels, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                            .disabled(levels.isEmpty)
                        }
                    }
                    CardSection("可用工具", note: "可开的工具由创建时的角色决定，角色必需的不能关闭。实例授权仍然有效；勾选工具不会增加文件、网络或其他实例的访问权限。") {
                        ForEach(capabilities.tools, id: \.self) { name in
                            let required = capabilities.required.contains(name)
                            Toggle(required ? "\(name)（角色必需）" : name, isOn: Binding(get: { draft?.tools.contains(name) == true }, set: { enabled in
                                draft?.tools.removeAll { $0 == name }
                                if enabled { draft?.tools.append(name) }
                            }))
                            .disabled(required)
                        }
                    }
                    CardField(label: "每回合最多模型请求数", focused: editingLimit, note: "达到上限后停止，保留已经产生的结果。") {
                        TextField("", value: Binding(get: { draft!.maxRequestsPerTurn }, set: { draft?.maxRequestsPerTurn = $0 }), format: .number)
                            .focused($editingLimit)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .cardInput { editingLimit = true }
                    }
                }
            }
            .disabled(working || !available)
        } actions: {
            CardSheetAction(title: "重新载入", systemImage: "arrow.clockwise") {
                if changed { discard = "reload" } else { perform { try await load() } }
            }
            .disabled(working || !available)
        } footer: {
            CardActions(primary: "保存", enabled: canSave, phase: $phase) { perform(succeeds: true) { try await save() } }
        }
        #if os(iOS)
        // 数字键盘没有换行键，键盘上方给一个完成
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { editingLimit = false } } }
        #endif
        .endsTyping(editingLimit) { editingLimit = false }
        .interactiveDismissDisabled(working || changed)
        .confirmationDialog("放弃未保存的代理配置？", isPresented: Binding(get: { discard != nil }, set: { if !$0 { discard = nil } }), titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) {
                let action = discard
                discard = nil
                if action == "back" { back() } else { perform { try await load() } }
            }
        }
        .task { perform { try await load() } }
    }

    private func boundClient() throws -> KitedClient {
        let current = try model.activeClient(in: area)
        guard available, current.machineID == area.remote?.machine.id, client == nil || client == current else {
            throw KitedError(message: "工作机或实例已变化，请重新打开代理配置")
        }
        return current
    }
    private func load() async throws {
        let client = try boundClient()
        self.client = client
        async let snapshot = client.request("/instances/\(instance.id)/agent-config", as: AgentConfigurationSnapshot.self)
        async let catalog = client.request("/instances/\(instance.id)/agent-capabilities", as: AgentCapabilities.self)
        let (value, capabilities) = try await (snapshot, catalog)
        _ = try boundClient()
        saved = value; draft = value.instance.config.agent; self.capabilities = capabilities
        thread.agentCapabilities = capabilities
    }
    private func save() async throws {
        guard let draft, let saved else { return }
        let value = try await boundClient().request("/instances/\(instance.id)/agent-config", method: "PUT",
            body: AgentConfigurationUpdate(expectedRevision: saved.revision, agent: draft), as: AgentConfigurationSnapshot.self)
        _ = try boundClient()
        self.saved = value; self.draft = value.instance.config.agent
        if let index = area.instances.firstIndex(where: { $0.id == instance.id }) { area.instances[index].config = value.instance.config }
    }
    private func perform(succeeds: Bool = false, _ action: @escaping () async throws -> Void) {
        $phase.run(succeeds: succeeds, action)
    }
}

extension AppModel {
    /// 快捷控件每次从最新配置改一个字段；设置页使用自己的草稿与版本。
    func updateAgent(in area: WorkArea, id: String, change: (inout AgentConfiguration) -> Void) async throws {
        let revision = self.revision(for: area)
        let client = try activeClient(in: area)
        func requireCurrent() throws {
            guard self.revision(for: area) == revision, isConnected(area), client == (try activeClient(in: area)), client.machineID == area.remote?.machine.id,
                  area.remote?.workspace.status == .open, area.instances.contains(where: { $0.id == id && $0.status == .open }) else {
                throw KitedError(message: "工作机或实例已变化，请重新修改配置")
            }
        }
        try requireCurrent()
        let path = "/instances/\(id)/agent-config"
        let snapshot = try await client.request(path, as: AgentConfigurationSnapshot.self)
        try requireCurrent()
        guard var agent = snapshot.instance.config.agent else { throw KitedError(message: "实例没有代理配置") }
        change(&agent)
        let updated = try await client.request(path, method: "PUT",
            body: AgentConfigurationUpdate(expectedRevision: snapshot.revision, agent: agent), as: AgentConfigurationSnapshot.self)
        try requireCurrent()
        if let index = area.instances.firstIndex(where: { $0.id == id }) { area.instances[index].config = updated.instance.config }
    }
}

/// 新代理草稿的配置：在所选角色允许的范围内调整工具与每回合预算；模型与思考强度在标题栏和输入区改。完成只改本机草稿。
struct DraftAgentSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(WorkThread.self) private var thread
    @Environment(\.dismiss) private var dismiss
    @State private var tools: [String] = []
    @State private var budget = 50
    @State private var phase = CardPhase.idle
    @FocusState private var editingLimit: Bool

    private var role: AgentRole? { model.newThreadRole(for: thread, in: area) }
    private var capabilities: AgentCapabilities? { thread.agentCapabilities }
    private var roleBudget: Int { role?.role.maxRequestsPerTurn ?? 50 }

    var body: some View {
        CardSheet(title: "代理配置", subtitle: role.map { "角色：\($0.role.title)" }, typing: editingLimit, size: InstanceSettings.size,
                  close: { dismiss() }) {
            if let capabilities {
                CardSection("可用工具", note: "可开的工具由角色决定，角色必需的不能关闭。") {
                    ForEach(capabilities.tools, id: \.self) { name in
                        let required = capabilities.required.contains(name)
                        Toggle(required ? "\(name)（角色必需）" : name, isOn: Binding(get: { tools.contains(name) }, set: { enabled in
                            tools.removeAll { $0 == name }
                            if enabled { tools.append(name) }
                        }))
                        .disabled(required)
                    }
                }
                CardField(label: "每回合最多模型请求数", focused: editingLimit, note: "达到上限后停止，保留已经产生的结果。") {
                    TextField("", value: $budget, format: .number)
                        .focused($editingLimit)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .cardInput { editingLimit = true }
                }
            } else {
                ProgressView()
            }
        } footer: {
            CardActions(primary: "完成", enabled: capabilities != nil && budget >= 1, phase: $phase, succeeded: "已更新") { save() }
        }
        #if os(iOS)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { editingLimit = false } } }
        #endif
        .endsTyping(editingLimit) { editingLimit = false }
        .onAppear {
            tools = thread.draftChoice?.tools ?? capabilities?.tools ?? []
            budget = thread.draftChoice?.maxRequestsPerTurn ?? roleBudget
        }
    }

    /// 与角色一致的部分不提交，由工作机按角色决定。
    private func save() {
        guard let capabilities else { return }
        let selected = capabilities.tools.filter { tools.contains($0) }
        thread.draftChoice?.tools = selected == capabilities.tools ? nil : selected
        thread.draftChoice?.maxRequestsPerTurn = budget == roleBudget ? nil : budget
        dismiss()
    }
}
