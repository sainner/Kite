import SwiftUI

/// 角色：代理的提示词、工具规则、默认模型与预算。与工作机上的角色同形，提示词按组装契约往返。
nonisolated struct RoleDefinition: Codable, Equatable, Identifiable, Sendable {
    var version = 1
    var id: String
    var title: String
    var context: ContextDefinition
    var tools: ToolRule
    var model: AgentModelConfiguration
    var maxRequestsPerTurn: Int

    /// 基于已有角色另存为新角色；提示词的 ID 与名称由工作机保存时随角色改写。
    func copy() -> Self {
        var result = self
        result.id = UUID().uuidString.lowercased()
        result.title += " 副本"
        return result
    }
}

nonisolated struct AgentRole: Decodable, Identifiable, Sendable {
    var role: RoleDefinition
    var revision: String
    var emblem: TemplateEmblem?
    /// ready、stale、missing、generating 或 failed。
    var emblemState: String?
    var emblemError: String?
    var id: String { role.id }
    var selection: RoleSelection { .init(id: id, revision: revision) }
}

nonisolated struct RoleSelection: Encodable, Sendable {
    let id: String
    let revision: String
}

/// 角色列表，附带编辑器要用的代理插件全部工具、提示词变量与模型目录。
nonisolated struct RoleCatalog: Decodable, Sendable {
    var roles: [AgentRole]
    let tools: [String]
    let variables: [ContextScene.Variable]
    let vendors: [AgentCapabilities.Vendor]
    let models: [AgentCapabilities.Model]

    /// 默认角色；工作机没有它时取第一个。
    var defaultRole: AgentRole? { roles.first { $0.id == "kite.work" } ?? roles.first }
}

private struct RoleSave: Encodable {
    let role: RoleDefinition
    let expectedRevision: String?
}

private struct ApplyRole: Encodable {
    let expectedRevision: String
    let roleId: String
    let roleRevision: String
}

extension AppModel {
    func roles(in area: WorkArea) -> RoleCatalog? {
        connection(for: area)?.roles
    }

    var roleCatalog: RoleCatalog? { activeConnection?.roles }

    func refreshRoles(in area: WorkArea? = nil) async throws {
        guard let connection = connection(for: area), connection.connected else { throw KitedError(message: "所属工作机未连接") }
        try await refreshRoles(of: connection)
    }

    /// 目录没读过才读；读过的由 roles.changed 事件和重连后的重读保持最新。
    func ensureRoles(in area: WorkArea? = nil) async throws {
        if connection(for: area)?.roles == nil { try await refreshRoles(in: area) }
    }

    func refreshRoles(of connection: WorkerConnection, fresh: Bool = false) async throws {
        try await refreshCatalog("/roles", of: connection, fresh: fresh, request: \.rolesRequest, into: \.roles)
    }

    func saveRole(_ role: RoleDefinition, expectedRevision: String?, connection: UUID) async throws -> AgentRole {
        guard let target = templateConnection(connection), target.connected else { throw KitedError(message: "工作机连接已变化，请返回角色列表") }
        let client = target.client
        let path = expectedRevision == nil ? "/roles" : "/roles/\(role.id.pathComponent)"
        let result = try await client.request(path, method: expectedRevision == nil ? "POST" : "PUT",
            body: RoleSave(role: role, expectedRevision: expectedRevision), as: AgentRole.self)
        guard target.catalog.generation == connection, accepts(client) else { throw KitedError(message: "工作机连接已变化，请返回角色列表") }
        target.roles?.roles.removeAll { $0.id == result.id }
        target.roles?.roles.append(result)
        return result
    }

    func saveRoleEmblem(_ design: EmblemDesign, for role: AgentRole, connection: UUID) async throws {
        guard let target = templateConnection(connection), target.connected else { throw KitedError(message: "工作机连接已变化，请返回角色列表") }
        let client = target.client
        let result = try await client.request("/roles/\(role.id.pathComponent)/emblem", method: "PUT",
            body: EmblemSave(emblem: design), as: AgentRole.self)
        guard target.catalog.generation == connection, accepts(client) else { throw KitedError(message: "工作机连接已变化，请返回角色列表") }
        if let index = target.roles?.roles.firstIndex(where: { $0.id == result.id }) { target.roles?.roles[index] = result }
    }

    /// 请工作机生成签名；force 时连手改的一起重新生成。结果随角色变化事件送达。
    func generateRoleEmblem(_ role: AgentRole, force: Bool, connection: UUID) async throws {
        guard let target = templateConnection(connection), target.connected else { throw KitedError(message: "工作机连接已变化") }
        let client = target.client
        let status = try await client.request("/roles/\(role.id.pathComponent)/emblem/generate", method: "POST",
            body: EmblemGenerate(force: force), as: EmblemStatus.self)
        guard target.catalog.generation == connection, accepts(client) else { return }
        if let index = target.roles?.roles.firstIndex(where: { $0.id == role.id }) {
            target.roles?.roles[index].emblem = status.emblem
            target.roles?.roles[index].emblemState = status.emblemState
            target.roles?.roles[index].emblemError = status.emblemError
        }
    }

