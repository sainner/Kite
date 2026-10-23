import Foundation
import Observation

/// 登录的 Tailscale 用户；email 放登录名。
struct AccountUser: Codable, Equatable { let id: String; let email: String; let name: String }
/// 同一 Tailscale 用户名下的一台设备：读得到 /machine 的是工作机，其余是控制端。address 只有工作机有。
struct AccountDevice: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let role: String
    let online: Bool
    let address: String?
}

/// 这台设备的身份设置：用途、登录的用户与本机节点，存在本机。
private struct Identity: Codable {
    var role: String?
    var user: AccountUser?
    var deviceID: String?
}

/// 身份与设备：登录 Tailscale 即登录 Kite，没有单独的 Kite 账号与密码（docs/分布式架构.md「身份与设备」）。
/// 作为工作机的 Mac 复用 kited 的组网节点，在 kited 的 kite-net 上登录；其余设备由 App 内的节点登录。
/// 设备就是同一 Tailscale 用户名下的节点，读得到 /machine 的是工作机；撤销设备在 Tailscale 管理后台把它移出。
@Observable final class KiteAccount {
    static let adminURL = URL(string: "https://login.tailscale.com/admin/machines")!
    private static let identityKey = "Kite.identity"
    private var identity: Identity
    private(set) var devices: [AccountDevice] = []
    private(set) var catalogs: [HostedCatalog] = []
    private(set) var projectAppearances: [String: ProjectAppearance] = [:]
    /// 项目登记表，从连着的工作机读到的最近一份；只在内存里，还没有工作区的项目靠它列出。
    private(set) var registeredProjects: [AccountProject] = []
    private(set) var appearanceRevision = 0
    /// 正在登录时要在浏览器里打开的地址；界面据此打开登录页。
    private(set) var loginURL: URL?
    /// 组网地址是不是工作机，连续读不到 /machine 的次数，及最近一次读的时刻；读不到的过一阵再试。
    @ObservationIgnored private var probes: [String: (worker: Bool, failures: Int, at: Date)] = [:]
    /// 上次写盘的目录缓存。
    @ObservationIgnored private var savedDirectory: Data?
    /// 用户关掉了登录页，正在等的登录就此放弃。
    @ObservationIgnored private var joinCancelled = false
    var error: String?
    var joining = false
    var signedIn: Bool { identity.user != nil }
    var ready: Bool { identity.user != nil && identity.role != nil }
    var user: AccountUser? { identity.user }
    var deviceID: String? { identity.deviceID }
    var role: String? { identity.role }
    var workers: [AccountDevice] { devices.filter { $0.role == "worker" } }
    /// 每台设备的形状，见 DeviceMark。
    var deviceShapes: [String: String] { DeviceMark.shapes(for: devices.map(\.id)) }

    init() {
        identity = (UserDefaults.standard.data(forKey: Self.identityKey)).flatMap { try? JSONDecoder().decode(Identity.self, from: $0) } ?? Identity()
        if let user = identity.user {
            let directory = AccountDirectory.load(user.id)
            devices = directory.devices
            catalogs = directory.catalogs
            projectAppearances = directory.projectAppearances
        }
    }

    #if DEBUG
    /// 手动验收使用临时目录，不触及当前设备的身份设置。
    init(verificationLogin: Data, directory: AccountDirectory) throws {
        struct Login: Decodable { let user: AccountUser }
        identity = Identity(role: "controller", user: try JSONDecoder().decode(Login.self, from: verificationLogin).user, deviceID: nil)
        devices = directory.devices
        catalogs = directory.catalogs
        projectAppearances = directory.projectAppearances
    }
    #endif

    /// 登录 Tailscale，让这台设备上线：作为工作机的 Mac 先装好 kited，由它的节点登录；其余设备由 App 的节点登录。
    /// 登录地址出现后放进 loginURL，界面打开登录页；等用户在浏览器里登录完成，最多等十分钟。
    func join(role: String) async throws {
        guard !joining else { return }
        joining = true
        joinCancelled = false
        error = nil
        defer { joining = false; loginURL = nil }
        #if os(macOS)
        if role == "worker" {
            try await LocalService.installAndStart()
            let _: NetworkState = try await Self.localClient().request("/network", method: "PUT", body: ["enabled": true], as: NetworkState.self)
        }
        #endif
        if role != "worker" { await Tailnet.shared.enable() }
        let deadline = Date().addingTimeInterval(600)
        var loginRequested: Date?
        while Date() < deadline {
            try checkJoin()
            let node = try await nodeState(role: role)
            if node.running, let user = node.user {
                try finish(role: role, user: user, deviceID: node.id)
                return
            }
            if let error = node.error { throw KitedError(message: error) }
            // App 的节点运行中登录失效时不会自己给出登录地址，主动发起；kited 的节点由 kite-net 发起。
            if role != "worker", node.needsLogin, node.loginURL == nil, loginRequested.map({ Date().timeIntervalSince($0) > 15 }) ?? true {
                loginRequested = Date()
                await Tailnet.shared.startLogin()
            }
            loginURL = node.loginURL
            try await Task.sleep(for: .seconds(1))
        }
        throw KitedError(message: "等待登录超时，请重试")
    }

