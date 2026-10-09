import SwiftUI

/// 指针停在停靠栏哪一格上：Mac 在左边浮出名字与状态。frame 用内容区坐标。
struct DockHover: Equatable {
    let id: String
    let frame: CGRect
}

extension DockModel {
    /// 按 ID 找到一格，「更多」和家族里的也算；家族的父代理按实例找。
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
    /// 点开或收起「更多」、家族格；depth 是它所在的层，外层在前。
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

/// 一个窗口或实例在停靠栏里的样子，连同进行中的脉冲波。
/// 窗口正看得到时头像模糊、画上指向它的箭头，不显示状态：宽屏台面上的父代理向左，紧凑布局的当前窗口向上。
struct DockEntryFace: View {
    enum Subject {
        case pane(Pane)
        case instance(RemotePluginInstance)
        /// 家族格里的父代理。
        case parent(DockFamily)
    }

    let subject: Subject
    /// 家族格里叠在后面的子代理只露一截，不发脉冲。
    var pulse = true
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.dockCurrentPane) private var current

    var body: some View {
        let id = instanceID, arrow = self.arrow
        DockFace(look: look, running: area.isRunning(id), tint: area.attention(of: id)?.color, arrow: arrow)
            .overlay { if pulse, arrow == nil { DockPulse(instance: id) } }
    }

    private var arrow: String? {
        switch subject {
        case .pane(let pane): pane == current ? "arrow.up" : nil
        case .instance: nil
        case .parent(let family): family.onStage ? "arrow.left" : family.pane.map { $0 == current } == true ? "arrow.up" : nil
        }
    }

    private var look: DockFace.Look {
        switch subject {
        case .pane(let pane): look(pane: pane)
        case .instance(let instance): look(instance)
        case .parent(let family): look(family.parent)
        }
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

/// 进行中（运行、正在停止、正在收尾）从头像向外扩散的实心脉冲，颜色和节奏随阶段，大小头像按比例；不含头像。
/// 只填头像外面的一圈，画在上面也不盖住头像：最小化的窗口卡片自己画头像，脉冲画在卡片上面。
struct DockPulse: View {
    let instance: String
    @Environment(WorkArea.self) private var area
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 波传出去的距离占头像直径的比例。
    private static let reach: CGFloat = 9 / 36

    var body: some View {
        if area.isRunning(instance) {
            let phase = area.activities[instance]?.phase ?? "idle"
            let color = ContextRing.color(phase), period = max(ContextRing.period(phase), 1)
            let margin = Metrics.dragBubble * Self.reach
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate / period
                Canvas { canvas, size in
                    let side = min(size.width, size.height) - 2 * margin
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let circle = { (radius: CGFloat) in
                        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
                    }
                    // 一次一个波，前一个散尽再发下一个；减弱动态时停在半路，只留一圈淡晕
                    let progress = reduceMotion ? 0.5 : time.truncatingRemainder(dividingBy: 1)
                    var disc = circle(side / 2 + side * Self.reach * progress)
                    disc.addPath(circle(side / 2))
                    canvas.fill(disc, with: .color(color.opacity(0.6 * (1 - progress))), style: FillStyle(eoFill: true))
                }
            }
            .padding(-margin)
            .allowsHitTesting(false)
        }
    }
}

/// 家族格：一格宽的长胶囊。父代理在最前面（竖排在上，横排在右），子代理和它一样大，
/// 一个压一个叠在后面往后错开，各露出一截；最多露三个，再多不再变长。
struct DockFamilyFace: View {
    let family: DockFamily
    /// 胶囊的宽，头像按它算。
    let width: CGFloat
    var axis: Axis = .vertical
    /// 宽屏上最小化的父代理由窗口卡片画在它的位置，这里只画后面的子代理和描边。
    var drawsParent = true

    static let shownChildren = 3
    static func inset(_ width: CGFloat) -> CGFloat { width * 3 / 36 }
    static func length(_ family: DockFamily, width: CGFloat) -> CGFloat {
        width * (1 + CGFloat(min(family.children.count, shownChildren)) / 3)
    }

    var body: some View {
        let length = Self.length(family, width: width), inset = Self.inset(width), size = width - 2 * inset
        // 第几个头像的位置，父代理是 0，往后每个错开三分之一格
        let offset = { (index: Int) -> CGSize in
            let along = inset + CGFloat(index) * width / 3
            return axis == .vertical ? CGSize(width: inset, height: along) : CGSize(width: length - along - size, height: inset)
        }
        ZStack(alignment: .topLeading) {
            // 越往后越压在下面
            ForEach(Array(family.children.prefix(Self.shownChildren).enumerated()).reversed(), id: \.element.id) { index, child in
                if let instance = child.leadInstance {
                    DockEntryFace(subject: .instance(instance), pulse: false)
                        .frame(width: size, height: size)
                        .offset(offset(index + 1))
                }
            }
            if drawsParent {
                DockEntryFace(subject: .parent(family))
                    .frame(width: size, height: size)
                    .offset(offset(0))
            }
        }
        .frame(width: axis == .vertical ? width : length, height: axis == .vertical ? length : width, alignment: .topLeading)
        .overlay { Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1) }
    }
}

/// 小头像排不下时的最后一个位置：省略号；里面有需要处理的，省略号和描边换成最要紧的那种颜色。
struct DockMoreFace: View {
    let entries: [DockEntry]
    @Environment(WorkArea.self) private var area

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: DockGeometry.miniSize * 0.5, weight: .bold))
            .foregroundStyle(attention.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { Circle().fill(Theme.background) }
            .overlay {
                if let attention { Circle().strokeBorder(attention.color, lineWidth: 1.5) }
                else { Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1) }
            }
    }

    private var attention: DockAttention? { area.attention(in: entries) }
}

