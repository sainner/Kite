import SwiftUI

/// 工作机上一个 MCP 服务的配置，字段与 kited 的 `PUT /mcp/servers/:name` 一致（docs/kited.md「外部 MCP 服务」）。
nonisolated struct McpServerConfig: Codable, Equatable, Sendable {
    /// stdio 是这台工作机上的程序，http 是远程服务。
    var type: String
    var command: String?
    var args: [String]?
    var env: [String: String]?
    var cwd: String?
    var url: String?
    var headers: [String: String]?
    var description: String?
}

/// `GET /mcp` 里的一项：配置与此刻的连接状态。
nonisolated struct McpServerEntry: Decodable, Identifiable, Sendable {
    struct Status: Decodable, Sendable {
        struct Server: Decodable, Sendable {
            let name: String
            let version: String
        }
        let phase: McpPhase
        let message: String?
        let tools: Int?
        let `protocol`: String?
        let server: Server?
    }
    let name: String
    let config: McpServerConfig
    let status: Status
    var id: String { name }
}

nonisolated struct McpServerList: Decodable, Sendable {
    let servers: [McpServerEntry]
    /// 工作机上的清单文件读不了时的原因。
    var error: String?
}

/// 连接状态跟着每一行：连上为主题色，要处理的为警示色，其余灰色。
struct McpStatusLabel: View {
    let phase: McpPhase
    var detail: String?

    var body: some View {
        StatusDotLabel(title: detail.map { "\(phase.title) · \($0)" } ?? phase.title,
                       color: phase == .connected ? .accentColor : phase.needsAttention ? Theme.warning : .secondary,
                       warns: phase.needsAttention)
    }
}

/// 设置页的表单草稿：参数每行一个，环境变量每行一条 `名字=值`，请求头每行一条 `名字: 值`。
private struct McpServerDraft: Equatable {
    /// 改名前的名字；新增时为空。
    var original: String?
    var name = ""
    var type = "stdio"
    var command = ""
    var args: [String] = []
    var env: [String] = []
    var cwd = ""
    var url = ""
    var headers: [String] = []
    var description = ""

    init() {}

