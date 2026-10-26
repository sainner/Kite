import SwiftUI
import UniformTypeIdentifiers

/// 工作机上的一条凭据：类型决定由谁取用，项目为空表示账号共享。保密内容只在新建或替换时提交，之后只看到公开信息。
struct AccountCredential: Decodable, Identifiable, Equatable {
    let id: String
    let type: String
    let name: String
    let projectId: String?
    let meta: [String: JSON]
    let updatedAt: Double

    /// 共享密钥在命令里的引用。
    var reference: String { "{\(projectId == nil ? "account" : "project").\(name)}" }
}

/// 资源库的凭据页：密钥、Git 账号、第三方 API Key 各一个固定窗口，同设备的账号页。凭据属于 Kite 账号，经任一台连着的工作机读写，
/// 不跟某台工作机的连接提示，读写失败写在各窗口的信息区。
struct CredentialPane: View {
    let pane: Pane
    @Environment(AppModel.self) private var model

    var body: some View {
        let title = PaneGroup.credentials(model.credentialWindows).appearance(of: pane).name
        switch pane.id {
        case "git": GitAccountsPane(title: title)
        case "keys": KeysPane(title: title)
        default: SecretsPane(title: title)
        }
    }
}

/// 新建或替换一条凭据的弹窗。
private enum CredentialEdit: Identifiable {
    case add
    case replace(AccountCredential)

    var id: String {
        switch self {
        case .add: "add"
        case .replace(let entry): entry.id
        }
    }

    var replacing: AccountCredential? { if case .replace(let entry) = self { entry } else { nil } }
}

/// 凭据的一个窗口：副行写这类凭据做什么用，右上角添加，正文是一组或几组凭据。没登录、读写失败在信息区；
/// 一条都没有时窗口开点阵，正文中间是这一类的点阵图案，配一句标题、一句怎么添加：平时文字在图案下面，上下放不下时放右边，
/// 再放不下只留文字。没登录时右上角换成去登录。登录了才读，换账号、连接变了重读。
private struct CredentialWindow<Content: View>: View {
    let title: String
    let purpose: String
    let glyph: CredentialGlyph
    /// 一条都没有时图案旁边的标题，和下一行写怎么添加。
    let empty: String
    var hint = "从右上角添加"
    /// 还没读到是 nil。
    let isEmpty: Bool?
    let error: String?
    let actions: PaneHeaderActions
    let reload: () async -> Void
    @ViewBuilder let content: Content
    @Environment(AppModel.self) private var model
    @Environment(\.self) private var environment

    private var notice: PaneNotice? {
        if !model.account.signedIn { return .info("登录后管理凭据", symbol: "person.crop.circle") }
        return error.map(PaneNotice.failure)
    }

    var body: some View {
        PaneWindow(header: PaneHeader(title: title, subtitle: purpose), usesDots: isEmpty == true, notice: notice,
                   actions: model.account.signedIn ? actions : signIn) {
            if isEmpty == true {
                ZStack {
                    Color.clear.dotTrace()
                    ViewThatFits {
                        VStack(spacing: Metrics.padding * 2) {
                            DotMask(figure: glyphFigure)
                            emptyText(.center)
                        }
                        HStack(spacing: Metrics.padding * 2) {
                            DotMask(figure: glyphFigure)
                            emptyText(.leading)
                        }
                        emptyText(.center)
                    }
                    .padding(Metrics.padding)
                }
                // 空着的控制区浮在上面，图案铺到它后面，不让它占掉高度，同订阅窗口
                .ignoresSafeArea(.container, edges: .bottom)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) { content }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Metrics.padding)
                        .separateScrollPocket()
                }
            }
        } controls: { _ in
            EmptyView()
        }
        .task(id: "\(model.account.user?.id ?? ""):\(model.connectionRevision)") {
            if model.account.signedIn { await reload() }
        }
    }

    private var glyphFigure: DotFigure {
        let accent = DotColor(Color.accentColor.resolve(in: environment))
        return DotFigure(glyph.lines, colors: ["B": accent, "b": accent], shapes: ["b": 0.5])
    }

    private func emptyText(_ alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(empty).font(Theme.body.weight(.semibold))
            Text(hint).font(Theme.secondary).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .fixedSize()
    }

    private var signIn: PaneHeaderActions {
        PaneHeaderActions(groups: [[PaneHeaderAction(title: "去登录", systemImage: "person.crop.circle") { model.openSettings(.account) }]])
    }
}