/// 收起时的一格：家族、「更多」或没有窗口的实例。最小化的窗口由窗口卡片自己画，不在这里。
/// mini 是排在停靠栏末尾的小头像，家族按比例缩小，占一列两个位置，胶囊从父代理那头排起。
struct DockCell: View {
    let entry: DockEntry
    var mini = false
    @Environment(\.dockCardsDrawPanes) private var cardsDrawPanes
    @Environment(\.dockAxis) private var axis

    var body: some View {
        switch entry {
        case .family(let family):
            // 宽屏上父代理最小化时，窗口卡片画在胶囊最上面，脉冲见 DockOverlay
            DockFamilyFace(family: family, width: mini ? DockGeometry.miniSize : Metrics.dragBubble, axis: axis,
                           drawsParent: !(cardsDrawPanes && family.pane != nil && !family.onStage))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: axis == .vertical ? .top : .trailing)
        case .more(let entries):
            DockMoreFace(entries: entries)
        case .instance(let instance):
            DockEntryFace(subject: .instance(instance))
        case .pane(let pane):
            DockEntryFace(subject: .pane(pane))
        }
    }

}

/// 一格的点击：展开「更多」与家族格，打开没有窗口的实例。
struct DockCellButton: View {
    let entry: DockEntry
    let depth: Int
    var mini = false
    var hoverFrame: CGRect?
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.dockAxis) private var axis

    var body: some View {
        let size = DockGeometry.cellSize(entry, mini: mini, axis: axis)
        Button(action: activate) {
            DockCell(entry: entry, mini: mini)
                .frame(width: size.width, height: size.height)
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
        case .family, .more: area.toggleDock(entry.id, depth: depth)
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
        case .more:
            EmptyView()
        }
    }
}

/// 展开的「更多」或家族格：原地拉长，里面的图标放大排开；里面再展开的家族嵌在描边里。
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
            else { total += DockGeometry.cellSize(member).height }
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
        .environment(\.dockAxis, axis)
        .padding(Self.padding)
        .background {
            Capsule(style: .continuous).fill(Theme.background)
                .overlay { Capsule(style: .continuous).strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1) }
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
    /// 停靠格排列的方向：宽屏停靠栏竖排，紧凑布局的底栏横排；家族胶囊顺着它拉长。
    @Entry var dockAxis: Axis = .vertical
    /// 紧凑布局的底栏里正显示的窗口，它的头像换成向上的箭头。
    @Entry var dockCurrentPane: Pane?
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

/// 加号：宽屏是圆、右上角与窗口右上角同心；紧凑布局的底栏边上没有窗口角，是正圆。
struct AddWindowButton: View {
    var concentric = true
    @Environment(WorkArea.self) private var area
    @State private var presented = false

    /// 右上角与窗口同心时圆角的下限，窗口角太小时不至于变成尖角。
    private static var minimumCorner: CGFloat { Metrics.dragBubble * 19 / 72 }

    var body: some View {
        let size = Metrics.dragBubble, radius = size / 2
        Button { presented = true } label: {
            if concentric {
                face(ConcentricRectangle(topLeadingCorner: .fixed(radius),
                                         topTrailingCorner: .concentric(minimum: .fixed(Self.minimumCorner)),
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

/// 紧凑布局的底栏：与宽屏停靠栏同样的分组与样式，横着倒序排、靠右，加号在最右端，当前窗口也在里面；
/// 没有窗口的代理和工具排成两行小头像贴着左端。「更多」与家族格原地拉宽展开，其余的模糊淡出。
struct CompactDockBar: View {
    @Binding var open: WorkspaceDrawer?
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @State private var width: CGFloat = 0

    var body: some View {
        let layout = area.layout
        let dock = area.dockModel(docked: layout.panes, onStage: [])
        let dimmed = !area.dockExpansion.isEmpty
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metrics.gap) {
                    if !dock.minis.isEmpty {
                        minis(dock.minis, cells: dock.miniCells, dimmed: dimmed)
                        Spacer(minLength: 0)
                    }
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
                .environment(\.dockAxis, .horizontal)
                .environment(\.dockCurrentPane, layout.focused)
                // 至少和底栏一样宽，小头像才能隔着空白贴到左端
                .frame(minWidth: width)
                .animation(.snappy, value: dock.all.map(\.id))
            }
            // 排不满时靠右，排满时停在右端，增减格子时右端不动
            .defaultScrollAnchor(.trailing)
            .scrollClipDisabled()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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

    /// 小头像每格两列两行，从左端往右排：宽屏的每一行在这里是一列，先排左边一列，列内从上到下；
    /// 家族横着占一行两个位置。展开的那项接在后面向右拉宽。
    @ViewBuilder
    private func minis(_ minis: [DockMini], cells: Int, dimmed: Bool) -> some View {
        let expanded = area.dockExpansion.first, step = DockGeometry.miniSize + DockGeometry.miniGap
        ForEach(0..<cells, id: \.self) { cell in
            ZStack(alignment: .topLeading) {
                ForEach(minis.filter { $0.cell == cell }) { mini in
                    DockCellButton(entry: mini.entry, depth: 0, mini: true)
                        .offset(x: CGFloat(mini.row) * step, y: CGFloat(mini.column) * step)
                        .modifier(DockDimmed(dimmed: dimmed && expanded != mini.id))
                }
            }
            .frame(width: Metrics.dragBubble, height: Metrics.dragBubble, alignment: .topLeading)
        }
        if let entry = minis.first(where: { $0.id == expanded })?.entry {
            DockPanel(entry: entry, depth: 0, axis: .horizontal, showPane: show)
                .transition(.scale(scale: 0.7, anchor: .leading).combined(with: .opacity))
                .id(entry.id)
        }
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
