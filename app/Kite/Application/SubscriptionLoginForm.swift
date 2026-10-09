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
    @Environment(\.toast) private var toast

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
        CardSheet(title: "登录 \(name)", subtitle: machine,
                  typing: typing, trailingActions: true, close: close) {
            if starting {
                HStack(spacing: 10) {
                    CardSpinner()
                    Text("正在启动登录…")
                }
                .font(Theme.secondary)
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if state?.finished == true || error != nil {
                providerIcon
            } else if state?.finished != true, error == nil, authorizationURL != nil {
                if let userCode = state?.userCode {
                    deviceCode(userCode)
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
            if authorizationURL != nil || (actionPhase.error == nil && state?.status != "complete") {
                PaneHeaderButtonGroup {
                    if let url = authorizationURL {
                        Button { openAuthorization(url) } label: {
                            PaneHeaderButtonLabel("打开登录页面", systemImage: "arrow.up.right.square")
                        }
                        .help("打开登录页面")
                    }
                    if actionPhase.error == nil && state?.status != "complete" {
                        Button(action: restart) {
                            PaneHeaderButtonLabel("重新登录", systemImage: "arrow.clockwise")
                        }
                        .disabled(starting || submitPhase.working)
                        .help("重新开始登录")
                    }
                }
            }
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
        Image(provider == "claude" ? .brandClaude : .brandOpenAI)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 48, height: 48)
            .foregroundStyle(.primary)
            .padding(CardMetrics.inset)
            .background(Theme.codeBackground, in: Circle())
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metrics.padding)
            .accessibilityHidden(true)
    }

    private func deviceCode(_ value: String) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(value.enumerated()), id: \.offset) { _, character in
                if character == "-" {
                    Text("-")
                        .font(Theme.heading2.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Button { copyToPasteboard(value, toast: toast) } label: {
                        Text(String(character))
                            .font(Theme.heading2.monospaced())
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.pointingPlain)
                    .help("复制设备码")
                    .accessibilityLabel("\(String(character))，复制完整设备码")
                    .accessibilityValue(value)
                }
            }
        }
    }
}