    /// 这台设备组网节点此刻的状态：作为工作机的 Mac 读 kited 的节点（上线后 App 改经它的代理访问组网），其余读 App 自己的节点。
    private func nodeState(role: String) async throws -> NodeState {
        #if os(macOS)
        if role == "worker" {
            let status = try await Self.localClient().request("/network", as: NetworkState.self)
            let running = status.state == "Running" && status.socksPort != nil
            if running, let port = status.socksPort { await Tailnet.shared.useWorker(port: port) }
            return NodeState(running: running, needsLogin: status.state == "NeedsLogin", loginURL: status.loginURL.flatMap(URL.init(string:)),
                             user: status.user.map { AccountUser(id: $0.id, email: $0.loginName, name: $0.displayName ?? $0.loginName) },
                             id: status.id, ipv4: status.ips?.first { !$0.contains(":") },
                             peers: (status.peers ?? []).map { Peer(id: $0.id ?? $0.ip ?? $0.name, name: $0.name, ip: $0.ip, online: $0.online ?? false) },
                             error: status.state == "Stopped" ? status.error : nil)
        }
        #endif
        let status = try await Tailnet.shared.status()
        let user = status.me?.UserID.flatMap { id in status.User?[String(id)].map {
            AccountUser(id: String(id), email: $0.LoginName ?? String(id), name: $0.DisplayName ?? $0.LoginName ?? "") } }
        return NodeState(running: status.running, needsLogin: status.BackendState == "NeedsLogin",
                         loginURL: status.AuthURL.flatMap { $0.isEmpty ? nil : URL(string: $0) }, user: user, id: status.me?.ID, ipv4: status.me?.ipv4,
                         peers: status.ownPeers.map { Peer(id: $0.ID ?? $0.ipv4 ?? "", name: $0.HostName ?? "设备", ip: $0.ipv4, online: $0.Online ?? false) },
                         error: nil)
    }

    /// 本机节点重新登记过（ID 变了）时记下新的 ID，设备列表里据此认出本机。
    private func noteDevice(_ id: String?) throws {
        guard let id, id != identity.deviceID else { return }
        identity.deviceID = id
        try saveIdentity()
    }

    func cancelJoin() { joinCancelled = true }

    private func checkJoin() throws {
        try Task.checkCancellation()
        if joinCancelled { throw KitedError(message: "登录页已关闭，没有完成登录") }
    }

    private func finish(role: String, user: AccountUser, deviceID: String?) throws {
        // 换了 Tailscale 用户就是换了一套设备，旧的导航缓存不能留。
        if let previous = identity.user, previous.id != user.id {
            AccountDirectory.clear(previous.id)
            devices = []; catalogs = []; projectAppearances = [:]; registeredProjects = []; appearanceRevision += 1
        }
        identity = Identity(role: role, user: user, deviceID: deviceID)
        try saveIdentity()
    }

    /// 控制端的节点按需上线；作为工作机的 Mac 复用 kited 的节点，见 resume。
    func configureNetwork() async {
        guard ready else { return }
        #if os(macOS)
        if role == "worker" { return }
        #endif
        await Tailnet.shared.enable()
    }

    /// 读一遍组网里的设备。登录失效（节点要求重新登录）时报错，界面提示重新登录。
    func resume() async throws {
        guard ready, let role else { return }
        #if os(macOS)
        // 作为工作机的 Mac：新装的 App 第一次启动时装上它带的服务，之后服务自动更新，见 LocalService。
        if role == "worker" { try await LocalService.installAndStart() }
        #endif
        await configureNetwork()
        // 先看节点状态：要重新登录时马上提示，不等上线超时。
        var node = try await nodeState(role: role)
        for _ in 0..<20 where !node.running {
            if node.needsLogin { throw KitedError(message: "Tailscale 登录已失效，请重新登录") }
            try await Task.sleep(for: .milliseconds(500))
            node = try await nodeState(role: role)
        }
        guard node.running else { throw KitedError(message: role == "worker" ? "本机 kited 还没有上线" : "组网还没有上线") }
        if role != "worker" { _ = try await Tailnet.shared.urlSession() }
        try noteDevice(node.id)
        let own = AccountDevice(id: node.id ?? "self", name: AppModel.deviceName, role: role, online: true,
                                address: role == "worker" ? node.ipv4.map(Self.workerAddress) : nil)
        try await refresh(own: own, peers: node.peers)
    }

