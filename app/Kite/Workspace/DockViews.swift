import SwiftUI

/// 指针停在停靠栏哪一格上：Mac 在左边浮出名字与状态。frame 用内容区坐标。
struct DockHover: Equatable {
    let id: String
    let frame: CGRect
}

extension DockModel {
    /// 按 ID 找到一格，文件夹和家族里的也算；家族的父代理按实例找。
    func entry(_ id: String) -> DockEntry? {
        func search(_ entries: [DockEntry]) -> DockEntry? {
            for entry in entries {
                if entry.id == id { return entry }
                if case .family(let family) = entry, DockEntry.instance(family.parent).id == id { return .instance(family.parent) }
                if let found = search(entry.members) { return found }
            }
            return nil
        }
        return search(all)
    }
}

extension WorkArea {
    /// 点开或收起文件夹、家族格；depth 是它所在的层，外层在前。
    func toggleDock(_ id: String, depth: Int) {
        withAnimation(.snappy) {
            if dockExpansion.count > depth, dockExpansion[depth] == id { dockExpansion = Array(dockExpansion.prefix(depth)) }
            else { dockExpansion = Array(dockExpansion.prefix(depth)) + [id] }
        }
    }

    /// 指针进入一格时浮出它的标签，离开时只收起自己的。
    func setDockHover(_ id: String, frame: CGRect, hovering: Bool) {
        if hovering { dockHover = DockHover(id: id, frame: frame) }
        else if dockHover?.id == id { dockHover = nil }
    }

    func collapseDock() {
        guard !dockExpansion.isEmpty else { return }
        withAnimation(.snappy) { dockExpansion = [] }
    }

    /// 窗口指向的实例 ID；草稿窗口指向草稿会话。
    func dockInstanceID(_ pane: Pane) -> String {
        windows.first { $0.id == pane.id }?.target.instanceId ?? pane.id
    }
}

/// 一个窗口或实例在停靠栏里的样子，连同运行外圈与角标。
struct DockEntryFace: View {
    enum Subject {
        case pane(Pane)
        case instance(RemotePluginInstance)
        /// 家族格里的父代理：窗口在台面上时是模糊头像加左箭头。
        case parent(DockFamily)
    }

    let subject: Subject
    var ring = true
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area

    var body: some View {
        let id = instanceID
        face(id)
            .overlay { if ring, !onStage { DockStatusMarks(instance: id) } }
    }

    @ViewBuilder
    private func face(_ id: String) -> some View {
        switch subject {
        case .pane(let pane):
            DockFace(look: look(pane: pane), running: area.isRunning(id))
        case .instance(let instance):
            DockFace(look: look(instance), windowless: true, running: area.isRunning(id))
        case .parent(let family):
            if family.onStage {
                ZStack {
                    Circle().fill(Theme.card)
                    AgentAvatar(design: model.emblem(for: family.parent.id, in: area), instance: family.parent.id)
                        .blur(radius: 3).opacity(0.55).clipShape(Circle())
                    Image(systemName: "arrow.left").font(Theme.title).foregroundStyle(Theme.ink)
                }
            } else if let pane = family.pane {
                DockFace(look: look(pane: pane), running: area.isRunning(id))
            } else {
                DockFace(look: look(family.parent), windowless: true, running: area.isRunning(id))
            }
        }
    }

    private var onStage: Bool {
        if case .parent(let family) = subject { family.onStage } else { false }
    }

    private var instanceID: String {
        switch subject {
        case .pane(let pane): area.dockInstanceID(pane)
        case .instance(let instance): instance.id
        case .parent(let family): family.parent.id
        }
    }

    private func look(pane: Pane) -> DockFace.Look {
        let id = area.dockInstanceID(pane)
        return area.isAgentPane(pane) ? .agent(instance: id, design: model.emblem(for: id, in: area)) : .tool(area.appearance(of: pane))
    }

    private func look(_ instance: RemotePluginInstance) -> DockFace.Look {
        if area.isAgent(instance) { return .agent(instance: instance.id, design: model.emblem(for: instance.id, in: area)) }
        return .tool(.renderer(area.definition(of: instance)?.views.first?.renderer ?? ""))
    }
}

/// 运行外圈与角标，不含头像；最小化的窗口卡片自己画头像，这些画在卡片上面。
struct DockStatusMarks: View {
    let instance: String
    @Environment(WorkArea.self) private var area