    init(_ entry: McpServerEntry) {
        let config = entry.config
        original = entry.name
        name = entry.name
        type = config.type
        command = config.command ?? ""
        args = config.args ?? []
        env = (config.env ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        cwd = config.cwd ?? ""
        url = config.url ?? ""
        headers = (config.headers ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        description = config.description ?? ""
    }

    private static func pairs(_ lines: [String], separator: Character) -> [String: String]? {
        var values: [String: String] = [:]
        for line in lines {
            guard let index = line.firstIndex(of: separator) else { continue }
            let key = line[..<index].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { values[key] = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces) }
        }
        return values.isEmpty ? nil : values
    }

    private static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var config: McpServerConfig {
        type == "http"
            ? McpServerConfig(type: "http", url: Self.text(url), headers: Self.pairs(headers, separator: ":"), description: Self.text(description))
            : McpServerConfig(type: "stdio", command: Self.text(command), args: args.isEmpty ? nil : args, env: Self.pairs(env, separator: "="),
                              cwd: Self.text(cwd), description: Self.text(description))
    }

    var incomplete: Bool {
        Self.text(name) == nil || (type == "http" ? Self.text(url) == nil : Self.text(command) == nil)
    }
}

/// 工作机的 MCP 页：这台工作机装的外部 MCP 服务，增删改、看连接状态、粘贴别处的 mcpServers 配置。
/// 服务装在这台工作机上，谁能用在角色、代理和项目约束里开关；新装的服务默认谁都不能用。
struct McpSettingsPage: View {
    let connection: WorkerConnection
    @State private var servers: [McpServerEntry]?
    /// 正在新增或修改的服务。
    @State private var editing: McpServerDraft?
    @State private var pasting = false
    @State private var pasted = ""
    @State private var removing: String?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            if let draft = Binding($editing) {
                editor(draft)
            } else if pasting {
                importSection
            } else {
                listSection
            }
            if let error { Section { Text(error).foregroundStyle(Theme.danger) } }
        }
        .pageForm()
        .task(id: "\(connection.id) \(connection.mcpRevision)") { await load() }
        .confirmationDialog("删除 MCP 服务 \(removing ?? "")？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let removing { run { try await remove(removing) } } }
        } message: {
            Text("开着它的代理下一次请求起就没有它的工具了。")
        }
    }

    // MARK: - 列表

    private var listSection: some View {
        Section {
            ForEach(servers ?? []) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                        Text(summary(entry.config)).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        McpStatusLabel(phase: entry.status.phase, detail: entry.status.tools.map { "\($0) 个工具" })
                        if let message = entry.status.message, entry.status.phase != .connected {
                            Text(message).font(Theme.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button("修改") { editing = McpServerDraft(entry); error = nil }
                        Button("重新连接") { run { try await reconnect(entry.name) } }
                        Button("删除", role: .destructive) { removing = entry.name }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.button).buttonStyle(.pointingBorderless).fixedSize()
                    .disabled(busy)
                }
            }
            if servers?.isEmpty == true {
                Text("这台工作机还没有 MCP 服务。").foregroundStyle(.secondary)
            } else if servers == nil, error == nil {
                ProgressView()
            }
            HStack {
                Button("粘贴配置") { pasting = true; pasted = ""; error = nil }
                Spacer()
                Button("添加服务") { editing = McpServerDraft(); error = nil }
            }
            .disabled(busy || servers == nil)
        } header: {
            Text("服务")
        } footer: {
            Text("服务在这台工作机上运行，不在 Kite 的沙箱里，授权一个服务等于把它能做的事交给代理。新装的服务默认谁都不能用，在角色、代理配置里打开；项目约束可以禁用。")
        }
    }

    private func summary(_ config: McpServerConfig) -> String {
        if config.type == "http" { return config.url ?? "" }
        return ([config.command ?? ""] + (config.args ?? [])).joined(separator: " ")
    }

    // MARK: - 编辑

    private func labeled(_ label: String, _ placeholder: String, _ values: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.caption).foregroundStyle(.secondary)
            LinesField(placeholder: placeholder, values: values).lineLimit(1...5)
        }
    }

    @ViewBuilder private func editor(_ draft: Binding<McpServerDraft>) -> some View {
        Section {
            TextField("名称", text: draft.name, prompt: Text("github"))
                .autocorrectionDisabled()
            Picker("类型", selection: draft.type) {
                Text("本机程序").tag("stdio")
                Text("远程服务").tag("http")
            }
            .pickerStyle(.segmented).clickPointer()
            if draft.wrappedValue.type == "http" {
                TextField("网址", text: draft.url, prompt: Text("https://example.com/mcp"))
                    .autocorrectionDisabled()
                labeled("请求头", "每行一条，例如 Authorization: Bearer {account.github}", draft.headers)
            } else {
                TextField("命令", text: draft.command, prompt: Text("npx"))
                    .autocorrectionDisabled()
                labeled("参数", "每行一个，例如 -y 和 @modelcontextprotocol/server-github", draft.args)
                labeled("环境变量", "每行一条，例如 GITHUB_TOKEN={account.github}", draft.env)
                TextField("工作目录", text: draft.cwd, prompt: Text("默认用户主目录"))
                    .autocorrectionDisabled()
            }
            TextField("说明", text: draft.description, prompt: Text("一句话告诉代理这个服务做什么"), axis: .vertical)
            HStack {
                Button("取消") { editing = nil; error = nil }
                Spacer()
                Button(busy ? "正在保存…" : "保存") { let value = draft.wrappedValue; run { try await save(value) } }
                    .disabled(busy || draft.wrappedValue.incomplete)
            }
        } header: {
            Text(draft.wrappedValue.original == nil ? "添加服务" : "修改服务")
        } footer: {
            Text((draft.wrappedValue.type == "http" ? "只接 Streamable HTTP。" : "命令按这台工作机的 PATH 找，找不到时写绝对路径。")
                 + "令牌存进「凭据」的共享密钥，这里写 {account.名字} 引用，连接时由工作机取出；直接写值会以明文存在这台工作机上。")
        }
    }

    // MARK: - 粘贴

    private var importSection: some View {
        Section {
            TextField("配置", text: $pasted, prompt: Text("{\"mcpServers\": {…}}"), axis: .vertical)
                .font(Theme.code).lineLimit(6...16).autocorrectionDisabled()
            HStack {
                Button("取消") { pasting = false; error = nil }
                Spacer()
                Button(busy ? "正在导入…" : "导入") { run { try await importPasted() } }
                    .disabled(busy || pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("粘贴配置")
        } footer: {
            Text("粘贴 Claude Code、Claude Desktop 或 Cursor 里的 mcpServers 配置，同名的服务会被替换。")
        }
    }

    // MARK: - 请求

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await action(); error = nil } catch { self.error = error.localizedDescription }
        }
    }

    private func load() async {
        do {
            let list = try await connection.client.request("/mcp", as: McpServerList.self)
            servers = list.servers
            error = list.error
        }
        catch is CancellationError { }
        catch { self.error = "读取 MCP 服务失败：\(error.localizedDescription)" }
    }

    private func path(_ name: String) -> String { "/mcp/servers/\(name.pathComponent)" }

    private func save(_ draft: McpServerDraft) async throws {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        _ = try await connection.client.request(path(name), method: "PUT", body: draft.config, as: McpServerEntry.self)
        // 改了名字就是换了一个服务：新的存好再删旧的。
        if let original = draft.original, original != name {
            let _: JSON = try await connection.client.request(path(original), method: "DELETE", as: JSON.self)
        }
        editing = nil
        await load()
    }

    private func importPasted() async throws {
        guard let data = pasted.data(using: .utf8), let value = try? JSONDecoder().decode(JSON.self, from: data) else {
            throw KitedError(message: "不是有效的 JSON")
        }
        _ = try await connection.client.request("/mcp/import", method: "POST", body: value, as: McpServerList.self)
        pasting = false
        await load()
    }

    private func reconnect(_ name: String) async throws {
        _ = try await connection.client.request("\(path(name))/reconnect", method: "POST", timeout: 90, as: McpServerEntry.self)
        await load()
    }

    private func remove(_ name: String) async throws {
        let _: JSON = try await connection.client.request(path(name), method: "DELETE", as: JSON.self)
        removing = nil
        await load()
    }
}

