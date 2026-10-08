import SwiftUI

struct ContextTemplateEdit: Identifiable {
    let definition: ContextDefinition
    var original: ContextTemplate? = nil
    var id: String { definition.id }
}

/// 设置与新会话共用的模板编辑器；保存失败或冲突时保留草稿。
struct ContextTemplateEditor: View {
    let request: ContextTemplateEdit
    @State private var connection: UUID
    var onSaved: (ContextTemplate) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ContextDefinition
    @State private var phase = CardPhase.idle
    @State private var discard = false
    /// 只跟踪模板名称；段落编辑器里的输入框由拖动收起键盘。
    @FocusState private var typing: Bool

    init(request: ContextTemplateEdit, connection: UUID, onSaved: @escaping (ContextTemplate) -> Void = { _ in }) {
        self.request = request
        _connection = State(initialValue: connection)
        self.onSaved = onSaved
        _draft = State(initialValue: request.definition)
    }

    private var changed: Bool { draft != request.definition }
    private var variables: [ContextScene.Variable] {
        model.templateConnection(connection)?.templates?.scenes.first { $0.id == draft.scene }?.variables ?? []
    }
    private var available: Bool { model.templateConnection(connection)?.connected == true }

    var body: some View {
        CardSheet(title: request.original == nil ? "新建上下文模板" : "编辑上下文模板",
                  subtitle: "双击段落编辑文字。变量在运行时填入；条件页签用于编辑各个分支。",
                  typing: typing, size: CGSize(width: 720, height: 680),
                  close: { if changed { discard = true } else { dismiss() } }) {
            Group {
                CardField(label: "模板名称", focused: typing) {
                    TextField("模板名称", text: $draft.title)
                        .focused($typing)
                        .cardInput { typing = true }
                }
                if let input = Binding($draft.input) {
                    Text("命名规则").font(.headline)
                    ContextBlocksEditor(blocks: $draft.blocks, variables: variables)
                    Divider()
                    Text("材料").font(.headline)
                    ContextBlocksEditor(blocks: input, variables: variables)
                } else {
                    ContextBlocksEditor(blocks: $draft.blocks, variables: variables)
                }
            }
            .disabled(working || !available)
            if !available { CardCallout(text: "工作机连接已变化，请返回后重新打开模板。草稿尚未保存。", systemImage: "info.circle", tint: .secondary) }
        } footer: {
            CardActions(primary: "保存",
                        enabled: !working && available && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        phase: $phase, action: save)
        }
        .interactiveDismissDisabled(working || changed)
        .confirmationDialog("放弃未保存的模板修改？", isPresented: $discard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
        }
    }

    private var working: Bool { phase.working }

    /// 保存成功后弹窗直接关掉。
    private func save() {
        $phase.run {
            let saved = try await model.saveContextTemplate(draft, expectedRevision: request.original?.revision, connection: connection)
            onSaved(saved)
            dismiss()
        }
    }
}

private struct ContextBlocksEditor: View {
    @Binding var blocks: [ContextBlock]
    let variables: [ContextScene.Variable]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach($blocks) { $block in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("段落或条件名称", text: $block.title).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                        Button("上移", systemImage: "arrow.up") { move(block.id, by: -1) }
                            .disabled(blocks.first?.id == block.id)
                        Button("下移", systemImage: "arrow.down") { move(block.id, by: 1) }
                            .disabled(blocks.last?.id == block.id)
                        Button("删除", systemImage: "trash", role: .destructive) {
                            let id = block.id
                            blocks.removeAll { $0.id == id }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    if block.type == "paragraph" {
                        ContextParagraphEditor(parts: Binding(get: { block.parts ?? [] }, set: { block.parts = $0 }), variables: variables)
                    } else {
                        ContextConditionEditor(block: $block, variables: variables)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Button("添加段落", systemImage: "text.badge.plus") { blocks.append(.paragraph()) }
                Button("添加条件", systemImage: "arrow.triangle.branch") {
                    if let variable = variables.first { blocks.append(.condition(variable: variable.name)) }
                }.disabled(variables.isEmpty)
            }
            .buttonStyle(.bordered)
        }
    }

    private func move(_ id: String, by offset: Int) {
        guard let index = blocks.firstIndex(where: { $0.id == id }), blocks.indices.contains(index + offset) else { return }
        blocks.swapAt(index, index + offset)
    }
}

