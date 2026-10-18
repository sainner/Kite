import SwiftUI

/// 资源库角色没保存的提示词。资源库的角色只有提示词改完要保存，名称、签名与初始配置改了即时存到工作机。
/// 切到别的角色或页面再回来还在，保存或放弃后清掉。
struct RoleDraft: Identifiable {
    let id: String
    var blocks: [ContextBlock]
    /// 开始修改时工作机上的提示词，保存前据此检查是否已在别处改过。
    var base: [ContextBlock]
}

/// 还没存过的新角色：工作机上还没有，名称、提示词、签名与初始配置都先记在本机，在上下文窗口保存时一起建。
struct NewRole: Identifiable {
    var role: RoleDefinition
    /// 手改过的签名；没改时保存后由模型按提示词生成。
    var emblem: EmblemDesign?
    var id: String { role.id }
}

/// 资源库角色即时生效的一次修改，存好之前先按改后的显示。
struct RoleChange: Identifiable {
    let id = UUID()
    let apply: (inout RoleDefinition) -> Void
}

extension AppModel {
    /// 资源库侧栏里的角色：工作机目录里的按现在的样子显示，后面接着还没存过的新角色。
    var libraryRoles: [RoleDefinition] {
        (roleCatalog?.roles ?? []).compactMap { libraryRole($0.id) } + newRoles.map(\.role)
    }

    func roleDraft(_ id: String) -> RoleDraft? { roleDrafts.first { $0.id == id } }

    func newRole(_ id: String) -> NewRole? { newRoles.first { $0.id == id } }

    /// 资源库里一个角色现在的样子：新角色是本机的；已有角色是工作机上的，叠上还没存好的修改与没保存的提示词。
    func libraryRole(_ id: String) -> RoleDefinition? {
        if let role = newRole(id)?.role { return role }
        guard var role = roleCatalog?.roles.first(where: { $0.id == id })?.role else { return nil }
        for change in roleChanges[id] ?? [] { change.apply(&role) }
        if let draft = roleDraft(id) { role.context.blocks = draft.blocks }
        return role
    }

    /// 有没保存的内容：改过提示词，或是还没存过的新角色。
    func roleUnsaved(_ id: String) -> Bool { roleDraft(id) != nil || newRole(id) != nil }

    /// 名称、签名与初始配置能不能改：新角色正在建时不能改；已有角色即时存到工作机，没连上时不能改。
    func roleEditable(_ id: String) -> Bool {
        newRole(id) != nil ? !savingRoles.contains(id) : connected
    }

    /// 改提示词，记成草稿等保存；改回与工作机上一致时草稿自动消失。新角色直接改在本机。
    func editRolePrompt(_ id: String, _ blocks: [ContextBlock]) {
        if let index = newRoles.firstIndex(where: { $0.id == id }) {
            newRoles[index].role.context.blocks = blocks
            return
        }
        guard let saved = roleCatalog?.roles.first(where: { $0.id == id })?.role.context.blocks else { return }
        if let index = roleDrafts.firstIndex(where: { $0.id == id }) {
            if blocks == saved { roleDrafts.remove(at: index) } else { roleDrafts[index].blocks = blocks }
        } else if blocks != saved {
            roleDrafts.append(RoleDraft(id: id, blocks: blocks, base: saved))
        }
    }

    /// 即时生效地改名称或初始配置：新角色改在本机；已有角色先按改后的显示，再排队存到工作机，每次都改在工作机上最新的角色上。
    /// 返回存的过程；失败时这次修改撤掉，显示退回工作机上的样子，由改的窗口报错。
    @discardableResult
    func changeRole(_ id: String, _ apply: @escaping (inout RoleDefinition) -> Void) -> Task<Void, Error>? {
        if let index = newRoles.firstIndex(where: { $0.id == id }) {
            apply(&newRoles[index].role)
            return nil
        }
        guard roleCatalog?.roles.contains(where: { $0.id == id }) == true else { return nil }
        let connection = connectionRevision
        let change = RoleChange(apply: apply)
        roleChanges[id, default: []].append(change)
        return queueRoleWrite(id) { [self] in
            defer { roleChanges[id]?.removeAll { $0.id == change.id } }
            let saved = try savedRole(id, connection: connection)
            var role = saved.role
            apply(&role)
            guard role != saved.role else { return }
            guard role.isSavable else { throw KitedError(message: "角色需要名称，每回合至少能发一次请求") }
            _ = try await saveRole(role, expectedRevision: saved.revision, connection: connection)
        }
    }

