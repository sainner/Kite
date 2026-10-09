import SwiftUI

/// 资源库一栏的单页，操作在标题栏：列出角色，点开编辑，或基于已有角色另存。
struct RoleLibrary: View {
    @Environment(AppModel.self) private var model
    @State private var edit: RoleEdit?
    @State private var error: String?
    @State private var loading = false

    private var catalog: RoleCatalog? { model.roleCatalog }
    /// 新建角色以默认角色为底，保留运行环境与项目材料等段落。
    private var base: AgentRole? { catalog?.roles.first { $0.id == "kite.work" } ?? catalog?.roles.first }

    var body: some View {
        SectionPage(header: PaneHeader(title: "角色", subtitle: SidebarSection.extensions.title)) {
            form
        } actions: {
            PaneHeaderButtonGroup {
                Button { Task { await refresh() } } label: { PaneHeaderButtonLabel("刷新", systemImage: "arrow.clockwise") }
                    .help("刷新")
                    .disabled(loading)
                Button {
                    guard var role = base?.role.copy() else { return }
                    role.title = "新角色"
                    role.context.title = role.title
                    edit = .init(role: role)
                } label: { PaneHeaderButtonLabel("新建角色", systemImage: "plus") }
                    .help("新建角色")
                    .disabled(base == nil)
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                Text("角色保存在当前工作机，决定新代理的提示词、可用工具、默认模型与每回合预算。修改角色只影响之后新建的代理。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                ForEach(catalog?.roles ?? []) { role in
                    HStack {
                        Button { edit = .init(role: role.role, original: role) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(role.role.title)
                                Text(summary(role.role)).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button("基于此新建角色", systemImage: "doc.on.doc") { edit = .init(role: role.role.copy()) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
            }
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(item: $edit) { request in
            RoleEditor(request: request, connection: model.connectionRevision).environment(model)
        }
        .task(id: model.connectionRevision) { await refresh() }
    }

    /// 一行概括：工具范围与默认模型。
    private func summary(_ role: RoleDefinition) -> String {
        let universe = catalog?.tools ?? []
        let permitted = role.tools.permitted(in: universe)
        let tools = permitted.count == universe.count ? "全部工具" : permitted.isEmpty ? "没有工具" : "工具：\(permitted.joined(separator: "、"))"
        let model = catalog?.models.first { $0.id == role.model.model }?.name ?? role.model.model
        return "\(tools) · \(model)"
    }

    private func refresh() async {
        loading = true
        error = nil
        defer { loading = false }
        do { try await model.refreshRoles() }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
