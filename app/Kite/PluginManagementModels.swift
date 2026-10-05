import Foundation

nonisolated enum PluginLifetime: String, Decodable, Sendable {
    case window, persistent

    var title: String { self == .window ? "随窗口回收" : "独立存续" }
    var explanation: String {
        self == .window ? "关闭最后一个窗口时，结束运行并回收实例和状态。" : "关闭窗口后保留实例和数据，可在侧栏重新打开。"
    }
}

/// 管理端只编辑授权选择；调用身份、声明与执行校验由工作机负责。
nonisolated struct OperationGrant: Codable, Equatable, Sendable {
    nonisolated struct Targets: Codable, Equatable, Sendable {
        let kind: String
        var instanceIds: [String]? = nil
    }
    let operation: String
    var definitionIds: [String]? = nil
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

    func includesDefinition(_ id: String) -> Bool {
        grants.contains { $0.operation == "agent.start" && ($0.definitionIds?.contains(id) ?? false) }
    }

    mutating func setDefinition(_ id: String, enabled: Bool) {
        var ids = Set(grants.filter { $0.operation == "agent.start" }.flatMap { $0.definitionIds ?? [] })
        if enabled { ids.insert(id) } else { ids.remove(id) }
        grants.removeAll { $0.operation == "agent.start" }
        if !ids.isEmpty { grants.append(OperationGrant(operation: "agent.start", definitionIds: ids.sorted())) }
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

nonisolated struct ExecutionGrants: Codable, Equatable, Sendable {
    nonisolated enum WorkspaceAccess: String, Codable, Sendable { case read, write }
    var workspace: WorkspaceAccess
    var read: [String]
    var write: [String]
    var network: [String]
}

nonisolated struct InstanceExecutionGrants: Decodable, Sendable {
    let revision: String
    let grants: ExecutionGrants
}

struct ExecutionGrantUpdate: Encodable {
    let expectedRevision: String
    let grants: ExecutionGrants
}

/// 路径属于工作机；客户端只整理输入，实际位置与授权范围由工作机校验。
struct ExecutionGrantDraft {
    let revision: String
    var workspace: ExecutionGrants.WorkspaceAccess
    var readPaths: String
    var writePaths: String
    var networkDomains: String

    init(snapshot: InstanceExecutionGrants) {
        revision = snapshot.revision
        workspace = snapshot.grants.workspace
        readPaths = snapshot.grants.read.joined(separator: "\n")
        writePaths = snapshot.grants.write.joined(separator: "\n")
        networkDomains = snapshot.grants.network.joined(separator: "\n")
    }

    var grants: ExecutionGrants {
        .init(workspace: workspace, read: lines(readPaths), write: lines(writePaths), network: lines(networkDomains))
    }
    var request: ExecutionGrantUpdate { .init(expectedRevision: revision, grants: grants) }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