    /// 即时生效地改签名：新角色改在本机；已有角色先按改后的显示，停 delay 没再改、两条算式都有效才排队存到工作机，
    /// 写到一半无效的留着等改对。存失败时撤掉，显示退回工作机上的签名，由签名窗口报错。
    @discardableResult
    func changeRoleEmblem(_ id: String, _ design: EmblemDesign, after delay: Duration = .zero) -> Task<Void, Error>? {
        if let index = newRoles.firstIndex(where: { $0.id == id }) {
            newRoles[index].emblem = design
            return nil
        }
        guard roleCatalog?.roles.contains(where: { $0.id == id }) == true else { return nil }
        let connection = connectionRevision
        let edit = UUID()
        roleEmblems[id] = design
        roleEmblemEdits[id] = edit
        return Task { [self] in
            try await Task.sleep(for: delay)
            // 等的时候又改了（改回同一条算式也算），交给后一次。
            guard roleEmblemEdits[id] == edit, roleEmblems[id] == design, design.isValid else { return }
            defer { if roleEmblems[id] == design { roleEmblems[id] = nil } }
            try await queueRoleWrite(id) { [self] in
                try await saveRoleEmblem(design, for: savedRole(id, connection: connection), connection: connection)
            }.value
        }
    }

    /// 按提示词重新生成签名，连手改过的一起替换；排在已改的签名后面，免得生成之后又被它盖掉。
    func regenerateRoleEmblem(_ id: String) {
        let connection = connectionRevision
        roleEmblems[id] = nil
        queueRoleWrite(id) { [self] in
            try await generateRoleEmblem(savedRole(id, connection: connection), force: true, connection: connection)
        }
    }

    /// 保存改过的提示词，只换提示词；开始修改之后提示词已在别处改过时不覆盖。
    func saveRolePrompt(_ id: String) -> Task<Void, Error>? {
        guard let draft = roleDraft(id) else { return nil }
        let connection = connectionRevision
        savingRoles.insert(id)
        return queueRoleWrite(id) { [self] in
            defer { savingRoles.remove(id) }
            let saved = try savedRole(id, connection: connection)
            guard saved.role.context.blocks == draft.base else { throw KitedError(message: "提示词已在别处修改，放弃修改后再改") }
            var role = saved.role
            role.context.blocks = draft.blocks
            _ = try await saveRole(role, expectedRevision: saved.revision, connection: connection)
            roleDrafts.removeAll { $0.id == id }
        }
    }

    /// 内置角色恢复默认，没保存的提示词一并放弃。
    func resetLibraryRole(_ id: String) -> Task<Void, Error> {
        let connection = connectionRevision
        savingRoles.insert(id)
        return queueRoleWrite(id) { [self] in
            defer { savingRoles.remove(id) }
            try await resetRole(savedRole(id, connection: connection), connection: connection)
            roleDrafts.removeAll { $0.id == id }
        }
    }

    /// 把新角色建到工作机上，手改过的签名随后存；签名没存上时角色已经建好，签名回到按提示词生成。
    func createLibraryRole(_ id: String) -> Task<Void, Error>? {
        guard let new = newRole(id) else { return nil }
        let connection = connectionRevision
        savingRoles.insert(id)
        return Task { [self] in
            defer { savingRoles.remove(id) }
            _ = try await saveRole(new.role, expectedRevision: nil, connection: connection)
            newRoles.removeAll { $0.id == id }
            guard let emblem = new.emblem else { return }
            do { try await changeRoleEmblem(id, emblem)?.value }
            catch { throw KitedError(message: "角色已建好，签名没存上：\(error.localizedDescription)") }
        }
    }

    /// 基于已有角色新建一个角色并选中；没给角色时以默认角色为底，保留运行环境与项目材料等段落。
    func newLibraryRole(from base: RoleDefinition? = nil) {
        guard var role = (base ?? roleCatalog?.defaultRole?.role)?.copy() else { return }
        if base == nil { role.title = "新角色" }
        newRoles.append(NewRole(role: role))
        extensionPage = .contexts
        selectedAgentContext = AgentContextItem(category: .role, id: role.id)
    }

    /// 同一角色的写入一次一个：前一次存完才开始下一次，每次都按工作机上最新的版本改，免得带着旧版本被拒。
    @discardableResult
    private func queueRoleWrite(_ id: String, _ write: @escaping () async throws -> Void) -> Task<Void, Error> {
        let previous = roleWrites[id]
        let task = Task {
            _ = await previous?.result
            try await write()
        }
        roleWrites[id] = task
        return task
    }

