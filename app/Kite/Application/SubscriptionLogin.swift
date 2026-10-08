import SwiftUI

struct SubscriptionLoginRequest: Identifiable {
    let id = UUID().uuidString
    let provider: String
    let name: String
    let connection: WorkerConnection
    let client: KitedClient

    init(account: ModelAccount, connection: WorkerConnection) {
        provider = account.id
        name = account.provider
        self.connection = connection
        client = connection.client
    }
}

/// 登录始终绑定打开弹窗时的工作机，切换侧栏不会把授权写到另一台机器。
struct SubscriptionLoginSheet: View {
    let request: SubscriptionLoginRequest
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var state: SubscriptionLoginState?
    @State private var error: String?
    @State private var code = ""
    @State private var submitPhase = CardPhase.idle
    @State private var openedBrowser = false
    @State private var attemptID: String
    @State private var cancellingID: String?
    @State private var submission: Task<Void, Never>?

    init(request: SubscriptionLoginRequest) {
        self.request = request
        _attemptID = State(initialValue: request.id)
    }

    private var trimmedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SubscriptionLoginForm(name: request.name, machine: request.connection.machine.name, provider: request.provider,
                              state: state, error: error, code: $code, submitPhase: $submitPhase,
                              close: { dismiss() }, openAuthorization: { openURL($0) }, submit: submit, restart: restart)
        .task(id: attemptID) { await login(id: attemptID) }
        .onDisappear {
            submission?.cancel()
            let ids = Set([attemptID, cancellingID].compactMap { $0 })
            // 独立任务确保弹窗任务被取消后仍向原工作机发送撤销。
            Task {
                for id in ids {
                    let _: JSON? = try? await request.client.request("/subscription-logins/\(id)", method: "DELETE", timeout: 10, as: JSON.self)
                }
            }
        }
    }

    private func login(id: String) async {
        do {
            // 先等旧 CLI 退出，再启动新流程；取消失败时保留旧 ID，下一次重试继续撤销。
            if let cancellingID {
                let _: JSON = try await request.client.request("/subscription-logins/\(cancellingID)", method: "DELETE", timeout: 10, as: JSON.self)
                try Task.checkCancellation()
                guard attemptID == id else { return }
                self.cancellingID = nil
            }
            var next = try await request.client.request("/subscription-logins", method: "POST",
                body: ["id": id, "provider": request.provider], as: SubscriptionLoginState.self)
            while !Task.isCancelled && attemptID == id {
                guard model.connections[request.connection.id]?.client == request.client else {
                    throw KitedError(message: "工作机连接已变化，请关闭窗口后重新登录。")
                }
                state = next
                if let address = next.url, let url = URL(string: address), !openedBrowser,
                   request.provider == "claude" || next.userCode != nil {
                    openedBrowser = true
                    openURL(url)
                }
                if next.finished {
                    if next.status == "complete" { await model.refreshModelAccounts(request.connection) }
                    return
                }
                try await Task.sleep(for: .seconds(1))
                next = try await request.client.request("/subscription-logins/\(id)", as: SubscriptionLoginState.self)
            }
        } catch {
            if !Task.isCancelled && attemptID == id { self.error = error.localizedDescription }
        }
    }

    private func restart() {
        submission?.cancel()
        cancellingID = cancellingID ?? attemptID
        attemptID = UUID().uuidString
        state = nil
        error = nil
        code = ""
        submitPhase = .idle
        openedBrowser = false
    }

    private func submit() {
        guard !trimmedCode.isEmpty, state?.acceptsCode == true, !submitPhase.working else { return }
        let id = attemptID
        let submittedCode = trimmedCode
        submitPhase = .working
        submission = Task {
            do {
                let _: JSON = try await request.client.request("/subscription-logins/\(id)", method: "POST",
                    body: ["code": submittedCode], as: JSON.self)
                try Task.checkCancellation()
                guard attemptID == id else { return }
                code = ""
                // HTTP 接收授权码不等于登录完成，按钮继续等待轮询给出最终状态。
            } catch {
                guard !Task.isCancelled, attemptID == id else { return }
                submitPhase = .failed("提交失败：\(error.localizedDescription)", retry: submit)
            }
        }
    }
}
