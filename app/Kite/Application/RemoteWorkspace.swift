import Foundation

struct RemoteMachine: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let createdAt: Int
}

enum RemoteCommitOwner: String, Decodable {
    case kite, user
}

enum RemoteWorkspaceKind: String, Decodable {
    case root, worktree
}

enum RemoteWorkspaceStatus: String, Decodable {
    case preparing, open, failed, archived
}

enum RemoteRuntime: String, Decodable {
    case claude, harness
}

enum RemotePresentation: String, Decodable {
    case window, inline, background
}

enum RemoteInstanceStatus: String, Decodable {
    case open, archived
}

enum RemoteWindowState: String, Decodable {
    case open, closed
}

struct RemoteProject: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let createdAt: Int
}

/// 工作机上的项目目录；同一检出可拥有根工作区和独立工作区。
struct RemoteCheckout: Decodable, Identifiable {
    let id: String
    let projectId: String
    let machineId: String
    let path: String
    let commits: RemoteCommitOwner
    let createdAt: Int
}

struct RemoteWorkspace: Decodable, Identifiable {
    let machine: RemoteMachine
    let project: RemoteProject
    let checkout: RemoteCheckout
    let workspace: WorkspaceInfo
    let threads: [RemoteThread]
    let instances: [RemotePluginInstance]
    let windows: [RemoteWorkspaceWindow]

    var id: String { workspace.id }
}

struct WorkspaceInfo: Decodable, Identifiable {
    let id: String
    let checkoutId: String
    let name: String
    let cwd: String
    let kind: RemoteWorkspaceKind
    let branch: String?
    let base: String?
    let status: RemoteWorkspaceStatus
    let createdAt: Int
}

/// 会话只持有 agent 实例的专有字段。
struct RemoteThread: Decodable {
    let instanceId: String
    let runtime: RemoteRuntime
    let nativeId: String
}

struct RemotePluginInstance: Decodable, Identifiable {
    struct State: Decodable {
        let path: String?
        let revision: String?
        var diffId: String? = nil
        var plugin: JSON? = nil
    }
    let id: String
    let workspaceId: String
    let definitionId: String
    let title: String
    let status: RemoteInstanceStatus
    let presentation: RemotePresentation
    let createdAt: Int
    var state: State? = nil
    var config: InstanceAgentConfig? = nil
}

struct FileSelection: Decodable, Equatable {
    let path: String?
    let revision: String
    var diffId: String? = nil
}

struct FileDirectory: Decodable {
    struct Entry: Decodable, Identifiable {
        let name: String
        let path: String
        let kind: String
        var id: String { path }
    }
    let path: String
    let entries: [Entry]
    let total: Int
    let nextOffset: Int?
}

struct FilePage: Decodable {
    let path: String
    let text: String
    let offset: Int
    let totalLines: Int
    let nextOffset: Int?
    let version: String
}

struct RemotePluginDefinition: Decodable, Identifiable {
    struct PluginView: Decodable, Identifiable {
        let id: String
        let title: String
        let renderer: String
    }
    struct Agent: Decodable {
        let runtime: RemoteRuntime
        var model: AgentModelConfiguration? = nil
    }
    let id: String
    let title: String
    let lifetime: PluginLifetime
    let views: [PluginView]
    let defaultView: String
    let agent: Agent?
    var runtime: String? = nil
    var operations: [String] = []
}

/// 所有窗口统一引用实例和已声明的视图。
struct WindowTarget: Codable, Equatable {
    let instanceId: String
    let viewId: String
}

struct RemoteWorkspaceWindow: Decodable, Identifiable {
    let id: String
    let workspaceId: String
    let target: WindowTarget
    let state: RemoteWindowState
    let createdAt: Int
}

struct OpenWindowRequest: Encodable {
    let id: String
    let content: Content

    enum Content: Encodable {
        case create(String)
        case open(WindowTarget)
        private enum Keys: String, CodingKey { case kind, definitionId, instanceId, viewId }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .create(let definitionId):
                try c.encode("create", forKey: .kind)
                try c.encode(definitionId, forKey: .definitionId)
            case .open(let target):
                try c.encode("open", forKey: .kind)
                try c.encode(target.instanceId, forKey: .instanceId)
                try c.encode(target.viewId, forKey: .viewId)
            }
        }
    }
}
