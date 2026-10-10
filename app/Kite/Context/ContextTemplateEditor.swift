import SwiftUI

/// 旁路任务与事件通知模板的内容，在资源库代理上下文的模板窗口里编辑；名称固定为内置名称。代理的提示词在角色里改。
/// 标题、压缩与签名分两节：指令是系统规则，材料作为用户消息发出。事件通知只有一节，插进会话的消息。
struct ContextTemplateForm: View {
    @Binding var definition: ContextDefinition
    let variables: [ContextScene.Variable]

    var body: some View {
        if let input = Binding($definition.input) {
            ContextSection("系统规则") {
                ContextBlocksEditor(blocks: $definition.blocks, variables: variables)
            }
            ContextSection("用户消息") {
                ContextBlocksEditor(blocks: input, variables: variables)
            }
        } else {
            ContextSection("通知消息") {
                ContextBlocksEditor(blocks: $definition.blocks, variables: variables)
            }
        }
    }
}

/// 编辑区的一节：标题后面一条分割线通到右边，比块名高一级。节与节之间多留一截空白。
struct ContextSection<Content: View>: View {
    let title: String
    var icon: String?
    @ViewBuilder let content: Content

    init(_ title: String, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Group {
                    if let icon { Label(title, systemImage: icon) } else { Text(title) }
                }
                .font(Theme.heading3)
                .fixedSize()
                Rectangle().fill(Theme.rule).frame(height: 1)
            }
            content
        }
        .padding(.bottom, 12)
    }
}

/// 弹窗里的上下文编辑：没有窗口底栏，工具栏放在正文上方。
struct ContextEditing<Content: View>: View {
    let variables: [ContextScene.Variable]
    let counting: ContextCounting?
    @ViewBuilder let content: Content
    @State private var editor = ContextEditor()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ContextVariablePreview(variables: variables)
            ContextEditorToolbar(variables: variables)
            content
        }
        .contextEditor(editor, counting: counting)
    }
}

/// 正文开头的可用变量一节：标题前是工具栏插入变量的同一个图标，胶囊和正文里的变量同样子，后面是说明。
/// 窄屏上胶囊一行、说明换到下一行，宽屏胶囊与说明并排对齐。只供查看，插入在工具栏。
struct ContextVariablePreview: View {
    let variables: [ContextScene.Variable]
    @Environment(\.workspacePresentation) private var presentation

