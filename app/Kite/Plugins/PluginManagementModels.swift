import Foundation

nonisolated enum PluginLifetime: String, Decodable, Sendable {
    case window, persistent, process

    var title: String {
        switch self {
        case .window: "随窗口回收"
        case .persistent: "独立存续"
        case .process: "随进程回收"
        }
    }
    var explanation: String {
        switch self {
        case .window: "关闭最后一个窗口时，结束运行并回收实例和状态。"
        case .persistent: "关闭窗口后保留实例和数据，可在侧栏重新打开；不再需要时归档。"
        case .process: "进程运行时关闭窗口照常运行，留在停靠栏；进程结束后没有窗口就回收。"
        }
    }
}

/// 管理端只编辑授权选择；调用身份、声明与执行校验由工作机负责。
nonisolated struct OperationGrant: Codable, Equatable, Sendable {
    nonisolated struct Targets: Codable, Equatable, Sendable {
        let kind: String
        var instanceIds: [String]? = nil
    }
    let operation: String
    var roleIds: [String]? = nil
    var targets: Targets? = nil
    var instanceId: String? = nil
    var tools: [String]? = nil
}

nonisolated struct InstanceGrants: Codable, Equatable, Sendable {
    let revision: String
    var grants: [OperationGrant]
}

struct GrantUpdate: Encodable {
    let expectedRevision: String
    let grants: [OperationGrant]
}

struct PluginGrantDraft {
    let revision: String
    var grants: [OperationGrant]

    init(snapshot: InstanceGrants) { revision = snapshot.revision; grants = snapshot.grants }
    var request: GrantUpdate { GrantUpdate(expectedRevision: revision, grants: grants) }

    func includesTool(instanceID: String, name: String) -> Bool {
        grants.contains { $0.operation == "plugin.call" && $0.instanceId == instanceID && ($0.tools?.contains(name) ?? false) }
    }

    mutating func setTool(instanceID: String, name: String, enabled: Bool) {
        var tools = Set(grants.filter { $0.operation == "plugin.call" && $0.instanceId == instanceID }.flatMap { $0.tools ?? [] })
        if enabled { tools.insert(name) } else { tools.remove(name) }
        grants.removeAll { $0.operation == "plugin.call" && $0.instanceId == instanceID }
        if !tools.isEmpty { grants.append(OperationGrant(operation: "plugin.call", instanceId: instanceID, tools: tools.sorted())) }
    }

    func includesTarget(operation: String, instanceID: String) -> Bool {
        grants.contains { $0.operation == operation && $0.targets?.kind == "instances" && ($0.targets?.instanceIds?.contains(instanceID) ?? false) }
    }

    mutating func setTarget(operation: String, instanceID: String, enabled: Bool) {
        var ids = Set(grants.filter { $0.operation == operation && $0.targets?.kind == "instances" }.flatMap { $0.targets?.instanceIds ?? [] })
        if enabled { ids.insert(instanceID) } else { ids.remove(instanceID) }
        grants.removeAll { $0.operation == operation && $0.targets?.kind == "instances" }
        if !ids.isEmpty { grants.append(OperationGrant(operation: operation, targets: .init(kind: "instances", instanceIds: ids.sorted()))) }
    }

    func includesRole(_ id: String) -> Bool {
        grants.contains { $0.operation == "agent.start" && ($0.roleIds?.contains(id) ?? false) }
    }

    mutating func setRole(_ id: String, enabled: Bool) {
        var ids = Set(grants.filter { $0.operation == "agent.start" }.flatMap { $0.roleIds ?? [] })
        if enabled { ids.insert(id) } else { ids.remove(id) }
        grants.removeAll { $0.operation == "agent.start" }
        if !ids.isEmpty { grants.append(OperationGrant(operation: "agent.start", roleIds: ids.sorted())) }
    }

    mutating func set(_ grant: OperationGrant, enabled: Bool) {
        grants.removeAll { $0 == grant }
        if enabled { grants.append(grant) }
    }
}

nonisolated struct RemoteOperation: Decodable, Identifiable, Sendable {
    let name: String
    let title: String
    let description: String
    let callers: [String]
    var id: String { name }
}

struct RemotePluginTool: Decodable, Identifiable {
    struct Meta: Decodable {
        struct UI: Decodable { let visibility: [String]? }
        let ui: UI?
    }
    struct Execution: Decodable { let taskSupport: String? }
    let name: String
    let title: String?
    let description: String?
    let _meta: Meta?
    let execution: Execution?
    var id: String { name }
    var canGrant: Bool { (_meta?.ui?.visibility?.contains("model") ?? true) && execution?.taskSupport != "required" }
}

nonisolated struct PluginPackagePreview: Decodable, Sendable {
    nonisolated struct View: Decodable, Identifiable, Sendable { let id: String; let title: String }
    let id: String
    let title: String
    let lifetime: PluginLifetime
    let views: [View]?
}

struct CreatePluginInstance: Encodable {
    let id: String
    let definitionId: String
}

