import SwiftUI

/// 停靠栏布局组里的一个布局：圆角矩形描边的一格，里面是成员头像的网格（最多四个，角色头像与工具图标，和具体实例无关）。
/// 点了整个台面换成这组（见 WorkArea.openLayout）；菜单里打开、用当前台面覆盖、改名、删除。
struct DockLayoutFolder: View {
    let layout: ProjectLayout
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area

    /// 文件夹的圆角：和格子一样大，按格子大小缩放。
    static var radius: CGFloat { Metrics.dragBubble * 10 / 36 }

    var body: some View {
        let size = Metrics.dragBubble, shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        Button(action: open) {
            DockLayoutFolderFace(layout: layout)
                .frame(width: size, height: size)
                .contentShape(shape)
        }
        .buttonStyle(.pointingPlain)
        .accessibilityLabel("布局：\(layout.name)")
        .modifier(DockHoverReport(id: DockBandItem.layout(layout).id))
        .contextMenuOutline(shape)
        .contextMenu {
            Text(layout.name)
            MenuButton("打开", action: open)
            MenuButton("用当前台面覆盖", action: overwrite)
            MenuButton("改名…") { area.layoutSheet = .rename(layout) }
            MenuButton("删除", role: .destructive, action: delete)
        }
    }

    private func open() {
        area.collapseDock()
        area.openLayout(layout, model: model)
    }

    private func overwrite() {
        let area = area, model = model, layout = layout
        Task {
            do { try await area.saveLayout(name: layout.name, replacing: layout, model: model) }
            catch { area.layoutError = error.localizedDescription }
        }
    }

    private func delete() {
        let area = area, model = model, layout = layout
        Task {
            do { try await area.deleteLayout(layout, model: model) }
            catch { area.layoutError = error.localizedDescription }
        }
    }
}

/// 文件夹的样子：描边，里面两行两列的成员头像，按成员的先后从左上排起。
struct DockLayoutFolderFace: View {
    let layout: ProjectLayout