/// 空窗口正文里的点阵图案，逐行字符画：B 是满格，b 是半格的细线，其余是静息的点。
nonisolated enum CredentialGlyph {
    case key, branch, chip

    var lines: [String] {
        switch self {
        case .key: [
            "..BBB..",
            ".B...B.",
            "B.....B",
            "B.....B",
            ".B...B.",
            "..BBB..",
            "...B...",
            "...BB..",
            "...B...",
            "...BBB.",
            "...B...",
        ]
        case .branch: [
            ".B...B.",
            "BBB.BBB",
            ".B...B.",
            ".b..b..",
            ".b.b...",
            ".bb....",
            ".B.....",
            "BBB....",
            ".B.....",
        ]
        case .chip: [
            "..b.b.b..",
            ".BBBBBBB.",
            "bB.....Bb",
            ".B.BBB.B.",
            "bB.BBB.Bb",
            ".B.BBB.B.",
            "bB.....Bb",
            ".BBBBBBB.",
            "..b.b.b..",
        ]
        }
    }
}

/// 一条凭据：前面是厂商或平台的标志（共享密钥没有），名称，下面一行公开信息；右边先是标签（第三方 Key 能做什么），
/// 再是放替换、删除这类操作的更多菜单。
private struct CredentialRow<Actions: View>: View {
    var logo: ImageResource?
    let name: String
    let detail: Text
    var tags: [String] = []
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            if let logo { TablerIcon(logo, size: 20) }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1).truncationMode(.middle)
                detail.font(Theme.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !tags.isEmpty { TagRow(titles: tags) }
            Menu { actions } label: {
                PaneButtonLabel("更多操作", systemImage: "ellipsis")
            }
            .menuStyle(.button).buttonStyle(PaneButtonStyle()).menuIndicator(.hidden).fixedSize()
            .help("更多操作")
        }
    }
}

/// 一个凭据窗口的读写：增删一次一个，做完重新读取；失败原因放窗口的信息区。
private struct CredentialLoad {
    var working = false
    var error: String?
}

private extension Binding where Value == CredentialLoad {
    /// 读一次列表：成功清掉原来的失败，失败记下原因。
    func read(_ action: () async throws -> Void) async {
        do {
            try await action()
            wrappedValue.error = nil
        } catch is CancellationError {
        } catch {
            wrappedValue.error = "读取失败：\(error.localizedDescription)"
        }
    }

    /// 增删一条，做完重新读取。
    func run(_ action: @escaping () async throws -> Void, reload: @escaping () async -> Void) {
        guard !wrappedValue.working else { return }
        wrappedValue.working = true
        wrappedValue.error = nil
        Task {
            defer { wrappedValue.working = false }
            do {
                try await action()
                await reload()
            } catch {
                wrappedValue.error = error.localizedDescription
            }
        }
    }
}

/// 共享密钥：账号共享一组在前，有密钥的项目各一组。
private struct SecretsPane: View {
    let title: String
    @Environment(AppModel.self) private var model
    @State private var groups: [SecretGroup]?
    @State private var load = CredentialLoad()
    @State private var edit: CredentialEdit?

    private struct SecretGroup: Identifiable {
        /// 账号共享为空，项目专用为项目 ID。
        let id: String
        let title: String
        let entries: [AccountCredential]
    }

    var body: some View {
        CredentialWindow(title: title, purpose: "agent 执行命令时按引用使用", glyph: .key, empty: "还没有密钥",
                         isEmpty: groups.map(\.isEmpty), error: load.error,
                         actions: PaneHeaderActions(groups: [[PaneHeaderAction(title: "添加密钥", systemImage: "plus", disabled: load.working) {
                             edit = .add
                         }]]), reload: reload) {
            ForEach(groups ?? []) { group in
                CardSection(group.title) {
                    ForEach(group.entries) { entry in
                        CredentialRow(name: entry.name, detail: detail(entry)) {
                            MenuButton("替换内容…", systemImage: "arrow.triangle.2.circlepath") { edit = .replace(entry) }
                            MenuButton("删除", systemImage: "trash", role: .destructive) {
                                $load.run({ try await model.deleteCredential(entry.id) }, reload: reload)
                            }
                        }
                    }
                }
                .disabled(load.working)
            }
        }
        .sheet(item: $edit) { edit in
            SecretSheet(replacing: edit.replacing) { Task { await reload() } }
                .environment(model).appAppearance()
        }
    }

