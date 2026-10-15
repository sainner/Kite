import SwiftUI

/// 项目约束：随项目登记表在工作机之间同步，由用户在 App 里修改。工作机据此实时过滤，与角色、代理自己的选择逐层求交。
nonisolated struct ProjectConstraints: Codable, Equatable, Sendable {
    struct Tools: Codable, Equatable, Sendable, ToolFilter {
        var mode: String
        var tools: [String]
    }
    var tools: Tools
    var revision: String
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
                ToolModePicker(mode: Binding(get: { draft.mode }, set: { self.draft?.setMode($0, in: universe) }))
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
            try? await model.ensureRoles()
            let value = try await model.projectConstraints(projectID)
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
                let value = try await model.saveProjectConstraints(projectID, tools: draft, expectedRevision: saved.revision)
                self.saved = value
                self.draft = value.tools
            } catch { self.error = error.localizedDescription }
        }
    }
}
