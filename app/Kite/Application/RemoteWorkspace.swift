import Foundation

/// App 与工作机之间的协议号，与 kited/src/version.ts 的 PROTOCOL 一起改；不一致的工作机锁定为待更新（docs/App.md「版本」）。
enum KiteProtocol {
    static let version = 14
}

/// 工作机正在运行的版本（`/machine` 的 version）：build 标识一份运行文件，源码运行时为 dev。
struct MachineVersion: Codable, Equatable {
    let build: String
    let `protocol`: Int
    var builtAt: String?
    var commit: String?
}

/// 工作机的身份；version 只在实时读 `/machine` 时有，目录摘要里没有。
struct RemoteMachine: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let createdAt: Int
    var version: MachineVersion?
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

/// 项目在一台工作机上的检出：Kite 数据目录里的裸仓库，这台机器上该项目的工作区都从它开出。
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
    let branch: String?
    let base: String?
    let status: RemoteWorkspaceStatus
    let createdAt: Int
    /// 主线比工作区分支多出的提交数，按工作机最近一次拉取计算；还没算过、或较早的目录摘要里没有。
    var behind: Int? = nil
    /// 提交 PR 的工作区最近一次集成推到的分支与 PR。
    var pullRequest: WorkspacePullRequest? = nil
    /// 子工作区挂在哪个工作区下；顶层工作区与较早的目录摘要里没有。只能合回它或放弃，随它流转。
    var parentId: String? = nil
    /// 工作区目录顶层的文件和目录名，消息里的路径以它们开头才认（见 ReferenceScope）；只有打开的工作区有，目录摘要里没有。
    var rootNames: [String]? = nil
}

/// 提交 PR 的工作区的 PR：url 是 PR 页面，不能自动开 PR 的平台是去开 PR 的网页、没有 number。
struct WorkspacePullRequest: Codable, Equatable {
    let branch: String
    let url: String
    var number: Int? = nil
    /// open、merged 或 closed，随工作机的项目同步更新。
    let state: String
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
    /// 回合卡在审批（approval）、提问（question）或密钥请求（secret）上等人回应。
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
        var preview: PreviewStatus? = nil
        /// 浏览选的网页：本工作区的端口或互联网网址，见 FileSelection。
        var port: Int? = nil
        var url: String? = nil
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

extension RemotePluginInstance.State {
    /// 本机先建的浏览实例：打开到这个网页。
    init(page: BrowsePage) {
        self.init(path: nil, revision: nil)
        switch page {
        case .port(let port): self.port = port
        case .url(let url): self.url = url.absoluteString
        }
    }
}

/// 终端与预览实例的进程状态，kited 的 terminal/terminals.ts 写在实例状态里；结束时带退出码或信号，不是自己退出的带原因。
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

    var running: Bool { phase == "running" }
    /// 结束后的副行：原因优先，其次退出码或信号。
    var summary: String {
        if let reason { return reason }
        if let signal { return "已结束 · \(signal)" }
        return exitCode.map { "已退出 · 退出码 \($0)" } ?? "已结束"
    }
}

/// 预览的画面，kited 的 preview/state.ts 写在实例状态里，各设备共用：种类由进程产生什么决定，网页带主端口，App 窗口带 App 的路径；
/// browser 是网页在哪看。
struct PreviewStatus: Decodable, Equatable {
    var screen: PreviewScreen = .none
    var port: Int? = nil
    /// 工作机上的浏览器；没有是 device，设备自己的网页视图。
    var browser: PreviewBrowser? = nil
    var app: String? = nil

    var choice: PreviewBrowser { browser ?? .device }
}

/// 预览画面的种类：进程树里开着窗口的 Mac App、目标用的模拟器、能用 HTTP 打开的端口，都没有是 none（只有输出）。
enum PreviewScreen: String, Decodable {
    case app, simulator, web, none
    init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .none }
}

/// 网页在哪看：设备自己的网页视图，或工作机上的浏览器（画面传过来）。
enum PreviewBrowser: String, CaseIterable, Identifiable, Codable {
    case device, webkit, chromium, firefox, safari
    var id: String { rawValue }
    var title: String {
        switch self {
        case .device: "本设备"
        case .webkit: "WebKit"
        case .chromium: "Chromium"
        case .firefox: "Firefox"
        case .safari: "Safari"
        }
    }
}

/// 浏览实例共用的选择：一个文件（可带历史差异），或一个网页（port、url 二选一），都没有时 path 为 nil。
struct FileSelection: Decodable, Equatable {
    let path: String?
    let revision: String
    var diffId: String? = nil
    var port: Int? = nil
    var url: String? = nil

    var page: BrowsePage? {
        if let port { return .port(port) }
        return url.flatMap(URL.init(string:)).map(BrowsePage.url)
    }
}

