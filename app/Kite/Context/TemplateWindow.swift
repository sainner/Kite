import SwiftUI

/// 资源库里改过还没保存的模板。切到别的模板或页面再回来还在，保存或放弃后清掉。
struct TemplateDraft: Identifiable {
    var definition: ContextDefinition
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

    /// 改动资源库里的模板；改回与工作机上一致时不再算草稿。
    func editTemplate(_ id: String, _ change: (inout ContextDefinition) -> Void) {
        let saved = contextTemplates?.templates.first { $0.id == id }
        let index = templateDrafts.firstIndex { $0.id == id }
        guard var draft = index.map({ templateDrafts[$0] }) ?? saved.map({ TemplateDraft(definition: $0.definition, revision: $0.revision) }) else { return }
        change(&draft.definition)
        let unchanged = saved.map { draft.definition == $0.definition && draft.revision == $0.revision } ?? false
        if let index {
            if unchanged { templateDrafts.remove(at: index) } else { templateDrafts[index] = draft }
        } else if !unchanged {
            templateDrafts.append(draft)
        }
    }
}

/// 资源库代理上下文里一个模板的窗口，占满内容区；名称固定，操作与保存都在标题栏，底部控制区是编辑工具栏。
/// 修改即时记成草稿，与工作机上一致时草稿自动消失。
struct TemplatePane: View {
    let id: String
    let category: AgentContextCategory
    @Environment(AppModel.self) private var model
    @State private var saving = false
    @State private var refreshing = false
    @State private var error: String?
    @State private var discard = false
    @State private var editor = ContextEditor()

    private var saved: ContextTemplate? { model.contextTemplates?.templates.first { $0.id == id } }
    private var draft: TemplateDraft? { model.templateDraft(id) }
    private var definition: ContextDefinition? { draft?.definition ?? saved?.definition }
    private var variables: [ContextScene.Variable] {
        model.contextTemplates?.scenes.first { $0.id == definition?.scene }?.variables ?? []
    }
    private var canSave: Bool { !saving && model.connected }

    var body: some View {
        PaneWindow(header: PaneHeader(title: definition?.title ?? "", subtitle: category.title)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error { CardCallout(text: error) }
                    if let definition {
                        ContextVariablePreview(variables: variables)
                        ContextTemplateForm(definition: Binding(get: { self.definition ?? definition },
                                                                set: { value in model.editTemplate(id) { $0 = value } }),
                                            variables: variables)
                            .disabled(saving)
                    }
                }
                .agentContextColumn()
            }
        } controls: { _ in
            if definition != nil { ContextEditorToolbar(variables: variables).disabled(saving) }
        } headerActions: {
            PaneHeaderButtonGroup {
                Button { refresh() } label: { PaneHeaderButtonLabel("刷新", systemImage: "arrow.clockwise") }
                    .help("刷新")
                    .disabled(refreshing)
            }
            // 有草稿才能保存或放弃。模板不能新建或删除，放弃只撤掉没保存的修改。
            if draft != nil {
                PaneHeaderButtonGroup {
                    Button { discard = true } label: { PaneHeaderButtonLabel("放弃修改", systemImage: "xmark") }
                        .help("放弃修改")
                        .disabled(saving)
                    Button(action: save) {
                        PaneHeaderButtonLabel("保存", systemImage: "checkmark")
                            .opacity(saving ? 0 : 1)
                            .overlay { if saving { CardSpinner().scaleEffect(0.6) } }
                    }
                    .help(model.connected ? "保存" : "工作机未连接")
                    .disabled(!canSave)
                }
            }
        }
        // 模板没有自己的模型，由工作机按场景推出：标题与签名用轻任务模型，其他按默认模型。
        .contextEditor(editor, counting: model.contextCounting(model: nil, scene: definition?.scene, connection: model.activeConnection))
        .discardAlert("放弃未保存的模板修改？", isPresented: $discard, discardLabel: "放弃修改") {
            model.templateDrafts.removeAll { $0.id == id }
        }
    }

    private func refresh() {
        refreshing = true
        error = nil
        Task {
            defer { refreshing = false }
            do { try await model.refreshContextTemplates() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard let draft, canSave else { return }
        let connection = model.connectionRevision
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await model.saveContextTemplate(draft.definition, expectedRevision: draft.revision, connection: connection)
                model.templateDrafts.removeAll { $0.id == draft.id }
            } catch {
                self.error = "保存失败：\(error.localizedDescription)"
            }
        }
    }
}
