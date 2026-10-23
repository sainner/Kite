import SwiftUI

/// 资源库里改过还没保存的模板。切到别的模板或页面再回来还在，保存或放弃后清掉。
struct TemplateDraft: Identifiable {
    var definition: ContextDefinition
    var model: AgentModelConfiguration?
    /// 开始修改时模板的版本，保存时据此检查冲突。
    var revision: String
    var id: String { definition.id }
}

extension AppModel {
    /// 资源库侧栏里一类模板：按场景排，改过的按草稿显示。模板由工作机按场景提供，不能新建或删除。
    func libraryTemplates(_ kind: ContextScene.Kind) -> [ContextDefinition] {
        guard let catalog = contextTemplates else { return [] }
        return catalog.scenes.filter { $0.kind == kind }
            .flatMap { scene in catalog.templates.filter { $0.definition.scene == scene.id } }
            .map { templateDraft($0.id)?.definition ?? $0.definition }
    }

    func templateDraft(_ id: String) -> TemplateDraft? { templateDrafts.first { $0.id == id } }

    func libraryTemplate(_ id: String) -> ContextDefinition? {
        templateDraft(id)?.definition ?? contextTemplates?.templates.first { $0.id == id }?.definition
    }

    /// 辅助生成模板的模型与思考强度，其他模板为 nil。
    func libraryTemplateModel(_ id: String) -> AgentModelConfiguration? {
        if let draft = templateDraft(id) { return draft.model }
        return contextTemplates?.templates.first { $0.id == id }?.model
    }

    /// 改动资源库里的模板；改回与工作机上一致时不再算草稿。
    func editTemplate(_ id: String, _ change: (inout TemplateDraft) -> Void) {
        let saved = contextTemplates?.templates.first { $0.id == id }
        editDraft(\.templateDrafts, id, from: saved.map { TemplateDraft(definition: $0.definition, model: $0.model, revision: $0.revision) }, change) { draft in
            saved.map { draft.definition == $0.definition && draft.model == $0.model && draft.revision == $0.revision } ?? false
        }
    }
}

/// 资源库代理上下文里一个模板的窗口，占满内容区；名称固定，操作与保存都在标题栏，底部控制区是编辑工具栏。
/// 辅助生成的模板在标题栏选模型与思考强度，副行是用什么凭据调用。修改即时记成草稿，与工作机上一致时草稿自动消失。
/// 账号里的变化经工作机推过来，不用手动刷新。
struct TemplatePane: View {
    let id: String
    let category: AgentContextCategory
    @Environment(AppModel.self) private var model
    @State private var saving = false
    @State private var error: String?
    @State private var discard = false
    @State private var confirmReset = false
    @State private var editor = ContextEditor()

    private var saved: ContextTemplate? { model.contextTemplates?.templates.first { $0.id == id } }
    private var draft: TemplateDraft? { model.templateDraft(id) }
    private var definition: ContextDefinition? { model.libraryTemplate(id) }
    private var configuration: AgentModelConfiguration? { model.libraryTemplateModel(id) }
    private var scene: ContextScene? { model.contextTemplates?.scenes.first { $0.id == definition?.scene } }
    private var variables: [ContextScene.Variable] { scene?.variables ?? [] }
    private var canSave: Bool { !saving && model.connected }

    var body: some View {
        PaneWindow(header: PaneHeader(title: definition?.title ?? "", subtitle: scene?.models?.note ?? category.title), notice: error.map(PaneNotice.failure),
                   actions: PaneHeaderActions(groups: headerGroups, menus: modelMenus)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let definition {
                        ContextVariablePreview(variables: variables, open: { [model] in model.contextVariable = $0 })
                        ContextTemplateForm(definition: Binding(get: { [model, id] in model.libraryTemplate(id) ?? definition },
                                                                set: { [model, id] value in model.editTemplate(id) { $0.definition = value } }),
                                            variables: variables)
                            .disabled(saving)
                    }
                }
                .agentContextColumn()
            }
        } controls: { _ in
            if definition != nil { ContextEditorToolbar(variables: variables).disabled(saving) }
        }
        // 辅助生成按模板自己的模型数；其他模板没有自己的模型（压缩实际用会话的模型），模型不能计数的（语音识别），由工作机按默认模型数。
        .contextEditor(editor, counting: model.contextCounting(
            model: scene?.models?.counts == true ? configuration?.model : nil, connection: model.activeConnection))
        .discardAlert("放弃未保存的模板修改？", isPresented: $discard, discardLabel: "放弃修改") {
            model.templateDrafts.removeAll { $0.id == id }
        }
        .discardAlert("恢复默认内容？", isPresented: $confirmReset, discardLabel: "恢复默认",
                      message: "\(scene?.models == nil ? "模板内容" : "模板内容与模型")换回内置的默认\(draft == nil ? "。" : "，未保存的修改一并放弃。")",
                      discard: reset)
    }

    /// 辅助生成模板的模型与思考强度菜单，同角色初始配置的默认模型。
    private var modelMenus: AnyView? {
        guard let configuration, let choices = scene?.models else { return nil }
        return AnyView(AgentModelMenus(configuration: Binding(get: { [model, id] in model.libraryTemplateModel(id) ?? configuration },
                                                              set: { [model, id] value in model.editTemplate(id) { $0.model = value } }),
                                       vendors: choices.vendors, models: choices.models)
            .disabled(saving))
    }

    /// 改过才能恢复默认；有草稿才能保存或放弃。模板不能新建或删除，放弃只撤掉没保存的修改。
    private var headerGroups: [[PaneHeaderAction]] {
        var groups: [[PaneHeaderAction]] = []
        if saved?.canReset == true {
            groups.append([PaneHeaderAction(title: "恢复默认", systemImage: "arrow.counterclockwise", help: model.connected ? "恢复默认" : "工作机未连接",
                                            disabled: !canSave) { confirmReset = true }])
        }
        if draft != nil {
            groups.append([
                PaneHeaderAction(title: "放弃修改", systemImage: "xmark", disabled: saving) { discard = true },
                PaneHeaderAction(title: "保存", systemImage: "checkmark", help: model.connected ? "保存" : "工作机未连接",
                                 busy: saving, disabled: !canSave, action: save),
            ])
        }
        return groups
    }

    private func save() {
        guard let draft, canSave else { return }
        let connection = model.connectionRevision
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await model.saveContextTemplate(draft, connection: connection)
                model.templateDrafts.removeAll { $0.id == draft.id }
            } catch {
                self.error = "保存失败：\(error.localizedDescription)"
            }
        }
    }

    private func reset() {
        guard let saved, canSave else { return }
        let connection = model.connectionRevision
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await model.resetContextTemplate(saved, connection: connection)
                model.templateDrafts.removeAll { $0.id == saved.id }
            } catch {
                self.error = "恢复默认失败：\(error.localizedDescription)"
            }
        }
    }
}