    var body: some View {
        ZStack {
            if area.isRunning(instance) {
                ContextRing(phase: area.activities[instance]?.phase ?? "idle", fraction: nil, lineWidth: 2)
                    .padding(-4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if let attention = area.attention(of: instance) { DockBadge(color: attention.color) }
        }
        .allowsHitTesting(false)
    }
}

/// 角标：一颗带底色描边的小圆点；count 大于 1 时写上个数。
struct DockBadge: View {
    let color: Color
    var count = 1

    var body: some View {
        let size = Metrics.dragBubble / 4
        Group {
            if count > 1 {
                Text("\(count)").font(.system(size: size * 0.75, weight: .bold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, size * 0.3)
                    .frame(minWidth: size, minHeight: size)
                    .background(Capsule().fill(color))
            } else {
                Circle().fill(color).frame(width: size, height: size)
            }
        }
        .overlay { Capsule().strokeBorder(Theme.background, lineWidth: 2).padding(-1.5) }
        .offset(x: size / 4, y: size / 4)
        .allowsHitTesting(false)
    }
}

/// 家族格的装饰：右上角的子代理小头像与包住父子的描边。父代理的头像另画：最小化时是窗口卡片，否则在下面。
struct DockFamilyDecoration: View {
    let family: DockFamily
    let size: CGFloat
    @Environment(WorkArea.self) private var area

    var body: some View {
        let cell = CGRect(x: 0, y: 0, width: size, height: size)
        let child = DockGeometry.childFrame(in: cell)
        ZStack(alignment: .topLeading) {
            NotchedCircle(corner: DockGeometry.familyCornerRadius(size))
                .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
            if let first = featured {
                // 多于一个子代理时在后面叠一层
                if family.children.count > 1 {
                    Circle().fill(Theme.background).overlay(Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
                        .frame(width: child.width, height: child.height)
                        .offset(x: child.minX - child.width * 0.18, y: child.minY + child.height * 0.18)
                }
                miniFace(first)
                    .frame(width: child.width, height: child.height)
                    .background(Circle().fill(Theme.background).padding(-1.5))
                    .offset(x: child.minX, y: child.minY)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

    /// 角上放运行中或需要处理的子代理，其次是最近活动的。
    private var featured: RemotePluginInstance? {
        let instances = family.children.compactMap(\.leadInstance)
        return instances.first { area.isRunning($0.id) || area.attention(of: $0.id) != nil } ?? instances.first
    }

    private func miniFace(_ instance: RemotePluginInstance) -> some View {
        DockEntryFace(subject: .instance(instance), ring: false)
            .overlay { if let attention = area.attention(of: instance.id) { Circle().strokeBorder(attention.color, lineWidth: 1.5) } }
    }
}

/// 文件夹：没有窗口的代理，2×2 小头像；超过四个时右下角换成「更多」。
struct DockFolderFace: View {
    let entries: [DockEntry]
    @Environment(WorkArea.self) private var area

    var body: some View {
        GeometryReader { geo in
            let inset = geo.size.width * 4 / 36, gap = geo.size.width * 2 / 36
            let mini = (geo.size.width - 2 * inset - gap) / 2
            let shown = entries.count > 4 ? Array(entries.prefix(3)) : entries
            ZStack(alignment: .topLeading) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                    miniFace(entry)
                        .frame(width: mini, height: mini)
                        .offset(x: inset + CGFloat(index % 2) * (mini + gap), y: inset + CGFloat(index / 2) * (mini + gap))
                }
                if entries.count > 4 {
                    Image(systemName: "ellipsis")
                        .font(.system(size: mini * 0.6, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: mini, height: mini)
                        .offset(x: inset + mini + gap, y: inset + mini + gap)
                }
            }
        }
        .windowlessPlate(RoundedRectangle(cornerRadius: Metrics.dragBubble * 14 / 36, style: .continuous), tint: Palette.breeze)
        .overlay(alignment: .bottomTrailing) {
            if let (attention, count) = area.attention(in: entries) { DockBadge(color: attention.color, count: count) }
        }
    }

    @ViewBuilder
    private func miniFace(_ entry: DockEntry) -> some View {
        if let instance = entry.leadInstance { DockEntryFace(subject: .instance(instance), ring: false) }
    }
}

/// 收起时的一格：家族、文件夹或没有窗口的实例。最小化的窗口由窗口卡片自己画，不在这里。
struct DockCell: View {
    let entry: DockEntry
    @Environment(\.dockCardsDrawPanes) private var cardsDrawPanes

    var body: some View {
        switch entry {
        case .family(let family):
            // 宽屏上父代理最小化时，窗口卡片和装饰画在这一格上面（见 DockOverlay），这里只接点击
            if cardsDrawPanes, family.pane != nil, !family.onStage {
                Color.clear
            } else {
                let parent = DockGeometry.parentFrame(in: CGRect(x: 0, y: 0, width: Metrics.dragBubble, height: Metrics.dragBubble))
                ZStack(alignment: .topLeading) {
                    DockEntryFace(subject: .parent(family))
                        .frame(width: parent.width, height: parent.height)
                        .offset(x: parent.minX, y: parent.minY)
                    DockFamilyDecoration(family: family, size: Metrics.dragBubble)
                }
            }
        case .folder(let entries):
            DockFolderFace(entries: entries)
        case .instance(let instance):
            DockEntryFace(subject: .instance(instance))
        case .pane(let pane):
            DockEntryFace(subject: .pane(pane))
        }
    }

}

/// 一格的点击：展开文件夹与家族格，打开没有窗口的实例。
struct DockCellButton: View {
    let entry: DockEntry
    let depth: Int
    var hoverFrame: CGRect?
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area

    var body: some View {
        Button(action: activate) {
            DockCell(entry: entry)
                .frame(width: Metrics.dragBubble, height: Metrics.dragBubble)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointingPlain)
        .accessibilityLabel(area.dockLabel(entry))
        .onHover { hovering in
            if let hoverFrame { area.setDockHover(entry.id, frame: hoverFrame, hovering: hovering) }
        }
        .contextMenu { DockEntryMenu(entry: entry) }
    }

    private func activate() {
        switch entry {
        case .family, .folder: area.toggleDock(entry.id, depth: depth)
        case .instance(let instance):
            model.openDockInstance(instance, in: area)
            area.collapseDock()
        case .pane: break
        }
    }
}

/// 长按与右键菜单：先写名字与状态，再是实例操作。
struct DockEntryMenu: View {
    let entry: DockEntry
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area

    var body: some View {
        Text(area.dockLabel(entry))
        switch entry {
        case .instance(let instance):
            InstanceActions(instance: instance)
        case .family(let family):
            InstanceActions(instance: family.parent)
            Section("子代理") {
                ForEach(family.children) { child in
                    if let instance = child.leadInstance {
                        Button(instance.title) { model.openDockInstance(instance, in: area) }
                    }
                }
            }
        case .pane(let pane):
            if let instance = area.instance(of: pane) { InstanceActions(instance: instance) }
            Button("关闭窗口") { model.closeWindow(pane, in: area) }
        case .folder:
            EmptyView()
        }
    }
}

/// 展开的文件夹或家族格：原地拉长，里面的图标放大排开；里面再展开的家族嵌在描边里。
/// 宽屏竖排，紧凑布局横排；横排和底栏一样倒着排，第一项在右端。
struct DockPanel: View {
    let entry: DockEntry
    let depth: Int
    let axis: Axis
    /// 点了父代理的窗口：宽屏放上台面，紧凑布局切过去。
    var showPane: (Pane) -> Void

    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area

    static var padding: CGFloat { Metrics.dragBubble * 5 / 36 }

    /// 沿排列方向的长度，宽屏据此摆放面板。
    static func extent(_ entry: DockEntry, path: ArraySlice<String>) -> CGFloat {
        let members = entry.members
        var total = 2 * padding + Metrics.gap * CGFloat(max(members.count - 1, 0))
        for member in members {
            if member.expands, path.first == member.id { total += extent(member, path: path.dropFirst()) }
            else { total += Metrics.dragBubble }
        }
        return total
    }

    /// 垂直于排列方向的宽度：每嵌一层多两份内边距。
    static func breadth(_ entry: DockEntry, path: ArraySlice<String>) -> CGFloat {
        let nested = entry.members.first { $0.expands && path.first == $0.id }
        return 2 * padding + (nested.map { breadth($0, path: path.dropFirst()) } ?? Metrics.dragBubble)
    }

    var body: some View {
        let path = area.dockExpansion.dropFirst(depth + 1)
        let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: Metrics.gap)) : AnyLayout(HStackLayout(spacing: Metrics.gap))
        let members = Array(entry.members.enumerated())
        layout {
            ForEach(axis == .horizontal ? Array(members.reversed()) : members, id: \.element.id) { index, member in
                Group {
                    if member.expands, path.first == member.id {
                        DockPanel(entry: member, depth: depth + 1, axis: axis, showPane: showPane)
                    } else if index == 0, case .family(let family) = entry {
                        parentRow(family)
                    } else {
                        DockPanelItem(entry: member, depth: depth + 1)
                    }
                }
                // 里面又展开了一层时，这一层其余的模糊淡出
                .modifier(DockDimmed(dimmed: path.first.map { $0 != member.id } ?? false))
            }
        }
        .padding(Self.padding)
        .background { background }
    }

    @ViewBuilder
    private var background: some View {
        if case .folder = entry {
            Color.clear.windowlessPlate(RoundedRectangle(cornerRadius: Metrics.dragBubble * 14 / 36 + Self.padding, style: .continuous),
                                        tint: Palette.breeze)
        } else {
            let radius = Metrics.dragBubble / 2 + Self.padding
            let shape = UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: radius,
                                               topTrailingRadius: DockGeometry.familyCornerRadius(Metrics.dragBubble) + Self.padding, style: .continuous)
            shape.fill(Theme.background)
                .overlay { shape.strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1) }
        }
    }

    private func parentRow(_ family: DockFamily) -> some View {
        Button {
            if let pane = family.pane { showPane(pane) }
            else { model.openDockInstance(family.parent, in: area) }
            area.collapseDock()
        } label: {
            DockEntryFace(subject: .parent(family))
                .frame(width: Metrics.dragBubble, height: Metrics.dragBubble)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointingPlain)
        .modifier(DockItemHover(id: DockEntry.instance(family.parent).id))
        .accessibilityLabel(area.dockLabel(.instance(family.parent)))
        .contextMenu {
            Text(area.dockLabel(.instance(family.parent)))
            InstanceActions(instance: family.parent)
        }
    }
}

/// 展开面板里的一项。
private struct DockPanelItem: View {
    let entry: DockEntry
    let depth: Int

    var body: some View {
        DockCellButton(entry: entry, depth: depth)
            .modifier(DockItemHover(id: entry.id))
    }
}

/// 展开面板里的项目自己报位置，悬停标签按它浮在左边。
private struct DockItemHover: ViewModifier {
    let id: String
    @Environment(WorkArea.self) private var area
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DockSpace.name)) } action: { frame = $0 }
            .onHover { area.setDockHover(id, frame: frame, hovering: $0) }
    }
}

