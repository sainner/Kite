import CoreImage.CIFilterBuiltins
import SwiftUI

/// Kite 账号：当前登录的邮箱与退出登录。
struct KiteAccountSection: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?
    @State private var working = false

    var body: some View {
        CardSection("Kite") {
            HStack(spacing: 12) {
                SidebarAvatar()
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.account.user?.email ?? "未登录").font(Theme.title).textSelection(.enabled)
                    Text("Kite 账号").font(Theme.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
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
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.danger)
                .disabled(!model.account.signedIn)
            }
            .padding(.vertical, 8)
            LabeledContent("额度", value: "暂无额度信息")
                .foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(Theme.danger) }
            // 账号层的错误只在这一页写全，侧栏用户栏的提示点开到这里。
            if let error = model.account.error { Text(error).foregroundStyle(Theme.danger).textSelection(.enabled) }
        }
        .disabled(working)
    }
}

/// 为新设备生成一次性登录二维码。
struct AccountDeviceInvitation: View {
    @Environment(AppModel.self) private var model
    @State private var invitation: (image: Image?, expiresAt: Date)?
    @State private var error: String?
    @State private var working = false

    var body: some View {
        CardSection("新设备登录") {
            if let invitation {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if context.date < invitation.expiresAt, let image = invitation.image {
                        image.resizable().interpolation(.none).scaledToFit().frame(width: 200, height: 200).frame(maxWidth: .infinity)
                        Text("用新设备扫描此二维码，即可登录你的账号。\(invitation.expiresAt.formatted(date: .omitted, time: .shortened)) 前有效，只能使用一次。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else { Text("二维码已过期，请重新生成").foregroundStyle(.secondary) }
                }
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
            Button("让新设备扫码登录") {
                perform {
                    let url = try await model.account.invitation()
                    invitation = (qrCode(url.absoluteString), Date().addingTimeInterval(5 * 60))
                }
            }
        }
        .disabled(working || !model.account.signedIn)
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
