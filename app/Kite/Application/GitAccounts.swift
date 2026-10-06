import SwiftUI

/// 账号绑定的 Git 平台；凭据只在托管服务和工作机之间流转，App 只看到主机与账号名。
struct GitAccount: Decodable, Identifiable, Equatable {
    let host: String
    let account: String
    let createdAt: Int
    var id: String { host }
}

/// 账号的项目登记表。托管项目可以迁移到正式远程，项目 ID 不变。
struct AccountProject: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let remote: String
    let url: String
    let hosted: Bool
    let createdAt: Int
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
    func gitAccounts() async throws -> [GitAccount] {
        if SampleWorkspace.enabled { return GitSamples.accounts }
        return try await request("/api/git/accounts", as: [GitAccount].self)
    }

    func bindToken(host: String, username: String, token: String) async throws {
        if SampleWorkspace.enabled { throw KitedError(message: "预览数据不能修改绑定") }
        var body = ["token": token]
        if !username.isEmpty { body["username"] = username }
        let _: JSON = try await request("/api/git/accounts/\(host)", method: "PUT", body: body, as: JSON.self)
    }

    func unbind(host: String) async throws {
        if SampleWorkspace.enabled { throw KitedError(message: "预览数据不能修改绑定") }
        let _: JSON = try await request("/api/git/accounts/\(host)", method: "DELETE", as: JSON.self)
    }

    func startGitHub() async throws -> GitHubDevice {
        if SampleWorkspace.enabled { return GitSamples.device }
        return try await request("/api/git/accounts/github.com/device", method: "POST", as: GitHubDevice.self)
    }

    /// 返回 pending、slow_down、expired、denied 或 authorized。
    func pollGitHub(_ flow: String) async throws -> String {
        struct Poll: Decodable { let status: String }
        return try await request("/api/git/accounts/github.com/device/\(flow)", method: "POST", as: Poll.self).status
    }

    /// 没有绑定 GitHub 时为空。
    func gitHubRepositories() async throws -> [GitHubRepository] {
        if SampleWorkspace.enabled { return GitSamples.repositories }
        do { return try await request("/api/git/accounts/github.com/repos", as: [GitHubRepository].self) }
        catch let error as KitedError where error.status == 404 { return [] }
    }

    func projects() async throws -> [AccountProject] {
        if SampleWorkspace.enabled { return GitSamples.projects }
        return try await request("/api/projects", as: [AccountProject].self)
    }

    /// 服务器直接把托管仓库推到新远程，大仓库需要较长时间。
    func migrate(_ project: String, to remote: String) async throws -> AccountProject {
        try await request("/api/projects/\(project)/migrate", method: "POST", body: ["remote": remote], timeout: 600, as: AccountProject.self)
    }
}

/// 预览用的账号数据，覆盖已绑定的两类平台、托管与正式远程的项目。
enum GitSamples {
    static let accounts = [
        GitAccount(host: "github.com", account: "sainner", createdAt: 0),
        GitAccount(host: "gitlab.com", account: "oauth2", createdAt: 0),
    ]
    static let device = GitHubDevice(flow: "sample", userCode: "WDJB-MJHT", verificationURI: "https://github.com/login/device", interval: 5)
    static let repositories = [
        GitHubRepository(fullName: "sainner/thesis", url: "https://github.com/sainner/thesis.git", private: true),
        GitHubRepository(fullName: "sainner/kite-notes", url: "https://github.com/sainner/kite-notes.git", private: false),
    ]
    static let projects = [
        AccountProject(id: "sample-hosted", name: "论文草稿", remote: "hs.sainner.top/git/sample-hosted",
                       url: "https://hs.sainner.top/git/sample-hosted.git", hosted: true, createdAt: 0),
        AccountProject(id: "sample", name: "harness", remote: "github.com/sample/harness",
                       url: "https://github.com/sample/harness.git", hosted: false, createdAt: 0),
    ]
}

struct GitAccountsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var accounts: [GitAccount] = []
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
                        Text(account.host)
                        Text(account.account).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("解除绑定", role: .destructive) {
                        perform { try await model.account.unbind(host: account.host); try await load() }
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
                        try await model.account.bindToken(host: host.trimmingCharacters(in: .whitespaces).lowercased(),
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

    private func load() async throws { accounts = try await model.account.gitAccounts() }

    /// 按服务端给的间隔轮询，授权完成、拒绝或过期即停。
    private func poll() async {
        guard let device, !SampleWorkspace.enabled else { return }
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

struct AccountProjectsSection: View {
    @Environment(AppModel.self) private var model
    @State private var projects: [AccountProject] = []
    @State private var targets: [String: String] = [:]
    @State private var migrating: String?
    @State private var error: String?

    var body: some View {
        Section {
            ForEach(projects) { project in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(project.name)
                        Spacer()
                        Text(project.hosted ? "Kite 托管" : project.remote).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if project.hosted {
                        HStack {
                            TextField("正式远程，如 github.com/me/repo", text: target(project.id)).autocorrectionDisabled()
                            Button(migrating == project.id ? "正在迁移…" : "迁移") { migrate(project) }
                                .disabled(migrating != nil || (targets[project.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
            if projects.isEmpty { Text("还没有项目").foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        } header: {
            Text("项目")
        } footer: {
            Text("迁移把托管仓库的全部分支和标签推到正式远程，之后各工作机自动改用新地址，全部切换后删除托管仓库。迁移开始后托管仓库只读。")
        }
        .task { await load() }
    }

    private func target(_ id: String) -> Binding<String> {
        Binding { targets[id] ?? "" } set: { targets[id] = $0 }
    }

    private func load() async {
        do { projects = try await model.account.projects() } catch { self.error = error.localizedDescription }
    }

    private func migrate(_ project: AccountProject) {
        guard let remote = targets[project.id]?.trimmingCharacters(in: .whitespaces), !remote.isEmpty else { return }
        if SampleWorkspace.enabled { error = "预览数据不能迁移"; return }
        migrating = project.id
        error = nil
        Task {
            defer { migrating = nil }
            do {
                let migrated = try await model.account.migrate(project.id, to: remote)
                projects = projects.map { $0.id == migrated.id ? migrated : $0 }
                targets[project.id] = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
