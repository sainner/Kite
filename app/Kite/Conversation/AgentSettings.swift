import SwiftUI

/// 保留完整配置草稿和读取版本，冲突时由用户选择重新载入，不覆盖另一端的修改。
struct AgentSettings: View {
    let instance: RemotePluginInstance
    let thread: WorkThread
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.dismiss) private var dismiss
    @State private var client: KitedClient?
    @State private var saved: AgentConfigurationSnapshot?
    @State private var draft: AgentConfiguration?
    @State private var capabilities: AgentCapabilities?
    @State private var working = false
    @State private var error: String?
    @State private var notice: String?
    @State private var discard: String?

    private var changed: Bool { draft != saved?.instance.config.agent }
    private var available: Bool {
        model.connected && area.remote?.machine.id == model.machine?.id && area.remote?.workspace.status == .open
            && area.instances.contains { $0.id == instance.id && $0.status == .open }
    }
    private var levels: [String] { capabilities?.model(draft?.model.model ?? "")?.reasoning ?? [] }

    var body: some View {
        Form {
            if draft != nil, let capabilities {
                Section("模型") {
                    Picker("模型", selection: Binding(get: { draft!.model.model }, set: { id in
                        draft?.model.selectModel(id, supportedReasoning: capabilities.model(id)?.reasoning ?? [])
                    })) {
                        if let current = draft?.model.model, !capabilities.models.contains(where: { $0.id == current }) {
                            Text(current).tag(current)
                        }
                        ForEach(capabilities.models) { entry in Text(entry.title).tag(entry.id) }
                    }
                    Picker("思考强度", selection: Binding(get: { draft!.model.reasoning }, set: { draft?.model.reasoning = $0 })) {
                        if levels.isEmpty || draft?.model.reasoning == "default" { Text("自动").tag("default") }
                        if let current = draft?.model.reasoning, current != "default", !levels.contains(current) { Text(current).tag(current) }
                        ForEach(levels, id: \.self) { Text($0).tag($0) }
                    }.disabled(levels.isEmpty)
                    Text(capabilities.explanation).font(.footnote).foregroundStyle(.secondary)
                    Text(capabilities.toolCatalogBoundary == "idle" ? "新增插件工具在下次执行时加入。" : "首次请求后工具目录固定；新增插件工具需要新会话。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("可用工具") {
                    ForEach(capabilities.tools, id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { draft?.tools.contains(name) == true }, set: { enabled in
                            draft?.tools.removeAll { $0 == name }
                            if enabled { draft?.tools.append(name) }
                        }))
                    }
                    Text("实例授权仍然有效；勾选工具不会增加文件、网络或其他实例的访问权限。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("执行上限") {
                    TextField("每回合最多模型请求数", value: Binding(get: { draft!.maxRequestsPerTurn }, set: { draft?.maxRequestsPerTurn = $0 }), format: .number)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Text("达到上限后停止，保留已经产生的结果。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let error { Section { Text(error).foregroundStyle(Theme.danger).textSelection(.enabled) } }
            if let notice { Section { Text(notice).foregroundStyle(.secondary) } }
        }
        .formStyle(.grouped)
        .disabled(working || !available)
        .navigationTitle("会话配置")
        .navigationBarBackButtonHidden(changed)
        .toolbar {
            if changed { ToolbarItem(placement: .cancellationAction) { Button("返回") { discard = "back" }.disabled(working) } }
            ToolbarItem(placement: .primaryAction) {
                Button("重新载入") { if changed { discard = "reload" } else { perform { try await load() } } }.disabled(working || !available)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { perform { try await save() } }
                    .disabled(working || !available || !changed || (draft?.maxRequestsPerTurn ?? 0) < 1
                        || capabilities?.canEdit(thread.state) != true || thread.hasUnconfirmedStop)
            }
        }
        .interactiveDismissDisabled(working || changed)
        .confirmationDialog("放弃未保存的会话配置？", isPresented: Binding(get: { discard != nil }, set: { if !$0 { discard = nil } }), titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) {
                let action = discard
                discard = nil
                if action == "back" { dismiss() } else { perform { try await load() } }
            }
        }
        .task { perform { try await load() } }
    }

    private func boundClient() throws -> KitedClient {
        let current = try model.activeClient()
        guard available, current.machineID == area.remote?.machine.id, client == nil || client == current else {
            throw KitedError(message: "工作机或实例已变化，请重新打开会话配置")
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
        notice = "会话配置已保存。"
    }
    private func perform(_ action: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true; error = nil; notice = nil
        Task {
            defer { working = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

extension AppModel {
    /// 快捷控件每次从最新配置改一个字段；设置页使用自己的草稿与版本。
    func updateAgent(in area: WorkArea, id: String, change: (inout AgentConfiguration) -> Void) async throws {
        let revision = connectionRevision
        let client = try activeClient()
        func requireCurrent() throws {
            guard connectionRevision == revision, connected, client == (try activeClient()), client.machineID == area.remote?.machine.id,
                  area.remote?.workspace.status == .open, area.instances.contains(where: { $0.id == id && $0.status == .open }) else {
                throw KitedError(message: "工作机或实例已变化，请重新修改配置")
            }
        }
        try requireCurrent()
        let path = "/instances/\(id)/agent-config"
        let snapshot = try await client.request(path, as: AgentConfigurationSnapshot.self)
        try requireCurrent()
        guard var agent = snapshot.instance.config.agent else { throw KitedError(message: "实例没有会话配置") }
        change(&agent)
        let updated = try await client.request(path, method: "PUT",
            body: AgentConfigurationUpdate(expectedRevision: snapshot.revision, agent: agent), as: AgentConfigurationSnapshot.self)
        try requireCurrent()
        if let index = area.instances.firstIndex(where: { $0.id == id }) { area.instances[index].config = updated.instance.config }
    }
}