    /// 把组网对端分成工作机与控制端：已知的工作机地址（各工作机目录里的）直接算，其余在线的读一次 /machine。
    private func refresh(own: AccountDevice, peers: [Peer]) async throws {
        let known = Set(catalogs.map(\.device.address).compactMap(\.self))
        let pending = peers.filter(\.online).compactMap(\.ip).map(Self.workerAddress).filter { address in
            guard !known.contains(address) else { return false }
            guard let probe = probes[address] else { return true }
            // 读不到可能只是一时超时，先隔一分钟再试，连续读不到才逐次拉长到十分钟。
            return Date().timeIntervalSince(probe.at) >= (probe.worker ? 60 : min(600, 60 * pow(2, Double(probe.failures - 1))))
        }
        await withTaskGroup(of: Void.self) { group in
            for address in pending { group.addTask { await self.probe(address) } }
        }
        let others = peers.map { peer -> AccountDevice in
            let address = peer.ip.map(Self.workerAddress)
            let worker = address.map { known.contains($0) || probes[$0]?.worker == true } ?? false
            return AccountDevice(id: peer.id, name: peer.name, role: worker ? "worker" : "controller",
                                 online: peer.online, address: worker ? address : nil)
        }.sorted { $0.name < $1.name }
        // 没变就不赋值，依赖设备列表的界面不必重算。
        if devices != [own] + others { devices = [own] + others }
        try saveDirectory()
        error = nil
    }

    private func probe(_ address: String) async {
        let machine = try? await KitedClient(address: address).request("/machine", timeout: 8, as: RemoteMachine.self)
        probes[address] = (machine != nil, machine == nil ? (probes[address]?.failures ?? 0) + 1 : 0, Date())
    }

    /// 工作机在组网上的访问地址；各工作机的 kited 都监听同一个端口。
    private static func workerAddress(_ ip: String) -> String { "http://\(ip.contains(":") ? "[\(ip)]" : ip):5483" }

    /// 从一台工作机读到的目录：各工作机最近一次的摘要按组网地址对上设备，对不上的（还没上线过）先不列。
    /// revision 是发请求前的外观版本，期间刚保存的外观不被旧数据覆盖。
    func updateDirectory(machines: [DirectoryMachine], projects: [AccountProject], revision: Int) throws {
        let catalogs: [HostedCatalog] = machines.compactMap { machine in
            guard let snapshot = machine.snapshot, let address = machine.address else { return nil }
            let device = devices.first { $0.address == address }
                ?? AccountDevice(id: machine.id, name: machine.name, role: "worker", online: machine.online, address: address)
            return HostedCatalog(device: device, machineId: machine.id, updatedAt: machine.updatedAt, snapshot: snapshot)
        }
        // 没变就不赋值，依赖目录的界面不必重算；摘要不可比较，按编码后的内容比。
        let encoder = JSONEncoder()
        if (try? encoder.encode(catalogs)) != (try? encoder.encode(self.catalogs)) { self.catalogs = catalogs }
        // 目录里的工作机也是设备，组网列表还没读到的先按目录补上。
        for catalog in catalogs where !devices.contains(where: { $0.id == catalog.device.id }) { devices.append(catalog.device) }
        if projects != registeredProjects { registeredProjects = projects }
        let appearances = Dictionary(projects.map { ($0.id, $0.appearance) }, uniquingKeysWith: { first, _ in first })
        if revision == appearanceRevision, appearances != projectAppearances { projectAppearances = appearances }
        try saveDirectory()
    }

    /// 工作机保存了外观后，本机立即换上，不等下一次读目录。
    func applyAppearance(_ project: AccountProject) throws {
        projectAppearances[project.id] = project.appearance
        applyProject(project)
        appearanceRevision += 1
        try saveDirectory()
    }

    /// 工作机改了一个项目（设置、远程、外观）后，本机立即换上这一项。
    func applyProject(_ project: AccountProject) {
        if let index = registeredProjects.firstIndex(where: { $0.id == project.id }) { registeredProjects[index] = project }
        else { registeredProjects.append(project) }
    }

    /// 本机到各对端的连接方式，按组网 IPv4 索引。作为工作机的 Mac 与 kited 共用节点，从 kited 读取。
    func peerConnections() async -> [String: PeerConnection] {
        #if os(macOS)
        if role == "worker" {
            guard let client = try? await Self.localClient(), let network = try? await client.request("/network", as: NetworkState.self) else { return [:] }
            return Dictionary((network.peers ?? []).compactMap { peer in peer.ip.map { ($0, PeerConnection(connection: peer.connection, endpoint: peer.endpoint)) } },
                              uniquingKeysWith: { first, _ in first })
        }
        #endif
        return await Tailnet.shared.peers()
    }

