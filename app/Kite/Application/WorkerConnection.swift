import Foundation
import Observation

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
    @ObservationIgnored var templatesRequest: (connection: UUID, task: Task<Void, Error>)?
    @ObservationIgnored var task: Task<Void, Never>?
    var id: String { machine.id }

    init(deviceID: String, machine: RemoteMachine, address: String) {
        self.deviceID = deviceID
        self.machine = machine
        client = KitedClient(address: address, machineID: machine.id)
    }
}
