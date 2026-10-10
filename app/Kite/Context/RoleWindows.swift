import SwiftUI

/// 资源库里改过还没保存的角色。切到别的角色或页面再回来还在，保存或放弃后清掉。
struct RoleDraft: Identifiable {
    var role: RoleDefinition
    /// 手改过的点阵签名；没改时跟随工作机上的最新签名，重新生成的结果直接显示。
    var emblem: EmblemDesign?
    /// 开始修改时角色的版本，保存时据此检查冲突；新角色没有。
    var revision: String?
    var id: String { role.id }
}

extension AppModel {
    /// 资源库侧栏里的角色：工作机目录里的按草稿显示，后面接着还没保存的新角色。
    var libraryRoles: [RoleDefinition] {
        (roleCatalog?.roles ?? []).map { role in roleDrafts.first { $0.id == role.id }?.role ?? role.role }
            + roleDrafts.filter { $0.revision == nil }.map(\.role)
    }

    func roleDraft(_ id: String) -> RoleDraft? { roleDrafts.first { $0.id == id } }

    /// 资源库里一个角色现在的样子：有草稿按草稿。
    func libraryRole(_ id: String) -> RoleDefinition? {
        roleDraft(id)?.role ?? roleCatalog?.roles.first { $0.id == id }?.role
    }

    /// 改动资源库里的角色；改回与工作机上一致时不再算草稿。
    func editRole(_ id: String, _ change: (inout RoleDraft) -> Void) {
        let saved = roleCatalog?.roles.first { $0.id == id }
        let index = roleDrafts.firstIndex { $0.id == id }
        guard var draft = index.map({ roleDrafts[$0] }) ?? saved.map({ RoleDraft(role: $0.role, revision: $0.revision) }) else { return }
        change(&draft)
        if draft.emblem == (saved?.emblem?.design ?? .fallback) { draft.emblem = nil }
        let unchanged = saved.map { draft.role == $0.role && draft.emblem == nil && draft.revision == $0.revision } ?? false
        if let index {
            if unchanged { roleDrafts.remove(at: index) } else { roleDrafts[index] = draft }
        } else if !unchanged {
            roleDrafts.append(draft)
        }
    }

    /// 基于已有角色新建一个角色草稿并选中；没给角色时以默认角色为底，保留运行环境与项目材料等段落。
    func newLibraryRole(from base: RoleDefinition? = nil) {
        guard var role = (base ?? roleCatalog?.defaultRole?.role)?.copy() else { return }
        if base == nil { role.title = "新角色" }
        roleDrafts.append(RoleDraft(role: role))
        extensionPage = .contexts
        selectedAgentContext = AgentContextItem(category: .role, id: role.id)
    }
}

/// 资源库角色的上下文窗口：标题是角色名称，可原地改名；刷新、另存与保存都在标题栏，保存连同签名与初始配置的修改一起存。
/// 底部控制区是编辑工具栏。
/// 修改即时记成草稿，与工作机上一致时草稿自动消失。
struct RoleContextPane: View {
    let id: String
    @Environment(AppModel.self) private var model
    @State private var refreshing = false
    @State private var error: String?
    @State private var discard = false
    @State private var editor = ContextEditor()

    private var catalog: RoleCatalog? { model.roleCatalog }
    private var saved: AgentRole? { catalog?.roles.first { $0.id == id } }
    private var draft: RoleDraft? { model.roleDraft(id) }
    private var role: RoleDefinition? { model.libraryRole(id) }
    private var saving: Bool { model.savingRoles.contains(id) }
    private var canSave: Bool { !saving && model.connected && role?.isSavable == true }
    private var isNew: Bool { saved == nil }
    private var discardTitle: String { isNew ? "放弃新角色" : "放弃修改" }

