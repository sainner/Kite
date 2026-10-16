import SwiftUI

enum RoleField { case title, budget, read, write, network, unsandboxed }

/// 用这个角色新建代理时的初始配置：每回合请求上限、工具、执行授权与默认审批模式。资源库角色的初始配置窗口与新代理另存角色的弹窗共用；
/// 默认模型各放各的，初始配置窗口在标题栏，弹窗在表单里。
struct RoleSettingsForm: View {
    @Binding var role: RoleDefinition
    let catalog: RoleCatalog?
    let focus: FocusState<RoleField?>.Binding

    private var universe: [String] { catalog?.tools ?? [] }

    var body: some View {
        TurnBudgetField(value: $role.maxRequestsPerTurn, focus: focus, field: .budget)
        tools
        execution
    }

    /// 执行授权在项目基础上加的许可，和新建代理的默认审批模式；项目禁止的仍打不开。
    @ViewBuilder
    private var execution: some View {
        CardSection("执行授权", info: "在项目给的基础上增加，新建代理时拷进代理，之后修改角色不影响已有代理。路径可写 ~/ 开头，由各工作机按自己的主目录解析。") {
            LabeledContent("工作区") {
                Picker("工作区", selection: Binding(get: { role.execution?.workspace ?? .write }, set: { value in
                    update { $0.workspace = value == .write ? nil : value }
                })) {
                    Text("读写").tag(WorkspaceAccess.write)
                    Text("只读").tag(WorkspaceAccess.read)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            LabeledContent("默认审批模式") {
                Picker("默认审批模式", selection: Binding(get: { role.approval ?? .allowlist }, set: { role.approval = $0 == .allowlist ? nil : $0 })) {
                    ForEach(ApprovalMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
        scopeField("额外只读路径", "每行一个，例如 ~/.cargo", .read, field: .read)
        scopeField("额外读写路径", "每行一个，例如 ~/Library/Caches/pnpm", .write, field: .write)
        scopeField("允许访问的网络地址", "例如 registry.npmjs.org:443", .network, field: .network)
        scopeField("沙箱外命令", "例如 npm run dev", .unsandboxed, field: .unsandboxed,
                   note: "匹配的命令不进沙箱、以用户身份运行。以「 *」结尾表示带任意参数；命令会执行工作区里代理能改的脚本。")
    }

    private func scopeField(_ label: String, _ placeholder: String, _ key: ExecutionScope.Key, field: RoleField, note: String? = nil) -> some View {
        CardField(label: label, focused: focus.wrappedValue == field, note: note) {
            LinesField(placeholder: placeholder, values: Binding(get: { role.execution?.add[key] ?? [] }, set: { values in update { $0.add[key] = values } }))
                .lineLimit(2...5).focused(focus, equals: field)
                .scrollsOnlyWhileTyping(focus.wrappedValue == field)
                .cardInput { focus.wrappedValue = field }
        }
    }

    /// 改执行授权；改完什么都没有了就不带这一项。
    private func update(_ change: (inout ExecutionChanges) -> Void) {
        var value = role.execution ?? ExecutionChanges()
        change(&value)
        role.execution = value == ExecutionChanges() ? nil : value
    }

    /// 开关表示这个角色能用哪些工具，按组折叠，旁边的胶囊标出必需；规则的方向只决定以后新增的工具默认是否可用，单独放在列表下面。
    @ViewBuilder
    private var tools: some View {
        CardSection("工具", info: "必需的工具在代理里不能关闭；被其他约束禁用时，这个角色不可选。") {
            AgentToolGroups(groups: (catalog?.toolCatalog ?? []).groups(of: universe), isOn: { role.tools.allows($0) }) { tool in
                let name = tool.name
                let enabled = role.tools.allows(name)
                let required = role.tools.required.contains(name)
                LabeledContent {
                    HStack(spacing: 12) {
                        Button("必需") { setRequired(name, !required) }
                            .buttonStyle(RequiredTagStyle(on: required))
                            .disabled(!enabled)
                            .accessibilityLabel("\(name) 必需")
                            .accessibilityAddTraits(required ? .isSelected : [])
                        Toggle(name, isOn: Binding(get: { enabled }, set: { setEnabled(name, $0) }))
                            .labelsHidden()
                    }
                } label: {
                    AgentToolTitle(tool: tool)
                }
            }
        }
        CardSection {
            ToolModePicker(mode: Binding(get: { role.tools.mode }, set: { role.tools.setMode($0, in: universe) }))
        }
    }

    /// 关掉的工具不再算必需。
    private func setEnabled(_ name: String, _ enabled: Bool) {
        role.tools.setEnabled(name, enabled)
        if !enabled { role.tools.required.removeAll { $0 == name } }
    }

    private func setRequired(_ name: String, _ required: Bool) {
        role.tools.required.removeAll { $0 == name }
        if required { role.tools.required.append(name) }
    }
}

/// 工具行里的「必需」：点一下切换。选中是主题色浅底配主题色字，没选中只描边、字淡；工具关掉时变暗不可点。
/// 胶囊本身小，上下多留出一截点击范围。
private struct RequiredTagStyle: ButtonStyle {
    let on: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.caption.weight(.medium))
            .foregroundStyle(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background { Capsule().fill(Color.accentColor.opacity(on ? 0.15 : 0)) }
            .overlay { Capsule().strokeBorder(on ? Color.clear : Theme.rule) }
            .animation(.easeOut(duration: 0.15), value: on)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.6 : 1)
            .clickPointer()
    }
}

/// 代理窗口的角色菜单里基于已有角色另存新角色的弹窗；资源库里的角色在代理上下文的窗口里编辑，见 RoleContextPane。保存失败或冲突时保留草稿。
struct RoleEditor: View {
    let connection: UUID
    var onSaved: (AgentRole) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let original: RoleDefinition
    @State private var draft: RoleDefinition
    @State private var emblem = EmblemDesign.fallback
    @State private var phase = CardPhase.idle
    @State private var discard = false
    @FocusState private var focus: RoleField?

    init(role: RoleDefinition, connection: UUID, onSaved: @escaping (AgentRole) -> Void = { _ in }) {
        original = role
        _draft = State(initialValue: role)
        self.connection = connection
        self.onSaved = onSaved
    }

    private var catalog: RoleCatalog? { model.templateConnection(connection)?.roles }
    private var changed: Bool { draft != original || emblem != .fallback }
    private var available: Bool { model.templateConnection(connection)?.connected == true }
    private var working: Bool { phase.working }

    var body: some View {
        CardSheet(title: "新建角色",
                  subtitle: "设定代理的提示词、模型与工具", error: phase.error,
                  typing: focus != nil, size: CGSize(width: 720, height: 720),
                  close: { if changed { discard = true } else { dismiss() } }) {
            Group {
                CardField(label: "角色名称", focused: focus == .title) {
                    TextField("角色名称", text: $draft.title)
                        .focused($focus, equals: .title)
                        .cardInput { focus = .title }
                }
                Text("提示词").font(Theme.heading3)
                ContextEditing(variables: catalog?.variables ?? [],
                               counting: model.contextCounting(model: draft.model.model, connection: model.templateConnection(connection))) {
                    ContextBlocksSection("系统规则", blocks: $draft.context.blocks, variables: catalog?.variables ?? [])
                }
                TemplateEmblemField(design: $emblem)
                CardSection("默认模型") {
                    AgentModelFields(configuration: $draft.model, vendors: catalog?.vendors ?? [], models: catalog?.models ?? [])
                }
                RoleSettingsForm(role: $draft, catalog: catalog, focus: $focus)
            }
            .disabled(working || !available)
            if !available { CardCallout(text: "工作机连接已变化，请返回后重新打开角色。草稿尚未保存。", systemImage: "info.circle", tint: .secondary) }
        } actions: {
            CardSheetAction(title: "保存", systemImage: "checkmark", busy: working, action: save)
                .disabled(working || !available || !draft.isSavable)
        }
        .interactiveDismissDisabled(working || changed)
        .discardAlert("放弃未保存的角色修改？", isPresented: $discard) { dismiss() }
    }

    /// 保存成功后弹窗直接关掉。
    private func save() {
        $phase.run {
            let saved = try await model.saveRole(draft, expectedRevision: nil, connection: connection)
            if emblem != .fallback { try await model.saveRoleEmblem(emblem, for: saved, connection: connection) }
            onSaved(saved)
            dismiss()
        }
    }
}
