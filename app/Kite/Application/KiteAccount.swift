import Foundation
import Observation
import Security
#if os(iOS)
import UIKit
#endif

struct AccountUser: Codable { let id: String; let email: String; let name: String }
struct AccountDevice: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let role: String
    let kind: String?
    let online: Bool
    let joined: Bool
    let address: String?
}
struct AccountEnrollment: Codable {
    struct Device: Codable { let id: String; let name: String; let role: String }
    let device: Device
    let controlURL: String
    let authKey: String
}
private struct AccountLogin: Codable {
    let token: String
    let user: AccountUser
    var enrollment: AccountEnrollment?
    var ready = false

    enum CodingKeys: String, CodingKey { case token, user, enrollment, ready }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        user = try c.decode(AccountUser.self, forKey: .user)
        enrollment = try c.decodeIfPresent(AccountEnrollment.self, forKey: .enrollment)
        ready = try c.decodeIfPresent(Bool.self, forKey: .ready) ?? false
    }
}

/// 每次登录对应一个设备会话；凭据仅放本机钥匙串，不随项目或工作机同步。
@Observable final class KiteAccount {
    static let server = "https://hs.sainner.top"
    private let http = AccountHTTP.makeSession()
    private var login: AccountLogin?
    private(set) var devices: [AccountDevice] = []
    private(set) var catalogs: [HostedCatalog] = []
    private(set) var projectAppearances: [String: ProjectAppearance] = [:]
    private var appearanceRevision = 0
    private var reportedKindDeviceID: String?
    var error: String?
    var joining = false
    var signedIn: Bool { login != nil }
    var ready: Bool { login?.ready == true }
    var user: AccountUser? { login?.user }
    var deviceID: String? { login?.enrollment?.device.id }
    var role: String? { login?.enrollment?.device.role }
    var workers: [AccountDevice] { devices.filter { $0.role == "worker" && $0.joined } }

