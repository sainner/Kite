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
    /// 见 DockFace.ring。
    var ring = true
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.dockCurrentPane) private var current

    var body: some View {
        let id = instanceID, arrow = self.arrow
        DockFace(look: look, running: area.isRunning(id), tint: area.attention(of: id)?.color, arrow: arrow, ring: ring)
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
        return .tool(area.appearance(of: instance))
    }
}

/// 进行中（运行、正在停止、正在收尾）从头像向外扩散的实心脉冲，颜色和节奏随阶段，大小头像按比例；不含头像。
/// 只填头像外面的一圈，画在上面也不盖住头像：最小化的窗口卡片自己画头像，脉冲画在卡片上面。
/// 一次一个波，前一个散尽再发下一个；减弱动态时停在半路，只留一圈淡晕。节奏按绝对时间对齐，几个头像同阶段时同步。
struct DockPulse: View {
    let instance: String
    @Environment(WorkArea.self) private var area
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 波传出去的距离占头像直径的比例。
    static let reach: CGFloat = 9 / 36

    var body: some View {
        if area.isRunning(instance) {
            // 等你回应时按等待的节奏起伏，颜色同头像换上的警示黄
            let activity = area.activities[instance]
            let phase = activity?.waiting != nil ? "waiting" : activity?.phase ?? "idle"
            let color = ContextRing.color(phase), period = max(ContextRing.period(phase), 1)
            let margin = Metrics.dragBubble * Self.reach
            // 交给图层动画，跟屏幕刷新率走，主线程不逐帧重画
            DockPulseLayers(color: color, period: period, margin: margin, still: reduceMotion)
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
    /// 紧凑布局里没有窗口的实例不缩成小头像，盖一层半透明的底色。
    var veiled = false
    var hoverFrame: CGRect?
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.dockAxis) private var axis

    var body: some View {
        let size = DockGeometry.cellSize(entry, mini: mini, axis: axis)
        Button(action: activate) {
            DockCell(entry: entry, mini: mini)
                .frame(width: size.width, height: size.height)
                .overlay { if veiled { outline(size).fill(Theme.background.opacity(0.5)) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.pointingPlain)
        .accessibilityLabel(area.dockLabel(entry))
        .onHover { hovering in
            if let hoverFrame { area.setDockHover(entry.id, frame: hoverFrame, hovering: hovering) }
        }
        .contextMenuOutline(outline(size))
        .contextMenu { DockEntryMenu(entry: entry) }
    }

    private func outline(_ size: CGSize) -> DockOutline {
        let width = min(size.width, size.height)
        switch entry {
        case .family(let family): return DockOutline(length: DockFamilyFace.length(family, width: width), axis: axis)
        case .more: return DockOutline()
        case .instance(let instance): return .face(agent: area.isAgent(instance), width: width)
        case .pane(let pane): return .face(agent: area.isAgentPane(pane), width: width)
        }
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
            if let instance = area.instance(of: pane) { InstanceActions(instance: instance, pane: pane) }
            else { Button("关闭窗口") { model.closeWindow(pane, in: area) } }
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
        .contextMenuOutline(Circle())
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

/// 加号：宽屏是圆、右上角与窗口右上角同心；紧凑布局的底栏边上没有窗口角，是正圆。
/// 点开是新建窗口（见 WorkArea.openChooser）。
struct AddWindowButton: View {
    var concentric = true
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area

    /// 右上角与窗口同心时圆角的下限，窗口角太小时不至于变成尖角。
    private static var minimumCorner: CGFloat { Metrics.dragBubble * 19 / 72 }

    var body: some View {
        let size = Metrics.dragBubble, radius = size / 2
        Button {
            area.openChooser()
        } label: {
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
        .help("创建窗口")
        .accessibilityLabel("添加")
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

/// 紧凑布局底栏里的当前窗口：垫在格子下面的选中底，向外扩出一圈，与格子同心。
struct DockSelection: View {
    /// 格子的圆角：工具图标是圆角矩形；nil 是代理头像和家族格，用圆和胶囊。
    var cornerRadius: CGFloat?

    var body: some View {
        let outset = Metrics.gap / 3
        Group {
            if let cornerRadius { RoundedRectangle(cornerRadius: cornerRadius + outset, style: .continuous).fill(Theme.selection) }
            else { Capsule().fill(Theme.selection) }
        }
        .padding(-outset)
    }
}

/// 长按菜单浮起的轮廓，与格子画出来的同形；不指定时系统按格子的方框取圆角矩形。
nonisolated struct DockOutline: Shape {
    /// 圆角；nil 是代理头像的圆和家族的胶囊。
    var cornerRadius: CGFloat?
    /// 家族胶囊沿排列方向的长度：小头像里的家族比格子短，竖排贴上端、横排贴右端，同 DockCell。nil 是铺满格子。
    var length: CGFloat?
    var axis: Axis = .vertical

    /// 一个头像：代理是圆，工具的圆角随格子大小缩放，同 DockFace。
    @MainActor static func face(agent: Bool, width: CGFloat = Metrics.dragBubble) -> Self {
        Self(cornerRadius: agent ? nil : Metrics.dockRadius * width / Metrics.dragBubble)
    }

    func path(in rect: CGRect) -> Path {
        var frame = rect
        if let length {
            if axis == .vertical { frame.size.height = min(length, rect.height) }
            else { frame = CGRect(x: rect.maxX - min(length, rect.width), y: rect.minY, width: min(length, rect.width), height: rect.height) }
        }
        if let cornerRadius { return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: frame) }
        return Capsule().path(in: frame)
    }
}

extension View {
    /// 长按菜单浮起的轮廓；Mac 的右键菜单没有浮起的预览。
    func contextMenuOutline(_ shape: some Shape) -> some View {
        #if os(iOS)
        contentShape(.contextMenuPreview, shape)
        #else
        self
        #endif
    }
}

/// 紧凑布局的底栏：加号固定在最右端；其余的与宽屏停靠栏同样的样式，从右往左依次是代理、工具、没有窗口的实例，
/// 组内按先后从左往右排，新的在同组最右端，从上面落进来、两边让开；排不满时靠右，当前窗口也在里面。
/// 左边还有滚出去的时候堆叠起来（见 DockStackCurve），右边滚出去的渐隐、画箭头。
/// 没有窗口的不缩成小头像，盖一层底色，也不收进「更多」。家族格原地拉宽展开，其余的模糊淡出。
///
/// 滚动区只借它的手势、惯性和滚动范围：里面是一条和照原来间距排开一样长的空轨道，头像钉在可视区里，由 DockStackLayout
/// 按离右端滚了多远来摆，加减格子、展开收起时由排版的动画过渡。头像若直接排在滚动内容里、用 visualEffect 挪成堆叠，
/// 内容变长时右端锚定会让滚动偏移跟着动画，visualEffect 拿到的却是格子的终点，两者对不上，堆叠会先散开再收回。
struct CompactDockBar: View {
    @Binding var open: WorkspaceDrawer?
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    /// 滚动区的宽，含四周让出的一圈。
    @State private var width: CGFloat = 0
    @State private var scroll = DockScroll()
    /// 刚加进底栏的窗口：切过去时把它滚到最右，见 reveal。
    @State private var fresh: Set<Pane> = []

    /// 头像的脉冲和选中底伸出格子，滚动区向四周多让出这一圈，免得被截掉；排版仍按格子算。
    private var margin: CGFloat { Metrics.dragBubble * DockPulse.reach }
    /// 展开的那一项在轨道上的替身，滚动到它让那一项居中。
    private static let focus = "dock-focus"
    /// 当前窗口在轨道上的替身，见 reveal。
    private static let current = "dock-current"

    var body: some View {
        let layout = area.layout
        let dock = area.dockModel(docked: layout.panes, onStage: [])
        let dimmed = !area.dockExpansion.isEmpty
        let region = max(width - 2 * margin, 0)
        // 代理按窗口先后排，有子代理的不提前：窗口有了子代理也不挪位置
        let agents = dock.agents.sorted { rank($0, in: layout.panes) < rank($1, in: layout.panes) }
        let items = dock.windowless.map { DockStackItem.entry($0, veiled: true) } + dock.tools.map { .entry($0, veiled: false) }
            + (agents.isEmpty || dock.tools.isEmpty ? [] : [.divider]) + agents.map { .entry($0, veiled: false) }
        let current = items.firstIndex { if case .entry(let entry, _) = $0 { window(of: entry) == layout.focused } else { false } }
        // 照原来的间距排开时每一项的长、离最左一项多远，整串多长
        let extents = items.map(extent)
        let positions = extents.indices.map { extents[..<$0].reduce(0, +) + Metrics.gap * CGFloat($0) }
        let total = (positions.last ?? 0) + (extents.last ?? 0)
        // 轨道两头含让出的一圈，不用 contentMargins：有内边距时滚动区坐标的原点不在边上，钉住会偏一圈
        let track = max(total, region) + 2 * margin, height = Metrics.dragBubble + 2 * margin
        let divider = items.firstIndex { $0.id == DockStackItem.divider.id }.map { positions[$0] } ?? 0
        HStack(spacing: Metrics.gap) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    Color.clear
                        .frame(width: track, height: height)
                        .overlay(alignment: .leading) {
                            if let index = items.firstIndex(where: { $0.id == area.dockExpansion.first }) {
                                Color.clear.frame(width: extents[index], height: 1).id(Self.focus)
                                    .padding(.leading, track - margin - total + positions[index])
                            }
                        }
                        .overlay(alignment: .leading) {
                            // 右边多出让出的那一圈：替身的右端贴着可视区右边时，格子正好贴着头像那一段的右端
                            if let current {
                                Color.clear.frame(width: extents[current] + margin, height: 1).id(Self.current)
                                    .padding(.leading, track - margin - total + positions[current])
                            }
                        }
                        .overlay(alignment: .leading) {
                            DockStackView(scroll: scroll, stacking: !dimmed, total: total) {
                                ForEach(Array(zip(items, positions)), id: \.0.id) { item, position in
                                    Group {
                                        switch item {
                                        case .entry(let entry, let veiled):
                                            self.item(entry, dimmed: dimmed, veiled: veiled)
                                        case .divider:
                                            DockStackDivider(scroll: scroll, position: divider, total: total, region: region, stacking: !dimmed)
                                                .modifier(DockDimmed(dimmed: dimmed))
                                                .transition(.opacity)
                                        }
                                    }
                                    .layoutValue(key: DockStackPosition.self, value: position)
                                }
                            }
                            .environment(\.dockAxis, .horizontal)
                            .environment(\.dockCurrentPane, layout.focused)
                            .animation(.snappy, value: items.map(\.id) + area.dockExpansion)
                            .padding(margin)
                            .frame(width: width, height: height)
                            // 钉在可视区：滚动挪了多少，反着挪回来
                            .visualEffect { content, proxy in
                                content.offset(x: -proxy.frame(in: .scrollView(axis: .horizontal)).minX)
                            }
                        }
                }
                // 排满时停在右端，增减格子时右端不动
                .defaultScrollAnchor(.trailing)
                // 轨道变长变短时不跟着动画，右端立刻锚住、离右端的距离不变，格子让位交给 DockStackLayout 的动画
                .transaction(value: track) { $0.animation = nil }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentSize.width - geometry.visibleRect.maxX
                } action: { _, distance in
                    withTransaction(Transaction(animation: nil)) { scroll.distance = distance }
                }
                .hintsScrollOverflow(.horizontal, carets: .endOnly)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .onChange(of: area.dockExpansion.first) { _, id in
                    if id != nil { withAnimation(.snappy) { proxy.scrollTo(Self.focus, anchor: .center) } }
                }
                // 新窗口加进来和切过去可能不在同一次更新里，先记下，切过去时再滚
                .onChange(of: layout.panes) { old, new in
                    // 累加：新窗口加进来、切过去之前别的窗口又有增减，也还记着它
                    fresh = fresh.union(Set(new).subtracting(old)).intersection(new)
                    reveal(proxy)
                }
                .onChange(of: layout.focused) {
                    reveal(proxy)
                    fresh = []
                }
                .padding(-margin)
            }
            AddWindowButton(concentric: false)
                .modifier(DockDimmed(dimmed: dimmed))
        }
        .onChange(of: layout.focused.map(area.dockInstanceID), initial: true) { _, id in
            area.noteVisible(id.map { [$0] } ?? [])
        }
        .onDisappear { area.noteVisible([]) }
        .task(id: model.revision(for: area)) {
            try? await model.ensureRoles(in: area)
        }
    }

    /// 照原来的间距排开时这一项沿底栏的长：展开的家族格、「更多」按面板算。
    private func extent(_ item: DockStackItem) -> CGFloat {
        guard case .entry(let entry, _) = item else { return 1 }
        if entry.expands, area.dockExpansion.first == entry.id { return DockPanel.extent(entry, path: area.dockExpansion.dropFirst()) }
        return DockGeometry.cellSize(entry, axis: .horizontal).width
    }

    private func item(_ entry: DockEntry, dimmed: Bool, veiled: Bool) -> some View {
        let expanded = area.dockExpansion.first == entry.id
        // 包一层容器：进出底栏的过渡只管整格，不落到里面展开、收起的切换上
        return ZStack {
            if entry.expands, expanded {
                DockPanel(entry: entry, depth: 0, axis: .horizontal, showPane: show)
                    .transition(.scale(scale: 0.7, anchor: .trailing).combined(with: .opacity))
            } else if case .pane(let pane) = entry {
                paneButton(pane)
            } else {
                DockCellButton(entry: entry, depth: 0, veiled: veiled)
                    .background { if current(entry) { DockSelection() } }
            }
        }
        .modifier(DockDimmed(dimmed: dimmed && !expanded))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// 新加的窗口切过去时（新建的窗口会自动切过去），把它滚到头像那一段的最右；离左端太近滚不到最右时停在左端，
    /// 全部照原来的间距排开，它也就尽量靠右了。
    private func reveal(_ proxy: ScrollViewProxy) {
        guard let focused = area.layout.focused, fresh.contains(focused) else { return }
        fresh = []
        withAnimation(.snappy) { proxy.scrollTo(Self.current, anchor: .trailing) }
    }

    /// 一格代表的窗口：家族按父代理的窗口算。
    private func window(of entry: DockEntry) -> Pane? {
        switch entry {
        case .pane(let pane): pane
        case .family(let family): family.pane
        default: nil
        }
    }

    /// 一格在窗口里的先后。
    private func rank(_ entry: DockEntry, in panes: [Pane]) -> Int {
        window(of: entry).flatMap { panes.firstIndex(of: $0) } ?? panes.count
    }

    private func paneButton(_ pane: Pane) -> some View {
        let current = area.layout.focused == pane, agent = area.isAgentPane(pane)
        return Button {
            if !current { area.layout.focus(pane) }
            open = nil
        } label: {
            DockEntryFace(subject: .pane(pane))
                .frame(width: Metrics.dragBubble, height: Metrics.dragBubble)
        }
        .buttonStyle(.pointingPlain)
        .accessibilityLabel(area.dockLabel(.pane(pane)))
        .contextMenuOutline(DockOutline.face(agent: agent))
        .contextMenu { DockEntryMenu(entry: .pane(pane)) }
        // 选中底垫在菜单外面，同家族格：长按浮起的只有头像，选中底留在底栏里
        .background { if current { DockSelection(cornerRadius: agent ? nil : Metrics.dockRadius) } }
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

/// 底栏里排成一串的一项：格子或工具与代理之间的分隔线。
private enum DockStackItem: Identifiable {
    case entry(DockEntry, veiled: Bool)
    case divider

    var id: String {
        switch self {
        case .entry(let entry, _): entry.id
        case .divider: "divider"
        }
    }
}

/// 底栏离右端滚了多远。单独放一个对象：滚动时只有读它的排版和分隔线重算，外面的停靠栏不跟着重算。
@MainActor @Observable private final class DockScroll {
    var distance: CGFloat = 0
}

/// 堆叠的摆法：照原来的间距排开时离最左一项 c 远的格子，画在头像那一段（宽 region）的哪里。
/// 左边还有滚出去的时候，靠右的一段照原来的间距，左边那段越往左挤得越紧，滚出去的都叠进最左端，越远叠得越密、最后完全重合。
/// 从内容开头到挤的那段右端共 span 长，按 zone·(c/span)^(span/zone) 收进宽 zone 的那段：开头贴着左端，右端接上原来的间距、
/// 连斜率也接上。挤的程度随滚出去的多少连续变化：滑到最左时全部照原来的间距排开；排不满时靠右；展开时不挤。
private nonisolated struct DockStackCurve {
    /// 左边挤起来的那段占头像那一段的比例，靠右的其余部分照原来的间距。
    static let squeeze: CGFloat = 0.6

    /// 左边滚出去多长。
    let hidden: CGFloat
    let zone: CGFloat

    init(total: CGFloat, region: CGFloat, distance: CGFloat, stacking: Bool) {
        hidden = total - region - distance
        zone = stacking ? region * Self.squeeze : 0
    }

    func callAsFunction(_ c: CGFloat) -> CGFloat {
        guard hidden > 0, zone > 0, c - hidden < zone else { return c - hidden }
        let span = hidden + zone
        return zone * pow(max(c, 0) / span, span / zone)
    }
}

/// 按离右端滚了多远摆一串格子：滚动时只有这里重算。
private struct DockStackView<Content: View>: View {
    let scroll: DockScroll
    let stacking: Bool
    let total: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        DockStackLayout(distance: scroll.distance, stacking: stacking, total: total) { content }
    }
}

/// 一格照原来的间距排开时离最左一项多远，body 按格子算好交给排版（DockStackPosition）。
private nonisolated struct DockStackPosition: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// 从左往右排一串格子，位置按 DockStackCurve，靠右的压在上面。位置是排版算出来的，变化时由排版的动画过渡。
/// 每格离最左多远、整串多长都用 body 算好的，和轨道、分隔线、替身同一套，滚动时不再逐格量：正在淡出的格子还在
/// subviews 里，但不占位置（留在原来那格淡出），别的格子当场带着动画让位，淡出完不会再跳一下。
private struct DockStackLayout: Layout {
    var distance: CGFloat
    var stacking: Bool
    var total: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let curve = DockStackCurve(total: total, region: bounds.width, distance: distance, stacking: stacking)
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.minX + curve(subview[DockStackPosition.self]), y: bounds.midY), anchor: .leading,
                          proposal: .unspecified)
        }
    }
}

/// 工具和代理之间的分隔线：跟着格子堆叠，挤到和两边的格子没有间距时淡出。左边挨着的工具一格宽。
private struct DockStackDivider: View {
    let scroll: DockScroll
    /// 照原来的间距排开时离最左一项多远，整串多长。
    let position: CGFloat
    let total: CGFloat
    let region: CGFloat
    let stacking: Bool

    var body: some View {
        let gap = Metrics.gap, cell = Metrics.dragBubble
        let curve = DockStackCurve(total: total, region: region, distance: scroll.distance, stacking: stacking)
        let spacing = min(curve(position) - curve(position - gap - cell) - cell, curve(position + 1 + gap) - curve(position) - 1)
        Rectangle().fill(Theme.rule)
            .frame(width: 1, height: Metrics.dragBubble * 0.6)
            .opacity(min(max(spacing / (gap / 3), 0), 1))
    }
}
