import Foundation

struct CatalogSnapshot: Codable {
    let machine: RemoteMachine
    let projects: [RemoteProject]
    let checkouts: [RemoteCheckout]
    let workspaces: [WorkspaceInfo]

    /// 离线目录没有窗口与会话内容；连接所属工作机后才装载这些内容。
    var summaries: [RemoteWorkspace] {
        workspaces.compactMap { workspace in
            guard let checkout = checkouts.first(where: { $0.id == workspace.checkoutId }),
                  let project = projects.first(where: { $0.id == checkout.projectId }) else { return nil }
            return RemoteWorkspace(machine: machine, project: project, checkout: checkout, workspace: workspace,
                                   threads: [], instances: [], windows: [])
        }
    }
}

/// 工作机目录里的一台（kited 的 `GET /machines`）：最近一次的摘要随工作机之间的同步传开。
struct DirectoryMachine: Decodable {
    let id: String
    let name: String
    let online: Bool
    let address: String?
    let updatedAt: Int?
    let snapshot: CatalogSnapshot?
}

/// 一台工作机最近一次的目录摘要，对上了组网里的设备。
struct HostedCatalog: Codable {
    let device: AccountDevice
    let machineId: String
    let updatedAt: Int?
    let snapshot: CatalogSnapshot
}

struct ProjectAppearance: Codable, Equatable {
    var icon = "folder"
    var color = "primary"
}

/// 账号各自缓存导航目录，不包含文件、会话正文或登录凭据。
struct AccountDirectory: Codable {
    var devices: [AccountDevice] = []
    var catalogs: [HostedCatalog] = []
    var projectAppearances: [String: ProjectAppearance] = [:]

    private static func file(_ user: String) -> URL {
        URL.applicationSupportDirectory.appending(path: "Kite/目录/\(Data(user.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_" )).json")
    }
    static func load(_ user: String) -> Self {
        guard let data = try? Data(contentsOf: file(user)), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(_ user: String) throws {
        let url = Self.file(user)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
    static func clear(_ user: String) { try? FileManager.default.removeItem(at: file(user)) }
}