    private func savedRole(_ id: String, connection: UUID) throws -> AgentRole {
        guard let target = templateConnection(connection), target.connected, let role = target.roles?.roles.first(where: { $0.id == id }) else {
            throw KitedError(message: "工作机连接已变化")
        }
        return role
    }
}

/// 资源库角色的上下文窗口：标题是角色名称，原地改名即时存；提示词改完要保存，另存、恢复默认、放弃与保存都在标题栏。
/// 新角色还没存过，另外两个窗口的修改也记在本机，在这里保存时一起建。底部控制区是编辑工具栏。
/// 改回与工作机上一致时草稿自动消失。账号里的变化经工作机推过来，不用手动刷新。
struct RoleContextPane: View {
    let id: String
    @Environment(AppModel.self) private var model
    @State private var error: String?
    @State private var discard = false
    @State private var confirmReset = false
    @State private var editor = ContextEditor()

    private var catalog: RoleCatalog? { model.roleCatalog }
    private var saved: AgentRole? { catalog?.roles.first { $0.id == id } }
    private var draft: RoleDraft? { model.roleDraft(id) }
    private var role: RoleDefinition? { model.libraryRole(id) }
    private var saving: Bool { model.savingRoles.contains(id) }
    private var canSave: Bool { !saving && model.connected && role?.isSavable == true }
    private var isNew: Bool { model.newRole(id) != nil }
    private var discardTitle: String { isNew ? "放弃新角色" : "放弃修改" }

    var body: some View {
        PaneWindow(header: PaneHeader(title: role?.title ?? "", subtitle: AgentContextCategory.role.title,
                                      titleEdit: role == nil ? nil : .init(label: "重命名角色", enabled: model.roleEditable(id)) { title in
                                          change { $0.title = title }
                                      }), notice: error.map(PaneNotice.failure), actions: PaneHeaderActions(groups: headerGroups)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if role != nil {
                        ContextVariablePreview(variables: catalog?.variables ?? [], open: { [model] in model.contextVariable = $0 })
                        ContextBlocksSection("系统规则",
                                             blocks: Binding(get: { [model, id] in model.libraryRole(id)?.context.blocks ?? [] },
                                                             set: { [model, id] blocks in model.editRolePrompt(id, blocks) }),
                                             variables: catalog?.variables ?? [])
                            .disabled(saving)
                    }
                }
                .agentContextColumn()
            }
        } controls: { _ in
            if role != nil { ContextEditorToolbar(variables: catalog?.variables ?? []).disabled(saving) }
        }
        // 按初始配置里的默认模型数 token，改了默认模型就重数。
        .contextEditor(editor, counting: model.contextCounting(model: role?.model.model, connection: model.activeConnection))
        .discardAlert(isNew ? "放弃这个新角色？" : "放弃未保存的提示词修改？", isPresented: $discard, discardLabel: discardTitle) {
            model.newRoles.removeAll { $0.id == id }
            model.roleDrafts.removeAll { $0.id == id }
        }
        .discardAlert("恢复默认内容？", isPresented: $confirmReset, discardLabel: "恢复默认",
                      message: "名称、提示词与初始配置都换回内置的默认内容\(draft == nil ? "。" : "，未保存的提示词修改一并放弃。")", discard: reset)
    }

    /// 基于此新建；内置角色改过才能恢复默认；改过提示词或是新角色才能保存或放弃。角色不能删除，放弃时新角色整个丢掉，已有角色撤掉没保存的提示词。
    private var headerGroups: [[PaneHeaderAction]] {
        var first = [
            PaneHeaderAction(title: "基于此新建角色", systemImage: "doc.on.doc", disabled: role == nil) { model.newLibraryRole(from: role) },
        ]
        if saved?.canReset == true {
            first.append(PaneHeaderAction(title: "恢复默认", systemImage: "arrow.counterclockwise", help: model.connected ? "恢复默认" : "工作机未连接",
                                          disabled: saving || !model.connected) { confirmReset = true })
        }
        var groups = [first]
        if isNew || draft != nil {
            groups.append([
                PaneHeaderAction(title: discardTitle, systemImage: isNew ? "trash" : "xmark", disabled: saving) { discard = true },
                PaneHeaderAction(title: "保存", systemImage: "checkmark", help: model.connected ? "保存" : "工作机未连接",
                                 busy: saving, disabled: !canSave, action: save),
            ])
        }
        return groups
    }

    private func change(_ apply: @escaping (inout RoleDefinition) -> Void) {
        report("保存失败", model.changeRole(id, apply))
    }

    private func save() {
        guard canSave else { return }
        report("保存失败", isNew ? model.createLibraryRole(id) : model.saveRolePrompt(id))
    }

    private func reset() {
        guard saved != nil, !saving, model.connected else { return }
        report("恢复默认失败", model.resetLibraryRole(id))
    }

    private func report(_ title: String, _ task: Task<Void, Error>?) {
        guard let task else { return }
        error = nil
        Task {
            do { try await task.value } catch { self.error = "\(title)：\(error.localizedDescription)" }
        }
    }
}