extension EnvironmentValues {
    /// 宽屏上最小化的窗口由卡片画在停靠格里；紧凑布局的底栏没有卡片，自己画。
    @Entry var dockCardsDrawPanes = false
}

/// 停靠栏和内容区共用的坐标系名字。
nonisolated enum DockSpace {
    static let name = "dock-space"
}

/// 展开时其余的格子模糊淡出。
struct DockDimmed: ViewModifier {
    let dimmed: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: dimmed ? 4 : 0)
            .opacity(dimmed ? 0.3 : 1)
            .allowsHitTesting(!dimmed)
    }
}

/// Mac 悬停时浮在格子左边的名字与状态。
struct DockHoverLabel: View {
    let text: String
    let frame: CGRect

    var body: some View {
        let width: CGFloat = 280
        Text(text)
            .font(Theme.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.card).shadow(color: .black.opacity(0.15), radius: 6, y: 2))
            .frame(width: width, height: frame.height, alignment: .trailing)
            .position(x: frame.minX - Metrics.gap / 2 - width / 2, y: frame.midY)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

/// 加号：宽屏是圆、右上角与窗口右上角同心，和家族格是同一种形状；紧凑布局的底栏边上没有窗口角，是正圆。
struct AddWindowButton: View {
    var concentric = true
    @Environment(WorkArea.self) private var area
    @State private var presented = false

