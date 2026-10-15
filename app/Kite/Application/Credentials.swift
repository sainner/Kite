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

struct CredentialsLibrary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SectionPage(header: PaneHeader(title: ExtensionLibrary.credentials.title, subtitle: SidebarSection.extensions.title)) {
            Form {
                if model.account.signedIn {
                    GitAccountsSection()
                    SecretsSection()
                    KeysSection<ApiProvider>()
                    KeysSection<SpeechProvider>()
                } else {
                    Section {
                        Text("登录后管理 Git 授权、共享密钥、模型 API Key 和语音识别 Key。")
                        Button("去登录") { model.openSettings(.account) }
                    }
                }
            }
            .pageForm()
        }
    }
}

struct SecretsSection: View {
    @Environment(AppModel.self) private var model
    @State private var projects: [AccountProject] = []
    @State private var entries: [AccountCredential] = []
    @State private var projectID = ""
    @State private var name = ""
    @State private var kind = "text"
    @State private var value = ""
    @State private var fileName: String?
    @State private var editing = false
    @State private var importing = false
    @State private var working = false
    @State private var error: String?

    private var valid: Bool {
        name.range(of: "^[a-zA-Z][a-zA-Z0-9_-]{0,63}$", options: .regularExpression) != nil
            && validSecretValue(value)
    }

