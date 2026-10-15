import SwiftUI

/// 事件通知、上下文压缩与辅助生成模板的内容，在资源库代理上下文的模板窗口里编辑；名称固定为内置名称。代理的提示词在角色里改。
/// 标题、压缩与签名分两节：指令是系统规则，材料作为用户消息发出。事件通知只有一节，插进会话的消息。
struct ContextTemplateForm: View {
    @Binding var definition: ContextDefinition
    let variables: [ContextScene.Variable]

    var body: some View {
        if let input = Binding($definition.input) {
            ContextBlocksSection("系统规则", blocks: $definition.blocks, variables: variables)
            ContextBlocksSection("用户消息", blocks: input, variables: variables)
        } else {
            ContextBlocksSection("通知消息", blocks: $definition.blocks, variables: variables)
        }
    }
}

/// 编辑区的一节：标题后面一条分割线通到右边，比块名高一级。节与节之间多留一截空白。
/// 给了选中动作的节，点标题、块之间或内容两侧的空白就选中，选中时标题和分割线用强调色。
/// 给了 expanded 的节整行标题都能点着展开、收起，分割线右端有箭头，收起时只留标题行。
struct ContextSection<Content: View>: View {
    let title: String
    let icon: String?
    let selected: Bool
    let select: (() -> Void)?
    let expanded: Binding<Bool>?
    @ViewBuilder let content: Content

    init(_ title: String, icon: String? = nil, selected: Bool = false, select: (() -> Void)? = nil, expanded: Binding<Bool>? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.selected = selected
        self.select = select
        self.expanded = expanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let expanded {
                let shown = expanded.wrappedValue
                Button { expanded.wrappedValue.toggle() } label: { header(chevron: shown) }
                    .buttonStyle(ContextPressFadeStyle())
                    .help(shown ? "收起\(title)" : "展开\(title)")
                    .accessibilityLabel(shown ? "收起\(title)" : "展开\(title)")
            } else {
                // 标题只是文字，点击交给背后的选中区
                header(chevron: nil).allowsHitTesting(false)
            }
            if expanded?.wrappedValue ?? true { content }
        }
        .padding(.bottom, 12)
        .background {
            if let select {
                // 横向铺满滚动区，内容两侧的空白也算本节
                Color.clear
                    .contentShape(Rectangle())
                    .containerRelativeFrame(.horizontal)
                    .onTapGesture(perform: select)
            }
        }
    }

    /// chevron 是展开与否，没有时不画箭头。
    private func header(chevron: Bool?) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                if let icon { Image(systemName: icon) }
            }
            .font(Theme.heading3)
            .fixedSize()
            Rectangle().fill(selected ? Color.accentColor : Theme.rule).frame(height: 1)
            if let chevron { ContextSectionChevron(expanded: chevron) }
        }
        .foregroundStyle(selected ? Color.accentColor : .primary)
    }
}

/// 行末箭头。
private struct ContextSectionChevron: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: expanded ? "chevron.up" : "chevron.down")
            .font(Theme.status.weight(.semibold))
            .imageScale(.small)
            .foregroundStyle(.secondary)
    }
}

/// 一节块列表：选中本节时工具栏的添加加在本节末尾，空着的节也能加。
struct ContextBlocksSection: View {
    let title: String
    @Binding var blocks: [ContextBlock]
    let variables: [ContextScene.Variable]
    @Environment(ContextEditor.self) private var editor

    init(_ title: String, blocks: Binding<[ContextBlock]>, variables: [ContextScene.Variable]) {
        self.title = title
        self._blocks = blocks
        self.variables = variables
    }

    private var id: String { "section:\(title)" }

    var body: some View {
        ContextSection(title, selected: editor.current?.id == id, select: { editor.current = handle }) {
            ContextBlocksEditor(blocks: $blocks, variables: variables)
        }
    }

