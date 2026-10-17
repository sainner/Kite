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

/// 要存成项目密钥的环境变量文件：path 是在工作区里的路径。value 是从这台设备选的文件内容；
/// from 是在工作机上选的文件的绝对路径；都为空时按 path 从添加的文件夹读。工作机上的文件由添加项目的那台读，内容不经过 App。
struct ProjectEnvFile: Encodable, Equatable, Identifiable {
    let path: String
    var value: String? = nil
    var from: String? = nil
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

/// 用 GitHub 的设备码授权绑定 github.com：打开就向一台工作机要验证码，在 GitHub 页面输入后自动完成，授权完弹窗自己关掉。
/// 凭据只在工作机之间流转，App 只看到主机与账号名。
struct GitHubBindSheet: View {
    let bound: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var device: GitHubDevice?
    @State private var phase = CardPhase.working
    /// 换一次就重新要验证码。
    @State private var attempt = UUID()

    var body: some View {
        CardSheet(title: "绑定 GitHub", subtitle: "授权访问你的 GitHub 仓库，各工作机共用", close: { dismiss() }) {
            if let device {
                DeviceCodeView(code: device.userCode)
                CardNote("在 GitHub 页面输入这个验证码，授权后自动完成绑定。")
            } else if phase.working {
                HStack(spacing: 10) {
                    CardSpinner()
                    Text("正在获取验证码…")
                }
                .font(Theme.secondary)
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        } actions: {
            if let device {
                PaneHeaderButtonGroup {
                    Button { open(device) } label: {
                        PaneHeaderButtonLabel("打开 GitHub", systemImage: "arrow.up.right.square")
                    }
                    .help("打开 GitHub")
                }
            }
        } footer: {
            if device != nil || phase.error != nil {
                CardActions(primary: "重试", phase: .constant(phase), working: "等待授权完成…", action: restart)
            }
        }
        .task(id: attempt) { await authorize() }
    }

    private func open(_ device: GitHubDevice) {
        if let url = URL(string: device.verificationURI) { openURL(url) }
    }

    private func restart() {
        device = nil
        phase = .working
        attempt = UUID()
    }

    /// 要到验证码就打开 GitHub，再按服务端给的间隔轮询，授权完成、拒绝或过期即停。
    private func authorize() async {
        do {
            let device = try await model.startGitHub()
            try Task.checkCancellation()
            self.device = device
            open(device)
            var interval = device.interval
            while true {
                try await Task.sleep(for: .seconds(interval))
                switch try await model.pollGitHub(device) {
                case "pending": continue
                case "slow_down": interval += 5
                case "authorized":
                    bound()
                    dismiss()
                    return
                case "denied": throw KitedError(message: "GitHub 授权被拒绝")
                default: throw KitedError(message: "验证码已过期，请重试")
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            device = nil
            phase = .failed(error.localizedDescription, retry: restart)
        }
    }
}

extension AppModel {
    /// 用访问令牌绑定一个 Git 平台，同一主机只有一条 Git 凭据，已绑定就替换；不填用户名时由服务端补上默认的 oauth2。
    /// machineID 指定写到哪台工作机（马上要用它的那台，不等同步），为空时任一台。
    func bindGit(host: String, username: String, token: String, on machineID: String? = nil) async throws {
        var client: KitedClient?
        if let machineID {
            guard let connection = connections[machineID], connection.connected else { throw KitedError(message: "工作机未连接") }
            client = connection.client
        }
        let meta = username.isEmpty ? [:] : ["username": username]
        if let existing = try await credentials(type: "git", via: client).first(where: { $0.name == host }) {
            try await updateCredential(existing.id, meta: meta, secret: ["token": token], via: client)
        } else {
            try await createCredential(type: "git", name: host, meta: meta, secret: ["token": token], via: client)
        }
    }
}

/// 用访问令牌绑定一个 Git 平台，存好后由调用方接着做。访问远程时平台要求登录就地绑定它（给了 host）；
/// 凭据页绑定 GitHub 以外的平台时由用户填域名，换令牌时给 host。
struct GitLoginSheet: View {
    let host: String?
    /// 存到哪台工作机，为空时任一台，见 AppModel.bindGit。
    var machineID: String? = nil
    let bound: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var typedHost = ""
    @State private var username = ""
    @State private var token = ""
    @State private var phase = CardPhase.idle
    @FocusState private var focus: Field?

    private var target: String { host ?? typedHost.trimmingCharacters(in: .whitespaces).lowercased() }

    var body: some View {
        CardSheet(title: host.map { "登录 \($0)" } ?? "用访问令牌绑定", subtitle: "用访问令牌绑定 Git 平台，各工作机共用",
                  error: phase.error, typing: focus != nil, close: { dismiss() }) {
            if host == nil {
                CardField(label: "域名", focused: focus == .host) {
                    TextField("gitlab.com", text: $typedHost)
                        .literal().focused($focus, equals: .host)
                        .cardInput { focus = .host }
                }
            }
            CardField(label: "用户名（可选）", focused: focus == .username) {
                TextField("不填时用 oauth2", text: $username)
                    .literal().focused($focus, equals: .username)
                    .cardInput { focus = .username }
            }
            CardField(label: "访问令牌", focused: focus == .token, note: "在平台的个人设置里生成，要能读写仓库。") {
                SecureField("访问令牌", text: $token)
                    .focused($focus, equals: .token).onSubmit(save)
                    .cardInput { focus = .token }
            }
        } actions: {
            CardSheetAction(title: "保存", busy: phase.working, action: save)
                .disabled(phase.working || token.isEmpty || target.isEmpty)
        }
        .endsTyping(focus != nil) { focus = nil }
    }

    private func save() {
        guard !token.isEmpty, !target.isEmpty else { return }
        let host = target
        $phase.run {
            try await model.bindGit(host: host, username: username.trimmingCharacters(in: .whitespaces), token: token, on: machineID)
            dismiss()
            bound()
        }
    }

    private enum Field { case host, username, token }
}