    /// 新代理选用的角色，取工作机目录里的最新版本；没选过时用默认角色。
    func newThreadRole(for thread: WorkThread, in area: WorkArea) -> AgentRole? {
        let catalog = roles(in: area)
        let id = selectedRoleID(for: thread, in: area)
        return catalog?.roles.first { $0.id == id } ?? catalog?.defaultRole
    }

    /// 代理当前的模型：已有代理取实例配置；草稿取本机选择，没改过时用角色的默认模型。
    func agentModel(for thread: WorkThread, instance: RemotePluginInstance?, in area: WorkArea) -> AgentModelConfiguration? {
        if let instance { return instance.config?.agent?.model }
        return thread.draftChoice.flatMap { $0.model ?? newThreadRole(for: thread, in: area)?.role.model }
    }

    /// 草稿取本机选好的角色，已有代理取实例配置里记下的角色。
    func selectedRoleID(for thread: WorkThread, in area: WorkArea) -> String? {
        if let role = thread.role { return role.id }
        return area.instances.first { $0.id == thread.id }?.config?.role?.id
    }

    func roleTitle(for thread: WorkThread, in area: WorkArea) -> String {
        thread.role?.role.title
            ?? area.instances.first { $0.id == thread.id }?.config?.agent?.context["title"]?.string
            ?? newThreadRole(for: thread, in: area)?.role.title ?? "工作"
    }

    func canSelectRole(for thread: WorkThread, in area: WorkArea) -> Bool {
        !thread.configuringTemplate && isConnected(area) && roles(in: area) != nil
            && (area.instances.first { $0.id == thread.id }?.config?.agent != nil || thread.isDraft)
    }

    /// 草稿改选角色时清掉在旧角色上改过的参数；已有代理由工作机换上角色的全部配置。套用期间输入区与角色菜单禁用。
    func selectNewThreadRole(_ role: AgentRole, for thread: WorkThread, in area: WorkArea) async throws {
        guard canSelectRole(for: thread, in: area) else { return }
        thread.configuringTemplate = true
        defer { thread.configuringTemplate = false }
        let connection = revision(for: area)
        if let instance = area.instances.first(where: { $0.id == thread.id }) {
            let client = try activeClient(in: area)
            @MainActor func requireCurrent() throws {
                guard revision(for: area) == connection, client == (try activeClient(in: area)),
                      area.remote?.machine.id == client.machineID,
                      area.instances.contains(where: { $0.id == instance.id && $0.status == .open }) else {
                    throw KitedError(message: "工作机或代理已变化，请重新选择角色")
                }
            }
            try requireCurrent()
            let config = try await client.request("/instances/\(instance.id)/agent-config", as: AgentConfigurationSnapshot.self)
            try requireCurrent()
            let updated = try await client.request("/instances/\(instance.id)/role", method: "PUT",
                body: ApplyRole(expectedRevision: config.revision, roleId: role.id, roleRevision: role.revision),
                as: AgentConfigurationSnapshot.self)
            try requireCurrent()
            if let index = area.instances.firstIndex(where: { $0.id == instance.id }) {
                area.instances[index].config = updated.instance.config
            }
        } else {
            thread.draftChoice = DraftAgentChoice()
            thread.agentCapabilities = thread.agentOptions?.capabilities(for: role.id)
        }
        thread.role = role
    }
}

/// 首次发送前在代理窗口标题栏的角色菜单里选用角色，或使用同一编辑器另存新角色；必需工具不可用的角色不可选。
struct NewThreadRoleMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(WorkThread.self) private var thread
    let select: (AgentRole) -> Void
    let copy: (AgentRole) -> Void

    var body: some View {
        let selected = model.newThreadRole(for: thread, in: area)
        Section("角色") {
            ForEach(model.roles(in: area)?.roles ?? []) { role in
                let unavailable = thread.agentOptions?.roles.first { $0.id == role.id }?.unavailable
                Button { select(role) } label: {
                    if role.id == selected?.id { Label(role.role.title, systemImage: "checkmark") }
                    else if let unavailable { Text("\(role.role.title)（\(unavailable)）") }
                    else { Text(role.role.title) }
                }
                .disabled(unavailable != nil)
            }
        }
        Divider()
        Button("基于「\(selected?.role.title ?? model.roleTitle(for: thread, in: area))」新建角色…", systemImage: "plus") {
            if let selected { copy(selected) }
        }.disabled(selected == nil)
    }
}
