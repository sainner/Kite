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

    /// 角色页显示的角色：侧栏选中的，没选过或已不在时是默认角色。
    var libraryRoleID: String? {
        if let id = selectedLibraryRole, libraryRoles.contains(where: { $0.id == id }) { return id }
        return roleCatalog?.defaultRole?.id
    }

    func roleDraft(_ id: String) -> RoleDraft? { roleDrafts.first { $0.id == id } }

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
        extensionPage = .roles
        selectedLibraryRole = role.id
    }
}

/// 资源库的角色页：侧栏里选中的角色直接在这里编辑。
struct RoleLibrary: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        Group {
            if let id = model.libraryRoleID {
                RolePage(id: id).id(id)
            } else {
                SectionPage(header: PaneHeader(title: ExtensionLibrary.roles.title, subtitle: SidebarSection.extensions.title)) {
                    Group {
                        if let error { Text(error).foregroundStyle(Theme.danger) } else { ProgressView() }
                    }
                    .font(Theme.body)
                    .padding(Metrics.padding)
                }
            }
        }
        .task(id: model.connectionRevision) {
            error = nil
            do { try await model.ensureRoles() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// 一个角色的编辑页，操作与保存都在标题栏。修改即时记成草稿，与工作机上一致时草稿自动消失。
private struct RolePage: View {
    let id: String
    @Environment(AppModel.self) private var model
    @State private var saving = false
    @State private var refreshing = false
    @State private var error: String?
    @State private var discard = false
    @FocusState private var focus: RoleField?

    private var catalog: RoleCatalog? { model.roleCatalog }
    private var saved: AgentRole? { catalog?.roles.first { $0.id == id } }
    private var draft: RoleDraft? { model.roleDraft(id) }
    private var role: RoleDefinition? { draft?.role ?? saved?.role }
    private var canSave: Bool { !saving && model.connected && role?.isSavable == true }
    private var isNew: Bool { saved == nil }
    private var discardTitle: String { isNew ? "放弃新角色" : "放弃修改" }

    var body: some View {
        SectionPage(header: PaneHeader(title: role?.title ?? "", subtitle: ExtensionLibrary.roles.title)) {
            if let role {
                form(role)
            }
        } actions: {
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
                        PaneHeaderButtonLabel("保存")
                            .opacity(saving ? 0 : 1)
                            .overlay { if saving { CardSpinner().scaleEffect(0.6) } }
                    }
                    .help(model.connected ? "保存" : "工作机未连接")
                    .disabled(!canSave)
                }
            }
        }
        .keyboardDoneButton { focus = nil }
        .discardAlert(isNew ? "放弃这个新角色？" : "放弃未保存的角色修改？", isPresented: $discard, discardLabel: discardTitle) {
            model.roleDrafts.removeAll { $0.id == id }
        }
    }

    private func form(_ role: RoleDefinition) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CardNote("角色随 Kite 账号保存，各工作机共用，修改只影响之后新建的代理。工具、模型与预算是新建代理时的初始值，代理草稿里还能在此范围内调整。提示词双击段落编辑。")
                if let error { CardCallout(text: error) }
                RoleForm(role: Binding(get: { self.role ?? role }, set: { value in model.editRole(id) { $0.role = value } }),
                         emblem: Binding(get: { draft?.emblem ?? saved?.emblem?.design ?? .fallback },
                                         set: { value in model.editRole(id) { $0.emblem = value } }),
                         current: saved, catalog: catalog,
                         regenerate: saved.map { saved in { regenerateEmblem(saved) } }, focus: $focus)
                    .disabled(saving)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, CardMetrics.sheetInset)
            .padding(.vertical, Metrics.padding)
            .frame(maxWidth: .infinity)
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

    /// 交给模型重画；手改的签名随之作废。
    private func regenerateEmblem(_ role: AgentRole) {
        model.editRole(id) { $0.emblem = nil }
        Task { try? await model.generateRoleEmblem(role, force: true, connection: model.connectionRevision) }
    }

    private func save() {
        guard let draft, canSave else { return }
        let connection = model.connectionRevision
        saving = true
        error = nil
        Task {
            defer { saving = false }
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
