import SwiftUI

/// 账号的项目登记表。托管项目可以迁移到正式远程，项目 ID 不变。
struct AccountProject: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let remote: String
    let hosted: Bool
    let icon: String?
    let color: String?
}

struct GitHubDevice: Decodable, Equatable {
    let flow: String
    let userCode: String
    let verificationURI: String
    let interval: Int
}

struct GitHubRepository: Decodable, Identifiable, Equatable {
    let fullName: String
    let url: String
    let `private`: Bool
    var id: String { fullName }
}

extension KiteAccount {
    func startGitHub() async throws -> GitHubDevice {
        return try await request("/api/git/github/device", method: "POST", as: GitHubDevice.self)
    }

    /// 返回 pending、slow_down、expired、denied 或 authorized。
    func pollGitHub(_ flow: String) async throws -> String {
        struct Poll: Decodable { let status: String }
        return try await request("/api/git/github/device/\(flow)", method: "POST", as: Poll.self).status
    }

    /// 没有绑定 GitHub 时为空。
    func gitHubRepositories() async throws -> [GitHubRepository] {
        do { return try await request("/api/git/github/repos", as: [GitHubRepository].self) }
        catch let error as KitedError where error.status == 404 { return [] }
    }

    func projects() async throws -> [AccountProject] {
        return try await request("/api/projects", as: [AccountProject].self)
    }

    /// 服务器直接把托管仓库推到新远程，大仓库需要较长时间。
    func migrate(_ project: String, to remote: String) async throws -> AccountProject {
        try await request("/api/projects/\(project)/migrate", method: "POST", body: ["remote": remote], timeout: 600, as: AccountProject.self)
    }
}

struct GitAccountsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// 账号绑定的 Git 平台；凭据只在托管服务和工作机之间流转，App 只看到主机与账号名。
    @State private var accounts: [AccountCredential] = []
    @State private var device: GitHubDevice?
    @State private var host = ""
    @State private var username = ""
    @State private var token = ""
    @State private var tokenForm = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Section {
            ForEach(accounts) { account in
                HStack {
                    VStack(alignment: .leading) {
                        Text(account.name)
                        Text(account.meta["username"]?.string ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("解除绑定", role: .destructive) {
                        perform { try await model.account.deleteCredential(account.id); try await load() }
                    }
                }
            }
            if let device {
                VStack(alignment: .leading, spacing: 6) {
                    Text("在 GitHub 页面输入验证码，授权后自动完成绑定")
                    Text(device.userCode).font(.title2.monospaced()).textSelection(.enabled)
                    HStack {
                        Button("打开 GitHub") { if let url = URL(string: device.verificationURI) { openURL(url) } }
                        Button("取消") { self.device = nil }
                    }
                }
            } else {
                Button("绑定 GitHub") { perform { device = try await model.account.startGitHub() } }
            }
            DisclosureGroup("用访问令牌绑定其他平台", isExpanded: $tokenForm) {
                TextField("域名，如 gitlab.com", text: $host).autocorrectionDisabled()
                TextField("用户名（可选）", text: $username).autocorrectionDisabled()
                SecureField("访问令牌", text: $token)
                Button("保存") {
                    perform {
                        try await bind(host: host.trimmingCharacters(in: .whitespaces).lowercased(),
                                       username: username.trimmingCharacters(in: .whitespaces), token: token)
                        host = ""; username = ""; token = ""; tokenForm = false
                        try await load()
                    }
                }.disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || token.isEmpty)
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        } header: {
            Text("Git 账号")
        } footer: {
            Text("绑定的凭据随 Kite 账号分发给各台工作机，用于克隆与推送。GitHub 授权覆盖该账号下的全部仓库。")
        }
        .disabled(working)
        .task { perform { try await load() } }
        .task(id: device?.flow) { await poll() }
    }

    private func load() async throws { accounts = try await model.account.credentials(type: "git") }

    /// 同一主机只有一条 Git 凭据，已绑定就替换。
    private func bind(host: String, username: String, token: String) async throws {
        // 不填用户名时由服务端补上默认的 oauth2
        let meta = username.isEmpty ? [:] : ["username": username]
        if let existing = accounts.first(where: { $0.name == host }) {
            try await model.account.updateCredential(existing.id, meta: meta, secret: ["token": token])
        } else {
            try await model.account.createCredential(type: "git", name: host, meta: meta, secret: ["token": token])
        }
    }

    /// 按服务端给的间隔轮询，授权完成、拒绝或过期即停。
    private func poll() async {
        guard let device else { return }
        var interval = device.interval
        while self.device?.flow == device.flow {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, self.device?.flow == device.flow else { return }
            do {
                switch try await model.account.pollGitHub(device.flow) {
                case "pending": continue
                case "slow_down": interval += 5
                case "authorized": self.device = nil; try await load()
                case "denied": self.device = nil; error = "GitHub 授权被拒绝"
                default: self.device = nil; error = "验证码已过期，请重新绑定"
                }
            } catch {
                self.device = nil
                self.error = error.localizedDescription
            }
        }
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