    private var handle: ContextBlockHandle {
        let list = $blocks, title = title
        return ContextBlockHandle(id: id, state: {
            .init(title: title, kind: .section, empty: list.wrappedValue.isEmpty, first: true, last: true)
        }, perform: { action in
            if case .add(let block) = action { list.wrappedValue.append(block) }
        })
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
            ContextEditorToolbar(variables: variables, keyboardButton: false)
            content
        }
        .contextEditor(editor, counting: counting)
    }
}

/// 正文开头的可用变量一节：标题后是工具栏插入变量的同一个图标，按组列出，胶囊和正文里的变量同样子，后面是说明；分割线右端可以收起。
/// 窄屏上胶囊一行、说明换到下一行，宽屏胶囊与说明并排对齐，各组共用一列宽。插入在工具栏；给了 open 时点胶囊打开变量窗口。
struct ContextVariablePreview: View {
    let variables: [ContextScene.Variable]
    var open: ((String) -> Void)?
    @Environment(\.workspacePresentation) private var presentation
    /// 收起与否本机记住，各个模板和角色窗口一致。
    @AppStorage("context.variables.expanded") private var expanded = true

    var body: some View {
        if !variables.isEmpty {
            ContextSection("可用变量", icon: ContextScene.Variable.icon, expanded: $expanded) {
                Group {
                    if presentation == .compact {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(variables.grouped) { group in
                                header(group.title)
                                ForEach(group.variables) { variable in
                                    VStack(alignment: .leading, spacing: 4) {
                                        chip(variable)
                                        description(variable)
                                    }
                                }
                            }
                        }
                    } else {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                            ForEach(variables.grouped) { group in
                                // 不在 GridRow 里的视图横跨各列
                                header(group.title)
                                ForEach(group.variables) { variable in
                                    GridRow {
                                        chip(variable)
                                        description(variable)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func chip(_ variable: ContextScene.Variable) -> some View {
        if let open {
            ContextVariableOpener(title: variable.title) { open(variable.name) }
        } else {
            ContextVariableChip(title: variable.title)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(Theme.secondary.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func description(_ variable: ContextScene.Variable) -> some View {
        Text(variable.description)
            .font(Theme.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 可用变量里能点的胶囊：点了打开变量窗口。原生按钮盖在胶囊上接点击，变量窗口开着时点这里不算点在它外面（见 OutsideClickButton），
/// 换成这个变量还是关掉由 open 决定；按下变淡，同条件里的变量菜单。
private struct ContextVariableOpener: View {
    let title: String
    let open: () -> Void
    @State private var pressed = false

    var body: some View {
        ContextVariableChip(title: title)
            .accessibilityHidden(true)
            .opacity(pressed ? 0.7 : 1)
            .overlay { OutsideClickButton(label: "查看\(title)", action: open, pressed: $pressed) }
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
        }
        .sensoryFeedback(.selection, trigger: dragging != nil)
    }

    /// 当前块的位置和操作每次从列表现取，移动、删除后工具栏跟着变。
    private func handle(_ id: String) -> ContextBlockHandle {
        let list = $blocks
        let editor = editor
        return ContextBlockHandle(id: id, state: {
            let blocks = list.wrappedValue
            guard let index = blocks.firstIndex(where: { $0.id == id }) else { return nil }
            let block = blocks[index], paragraph = block.type == "paragraph"
            // 条件不显示名称，认它靠变量
            let title = paragraph ? block.title : variables.first { $0.name == block.variable }?.title ?? block.variable ?? ""
            return .init(title: title, kind: paragraph ? .paragraph : .condition,
                         empty: block.isEmpty, first: index == 0, last: index == blocks.count - 1)
        }, perform: { [weak editor] action in
            guard let index = list.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
            switch action {
            case .move(let offset):
                guard list.wrappedValue.indices.contains(index + offset) else { return }
                withAnimation(.snappy(duration: 0.25)) { list.wrappedValue.swapAt(index, index + offset) }
            case .add(let block):
                let current = list.wrappedValue[index]
                if current.type == "paragraph" {
                    list.wrappedValue.insert(block, at: index + 1)
                } else if var branch = editor?.branch(of: current) {
                    branch.blocks.append(block)
                    list.wrappedValue[index].replaceBranch(branch)
                }
            case .delete:
                list.wrappedValue.remove(at: index)
                if editor?.current?.id == id { editor?.current = nil }
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
                // 条件包住段落：只描边不填色。拖起来时垫上底色，盖住后面的块。
                ContextConditionEditor(block: $block, variables: variables, depth: depth, select: { editor.current = handle }) {
                    grip.font(Theme.secondary.weight(.medium))
                }
                // 点框里的空白选中条件，工具栏的添加加进当前分支
                .background {
                    shape.fill(lifted ? Theme.card : .clear)
                        .contentShape(shape)
                        .onTapGesture { editor.current = handle }
                }
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

    /// 段落的手柄与名称。不用卡片给代码块语言标签的等宽小字，和分支名同级，手柄跟着名称的字号字重。
    private var title: some View {
        HStack(spacing: 4) {
            grip
            ContextNameField(title: $block.title, placeholder: "段落名称")
        }
        .font(Theme.secondary.weight(.medium))
        .simultaneousGesture(TapGesture().onEnded { editor.current = handle })
    }

    private var count: some View {
        ContextCountLabel(total: editor.total(of: block), variables: (block.parts ?? []).contains { $0.type == "variable" })
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
        return branches.allSatisfy(\.blocks.isEmpty)
    }
}

/// 标题栏右边的计数：数出 token 就显示 token，不然显示字数；重数期间先留着上次的值。明细按输入方式看：指针悬停显示提示，手指点开气泡。
private struct ContextCountLabel: View {
    let total: ContextTotal
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
        if variables { lines.append("变量的值运行时才有，不算在内") }
        return lines.joined(separator: "\n")
    }
}

/// 条件框：标题栏左边是手柄和变量，点变量旁的箭头换变量；右边是分支页签和添加分支。条件不计字数。
/// 选中的页签像文件夹标签：标题栏下沿的分割线到它这里弯上去包住它，和下面选中分支的匹配值与内容连成一片。
/// 选中哪个分支记在窗口的编辑状态里。框和匹配值都不填色。
private struct ContextConditionEditor<Grip: View>: View {
    @Binding var block: ContextBlock
    let variables: [ContextScene.Variable]
    let depth: Int
    /// 点页签时顺带选中条件，工具栏的添加加进这个分支。
    let select: () -> Void
    @ViewBuilder let grip: Grip
    @Environment(ContextEditor.self) private var editor
    @Environment(\.fontResolutionContext) private var fontContext
    @State private var confirmingDelete = false
    /// 各页签在框里的位置与标题栏高度，画选中页签的轮廓用。
    @State private var tabs: [String: CGRect] = [:]
    @State private var headerHeight: CGFloat = 0
    /// 正在改名的分支，名称就地换成输入框。
    @State private var renaming: String?
    /// 页签间竖线的高度：比分支名高一点，跟着字号变。
    @ScaledMetric(relativeTo: .subheadline) private var dividerHeight: CGFloat = 18
    @FocusState private var matchFocused: Bool

    /// 嵌套的条件各自找最近的同名坐标空间，量到的都是自己框里的位置。
    private static var space: String { "contextCondition" }
    private var currentID: String { editor.branch(of: block)?.id ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let branch = binding(currentID) {
                VStack(alignment: .leading, spacing: 12) {
                    branchFields(branch)
                    // 显式擦除递归的视图类型，数据仍保留完整分支结构。
                    AnyView(ContextBlocksEditor(blocks: branch.blocks, variables: variables, depth: depth + 1))
                }
                .padding(ContextTextStyle.inset)
            }
        }
        .coordinateSpace(.named(Self.space))
        .overlay {
            let tab = tabs[currentID]
            ContextTabOutline(tab: tab ?? .zero, baseline: headerHeight)
                .stroke(Theme.rule, lineWidth: 1)
                // 换页签时轮廓滑过去；新加的分支还没量出位置，直接出现
                .animation(tab == nil ? nil : .snappy(duration: 0.2), value: currentID)
                .allowsHitTesting(false)
        }
        .alert("删除分支「\(binding(currentID)?.wrappedValue.title ?? "")」？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive, action: deleteBranch)
            Button("取消", role: .cancel) {}
        } message: {
            Text("分支里的内容会一起删掉。")
        }
    }

    /// 与段落卡片的标题栏同样的边距，两种块的手柄对齐。
    private var header: some View {
        HStack(spacing: Metrics.paneButtonGap) {
            HStack(spacing: 4) {
                grip
                variableMenu
            }
            Spacer(minLength: 12)
            // 添加分支离页签、离框的右边看起来都和离上边一样远：框线往里画，选中时 1.5pt；页签的线骑在边上，只往外占 0.5pt，
            // 离页签比离框边少让 2pt
            HStack(spacing: Metrics.codeHeaderInset - 2) {
                HStack(spacing: 2) {
                    ForEach(block.branches) { branch in
                        tab(branch)
                    }
                }
                Button(action: addBranch) { PaneButtonLabel("添加分支", systemImage: "plus") }
                    .buttonStyle(PaneButtonStyle())
                    .help("添加分支")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.leading, (Metrics.paneButton - Theme.body.resolve(in: fontContext).pointSize) / 2 + Metrics.codeHeaderInset)
        .padding([.trailing, .vertical], Metrics.codeHeaderInset)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
    }

    private var variableMenu: some View {
        let variable = variables.first { $0.name == block.variable }
        return Menu {
            ForEach(variables.grouped) { group in
                Section(group.title) {
                    ForEach(group.variables) { item in
                        Button(item.title) { block.variable = item.name }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                ContextVariableChip(title: variable?.title ?? block.variable ?? "", missing: variable == nil)
                Image(systemName: "chevron.down").font(Theme.status.weight(.semibold)).imageScale(.small)
            }
            .frame(minHeight: Metrics.paneButton)
        }
        // 横向不固定：窄屏放不下时变量名跟着截断，不把整个窗口撑宽
        .menuStyle(.button).buttonStyle(ContextPressFadeStyle()).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
        .help(variable?.description ?? "选择变量")
    }

    /// 页签只写分支名，匹配条件在悬停提示和选中后的输入框里。放不下时分支名截断。
    /// 选中的页签名称右边是删除分支，其他情况不能删。改名：鼠标双击、触屏长按名称，就地换成输入框，回车或离开就结束。
    private func tab(_ branch: ContextBranch) -> some View {
        let current = branch.id == currentID
        let deletable = current && branch.equals != nil
        // 页签之间和最右的页签与加号之间各有一条竖线；挨着选中的页签就不画，那里有轮廓
        let branches = block.branches
        let next = branches.firstIndex { $0.id == branch.id }.flatMap { branches.indices.contains($0 + 1) ? branches[$0 + 1].id : nil }
        let divider = !current && next != currentID
        // 点击范围从顶上一直到标题栏下沿，多出的一截垂进标题栏的下边距，不撑高标题栏。
        // 轮廓顶边再往下让一截，离框顶远些，内容在轮廓里居中。左边是斜边，文字离它多留一点，右边竖直，留得少些。
        return HStack(spacing: 0) {
            Group {
                if renaming == branch.id, let title = binding(branch.id)?.title {
                    ContextNameField(title: title, placeholder: "分支名称", autofocus: true) { renaming = nil }
                        .fixedSize()
                } else {
                    Button {
                        editor.branches[block.id] = branch.id
                        select()
                    } label: {
                        Text(branch.title)
                            .lineLimit(1)
                            .foregroundStyle(current ? HierarchicalShapeStyle.primary : .secondary)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pointingPlain)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { renaming = branch.id }, isEnabled: !InputMode.current.isTouch)
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.4, maximumDistance: 8).onEnded { _ in renaming = branch.id },
                                         isEnabled: InputMode.current.isTouch)
                }
            }
            .font(Theme.secondary.weight(.medium))
            .padding(.leading, 12)
            .padding(.trailing, deletable ? 2 : 8)
            if deletable {
                Button {
                    if branch.blocks.isEmpty { deleteBranch() } else { confirmingDelete = true }
                } label: {
                    Image(systemName: "trash").font(Theme.status)
                }
                .buttonStyle(PaneButtonStyle(size: Metrics.paneButton - 8))
                .help("删除分支")
                .accessibilityLabel("删除分支")
                .padding(.trailing, 4)
            }
        }
        .padding(.top, Metrics.codeHeaderInset)
        .frame(height: Metrics.paneButton + Metrics.codeHeaderInset)
        .padding(.bottom, -Metrics.codeHeaderInset)
        // 位置与选中时轮廓的右边重合
        .overlay(alignment: .trailing) {
            if divider {
                Rectangle().fill(Theme.rule).frame(width: 1, height: dividerHeight).offset(x: 0.5).allowsHitTesting(false)
            }
        }
        .help(match(branch))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)).offsetBy(dx: 0, dy: Metrics.codeHeaderInset) } action: {
            tabs[branch.id] = $0
        }
    }

    private func match(_ branch: ContextBranch) -> String {
        guard let equals = branch.equals else { return "其他情况" }
        return equals.isEmpty ? "为空" : "等于「\(equals)」"
    }

    @ViewBuilder
    private func branchFields(_ branch: Binding<ContextBranch>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if branch.wrappedValue.equals == nil {
                // 与「值为 … 时」同字号、同样靠左，占的是同一个位置
                Text("其他分支都不匹配时用这里的内容。")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                matchLine(branch)
                if let other = (block.cases ?? []).first(where: { $0.id != branch.wrappedValue.id && $0.equals == branch.wrappedValue.equals }) {
                    CardNote("和「\(other.title)」的匹配值相同，保存时会被拒绝。")
                }
            }
        }
    }

    /// 「值为 … 时」：值直接写在句子里，不垫底色，下面常驻一条下划线标出能输入的范围，编辑时换成强调色；
    /// 点这一行就编辑，输入框撑满整行。空着时占位写「空」，下划线留出一截空格的长度。
    private func matchLine(_ branch: Binding<ContextBranch>) -> some View {
        HStack(spacing: 4) {
            Text("值为").foregroundStyle(.secondary)
            TextField("空", text: Binding(get: { branch.wrappedValue.equals ?? "" }, set: { branch.wrappedValue.equals = $0 }))
                .textFieldStyle(.plain)
                .focused($matchFocused)
                // 回车或 Esc 结束编辑，和段落、名称一样
                .onSubmit { matchFocused = false }
                #if os(macOS)
                .onExitCommand { matchFocused = false }
                #endif
                .fixedSize(horizontal: !matchFocused, vertical: false)
                .frame(minWidth: 48, maxWidth: matchFocused ? .infinity : nil, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(matchFocused ? Color.accentColor : Theme.rule).frame(height: 1).offset(y: 2)
                }
            Text("时").foregroundStyle(.secondary)
        }
        .font(Theme.body)
        // 撑开、缩回时输入框和「时」平滑地滑过去；不带回弹，免得冲出这一行
        .animation(.smooth(duration: 0.25), value: matchFocused)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { matchFocused = true }
        .help("变量的值等于这段文字时用这个分支；留空表示变量为空")
    }

    private func addBranch() {
        let branch = ContextBranch(title: "新分支", equals: "值\((block.cases ?? []).count + 1)", blocks: [])
        block.cases = (block.cases ?? []) + [branch]
        editor.branches[block.id] = branch.id
    }

    private func deleteBranch() {
        let id = currentID
        block.cases?.removeAll { $0.id == id }
        tabs[id] = nil
    }

    private func binding(_ id: String) -> Binding<ContextBranch>? {
        guard let original = block.branches.first(where: { $0.id == id }) else { return nil }
        let source = $block
        return Binding(get: { source.wrappedValue.branches.first { $0.id == id } ?? original },
                       set: { source.wrappedValue.replaceBranch($0) })
    }
}

/// 没有悬停底色和底框，整块都能点，按下变淡：可收起的节整行标题是展开、收起按钮；
/// 条件的变量菜单只有胶囊和箭头（系统菜单按钮在 Mac 上会垫一层底框，这里不要），点击范围占满标题栏高度。
private struct ContextPressFadeStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
            .clickPointer()
    }
}

/// 选中页签的轮廓：一条分割线沿标题栏下沿横贯条件框，到选中的页签处圆角弯上去包住它，两边与分割线相接处向外撇开。
/// 左边像文件夹的页签一样斜上去，右边竖直。还没量出页签时只画分割线。左右各让开框线的宽度，免得叠在框线上颜色变深。
private nonisolated struct ContextTabOutline: Shape {
    var tab: CGRect
    let baseline: CGFloat

    var animatableData: CGRect.AnimatableData {
        get { tab.animatableData }
        set { tab.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let flare: CGFloat = 6, corner: CGFloat = 8
        let left = rect.minX + 1, right = rect.maxX - 1, top = tab.minY
        // 斜边按页签高度取，触屏的页签更高，倾斜角度不变；底边外撇、顶边内收各一半，文字仍在中间
        let slant = (baseline - top) * 0.25
        var path = Path()
        path.move(to: CGPoint(x: left, y: baseline))
        if tab.width > 0 {
            let foot = CGPoint(x: tab.minX - slant / 2, y: baseline), shoulder = CGPoint(x: tab.minX + slant / 2, y: top)
            path.addArc(tangent1End: foot, tangent2End: shoulder, radius: flare)
            path.addArc(tangent1End: shoulder, tangent2End: CGPoint(x: tab.maxX, y: top), radius: corner)
            path.addArc(tangent1End: CGPoint(x: tab.maxX, y: top), tangent2End: CGPoint(x: tab.maxX, y: baseline), radius: corner)
            path.addArc(tangent1End: CGPoint(x: tab.maxX, y: baseline), tangent2End: CGPoint(x: right, y: baseline), radius: flare)
        }
        path.addLine(to: CGPoint(x: right, y: baseline))
        return path
    }
}

/// 块和分支的名称：名称不能为空，清空时保留原名，离开输入框后显示回原名。输入时工具栏的格式与变量工具禁用。字体、颜色与边距由使用方给。
private struct ContextNameField: View {
    @Binding var title: String
    let placeholder: String
    /// 就地改名：出现就放光标，回车、Esc 或离开时调 ended。
    var autofocus = false
    var ended: (() -> Void)?
    @Environment(ContextEditor.self) private var editor
    @State private var text = ""
    @State private var token = UUID()
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear {
                text = title
                if autofocus { focused = true }
            }
            .onChange(of: title) { _, value in if !focused { text = value } }
            .onChange(of: text) { _, value in
                let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, name != title { title = name }
            }
            .onChange(of: focused) { _, now in
                if now { editor.naming = token } else {
                    text = title
                    if editor.naming == token { editor.naming = nil }
                    ended?()
                }
            }
            .onDisappear { if editor.naming == token { editor.naming = nil } }
            .onSubmit { focused = false }
            #if os(macOS)
            .onExitCommand { focused = false }
            #endif
    }
}
