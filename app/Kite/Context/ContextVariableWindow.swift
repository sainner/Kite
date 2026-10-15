import SwiftUI

/// 变量窗口按代理取到的值，见 GET /instances/:id/context-variables/:name。来自文件的（项目规则、记忆索引）另带逐级找到的各份文件，
/// 由外到内；一份都没有时 create 是在工作目录新建的位置。
nonisolated struct ContextVariableValue: Decodable, Sendable {
    struct File: Decodable, Sendable, Identifiable {
        let path: String
        let content: String
        let sha256: String
        var id: String { path }
    }
    let name: String
    let text: String
    let files: [File]?
    let create: String?
}

/// 变量窗口里改过还没保存的一份文件。
struct ContextFileDraft: Identifiable {
    let machine: String
    let path: String
    var content: String
    /// 开始修改时文件的摘要，保存时工作机据此检查是否已在别处改过；新建的文件为 nil。
    let base: String?
    var id: String { "\(machine):\(path)" }
}

/// 变量按所在的层选取值的对象：环境层选工作机，项目层选项目，工作区层选工作区，代理层选代理。
enum ContextVariableLayer: String {
    case environment, project, workspace, agent

    var noun: String {
        switch self {
        case .environment: "工作机"
        case .project: "项目"
        case .workspace: "工作区"
        case .agent: "代理"
        }
    }

    var icon: String {
        switch self {
        case .environment: "desktopcomputer"
        case .project: "folder"
        case .workspace: "rectangle.on.rectangle"
        case .agent: "person.crop.circle"
        }
    }
}

/// 一个取值对象：请求发到哪台工作机、哪个路径（后面接变量名），菜单里排在哪一节、叫什么。
/// 项目按它在某台工作机上的检出取，规则与记忆索引也写回那个文件夹。
struct ContextVariableSource: Identifiable {
    let id: String
    let machine: String
    let path: String
    let section: String?
    let title: String
}

extension AppModel {
    /// 代理上下文页的变量窗口。
    static let contextVariablePane = Pane("variable")

    /// 代理上下文页这一项可用的变量：角色的提示词变量，或模板所在场景的变量。
    var agentContextVariables: [ContextScene.Variable] {
        guard let item = agentContextItem else { return [] }
        if item.category == .role { return roleCatalog?.variables ?? [] }
        let scene = libraryTemplate(item.id)?.scene
        return contextTemplates?.scenes.first { $0.id == scene }?.variables ?? []
    }

    var contextVariableShown: Bool { agentContextGroup?.layout.root?.panes.contains(Self.contextVariablePane) == true }

    /// 点可用变量里的一个：上下文窗口原地不动，变量窗口占掉它以外的地方；开着时换成这个变量，再点开着的那个就关掉。
    func openContextVariable(_ name: String) {
        guard let layout = agentContextGroup?.layout else { return }
        if contextVariableShown, contextVariable == name { return closeContextVariable() }
        contextVariable = name
        layout.present(Self.contextVariablePane, beside: Pane("context"))
    }

    func closeContextVariable() {
        roleWindows.dismiss(Self.contextVariablePane)
        templateWindows.dismiss(Self.contextVariablePane)
    }

    /// 连着的工作机上的工作区，先放当前工作机的。
    private var contextVariableAreas: [(area: WorkArea, remote: RemoteWorkspace)] {
        let active = activeConnection?.machine.id
        let areas = workspaces.compactMap { area in area.remote.map { (area: area, remote: $0) } }
            .filter { connections[$0.remote.machine.id]?.connected == true }
        return areas.filter { $0.remote.machine.id == active } + areas.filter { $0.remote.machine.id != active }
    }