    private func detail(_ entry: AccountCredential) -> Text {
        let use = entry.meta["path"]?.string.map { "写到 \($0)" } ?? (entry.meta["kind"]?.string == "file" ? "文件" : "文本")
        return Text("\(Text(entry.reference).monospaced()) · \(use)")
    }

    /// 账号共享与各项目的一起读，按项目登记的顺序分组。
    private func reload() async {
        let model = model
        let projects = model.account.registeredProjects
        await $load.read {
            let found = try await withThrowingTaskGroup(of: (String, [AccountCredential]).self) { group in
                for id in [""] + projects.map(\.id) {
                    group.addTask { (id, try await model.credentials(type: "secret", projectID: id)) }
                }
                var found: [String: [AccountCredential]] = [:]
                for try await (id, entries) in group { found[id] = entries }
                return found
            }
            let label = model.projectLabels()
            groups = ([("", "账号共享")] + projects.map { ($0.id, label($0.project)) }).compactMap { id, title in
                guard let entries = found[id], !entries.isEmpty else { return nil }
                return SecretGroup(id: id, title: title, entries: entries)
            }
        }
    }
}

/// 添加或替换一条共享密钥。替换只换内容，名称、范围、类型与工作区里的路径不变。
private struct SecretSheet: View {
    let replacing: AccountCredential?
    let saved: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    /// 账号共享为空。
    @State private var projectID = ""
    @State private var kind = "text"
    @State private var path = ""
    @State private var value = ""
    @State private var fileName: String?
    @State private var importing = false
    @State private var phase = CardPhase.idle
    @FocusState private var focus: Field?

    private enum Field { case name, path, value }

    private var currentKind: String { replacing?.meta["kind"]?.string ?? kind }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedPath: String { path.trimmingCharacters(in: .whitespaces) }
    private var valid: Bool {
        validSecretValue(value)
            && (replacing != nil || trimmedName.range(of: "^[a-zA-Z][a-zA-Z0-9_-]{0,63}$", options: .regularExpression) != nil)
    }
    var body: some View {
        let projects = model.account.registeredProjects
        let label = model.projectLabels()
        CardSheet(title: replacing.map { "替换 \($0.name)" } ?? "添加密钥",
                  subtitle: replacing == nil ? "供 agent 执行命令时按引用使用" : "换成新的内容",
                  error: phase.error, typing: focus != nil, close: { dismiss() }) {
            if replacing == nil {
                CardField(label: "名称", focused: focus == .name, note: "英文字母开头，可含数字、下划线和短横线，最多 64 个字符。") {
                    TextField("api_key", text: $name)
                        .literal().focused($focus, equals: .name).onSubmit(save)
                        .cardInput { focus = .name }
                }
                CardField(label: "可用范围") {
                    Menu {
                        Button("账号共享 · 所有项目") { projectID = "" }
                        Section("项目专用") {
                            ForEach(projects) { project in
                                Button(label(project.project)) { projectID = project.id }
                            }
                        }
                    } label: {
                        Text(projects.first { $0.id == projectID }.map { "\(label($0.project)) · 项目专用" } ?? "账号共享 · 所有项目")
                    }
                    .menuStyle(.button).buttonStyle(CardSelectStyle()).menuIndicator(.hidden)
                }
                CardField(label: "使用方式") {
                    Menu {
                        Button("文本 · 环境变量") { kind = "text" }
                        Button("文件 · 临时文件路径") { kind = "file" }
                    } label: {
                        Text(kind == "file" ? "文件 · 临时文件路径" : "文本 · 环境变量")
                    }
                    .menuStyle(.button).buttonStyle(CardSelectStyle()).menuIndicator(.hidden)
                }
                if kind == "file", !projectID.isEmpty {
                    CardField(label: "工作区里的路径（可选）", focused: focus == .path,
                              note: "每次建工作区时把内容写到这里，如 .env，供开发服务器、测试读取；agent 能读到这个文件，不想让模型看到的不要设。") {
                        TextField(".env", text: $path)
                            .literal().focused($focus, equals: .path).onSubmit(save)
                            .cardInput { focus = .path }
                    }
                }
            }
            if currentKind == "file" {
                CardField(label: "内容", note: "UTF-8 文本文件，如 SSH 私钥或 .env。") {
                    Button { importing = true } label: {
                        HStack(spacing: 8) {
                            Text(fileName ?? "选择文件…")
                                .foregroundStyle(fileName == nil ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "folder").font(Theme.caption).foregroundStyle(.secondary)
                        }
                        .font(Theme.body)
                        .padding(.horizontal, 12)
                        .frame(minHeight: CardMetrics.fieldHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pointingPlain)
                }
            } else {
                CardField(label: "内容", focused: focus == .value) {
                    SecureField("粘贴密钥内容", text: $value)
                        .focused($focus, equals: .value).onSubmit(save)
                        .cardInput { focus = .value }
                }
            }
            CardNote("加密保存在工作机上、在工作机之间同步。保存后不再显示内容，用到它的命令只返回执行状态，不显示输出。")
        } actions: {
            [[.sheet("保存", busy: phase.working, disabled: !valid || phase.working, action: save)]]
        }
        .endsTyping(focus != nil) { focus = nil }
        .onChange(of: kind) { _, _ in value = ""; fileName = nil }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get()
                value = try readSecretText(url)
                fileName = url.lastPathComponent
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription) { importing = true }
            }
        }
    }

    private func save() {
        guard valid else { return }
        var meta = ["kind": kind]
        if kind == "file", !projectID.isEmpty, !trimmedPath.isEmpty { meta["path"] = trimmedPath }
        let value = value, name = trimmedName, scope = projectID, replacing = replacing
        $phase.run {
            if let replacing {
                // 不带 meta：工作机沿用原来的类型与路径
                try await model.updateCredential(replacing.id, secret: ["value": value])
            } else {
                try await model.createCredential(type: "secret", name: name, projectID: scope, meta: meta, secret: ["value": value])
            }
            saved()
            dismiss()
        }
    }
}