    var body: some View {
        if !variables.isEmpty {
            ContextSection("可用变量", icon: ContextScene.Variable.icon) {
                Group {
                    if presentation == .compact {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(variables) { variable in
                                VStack(alignment: .leading, spacing: 4) {
                                    ContextVariableChip(title: variable.title)
                                    description(variable)
                                }
                            }
                        }
                    } else {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                            ForEach(variables) { variable in
                                GridRow {
                                    ContextVariableChip(title: variable.title)
                                    description(variable)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private func description(_ variable: ContextScene.Variable) -> some View {
        Text(variable.description)
            .font(Theme.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 模板与角色提示词共用的段落、条件编辑器。段落是一张和代码块、表格同样式的卡片；条件是包住段落的描边框，不是和段落同级的卡片。
/// 两者顶上都是拖动手柄、可改的名称和计数。长按手柄拖动换位置，只在同一层里换。条件里的段落和外面的同一个样子，圆角与外框同心。
struct ContextBlocksEditor: View {
    @Binding var blocks: [ContextBlock]
    let variables: [ContextScene.Variable]
    var depth = 0
    @Environment(ContextEditor.self) private var editor
    @State private var dragging: String?
    @State private var dragOffset: CGFloat = 0
    @State private var heights: [String: CGFloat] = [:]
    private let spacing: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach($blocks) { $block in
                let id = block.id
                let shift = shift(of: id)
                ContextBlockView(block: $block, variables: variables, depth: depth, handle: handle(id),
                                 lifted: dragging == id, drag: ContextDrag(changed: { drag(id, by: $0) }, ended: drop))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[id] = $0 }
                    .offset(y: shift)
                    .animation(.snappy(duration: 0.2), value: shift)
                    .offset(y: dragging == id ? dragOffset : 0)
                    .zIndex(dragging == id ? 1 : 0)
            }
            HStack(spacing: 16) {
                Button { add(.paragraph()) } label: { Label("添加段落", systemImage: "plus") }
                if let variable = variables.first {
                    Button { add(.condition(variable: variable.name)) } label: { Label("添加条件", systemImage: "arrow.triangle.branch") }
                }
            }
            .font(Theme.secondary)
            .foregroundStyle(Color.accentColor)
            .buttonStyle(.pointingPlain)
            .padding(.horizontal, ContextTextStyle.inset)
        }
        .sensoryFeedback(.selection, trigger: dragging != nil)
    }

    private func add(_ block: ContextBlock) {
        editor.focusRequest = block.id
        blocks.append(block)
    }

    /// 当前块的位置和操作每次从列表现取，移动、删除后工具栏跟着变。
    private func handle(_ id: String) -> ContextBlockHandle {
        let list = $blocks
        let editor = editor
        return ContextBlockHandle(id: id, state: {
            let blocks = list.wrappedValue
            guard let index = blocks.firstIndex(where: { $0.id == id }) else { return nil }
            return .init(title: blocks[index].title, paragraph: blocks[index].type == "paragraph", empty: blocks[index].isEmpty,
                         first: index == 0, last: index == blocks.count - 1)
        }, perform: { action in
            guard let index = list.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
            switch action {
            case .move(let offset):
                guard list.wrappedValue.indices.contains(index + offset) else { return }
                withAnimation(.snappy(duration: 0.25)) { list.wrappedValue.swapAt(index, index + offset) }
            case .insert(let block):
                list.wrappedValue.insert(block, at: index + 1)
            case .delete:
                list.wrappedValue.remove(at: index)
                if editor.current?.id == id { editor.current = nil }
            }
        })
    }

    // MARK: 拖动换位置

    private func drag(_ id: String, by offset: CGFloat) {
        dragging = id
        dragOffset = offset
    }

    /// 拖着的块中线越过相邻块的一半就换到它那边。
    private var target: Int? {
        guard let dragging, let from = blocks.firstIndex(where: { $0.id == dragging }) else { return nil }
        var index = from, travelled: CGFloat = 0
        if dragOffset > 0 {
            while index + 1 < blocks.count {
                let next = (heights[blocks[index + 1].id] ?? 0) + spacing
                if dragOffset < travelled + next / 2 { break }
                travelled += next
                index += 1
            }
        } else {
            while index > 0 {
                let previous = (heights[blocks[index - 1].id] ?? 0) + spacing
                if -dragOffset < travelled + previous / 2 { break }
                travelled += previous
                index -= 1
            }
        }
        return index
    }

    /// 其他块给拖着的块让位。
    private func shift(of id: String) -> CGFloat {
        guard let dragging, dragging != id, let to = target,
              let from = blocks.firstIndex(where: { $0.id == dragging }),
              let index = blocks.firstIndex(where: { $0.id == id }) else { return 0 }
        let height = (heights[dragging] ?? 0) + spacing
        if from < to, index > from, index <= to { return -height }
        if to < from, index >= to, index < from { return height }
        return 0
    }

    private func drop() {
        guard let dragging else { return }
        let to = target
        withAnimation(.snappy(duration: 0.25)) {
            if let to, let from = blocks.firstIndex(where: { $0.id == dragging }), to != from {
                blocks.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
            }
            self.dragging = nil
            dragOffset = 0
        }
    }
}

/// 拖动手柄把位移报给所在的列表。
private struct ContextDrag {
    let changed: (CGFloat) -> Void
    let ended: () -> Void
}

/// 第几层的圆角：最外层与代码块相同，往里一层按条件框的内边距收小，与外框同心。
private struct ContextCardLevel {
    let depth: Int
    var radius: CGFloat { depth == 0 ? Metrics.contentRadius : Metrics.nestedRadius(inset: ContextTextStyle.inset * CGFloat(depth)) }
}

private struct ContextBlockView: View {
    @Binding var block: ContextBlock
    let variables: [ContextScene.Variable]
    let depth: Int
    let handle: ContextBlockHandle
    let lifted: Bool
    let drag: ContextDrag
    @Environment(ContextEditor.self) private var editor
    @State private var focused = false
    /// 打开以后改过文字才等停手再数；刚打开时直接数。
    @State private var edited = false
    /// 指针停在手柄上；手指触摸没有悬停。
    @State private var pointing = false
    @GestureState private var grabbing = false
    /// 手柄按住的范围：宽和工具栏按钮的图标一样，高度占满标题栏的按钮高度。
    @ScaledMetric(relativeTo: .body) private var gripExtent: CGFloat = InputMode.current.labelExtent
    @Environment(\.fontResolutionContext) private var fontContext

    private var paragraph: Bool { block.type == "paragraph" }
    private var text: String { (block.parts ?? []).literalText }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ContextCardLevel(depth: depth).radius, style: .continuous)
        let current = editor.current?.id == block.id
        Group {
            if paragraph {
                BlockCard(radius: ContextCardLevel(depth: depth).radius) {
                    title
                } actions: { _ in
                    count
                } content: {
                    ContextParagraphField(parts: Binding(get: { block.parts ?? [] }, set: { block.parts = $0 }), variables: variables,
                                          focused: $focused, focusRequested: editor.focusRequest == block.id,
                                          focusHandled: { editor.focusRequest = nil })
                        .task(id: "\(editor.countingKey ?? "")|\(text)") {
                            guard editor.countingKey != nil, !text.isEmpty, editor.count(of: text) == nil else { return }
                            // 停止输入一秒后才数，打字过程中不发请求。
                            if edited { try? await Task.sleep(for: .seconds(1)) }
                            guard !Task.isCancelled else { return }
                            await editor.request(text)
                        }
                        .onChange(of: text) { edited = true }
                }
            } else {
                // 条件包住段落：只描边不填色，顶上一行与段落卡片的标题栏同样的边距，两种块的手柄对齐。拖起来时垫上底色，盖住后面的块。
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Metrics.paneButtonGap) {
                        title
                        Spacer(minLength: 12)
                        count
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, (Metrics.paneButton - Theme.body.resolve(in: fontContext).pointSize) / 2 + Metrics.codeHeaderInset)
                    .padding(.trailing, Metrics.paneToolbarInset)
                    .padding(.vertical, Metrics.codeHeaderInset)
                    ContextConditionEditor(block: $block, variables: variables, depth: depth)
                }
                .background { if lifted { shape.fill(Theme.card) } }
                .overlay { shape.strokeBorder(Theme.rule) }
            }
        }
        .overlay {
            shape.strokeBorder(Color.accentColor.opacity(focused ? 0.8 : current ? 0.35 : 0), lineWidth: 1.5)
        }
        .animation(.easeOut(duration: 0.15), value: focused)
        .scaleEffect(lifted ? 1.015 : 1)
        .shadow(color: .black.opacity(lifted ? 0.18 : 0), radius: lifted ? 12 : 0, y: lifted ? 4 : 0)
        .animation(.snappy(duration: 0.2), value: lifted)
        .onChange(of: focused) { _, now in if now { editor.current = handle } }
        .onAppear {
            // 新加的条件没有正文可放光标，直接当作当前块。
            if !paragraph, editor.focusRequest == block.id {
                editor.focusRequest = nil
                editor.current = handle
            }
        }
    }

    /// 手柄与名称；条件在名称前多一个分支图标。不用卡片给代码块语言标签的等宽小字，和分支名同级，手柄跟着名称的字号字重。
    private var title: some View {
        HStack(spacing: 4) {
            grip
            if !paragraph { Image(systemName: "arrow.triangle.branch") }
            ContextNameField(title: $block.title, placeholder: paragraph ? "段落名称" : "条件名称")
        }
        .font(Theme.secondary.weight(.medium))
        .simultaneousGesture(TapGesture().onEnded { editor.current = handle })
    }

    private var count: some View {
        ContextCountLabel(total: editor.total(of: [block]), paragraph: paragraph,
                          variables: paragraph && (block.parts ?? []).contains { $0.type == "variable" })
            .simultaneousGesture(TapGesture().onEnded { editor.current = handle })
    }

    /// 拖手柄调整顺序，松手或手势被取消都会落下。按输入方式分：指针停在手柄上时按住就拖，三指拖移一碰就开始移动，等不到长按；
    /// 手指没有悬停，先长按再拖，免得和滚动抢。拖动中不换手势，块跟着指针走时悬停可能短暂断开。
    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.tertiary)
            .frame(width: gripExtent, height: Metrics.paneButton)
            .contentShape(Rectangle())
            .onHover { hovering in if !grabbing { pointing = hovering } }
            .grabPointer(grabbing)
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .updating($grabbing) { _, state, _ in state = true }
                .onChanged { moved($0.translation.height) }, isEnabled: pointing)
            .gesture(LongPressGesture(minimumDuration: 0.25)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                .updating($grabbing) { value, state, _ in if case .second(true, _) = value { state = true } }
                .onChanged { value in
                    if case .second(true, let movement) = value { moved(movement?.translation.height ?? 0) }
                }, isEnabled: !pointing)
            .onChange(of: grabbing) { _, now in if !now { drag.ended() } }
            .help("拖动调整顺序")
            .accessibilityLabel("移动\(paragraph ? "段落" : "条件")")
            .accessibilityActions {
                Button("上移") { handle.perform(.move(-1)) }
                Button("下移") { handle.perform(.move(1)) }
            }
    }

    private func moved(_ offset: CGFloat) {
        if editor.current?.id != block.id { editor.current = handle }
        drag.changed(offset)
    }
}