    /// 退出 Tailscale 登录：这台设备离开组网，下次要重新登录；别的设备仍在。
    func signOut() async throws {
        #if os(macOS)
        if role == "worker" {
            let client = try await Self.localClient()
            let _: NetworkState = try await client.request("/network/logout", method: "POST", as: NetworkState.self)
        }
        #endif
        await Tailnet.shared.logout()
        clear()
    }

    private func saveIdentity() throws {
        UserDefaults.standard.set(try JSONEncoder().encode(identity), forKey: Self.identityKey)
    }
    /// 内容和上次写的一样就不写盘：每轮读设备和读目录各会调一次。
    private func saveDirectory() throws {
        guard let user else { return }
        let directory = AccountDirectory(devices: devices, catalogs: catalogs, projectAppearances: projectAppearances)
        let data = try JSONEncoder().encode(directory)
        guard data != savedDirectory else { return }
        try directory.save(user.id)
        savedDirectory = data
    }
    private func clear() {
        if let user { AccountDirectory.clear(user.id) }
        identity = Identity(); devices = []; catalogs = []; projectAppearances = [:]; registeredProjects = []; appearanceRevision += 1; probes = [:]
        UserDefaults.standard.removeObject(forKey: Self.identityKey)
    }

    #if os(macOS)
    /// 本机 kited 的客户端，带它的机器身份。
    private static func localClient() async throws -> KitedClient {
        let machine = try await KitedClient(address: KitedClient.local).request("/machine", as: RemoteMachine.self)
        return KitedClient(address: KitedClient.local, machineID: machine.id)
    }
    #endif
}

/// 组网里同一用户的一台对端。
private struct Peer: Sendable {
    let id: String
    let name: String
    let ip: String?
    let online: Bool
}

/// 这台设备组网节点此刻的状态，作为工作机的 Mac 与其余设备各自读出后归成这一种。
private struct NodeState {
    let running: Bool
    let needsLogin: Bool
    let loginURL: URL?
    let user: AccountUser?
    let id: String?
    let ipv4: String?
    let peers: [Peer]
    /// 节点起不来时的原因（只有本机 kited 会给）。
    let error: String?
}

#if os(macOS)
enum LocalService {
    static func installAndStart() async throws {
        #if DEBUG
        // Debug 版只用于改界面时快速预览，不打包 kited，直接连本机已安装的服务，也不重启它。
        guard (try? await KitedClient(address: KitedClient.local).request("/machine", as: RemoteMachine.self)) != nil else {
            throw KitedError(message: "Debug 版不带 kited，请先用 install.command 安装 Kite 并启动本机服务")
        }
        #else
        guard let resource = Bundle.main.resourceURL?.appending(path: "Service/runtime"),
              FileManager.default.isExecutableFile(atPath: resource.appending(path: "bin/bun").path) else {
            throw KitedError(message: "此 App 未包含 kited，请使用完整的 Kite 安装包")
        }
        let installed = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Kite/runtime/manifest.json")
        let current = try? Data(contentsOf: installed)
        func responds() async -> Bool { (try? await KitedClient(address: KitedClient.local).request("/machine", as: RemoteMachine.self)) != nil }
        var running = await responds()
        if current != nil, current == (try? Data(contentsOf: resource.appending(path: "manifest.json"))), running {
            UserDefaults.standard.set(AppBuild.current, forKey: installedBuildKey)
            return
        }
        // 这个 App 带的服务装过一次后，服务按发布的版本自动更新，不再用 App 带的旧版覆盖：那等于发布旧版。
        if current != nil, let build = AppBuild.current, UserDefaults.standard.string(forKey: installedBuildKey) == build {
            // 刚登录时 launchd 还在拉起服务，自动换版时服务正在重启：等一会儿再下结论。
            let deadline = Date.now.addingTimeInterval(30)
            while !running, Date.now < deadline {
                try await Task.sleep(for: .seconds(1))
                running = await responds()
            }
            if running { return }
            throw KitedError(message: "本机 kited 没有运行，可以用 kite-service start 启动")
        }
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
        UserDefaults.standard.set(AppBuild.current, forKey: installedBuildKey)
        #endif
    }

    /// 上次由这个 App 装上服务时 App 的构建号：新装的 App 第一次启动才装它带的服务，见 docs/macOS安装与打包.md「管理、升级和卸载」。
    private static let installedBuildKey = "Kite.installedServiceBuild"
}
#endif