/// 绑定的 Git 平台：GitHub 走设备码授权，其他平台用访问令牌。
private struct GitAccountsPane: View {
    let title: String
    @Environment(AppModel.self) private var model
    @State private var accounts: [AccountCredential]?
    @State private var load = CredentialLoad()
    @State private var sheet: GitSheet?

    private enum GitSheet: Identifiable {
        case github
        /// 给了主机是给这个平台换令牌，否则由用户填域名。
        case token(String?)

        var id: String {
            switch self {
            case .github: "github"
            case .token(let host): "token:\(host ?? "")"
            }
        }
    }

    var body: some View {
        CredentialWindow(title: title, purpose: "克隆与推送时使用", glyph: .branch, empty: "还没有绑定 Git 平台",
                         hint: "从右上角绑定 GitHub 或其他平台",
                         isEmpty: accounts.map(\.isEmpty), error: load.error, actions: actions, reload: reload) {
            if let accounts {
                CardSection {
                    ForEach(accounts) { account in
                        CredentialRow(logo: logo(account.name), name: account.name, detail: Text(account.meta["username"]?.string ?? "")) {
                            if account.name == "github.com" {
                                MenuButton("重新授权…", systemImage: "arrow.triangle.2.circlepath") { sheet = .github }
                            } else {
                                MenuButton("更换令牌…", systemImage: "arrow.triangle.2.circlepath") { sheet = .token(account.name) }
                            }
                            MenuButton("解除绑定", systemImage: "trash", role: .destructive) {
                                $load.run({ try await model.deleteCredential(account.id) }, reload: reload)
                            }
                        }
                    }
                }
                .disabled(load.working)
            }
        }
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .github: GitHubBindSheet { Task { await reload() } }
                case .token(let host): GitLoginSheet(host: host) { Task { await reload() } }
                }
            }
            .environment(model).appAppearance()
        }
    }

    /// GitHub、GitLab 用各自的标志，其他平台是通用的分支图标。
    private func logo(_ host: String) -> ImageResource {
        switch host {
        case "github.com": .tablerBrandGithub
        case "gitlab.com": .tablerBrandGitlab
        default: .tablerGitBranch
        }
    }

    private var actions: PaneHeaderActions {
        PaneHeaderActions(menus: AnyView(PaneHeaderButtonGroup {
            Menu {
                MenuButton("绑定 GitHub", systemImage: "person.badge.key") { sheet = .github }
                MenuButton("用访问令牌绑定其他平台", systemImage: "key") { sheet = .token(nil) }
            } label: {
                PaneHeaderButtonLabel("绑定 Git 平台", systemImage: "plus")
            }
            .help("绑定 Git 平台")
            .disabled(load.working)
        }))
    }

    private func reload() async {
        await $load.read { accounts = try await model.credentials(type: "git") }
    }
}

