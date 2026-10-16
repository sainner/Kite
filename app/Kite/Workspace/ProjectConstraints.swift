import SwiftUI

/// 项目约束：随项目登记表在工作机之间同步，由用户在 App 里修改。工作机据此实时作用于本项目的全部代理（docs/Agent与插件契约.md §3.2）。
nonisolated struct ProjectConstraints: Codable, Equatable, Sendable {
    struct Tools: Codable, Equatable, Sendable, ToolFilter {
        var mode: String
        var tools: [String]
    }
    var tools: Tools
    /// 执行授权的基础与边界；没设置过时没有。
    var execution: ProjectExecution?
    var revision: String
}

/// 项目配置页里的「代理约束」：这个项目里的代理能用哪些工具，执行授权的基础许可与禁止，审批模式的上限。
/// 收紧后正在运行的代理从下一次工具调用起受限，已在运行的命令不追溯。
struct ProjectConstraintsSection: View {
    let projectID: String
    @Environment(AppModel.self) private var model
    @State private var saved: ProjectConstraints?
    @State private var draft: ProjectConstraints.Tools?
    @State private var execution = ProjectExecution()
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
            } else if error == nil {
                ProgressView()
            }
        } header: {
            Text("代理约束")
        } footer: {
            Text("项目禁用的工具任何代理都开不了。角色必需的工具被禁用时，这个项目里不能选用该角色。")
        }
        .task(id: projectID) { await load() }
        if draft != nil {
            Section {
                Toggle("工作区只读", isOn: Binding(get: { execution.workspace == .read }, set: { execution.workspace = $0 ? .read : .write }))
                Picker("审批模式上限", selection: $execution.approval) {
                    ForEach(ApprovalMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                lines("额外只读路径", "每行一个，例如 ~/.cargo", $execution.allow.read)
                lines("额外读写路径", "每行一个，例如 ~/Library/Caches/pnpm", $execution.allow.write)
                lines("允许访问的网络地址", "每行一个，例如 registry.npmjs.org:443", $execution.allow.network)
                lines("沙箱外命令", "每行一条，例如 docker compose *", $execution.allow.unsandboxed)
            } header: {
                Text("执行授权的基础")
            } footer: {
                Text("本项目所有代理的起点，角色和代理可以在此之上增减。路径可写 ~/ 开头，由各工作机按自己的主目录解析。沙箱外命令以「 *」结尾表示带任意参数，匹配的命令以用户身份运行，会执行工作区里代理能改的脚本。")
            }
            Section {
                lines("不能读写的路径", "每行一个，例如 ~/.ssh", $execution.deny.read)
                lines("不能写的路径", "每行一个", $execution.deny.write)
                lines("不能访问的网络地址", "每行一个，支持 *.example.com", $execution.deny.network)
                lines("不能在沙箱外运行的命令", "每行一条，例如 sudo *", $execution.deny.unsandboxed)
                HStack {
                    Spacer()
                    Button(saving ? "正在保存…" : "保存") { save() }
                        .disabled(saving || (draft == saved?.tools && execution == (saved?.execution ?? ProjectExecution())))
                }
                if let error { Text(error).foregroundStyle(Theme.danger) }
            } header: {
                Text("禁止")
            } footer: {
                Text("任何代理、角色和审批都打不开。收紧从下一次工具调用起生效，已在运行的命令不追溯。")
            }
        } else if let error {
            Section { Text(error).foregroundStyle(Theme.danger) }
        }
    }

    private func lines(_ label: String, _ placeholder: String, _ values: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.caption).foregroundStyle(.secondary)
            LinesField(placeholder: placeholder, values: values).lineLimit(1...5)
        }
    }

    private func load() async {
        do {
            try? await model.ensureRoles()
            let value = try await model.projectConstraints(projectID)
            saved = value
            draft = value.tools
            execution = value.execution ?? ProjectExecution()
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
                let value = try await model.saveProjectConstraints(projectID, tools: draft, execution: execution, expectedRevision: saved.revision)
                self.saved = value
                self.draft = value.tools
                self.execution = value.execution ?? ProjectExecution()
            } catch { self.error = error.localizedDescription }
        }
    }
}