    var body: some View {
        let size = Metrics.dragBubble, radius = size / 2
        Button { presented = true } label: {
            if concentric {
                face(ConcentricRectangle(topLeadingCorner: .fixed(radius),
                                         topTrailingCorner: .concentric(minimum: .fixed(DockGeometry.familyCornerRadius(size))),
                                         bottomLeadingCorner: .fixed(radius), bottomTrailingCorner: .fixed(radius)))
            } else {
                face(Circle())
            }
        }
        .buttonStyle(.pointingPlain)
        .fixedSize()
        .help("创建实例")
        .accessibilityLabel("添加")
        .popover(isPresented: $presented) { CreateInstanceMenu(presented: $presented) }
        .modifier(WindowErrorAlert())
    }

    private func face(_ shape: some Shape) -> some View {
        Image(systemName: "plus")
            .font(Theme.title)
            .foregroundStyle(.secondary)
            .frame(width: Metrics.dragBubble, height: Metrics.dragBubble)
            .overlay { shape.stroke(.secondary.opacity(0.4), lineWidth: 1).padding(0.5) }
            .contentShape(shape)
    }
}

/// 紧凑布局底栏里的当前窗口：垫在格子下面的选中底。
struct DockSelection: View {
    var body: some View {
        Capsule().fill(Theme.selection).padding(-Metrics.gap / 3)
    }
}

/// 紧凑布局的底栏：与宽屏停靠栏同样的分组与样式，横着倒序排、靠右，加号在最右端，当前窗口也在里面。
/// 文件夹与家族格原地拉宽展开，其余的模糊淡出。
struct CompactDockBar: View {
    @Binding var open: WorkspaceDrawer?
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area