    /// 某一层可选的取值对象，按菜单里的先后排。
    func contextVariableSources(_ layer: ContextVariableLayer) -> [ContextVariableSource] {
        let areas = contextVariableAreas
        let machines = Set(areas.map(\.remote.machine.id)).count > 1
        func onMachine(_ remote: RemoteWorkspace, _ title: String) -> String { machines ? "\(title) · \(remote.machine.name)" : title }
        switch layer {
        case .environment:
            return availableWorkers.map { ContextVariableSource(id: $0.machine.id, machine: $0.machine.id, path: "/context-variables",
                                                                section: nil, title: $0.machine.name) }
        case .project:
            // 同一项目在几台工作机上都有检出时，按先排到的（当前工作机优先）
            var seen = Set<String>()
            return areas.filter { seen.insert($0.remote.project.id).inserted }.map { _, remote in
                ContextVariableSource(id: remote.project.id, machine: remote.machine.id, path: "/checkouts/\(remote.checkout.id)/context-variables",
                                      section: nil, title: projectLabel(remote.project))
            }
        case .workspace:
            return areas.map { _, remote in
                ContextVariableSource(id: remote.id, machine: remote.machine.id, path: "/workspaces/\(remote.id)/context-variables",
                                      section: projectLabel(remote.project), title: onMachine(remote, remote.workspace.name))
            }
        case .agent:
            return areas.flatMap { area, remote in
                area.threads.map { thread in
                    ContextVariableSource(id: thread.id, machine: remote.machine.id, path: "/instances/\(thread.id)/context-variables",
                                          section: onMachine(remote, "\(projectLabel(remote.project)) · \(remote.workspace.name)"), title: thread.title)
                }
            }
        }
    }

    /// 某一层按哪个对象取值：选过的还在就用它，不然是当前所在的（当前工作机、当前工作区和它的项目、当前工作区里聚焦的代理），再不然是第一个。
    /// 已经列出这一层的对象时传进来，不再列一遍。
    func contextVariableSource(_ layer: ContextVariableLayer, among listed: [ContextVariableSource]? = nil) -> ContextVariableSource? {
        let sources = listed ?? contextVariableSources(layer)
        let here: String? = switch layer {
        case .environment: activeConnection?.machine.id
        case .project: current?.remote?.project.id
        case .workspace: current?.remote?.id
        case .agent: current.flatMap { area in area.layout.focused.flatMap(area.thread(in:))?.id }
        }
        return [contextVariableChoices[layer.rawValue], here].lazy.compactMap { id in id.flatMap { id in sources.first { $0.id == id } } }.first
            ?? sources.first
    }

    func contextFileDraft(_ path: String, on machine: String) -> ContextFileDraft? {
        contextFileDrafts.first { $0.machine == machine && $0.path == path }
    }

    /// 改变量窗口里的文件：改回与读到的一致时不再算草稿；新建的（saved 为 nil）一直留着，保存或放弃才清掉。
    func editContextFile(_ path: String, on machine: String, content: String, saved: ContextVariableValue.File?) {
        let index = contextFileDrafts.firstIndex { $0.machine == machine && $0.path == path }
        if let saved, content == saved.content {
            if let index { contextFileDrafts.remove(at: index) }
        } else if let index {
            contextFileDrafts[index].content = content
        } else {
            contextFileDrafts.append(ContextFileDraft(machine: machine, path: path, content: content, base: saved?.sha256))
        }
    }

    func discardContextFiles(_ paths: [String], on machine: String) {
        contextFileDrafts.removeAll { $0.machine == machine && paths.contains($0.path) }
    }

    private func contextVariableClient(_ source: ContextVariableSource) throws -> KitedClient {
        guard let connection = connections[source.machine], connection.connected else { throw KitedError(message: "所属工作机未连接") }
        return connection.client
    }

    func contextVariableValue(_ name: String, from source: ContextVariableSource) async throws -> ContextVariableValue {
        try await contextVariableClient(source).request("\(source.path)/\(name)", as: ContextVariableValue.self)
    }

    /// 把改过的文件一份份存回工作机，返回最后存完后的值；存好的草稿清掉，没存上的留着。
    func saveContextFiles(_ name: String, to source: ContextVariableSource, paths: [String]) async throws -> ContextVariableValue? {
        let client = try contextVariableClient(source)
        var value: ContextVariableValue?
        for path in paths {
            guard let draft = contextFileDraft(path, on: source.machine) else { continue }
            value = try await client.request("\(source.path)/\(name)/file", method: "PUT",
                                             body: ContextFileWrite(path: path, content: draft.content, expectedSha256: draft.base),
                                             as: ContextVariableValue.self)
            contextFileDrafts.removeAll { $0.id == draft.id }
        }
        return value
    }
}

/// 新建时摘要写 null，不能省掉。
private nonisolated struct ContextFileWrite: Encodable {
    let path: String
    let content: String
    let expectedSha256: String?

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(content, forKey: .content)
        try container.encode(expectedSha256, forKey: .expectedSha256)
    }

    private enum CodingKeys: String, CodingKey { case path, content, expectedSha256 }
}