/// 资源库角色的初始配置窗口：用这个角色新建代理时的默认模型、每回合请求上限与工具，改了即时存到工作机；默认模型与思考强度在标题栏。
struct RoleSettingsPane: View {
    let id: String
    @Environment(AppModel.self) private var model
    @State private var error: String?
    @FocusState private var focus: RoleField?

    var body: some View {
        PaneWindow(header: PaneHeader(title: "初始配置", subtitle: "以此角色新建代理时的默认配置"), notice: error.map(PaneNotice.failure),
                   actions: headerActions) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let role = model.libraryRole(id) {
                        RoleSettingsForm(role: Binding(get: { model.libraryRole(id) ?? role }, set: { value in
                                             let before = model.libraryRole(id) ?? role, universe = model.roleCatalog?.tools ?? []
                                             change { $0.adopt(value, since: before, in: universe) }
                                         }),
                                         catalog: model.roleCatalog, focus: $focus)
                            .disabled(!model.roleEditable(id))
                    }
                }
                .agentContextColumn()
            }
        } controls: { _ in
            EmptyView()
        }
    }

    /// 默认模型与思考强度菜单。
    private var headerActions: PaneHeaderActions {
        PaneHeaderActions(menus: model.libraryRole(id).map { role in
            AnyView(AgentModelMenus(configuration: Binding(get: { model.libraryRole(id)?.model ?? role.model },
                                                           set: { value in change { $0.model = value } }),
                                    vendors: model.roleCatalog?.vendors ?? [], models: model.roleCatalog?.models ?? [])
                .disabled(!model.roleEditable(id)))
        })
    }

    private func change(_ apply: @escaping (inout RoleDefinition) -> Void) {
        guard let task = model.changeRole(id, apply) else { return }
        error = nil
        Task {
            do { try await task.value } catch { self.error = "保存失败：\(error.localizedDescription)" }
        }
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

private extension RoleDefinition {
    /// 表单交回的是整份改后的角色：只把这一下改了的（换规则方向、开关哪几个工具、是否必需、每回合上限、执行授权的各项、
    /// 默认审批模式）落到排队写入时工作机上最新的角色上。整份覆盖会把排在前面、没存上已撤掉的改动和别的设备的改动一起写回去。
    mutating func adopt(_ after: RoleDefinition, since before: RoleDefinition, in universe: [String]) {
        if after.maxRequestsPerTurn != before.maxRequestsPerTurn { maxRequestsPerTurn = after.maxRequestsPerTurn }
        if after.approval != before.approval { approval = after.approval }
        if after.execution != before.execution {
            let (old, new) = (before.execution ?? ExecutionChanges(), after.execution ?? ExecutionChanges())
            var value = execution ?? ExecutionChanges()
            if new.workspace != old.workspace { value.workspace = new.workspace }
            for key in ExecutionScope.Key.allCases {
                if new.add[key] != old.add[key] { value.add[key] = new.add[key] }
                if new.remove[key] != old.remove[key] { value.remove[key] = new.remove[key] }
            }
            execution = value == ExecutionChanges() ? nil : value
        }
        if after.tools.mode != before.tools.mode { tools.setMode(after.tools.mode, in: universe) }
        var seen = Set<String>()
        for name in universe + before.tools.tools + after.tools.tools where seen.insert(name).inserted {
            let enabled = after.tools.allows(name)
            if enabled != before.tools.allows(name) { tools.setEnabled(name, enabled) }
        }
        for name in before.tools.required + after.tools.required {
            let required = after.tools.required.contains(name)
            guard required != before.tools.required.contains(name), required != tools.required.contains(name) else { continue }
            tools.required.removeAll { $0 == name }
            if required { tools.required.append(name) }
        }
    }
}