    var body: some View {
        let layout = area.layout
        let dock = area.dockModel(docked: layout.panes, onStage: [])
        let dimmed = !area.dockExpansion.isEmpty
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metrics.gap) {
                    ForEach(dock.tools.reversed()) { item($0, dimmed: dimmed) }
                    if !dock.agents.isEmpty && !dock.tools.isEmpty {
                        Rectangle().fill(Theme.rule)
                            .frame(width: 1, height: Metrics.dragBubble * 0.6)
                            .modifier(DockDimmed(dimmed: dimmed))
                    }
                    ForEach(dock.agents.reversed()) { item($0, dimmed: dimmed) }
                    AddWindowButton(concentric: false)
                        .modifier(DockDimmed(dimmed: dimmed))
                }
                .frame(height: Metrics.dragBubble)
                .animation(.snappy, value: dock.all.map(\.id))
            }
            // 排不满时靠右，排满时停在右端，增减格子时右端不动
            .defaultScrollAnchor(.trailing)
            .scrollClipDisabled()
            .onChange(of: area.dockExpansion.first) { _, id in
                if let id { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .onChange(of: layout.focused.map(area.dockInstanceID), initial: true) { _, id in
            area.noteVisible(id.map { [$0] } ?? [])
        }
        .onDisappear { area.noteVisible([]) }
        .task(id: model.revision(for: area)) {
            try? await model.ensureRoles(in: area)
        }
    }

    private func item(_ entry: DockEntry, dimmed: Bool) -> some View {
        let expanded = area.dockExpansion.first == entry.id
        return Group {
            if entry.expands, expanded {
                DockPanel(entry: entry, depth: 0, axis: .horizontal, showPane: show)
                    .transition(.scale(scale: 0.7, anchor: .trailing).combined(with: .opacity))
            } else if case .pane(let pane) = entry {
                paneButton(pane)
            } else {
                DockCellButton(entry: entry, depth: 0)
                    .background { if current(entry) { DockSelection() } }
            }
        }
        .id(entry.id)
        .modifier(DockDimmed(dimmed: dimmed && !expanded))
    }

    private func paneButton(_ pane: Pane) -> some View {
        let current = area.layout.focused == pane
        return Button {
            if !current { area.layout.focus(pane) }
            open = nil
        } label: {
            DockEntryFace(subject: .pane(pane))
                .frame(width: Metrics.dragBubble, height: Metrics.dragBubble)
                .background { if current { DockSelection() } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(area.dockLabel(.pane(pane)))
        .contextMenu { DockEntryMenu(entry: .pane(pane)) }
    }

    /// 家族格的父代理是当前窗口时也垫选中底。
    private func current(_ entry: DockEntry) -> Bool {
        if case .family(let family) = entry, let pane = family.pane { return pane == area.layout.focused }
        return false
    }

    private func show(_ pane: Pane) {
        area.layout.focus(pane)
        open = nil
    }
}