/// 一组执行许可：额外读、写路径，网络，沙箱外命令。项目、角色、实例三层共用，见 docs/Agent与插件契约.md §3.2。
nonisolated struct ExecutionScope: Codable, Equatable, Sendable {
    var read: [String] = []
    var write: [String] = []
    var network: [String] = []
    var unsandboxed: [String] = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        read = try c.decodeIfPresent([String].self, forKey: .read) ?? []
        write = try c.decodeIfPresent([String].self, forKey: .write) ?? []
        network = try c.decodeIfPresent([String].self, forKey: .network) ?? []
        unsandboxed = try c.decodeIfPresent([String].self, forKey: .unsandboxed) ?? []
    }

    subscript(_ key: ExecutionScope.Key) -> [String] {
        get { self[keyPath: key.path] }
        set { self[keyPath: key.path] = newValue }
    }

    enum Key: CaseIterable {
        case read, write, network, unsandboxed
        var path: WritableKeyPath<ExecutionScope, [String]> {
            switch self {
            case .read: \.read
            case .write: \.write
            case .network: \.network
            case .unsandboxed: \.unsandboxed
            }
        }
    }
}

/// 代理对工作区的访问权限。
nonisolated enum WorkspaceAccess: String, Codable, Sendable { case read, write }

/// 角色与实例在项目基础上的增减；workspace 为空时可写。
nonisolated struct ExecutionChanges: Codable, Equatable, Sendable {
    var workspace: WorkspaceAccess?
    var add = ExecutionScope()
    var remove = ExecutionScope()

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspace = try c.decodeIfPresent(WorkspaceAccess.self, forKey: .workspace)
        add = try c.decodeIfPresent(ExecutionScope.self, forKey: .add) ?? ExecutionScope()
        remove = try c.decodeIfPresent(ExecutionScope.self, forKey: .remove) ?? ExecutionScope()
    }
}

/// 越出执行授权的请求怎么处理：仅白名单直接拒绝，越界询问停下来问人，全放行自动允许。按严到宽排。
nonisolated enum ApprovalMode: String, Codable, CaseIterable, Sendable {
    case allowlist, ask
    case allowAll = "allow_all"

    var title: String {
        switch self {
        case .allowlist: "仅白名单"
        case .ask: "越界询问"
        case .allowAll: "全放行"
        }
    }
}

/// 项目的基础与边界：allow 是本项目所有代理的起点，deny 任何层和审批都打不开；工作区可定为只读，审批模式有上限。
nonisolated struct ProjectExecution: Codable, Equatable, Sendable {
    var workspace: WorkspaceAccess = .write
    var allow = ExecutionScope()
    var deny = ExecutionScope()
    var approval: ApprovalMode = .allowAll

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspace = try c.decodeIfPresent(WorkspaceAccess.self, forKey: .workspace) ?? .write
        allow = try c.decodeIfPresent(ExecutionScope.self, forKey: .allow) ?? ExecutionScope()
        deny = try c.decodeIfPresent(ExecutionScope.self, forKey: .deny) ?? ExecutionScope()
        approval = try c.decodeIfPresent(ApprovalMode.self, forKey: .approval) ?? .allowAll
    }
}

/// grants 是实例在项目上的增减，project 是项目的基础与边界。
nonisolated struct InstanceExecutionGrants: Decodable, Sendable {
    let revision: String
    let grants: ExecutionChanges
    let project: ProjectExecution
}

struct ExecutionGrantUpdate: Encodable {
    let expectedRevision: String
    let grants: ExecutionChanges
}

/// 实例的审批模式：mode 是实例的选择，effective 是按项目上限 max 收紧后实际用的。
nonisolated struct InstanceApprovalMode: Decodable, Sendable {
    let mode: ApprovalMode
    let effective: ApprovalMode
    let max: ApprovalMode
}

/// 每一项按「项目给的 + 实例加的 − 实例去掉的」整份编辑，保存时再拆回在项目上的增减。
/// 路径属于工作机；客户端只整理输入，实际位置与授权范围由工作机校验。
struct ExecutionGrantDraft: Equatable {
    let revision: String
    let project: ProjectExecution
    var workspace: WorkspaceAccess
    var scope = ExecutionScope()

    init(snapshot: InstanceExecutionGrants) {
        revision = snapshot.revision
        project = snapshot.project
        workspace = snapshot.grants.workspace ?? .write
        let changes = snapshot.grants
        for key in ExecutionScope.Key.allCases {
            var seen = Set<String>()
            scope[key] = (snapshot.project.allow[key] + changes.add[key]).filter { !changes.remove[key].contains($0) && seen.insert($0).inserted }
        }
    }

    var grants: ExecutionChanges {
        var changes = ExecutionChanges()
        changes.workspace = workspace
        for key in ExecutionScope.Key.allCases {
            changes.add[key] = scope[key].filter { !project.allow[key].contains($0) }
            changes.remove[key] = project.allow[key].filter { !scope[key].contains($0) }
        }
        return changes
    }
    var request: ExecutionGrantUpdate { .init(expectedRevision: revision, grants: grants) }
}
