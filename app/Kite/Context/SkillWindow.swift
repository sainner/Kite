import SwiftUI
import UniformTypeIdentifiers

/// 资源库的 Skill 页：侧栏里选中的 skill 在固定排布的窗口里编辑，同代理上下文页。一个都没有时是说明页，标题栏能新建。
struct SkillLibrary: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        Group {
            if let group = model.skillGroup {
                TilesLayer(group: group).id(group.id)
            } else {
                SectionPage(header: PaneHeader(title: ExtensionLibrary.skills.title, subtitle: SidebarSection.extensions.title)) {
                    Group {
                        if let error { Text(error).foregroundStyle(Theme.danger) }
                        else if model.skillCatalog != nil { Text("资源库里还没有 skill。").foregroundStyle(.secondary) }
                        else { ProgressView() }
                    }
                    .font(Theme.body)
                    .padding(Metrics.padding)
                } actions: {
                    PaneHeaderButtonGroup {
                        Button { model.newLibrarySkill() } label: { PaneHeaderButtonLabel("新建 Skill", systemImage: "plus") }
                            .help("新建 Skill")
                    }
                }
            }
        }
        .task(id: model.connectionRevision) {
            error = nil
            do { try await model.ensureSkills() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// 一个 skill 的窗口：标题是名字（新建的可以改），副行是来源。上面一行是文件夹里的文件，点哪个改哪个，SKILL.md 排第一，末尾能加文件；
/// 下面是选中文件的正文，Markdown 按样式显示，存回去的是原文。恢复默认、删除、放弃与保存都在标题栏，底部控制区是编辑工具栏。
/// 修改即时记成草稿，与工作机上一致时草稿自动消失；账号里的变化经工作机推过来，不用手动刷新。
struct SkillPane: View {
    let name: String
    @Environment(AppModel.self) private var model
    @State private var error: String?
    @State private var file = SkillPackage.mainFile
    @State private var focused = false
    @State private var saving = false
    @State private var discard = false
    @State private var confirmReset = false
    @State private var confirmDelete = false
    @State private var confirmRemoveFile = false
    @State private var adding = false
    @State private var newPath = ""
    @State private var importing = false
    @State private var replacing: String?
    @State private var exporting = false
    @State private var exportDocument: SkillFileDocument?
    @State private var exportName = ""
    @State private var exportType = UTType.data
    @State private var editor = ContextEditor()

    private var saved: LibrarySkill? { model.savedSkill(name) }
    private var draft: SkillDraft? { model.skillDraft(name) }
    private var skill: SkillPackage? { model.librarySkill(name) }
    private var isNew: Bool { draft?.isNew == true }
    private var canSave: Bool { !saving && model.connected }
    /// SKILL.md 排第一，其余按路径。
    private var files: [SkillPackage.File] {
        (skill?.files ?? []).sorted { a, b in
            if a.path == SkillPackage.mainFile { return true }
            if b.path == SkillPackage.mainFile { return false }
            return a.path < b.path
        }
    }
    private var current: SkillPackage.File? { files.first { $0.path == file } ?? files.first }
    private var subtitle: String {
        if isNew { return "新建，还没保存" }
        return saved?.isBuiltin == true ? "随 Kite 提供" : "自建"
    }

    var body: some View {
        PaneWindow(header: PaneHeader(title: name, subtitle: subtitle,
                                      titleEdit: isNew ? .init(label: "改名", enabled: !saving) { rename($0) } : nil),
                   notice: error.map(PaneNotice.failure), actions: PaneHeaderActions(groups: headerGroups)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if skill != nil {
                        SkillFileTabs(files: files, selected: Binding(get: { current?.path ?? SkillPackage.mainFile }, set: { file = $0 }),
                                      add: { newPath = ""; adding = true }, importFiles: { replacing = nil; importing = true })
                            .disabled(saving)
                        if let current {
                            let path = current.path
                            if current.isBinary {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "doc")
                                        .font(Theme.body)
                                    Text("\(UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?.localizedDescription ?? "文件") · \(ByteCountFormatter.string(fromByteCount: Int64(current.byteCount), countStyle: .file))")
                                        .font(Theme.secondary).foregroundStyle(.secondary)
                                    Text("文件会原样保存并同步。可从标题栏导出，或选择新文件替换。")
                                        .font(Theme.secondary).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                SkillFileEditor(path: path,
                                            text: Binding(get: { [model, name] in model.librarySkill(name)?.files.first { $0.path == path }?.content ?? "" },
                                                          set: { [model, name] value in
                                                              model.editSkill(name) { draft in
                                                                  if let index = draft.skill.files.firstIndex(where: { $0.path == path }) { draft.skill.files[index].content = value }
                                                              }
                                                          }),
                                            focused: $focused)
                                .disabled(saving)
                                .id(path)
                            }
                        }
                    }
                }
                .agentContextColumn()
            }
        } controls: { _ in
            if current?.isBinary == false { ContextEditorToolbar(variables: []).disabled(saving) }
        }
        // 没有自己的模型，由工作机按默认模型数 token。
        .contextEditor(editor, counting: model.contextCounting(model: nil, connection: model.activeConnection))
        .alert("新建文本文件", isPresented: $adding) {
            TextField("相对路径，如 templates/AGENTS.md", text: $newPath)
            Button("添加", action: addFile)
            Button("取消", role: .cancel) {}
        } message: {
            Text("路径相对 skill 文件夹。图片、PDF 等已有文件可通过「导入文件」添加。")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: replacing == nil, onCompletion: importFiles)
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType, defaultFilename: exportName) { result in
            if case .failure(let failure) = result { error = "导出失败：\(failure.localizedDescription)" }
        }
        .discardAlert(isNew ? "放弃这个新 skill？" : "放弃未保存的修改？", isPresented: $discard, discardLabel: isNew ? "放弃新 skill" : "放弃修改") {
            model.skillDrafts.removeAll { $0.id == name }
        }
        .discardAlert("恢复默认内容？", isPresented: $confirmReset, discardLabel: "恢复默认",
                      message: "整个文件夹换回随 Kite 提供的内容\(draft == nil ? "。" : "，未保存的修改一并放弃。")", discard: reset)
        .discardAlert("删除这个 skill？", isPresented: $confirmDelete, discardLabel: "删除", message: "从资源库删掉，各工作机同步后一起删。", discard: delete)
        .discardAlert("删除文件 \(current?.path ?? "")？", isPresented: $confirmRemoveFile, discardLabel: "删除文件", message: "保存后才真正删掉。", discard: removeFile)
    }

    /// 选中的不是 SKILL.md 时能删这个文件；随 kited 带的改过才能恢复默认；自建已存的能删；有草稿才能保存或放弃。
    private var headerGroups: [[PaneHeaderAction]] {
        var groups: [[PaneHeaderAction]] = []
        var first: [PaneHeaderAction] = []
        if let current {
            groups.append([
                PaneHeaderAction(title: "替换文件", systemImage: "arrow.triangle.2.circlepath", disabled: saving) {
                    replacing = current.path
                    importing = true
                },
                PaneHeaderAction(title: "导出文件", systemImage: "square.and.arrow.up", action: exportFile),
            ])
        }
        if let current, current.path != SkillPackage.mainFile {
            first.append(PaneHeaderAction(title: "删除文件", systemImage: "doc.badge.minus", disabled: saving) { confirmRemoveFile = true })
        }
        if saved?.canReset == true {
            first.append(PaneHeaderAction(title: "恢复默认", systemImage: "arrow.counterclockwise", help: model.connected ? "恢复默认" : "工作机未连接",
                                          disabled: !canSave) { confirmReset = true })
        }
        if let saved, !saved.isBuiltin {
            first.append(PaneHeaderAction(title: "删除 skill", systemImage: "trash", help: model.connected ? "删除 skill" : "工作机未连接",
                                          disabled: !canSave, tint: Theme.danger) { confirmDelete = true })
        }
        if !first.isEmpty { groups.append(first) }
        if draft != nil {
            groups.append([
                PaneHeaderAction(title: isNew ? "放弃新 skill" : "放弃修改", systemImage: isNew ? "trash" : "xmark", disabled: saving) { discard = true },
                PaneHeaderAction(title: "保存", systemImage: "checkmark", help: model.connected ? "保存" : "工作机未连接",
                                 busy: saving, disabled: !canSave, action: save),
            ])
        }
        return groups
    }

    private func save() {
        guard let draft, canSave else { return }
        perform("保存", draftID: draft.id) { connection in
            try await model.saveSkill(draft, connection: connection)
        }
    }

    private func reset() {
        guard let saved, canSave else { return }
        perform("恢复默认", draftID: saved.id) { connection in
            try await model.resetSkill(saved, connection: connection)
        }
    }

    private func delete() {
        guard let saved, canSave else { return }
        perform("删除", draftID: saved.id) { connection in
            try await model.deleteSkill(saved, connection: connection)
        }
    }

    private func perform(_ title: String, draftID: String, operation: @escaping (UUID) async throws -> Void) {
        let connection = model.connectionRevision
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await operation(connection)
                model.skillDrafts.removeAll { $0.id == draftID }
            } catch {
                self.error = "\(title)失败：\(error.localizedDescription)"
            }
        }
    }

    private func addFile() {
        let path = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            error = "路径要是文件夹里的相对路径，不含 . 或 .."
            return
        }
        guard skill?.files.contains(where: { $0.path == path }) != true else { error = "已有这个文件"; return }
        error = nil
        model.editSkill(name) { $0.skill.files.append(SkillPackage.File(path: path, content: "")) }
        file = path
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let skill, !urls.isEmpty else { return }
            var files = skill.files
            var selected = file
            for url in urls {
                let imported = try SkillPackage.File.importing(url, path: replacing)
                if let index = files.firstIndex(where: { $0.path == imported.path }) {
                    guard replacing != nil else { throw KitedError(message: "已有 \(imported.path)，请选中后用「替换文件」更新") }
                    files[index] = imported
                } else {
                    files.append(imported)
                }
                selected = imported.path
            }
            guard files.count <= 200 else { throw KitedError(message: "一个 skill 最多包含 200 个文件") }
            guard files.reduce(0, { $0 + $1.byteCount }) <= SkillPackage.maximumBytes else { throw KitedError(message: "skill 整包不能超过 4 MiB") }
            model.editSkill(name) { $0.skill.files = files }
            file = selected
            error = nil
        } catch {
            self.error = "导入失败：\(error.localizedDescription)"
        }
        replacing = nil
    }

    private func exportFile() {
        guard let current, let data = current.data else { error = "无法读取文件内容"; return }
        let url = URL(fileURLWithPath: current.path)
        exportDocument = SkillFileDocument(data: data)
        exportName = url.lastPathComponent
        exportType = UTType(filenameExtension: url.pathExtension) ?? .data
        exporting = true
    }

    private func removeFile() {
        guard let current, current.path != SkillPackage.mainFile else { return }
        model.editSkill(name) { $0.skill.files.removeAll { $0.path == current.path } }
        file = SkillPackage.mainFile
    }

    private func rename(_ title: String) {
        do {
            try model.renameNewSkill(name, to: title.trimmingCharacters(in: .whitespacesAndNewlines))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 文件夹里的文件，一个挨一个靠左排，放不下换行；选中的带底色，末尾是添加。
private struct SkillFileTabs: View {
    let files: [SkillPackage.File]
    @Binding var selected: String
    let add: () -> Void
    let importFiles: () -> Void

    var body: some View {
        AttachmentFlow(spacing: 6, trailing: false) {
            ForEach(files) { file in
                Button { selected = file.path } label: {
                    Text(file.path)
                        .font(Theme.code)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(selected == file.path ? Color.accentColor.opacity(0.18) : ComposerLayout.fieldFill, in: Capsule())
                }
                .buttonStyle(.pointingPlain)
                .accessibilityAddTraits(selected == file.path ? .isSelected : [])
            }
            Button(action: add) {
                Label("新建文本文件", systemImage: "plus")
                    .font(Theme.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(Theme.rule))
            }
            .buttonStyle(.pointingPlain)
            Button(action: importFiles) {
                Label("导入文件", systemImage: "square.and.arrow.down")
                    .font(Theme.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(Theme.rule))
            }
            .buttonStyle(.pointingPlain)
        }
    }
}

/// skill 文件夹里的一份文件：和段落一样直接改，Markdown 标记按样式显示，存回去的是原文。不套卡片，字和正文的边对齐。
private struct SkillFileEditor: View {
    let path: String
    @Binding var text: String
    @Binding var focused: Bool

    var body: some View {
        ContextParagraphField(parts: Binding(get: { text.isEmpty ? [] : [.text(text)] }, set: { text = $0.plainText }),
                              variables: [], focused: $focused,
                              placeholder: path == SkillPackage.mainFile ? "SKILL.md：开头是 --- 包起来的 name 与 description，后面是做法" : "文件内容")
            // 段落的字离卡片边留了一圈，这里没有卡片，收回去
            .padding(-ContextTextStyle.inset)
    }
}