/// 资源库代理上下文的变量窗口：按变量所在的层选一个对象取现在的值，环境层选工作机，项目层选项目，工作区层选工作区，代理层选代理，
/// 在标题栏选，默认是当前所在的那个。项目规则与记忆索引逐份列出原文，直接改，改完保存，写回项目在那台工作机上的文件夹，
/// 下一次请求时生效，底栏是格式工具；其他变量只读。台面上点窗口外面就关掉，上下文窗口原地不动；改了没保存的文件关掉也留着，再打开接着改。
struct ContextVariablePane: View {
    @Environment(AppModel.self) private var model
    @State private var value: ContextVariableValue?
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @Environment(\.toast) private var toast
    @State private var editor = ContextEditor()

    private var name: String { model.contextVariable ?? "" }

    /// 这一次显示要用的：变量、所在的层、这一层可选的对象和选中的那个、列出来的文件。body 里算一次往下传，
    /// 列取值对象要走遍连着的工作区（代理层还要走遍各工作区的线程），不在各处各算一遍。
    private struct Shown {
        let variable: ContextScene.Variable?
        let layer: ContextVariableLayer?
        let sources: [ContextVariableSource]
        let source: ContextVariableSource?
        /// 列出来的文件：读到的各份，加上开始新建、还没存过的那份。
        let paths: [String]
        /// 其中改过还没保存的。
        let changed: [String]
    }

    private func shown() -> Shown {
        let name = name
        let variable = model.agentContextVariables.first { $0.name == name }
        let layer = variable?.layer.flatMap(ContextVariableLayer.init(rawValue:))
        let sources = layer.map(model.contextVariableSources) ?? []
        let source = layer.flatMap { model.contextVariableSource($0, among: sources) }
        var paths: [String] = []
        var changed: [String] = []
        if let source {
            paths = value?.files?.map(\.path) ?? []
            if let create = value?.create, model.contextFileDraft(create, on: source.machine) != nil { paths.append(create) }
            changed = paths.filter { model.contextFileDraft($0, on: source.machine) != nil }
        }
        return Shown(variable: variable, layer: layer, sources: sources, source: source, paths: paths, changed: changed)
    }