    var body: some View {
        let size = Metrics.dragBubble, inset = size * 5 / 36, spacing = size * 2 / 36
        let face = (size - 2 * inset - spacing) / 2
        let members = Array(layout.members.prefix(4).enumerated())
        ZStack(alignment: .topLeading) {
            ForEach(members, id: \.offset) { index, member in
                DockLayoutMemberFace(member: member, seed: "\(layout.id).\(index)")
                    .frame(width: face, height: face)
                    .offset(x: inset + CGFloat(index % 2) * (face + spacing), y: inset + CGFloat(index / 2) * (face + spacing))
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .overlay {
            RoundedRectangle(cornerRadius: DockLayoutFolder.radius, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
        }
    }
}

/// 布局成员的头像：代理画角色的签名，浏览、终端、预览、插件画它的图标；同停靠栏的头像，只是小。
private struct DockLayoutMemberFace: View {
    let member: LayoutMember
    /// 签名动画的起始时刻，同一角色的几个成员各不相同。
    let seed: String
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area

    var body: some View {
        switch member {
        case .agent(let role):
            DockFace(look: .agent(instance: seed, design: model.roles(in: area)?.roles.first { $0.id == role }?.emblem?.design))
        case .files: DockFace(look: .tool(.renderer("files")))
        case .terminal: DockFace(look: .tool(.renderer("terminal")))
        case .preview: DockFace(look: .tool(.renderer("preview")))
        case .plugin(let definition):
            DockFace(look: .tool(area.definitions.first { $0.id == definition }.map(WindowAppearance.definition) ?? .renderer("")))
        }
    }
}

/// 添加布局：布局组第一格，点了把本机台面上现有的卡片存成一个新布局，先在弹窗里起个名字（见 LayoutNameSheet）。
struct AddLayoutButton: View {
    @Environment(WorkArea.self) private var area

    var body: some View {
        Button {
            area.layoutSheet = .save(name: area.defaultLayoutName)
        } label: {
            DockAddFace(symbol: "rectangle.stack.badge.plus")
        }
        .buttonStyle(.pointingPlain)
        .fixedSize()
        .help("把台面存成布局")
        .accessibilityLabel("把台面存成布局")
    }
}

/// 布局的名字要在弹窗里填的两件事：把台面存成新布局，给已有的布局改名。
enum LayoutSheetRequest: Identifiable {
    case save(name: String)
    case rename(ProjectLayout)

    var id: String {
        switch self {
        case .save: "save"
        case .rename(let layout): "rename:\(layout.id)"
        }
    }
}

/// 起名字的弹窗：存成新布局时预填台面上几个窗口的标题，改名时预填原来的名字；保存成功就关掉。
struct LayoutNameSheet: View {
    let request: LayoutSheetRequest
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var phase = CardPhase.idle
    @FocusState private var focused: Bool

    init(request: LayoutSheetRequest) {
        self.request = request
        // 预填的名字在 init 里定：按内容定高的弹窗，影响排版的初始状态放到 onAppear 里改会跳高（见 CardSheet）
        switch request {
        case .save(let name): _name = State(initialValue: name)
        case .rename(let layout): _name = State(initialValue: layout.name)
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let saving = if case .save = request { true } else { false }
        CardSheet(title: saving ? "存成布局" : "布局改名", subtitle: saving ? "记下台面上的卡片和摆法，之后一点就摆回来" : "改这个布局的名字",
                  error: phase.error, typing: focused, close: { dismiss() }) {
            CardField(label: "名字", focused: focused) {
                TextField("布局", text: $name)
                    .focused($focused)
                    .onSubmit(save)
                    .cardInput { focused = true }
            }
        } actions: {
            [[.sheet("保存", busy: phase.working, disabled: phase.working || trimmed.isEmpty, action: save)]]
        }
        .endsTyping(focused) { focused = false }
    }

    private func save() {
        let name = trimmed
        guard !name.isEmpty else { return }
        let request = request, area = area, model = model
        $phase.run {
            switch request {
            case .save: try await area.saveLayout(name: name, model: model)
            case .rename(let layout): try await area.renameLayout(layout, to: name, model: model)
            }
            dismiss()
        }
    }
}

extension WorkArea {
    /// 存成布局时预填的名字：台面上几个窗口的标题，按排布里的先后，用顿号连起来。
    var defaultLayoutName: String {
        let titles = (layout.shown?.panes ?? []).filter { !isChooser($0) }.map { appearance(of: $0).name }
        return titles.isEmpty ? "布局" : titles.joined(separator: "、")
    }

    /// 改名：配方不变，只换名字；版本不符（别处刚改过）时工作机拒绝，读回最新的再说。
    func renameLayout(_ target: ProjectLayout, to name: String, model: AppModel) async throws {
        let client = try model.activeClient(in: self)
        _ = try await client.putLayout(project: remote.project.id, id: target.id, expectedRevision: target.revision,
                                       layout: ProjectLayout.Recipe(name: name, members: target.members, arrangement: target.arrangement))
        await model.refreshLayouts(project: remote.project.id, client: client)
    }

    func deleteLayout(_ target: ProjectLayout, model: AppModel) async throws {
        let client = try model.activeClient(in: self)
        try await client.deleteLayout(project: remote.project.id, id: target.id, expectedRevision: target.revision)
        await model.refreshLayouts(project: remote.project.id, client: client)
    }
}

/// 布局的弹窗和失败提示，挂在工作区的窗口组上（同 InstanceSettingsPresentation）。
struct LayoutSheetPresentation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area

    func body(content: Content) -> some View {
        @Bindable var area = area
        content
            .sheet(item: $area.layoutSheet) { request in
                LayoutNameSheet(request: request).environment(model).environment(area).toastHost().appAppearance()
            }
            .alert("布局操作失败", isPresented: Binding(get: { area.layoutError != nil }, set: { if !$0 { area.layoutError = nil } })) {
                Button("好", role: .cancel) { area.layoutError = nil }
            } message: { Text(area.layoutError ?? "") }
    }
}
