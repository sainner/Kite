import SwiftUI

struct RoleEdit: Identifiable {
    let role: RoleDefinition
    var original: AgentRole? = nil
    var id: String { role.id }
}

/// 资源库与新代理共用的角色编辑器：名称、提示词、点阵签名、工具规则、默认模型与预算。保存失败或冲突时保留草稿。
struct RoleEditor: View {
    private enum Field { case title, budget }

    let request: RoleEdit
    @State private var connection: UUID
    var onSaved: (AgentRole) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RoleDefinition
    /// 点阵签名草稿；与 emblemBase 不同即为手改，保存角色后一并保存。
    @State private var emblem: EmblemDesign
    /// 工作机上签名的最新版本；没改过草稿时，重新生成的结果直接替换草稿。
    @State private var emblemBase: EmblemDesign
    @State private var phase = CardPhase.idle
    @State private var discard = false
    @FocusState private var focus: Field?

    init(request: RoleEdit, connection: UUID, onSaved: @escaping (AgentRole) -> Void = { _ in }) {
        self.request = request
        _connection = State(initialValue: connection)
        self.onSaved = onSaved
        _draft = State(initialValue: request.role)
        let emblem = request.original?.emblem?.design ?? .fallback
        _emblem = State(initialValue: emblem)
        _emblemBase = State(initialValue: emblem)
    }

    private var catalog: RoleCatalog? { model.templateConnection(connection)?.roles }
    /// 工作机目录里这个角色的最新状态，签名生成的进度从这里来。
    private var current: AgentRole? {
        request.original.flatMap { original in catalog?.roles.first { $0.id == original.id } }
    }
    private var universe: [String] { catalog?.tools ?? [] }
    private var changed: Bool { draft != request.role || emblemEdited }
    private var emblemEdited: Bool { emblem != emblemBase }
    private var available: Bool { model.templateConnection(connection)?.connected == true }
    private var working: Bool { phase.working }
    private var levels: [String] { catalog?.models.first { $0.id == draft.model.model }?.reasoning ?? [] }

    var body: some View {
        CardSheet(title: request.original == nil ? "新建角色" : "编辑角色",
                  subtitle: "提示词双击段落编辑。工具、模型与预算是用这个角色新建代理时的初始值，草稿里还能在此范围内调整。",
                  typing: focus != nil, size: CGSize(width: 720, height: 720),
                  close: { if changed { discard = true } else { dismiss() } }) {
            Group {
                CardField(label: "角色名称", focused: focus == .title) {
                    TextField("角色名称", text: $draft.title)
                        .focused($focus, equals: .title)
                        .cardInput { focus = .title }
                }
                Text("提示词").font(.headline)
                ContextBlocksEditor(blocks: $draft.context.blocks, variables: catalog?.variables ?? [])
                TemplateEmblemField(design: $emblem, role: current,
                                    regenerate: current.map { role in { regenerateEmblem(role) } })
                tools
                defaults
            }
            .disabled(working || !available)
            .onChange(of: current?.emblem?.design) { _, design in
                guard let design else { return }
                if emblem == emblemBase { emblem = design }
                emblemBase = design
            }
            if !available { CardCallout(text: "工作机连接已变化，请返回后重新打开角色。草稿尚未保存。", systemImage: "info.circle", tint: .secondary) }
        } footer: {
            CardActions(primary: "保存",
                        enabled: !working && available && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && draft.maxRequestsPerTurn >= 1,
                        phase: $phase, action: save)
        }
        #if os(iOS)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focus = nil } } }
        #endif
        .interactiveDismissDisabled(working || changed)
        .confirmationDialog("放弃未保存的角色修改？", isPresented: $discard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
        }
    }

    /// 开关表示这个角色能用哪些工具；规则的方向只决定以后新增的工具默认是否可用。
    private var tools: some View {
        CardSection("工具", note: "必需的工具在代理里不能关闭；被其他约束禁用时，这个角色不可选。") {
            LabeledContent("以后新增的工具") {
                Picker("以后新增的工具", selection: Binding(get: { draft.tools.mode }, set: setMode)) {
                    Text("默认可用").tag("deny")
                    Text("默认不可用").tag("allow")
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            ForEach(universe, id: \.self) { name in
                let enabled = draft.tools.permitted(in: universe).contains(name)
                let required = draft.tools.required.contains(name)
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

    private var defaults: some View {
        Group {
            CardSection("默认模型") {
                LabeledContent("模型") {
                    Picker("模型", selection: Binding(get: { draft.model.model }, set: { id in
                        draft.model.selectModel(id, supportedReasoning: catalog?.models.first { $0.id == id }?.reasoning ?? [])
                    })) {
                        if let catalog, !catalog.models.contains(where: { $0.id == draft.model.model }) {
                            Text(draft.model.model).tag(draft.model.model)
                        }
                        ForEach(catalog?.vendors ?? []) { vendor in
                            Section(vendor.title) {
                                ForEach(catalog?.models.filter { $0.vendor == vendor.id } ?? []) { entry in Text(entry.name).tag(entry.id) }
                            }
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                LabeledContent("思考强度") {
                    Picker("思考强度", selection: $draft.model.reasoning) {
                        if levels.isEmpty || draft.model.reasoning == "default" { Text("自动").tag("default") }
                        if draft.model.reasoning != "default", !levels.contains(draft.model.reasoning) {
                            Text(draft.model.reasoning).tag(draft.model.reasoning)
                        }
                        ForEach(levels, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(levels.isEmpty)
                }
            }
            CardField(label: "每回合最多模型请求数", focused: focus == .budget, note: "达到上限后停止，保留已经产生的结果。") {
                TextField("", value: $draft.maxRequestsPerTurn, format: .number)
                    .focused($focus, equals: .budget)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .cardInput { focus = .budget }
            }
        }
    }

    /// 换规则方向时保持当前能用的工具不变。
    private func setMode(_ mode: String) {
        let enabled = draft.tools.permitted(in: universe)
        draft.tools.mode = mode
        draft.tools.tools = mode == "allow" ? enabled : universe.filter { !enabled.contains($0) }
    }

    private func setEnabled(_ name: String, _ enabled: Bool) {
        draft.tools.tools.removeAll { $0 == name }
        if enabled == (draft.tools.mode == "allow") { draft.tools.tools.append(name) }
        if !enabled { draft.tools.required.removeAll { $0 == name } }
    }

    private func setRequired(_ name: String, _ required: Bool) {
        draft.tools.required.removeAll { $0 == name }
        if required { draft.tools.required.append(name) }
    }

    /// 交给模型重画；草稿里手改的部分随之作废。
    private func regenerateEmblem(_ role: AgentRole) {
        emblem = emblemBase
        Task { try? await model.generateRoleEmblem(role, force: true, connection: connection) }
    }

    /// 保存成功后弹窗直接关掉。
    private func save() {
        $phase.run {
            var role = draft
            role.context.id = role.id
            role.context.title = role.title
            let saved = try await model.saveRole(role, expectedRevision: request.original?.revision, connection: connection)
            if emblemEdited { try await model.saveRoleEmblem(emblem, for: saved, connection: connection) }
            onSaved(saved)
            dismiss()
        }
    }
}