    var body: some View {
        let shown = shown()
        let source = shown.source, paths = shown.paths
        PaneWindow(header: PaneHeader(title: shown.variable?.title ?? name, subtitle: status(shown) ?? (paths.count == 1 ? paths[0] : name)),
                   notice: error.map(PaneNotice.failure), actions: PaneHeaderActions(groups: headerGroups(shown), menus: sourceMenu(shown))) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let value, let source { content(value, source: source, labeled: paths.count > 1) }
                }
                .agentContextColumn()
            }
        } controls: { _ in
            if !paths.isEmpty { ContextTextToolbar().disabled(saving) }
        }
        .contextEditor(editor, counting: nil)
        .background {
            OutsideClickDismissal(paused: { [model] in model.agentContextGroup?.layout.transitioning ?? false }) { [model] in
                model.closeContextVariable()
            }
        }
        .task(id: "\(source.map { "\(model.connections[$0.machine]?.catalog.generation.uuidString ?? "")|\($0.path)" } ?? "")|\(name)") {
            await load(from: source)
        }
    }

    /// 窗口现在的情况写在副行：取不到值的原因、正在取值、值是空的、文件一份都没有。
    private func status(_ shown: Shown) -> String? {
        guard shown.variable != nil else { return nil }
        guard let layer = shown.layer else { return "场景材料，生成时才有，这里看不到取值" }
        guard let source = shown.source else { return "没有可以取值的\(layer.noun)" }
        guard let value else { return loading ? "正在取值…" : nil }
        if let files = value.files {
            guard files.isEmpty, let create = value.create, model.contextFileDraft(create, on: source.machine) == nil else { return nil }
            return "没有 \((create as NSString).lastPathComponent)"
        }
        return value.text.isEmpty ? "现在为空" : nil
    }

    /// 取值直接放在正文里，不套卡片。文件只有一份时路径在副行，几份时各自标在上面。
    @ViewBuilder private func content(_ value: ContextVariableValue, source: ContextVariableSource, labeled: Bool) -> some View {
        if let files = value.files {
            ForEach(files) { file in fileEditor(file.path, saved: file, source: source, labeled: labeled) }
            if let create = value.create, model.contextFileDraft(create, on: source.machine) != nil {
                fileEditor(create, saved: nil, source: source, labeled: labeled)
            }
        } else if !value.text.isEmpty {
            Text(value.text)
                .font(Theme.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fileEditor(_ path: String, saved: ContextVariableValue.File?, source: ContextVariableSource, labeled: Bool) -> some View {
        let machine = source.machine
        return ContextFileEditor(path: path, labeled: labeled,
                                 text: Binding(get: { [model] in model.contextFileDraft(path, on: machine)?.content ?? saved?.content ?? "" },
                                               set: { [model] content in model.editContextFile(path, on: machine, content: content, saved: saved) }))
            .disabled(saving)
    }

    /// 取值对象的菜单：图标和名字随变量所在的层，几节时按节分开。
    private func sourceMenu(_ shown: Shown) -> AnyView? {
        guard let layer = shown.layer, let source = shown.source else { return nil }
        let sections = shown.sources.reduce(into: [(title: String?, sources: [ContextVariableSource])]()) { sections, source in
            if let last = sections.last, last.title == source.section { sections[sections.count - 1].sources.append(source) }
            else { sections.append((source.section, [source])) }
        }
        return AnyView(PaneHeaderButtonGroup {
            Menu {
                Picker("取值的\(layer.noun)", selection: Binding(get: { source.id }, set: { [model] id in model.contextVariableChoices[layer.rawValue] = id })) {
                    ForEach(sections.indices, id: \.self) { index in
                        if let title = sections[index].title {
                            Section(title) { ForEach(sections[index].sources) { Text($0.title).tag($0.id) } }
                        } else {
                            ForEach(sections[index].sources) { Text($0.title).tag($0.id) }
                        }
                    }
                }
                .pickerStyle(.inline)
            } label: {
                PaneHeaderButtonLabel(source.title, systemImage: layer.icon)
            }
            .help("按哪个\(layer.noun)取值")
            .accessibilityLabel("取值的\(layer.noun)")
            .accessibilityValue(source.title)
        }
        .disabled(saving))
    }

    /// 取到值就能复制；文件一份都没有时可以新建；改过文件才能放弃或保存。
    private func headerGroups(_ shown: Shown) -> [[PaneHeaderAction]] {
        var groups: [[PaneHeaderAction]] = []
        if let text = value?.text, !text.isEmpty {
            groups.append([PaneHeaderAction(title: "复制取值", systemImage: "doc.on.doc") { [toast] in copyToPasteboard(text, toast: toast) }])
        }
        guard let source = shown.source else { return groups }
        let machine = source.machine
        if let value, value.files?.isEmpty == true, let create = value.create, model.contextFileDraft(create, on: machine) == nil {
            groups.append([PaneHeaderAction(title: "在项目文件夹新建", systemImage: "doc.badge.plus") { [model] in
                model.editContextFile(create, on: machine, content: "", saved: nil)
            }])
        }
        let changed = shown.changed
        if !changed.isEmpty {
            let connected = model.connections[machine]?.connected == true
            groups.append([
                PaneHeaderAction(title: "放弃修改", systemImage: "xmark", disabled: saving) { [model] in model.discardContextFiles(changed, on: machine) },
                PaneHeaderAction(title: "保存", systemImage: "checkmark", help: connected ? "保存" : "工作机未连接",
                                 busy: saving, disabled: saving || !connected) { save(changed, to: source) },
            ])
        }
        return groups
    }

    private func load(from source: ContextVariableSource?) async {
        value = nil
        error = nil
        guard let source else { return }
        loading = true
        defer { loading = false }
        do {
            let value = try await model.contextVariableValue(name, from: source)
            if !Task.isCancelled { self.value = value }
        } catch {
            if !Task.isCancelled { self.error = "取值失败：\(error.localizedDescription)" }
        }
    }

    private func save(_ paths: [String], to source: ContextVariableSource) {
        guard !saving else { return }
        let name = name
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                if let saved = try await model.saveContextFiles(name, to: source, paths: paths), saved.name == model.contextVariable {
                    value = saved
                }
            } catch {
                self.error = "保存失败：\(error.localizedDescription)"
            }
        }
    }
}

/// 变量窗口里的一份文件：和段落一样直接改，Markdown 标记按样式显示，存回去的是原文。不套卡片，字和正文的边对齐；几份文件时上面标出路径。
private struct ContextFileEditor: View {
    let path: String
    let labeled: Bool
    @Binding var text: String
    @State private var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if labeled {
                Text(path)
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(path)
            }
            ContextParagraphField(parts: Binding(get: { text.isEmpty ? [] : [.text(text)] }, set: { text = $0.plainText }),
                                  variables: [], focused: $focused, placeholder: "文件内容")
                // 段落的字离卡片边留了一圈，这里没有卡片，收回去
                .padding(-ContextTextStyle.inset)
        }
    }
}
