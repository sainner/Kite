import SwiftUI

/// 一个窗口里的上下文编辑状态，块与底部工具栏共用：最后放过光标的段落、当前块、各条件选中的分支，以及 token 计数。
@Observable
final class ContextEditor {
    /// 最后放过光标的段落；格式和变量作用在它上面，段落不在了就没有。
    var target: ContextTextCoordinator?
    /// 当前块：光标所在或点过标题栏的块；段落工具作用在它上面。
    var current: ContextBlockHandle?
    /// 刚加的块，出现时放光标。
    var focusRequest: String?
    /// 各条件块选中的分支，显示与计数用同一份。
    var branches: [String: String] = [:]
    private var counting: ContextCounting?
    private var counts: [String: ContextTokenCount] = [:]
    private var pending: Set<String> = []

    /// 换了模型或场景就重数。
    var countingKey: String? { counting?.key }

    func configure(_ counting: ContextCounting) {
        if counting.key != self.counting?.key {
            counts = [:]
            pending = []
        }
        self.counting = counting
    }

    func count(of text: String) -> ContextTokenCount? { counts[text] }

    /// 数一段文字；结果按文字缓存，同一段只数一次。
    func request(_ text: String) async {
        guard let counting, counts[text] == nil, !pending.contains(text) else { return }
        pending.insert(text)
        defer { pending.remove(text) }
        guard let result = try? await counting.count([text]), counting.key == self.counting?.key,
              let first = result.results.first else { return }
        counts[text] = ContextTokenCount(tokens: first.tokens, method: first.method, exact: first.exact, model: result.model)
    }

    /// 一组块的字数与 token：条件只算选中的分支；有一段还没数出 token 就只给字数。
    func total(of blocks: [ContextBlock]) -> ContextTotal {
        blocks.reduce(ContextTotal()) { sum, block in
            if block.type == "paragraph" {
                let text = (block.parts ?? []).literalText
                return sum.adding(characters: text.count, count: text.isEmpty ? .empty : counts[text])
            }
            let branches = (block.cases ?? []) + [block.otherwise].compactMap { $0 }
            let branch = branches.first { $0.id == self.branches[block.id] } ?? branches.first
            return sum.adding(total(of: branch?.blocks ?? []))
        }
    }
}

/// 计数用的模型（或按场景推出）与请求。
struct ContextCounting {
    let key: String
    let count: ([String]) async throws -> ContextTokenCounts
}

nonisolated struct ContextTokenCounts: Decodable, Sendable {
    struct Result: Decodable, Sendable {
        let tokens: Int?
        /// api、o200k 或 none。
        let method: String
        let exact: Bool
    }
    let model: String
    let results: [Result]
}

struct ContextTokenCount: Equatable {
    var tokens: Int?
    var method: String
    var exact: Bool
    var model: String

    static let empty = ContextTokenCount(tokens: 0, method: "", exact: true, model: "")
}

struct ContextTotal: Equatable {
    var characters = 0
    var tokens: Int? = 0
    var exact = true
    var method: String?
    var model: String?

    func adding(characters: Int, count: ContextTokenCount?) -> Self {
        var result = self
        result.characters += characters
        result.tokens = count?.tokens.flatMap { tokens in self.tokens.map { $0 + tokens } }
        result.exact = exact && (count?.exact ?? false)
        if let count, !count.method.isEmpty {
            result.method = count.method
            result.model = count.model
        }
        return result
    }

    func adding(_ other: Self) -> Self {
        var result = self
        result.characters += other.characters
        result.tokens = tokens.flatMap { tokens in other.tokens.map { tokens + $0 } }
        result.exact = exact && other.exact
        result.method = other.method ?? method
        result.model = other.model ?? model
        return result
    }
}

private struct TokenCountRequest: Encodable {
    let texts: [String]
    let model: String?
    let scene: String?
}

