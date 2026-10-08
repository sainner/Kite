import Foundation

// ACCOUNT_DEVICE
// PROJECT_APPEARANCE

// 网络与存储是替身；原生解码、默认外观及 refresh 状态交接来自 App。
struct HostedCatalog: Decodable { let machineId: String }
struct AccountDirectory {
    var devices: [AccountDevice]
    var catalogs: [HostedCatalog]
    var projectAppearances: [String: ProjectAppearance]
    func save(_ userID: String) throws { fatalError("验证不应写入真实账号目录") }
}

@MainActor final class KiteAccount {
    private struct Login { let token: String }
    private struct User { let id: String }
    private var login: Login?
    private var user: User?
    private var appearanceRevision = 0
    var devices: [AccountDevice] = []
    var catalogs: [HostedCatalog] = []
    var projectAppearances: [String: ProjectAppearance] = [:]
    var error: String? = "上次目录读取失败"
    var requested: Set<String> = []

    func request<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let responses = [
            "/api/devices": #"[{"id":"worker","name":"工作机","role":"worker","online":true,"joined":true,"address":"http://127.0.0.1:5483"}]"#,
            "/api/catalog": #"[{"machineId":"machine"}]"#,
            "/api/projects": #"[{"id":"plain","name":"无外观字段","remote":"github.com/test/plain","url":"https://github.com/test/plain.git","hosted":false,"createdAt":1},{"id":"styled","name":"自定义外观","remote":"github.com/test/styled","url":"https://github.com/test/styled.git","hosted":false,"createdAt":2,"icon":"terminal","color":"green"}]"#,
        ]
        guard let response = responses[path] else { fatalError("未知账号请求：\(path)") }
        requested.insert(path)
        return try JSONDecoder().decode(type, from: Data(response.utf8))
    }

    // PROJECT_STYLE
    // ACCOUNT_REFRESH
}

private func require(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}

@main struct AccountProjectStyleVerify {
    @MainActor static func main() async throws {
        let account = KiteAccount()
        try await account.refresh()
        require(account.requested == ["/api/devices", "/api/catalog", "/api/projects"], "未完成三个目录请求")
        require(account.devices.map(\.id) == ["worker"] && account.catalogs.map(\.machineId) == ["machine"],
                "缺少项目外观字段阻止了设备或目录刷新")
        require(account.projectAppearances.count == 2, "刷新丢失了项目外观记录")
        require(account.projectAppearances["plain"]?.icon == "folder" && account.projectAppearances["plain"]?.color == "primary",
                "缺少项目外观字段时没有使用默认外观")
        require(account.projectAppearances["styled"]?.icon == "terminal" && account.projectAppearances["styled"]?.color == "green",
                "已有项目外观被默认值覆盖")
        require(account.error == nil, "刷新成功后仍残留读取错误")
        print("账号目录刷新合同通过：缺少项目外观字段仍可刷新，默认外观与自定义值均保留")
    }
}