    private func validSecretValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf16.count <= 65_536 && !value.contains("\0")
    }

    var body: some View {
        Section {
            Picker("可用范围", selection: $projectID) {
                Text("账号共享 · 所有项目").tag("")
                ForEach(projects) { project in Text(project.name).tag(project.id) }
            }
            ForEach(entries) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.name)
                        Text(entry.reference).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Text(entry.meta["kind"]?.string == "file" ? "文件" : "文本").foregroundStyle(.secondary)
                    Button("替换") {
                        clearDraft()
                        name = entry.name
                        kind = entry.meta["kind"]?.string ?? "text"
                        editing = true
                    }
                    Button("删除", role: .destructive) {
                        perform { try await model.deleteCredential(entry.id); try await load() }
                    }
                }
            }
            DisclosureGroup("保存密钥", isExpanded: $editing) {
                TextField("名称，如 api_key 或 ssh_key", text: $name).autocorrectionDisabled()
                Text("名称以英文字母开头，可包含数字、下划线和短横线，最多 64 个字符。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("使用方式", selection: $kind) {
                    Text("文本 · 环境变量").tag("text")
                    Text("文件 · 临时文件路径").tag("file")
                }
                if kind == "text" {
                    SecureField("密钥内容", text: $value)
                } else {
                    Button(fileName ?? "选择密钥文件…") { importing = true }
                    Text("支持 UTF-8 文本文件，如 SSH 私钥；执行结束后删除临时副本。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(entries.contains { $0.name == name } ? "替换密钥" : "保存密钥") {
                    let savedName = name, savedKind = kind, savedValue = value, scope = projectID
                    let existing = entries.first { $0.name == savedName }
                    perform {
                        if let existing {
                            try await model.updateCredential(existing.id, meta: ["kind": savedKind], secret: ["value": savedValue])
                        } else {
                            try await model.createCredential(type: "secret", name: savedName, projectID: scope,
                                                                     meta: ["kind": savedKind], secret: ["value": savedValue])
                        }
                        clearDraft()
                        editing = false
                        try await load()
                    }
                }.disabled(!valid)
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        } header: {
            Text("共享密钥")
        } footer: {
            Text("密钥加密保存在你的工作机上、在工作机之间同步，供所选范围内的 agent 执行命令时使用。保存后不显示内容；使用密钥的命令只返回执行状态，不显示输出。")
        }
        .disabled(working)
        .task {
            do { projects = try await model.registeredProjects() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
        .task(id: projectID) {
            entries = []
            clearDraft()
            error = nil
            do { try await load() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: kind) { _, _ in value = ""; fileName = nil }
        .onDisappear { clearDraft() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 262_144 else {
                    throw KitedError(message: "密钥文件过大", status: 400)
                }
                let text = try String(contentsOf: url, encoding: .utf8)
                guard validSecretValue(text) else {
                    throw KitedError(message: "请选择不超过 65536 个字符的 UTF-8 密钥文件", status: 400)
                }
                value = text
                fileName = url.lastPathComponent
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    private func clearDraft() { name = ""; value = ""; fileName = nil }

    private func load() async throws {
        let requested = projectID
        let loaded = try await model.credentials(type: "secret", projectID: requested)
        guard requested == projectID else { return }
        entries = loaded
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do { try await action() }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// 一类带 Key 的凭据（模型 API、语音识别）的供应商，连同这一类在资源库和添加表单里的文案。
protocol KeyProvider: RawRepresentable<String>, CaseIterable, Identifiable, Hashable where AllCases: RandomAccessCollection {
    /// 工作机上的凭据类型。
    static var type: String { get }
    static var header: String { get }
    static var footer: String { get }
    /// 添加按钮和表单的标题。
    static var addTitle: String { get }
    static var sheetSubtitle: String { get }
    var title: String { get }
    /// 能另填组织管理 Key。
    var acceptsAdminKey: Bool { get }
    /// API Key 输入框下的说明。
    var keyNote: String? { get }
    /// 添加、删除以后要跟着刷新的。
    @MainActor static func changed(_ model: AppModel)
}

extension KeyProvider {
    @MainActor static func changed(_ model: AppModel) {}
}

/// 额度查询支持的 API 供应商。
nonisolated enum ApiProvider: String, KeyProvider {
    case openai, anthropic, deepseek

    static let type = "api"
    static let header = "模型 API"
    static let footer = "API Key 加密保存在工作机上、在工作机之间同步，只用于查询额度与余额，agent 执行的命令里无法引用。"
    static let addTitle = "添加 API Key"
    static let sheetSubtitle = "保存到工作机，各工作机查询额度时使用"
    var id: Self { self }
    var title: String {
        switch self {
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .deepseek: "DeepSeek"
        }
    }
    /// DeepSeek 用调用 Key 查余额；OpenAI、Anthropic 的组织费用要管理 Key。
    var acceptsAdminKey: Bool { self != .deepseek }
    var keyNote: String? { acceptsAdminKey ? "只想查询组织费用时可以留空，只填管理 Key。" : nil }
    @MainActor static func changed(_ model: AppModel) { model.refreshAllModelAccounts() }
}

/// 语音识别支持的供应商。
nonisolated enum SpeechProvider: String, KeyProvider {
    case dashscope

    static let type = "speech"
    static let header = "语音识别"
    static let footer = "语音识别 Key 加密保存在工作机上、在工作机之间同步，只用于识别语音输入，agent 执行的命令里无法引用。"
    static let addTitle = "添加语音识别 Key"
    static let sheetSubtitle = "保存到工作机，各工作机识别语音输入时使用"
    var id: Self { self }
    var title: String {
        switch self {
        case .dashscope: "千问（百炼）"
        }
    }
    var acceptsAdminKey: Bool { false }
    var keyNote: String? { "百炼控制台的 API Key，北京地域。" }
}

/// 保存一把 Key 到工作机；查询额度、识别语音时使用，命令里无法引用。
struct KeySheet<Provider: KeyProvider>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var provider = Provider.allCases.first!
    @State private var name = ""
    @State private var key = ""
    @State private var adminKey = ""
    @State private var phase = CardPhase.idle
    @FocusState private var focus: Field?

    private enum Field { case name, key, admin }

    private func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { !trimmed(key).isEmpty || (provider.acceptsAdminKey && !trimmed(adminKey).isEmpty) }

    var body: some View {
        CardSheet(title: Provider.addTitle, subtitle: Provider.sheetSubtitle, typing: focus != nil, close: { dismiss() }) {
            CardField(label: "供应商") {
                Menu {
                    ForEach(Provider.allCases) { item in
                        Button(item.title) { provider = item }
                    }
                } label: {
                    Text(provider.title)
                }
                .menuStyle(.button).buttonStyle(CardSelectStyle()).menuIndicator(.hidden).clickPointer()
            }
            CardField(label: "名称", focused: focus == .name, note: "用来区分同一供应商的多把 Key，留空时使用供应商名。") {
                TextField(provider.title, text: $name)
                    .focused($focus, equals: .name).onSubmit(save)
                    .cardInput { focus = .name }
            }
            CardField(label: "API Key", focused: focus == .key, note: provider.keyNote) {
                SecureField("粘贴 API Key", text: $key)
                    .focused($focus, equals: .key).onSubmit(save)
                    .cardInput { focus = .key }
            }
            if provider.acceptsAdminKey {
                CardField(label: "组织管理 Key（可选）", focused: focus == .admin, note: "用于查询本月组织费用，需要组织管理员创建。") {
                    SecureField("粘贴管理 Key", text: $adminKey)
                        .focused($focus, equals: .admin).onSubmit(save)
                        .cardInput { focus = .admin }
                }
            }
        } footer: {
            CardActions(primary: "保存", enabled: valid, phase: $phase, action: save)
        }
        .endsTyping(focus != nil) { focus = nil }
        .onChange(of: provider) { _, value in if !value.acceptsAdminKey { adminKey = "" } }
    }

    private func save() {
        guard valid else { return }
        var secret: [String: String] = [:]
        if !trimmed(key).isEmpty { secret["key"] = trimmed(key) }
        if provider.acceptsAdminKey, !trimmed(adminKey).isEmpty { secret["adminKey"] = trimmed(adminKey) }
        let name = trimmed(name).isEmpty ? provider.title : trimmed(name)
        let provider = provider
        $phase.run {
            try await model.createCredential(type: Provider.type, name: name, meta: ["provider": provider.rawValue], secret: secret)
            Provider.changed(model)
            dismiss()
        }
    }
}

/// 资源库里一类带 Key 的凭据：列出公开信息，可添加和删除。
struct KeysSection<Provider: KeyProvider>: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [AccountCredential] = []
    @State private var adding = false
    @State private var phase = CardPhase.idle

    var body: some View {
        Section {
            ForEach(entries) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.name)
                        Text(detail(entry)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("删除", role: .destructive) {
                        $phase.run {
                            try await model.deleteCredential(entry.id)
                            Provider.changed(model)
                            try await load()
                        }
                    }
                }
            }
            Button(Provider.addTitle) { adding = true }
            if let error = phase.error { Text(error).foregroundStyle(Theme.danger) }
        } header: {
            Text(Provider.header)
        } footer: {
            Text(Provider.footer)
        }
        .disabled(phase.working)
        .task { $phase.run { try await load() } }
        .sheet(isPresented: $adding, onDismiss: { $phase.run { try await load() } }) {
            KeySheet<Provider>().environment(model).appAppearance()
        }
    }

    private func detail(_ entry: AccountCredential) -> String {
        let provider = Provider(rawValue: entry.meta["provider"]?.string ?? "")?.title ?? Provider.header
        let hint = entry.meta["hint"]?.string.map { " · …\($0)" } ?? ""
        return provider + hint + (entry.meta["admin"]?.bool == true ? " · 含管理 Key" : "")
    }

    private func load() async throws { entries = try await model.credentials(type: Provider.type) }
}
