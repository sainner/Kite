import SwiftUI

/// 资源库一栏的单页，操作在标题栏。
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
                Button { edit = .init(definition: .empty()) } label: { PaneHeaderButtonLabel("新建模板", systemImage: "plus") }
                    .help("新建模板")
                    .disabled(model.contextTemplates == nil)
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                Text("模板保存在当前工作机。创建会话模板用于之后的新会话；标题模板在下次生成时生效；通知模板用于之后生成的通知，已生成的内容保留原样。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(model.contextTemplates?.scenes ?? []) { scene in
                Section(scene.title) {
                    ForEach((model.contextTemplates?.templates ?? []).filter { $0.definition.scene == scene.id }) { template in
                        HStack {
                            Button { edit = .init(definition: template.definition, original: template) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(template.definition.title)
                                    Text("\(template.definition.blocks.count + (template.definition.input?.count ?? 0)) 个内容块")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if scene.id == "thread.create" {
                                Button("复制为新模板", systemImage: "doc.on.doc") { edit = .init(definition: template.definition.copy()) }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                        }
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

extension AppModel {
    /// 新会话选用的创建会话模板，取工作机目录里的最新版本；没选过时是第一个。
    func newThreadTemplate(for thread: WorkThread, in area: WorkArea) -> ContextTemplate? {
        let templates = (templates(in: area)?.templates ?? []).filter { $0.definition.scene == "thread.create" }
        let id = selectedTemplateID(for: thread, in: area)
        return templates.first { $0.id == id } ?? templates.first
    }

    /// 草稿取本机选好的模板，已有会话取实例配置里的上下文。
    func selectedTemplateID(for thread: WorkThread, in area: WorkArea) -> String? {
        thread.contextTemplate?.id ?? area.instances.first { $0.id == thread.id }?.config?.agent?.context["id"]?.string
    }

    func templateTitle(for thread: WorkThread, in area: WorkArea) -> String {
        thread.contextTemplate?.definition.title
            ?? area.instances.first { $0.id == thread.id }?.config?.agent?.context["title"]?.string ?? "默认模板"
    }

    func canSelectTemplate(for thread: WorkThread, in area: WorkArea) -> Bool {
        !thread.configuringTemplate && isConnected(area) && templates(in: area) != nil
            && (area.instances.first { $0.id == thread.id }?.config?.agent != nil || thread.isDraft)
    }

    /// 套用期间输入区与模板菜单禁用。
    func selectNewThreadTemplate(_ template: ContextTemplate, for thread: WorkThread, in area: WorkArea) async throws {
        guard canSelectTemplate(for: thread, in: area) else { return }
        thread.configuringTemplate = true
        defer { thread.configuringTemplate = false }
        try await applyContextTemplate(template, to: thread, in: area, connection: revision(for: area))
    }
}

/// 首次发送前在会话标题栏的模板菜单里选用模板，或使用同一编辑器复制新模板；不单独增加创建向导。
struct NewThreadTemplateMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(WorkThread.self) private var thread
    let select: (ContextTemplate) -> Void
    let copy: (ContextTemplate) -> Void

    var body: some View {
        let selected = model.selectedTemplateID(for: thread, in: area)
        let source = model.newThreadTemplate(for: thread, in: area)
        Section("上下文模板") {
            ForEach((model.templates(in: area)?.templates ?? []).filter { $0.definition.scene == "thread.create" }) { template in
                Button { select(template) } label: {
                    if template.id == selected { Label(template.definition.title, systemImage: "checkmark") }
                    else { Text(template.definition.title) }
                }
            }
        }
        Divider()
        Button("基于「\(source?.definition.title ?? model.templateTitle(for: thread, in: area))」新建模板…", systemImage: "plus") {
            if let source { copy(source) }
        }.disabled(source == nil)
    }
}
