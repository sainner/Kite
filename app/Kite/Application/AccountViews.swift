import CoreImage.CIFilterBuiltins
import SwiftUI

/// Kite 账号：当前登录的邮箱与退出登录。
struct KiteAccountSection: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?
    @State private var working = false

    var body: some View {
        Section {
            if let user = model.account.user { Text(user.email) }
            Button("退出登录", role: .destructive) {
                guard !working else { return }
                error = nil
                working = true
                Task {
                    defer { working = false }
                    do {
                        try await model.account.signOut()
                        model.clearAccountConnections()
                        model.sidebarSection = .workspaces
                    } catch { self.error = error.localizedDescription }
                }
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        }
        .disabled(working)
    }
}

/// 账号下的设备：扫码让新设备登录，列出各台设备并可移除本机以外的。
struct AccountDevices: View {
    @Environment(AppModel.self) private var model
    @State private var invitation: (image: Image?, expiresAt: Date)?
    @State private var error: String?
    @State private var working = false
    @State private var peers: [String: PeerConnection] = [:]

    var body: some View {
        Section {
            ForEach(model.account.devices) { device in
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.name + (device.id == model.account.deviceID ? "（本机）" : ""))
                        Text("\(device.role == "worker" ? "工作机" : "控制端") · \(device.online ? "在线" : "离线")\(connection(device))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if device.id != model.account.deviceID {
                        Button("移除", role: .destructive) {
                            perform { try await model.account.remove(device.id); model.mergeDirectory() }
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        }
        .task {
            while !Task.isCancelled {
                peers = await model.account.peerConnections()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        Section {
            if let invitation {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if context.date < invitation.expiresAt, let image = invitation.image {
                        image.resizable().interpolation(.none).scaledToFit().frame(width: 200, height: 200).frame(maxWidth: .infinity)
                        Text("用新设备扫描此二维码，即可登录你的账号。\(invitation.expiresAt.formatted(date: .omitted, time: .shortened)) 前有效，只能使用一次。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else { Text("二维码已过期，请重新生成").foregroundStyle(.secondary) }
                }
            }
            Button("让新设备扫码登录") {
                perform {
                    let url = try await model.account.invitation()
                    invitation = (qrCode(url.absoluteString), Date().addingTimeInterval(5 * 60))
                }
            }
        }
        .disabled(working)
        .task { perform { try await model.account.refresh() } }
    }

    /// 账号服务只给工作机地址，按其组网 IP 对应本机节点看到的连接方式。
    private func connection(_ device: AccountDevice) -> String {
        guard device.online, device.id != model.account.deviceID,
              let ip = device.address.flatMap({ URL(string: $0)?.host() }), let peer = peers[ip] else { return "" }
        let endpoint = peer.endpoint.map { " \($0)" } ?? ""
        return switch peer.connection {
        case "direct": " · 直连\(endpoint)"
        case "relay": " · 经中继\(endpoint)"
        default: " · 空闲"
        }
    }

    private func qrCode(_ text: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage, let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return Image(decorative: image, scale: 1)
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        guard !working else { return }
        error = nil
        working = true
        Task {
            defer { working = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}