/// 浏览看的网页：本工作区运行中终端或预览监听的端口（路径、前进后退只在本设备），或互联网上的一个网址。
enum BrowsePage: Equatable {
    case port(Int)
    case url(URL)
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

    /// 默认视图的渲染方式：这类实例的窗口由哪种正文显示、什么外观，不随窗口当前的视图换。
    var defaultRenderer: String? { views.first { $0.id == defaultView }?.renderer }
}

/// 所有窗口统一引用实例和已声明的视图。
struct WindowTarget: Codable {
    let instanceId: String
    let viewId: String
}

struct RemoteWorkspaceWindow: Decodable, Identifiable {
    let id: String
    let workspaceId: String
    let target: WindowTarget
    let state: RemoteWindowState
    let createdAt: Int

    /// 同一个窗口换到实例的另一个视图。
    func showing(_ viewId: String) -> RemoteWorkspaceWindow {
        RemoteWorkspaceWindow(id: id, workspaceId: workspaceId, target: WindowTarget(instanceId: target.instanceId, viewId: viewId),
                              state: state, createdAt: createdAt)
    }
}

/// 预览装到哪台设备：工作区的这个型号的模拟器，或与工作机配对过的真机（编号），kited 的 preview/devices.ts。
nonisolated enum PreviewDevice: Codable, Equatable, Hashable, Sendable {
    case simulator(String)
    case physical(String)

    private enum Keys: String, CodingKey { case simulator, physical }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let model = try c.decodeIfPresent(String.self, forKey: .simulator) { self = .simulator(model) }
        else { self = .physical(try c.decode(String.self, forKey: .physical)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .simulator(let model): try c.encode(model, forKey: .simulator)
        case .physical(let id): try c.encode(id, forKey: .physical)
        }
    }
}

/// 新建预览：跑哪个目标、装到哪台设备（kited 的 preview/state.ts），建好不变。
nonisolated struct PreviewSpec: Codable, Equatable, Sendable {
    let target: String
    var device: PreviewDevice? = nil
}

/// 新建窗口里的设备候选：模拟器型号，或配对过的真机（名字、硬件型号、连没连着）。
struct DeviceCandidate: Decodable, Identifiable, Hashable {
    enum Kind: String, Decodable { case simulator, physical }
    let kind: Kind
    let model: String
    var family: String? = nil
    var id: String { kind == .physical ? physicalID ?? model : "simulator \(model)" }
    /// 真机的编号与名字。
    var physicalID: String? = nil
    var name: String? = nil
    var marketingName: String? = nil
    var connected: Bool? = nil

    private enum CodingKeys: String, CodingKey { case kind, model, family, physicalID = "id", name, marketingName, connected }

    var device: PreviewDevice { kind == .physical ? .physical(physicalID ?? "") : .simulator(model) }
    var title: String { kind == .physical ? name ?? model : model }
}

/// 新建窗口里列的预览目标与设备候选（kited 的 GET /workspaces/:id/preview-targets）。
struct PreviewTargets: Decodable {
    let targets: [String]
    let devices: [DeviceCandidate]
}

struct OpenWindowRequest: Encodable {
    let id: String
    let content: Content

    /// 新建实例的 ID 也由本机定：本机先按它建好实例和窗口（见 AppModel.sendWindowRequest）。
    /// title 省略时按插件名编号；command 只用于终端，等 shell 起好后打进去执行。preview 只用于预览，必带：
    /// 同一目标与设备已经在跑时工作机打开那个实例。page 只用于浏览，打开到一个网页。
    enum Content: Encodable {
        case create(String, instance: String, title: String? = nil, command: String? = nil, preview: PreviewSpec? = nil, page: BrowsePage? = nil)
        case open(WindowTarget)
        private enum Keys: String, CodingKey { case kind, definitionId, instanceId, title, command, preview, page, viewId }
        private struct Page: Encodable { var port: Int? = nil; var url: URL? = nil }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .create(let definitionId, let instanceId, let title, let command, let preview, let page):
                try c.encode("create", forKey: .kind)
                try c.encode(definitionId, forKey: .definitionId)
                try c.encode(instanceId, forKey: .instanceId)
                try c.encodeIfPresent(title, forKey: .title)
                try c.encodeIfPresent(command, forKey: .command)
                try c.encodeIfPresent(preview, forKey: .preview)
                switch page {
                case .port(let port): try c.encode(Page(port: port), forKey: .page)
                case .url(let url): try c.encode(Page(url: url), forKey: .page)
                case nil: break
                }
            case .open(let target):
                try c.encode("open", forKey: .kind)
                try c.encode(target.instanceId, forKey: .instanceId)
                try c.encode(target.viewId, forKey: .viewId)
            }
        }
    }
}
