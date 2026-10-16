import Foundation

struct RemoteMachine: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let createdAt: Int
}

enum RemoteWorkspaceKind: String, Codable {
    case root, worktree
}

/// handingOff：正在交给另一台工作机，暂不接受新的执行；transferred：执行权已流转走，这一份是冻结的旧记录。
enum RemoteWorkspaceStatus: String, Codable {
    case preparing, open, failed, archived, transferred
    case handingOff = "handing_off"
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

/// 项目以远程仓库为身份；remote 是归一化地址（域名/owner/repo）。
struct RemoteProject: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    /// 归一化的远程地址；没有远程的项目为空，各工作机上的检出互为远程。
    let remote: String?
    let createdAt: Int
}

/// 工作机上的项目目录；同一检出可拥有根工作区和独立工作区。
struct RemoteCheckout: Codable, Identifiable {
    let id: String
    let projectId: String
    let machineId: String
    let path: String
    let remote: String?
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

struct WorkspaceInfo: Codable, Identifiable {
    let id: String
    /// 同一工作区 ID 在不同工作机上的记录以它区分新旧，每次接管加 1；托管目录里较早上报的快照没有。
    let epoch: Int?
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
    /// 工作机载入过显示投影的线程才有。
    var activity: ThreadActivity? = nil
}

/// 代理的活动摘要，停靠栏据此显示后台代理的状态；完整状态以线程流为准。
/// 时间是工作机的毫秒时间戳，settledAt 只在工作机实时看到回合收尾时记录。
struct ThreadActivity: Decodable, Equatable {
    let phase: String
    let waitingForResume: Bool
    /// 回合卡在审批（approval）或提问（question）上等人回应。
    var waiting: String? = nil
    var outcome: String? = nil
    var error: Bool? = nil
    var changedAt: Double? = nil
    var settledAt: Double? = nil
}

struct RemotePluginInstance: Decodable, Identifiable {
    struct State: Decodable {
        let path: String?
        let revision: String?
        var diffId: String? = nil
        var plugin: JSON? = nil
        var terminal: TerminalStatus? = nil
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
    /// 由另一个实例经 agent_start 创建时，工作机记下的创建来源。
    var origin: Origin? = nil

    struct Origin: Decodable { let instanceId: String }
}

/// 终端进程的状态，kited 的 terminal/terminals.ts 写在实例状态里；结束时带退出码或信号，不是自己退出的带原因。
struct TerminalStatus: Decodable, Equatable {
    /// 进程树正在监听的端口；http 是工作机试过能用 HTTP 打开。
    struct Port: Decodable, Equatable, Hashable {
        let port: Int
        let http: Bool
    }
    let phase: String
    var exitCode: Int? = nil
    var signal: String? = nil
    var reason: String? = nil
    /// 运行中才有，按端口号排。
    var ports: [Port]? = nil
    /// 网页视图选的端口，各设备共用。
    var port: Int? = nil

    var running: Bool { phase == "running" }
    /// 网页视图打开的端口：选过且还在监听的，否则第一个能响应 HTTP 的。
    var webPort: Int? {
        let ports = ports ?? []
        if let port, ports.contains(where: { $0.port == port }) { return port }
        return ports.first(where: \.http)?.port
    }
    /// 结束后的副行：原因优先，其次退出码或信号。
    var summary: String {
        if let reason { return reason }
        if let signal { return "已结束 · \(signal)" }
        return exitCode.map { "已退出 · 退出码 \($0)" } ?? "已结束"
    }
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
    /// 一句话的用途，只有内置定义有。
    var description: String? = nil
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

    /// 新建实例的 ID 也由本机定：本机先按它建好实例和窗口（见 AppModel.sendWindowRequest）。
    enum Content: Encodable {
        case create(String, instance: String)
        case open(WindowTarget)
        private enum Keys: String, CodingKey { case kind, definitionId, instanceId, viewId }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .create(let definitionId, let instanceId):
                try c.encode("create", forKey: .kind)
                try c.encode(definitionId, forKey: .definitionId)
                try c.encode(instanceId, forKey: .instanceId)
            case .open(let target):
                try c.encode("open", forKey: .kind)
                try c.encode(target.instanceId, forKey: .instanceId)
                try c.encode(target.viewId, forKey: .viewId)
            }
        }
    }
}
