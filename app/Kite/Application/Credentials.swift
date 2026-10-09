import SwiftUI
import UniformTypeIdentifiers

/// 账号里的一条凭据：类型决定由谁取用，项目为空表示账号共享。保密内容只在新建或替换时提交，之后只看到公开信息。
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

extension KiteAccount {
    func credentials(type: String, projectID: String = "") async throws -> [AccountCredential] {
        try await request("/api/credentials?type=\(type)" + (projectID.isEmpty ? "" : "&projectId=\(projectID)"), as: [AccountCredential].self)
    }

    func createCredential(type: String, name: String, projectID: String = "", meta: [String: String] = [:], secret: [String: String]) async throws {
        struct Body: Encodable { let type: String; let name: String; let projectId: String?; let meta: [String: String]; let secret: [String: String] }
        let _: AccountCredential = try await request("/api/credentials", method: "POST",
            body: Body(type: type, name: name, projectId: projectID.isEmpty ? nil : projectID, meta: meta, secret: secret), as: AccountCredential.self)
    }

    /// 类型与范围不变；不提供的项保留原样。
    func updateCredential(_ id: String, name: String? = nil, meta: [String: String]? = nil, secret: [String: String]? = nil) async throws {
        struct Body: Encodable { let name: String?; let meta: [String: String]?; let secret: [String: String]? }
        let _: AccountCredential = try await request("/api/credentials/\(id)", method: "PUT",
            body: Body(name: name, meta: meta, secret: secret), as: AccountCredential.self)
    }

    func deleteCredential(_ id: String) async throws {
        let _: JSON = try await request("/api/credentials/\(id)", method: "DELETE", as: JSON.self)
    }
}

struct CredentialsLibrary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SectionPage(header: PaneHeader(title: ExtensionLibrary.credentials.title, subtitle: SidebarSection.extensions.title)) {
            Form {
                if model.account.signedIn {
                    GitAccountsSection()
                    SecretsSection()
                    ApiKeysSection()
                } else {
                    Section {
                        Text("登录 Kite 账号后管理 Git 授权、共享密钥和模型 API Key。")
                        Button("登录 Kite 账号") { model.openSettings(.account) }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
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
                        perform { try await model.account.deleteCredential(entry.id); try await load() }
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
                            try await model.account.updateCredential(existing.id, meta: ["kind": savedKind], secret: ["value": savedValue])
                        } else {
                            try await model.account.createCredential(type: "secret", name: savedName, projectID: scope,
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
            Text("密钥加密保存在 Kite 账号中，供所选范围内的 agent 执行命令时使用。保存后不显示内容；使用密钥的命令只返回执行状态，不显示输出。")
        }
        .disabled(working)
        .task {
            do { projects = try await model.account.projects() }
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
        let loaded = try await model.account.credentials(type: "secret", projectID: requested)
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

/// 额度查询支持的 API 供应商。
enum ApiProvider: String, CaseIterable, Identifiable {
    case openai, anthropic, deepseek

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
}

/// 保存一把模型 API Key 到 Kite 账号；各工作机查询额度时领取，命令里无法引用。
struct ApiKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var provider = ApiProvider.openai
    @State private var name = ""
    @State private var key = ""
    @State private var adminKey = ""
    @State private var phase = CardPhase.idle
    @FocusState private var focus: Field?

    private enum Field { case name, key, admin }

    private func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { !trimmed(key).isEmpty || (provider.acceptsAdminKey && !trimmed(adminKey).isEmpty) }

    var body: some View {
        CardSheet(title: "添加 API Key", subtitle: "保存到 Kite 账号，各工作机查询额度时使用", typing: focus != nil, close: { dismiss() }) {
            CardField(label: "供应商") {
                Menu {
                    ForEach(ApiProvider.allCases) { item in
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
            CardField(label: "API Key", focused: focus == .key,
                      note: provider.acceptsAdminKey ? "只想查询组织费用时可以留空，只填管理 Key。" : nil) {
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
            try await model.account.createCredential(type: "api", name: name, meta: ["provider": provider.rawValue], secret: secret)
            model.refreshAllModelAccounts()
            dismiss()
        }
    }
}

/// 资源库里的模型 API Key：列出公开信息，可添加和删除。
struct ApiKeysSection: View {
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
                            try await model.account.deleteCredential(entry.id)
                            model.refreshAllModelAccounts()
                            try await load()
                        }
                    }
                }
            }
            Button("添加 API Key") { adding = true }
            if let error = phase.error { Text(error).foregroundStyle(Theme.danger) }
        } header: {
            Text("模型 API")
        } footer: {
            Text("API Key 随 Kite 账号分发给各台工作机，只用于查询额度与余额，agent 执行的命令里无法引用。")
        }
        .disabled(phase.working)
        .task { $phase.run { try await load() } }
        .sheet(isPresented: $adding, onDismiss: { $phase.run { try await load() } }) {
            ApiKeySheet().environment(model).appAppearance()
        }
    }

    private func detail(_ entry: AccountCredential) -> String {
        let provider = ApiProvider(rawValue: entry.meta["provider"]?.string ?? "")?.title ?? "API"
        let hint = entry.meta["hint"]?.string.map { " · …\($0)" } ?? ""
        return provider + hint + (entry.meta["admin"]?.bool == true ? " · 含管理 Key" : "")
    }

    private func load() async throws { entries = try await model.account.credentials(type: "api") }
}
