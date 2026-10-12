import SwiftUI

enum RoleField { case title, budget }

/// 用这个角色新建代理时的初始配置：每回合请求上限与工具。资源库角色的初始配置窗口与新代理另存角色的弹窗共用；
/// 默认模型各放各的，初始配置窗口在标题栏，弹窗在表单里。
struct RoleSettingsForm: View {
    @Binding var role: RoleDefinition
    let catalog: RoleCatalog?
    let focus: FocusState<RoleField?>.Binding

    private var universe: [String] { catalog?.tools ?? [] }

    var body: some View {
        TurnBudgetField(value: $role.maxRequestsPerTurn, focus: focus, field: .budget)
        tools
    }

    /// 开关表示这个角色能用哪些工具，按组折叠，旁边的胶囊标出必需；规则的方向只决定以后新增的工具默认是否可用，单独放在列表下面。
    @ViewBuilder
    private var tools: some View {
        CardSection("工具", info: "必需的工具在代理里不能关闭；被其他约束禁用时，这个角色不可选。") {
            AgentToolGroups(groups: (catalog?.toolCatalog).groups(of: universe), isOn: { role.tools.allows($0) }) { tool in
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
                  subtitle: "工具、模型与预算是用这个角色新建代理时的初始值，草稿里还能在此范围内调整。",
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
        } footer: {
            CardActions(primary: "保存",
                        enabled: !working && available && draft.isSavable,
                        phase: $phase, action: save)
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