    var body: some View {
        PaneWindow(header: PaneHeader(title: role?.title ?? "", subtitle: AgentContextCategory.role.title,
                                      titleEdit: role == nil ? nil : .init(label: "重命名角色", enabled: !saving) { title in
                                          model.editRole(id) { $0.role.title = title }
                                      })) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error { CardCallout(text: error) }
                    if role != nil {
                        ContextVariablePreview(variables: catalog?.variables ?? [])
                        ContextSection("系统规则") {
                            ContextBlocksEditor(blocks: Binding(get: { model.libraryRole(id)?.context.blocks ?? [] },
                                                                set: { blocks in model.editRole(id) { $0.role.context.blocks = blocks } }),
                                                variables: catalog?.variables ?? [])
                        }
                        .disabled(saving)
                    }
                }
                .agentContextColumn()
            }
        } controls: { _ in
            if role != nil { ContextEditorToolbar(variables: catalog?.variables ?? []).disabled(saving) }
        } headerActions: {
            PaneHeaderButtonGroup {
                Button { refresh() } label: { PaneHeaderButtonLabel("刷新", systemImage: "arrow.clockwise") }
                    .help("刷新")
                    .disabled(refreshing)
                Button { model.newLibraryRole(from: role) } label: { PaneHeaderButtonLabel("基于此新建角色", systemImage: "doc.on.doc") }
                    .help("基于此新建角色")
                    .disabled(role == nil)
            }
            // 有草稿才能保存或放弃。角色不能删除，放弃时新角色整个丢掉，已有角色撤掉没保存的修改。
            if draft != nil {
                PaneHeaderButtonGroup {
                    Button { discard = true } label: {
                        PaneHeaderButtonLabel(discardTitle, systemImage: isNew ? "trash" : "xmark")
                    }
                    .help(discardTitle)
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
        // 按初始配置里的默认模型数 token，改了默认模型就重数。
        .contextEditor(editor, counting: model.contextCounting(model: role?.model.model, scene: nil, connection: model.activeConnection))
        .discardAlert(isNew ? "放弃这个新角色？" : "放弃未保存的角色修改？", isPresented: $discard, discardLabel: discardTitle) {
            model.roleDrafts.removeAll { $0.id == id }
        }
    }

    private func refresh() {
        refreshing = true
        error = nil
        Task {
            defer { refreshing = false }
            do { try await model.refreshRoles() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard let draft, canSave else { return }
        let connection = model.connectionRevision
        model.savingRoles.insert(id)
        error = nil
        Task {
            defer { model.savingRoles.remove(draft.id) }
            do {
                let saved = try await model.saveRole(draft.role, expectedRevision: draft.revision, connection: connection)
                // 角色先存好；签名另存失败时，草稿里只剩手改的签名。
                model.editRole(saved.id) { $0.role = saved.role; $0.revision = saved.revision }
                if let emblem = draft.emblem { try await model.saveRoleEmblem(emblem, for: saved, connection: connection) }
                model.roleDrafts.removeAll { $0.id == saved.id }
            } catch {
                self.error = "保存失败：\(error.localizedDescription)"
            }
        }
    }
}

/// 资源库角色的初始配置窗口：用这个角色新建代理时的默认模型、每回合请求上限与工具。
struct RoleSettingsPane: View {
    let id: String
    @Environment(AppModel.self) private var model
    @FocusState private var focus: RoleField?

    var body: some View {
        PaneWindow(header: PaneHeader(title: "初始配置")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let role = model.libraryRole(id) {
                        RoleSettingsForm(role: Binding(get: { model.libraryRole(id) ?? role }, set: { value in model.editRole(id) { $0.role = value } }),
                                         catalog: model.roleCatalog, focus: $focus)
                            .disabled(model.savingRoles.contains(id))
                    }
                }
                .agentContextColumn()
            }
        } controls: { _ in
            EmptyView()
        }
        .keyboardDoneButton { focus = nil }
    }
}

extension View {
    /// 代理上下文窗口的正文：限宽居中，边距同账号窗口。
    func agentContextColumn() -> some View {
        frame(maxWidth: Metrics.transcriptWidth, alignment: .leading)
            .padding(CardMetrics.inset)
            .frame(maxWidth: .infinity)
            .separateScrollPocket()
    }
}
