import SwiftUI
import UniformTypeIdentifiers

struct AccountSecret: Decodable, Identifiable {
    let name: String
    let kind: String
    let projectId: String?
    var id: String { name }
    var reference: String { "{\(projectId == nil ? "account" : "project").\(name)}" }
}

extension KiteAccount {
    func secrets(projectID: String) async throws -> [AccountSecret] {
        try await request("/api/secrets" + secretQuery(projectID), as: [AccountSecret].self)
    }

    func saveSecret(name: String, kind: String, value: String, projectID: String) async throws {
        var body = ["kind": kind, "value": value]
        if !projectID.isEmpty { body["projectId"] = projectID }
        let _: JSON = try await request("/api/secrets/\(name)", method: "PUT", body: body, as: JSON.self)
    }

    func deleteSecret(name: String, projectID: String) async throws {
        let _: JSON = try await request("/api/secrets/\(name)" + secretQuery(projectID), method: "DELETE", as: JSON.self)
    }

    private func secretQuery(_ projectID: String) -> String {
        projectID.isEmpty ? "" : "?projectId=\(projectID)"
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
                } else {
                    Section {
                        Text("登录 Kite 账号后管理 Git 授权和共享密钥。")
                        Button("登录 Kite 账号") { model.openSettings(.account) }
                    }
                }
                if let error = model.account.error { Text(error).foregroundStyle(Theme.danger) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}

struct SecretsSection: View {
    @Environment(AppModel.self) private var model
    @State private var projects: [AccountProject] = []
    @State private var entries: [AccountSecret] = []
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
                    Text(entry.kind == "file" ? "文件" : "文本").foregroundStyle(.secondary)
                    Button("替换") {
                        clearDraft()
                        name = entry.name
                        kind = entry.kind
                        editing = true
                    }
                    Button("删除", role: .destructive) {
                        let scope = projectID
                        perform { try await model.account.deleteSecret(name: entry.name, projectID: scope); try await load() }
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
                    perform {
                        try await model.account.saveSecret(name: savedName, kind: savedKind, value: savedValue, projectID: scope)
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
        let loaded = try await model.account.secrets(projectID: requested)
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