private extension ContextBlock {
    /// 段落没有文字和变量，或条件的各分支都没有内容。
    var isEmpty: Bool {
        if type == "paragraph" { return (parts ?? []).normalized.isEmpty }
        return ((cases ?? []) + [otherwise].compactMap { $0 }).allSatisfy(\.blocks.isEmpty)
    }
}

/// 标题栏右边的计数：数出 token 就显示 token，不然显示字数；重数期间先留着上次的值。明细按输入方式看：指针悬停显示提示，手指点开气泡。
private struct ContextCountLabel: View {
    let total: ContextTotal
    let paragraph: Bool
    let variables: Bool
    @Environment(AppModel.self) private var model
    @State private var last: ContextTotal?
    @State private var explaining = false
    @State private var pointing = false

    var body: some View {
        let shown = total.tokens != nil ? total : last ?? total
        Text(label(shown))
            .font(Theme.status.monospacedDigit())
            .foregroundStyle(.secondary)
            .opacity(shown == total ? 1 : 0.6)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(minHeight: Metrics.paneButton)
            .contentShape(Rectangle())
            .help(detail)
            .onHover { pointing = $0 }
            .onChange(of: total) { _, value in if value.tokens != nil { last = value } }
            .onTapGesture { if !pointing { explaining = true } }
            .popover(isPresented: $explaining) {
                Text(detail).font(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(14).frame(maxWidth: 300, alignment: .leading)
                    .presentationCompactAdaptation(.popover)
            }
    }

    private func label(_ total: ContextTotal) -> String {
        guard let tokens = total.tokens, total.method != nil, total.method != "none" else { return "\(total.characters) 字" }
        return total.exact ? "\(tokens) tokens" : "约 \(tokens) tokens"
    }

    private var detail: String {
        var lines = ["\(total.characters) 字"]
        if let method = total.method, let id = total.model {
            let name = model.modelTitle(id)
            switch method {
            case "api": lines.append("\(name)：官方计数接口")
            case "o200k": lines.append(total.exact ? "\(name)：o200k 分词" : "\(name)：没有公开分词表，按 o200k 分词估算")
            default: lines.append("\(name)：没有公开分词器，资源库里有这家的 API Key 时才能计数")
            }
        }
        if !paragraph { lines.append("只算选中的分支") }
        if variables { lines.append("变量的值运行时才有，不算在内") }
        return lines.joined(separator: "\n")
    }
}

/// 条件框的正文：上面是变量和分支页签，下面是选中分支的名称、匹配值和内容。选中哪个分支记在窗口的编辑状态里，计数跟着它。
/// 框不填色，页签和输入框用段落卡片的底色。
private struct ContextConditionEditor: View {
    @Binding var block: ContextBlock
    let variables: [ContextScene.Variable]
    let depth: Int
    @Environment(ContextEditor.self) private var editor
    @State private var confirmingDelete = false
    @FocusState private var matchFocused: Bool

