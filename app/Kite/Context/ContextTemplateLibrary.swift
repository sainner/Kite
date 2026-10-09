import SwiftUI

/// 资源库一栏的单页，操作在标题栏。这里只有后台场景的模板；代理的提示词属于角色。
struct ContextTemplateLibrary: View {
    @Environment(AppModel.self) private var model
    @State private var edit: ContextTemplateEdit?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        SectionPage(header: PaneHeader(title: "上下文模板", subtitle: SidebarSection.extensions.title)) {
            form
        } actions: {
            PaneHeaderButtonGroup {
                Button { Task { await refresh() } } label: { PaneHeaderButtonLabel("刷新", systemImage: "arrow.clockwise") }
                    .help("刷新")
                    .disabled(loading)
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                Text("模板保存在当前工作机。标题模板在下次生成时生效；通知模板用于之后生成的通知，已生成的内容保留原样。代理的提示词在「角色」里编辑。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(model.contextTemplates?.scenes ?? []) { scene in
                Section(scene.title) {
                    ForEach((model.contextTemplates?.templates ?? []).filter { $0.definition.scene == scene.id }) { template in
                        Button { edit = .init(template: template) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(template.definition.title)
                                Text("\(template.definition.blocks.count + (template.definition.input?.count ?? 0)) 个内容块")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(Theme.danger) }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(item: $edit) { request in
            ContextTemplateEditor(request: request, connection: model.connectionRevision).environment(model)
        }
        .task(id: model.connectionRevision) { await refresh() }
    }

    private func refresh() async {
        loading = true
        error = nil
        defer { loading = false }
        do { try await model.refreshContextTemplates() }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
