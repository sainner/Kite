import Observation
import SwiftUI

/// 每台工作机独立维护连接、目录游标和本机配置，切换工作区不重建其他机器的状态。
@Observable final class WorkerConnection: Identifiable {
    let deviceID: String
    let machine: RemoteMachine
    var client: KitedClient
    var connected = false
    var error: String?
    var updatedAt: Int?
    var hasLiveCatalog = false
    let catalog = CatalogRefresh()
    var definitions: [RemotePluginDefinition] = []
    var definitionsRequest = UUID()
    var templates: ContextTemplateCatalog?
    var roles: RoleCatalog?
    var skills: SkillCatalog?
    /// 打开过的 skill 的整包，按名字；列表只有名字与版本，见 AppModel.loadSkillPackage。
    var skillPackages: [String: LibrarySkill] = [:]
    var modelAccounts: ModelAccountsSnapshot?
    var modelAccountsError: String?
    var readingModelAccounts = false
    /// 连接前实时读到的版本；协议号与 App 不同时 outdated 说明哪边旧了，这台锁定为待更新（docs/App.md「版本」）。
    var version: MachineVersion?
    var outdated: VersionMismatch?
    /// 工作机推 update.changed 时加一，版本页据此重新读 /update。
    var updateRevision = 0
    /// 工作机推 mcp.changed 时加一，MCP 页与代理的服务开关据此重新读 /mcp；清单本身变了时 mcpCatalogRevision 也加一。
    var mcpRevision = 0
    var mcpCatalogRevision = 0
    /// 进行中的目录读取，按请求路径，见 AppModel.refreshCatalog。
    @ObservationIgnored var catalogRequests: [String: (connection: UUID, task: Task<Void, Error>)] = [:]
    @ObservationIgnored var task: Task<Void, Never>?
    var id: String { machine.id }

    init(deviceID: String, machine: RemoteMachine, address: String) {
        self.deviceID = deviceID
        self.machine = machine
        client = KitedClient(address: address, machineID: machine.id)
    }
}

/// App 与工作机的协议号不同：哪边旧了。协议号只增不减，工作机更高说明 App 旧了。
enum VersionMismatch: Equatable {
    case app, machine

    /// 协议号相同时为 nil；没带版本的工作机早于版本号，按工作机旧了处理。
    init?(_ version: MachineVersion?) {
        let remote = version?.protocol ?? 0
        guard remote != KiteProtocol.version else { return nil }
        self = remote > KiteProtocol.version ? .app : .machine
    }

    var detail: String {
        switch self {
        case .app: "这台工作机的 Kite 比这个 App 新，更新 App 后才能连接"
        case .machine: "这台工作机的 Kite 比这个 App 旧，等它自动更新，或在那台工作机上重新安装"
        }
    }
}

/// 设备的连接状态。侧栏的设备行、工作区行和窗口信息区共用同一套判断、文字、颜色与图标。
struct DeviceStatus {
    let ready: Bool
    let waiting: Bool
    /// 协议号与 App 不同，锁定为待更新。
    let outdated: Bool

    /// 工作机以本机的连接为准，控制端没有连接，按工作机目录的在线状态；目录里找不到的设备按离线处理。
    init(device: AccountDevice?, connection: WorkerConnection?) {
        ready = connection?.connected == true || (device.map { $0.role != "worker" && $0.online } ?? false)
        outdated = !ready && connection?.outdated != nil
        waiting = !ready && !outdated && device?.online == true
    }

    var tint: Color { ready ? .accentColor : outdated || waiting ? Theme.warning : .secondary }
    var title: String { ready ? "在线" : outdated ? "待更新" : waiting ? "等待连接" : "离线" }
    var symbol: String { ready ? "checkmark.circle.fill" : outdated ? "arrow.down.circle.fill" : waiting ? "clock.fill" : "xmark.circle.fill" }
}

extension AppModel {
    func deviceStatus(_ connection: WorkerConnection?) -> DeviceStatus {
        DeviceStatus(device: connection.flatMap { connection in account.devices.first { $0.id == connection.deviceID } },
                     connection: connection)
    }

    /// 所属工作机没连上时窗口信息区的提示，比窗口自己的提示更优先；连接错误跟在说明里。
    func connectionNotice(_ connection: WorkerConnection?) -> PaneNotice? {
        guard let connection else { return nil }
        let status = deviceStatus(connection)
        guard !status.ready else { return nil }
        let text = ["\(connection.machine.name) \(status.title)", connection.outdated?.detail ?? connection.error].compactMap(\.self).joined(separator: "\n")
        return PaneNotice(text: text, symbol: status.symbol, tint: status.tint)
    }
}
