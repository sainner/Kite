import SwiftUI

struct SubscriptionLoginState: Decodable {
    let status: String
    let url: String?
    let userCode: String?
    let acceptsCode: Bool
    let message: String?

    var finished: Bool { ["complete", "failed", "cancelled", "expired"].contains(status) }
}

/// 登录弹窗的呈现，授权流程由调用方驱动。
struct SubscriptionLoginForm: View {
    let name: String
    let machine: String
    let provider: String
    let state: SubscriptionLoginState?
    var error: String?
    @Binding var code: String
    @Binding var submitPhase: CardPhase
    let close: () -> Void
    let openAuthorization: (URL) -> Void
    let submit: () -> Void
    let restart: () -> Void
    @FocusState private var typing: Bool

    private var authorizationURL: URL? { state?.url.flatMap(URL.init(string:)) }
    private var trimmedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var starting: Bool {
        error == nil && state?.finished != true && authorizationURL == nil && submitPhase.error == nil
    }
    private var actionPhase: CardPhase {
        if state?.status == "complete" { return .succeeded }
        if let message = error ?? state?.message {
            return .failed("登录失败：\(message)", retry: restart)
        }
        if state?.finished == true { return .failed("登录未完成，请重试", retry: restart) }
        if submitPhase != .idle { return submitPhase }
        if provider == "chatgpt" || state?.acceptsCode == false { return .working }
        return .idle
    }

    var body: some View {
        CardSheet(title: "登录 \(name)", subtitle: "让工作机 \(machine) 使用这个订阅",
                  typing: typing, close: close) {
            if starting {
                CardProgress("正在启动登录…")
            } else if state?.finished == true || error != nil {
                providerIcon
            } else if state?.finished != true, error == nil, authorizationURL != nil {
                if let userCode = state?.userCode {
                    DeviceCodeView(code: userCode)
                } else if provider == "claude" {
                    CardField(label: "授权码", focused: typing) {
                        SecureField("在此处粘贴授权码", text: $code)
                            .focused($typing)
                            .cardInput { typing = true }
                            .onSubmit { if !trimmedCode.isEmpty && !submitPhase.working { submit() } }
                    }
                    .disabled(submitPhase.working || state?.acceptsCode != true)
                }
            }
        } actions: {
            var group: [PaneHeaderAction] = []
            if let url = authorizationURL {
                group.append(PaneHeaderAction(title: "打开登录页面", systemImage: "arrow.up.right.square") { openAuthorization(url) })
            }
            if actionPhase.error == nil && state?.status != "complete" {
                group.append(PaneHeaderAction(title: "重新登录", systemImage: "arrow.clockwise", help: "重新开始登录",
                                              disabled: starting || submitPhase.working, action: restart))
            }
            return group.isEmpty ? [] : [group]
        } footer: {
            if !starting {
                CardActions(primary: "提交", enabled: !trimmedCode.isEmpty,
                            phase: .constant(actionPhase), succeeded: "登录成功",
                            working: provider == "chatgpt" ? "等待授权完成…" : "正在提交…",
                            action: submit, succeededAction: close)
            }
        }
        .endsTyping(typing) { typing = false }
        .onChange(of: code) { _, value in if value.isEmpty { typing = false } }
    }

    private var providerIcon: some View {
        VStack(spacing: Metrics.padding) {
            Image(provider == "claude" ? .brandClaude : .brandOpenAI)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .foregroundStyle(.primary)
                .padding(CardMetrics.inset)
                .background(Theme.codeBackground, in: Circle())
                .accessibilityHidden(true)
            if state?.status == "complete" {
                Text("授权成功")
                    .font(Theme.heading3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.padding)
    }
}

/// 设备码授权的验证码：一位一格，点任一格复制整串。订阅登录与绑定 GitHub 共用。
struct DeviceCodeView: View {
    let code: String
    @Environment(\.toast) private var toast

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(code.enumerated()), id: \.offset) { _, character in
                if character == "-" {
                    Text("-")
                        .font(Theme.heading2.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Button { copyToPasteboard(code, toast: toast) } label: {
                        Text(String(character))
                            .font(Theme.heading2.monospaced())
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.pointingPlain)
                    .help("复制设备码")
                    .accessibilityLabel("\(String(character))，复制完整设备码")
                    .accessibilityValue(code)
                }
            }
        }
    }
}
