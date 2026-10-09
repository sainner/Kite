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
        let instance = area.instances.first { $0.id == thread.id }
        let id = thread.contextTemplate?.id ?? instance?.config?.agent?.context["id"]?.string
        return templates.first { $0.id == id } ?? templates.first
    }
}

/// 首次发送前选用模板，或使用同一编辑器复制新模板；不单独增加创建向导。
struct NewThreadContextTemplate: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(WorkThread.self) private var thread
    @State private var edit: ContextTemplateEdit?
    @State private var error: String?

    private var instance: RemotePluginInstance? { area.instances.first { $0.id == thread.id } }
    private var templateID: String? { thread.contextTemplate?.id ?? instance?.config?.agent?.context["id"]?.string }
    private var templates: [ContextTemplate] {
        (model.templates(in: area)?.templates ?? []).filter { $0.definition.scene == "thread.create" }
    }
    private var title: String {
        thread.contextTemplate?.definition.title ?? instance?.config?.agent?.context["title"]?.string ?? "默认模板"
    }
    private var source: ContextTemplate? { model.newThreadTemplate(for: thread, in: area) }
    private var available: Bool {
        !thread.configuringTemplate && model.isConnected(area)
            && (instance?.config?.agent != nil || thread.isDraft)
    }

    var body: some View {
        VStack(spacing: 10) {
            Menu {
                Section("上下文模板") {
                    ForEach(templates) { template in
                        Button { apply(template) } label: {
                            if template.id == templateID { Label(template.definition.title, systemImage: "checkmark") }
                            else { Text(template.definition.title) }
                        }
                    }
                }
                Divider()
                Button("基于「\(source?.definition.title ?? title)」新建模板…", systemImage: "plus") {
                    if let source { edit = .init(definition: source.definition.copy()) }
                }.disabled(source == nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "text.document").foregroundStyle(.secondary)
                    Text(title).lineLimit(1).truncationMode(.middle)
                    Group {
                        if thread.configuringTemplate { CardSpinner().scaleEffect(0.75) }
                        else { Image(systemName: "chevron.down").font(Theme.status.weight(.semibold)) }
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                }
            }
            .menuStyle(.button).buttonStyle(TemplateChipStyle()).menuIndicator(.hidden).fixedSize().clickPointer()
            .disabled(!available || model.templates(in: area) == nil)
            .help("上下文模板")
            if let error {
                HStack(spacing: 8) {
                    Text(error).foregroundStyle(Theme.danger).lineLimit(2)
                    Button("重新读取") { Task { await load() } }
                        .buttonStyle(.borderless).foregroundStyle(Color.accentColor).clickPointer()
                }
                .font(Theme.caption)
                .multilineTextAlignment(.center)
            }
        }
        .sheet(item: $edit) { request in
            ContextTemplateEditor(request: request, connection: model.revision(for: area)) { template in apply(template) }
                .environment(model)
        }
        .task(id: model.revision(for: area)) { await load() }
    }

    private func load() async {
        do { try await model.refreshContextTemplates(in: area); error = nil }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func apply(_ template: ContextTemplate) {
        guard available else { return }
        thread.configuringTemplate = true
        error = nil
        let revision = model.revision(for: area)
        Task {
            defer { thread.configuringTemplate = false }
            do { try await model.applyContextTemplate(template, to: thread, in: area, connection: revision) }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// 新会话中间的模板选择：一枚浅底胶囊，悬停略深，按下变淡。
private struct TemplateChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration)
    }

    private struct Chip: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Theme.secondary)
                .padding(.horizontal, 14)
                .frame(minHeight: InputMode.current.isTouch ? 40 : 30)
                .background(Theme.codeBackground.opacity(hovering ? 1 : 0.7), in: Capsule())
                .contentShape(Capsule())
                .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.5)
                .onHover { hovering = $0 && enabled }
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}
