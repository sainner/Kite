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
    var modelAccounts: ModelAccountsSnapshot?
    var modelAccountsError: String?
    var readingModelAccounts = false
    @ObservationIgnored var templatesRequest: (connection: UUID, task: Task<Void, Error>)?
    @ObservationIgnored var rolesRequest: (connection: UUID, task: Task<Void, Error>)?
    @ObservationIgnored var task: Task<Void, Never>?
    var id: String { machine.id }

    init(deviceID: String, machine: RemoteMachine, address: String) {
        self.deviceID = deviceID
        self.machine = machine
        client = KitedClient(address: address, machineID: machine.id)
    }
}

/// 设备的连接状态。侧栏的设备行、工作区行和窗口信息区共用同一套判断、文字、颜色与图标。
struct DeviceStatus {
    let ready: Bool
    let waiting: Bool

    /// 工作机以本机的连接为准，控制端没有连接，按账号目录的在线状态；目录里找不到的设备按离线处理。
    init(device: AccountDevice?, connection: WorkerConnection?) {
        ready = connection?.connected == true || (device.map { $0.role != "worker" && $0.online } ?? false)
        waiting = !ready && device?.online == true
    }

    var tint: Color { ready ? .accentColor : waiting ? Theme.warning : .secondary }
    var title: String { ready ? "在线" : waiting ? "等待连接" : "离线" }
    var symbol: String { ready ? "checkmark.circle.fill" : waiting ? "clock.fill" : "xmark.circle.fill" }
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
        let text = ["\(connection.machine.name) \(status.title)", connection.error].compactMap(\.self).joined(separator: "\n")
        return PaneNotice(text: text, symbol: status.symbol, tint: status.tint)
    }
}