extension AppModel {
    /// 资源库的 token 计数：角色给默认模型，模板给场景，由工作机推出模型。
    func contextCounting(model: String?, scene: String?, connection: WorkerConnection?) -> ContextCounting? {
        guard let connection, connection.connected else { return nil }
        let client = connection.client
        return ContextCounting(key: "\(connection.catalog.generation)|\(model ?? "")|\(scene ?? "")") { texts in
            try await client.request("/token-counts", method: "POST", body: TokenCountRequest(texts: texts, model: model, scene: scene),
                                     as: ContextTokenCounts.self)
        }
    }

    func modelTitle(_ id: String) -> String {
        roleCatalog?.models.first { $0.id == id }?.title ?? id
    }
}

extension View {
    /// 把编辑状态交给窗口里的块和工具栏，计数用的模型变了就重数。
    func contextEditor(_ editor: ContextEditor, counting: ContextCounting?) -> some View {
        environment(editor)
            .task(id: counting?.key) { if let counting { editor.configure(counting) } }
    }
}

/// 当前块：位置与能做的操作每次现取，块被删了就是 nil。
struct ContextBlockHandle {
    struct State {
        let title: String
        let paragraph: Bool
        let empty: Bool
        let first: Bool
        let last: Bool
    }

    let id: String
    let state: () -> State?
    let perform: (ContextBlockAction) -> Void
}

enum ContextBlockAction {
    case move(Int)
    case insert(ContextBlock)
    case delete
}

/// 窗口底部的工具栏：添加块、当前块、行级、行内四组，与标题栏同一套按钮组，整体右对齐；变量也是行内的内容，放在行内组里。
/// 格式与变量作用在最后放过光标的段落上，块工具作用在当前块上，添加在当前块下方。放不下一行时，添加与当前块一行，行级与行内一行。
struct ContextEditorToolbar: View {
    let variables: [ContextScene.Variable]
    @Environment(ContextEditor.self) private var editor
    @Environment(\.keyboardShown) private var keyboardShown
    @State private var confirmingDelete: ContextBlockHandle?

    var body: some View {
        let current = editor.current.flatMap { handle in handle.state().map { (handle, $0) } }
        ContextToolbarLayout(spacing: Metrics.paneButtonGap) {
            keyboardButton.layoutValue(key: ContextToolbarLayout.UpperRow.self, value: true)
            addMenu(current).layoutValue(key: ContextToolbarLayout.UpperRow.self, value: true)
            blockTools(current).layoutValue(key: ContextToolbarLayout.UpperRow.self, value: true)
            lineFormat
            inlineFormat
        }
        .alert("删除「\(confirmingDelete?.state()?.title ?? "")」？", isPresented: Binding(get: { confirmingDelete != nil },
                                                                                       set: { if !$0 { confirmingDelete = nil } })) {
            Button("删除", role: .destructive) { confirmingDelete?.perform(.delete) }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmingDelete?.state()?.paragraph == true ? "段落里的文字会一起删掉。" : "各分支里的内容会一起删掉。")
        }
    }

    private var inlineFormat: some View {
        PaneHeaderButtonGroup {
            format("粗体", "bold", .bold)
            format("斜体", "italic", .italic)
            format("行内代码", "chevron.left.forwardslash.chevron.right", .code)
            ActionMenu("插入变量", icon: ContextScene.Variable.icon) {
                ForEach(variables) { variable in
                    Button { editor.target?.insert(variable: variable.name) } label: {
                        Text(variable.title)
                        Text(variable.description)
                    }
                }
            }
            .disabled(variables.isEmpty)
        }
        .disabled(editor.target == nil)
    }

    private var lineFormat: some View {
        PaneHeaderButtonGroup {
            ActionMenu("标题", icon: "number") {
                Button("一级标题") { editor.target?.apply(.heading(1)) }
                Button("二级标题") { editor.target?.apply(.heading(2)) }
                Button("三级标题") { editor.target?.apply(.heading(3)) }
            }
            format("无序列表", "list.bullet", .bullet)
            format("有序列表", "list.number", .numbered)
            format("引用", "text.quote", .quote)
        }
        .disabled(editor.target == nil)
    }

    private func format(_ title: String, _ icon: String, _ format: ContextFormat) -> some View {
        ActionButton(title, icon: icon) { editor.target?.apply(format) }
    }

    /// 添加是新建一块，单独一组；当前块组里的都是对这一块本身的操作。
    private func addMenu(_ current: (ContextBlockHandle, ContextBlockHandle.State)?) -> some View {
        PaneHeaderButtonGroup {
            ActionMenu("在当前块下方添加", icon: "plus") {
                Button("段落", systemImage: "text.alignleft") { insert(.paragraph(), after: current?.0) }
                if let variable = variables.first {
                    Button("条件", systemImage: "arrow.triangle.branch") { insert(.condition(variable: variable.name), after: current?.0) }
                }
            }
        }
        .disabled(current == nil)
    }

    private func blockTools(_ current: (ContextBlockHandle, ContextBlockHandle.State)?) -> some View {
        PaneHeaderButtonGroup {
            ActionButton("上移", icon: "arrow.up") { current?.0.perform(.move(-1)) }
                .disabled(current == nil || current?.1.first == true)
            ActionButton("下移", icon: "arrow.down") { current?.0.perform(.move(1)) }
                .disabled(current == nil || current?.1.last == true)
            ActionButton("删除当前块", icon: "trash") {
                guard let (handle, state) = current else { return }
                if state.empty { handle.perform(.delete) } else { confirmingDelete = handle }
            }
            .disabled(current == nil)
        }
    }

    private func insert(_ block: ContextBlock, after handle: ContextBlockHandle?) {
        guard let handle else { return }
        editor.focusRequest = block.id
        handle.perform(.insert(block))
    }

    /// 屏幕键盘弹出时，在块级那一行的最左边放收起键盘：出现、消失时占的是空白，不挤动别的按钮；玻璃也不和旁边融合。
    @ViewBuilder
    private var keyboardButton: some View {
        if keyboardShown, let target = editor.target {
            PaneHeaderButtonGroup {
                // 等按钮松手这次更新过去再收：同步收的话键盘让位会沿用玻璃松手的回弹，整条底栏落下时弹一下
                ActionButton("收起键盘", icon: "keyboard.chevron.compact.down") { Task { target.endEditing() } }
            }
            .glassEffectTransition(.identity)
        }
    }
}

