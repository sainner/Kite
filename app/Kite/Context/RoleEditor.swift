import SwiftUI

enum RoleField { case title, budget }

/// 角色的各项设置：名称、提示词、点阵签名、工具规则、默认模型与预算。资源库的角色页与新代理另存角色的弹窗共用。
struct RoleForm: View {
    @Binding var role: RoleDefinition
    @Binding var emblem: EmblemDesign
    /// 工作机目录里这个角色的最新状态，签名生成的进度从这里来；新角色没有。
    let current: AgentRole?
    let catalog: RoleCatalog?
    var regenerate: (() -> Void)?
    let focus: FocusState<RoleField?>.Binding

    private var universe: [String] { catalog?.tools ?? [] }

    var body: some View {
        CardField(label: "角色名称", focused: focus.wrappedValue == .title) {
            TextField("角色名称", text: $role.title)
                .focused(focus, equals: .title)
                .cardInput { focus.wrappedValue = .title }
        }
        Text("提示词").font(.headline)
        ContextBlocksEditor(blocks: $role.context.blocks, variables: catalog?.variables ?? [])
        TemplateEmblemField(design: $emblem, role: current, regenerate: regenerate)
        tools
        CardSection("默认模型") {
            AgentModelFields(configuration: $role.model, vendors: catalog?.vendors ?? [], models: catalog?.models ?? [])
        }
        TurnBudgetField(value: $role.maxRequestsPerTurn, focus: focus, field: .budget)
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

/// 代理窗口的角色菜单里基于已有角色另存新角色的弹窗；资源库里的角色在角色页编辑，见 RoleLibrary。保存失败或冲突时保留草稿。
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
                  subtitle: "提示词双击段落编辑。工具、模型与预算是用这个角色新建代理时的初始值，草稿里还能在此范围内调整。",
                  typing: focus != nil, size: CGSize(width: 720, height: 720),
                  close: { if changed { discard = true } else { dismiss() } }) {
            RoleForm(role: $draft, emblem: $emblem, current: nil, catalog: catalog, focus: $focus)
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
