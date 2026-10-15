import Foundation
import os
import TailscaleKit
#if os(iOS)
import UIKit
#endif

/// App 自己作为组网节点上线（TailscaleKit，用户态），连 Tailscale 官方协调服务，用户在浏览器里登录；
/// 经节点的本机 SOCKS 代理访问远程工作机，不占用系统 VPN。作为工作机的 Mac 复用 kited 的节点，见 useWorker。
/// iOS 挂起后代理监听会被系统回收，所以挂起前关闭节点，回到前台再上线；登录状态保存在节点目录，重新上线不用再登录。
/// 关闭后到回前台之前不允许启动：迟到的请求若在挂起前重新拉起节点，回到前台时会话指向已失效的代理，只能杀掉 App 才能恢复。
actor Tailnet {
    static let shared = Tailnet()

    private var node: TailscaleNode?
    /// 节点的 up：登录完成、上线后才结束；没登录的节点一直等用户在浏览器里登录。
    private var up: Task<Void, Error>?
    private var session: URLSession?
    private var starting: Task<URLSession, Error>?
    /// 这台设备登录过，节点可以按需上线；没登录过的要等用户发起登录。
    private var enabled = false
    private var workerPort: Int?
    private var active = true
    /// 最近一次前后台切换的序号；切换由主线程按发生顺序编号，迟到的旧切换不生效。
    private var phase = 0

    private static var directory: URL { URL.applicationSupportDirectory.appending(path: "Tailnet/node", directoryHint: .isDirectory) }

    /// 允许节点上线：登录过的设备启动时，或用户发起登录时。
    func enable() {
        if workerPort != nil { session = nil }
        workerPort = nil
        enabled = true
    }

    func useWorker(port: Int) async {
        guard workerPort != port || session == nil else { return }
        await stop()
        workerPort = port
        enabled = false
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = ["SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": port]
        session = URLSession(configuration: config)
    }

    /// 节点此刻的状态；节点没起时先起（不等登录完成），用来在登录时读登录地址。
    func status() async throws -> TailnetStatus {
        let node = try await startNode()
        let data = try await node.statusJSON()
        return try JSONDecoder().decode(TailnetStatus.self, from: data)
    }

    /// 已启动节点的状态；没启动时为 nil，不为查询而上线。复用 kited 节点时由 kited 上报。
    func currentStatus() async -> TailnetStatus? {
        guard workerPort == nil, let node, let data = try? await node.statusJSON() else { return nil }
        return try? JSONDecoder().decode(TailnetStatus.self, from: data)
    }

    /// 退出 Tailscale 登录：注销节点并删掉节点目录，下次要重新登录。节点没起时先起来再注销，Tailscale 管理页里不留下这台设备。
    func logout() async {
        if workerPort == nil, let node = try? await startNode(), let loopback = try? await node.loopback() {
            _ = await Self.localAPI(loopback, "logout", [:], timeout: 10)
        }
        await stop()
        enabled = false
        try? FileManager.default.removeItem(at: Self.directory)
    }

    /// 发起一次交互登录，让节点给出登录地址。节点刚起时组网库自己会发起；运行中登录失效后不会，要主动发起。
    func startLogin() async {
        guard workerPort == nil, let node, let loopback = try? await node.loopback() else { return }
        _ = await Self.localAPI(loopback, "login-interactive", [:])
    }

    /// App 自己的节点到各对端的连接方式，按组网 IPv4 索引；判断方式与 kite-net 一致。
    func peers() async -> [String: PeerConnection] {
        guard let status = await currentStatus() else { return [:] }
        var result: [String: PeerConnection] = [:]
        for peer in (status.Peer ?? [:]).values {
            guard let ip = peer.ipv4 else { continue }
            result[ip] = switch (peer.Active == true, peer.CurAddr, peer.PeerRelay, peer.Relay) {
            case (true, let address?, _, _) where !address.isEmpty: PeerConnection(connection: "direct", endpoint: address)
            case (true, _, let relay?, _) where !relay.isEmpty: PeerConnection(connection: "relay", endpoint: relay)
            case (true, _, _, let relay?) where !relay.isEmpty: PeerConnection(connection: "relay", endpoint: relay)
            default: PeerConnection(connection: "idle", endpoint: nil)
            }
        }
        return result
    }

    /// Tailscale 的 IPv4 段 100.64.0.0/10、IPv6 段和 MagicDNS 名称经组网访问，其他地址直连。
    nonisolated static func covers(_ address: String) -> Bool {
        guard let host = URL(string: address)?.host(percentEncoded: false)?.lowercased() else { return false }
        if host.hasSuffix(".ts.net") || host.hasPrefix("fd7a:115c:a1e0:") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// 关闭节点并禁止再启动，或回到前台后重新允许启动。
    func setActive(_ value: Bool, phase: Int) async {
        guard phase > self.phase else { return }
        self.phase = phase
        active = value
        if !value { await stop() }
        else if session != nil, let node { Task { await refreshPaths(node) } }
    }

    /// 回到前台时节点仍在：锁屏期间网络可能已切换、公网端口映射可能已变，组网库要等超时才会发现。
    /// 主动重新绑定、重新探测公网地址，再探测到各在线对端的路径，让双方尽快改用可用的路径。
    private func refreshPaths(_ node: TailscaleNode) async {
        guard let loopback = try? await node.loopback() else { return }
        let refreshed = TimingTrace.span("刷新路径")
        for action in ["rebind", "restun"] {
            let done = TimingTrace.span("组网 \(action)")
            done(await Self.localAPI(loopback, "debug", ["action": action]) ? "完成" : "失败")
        }
        await probePeers(loopback)
        refreshed("完成")
    }

    /// 对各在线对端做 disco 探测，建立直连或中继路径；每台最多等两秒，离线或不通的对端不拖住其他流程。
    private func probePeers(_ loopback: TailscaleNode.LoopbackConfig) async {
        let peers = (await currentStatus())?.Peer?.values.filter { $0.Online == true }.compactMap(\.ipv4) ?? []
        await withTaskGroup(of: Void.self) { group in
            for ip in peers {
                group.addTask {
                    let pinged = TimingTrace.span("探测对端 \(ip)")
                    pinged(await Self.localAPI(loopback, "ping", ["ip": ip, "type": "disco"], timeout: 2) ? "完成" : "失败")
                }
            }
        }
    }

    /// 经节点的本地回环接口调用组网库的本地接口，凭据随回环配置下发。
    private static func localAPI(_ loopback: TailscaleNode.LoopbackConfig, _ path: String, _ form: [String: String],
                                 timeout: TimeInterval = 5) async -> Bool {
        guard let ip = loopback.ip, let port = loopback.port else { return false }
        var components = URLComponents()
        components.scheme = "http"
        components.host = ip
        components.port = port
        components.path = "/localapi/v0/\(path)"
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Basic \(Data("tsnet:\(loopback.localAPIKey)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        request.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return ((response as? HTTPURLResponse)?.statusCode ?? 500) < 300
    }

    /// 并发请求共用同一次节点启动。
    func urlSession() async throws -> URLSession {
        if let session { return session }
        guard active else { throw KitedError(message: "App 在后台，回到前台后重新连接") }
        if let starting { return try await starting.value }
        let task = Task { try await connect() }
        starting = task
        defer { starting = nil }
        let value = try await task.value
        session = value
        return value
    }

    func stop() async {
        starting?.cancel()
        session?.invalidateAndCancel()
        session = nil
        up?.cancel()
        up = nil
        // 先清引用再等关闭，关闭期间新启动的节点不会被这里清掉。
        let node = node
        self.node = nil
        if let node { try? await node.close() }
    }

    /// 起节点并开始上线，不等登录完成。
    private func startNode() async throws -> TailscaleNode {
        if let node { return node }
        guard active else { throw KitedError(message: "App 在后台，回到前台后重新连接") }
        guard enabled else { throw KitedError(message: "还没有登录 Tailscale") }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let created = TimingTrace.span("创建节点")
        let hostName = await Self.hostName
        guard self.node == nil else { return self.node! }
        let node = try TailscaleNode(config: TailscaleKit.Configuration(
            hostName: hostName, path: Self.directory.path(percentEncoded: false), authKey: nil, controlURL: kDefaultControlURL), logger: TailnetLog())
        self.node = node
        created("完成")
        up = Task { try await node.up() }
        return node
    }

    /// 等节点上线后建经它访问组网的会话。登录过的节点很快上线；要登录时马上报错，节点留给登录页用，登录完成后照常上线；
    /// 45 秒既没上线也不是在等登录就关掉节点，让失败回到可重试的状态。
    private func connect() async throws -> URLSession {
        let node = try await startNode()
        guard let up else { throw KitedError(message: "网络节点未启动") }
        let span = TimingTrace.span("节点上线")
        let deadline = ContinuousClock.now + .seconds(45)
        var state: String?
        while state != "Running", ContinuousClock.now < deadline {
            guard self.node === node else { throw CancellationError() }
            state = (try? await node.statusJSON()).flatMap { try? JSONDecoder().decode(TailnetStatus.self, from: $0) }?.BackendState
            if state == "NeedsLogin" {
                span("要登录")
                throw KitedError(message: "Tailscale 登录已失效，请重新登录")
            }
            if state != "Running" { try await Task.sleep(for: .milliseconds(200)) }
        }
        do {
            guard state == "Running" else { throw KitedError(message: "组网上线超时") }
            try await up.value
        } catch {
            span("失败")
            if self.node === node { self.node = nil; self.up = nil }
            try? await node.close()
            throw KitedError(message: "组网上线失败或超时，请检查网络后重试")
        }
        span("完成")
        // 上线期间被停止（如进入后台）时关掉这个节点，不能留一个没人管的节点占着同一份身份。
        guard !Task.isCancelled, active, self.node === node else {
            if self.node === node { self.node = nil; self.up = nil }
            try? await node.close()
            throw CancellationError()
        }
        tracePaths()
        return URLSession(configuration: try await URLSessionConfiguration.tailscaleSession(node).0)
    }

    /// 计时：节点上线后十五秒内跟踪到各对端的路径变化。
    private func tracePaths() {
        #if DEBUG
        Task {
            var last: [String: PeerConnection] = [:]
            for _ in 0..<150 {
                let current = await peers()
                for (ip, peer) in current where last[ip] != peer {
                    TimingTrace.mark("对端 \(ip) 路径 \(peer.connection) \(peer.endpoint ?? "")")
                }
                last = current
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        #endif
    }

    /// 设备在组网里的名字；iPhone、iPad 的系统名称就是机型，其他设备靠它区分手机和平板。
    @MainActor private static var hostName: String {
        #if os(macOS)
        let device = Host.current().localizedName ?? "mac"
        #else
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
        let name = "kite-app-\(device)".lowercased().map { $0.isLetter && $0.isASCII || $0.isNumber ? $0 : "-" }
        return String(String(name).prefix(63))
    }
}

/// 节点的 ipnstate.Status：上游 Swift 类型缺少 Active、OS 等字段，直接解析 JSON。
nonisolated struct TailnetStatus: Decodable, Sendable {
    struct Node: Decodable {
        let ID: String?
        let HostName: String?
        let TailscaleIPs: [String]?
        let OS: String?
        let UserID: Int64?
        let Online: Bool?
        let Active: Bool?
        let CurAddr: String?
        let Relay: String?
        let PeerRelay: String?
        let Tags: [String]?

        var ipv4: String? { TailscaleIPs?.first { !$0.contains(":") } }
    }
    struct User: Decodable {
        let LoginName: String?
        let DisplayName: String?
    }
    let BackendState: String?
    let AuthURL: String?
    let me: Node?
    let User: [String: User]?
    let Peer: [String: Node]?

    enum CodingKeys: String, CodingKey { case BackendState, AuthURL, me = "Self", User, Peer }

    var running: Bool { BackendState == "Running" }
    /// 同一用户、不带标签的对端；共享进来的、别人的设备不算。
    var ownPeers: [Node] {
        guard let user = me?.UserID else { return [] }
        return (Peer ?? [:]).values.filter { $0.UserID == user && ($0.Tags ?? []).isEmpty }
    }
}

/// 本机到某个对端的连接方式：direct 点对点直连，relay 经中继，idle 近两分钟无流量、尚未确定路径。
struct PeerConnection: Decodable, Equatable {
    let connection: String
    /// 直连时为对端实际地址，中继时为 DERP 区域或对端中继地址。
    let endpoint: String?
}

/// 节点日志：Go 端写标准错误，Swift 端记到系统日志，排查真机连接时用 devicectl --console 或控制台查看。
private struct TailnetLog: LogSink {
    /// 组网库用 os.NewFile 包装这个描述符，节点关闭后随垃圾回收关掉它；每个节点交一份副本，
    /// 否则共用的描述符被关闭后号码会被新连接复用，下一个节点的日志就写进了别的连接。
    var logFileHandle: Int32? {
        #if DEBUG
        dup(Self.goLog)
        #else
        dup(STDERR_FILENO)
        #endif
    }

    #if DEBUG
    /// 组网库日志经管道读出，转发到标准错误，同时带上时间写入计时文件，用于对照节点内部各阶段。
    private static let pipe = Pipe()
    private static let goLog: Int32 = {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            FileHandle.standardError.write(data)
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                TimingTrace.mark("组网库 \(line)")
            }
        }
        return pipe.fileHandleForWriting.fileDescriptor
    }()
    #endif

    func log(_ message: String) {
        Logger(subsystem: "Kite", category: "Tailnet").info("\(message, privacy: .public)")
        #if DEBUG
        print("Tailnet: \(message)")
        #endif
    }
}
