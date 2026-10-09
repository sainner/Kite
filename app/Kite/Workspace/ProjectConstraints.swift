import SwiftUI

/// 项目约束：按项目保存在账号服务，只能由用户在 App 里修改。工作机拉取后作为实时过滤，与角色、代理自己的选择逐层求交。
nonisolated struct ProjectConstraints: Codable, Equatable, Sendable {
    struct Tools: Codable, Equatable, Sendable, ToolFilter {
        var mode: String
        var tools: [String]
    }
    var tools: Tools
    var revision: String
}

private struct ConstraintsSave: Encodable {
    let tools: ProjectConstraints.Tools
    let expectedRevision: String
}

extension KiteAccount {
    func projectConstraints(_ projectID: String) async throws -> ProjectConstraints {
        try await request("/api/projects/\(projectID)/constraints", as: ProjectConstraints.self)
    }

    func saveProjectConstraints(_ projectID: String, tools: ProjectConstraints.Tools, expectedRevision: String) async throws -> ProjectConstraints {
        try await request("/api/projects/\(projectID)/constraints", method: "PUT",
                          body: ConstraintsSave(tools: tools, expectedRevision: expectedRevision), as: ProjectConstraints.self)
    }
}

extension AppModel {
    /// 改了账号里的约束后请已连接的工作机立即拉取，运行中的代理在下一次请求或工具调用时生效；离线的工作机上线后再拉取。
    func refreshWorkerLibraries() async {
        await withTaskGroup(of: Void.self) { group in
            for connection in connections.values where connection.connected {
                let client = connection.client
                group.addTask { _ = try? await client.request("/library/refresh", method: "POST", as: JSON.self) }
            }
        }
    }
}

/// 项目配置页里的「代理约束」：这个项目里的代理能用哪些工具。收紧后正在运行的代理也立即受限。
struct ProjectConstraintsSection: View {
    let projectID: String
    @Environment(AppModel.self) private var model
    @State private var saved: ProjectConstraints?
    @State private var draft: ProjectConstraints.Tools?
    @State private var saving = false
    @State private var error: String?

    /// 代理插件声明的全部工具，来自工作机的角色目录。
    private var universe: [String] { model.roleCatalog?.tools ?? [] }

    var body: some View {
        Section {
            if let draft {
                LabeledContent("以后新增的工具") {
                    Picker("以后新增的工具", selection: Binding(get: { draft.mode }, set: { self.draft?.setMode($0, in: universe) })) {
                        Text("默认可用").tag("deny")
                        Text("默认不可用").tag("allow")
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                ForEach(universe, id: \.self) { name in
                    Toggle(name, isOn: Binding(get: { draft.allows(name) }, set: { self.draft?.setEnabled(name, $0) }))
                }
                HStack {
                    Spacer()
                    Button(saving ? "正在保存…" : "保存") { save() }
                        .disabled(saving || draft == saved?.tools)
                }
            } else if error == nil {
                ProgressView()
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        } header: {
            Text("代理约束")
        } footer: {
            Text("与角色和代理自己的选择逐层取交集，禁止优先。角色必需的工具被禁用时，这个项目里不能选用该角色。")
        }
        .task(id: projectID) { await load() }
    }

    private func load() async {
        do {
            if model.roleCatalog == nil { try? await model.refreshRoles() }
            let value = try await model.account.projectConstraints(projectID)
            saved = value
            draft = value.tools
            error = nil
        }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func save() {
        guard let draft, let saved else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                let value = try await model.account.saveProjectConstraints(projectID, tools: draft, expectedRevision: saved.revision)
                self.saved = value
                self.draft = value.tools
                // 工作机在后台拉取，保存不等最慢的那台。
                Task { await model.refreshWorkerLibraries() }
            } catch { self.error = error.localizedDescription }
        }
    }
}