    private var branches: [ContextBranch] { (block.cases ?? []) + [block.otherwise].compactMap { $0 } }
    private var currentID: String {
        let selected = editor.branches[block.id] ?? ""
        return branches.contains { $0.id == selected } ? selected : branches.first?.id ?? ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("按")
                variableMenu
                Text("的值选择")
            }
            .font(Theme.secondary)
            .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(branches) { branch in
                        tab(branch)
                    }
                    Button(action: addBranch) { PaneButtonLabel("添加分支", systemImage: "plus") }
                        .buttonStyle(PaneButtonStyle())
                        .help("添加分支")
                }
            }
            .scrollIndicators(.hidden)
            if let branch = binding(currentID) {
                branchFields(branch)
                // 显式擦除递归的视图类型，数据仍保留完整分支结构。
                AnyView(ContextBlocksEditor(blocks: branch.blocks, variables: variables, depth: depth + 1))
            }
        }
        .padding(ContextTextStyle.inset)
        .alert("删除分支「\(binding(currentID)?.wrappedValue.title ?? "")」？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive, action: deleteBranch)
            Button("取消", role: .cancel) {}
        } message: {
            Text("分支里的内容会一起删掉。")
        }
    }

    private var variableMenu: some View {
        let variable = variables.first { $0.name == block.variable }
        return Menu {
            ForEach(variables) { item in
                Button(item.title) { block.variable = item.name }
            }
        } label: {
            HStack(spacing: 3) {
                ContextVariableChip(title: variable?.title ?? block.variable ?? "", missing: variable == nil)
                Image(systemName: "chevron.down").font(Theme.status.weight(.semibold))
            }
        }
        .menuStyle(.button).buttonStyle(.pointingPlain).menuIndicator(.hidden).fixedSize()
        .help(variable?.description ?? "选择变量")
    }

    private func tab(_ branch: ContextBranch) -> some View {
        let current = branch.id == currentID
        return Button { editor.branches[block.id] = branch.id } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(branch.title).font(Theme.secondary.weight(.medium))
                Text(match(branch)).font(Theme.status).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .foregroundStyle(current ? Color.accentColor : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(current ? Color.accentColor.opacity(0.14) : Theme.codeBackground,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.pointingPlain)
    }

    private func match(_ branch: ContextBranch) -> String {
        guard let equals = branch.equals else { return "其他情况" }
        return equals.isEmpty ? "为空" : "等于「\(equals)」"
    }

    @ViewBuilder
    private func branchFields(_ branch: Binding<ContextBranch>) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ContextNameField(title: branch.title, placeholder: "分支名称")
                    .font(Theme.body)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: CardMetrics.fieldHeight, alignment: .leading)
                    .background(Theme.codeBackground, in: shape)
                if branch.wrappedValue.equals != nil {
                    TextField("为空", text: Binding(get: { branch.wrappedValue.equals ?? "" }, set: { branch.wrappedValue.equals = $0 }))
                        .focused($matchFocused)
                        .cardInput { matchFocused = true }
                        .background(Theme.codeBackground, in: shape)
                        .overlay { shape.strokeBorder(Color.accentColor.opacity(matchFocused ? 0.8 : 0), lineWidth: 1.5) }
                        .help("变量的值等于这段文字时用这个分支；留空表示变量为空")
                    Button {
                        if branch.wrappedValue.blocks.isEmpty { deleteBranch() } else { confirmingDelete = true }
                    } label: {
                        PaneButtonLabel("删除分支", systemImage: "trash")
                    }
                    .buttonStyle(PaneButtonStyle())
                    .help("删除分支")
                }
            }
            if branch.wrappedValue.equals == nil {
                CardNote("其他分支都不匹配时用这里的内容。")
            } else if let other = (block.cases ?? []).first(where: { $0.id != branch.wrappedValue.id && $0.equals == branch.wrappedValue.equals }) {
                CardNote("和「\(other.title)」的匹配值相同，保存时会被拒绝。")
            }
        }
    }

    private func addBranch() {
        let branch = ContextBranch(title: "新分支", equals: "值\((block.cases ?? []).count + 1)", blocks: [])
        block.cases = (block.cases ?? []) + [branch]
        editor.branches[block.id] = branch.id
    }

    private func deleteBranch() {
        let id = currentID
        block.cases?.removeAll { $0.id == id }
    }

    private func binding(_ id: String) -> Binding<ContextBranch>? {
        guard let original = branches.first(where: { $0.id == id }) else { return nil }
        return Binding(get: { branches.first { $0.id == id } ?? original }, set: { value in
            if let index = block.cases?.firstIndex(where: { $0.id == id }) { block.cases?[index] = value }
            else if block.otherwise?.id == id { block.otherwise = value }
        })
    }
}

/// 块和分支的名称：名称不能为空，清空时保留原名，离开输入框后显示回原名。字体、颜色与边距由使用方给。
private struct ContextNameField: View {
    @Binding var title: String
    let placeholder: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear { text = title }
            .onChange(of: title) { _, value in if !focused { text = value } }
            .onChange(of: text) { _, value in
                let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, name != title { title = name }
            }
            .onChange(of: focused) { _, now in if !now { text = title } }
            .onSubmit { focused = false }
    }
}