private struct ContextParagraphEditor: View {
    @Binding var parts: [ContextPart]
    let variables: [ContextScene.Variable]
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editing {
                ForEach($parts) { $part in
                    HStack(alignment: .top, spacing: 8) {
                        if part.type == "variable" {
                            Menu {
                                ForEach(variables) { variable in
                                    Button(variable.title) { part.name = variable.name }
                                }
                            } label: { chip(part.name ?? "") }
                        } else {
                            TextField("段落文字", text: Binding(get: { part.text ?? "" }, set: { part.text = $0 }), axis: .vertical)
                                .lineLimit(1...8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                        Button("前移", systemImage: "arrow.up") { move(part.id, by: -1) }.disabled(parts.first?.id == part.id)
                        Button("后移", systemImage: "arrow.down") { move(part.id, by: 1) }.disabled(parts.last?.id == part.id)
                        Button("移除", systemImage: "minus.circle") {
                            let id = part.id
                            parts.removeAll { $0.id == id }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
                HStack {
                    Button("添加文字") { parts.append(.text("")) }
                    Menu("插入变量") {
                        ForEach(variables) { variable in
                            Button(variable.title) { parts.append(.variable(variable.name)) }
                        }
                    }
                    Spacer()
                    Button("完成") { editing = false }
                }
                .buttonStyle(.bordered)
            } else {
                ContextPartFlow {
                    ForEach(parts) { part in
                        if part.type == "variable" { chip(part.name ?? "") }
                        else { Text(part.text ?? "").fixedSize(horizontal: false, vertical: true) }
                    }
                    if parts.isEmpty || parts.allSatisfy({ $0.type == "text" && ($0.text ?? "").isEmpty }) {
                        Text("双击添加段落内容").foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { editing = true }
                Button("编辑段落", systemImage: "pencil") { editing = true }.font(.caption).buttonStyle(.borderless)
            }
        }
        .font(.callout)
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = parts.firstIndex(where: { $0.id == id }), parts.indices.contains(index + offset) else { return }
        parts.swapAt(index, index + offset)
    }

    private func chip(_ name: String) -> some View {
        Text(variables.first { $0.name == name }?.title ?? name)
            .font(.caption)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}

private struct ContextConditionEditor: View {
    @Binding var block: ContextBlock
    let variables: [ContextScene.Variable]
    @State private var selected = ""

    private var branches: [ContextBranch] { (block.cases ?? []) + [block.otherwise].compactMap { $0 } }
    private var currentID: String { branches.contains { $0.id == selected } ? selected : branches.first?.id ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("根据变量", selection: Binding(get: { block.variable ?? "" }, set: { block.variable = $0 })) {
                ForEach(variables) { Text($0.title).tag($0.name) }
            }
            ScrollView(.horizontal) {
                HStack {
                    ForEach(branches) { branch in
                        Button(branch.title) { selected = branch.id }
                            .buttonStyle(.bordered)
                            .tint(currentID == branch.id ? .accentColor : .secondary)
                    }
                    Button("添加分支", systemImage: "plus") {
                        let branch = ContextBranch(title: "新分支", equals: "值\((block.cases ?? []).count + 1)", blocks: [])
                        block.cases = (block.cases ?? []) + [branch]
                        selected = branch.id
                    }.labelStyle(.iconOnly)
                }
            }.scrollIndicators(.hidden)
            if let branch = binding(currentID) {
                HStack {
                    TextField("分支名称", text: branch.title)
                    if branch.wrappedValue.equals != nil {
                        Button("删除分支", systemImage: "trash", role: .destructive) {
                            let id = currentID
                            block.cases?.removeAll { $0.id == id }
                        }.labelStyle(.iconOnly)
                    }
                }
                if branch.wrappedValue.equals != nil {
                    TextField("匹配文本（留空表示空值）", text: Binding(get: { branch.wrappedValue.equals ?? "" }, set: { branch.wrappedValue.equals = $0 }))
                } else {
                    Text("未匹配其他分支时使用这里的内容。").font(.caption).foregroundStyle(.secondary)
                }
                // 显式擦除递归的视图类型，数据仍保留完整分支结构。
                AnyView(ContextBlocksEditor(blocks: branch.blocks, variables: variables))
            }
        }
    }

    private func binding(_ id: String) -> Binding<ContextBranch>? {
        guard let original = branches.first(where: { $0.id == id }) else { return nil }
        return Binding(get: { branches.first { $0.id == id } ?? original }, set: { value in
            if let index = block.cases?.firstIndex(where: { $0.id == id }) { block.cases?[index] = value }
            else if block.otherwise?.id == id { block.otherwise = value }
        })
    }
}

/// 文字和变量 chip 按内容换行，长文字使用当前可用宽度。
private struct ContextPartFlow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(width: proposal.width ?? 400, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = positions(width: bounds.width, subviews: subviews)
        for (index, view) in subviews.enumerated() {
            let rect = layout.frames[index]
            view.place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                       proposal: ProposedViewSize(rect.size))
        }
    }
    private func positions(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        var frames: [CGRect] = []
        let width = max(width, 1)
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width { x = 0; y += row + 4; row = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + 4
            row = max(row, size.height)
        }
        return (frames, CGSize(width: width, height: y + row))
    }
}
