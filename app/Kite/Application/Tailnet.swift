import Foundation
import Observation
import os
import TailscaleKit
#if os(iOS)
import UIKit
#endif

/// App 自己作为组网节点上线（TailscaleKit，用户态），经它的本机 SOCKS 代理访问远程工作机，不占用系统 VPN。
/// iOS 挂起后代理监听会被系统回收，所以进入后台时关闭节点，回到前台再上线；登录状态保存在节点目录。
actor Tailnet {
    static let shared = Tailnet()

    /// 界面读取的节点状态；等待登录时给出登录网址。
    @MainActor @Observable final class Status {
        var loginURL: URL?
        var running = false
    }
    @MainActor static let status = Status()

    private var node: TailscaleNode?
    private var processor: MessageProcessor?
    private var session: URLSession?
    private var starting: Task<URLSession, Error>?
    /// 扫码带来的一次性入网密钥，下次上线时代替浏览器登录。
    private var pendingAuthKey: String?

    /// 控制服务器，留空用 Tailscale 官方服务；自建 headscale 时填它的地址。
    nonisolated static var controlURL: String {
        get { UserDefaults.standard.string(forKey: "KiteTailnetControlURL").flatMap { $0.isEmpty ? nil : $0 } ?? kDefaultControlURL }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(value == kDefaultControlURL ? "" : value, forKey: "KiteTailnetControlURL")
        }
    }

    /// 自建的控制服务器地址；用官方服务时为空，供输入框显示。
    nonisolated static var customControlURL: String { UserDefaults.standard.string(forKey: "KiteTailnetControlURL") ?? "" }

    /// 改了控制服务器或带来入网密钥时关闭当前节点，下次连接按新设置上线。
    func configure(controlURL: String, authKey: String? = nil) async {
        let previous = Self.controlURL
        Self.controlURL = controlURL.isEmpty ? kDefaultControlURL : controlURL
        if let authKey { pendingAuthKey = authKey }
        if Self.controlURL != previous || authKey != nil { await stop() }
    }

    /// Tailscale 的 IPv4 段 100.64.0.0/10、IPv6 段和 MagicDNS 名称经组网访问，其他地址直连。
    nonisolated static func covers(_ address: String) -> Bool {
        guard let host = URL(string: address)?.host(percentEncoded: false)?.lowercased() else { return false }
        if host.hasSuffix(".ts.net") || host.hasPrefix("fd7a:115c:a1e0:") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// 节点首次上线要在浏览器登录，期间调用方一直等待。
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
        processor?.cancel()
        processor = nil
        session?.invalidateAndCancel()
        session = nil
        if let node { try? await node.close() }
        node = nil
        await MainActor.run { Tailnet.status.running = false }
    }

    private func start() async throws -> URLSession {
        // 每个控制服务器一份节点状态，切换后各自登录。
        let control = Self.controlURL
        let directory = URL.applicationSupportDirectory
            .appending(path: "Tailnet/\(URL(string: control)?.host() ?? "default")", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hostName = await Self.hostName
        let node = try TailscaleNode(config: TailscaleKit.Configuration(
            hostName: hostName, path: directory.path(percentEncoded: false), authKey: pendingAuthKey, controlURL: control), logger: TailnetLog())
        self.node = node
        processor = try await LocalAPIClient(localNode: node, logger: TailnetLog())
            .watchIPNBus(mask: [.initialState, .noPrivateKeys], consumer: LoginWatcher())
        try await node.up()
        pendingAuthKey = nil
        await MainActor.run {
            Tailnet.status.loginURL = nil
            Tailnet.status.running = true
        }
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

/// 只关心登录网址；连接状态以请求结果为准。
private actor LoginWatcher: MessageConsumer {
    func notify(_ notify: Ipn.Notify) {
        guard let text = notify.BrowseToURL, let url = URL(string: text) else { return }
        Task { @MainActor in Tailnet.status.loginURL = url }
    }

    func error(_ error: Error) {}
}
