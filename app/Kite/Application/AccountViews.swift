import CoreImage.CIFilterBuiltins
import SwiftUI

struct AccountDevices: View {
    @Environment(AppModel.self) private var model
    @State private var invitation: (image: Image?, expiresAt: Date)?
    @State private var error: String?
    @State private var working = false

    var body: some View {
        Section("Kite 账号") {
            if let user = model.account.user { Text(user.email) }
            Button("退出登录", role: .destructive) {
                perform { try await model.account.signOut(); model.clearAccountConnections(); model.showConnection = false }
            }
        }
        Section("我的设备") {
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
            ForEach(model.account.devices) { device in
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.name + (device.id == model.account.deviceID ? "（本机）" : ""))
                        Text("\(device.role == "worker" ? "工作机" : "控制端") · \(device.online ? "在线" : "离线")")
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
        .disabled(working)
        .task { perform { try await model.account.refresh() } }
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