    static var localDeviceKind: String {
        #if os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: "phone"
        case .pad: "tablet"
        default: "unknown"
        }
        #else
        "computer"
        #endif
    }

    init() {
        login = AccountVault.load()
        if let user = login?.user {
            let directory = AccountDirectory.load(user.id)
            devices = directory.devices
            catalogs = directory.catalogs
            projectAppearances = directory.projectAppearances
        }
    }

    #if DEBUG
    /// 手动验收使用临时账号目录，不触及当前用户的钥匙串。
    init(verificationLogin: Data, directory: AccountDirectory) throws {
        login = try JSONDecoder().decode(AccountLogin.self, from: verificationLogin)
        devices = directory.devices
        catalogs = directory.catalogs
        projectAppearances = directory.projectAppearances
    }
    #endif

    func request<T: Decodable>(_ path: String, method: String = "GET", body: (any Encodable)? = nil,
                               timeout: TimeInterval = 25, as: T.Type) async throws -> T {
        let expectedToken = login?.token
        var request = URLRequest(url: URL(string: Self.server + path)!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = login?.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await http.data(for: request)
        try Task.checkCancellation()
        guard login?.token == expectedToken else { throw CancellationError() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if status == 401, !path.hasPrefix("/api/auth/") { clear() }
            let messages = ["INVALID_EMAIL_OR_PASSWORD": "邮箱或密码不正确", "USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL": "该邮箱已注册，请登录",
                            "PASSWORD_TOO_SHORT": "密码至少需要 10 个字符", "INVALID_EMAIL": "请输入有效的邮箱地址"]
            throw KitedError(message: messages[value?["code"] as? String ?? ""] ?? (value?["error"] as? String) ?? (value?["message"] as? String) ?? "账号服务暂时不可用（\(status)）", status: status)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func signIn(email: String, password: String, register: Bool) async throws {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = try await request(register ? "/api/auth/sign-up/email" : "/api/auth/sign-in/email", method: "POST",
                                      body: ["email": email, "password": password, "name": String(email.split(separator: "@").first ?? "Kite")], as: AccountLogin.self)
        try AccountVault.save(value)
        login = value
        error = nil
    }

    #if os(iOS)
    func accept(_ url: URL) async throws {
        guard !signedIn, url.scheme == "kite", url.host() == "join",
              let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token" })?.value else {
            throw KitedError(message: "请在未登录的设备上扫描 Kite 登录二维码")
        }
        let value = try await request("/api/invitations/accept", method: "POST", body: ["token": token], as: AccountLogin.self)
        try AccountVault.save(value)
        login = value
    }
    #endif

    func invitation() async throws -> URL {
        struct Invitation: Decodable { let token: String }
        let value = try await request("/api/invitations", method: "POST", as: Invitation.self)
        var url = URLComponents(string: "kite://join")!
        url.queryItems = [URLQueryItem(name: "token", value: value.token)]
        return url.url!
    }

    func join(role: String, name: String) async throws {
        guard !joining, login != nil else { return }
        joining = true
        defer { joining = false }
        if login?.enrollment == nil {
            let enrollment = try await request("/api/devices/enroll", method: "POST", body: ["name": name, "role": role, "kind": Self.localDeviceKind], as: AccountEnrollment.self)
            login?.enrollment = enrollment
            try save()
        }
        guard let enrollment = login?.enrollment else { return }
        let ip = try await startNetwork(enrollment)
        // 入网地址由控制服务核验节点归属与一次性密钥，不能只相信客户端报告。
        let _: AccountDevice = try await request("/api/devices/\(enrollment.device.id)/complete", method: "POST", body: ["ip": ip], as: AccountDevice.self)
        login?.ready = true
        try save()
        try await refresh()
    }

    private func startNetwork(_ enrollment: AccountEnrollment) async throws -> String {
        #if os(macOS)
        if enrollment.device.role == "worker" {
            try await LocalService.installAndStart()
            let machine = try await KitedClient(address: "http://127.0.0.1:5483").request("/machine", as: RemoteMachine.self)
            let client = KitedClient(address: "http://127.0.0.1:5483", machineID: machine.id)
            struct Join: Encodable { let deviceId: String; let controlURL: String; let authKey: String }
            let _: LocalNetwork = try await client.request("/network/account", method: "PUT", body: Join(deviceId: enrollment.device.id, controlURL: enrollment.controlURL, authKey: enrollment.authKey), as: LocalNetwork.self)
            for _ in 0..<90 {
                try Task.checkCancellation()
                let status = try await client.request("/network", as: LocalNetwork.self)
                if status.state == "Running", let port = status.socksPort, let ip = status.ips?.first(where: { !$0.contains(":") }) {
                    await Tailnet.shared.useWorker(port: port)
                    return ip
                }
                if status.state == "Stopped", let error = status.error { throw KitedError(message: error) }
                try await Task.sleep(for: .seconds(1))
            }
            throw KitedError(message: "入网超时，请重试")
        }
        #endif
        await Tailnet.shared.configure(controlURL: enrollment.controlURL, authKey: enrollment.authKey, deviceID: enrollment.device.id)
        return try await Tailnet.shared.address()
    }

    /// 控制端用本机保存的入网信息配置组网，无需等账号核验。作为工作机的 Mac 复用 kited 的节点，见 resume。
    func configureNetwork() async {
        guard ready, let device = login?.enrollment?.device, let controlURL = login?.enrollment?.controlURL else { return }
        #if os(macOS)
        if device.role == "worker" { return }
        #endif
        await Tailnet.shared.configure(controlURL: controlURL, deviceID: device.id)
    }

    func resume() async throws {
        guard ready, let enrollment = login?.enrollment else { return }
        // 控制端的组网与账号核验同时进行：已移除设备的节点已从 Headscale 删除，无法上线；
        // 核验返回 401 时清空登录，界面随之关闭网络。
        await configureNetwork()
        var network: Task<URLSession, Error>?
        #if os(macOS)
        if enrollment.device.role != "worker" { network = Task { try await Tailnet.shared.urlSession() } }
        #else
        network = Task { try await Tailnet.shared.urlSession() }
        #endif
        let session = TimingTrace.span("组网会话")
        let verified = TimingTrace.span("账号核验")
        await reportDeviceKind()
        do { try await refresh(); verified("完成") }
        catch {
            verified("失败：\(error.localizedDescription)")
            if !signedIn || error is CancellationError { throw error }
            self.error = error.localizedDescription
        }
        #if os(macOS)
        if enrollment.device.role == "worker" {
            try await LocalService.installAndStart()
            let machine = try await KitedClient(address: "http://127.0.0.1:5483").request("/machine", as: RemoteMachine.self)
            let network = try await KitedClient(address: "http://127.0.0.1:5483", machineID: machine.id).request("/network", as: LocalNetwork.self)
            guard network.state == "Running", let port = network.socksPort else { throw KitedError(message: "本机 kited 尚未入网") }
            await Tailnet.shared.useWorker(port: port)
            do { try await configurePublisher(enrollment, machine: machine) }
            catch {
                if !signedIn || error is CancellationError { throw error }
                self.error = error.localizedDescription
            }
            return
        }
        #endif
        _ = try await network?.value
        session("就绪")
    }

    /// 类型补报独立于目录读取；服务暂不可达时下一轮重试。
    private func reportDeviceKind() async {
        guard let id = deviceID, reportedKindDeviceID != id else { return }
        do {
            let _: JSON = try await request("/api/devices/\(id)", method: "PATCH", body: ["kind": Self.localDeviceKind], as: JSON.self)
            if deviceID == id { reportedKindDeviceID = id }
        } catch { /* 保留未知类型，等待下次连接补报。 */ }
    }

    func refresh() async throws {
        let expectedToken = login?.token
        let revision = appearanceRevision
        async let devices = request("/api/devices", as: [AccountDevice].self)
        async let catalogs = request("/api/catalog", as: [HostedCatalog].self)
        async let projects = request("/api/projects", as: [ProjectStyle].self)
        var directory = try await AccountDirectory(devices: devices, catalogs: catalogs,
                                                   projectAppearances: Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.appearance) }))
        guard expectedToken == login?.token else { throw CancellationError() }
        self.devices = directory.devices
        self.catalogs = directory.catalogs
        // 更换外观期间发出的旧目录请求不能把刚保存的选择覆盖掉。
        if revision == appearanceRevision { projectAppearances = directory.projectAppearances }
        else { directory.projectAppearances = projectAppearances }
        if let user { try directory.save(user.id) }
        error = nil
    }

    private struct ProjectStyle: Decodable {
        let id: String
        let icon: String?
        let color: String?

        var appearance: ProjectAppearance {
            var value = ProjectAppearance()
            if let icon { value.icon = icon }
            if let color { value.color = color }
            return value
        }
    }

    func setProjectAppearance(_ values: [String: String], projectID: String) async throws {
        let project = try await request("/api/projects/\(projectID)/appearance", method: "PUT", body: values, as: ProjectStyle.self)
        projectAppearances[project.id] = project.appearance
        appearanceRevision += 1
        if let user { try AccountDirectory(devices: devices, catalogs: catalogs, projectAppearances: projectAppearances).save(user.id) }
    }

    #if os(macOS)
    private func configurePublisher(_ enrollment: AccountEnrollment, machine: RemoteMachine) async throws {
        let client = KitedClient(address: "http://127.0.0.1:5483", machineID: machine.id)
        struct Status: Decodable { let deviceId: String?; let needsAuthorization: Bool? }
        let status = try await client.request("/catalog/account", as: Status.self)
        guard status.deviceId != enrollment.device.id || status.needsAuthorization == true else { return }
        struct Publisher: Codable { let deviceId: String; let url: String; let token: String }
        let publisher = try await request("/api/devices/\(enrollment.device.id)/catalog-publisher", method: "POST",
                                          body: ["machineId": machine.id], as: Publisher.self)
        let _: Status = try await client.request("/catalog/account", method: "PUT", body: publisher, as: Status.self)
    }
    #endif

    /// 本机到各对端的连接方式，按组网 IPv4 索引。作为工作机的 Mac 与 kited 共用节点，从 kited 读取。
    func peerConnections() async -> [String: PeerConnection] {
        #if os(macOS)
        if role == "worker" {
            guard let machine = try? await KitedClient(address: "http://127.0.0.1:5483").request("/machine", as: RemoteMachine.self),
                  let network = try? await KitedClient(address: "http://127.0.0.1:5483", machineID: machine.id).request("/network", as: LocalNetwork.self)
            else { return [:] }
            return Dictionary((network.peers ?? []).compactMap { peer in peer.ip.map { ($0, PeerConnection(connection: peer.connection, endpoint: peer.endpoint)) } },
                              uniquingKeysWith: { first, _ in first })
        }
        #endif
        return await Tailnet.shared.peers()
    }

    func remove(_ id: String) async throws {
        let _: JSON = try await request("/api/devices/\(id)", method: "DELETE", as: JSON.self)
        if id == deviceID { clear(); await Tailnet.shared.stop() }
        else { try await refresh() }
    }

    func signOut() async throws {
        if let id = deviceID { try await remove(id) }
        else {
            let _: JSON = try await request("/api/auth/sign-out", method: "POST", as: JSON.self)
            clear()
        }
    }

    private func save() throws { if let login { try AccountVault.save(login) } }
    private func clear() {
        if let user { AccountDirectory.clear(user.id) }
        login = nil; devices = []; catalogs = []; projectAppearances = [:]; appearanceRevision += 1; AccountVault.clear()
    }
}