/// 服务开关：available 是这台（或各台）工作机装的服务，selected 里没装的也列出来；项目禁用的划掉并暂不可用。
struct McpServerToggles: View {
    let available: [McpServerSummary]
    var denied: [String] = []
    @Binding var selected: [String]
    /// 设了就显示连接状态（代理配置用；角色和项目约束跨工作机，不显示）。
    var showsStatus = false

    private var rows: [McpServerSummary] {
        let names = Set(available.map(\.name))
        return available + selected.filter { !names.contains($0) }.sorted().map { McpServerSummary(name: $0) }
    }

    var body: some View {
        ForEach(rows) { server in
            let blocked = denied.contains(server.name)
            let installed = available.contains { $0.name == server.name }
            Toggle(isOn: Binding(get: { selected.contains(server.name) && !blocked }, set: { enabled in
                selected.removeAll { $0 == server.name }
                if enabled { selected.append(server.name) }
                selected.sort()
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(server.name)
                        if blocked { Text("项目禁用").font(Theme.caption).foregroundStyle(.secondary) }
                        else if !installed { Text("没装").font(Theme.caption).foregroundStyle(.secondary) }
                    }
                    if let description = server.description { Text(description).font(Theme.caption).foregroundStyle(.secondary).lineLimit(2) }
                    if showsStatus, installed, let phase = server.phase { McpStatusLabel(phase: phase) }
                }
            }
            .strikethrough(blocked)
            .disabled(blocked)
        }
    }
}

extension AppModel {
    /// 连着的各台工作机装的服务合在一起，按名字去重：角色与项目约束是账号级的，开关列出哪台装的都算。
    func knownMcpServers() async -> [McpServerSummary] {
        var merged: [String: McpServerSummary] = [:]
        let clients = availableWorkers.map(\.client)
        await withTaskGroup(of: [McpServerEntry].self) { group in
            for client in clients {
                group.addTask { (try? await client.request("/mcp", as: McpServerList.self).servers) ?? [] }
            }
            for await servers in group {
                for entry in servers where merged[entry.name]?.description == nil {
                    merged[entry.name] = McpServerSummary(name: entry.name, description: entry.config.description)
                }
            }
        }
        return merged.values.sorted { $0.name < $1.name }
    }

    /// 各台工作机服务清单变化的总次数，角色与项目约束的开关列表据此重新读取；只是连接状态变了不算。
    var mcpCatalogRevision: Int { availableWorkers.reduce(0) { $0 + $1.mcpCatalogRevision } }
}