/// 工具栏的排法：一行放得下就排一行；放不下时标了 UpperRow 的一行，其余一行；某一行还放不下就每组一行。都靠右。
/// 不用 ViewThatFits：它把两种排法各量一遍，窄屏拉侧栏、底栏时整个窗口每帧重排，这一遍遍的测量会掉帧。
private struct ContextToolbarLayout: Layout {
    let spacing: CGFloat

    /// 放不下一行时排在上面的那一行。
    struct UpperRow: LayoutValueKey {
        static let defaultValue = false
    }

    func makeCache(subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) -> CGSize {
        let rows = rows(subviews.indices, width: proposal.width, sizes: cache, subviews: subviews).map { size(of: $0, sizes: cache) }
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) {
        var y = bounds.minY
        for row in rows(subviews.indices, width: bounds.width, sizes: cache, subviews: subviews) {
            let height = size(of: row, sizes: cache).height
            var x = bounds.maxX
            for index in row.reversed() {
                let size = cache[index]
                x -= size.width
                subviews[index].place(at: CGPoint(x: x, y: y + (height - size.height) / 2), proposal: ProposedViewSize(size))
                x -= spacing
            }
            y += height + spacing
        }
    }

    private func rows(_ indices: Range<Int>, width: CGFloat?, sizes: [CGSize], subviews: Subviews) -> [[Int]] {
        let all = Array(indices)
        guard let width, size(of: all, sizes: sizes).width > width else { return [all] }
        return [all.filter { subviews[$0][UpperRow.self] }, all.filter { !subviews[$0][UpperRow.self] }]
            .filter { !$0.isEmpty }
            .flatMap { row in size(of: row, sizes: sizes).width > width ? row.map { [$0] } : [row] }
    }

    private func size(of row: [Int], sizes: [CGSize]) -> CGSize {
        CGSize(width: row.map { sizes[$0].width }.reduce(0, +) + spacing * CGFloat(max(row.count - 1, 0)),
               height: row.map { sizes[$0].height }.max() ?? 0)
    }
}