private struct LocalNetwork: Decodable {
    struct Peer: Decodable { let ip: String?; let connection: String; let endpoint: String? }
    let state: String
    let ips: [String]?
    let socksPort: Int?
    let peers: [Peer]?
    let error: String?
}

private enum AccountVault {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Kite 账号", kSecAttrAccount as String: "session"]
    static func load() -> AccountLogin? {
        var query = query
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AccountLogin.self, from: data)
    }
    static func save(_ login: AccountLogin) throws {
        let data = try JSONEncoder().encode(login)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KitedError(message: "无法保存 Kite 登录（\(updated)）") }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KitedError(message: "无法保存 Kite 登录（\(status)）") }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

#if os(macOS)
enum LocalService {
    static func installAndStart() async throws {
        guard let resource = Bundle.main.resourceURL?.appending(path: "Service/runtime"),
              FileManager.default.isExecutableFile(atPath: resource.appending(path: "bin/bun").path) else {
            throw KitedError(message: "此 App 未包含 kited，请使用完整的 Kite 安装包")
        }
        let installed = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Kite/runtime/manifest.json")
        if let current = try? Data(contentsOf: installed), current == (try? Data(contentsOf: resource.appending(path: "manifest.json"))),
           (try? await KitedClient(address: "http://127.0.0.1:5483").request("/machine", as: RemoteMachine.self)) != nil { return }
        let process = Process()
        process.executableURL = resource.appending(path: "bin/bun")
        process.arguments = ["run", "--no-env-file", "--no-install", resource.appending(path: "kited/scripts/install-macos.ts").path, "install"]
        process.environment = ProcessInfo.processInfo.environment
        let log = FileManager.default.temporaryDirectory.appending(path: "kite-install-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close(); try? FileManager.default.removeItem(at: log) }
        process.standardOutput = output
        process.standardError = output
        let code: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard code == 0 else { throw KitedError(message: (try? String(contentsOf: log, encoding: .utf8)) ?? "安装 kited 失败") }
    }
}
#endif
