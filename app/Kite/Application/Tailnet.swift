import Foundation
import os
import TailscaleKit
#if os(iOS)
import UIKit
#endif

/// App 自己作为组网节点上线（TailscaleKit，用户态），经它的本机 SOCKS 代理访问远程工作机，不占用系统 VPN。
/// iOS 挂起后代理监听会被系统回收，所以进入后台时关闭节点，回到前台再上线；登录状态保存在节点目录。
actor Tailnet {
    static let shared = Tailnet()

    private var node: TailscaleNode?
    private var session: URLSession?
    private var starting: Task<URLSession, Error>?
    /// 账号服务签发的一次性入网密钥，节点成功上线后清除。
    private var pendingAuthKey: String?
    private var controlURL: String?
    private var deviceID: String?
    private var workerPort: Int?

    /// 入网配置以账号会话为准；设备或密钥变化时重新启动节点。
    func configure(controlURL: String, authKey: String? = nil, deviceID: String) async {
        let changed = self.controlURL != controlURL || self.deviceID != deviceID || workerPort != nil
        self.controlURL = controlURL
        self.deviceID = deviceID
        workerPort = nil
        if let authKey { pendingAuthKey = authKey }
        if authKey != nil || changed { await stop() }
    }

    func useWorker(port: Int) async {
        guard workerPort != port || session == nil else { return }
        await stop()
        workerPort = port
        deviceID = nil
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = ["SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": port]
        session = URLSession(configuration: config)
    }

    func address() async throws -> String {
        _ = try await urlSession()
        guard let node else { throw KitedError(message: "网络节点未启动") }
        let status = try await LocalAPIClient(localNode: node, logger: TailnetLog()).backendStatus()
        guard let ip = status.SelfStatus?.TailscaleIPs?.first(where: { !$0.contains(":") }) else { throw KitedError(message: "尚未取得设备地址，请重试") }
        return ip
    }

    /// Tailscale 的 IPv4 段 100.64.0.0/10、IPv6 段和 MagicDNS 名称经组网访问，其他地址直连。
    nonisolated static func covers(_ address: String) -> Bool {
        guard let host = URL(string: address)?.host(percentEncoded: false)?.lowercased() else { return false }
        if host.hasSuffix(".ts.net") || host.hasPrefix("fd7a:115c:a1e0:") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// 并发请求共用同一次节点启动。
    func urlSession() async throws -> URLSession {
        if let session { return session }
        if let starting { return try await starting.value }
        let task = Task { try await start() }
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
        if let node { try? await node.close() }
        node = nil
    }

    private func start() async throws -> URLSession {
        guard let deviceID, let controlURL else { throw KitedError(message: "设备网络尚未就绪，请稍后重试") }
        // 每次设备入网独立保存状态，退出再登录不会复用旧节点身份。
        let directory = URL.applicationSupportDirectory
            .appending(path: "Tailnet/\(deviceID)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hostName = await Self.hostName
        let node = try TailscaleNode(config: TailscaleKit.Configuration(
            hostName: hostName, path: directory.path(percentEncoded: false), authKey: pendingAuthKey, controlURL: controlURL), logger: TailnetLog())
        self.node = node
        // 上游 up 等到登录成功才返回；超时关闭节点，让失败回到可重试的表单。
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(45)); try? await node.close() }
            catch { /* 登录完成会取消超时。 */ }
        }
        defer { timeout.cancel() }
        do { try await node.up() }
        catch {
            self.node = nil
            throw KitedError(message: "设备入网失败或超时，请检查网络后重试")
        }
        try Task.checkCancellation()
        pendingAuthKey = nil
        return URLSession(configuration: try await URLSessionConfiguration.tailscaleSession(node).0)
    }

    @MainActor private static var hostName: String {
        #if os(macOS)
        let device = Host.current().localizedName ?? "mac"
        #else
        let device = UIDevice.current.name
        #endif
        let name = "kite-app-\(device)".lowercased().map { $0.isLetter && $0.isASCII || $0.isNumber ? $0 : "-" }
        return String(String(name).prefix(63))
    }
}

/// 节点日志：Go 端写标准错误，Swift 端记到系统日志，排查真机连接时用 devicectl --console 或控制台查看。
private struct TailnetLog: LogSink {
    var logFileHandle: Int32? { STDERR_FILENO }
    func log(_ message: String) {
        Logger(subsystem: "Kite", category: "Tailnet").info("\(message, privacy: .public)")
        #if DEBUG
        print("Tailnet: \(message)")
        #endif
    }
}
