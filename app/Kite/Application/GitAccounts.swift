import SwiftUI

/// 项目登记表里的项目，存在工作机上、随工作机之间同步。没有远程的项目可以之后再设远程，项目 ID 不变。
struct AccountProject: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let remote: String?
    let icon: String?
    let color: String?
    /// 集成方式：merge（直接合入）或 pullRequest（提交 PR）；integrationReason 是按仓库情况自动选择时的理由。
    var integration: String? = nil
    var integrationReason: String? = nil
    /// 工作机睡眠、登出、重启或关机前，把这个项目里正在工作的工作区换到别的工作机。
    let autoHandover: Bool?
    /// 自动换机的目标须满足的环境，取值见 HandoverNeed。
    let handoverNeeds: [String]?

    var appearance: ProjectAppearance { ProjectAppearance(icon: icon ?? "folder", color: color ?? "primary") }
    var proposes: Bool { integration == "pullRequest" }
    /// 侧栏和新建工作区用的项目身份。
    var project: RemoteProject { RemoteProject(id: id, name: name, remote: remote, createdAt: 0) }
}

/// 添加项目的来源：远程地址，或某台工作机上的文件夹。
struct ProjectSource: Encodable, Equatable {
    var remote: String? = nil
    var path: String? = nil
}

/// 添加项目前的检查结果（kited 的 POST /project-registry/check）。
struct ProjectCheck: Decodable, Equatable {
    /// 归一化的远程地址；没有远程的文件夹为空。
    let remote: String?
    let integration: String
    let integrationReason: String?
    /// 文件夹里被忽略的环境变量文件，远程为空。
    let envFiles: [String]
    /// 同一远程已登记的项目。
    let existing: AccountProject?
}

/// 要存成项目密钥的环境变量文件：path 是在工作区里的路径；value 为空时由文件夹所在的工作机读，内容不经过 App。
struct ProjectEnvFile: Encodable, Equatable, Identifiable {
    let path: String
    var value: String? = nil
    var id: String { path }
}

struct GitHubDevice: Decodable, Equatable {
    let flow: String
    let userCode: String
    let verificationURI: String
    let interval: Int
    /// 发起授权的工作机：授权流程只在它那里。
    var machineID = ""

    private enum CodingKeys: String, CodingKey { case flow, userCode, verificationURI, interval }
}

struct GitHubRepository: Decodable, Identifiable, Equatable {
    let fullName: String
    let url: String
    let `private`: Bool
    var id: String { fullName }
}

struct GitAccountsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// 绑定的 Git 平台；凭据只在工作机之间流转，App 只看到主机与账号名。
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
                        perform { try await model.deleteCredential(account.id); try await load() }
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
                Button("绑定 GitHub") { perform { device = try await model.startGitHub() } }
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
            Text("绑定的凭据加密保存在工作机上、在工作机之间同步，用于克隆与推送。GitHub 授权覆盖该账号下的全部仓库。")
        }
        .disabled(working)
        .task { perform { try await load() } }
        .task(id: device?.flow) { await poll() }
    }

    private func load() async throws { accounts = try await model.credentials(type: "git") }

    /// 同一主机只有一条 Git 凭据，已绑定就替换。
    private func bind(host: String, username: String, token: String) async throws {
        // 不填用户名时由服务端补上默认的 oauth2
        let meta = username.isEmpty ? [:] : ["username": username]
        if let existing = accounts.first(where: { $0.name == host }) {
            try await model.updateCredential(existing.id, meta: meta, secret: ["token": token])
        } else {
            try await model.createCredential(type: "git", name: host, meta: meta, secret: ["token": token])
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
                switch try await model.pollGitHub(device) {
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
