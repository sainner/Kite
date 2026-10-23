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

    private var changed: Bool { draft != saved?.instance.config.agent }
    private var available: Bool {
        model.isConnected(area) && area.remote.workspace.status == .open
            && area.instances.contains { $0.id == instance.id && $0.status == .open }
    }
    private var working: Bool { phase.working }

    private var canSave: Bool {
        !working && available && changed
            && capabilities?.canEdit(thread.state) == true && !thread.hasUnconfirmedStop
    }

    var body: some View {
        CardSheet(title: "代理配置", subtitle: "选择模型与可用工具", error: phase.error, back: true, size: InstanceSettings.size,
                  close: { if changed { discard = "back" } else { back() } }) {
            Group {
                if draft != nil, let capabilities {
                    CardSection("模型", note: capabilities.explanation
                        + (capabilities.toolCatalogBoundary == "idle" ? "新增插件工具在下次执行时加入。" : "首次请求后内置工具目录固定，增减要新代理；新授权的插件工具会话中途就能加载。")) {
                        AgentModelFields(configuration: Binding(get: { draft!.model }, set: { draft?.model = $0 }),
                                         vendors: capabilities.vendors, models: capabilities.models)
                    }
                    CardSection("可用工具", note: "角色给出默认勾选，也可以开角色没给的；角色必需的不能关闭，项目禁用的暂不可用，项目放宽后恢复。勾选工具不会增加文件、网络或其他实例的访问权限，那些由执行授权和协作授权决定。") {
                        AgentToolToggles(capabilities: capabilities, tools: Binding(get: { draft?.tools ?? [] }, set: { draft?.tools = $0 }))
                    }
                }
            }
            .disabled(working || !available)
        } actions: {
            CardSheetAction(title: "重新载入", systemImage: "arrow.clockwise") {
                if changed { discard = "reload" } else { perform { try await load() } }
            }
            .disabled(working || !available)
            CardSheetAction(title: "保存", busy: working) { perform { try await save() } }
                .disabled(!canSave)
        }
        .interactiveDismissDisabled(working || changed)
        .discardAlert("放弃未保存的代理配置？", item: $discard) { action in
            if action == "back" { back() } else { perform { try await load() } }
        }
        .task { perform { try await load() } }
    }

    private func boundClient() throws -> KitedClient {
        let current = try model.activeClient(in: area)
        guard available, current.machineID == area.remote.machine.id, client == nil || client == current else {
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
    private func perform(_ action: @escaping () async throws -> Void) {
        $phase.run(action)
    }
}

extension AppModel {
    /// 快捷控件每次从最新配置改一个字段；设置页使用自己的草稿与版本。
    func updateAgent(in area: WorkArea, id: String, change: (inout AgentConfiguration) -> Void) async throws {
        let revision = self.revision(for: area)
        let client = try activeClient(in: area)
        func requireCurrent() throws {
            guard self.revision(for: area) == revision, isConnected(area), client == (try activeClient(in: area)), client.machineID == area.remote.machine.id,
                  area.remote.workspace.status == .open, area.instances.contains(where: { $0.id == id && $0.status == .open }) else {
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

/// 新代理草稿的配置：在所选角色允许的范围内调整工具与 MCP 服务；模型与思考强度在标题栏和输入区改。完成只改本机草稿。
struct DraftAgentSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(WorkThread.self) private var thread
    @Environment(\.dismiss) private var dismiss
    @State private var tools: [String] = []
    @State private var mcp: [String] = []

    private var capabilities: AgentCapabilities? { thread.agentCapabilities }
    /// 所选角色默认打开的 MCP 服务。
    private var roleMcp: [String] {
        let role = model.newThreadRole(for: thread, in: area)?.id
        return (thread.agentOptions?.roles.first { $0.id == role }?.mcp ?? []).sorted()
    }

    var body: some View {
        CardSheet(title: "配置", subtitle: "选择可用工具", size: InstanceSettings.size,
                  close: { dismiss() }) {
            if let capabilities {
                CardSection("可用工具", note: "角色给出默认勾选，也可以开角色没给的；角色必需的不能关闭，项目禁用的暂不可用。") {
                    AgentToolToggles(capabilities: capabilities, tools: $tools)
                }
                if let options = thread.agentOptions?.mcp, !(options.available.isEmpty && mcp.isEmpty) {
                    CardSection("MCP 服务", note: "这台工作机装的外部 MCP 服务，角色给出默认勾选。服务不在沙箱里，授权一个服务等于把它能做的事交给代理。") {
                        McpServerToggles(available: options.available, denied: options.denied, selected: $mcp, showsStatus: true)
                    }
                }
            } else {
                ProgressView()
            }
        } actions: {
            CardSheetAction(title: "完成", action: save)
                .disabled(capabilities == nil)
        }
        .onAppear {
            tools = thread.draftChoice?.tools ?? capabilities?.defaults ?? []
            mcp = thread.draftChoice?.mcp ?? roleMcp
        }
    }

    /// 与角色一致的部分不提交，由工作机按角色决定。
    private func save() {
        guard let capabilities else { return }
        let selected = capabilities.tools.filter { tools.contains($0) }
        thread.draftChoice?.tools = selected == capabilities.tools.filter(capabilities.defaults.contains) ? nil : selected
        thread.draftChoice?.mcp = mcp.sorted() == roleMcp ? nil : mcp.sorted()
        dismiss()
    }
}

/// 工具规则的方向，角色与项目约束共用：只决定以后新增的工具默认是否可用，见 ToolFilter.setMode。
struct ToolModePicker: View {
    let mode: Binding<String>

    var body: some View {
        LabeledContent("以后新增的工具") {
            Picker("以后新增的工具", selection: mode) {
                Text("默认可用").tag("deny")
                Text("默认不可用").tag("allow")
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize().clickPointer()
        }
    }
}

/// 模型按厂商分组，连同思考强度；不在目录里的当前值也列出，选择器不丢值。目录里都没有思考强度（语音识别）时不显示。
struct AgentModelFields: View {
    @Binding var configuration: AgentModelConfiguration
    let vendors: [AgentCapabilities.Vendor]
    let models: [AgentCapabilities.Model]

    private var levels: [String] { models.first { $0.id == configuration.model }?.reasoning ?? [] }

    var body: some View {
        LabeledContent("模型") {
            Picker("模型", selection: Binding(get: { configuration.model }, set: { configuration.selectModel($0, in: models) })) {
                if !models.contains(where: { $0.id == configuration.model }) { Text(configuration.model).tag(configuration.model) }
                ForEach(vendors) { vendor in
                    Section(vendor.title) {
                        ForEach(models.filter { $0.vendor == vendor.id }) { entry in Text(entry.name).tag(entry.id) }
                    }
                }
            }
            .labelsHidden().fixedSize().clickPointer()
        }
        // 目录还没读到时照常显示，只是不能选
        if models.isEmpty || models.contains(where: { !$0.reasoning.isEmpty }) {
            LabeledContent("思考强度") {
                ReasoningPicker(reasoning: $configuration.reasoning, levels: levels)
                    .labelsHidden().fixedSize().clickPointer()
                    .disabled(levels.isEmpty)
            }
        }
    }
}

/// AgentModelFields 放在标题栏的样子：模型与思考强度是同一块玻璃里的两个原生菜单，中间一道竖线，选项与表单相同，
/// 目录里都没有思考强度（语音识别）时也只有模型一个菜单。
struct AgentModelMenus: View {
    @Binding var configuration: AgentModelConfiguration
    let vendors: [AgentCapabilities.Vendor]
    let models: [AgentCapabilities.Model]
    /// 竖线与按钮里的图标同高。
    @ScaledMetric(relativeTo: .body) private var dividerHeight: CGFloat = InputMode.current.labelExtent

    private var current: AgentCapabilities.Model? { models.first { $0.id == configuration.model } }
    private var levels: [String] { current?.reasoning ?? [] }

    var body: some View {
        PaneHeaderButtonGroup {
            Menu {
                ThreadModelMenuItems(models: menu)
            } label: {
                PaneHeaderButtonLabel(current?.title ?? configuration.model, logo: ThreadModelMenu.logo(vendor: current?.vendor))
            }
            .help(configuration.model)
            .accessibilityLabel("模型")
            .accessibilityValue(configuration.model)
            if models.isEmpty || models.contains(where: { !$0.reasoning.isEmpty }) {
                Rectangle().fill(Theme.rule).frame(width: 1, height: dividerHeight)
                    .allowsHitTesting(false).accessibilityHidden(true)
                Menu {
                    ReasoningPicker(reasoning: $configuration.reasoning, levels: levels)
                        .pickerStyle(.inline)
                } label: {
                    PaneHeaderButtonLabel(configuration.reasoning == "default" ? "自动" : configuration.reasoning)
                }
                .disabled(levels.isEmpty)
                .help("思考强度")
                .accessibilityLabel("思考强度")
                .accessibilityValue(configuration.reasoning)
            }
        }
    }

    /// 不在目录里的当前值单独一节排最前。
    private var menu: ThreadModelMenu {
        var sections = ThreadModelMenu.sections(vendors: vendors, models: models, selected: configuration.model) { _ in true }
        if current == nil {
            sections.insert(.init(id: "", title: nil, models: [.init(id: configuration.model, name: configuration.model, selected: true, enabled: true)]), at: 0)
        }
        return ThreadModelMenu(vendors: sections, status: nil, note: nil) { id in
            guard id != configuration.model else { return }
            configuration.selectModel(id, in: models)
        }
    }
}

/// 思考强度的选项：模型没有档位时只有「自动」，不在档位里的当前值也列出，选择器不丢值。
private struct ReasoningPicker: View {
    @Binding var reasoning: String
    let levels: [String]

    var body: some View {
        Picker("思考强度", selection: $reasoning) {
            if levels.isEmpty || reasoning == "default" { Text("自动").tag("default") }
            if reasoning != "default", !levels.contains(reasoning) {
                Text(reasoning).tag(reasoning)
            }
            ForEach(levels, id: \.self) { Text($0).tag($0) }
        }
    }
}

/// 代理可开的工具，按组折叠：角色必需的不能关闭，项目约束禁用的划掉并暂不可用。
struct AgentToolToggles: View {
    let capabilities: AgentCapabilities
    @Binding var tools: [String]

    var body: some View {
        AgentToolGroups(groups: capabilities.toolGroups, isOn: { tools.contains($0) && !capabilities.blocked.contains($0) }) { tool in
            let blocked = capabilities.blocked.contains(tool.name)
            Toggle(isOn: Binding(get: { tools.contains(tool.name) && !blocked }, set: { enabled in
                tools.removeAll { $0 == tool.name }
                if enabled { tools.append(tool.name) }
            })) {
                AgentToolTitle(tool: tool, note: capabilities.toolNote(tool.name))
            }
            .strikethrough(blocked)
            .disabled(blocked || capabilities.required.contains(tool.name))
        }
    }
}

/// 工具按组折叠列出，放在 CardSection 里：每组一行，右边是开了几个，点开逐个列出，展开的行样式由 CardSection 统一。组默认收起。
struct AgentToolGroups<Row: View>: View {
    let groups: [AgentToolGroup]
    let isOn: (String) -> Bool
    @ViewBuilder let row: (AgentToolInfo) -> Row
    @State private var expanded: Set<String> = []

    var body: some View {
        ForEach(groups) { group in
            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(group.id) }, set: { open in
                if open { expanded.insert(group.id) } else { expanded.remove(group.id) }
            })) {
                ForEach(group.tools) { row($0) }
            } label: {
                HStack(spacing: 12) {
                    Text(group.title)
                    Spacer(minLength: 0)
                    Text("\(group.tools.filter { isOn($0.name) }.count)/\(group.tools.count) 已开")
                        .font(Theme.secondary).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }
}

/// 工具行左边的名称：中文名后跟淡色的标识，名称就是标识时只写一次；note 是项目禁用、角色必需这类注明。
struct AgentToolTitle: View {
    let tool: AgentToolInfo
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(tool.title)
            if tool.title != tool.name { Text(tool.name).font(Theme.caption).foregroundStyle(.tertiary) }
            if let note { Text(note).font(Theme.caption).foregroundStyle(.secondary) }
        }
    }
}
