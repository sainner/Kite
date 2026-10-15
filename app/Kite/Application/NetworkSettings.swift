import SwiftUI

/// 工作机的网络页：组网状态与受管网络通道（docs/kited.md「受管网络通道」）。kited 的组网接口只对本机开放，
/// 所以只有本机的工作机能看和设置，远程工作机只给一句说明。受管网络通道是给特殊网络用的可选项，默认不配。
struct NetworkSettingsPage: View {
    let connection: WorkerConnection
    @Environment(\.toast) private var toast
    @State private var status: NetworkState?
    @State private var channel: NetworkChannelConfig?
    @State private var draft = NetworkChannelConfig()
    @State private var editing = false
    @State private var publicKey: String?
    @State private var busy = false
    @State private var error: String?

    private var local: Bool { connection.client.isLocal }

    var body: some View {
        Form {
            if local {
                networkSection
                channelSection
            } else {
                Section { Text("组网状态与受管网络通道只能在这台工作机本机查看和设置。").foregroundStyle(.secondary) }
            }
        }
        .pageForm()
        .task(id: connection.id) {
            guard local else { return }
            await loadChannel()
            // 通道握手、对端路径会变，开着这一页时每两秒读一次状态。
            while !Task.isCancelled {
                status = try? await connection.client.request("/network", as: NetworkState.self)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - 组网

    private var networkSection: some View {
        Section("组网") {
            LabeledContent("状态", value: status.map(\.stateText) ?? "读取中")
            if let address = status?.ips?.first { LabeledContent("组网地址", value: address) }
            if let endpoints = status?.endpoints, !endpoints.isEmpty {
                LabeledContent("对外端点") {
                    Text(endpoints.joined(separator: "\n")).multilineTextAlignment(.trailing).textSelection(.enabled)
                }
            }
            ForEach(status?.peers ?? [], id: \.self) { peer in
                LabeledContent(peer.name, value: peer.pathText)
            }
        }
    }

    // MARK: - 受管网络通道

    private var channelSection: some View {
        Section {
            if editing {
                TextField("路由器端点", text: $draft.endpoint, prompt: Text("192.168.31.1:51830"))
                TextField("路由器公钥", text: $draft.routerKey, prompt: Text("base64"))
                TextField("通道 IPv4", text: $draft.address4, prompt: Text("10.203.0.2"))
                TextField("通道 IPv6（可选）", text: $draft.address6Text, prompt: Text("没有可以不填"))
                HStack {
                    Button("取消") { editing = false; error = nil }
                    Spacer()
                    Button("保存") { Task { await save() } }.disabled(busy || draft.incomplete)
                }
            } else if let channel {
                LabeledContent("状态") { Text(channelStateText).foregroundStyle(channelStateColor) }
                if let at = status?.channel?.handshakeAt {
                    LabeledContent("最近握手") {
                        Text(Date(timeIntervalSince1970: at / 1000), style: .relative) + Text("前")
                    }
                }
                LabeledContent("路由器", value: channel.endpoint)
                LabeledContent("通道地址", value: [channel.address4, channel.address6].compactMap(\.self).joined(separator: "\n"))
                HStack {
                    Button("停用", role: .destructive) { Task { await remove() } }.disabled(busy)
                    Spacer()
                    Button("修改") { draft = channel; editing = true }
                }
            } else {
                Button("配置受管网络通道") { draft = NetworkChannelConfig(); editing = true }
            }
            if let publicKey {
                LabeledContent("本机公钥") {
                    HStack(spacing: 6) {
                        Text(publicKey).font(Theme.code).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button("复制") { copyToPasteboard(publicKey, toast: toast) }
                    }
                }
            } else {
                Button("取出本机公钥") { Task { await loadKey() } }.disabled(busy)
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        } header: {
            Text("受管网络通道")
        } footer: {
            Text("只有网络要求组网流量先经路由器认证的 WireGuard 通道出网时才需要，普通网络不用配。本机公钥交给网络管理员登记；第一次取时生成私钥存进钥匙串，系统可能弹窗请你允许。")
        }
    }

    private var channelStateText: String {
        switch status?.channel?.state {
        case "up": "已连通"
        case "handshaking": "等待与路由器握手"
        case "waitingKey": "等待钥匙串允许读取私钥"
        case "error": "出错：\(status?.channel?.error ?? "")"
        default: status?.enabled == false ? "组网已关闭" : "读取中"
        }
    }

    private var channelStateColor: Color {
        switch status?.channel?.state {
        case "up": .accentColor
        case "error": Theme.danger
        default: Theme.warning
        }
    }

    private func loadChannel() async {
        do { channel = try await connection.client.request("/network/channel", as: NetworkChannelResponse.self).channel }
        catch { self.error = "读取受管网络通道失败：\(error.localizedDescription)" }
    }

    private func loadKey() async {
        busy = true
        defer { busy = false }
        // 等用户在钥匙串弹窗里允许，给足时间。
        do { publicKey = try await connection.client.request("/network/channel/key", timeout: 150, as: NetworkChannelKey.self).publicKey; error = nil }
        catch { self.error = "取本机公钥失败：\(error.localizedDescription)" }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            status = try await connection.client.request("/network/channel", method: "PUT", body: draft, as: NetworkState.self)
            // kited 会去掉前后空白和地址后面的前缀长度，保存后读回它规整过的配置。
            await loadChannel()
            editing = false
            error = nil
        } catch { self.error = "保存失败：\(error.localizedDescription)" }
    }

    private func remove() async {
        busy = true
        defer { busy = false }
        do {
            status = try await connection.client.request("/network/channel", method: "DELETE", as: NetworkState.self)
            channel = nil
            error = nil
        } catch { self.error = "停用失败：\(error.localizedDescription)" }
    }
}

/// 本机 kited 的组网状态（`GET /network`），网络页与身份模型共用。
struct NetworkState: Decodable {
    struct Peer: Decodable, Hashable {
        let id: String?
        let name: String
        let ip: String?
        let os: String?
        let online: Bool?
        let connection: String
        let endpoint: String?

        var pathText: String {
            switch connection {
            case "direct": "直连 \(endpoint ?? "")"
            case "relay": "中继 \(endpoint ?? "")"
            default: "暂无流量"
            }
        }
    }
    struct Channel: Decodable {
        let state: String
        let handshakeAt: Double?
        let error: String?
    }
    struct User: Decodable { let id: String; let loginName: String; let displayName: String? }
    let enabled: Bool
    let state: String
    /// 需要登录时，要在浏览器里打开的地址。
    let loginURL: String?
    let id: String?
    let user: User?
    let ips: [String]?
    let socksPort: Int?
    let peers: [Peer]?
    let endpoints: [String]?
    let channel: Channel?
    let error: String?

    var stateText: String {
        let text = switch state {
        case "Running": "在线"
        case "NeedsLogin": "需要登录"
        case "Starting": "启动中"
        case "Stopped": enabled ? "已停止" : "已关闭"
        default: state
        }
        return error.map { "\(text)：\($0)" } ?? text
    }
}

/// 受管网络通道的配置，字段与 kited 的 `PUT /network/channel` 一致。
struct NetworkChannelConfig: Codable, Equatable {
    var endpoint = ""
    var routerKey = ""
    var address4 = ""
    var address6: String?

    /// 输入框绑定；清空即不配 IPv6。
    var address6Text: String {
        get { address6 ?? "" }
        set { address6 = newValue.isEmpty ? nil : newValue }
    }

    var incomplete: Bool { [endpoint, routerKey, address4].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
}

private struct NetworkChannelResponse: Decodable { let channel: NetworkChannelConfig? }
private struct NetworkChannelKey: Decodable { let publicKey: String }