/// 能在凭据页添加 Key 的第三方服务。供应商决定工作机上的凭据类型：DeepSeek 是模型 API（`api`），千问是语音识别（`speech`），
/// Tavily、Exa 是搜索服务（`search`）；uses 是这把 Key 在 Kite 里拿来做什么，列表和添加表单里标成标签。
nonisolated enum KeyService: String, CaseIterable, Identifiable {
    case deepseek, dashscope, tavily, exa

    /// 窗口里列的几类凭据。
    static let types = Set(allCases.map(\.type))

    /// 认不出的（旧版本存的、类型对不上的）为 nil。
    init?(_ credential: AccountCredential) {
        guard let service = KeyService(rawValue: credential.meta["provider"]?.string ?? ""), service.type == credential.type else { return nil }
        self = service
    }

    var id: Self { self }
    var type: String {
        switch self {
        case .deepseek: "api"
        case .dashscope: "speech"
        case .tavily, .exa: "search"
        }
    }
    var title: String {
        switch self {
        case .deepseek: "DeepSeek"
        case .dashscope: "千问（百炼）"
        case .tavily: "Tavily"
        case .exa: "Exa"
        }
    }
    var uses: [String] {
        switch self {
        case .deepseek: ["模型", "网页搜索", "余额"]
        case .dashscope: ["语音识别"]
        case .tavily, .exa: ["网页搜索"]
        }
    }
    /// API Key 输入框下的说明。
    var keyNote: String? {
        switch self {
        case .deepseek: nil
        case .dashscope: "百炼控制台的 API Key，北京地域。"
        case .tavily: "Tavily 控制台的 API Key，以 tvly- 开头。"
        case .exa: "Exa 控制台的 API Key。"
        }
    }
    /// 添加、替换、删除以后要跟着刷新的：DeepSeek 的 Key 带出额度页的余额账号。
    @MainActor func changed(_ model: AppModel) {
        if self == .deepseek { model.refreshAllModelAccounts() }
    }
}

/// 保存一把第三方 Key 到工作机，命令里无法引用。替换时供应商不变，填的 Key 换掉原来的。
struct KeySheet: View {
    var replacing: AccountCredential?
    var saved: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var service: KeyService
    @State private var name: String
    @State private var key = ""
    @State private var phase = CardPhase.idle
    @FocusState private var focus: Field?

    private enum Field { case name, key }

    init(replacing: AccountCredential? = nil, saved: @escaping () -> Void = {}) {
        self.replacing = replacing
        self.saved = saved
        _service = State(initialValue: replacing.flatMap(KeyService.init) ?? .deepseek)
        _name = State(initialValue: replacing?.name ?? "")
    }

    private func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { !trimmed(key).isEmpty }

    var body: some View {
        CardSheet(title: replacing.map { "替换 \($0.name)" } ?? "添加 API Key",
                  subtitle: replacing == nil ? "模型、语音识别和网页搜索用的第三方 Key" : "换成新的 Key",
                  error: phase.error, typing: focus != nil, close: { dismiss() }) {
            CardField(label: "供应商") {
                Menu {
                    ForEach(KeyService.allCases) { item in
                        Button(item.title) { service = item }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(service.title)
                        Spacer(minLength: 0)
                        TagRow(titles: service.uses)
                    }
                }
                .menuStyle(.button).buttonStyle(CardSelectStyle()).menuIndicator(.hidden)
                .disabled(replacing != nil)
            }
            CardField(label: "名称", focused: focus == .name, note: "用来区分同一供应商的多把 Key，留空时使用供应商名。") {
                TextField(service.title, text: $name)
                    .focused($focus, equals: .name).onSubmit(save)
                    .cardInput { focus = .name }
            }
            CardField(label: "API Key", focused: focus == .key, note: service.keyNote) {
                SecureField("粘贴 API Key", text: $key)
                    .focused($focus, equals: .key).onSubmit(save)
                    .cardInput { focus = .key }
            }
        } actions: {
            [[.sheet("保存", busy: phase.working, disabled: !valid || phase.working, action: save)]]
        }
        .endsTyping(focus != nil) { focus = nil }
    }

