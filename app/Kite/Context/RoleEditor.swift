import SwiftUI

enum RoleField { case title, budget }

/// 用这个角色新建代理时的初始配置：默认模型、每回合请求上限与工具。资源库角色的初始配置窗口与新代理另存角色的弹窗共用。
struct RoleSettingsForm: View {
    @Binding var role: RoleDefinition
    let catalog: RoleCatalog?
    let focus: FocusState<RoleField?>.Binding

    private var universe: [String] { catalog?.tools ?? [] }

    var body: some View {
        CardSection("默认模型") {
            AgentModelFields(configuration: $role.model, vendors: catalog?.vendors ?? [], models: catalog?.models ?? [])
        }
        TurnBudgetField(value: $role.maxRequestsPerTurn, focus: focus, field: .budget)
        tools
    }

    /// 开关表示这个角色能用哪些工具；规则的方向只决定以后新增的工具默认是否可用。
    private var tools: some View {
        CardSection("工具", note: "必需的工具在代理里不能关闭；被其他约束禁用时，这个角色不可选。") {
            ToolModePicker(mode: Binding(get: { role.tools.mode }, set: { role.tools.setMode($0, in: universe) }))
            ForEach(universe, id: \.self) { name in
                let enabled = role.tools.allows(name)
                let required = role.tools.required.contains(name)
                LabeledContent(name) {
                    HStack(spacing: 12) {
                        Button(required ? "必需" : "可选") { setRequired(name, !required) }
                            .buttonStyle(.borderless).font(Theme.secondary)
                            .foregroundStyle(required ? Color.accentColor : .secondary)
                            .disabled(!enabled)
                        Toggle(name, isOn: Binding(get: { enabled }, set: { setEnabled(name, $0) }))
                            .labelsHidden()
                    }
                }
            }
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
                               counting: model.contextCounting(model: draft.model.model, scene: nil, connection: model.templateConnection(connection))) {
                    ContextBlocksEditor(blocks: $draft.context.blocks, variables: catalog?.variables ?? [])
                }
                TemplateEmblemField(design: $emblem)
                RoleSettingsForm(role: $draft, catalog: catalog, focus: $focus)
            }
            .disabled(working || !available)
            if !available { CardCallout(text: "工作机连接已变化，请返回后重新打开角色。草稿尚未保存。", systemImage: "info.circle", tint: .secondary) }
        } footer: {
            CardActions(primary: "保存",
                        enabled: !working && available && draft.isSavable,
                        phase: $phase, action: save)
        }
        .keyboardDoneButton { focus = nil }
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
