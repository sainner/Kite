import SwiftUI

/// 独立启动的样式画板，只驱动共享弹窗的呈现，不创建登录请求。
struct SubscriptionLoginPreview: View {
    private enum Stage: String, CaseIterable, Identifiable {
        case starting = "启动中", waiting = "等待授权", submitting = "提交中"
        case submitFailed = "提交失败", complete = "成功", failed = "登录失败"
        var id: Self { self }
    }

    @State private var provider = "chatgpt"
    @State private var stage = Stage.waiting
    @State private var code = ""
    @State private var phase = CardPhase.idle
    @State private var showing = true
    @Environment(\.toast) private var toast

    private var state: SubscriptionLoginState {
        switch stage {
        case .starting:
            SubscriptionLoginState(status: "starting", url: nil, userCode: nil, acceptsCode: false, message: nil)
        case .waiting, .submitting, .submitFailed:
            SubscriptionLoginState(status: "waiting", url: "https://example.invalid/login",
                                   userCode: provider == "chatgpt" ? "DEMO-12345" : nil,
                                   acceptsCode: provider == "claude", message: nil)
        case .complete:
            SubscriptionLoginState(status: "complete", url: nil, userCode: nil, acceptsCode: false, message: nil)
        case .failed:
            SubscriptionLoginState(status: "failed", url: nil, userCode: nil, acceptsCode: false,
                                   message: "登录未完成，请检查工作机连接后重新尝试。")
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                Picker("订阅", selection: $provider) {
                    Text("ChatGPT").tag("chatgpt")
                    Text("Claude").tag("claude")
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Picker("状态", selection: $stage) {
                    ForEach(Stage.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                Spacer(minLength: 0)
            }
            if showing {
                SubscriptionLoginForm(name: provider == "chatgpt" ? "ChatGPT" : "Claude", machine: "工作机 · 样式预览",
                                      provider: provider, state: state, code: $code, submitPhase: $phase,
                                      close: { showing = false },
                                      openAuthorization: { _ in toast?.show("样式预览不会打开浏览器或发起登录") },
                                      submit: { stage = .submitting }, restart: { stage = .starting })
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
            } else {
                CardActions(primary: "重新打开预览", phase: .constant(.idle), action: { showing = true })
                    .frame(width: 480)
            }
            Text("与实际登录共用组件").font(Theme.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onChange(of: stage) { _, _ in updateStage() }
        .onChange(of: provider) { _, _ in updateStage() }
    }

    private func updateStage() {
        showing = true
        code = ""
        if stage == .submitting || stage == .submitFailed {
            provider = "claude"
            code = "preview-authorization-code"
        }
        switch stage {
        case .submitting: phase = .working
        case .submitFailed:
            phase = .failed("提交失败，请检查工作机连接后重试。") { stage = .submitting }
        default: phase = .idle
        }
    }
}