    private func save() {
        guard valid else { return }
        let secret = ["key": trimmed(key)]
        let name = trimmed(name).isEmpty ? service.title : trimmed(name)
        let service = service, replacing = replacing
        $phase.run {
            if let replacing {
                try await model.updateCredential(replacing.id, name: name, secret: secret)
            } else {
                try await model.createCredential(type: service.type, name: name, meta: ["provider": service.rawValue], secret: secret)
            }
            service.changed(model)
            saved()
            dismiss()
        }
    }
}

/// 第三方 Key 的窗口：模型 API、语音识别、搜索服务三类凭据列在一起，每把右边用标签写它能做什么；可添加、替换和删除。
private struct KeysPane: View {
    let title: String
    @Environment(AppModel.self) private var model
    @State private var entries: [AccountCredential]?
    @State private var load = CredentialLoad()
    @State private var edit: CredentialEdit?

    var body: some View {
        CredentialWindow(title: title, purpose: "模型、语音识别和网页搜索用的 Key，命令里无法引用", glyph: .chip, empty: "还没有 API Key",
                         isEmpty: entries.map(\.isEmpty), error: load.error,
                         actions: PaneHeaderActions(groups: [[PaneHeaderAction(title: "添加 API Key", systemImage: "plus", disabled: load.working) {
                             edit = .add
                         }]]), reload: reload) {
            if let entries {
                CardSection {
                    ForEach(entries) { entry in
                        let service = KeyService(entry)
                        CredentialRow(logo: ThreadModelMenu.logo(vendor: entry.meta["provider"]?.string), name: entry.name,
                                      detail: Text(detail(entry, service)), tags: service?.uses ?? []) {
                            MenuButton("替换 Key…", systemImage: "arrow.triangle.2.circlepath") { edit = .replace(entry) }
                            MenuButton("删除", systemImage: "trash", role: .destructive) {
                                $load.run({
                                    try await model.deleteCredential(entry.id)
                                    service?.changed(model)
                                }, reload: reload)
                            }
                        }
                    }
                }
                .disabled(load.working)
            }
        }
        .sheet(item: $edit) { edit in
            KeySheet(replacing: edit.replacing) { Task { await reload() } }
                .environment(model).appAppearance()
        }
    }

    private func detail(_ entry: AccountCredential, _ service: KeyService?) -> String {
        let hint = entry.meta["hint"]?.string.map { " · …\($0)" } ?? ""
        // 旧版本存的 OpenAI、Anthropic Key 工作机已不再使用，留着只为能删掉。
        return (service?.title ?? "\(entry.meta["provider"]?.string ?? "未知供应商") · 已不再使用") + hint
    }

    /// 一次读回各类，留下这几类，按供应商的顺序排，同一家按名称。
    private func reload() async {
        await $load.read {
            let all = try await model.credentials(type: nil).filter { KeyService.types.contains($0.type) }
            let order = { (entry: AccountCredential) in KeyService(entry).flatMap { KeyService.allCases.firstIndex(of: $0) } ?? KeyService.allCases.count }
            entries = all.sorted { (order($0), $0.name) < (order($1), $1.name) }
        }
    }
}

/// 密钥内容与工作机的规则一致：1–65536 个 UTF-16 单元的文本，不含 NUL。
func validSecretValue(_ value: String) -> Bool {
    !value.isEmpty && value.utf16.count <= 65_536 && !value.contains("\0")
}

/// 从这台设备选的文件读出密钥内容（如 SSH 私钥、.env），不合规则时报错。
func readSecretText(_ url: URL) throws -> String {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 262_144 else {
        throw KitedError(message: "密钥文件过大", status: 400)
    }
    let text = try String(contentsOf: url, encoding: .utf8)
    guard validSecretValue(text) else { throw KitedError(message: "请选择不超过 65536 个字符的 UTF-8 文本文件", status: 400) }
    return text
}
