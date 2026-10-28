import SwiftUI

/// 指针停在停靠栏哪一格上：Mac 在左边浮出名字与状态。frame 用内容区坐标；为 nil 时按停靠栏的几何找（见 DockGeometry.hoverFrame），
/// 带子上的格子挪着摆（堆叠、滚动），自己不报位置。
struct DockHover: Equatable {
    let id: String
    var frame: CGRect?
}

extension DockModel {
    /// 按 ID 找到一格，家族里的也算；家族的父代理按实例找。
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
    /// 点开或收起家族格；depth 是它所在的层，外层在前，axis 是停靠栏的方向。展开外层的那一刻定下它最长多长：到停靠栏看得见的末端为止
    /// （见 DockBandMetrics.familyLimit）。
    func toggleDock(_ id: String, depth: Int, axis: Axis) {
        if depth == 0, dockExpansion.first != id { dockFamilyLimit = familyLimit(for: id, axis: axis) }
        withAnimation(.snappy) {
            if dockExpansion.count > depth, dockExpansion[depth] == id { dockExpansion = Array(dockExpansion.prefix(depth)) }
            else { dockExpansion = Array(dockExpansion.prefix(depth)) + [id] }
        }
    }

    /// 指针进入一格时浮出它的标签，离开时只收起自己的。
    func setDockHover(_ id: String, frame: CGRect? = nil, hovering: Bool) {
        if hovering { dockHover = DockHover(id: id, frame: frame) }
        else if dockHover?.id == id { dockHover = nil }
    }

    /// 展开 id 那个家族格时它最长多长：按它收着时照原来的间距排开离前端多远、停靠栏这一刻滚到哪。
    private func familyLimit(for id: String, axis: Axis) -> CGFloat? {
        guard dockVisibleLength > 0 else { return nil }
        let items = dockModel().bandItems(axis)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let run = DockBandRun(extents: items.map { DockBandMetrics.extent($0, expansion: [], limit: 0) }, gap: Metrics.gap)
        return DockBandMetrics.familyLimit(visible: dockVisibleLength, front: run.starts[index], distance: dockScrollDistance)
    }

    func collapseDock() {
        guard !dockExpansion.isEmpty else { return }
        withAnimation(.snappy) { dockExpansion = [] }
    }

    /// 点了展开的家族格里的一项、放上了台面：等台面按展开着的样子排完这一轮再收起，卡片从那一项现在的位置飞出去，
    /// 不从收起后的胶囊里起。
    func collapseDockAfterShowing() {
        guard !dockExpansion.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.collapseDock() }
    }

    /// pane 对应的实例 ID（就是 pane 的 ID；草稿是草稿会话的 ID）；新建页交给了后台实例的按那个实例算。
    func dockInstanceID(_ pane: Pane) -> String {
        handedOff[pane.id] ?? pane.id
    }
}

/// 一个实例在停靠栏里的样子，连同进行中的脉冲波。
/// 实例正看得到时头像模糊、画上指向它的箭头，不显示状态：宽屏台面上的（dockOnStage）向左，紧凑布局的当前窗口向上。
/// 卡片自己画着头像的时候（dockHidden：在停靠栏和台面之间飞、拖着）这里不画，同一时刻只有一份头像；
/// 卡片停到台面上以后「看得到」的样子淡入，别的时候当场换手（卡片和格子在同一处、一样的样子）。
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
    /// 家族格里的父代理：家族收着到哪（1 收着、0 展开）。收着时子代理的脉冲不发（见 DockGroup），家族里有别的成员在跑，
    /// 父代理这一格替它发；展开途中跟着淡出，换成各自的脉冲。
    var familyFold: Double = 0
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.dockCurrentPane) private var current
    @Environment(\.dockOnStage) private var onStage
    @Environment(\.dockHidden) private var hiddenInstances
    @Environment(\.dockPulseOpacity) private var pulseOpacity

    var body: some View {
        let id = instanceID, arrow = self.arrow, hidden = hiddenInstances.contains(id)
        DockFace(look: look, running: area.isRunning(id), tint: area.attention(of: id)?.color, arrow: arrow, ring: ring)
            .overlay {
                if pulse, pulseOpacity > 0 {
                    if arrow == nil, area.isRunning(id) { DockPulse(instance: id).opacity(pulseOpacity) }
                    else if familyFold > 0, let member = runningMember { DockPulse(instance: member).opacity(pulseOpacity * familyFold) }
                }
            }
            .opacity(hidden ? 0 : 1)
            .animation(arrow != nil && !hidden ? .easeOut(duration: 0.2) : nil, value: hidden)
    }

    /// 家族里在跑、此刻又看不到的子代理（各层都算，按家族里的先后取第一个）：脉冲的颜色和节奏按它。
    /// 父代理自己在跑时发它自己的；正看得到的（台面上、紧凑布局的当前窗口）不替它发，同头像「看得到」时不显示状态。
    private var runningMember: String? {
        guard case .parent(let family) = subject else { return nil }
        let shown = current.map(area.dockInstanceID)
        return DockEntry.family(family).instanceIDs.dropFirst().first { area.isRunning($0) && !onStage.contains($0) && $0 != shown }
    }

    private var arrow: String? {
        switch subject {
        case .pane(let pane): pane == current ? "arrow.up" : onStage.contains(area.dockInstanceID(pane)) ? "arrow.left" : nil
        case .instance(let instance): onStage.contains(instance.id) ? "arrow.left" : current.map(area.dockInstanceID) == instance.id ? "arrow.up" : nil
        case .parent(let family): onStage.contains(family.parent.id) ? "arrow.left" : family.pane == current ? "arrow.up" : nil
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
/// 只填头像外面的一圈，画在上面也不盖住头像。
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

/// 有视图的实例（含草稿、打开着的新建页）在停靠栏的一格：点了宽屏放上台面（在台面上就聚焦）、紧凑布局切过去；
/// 宽屏上按住拖出去放到台面上（见 DockPaneDrag）。长按与右键是实例菜单。紧凑布局的当前窗口垫选中底。
struct DockPaneButton: View {
    let pane: Pane
    let show: (Pane) -> Void
    @Environment(WorkArea.self) private var area
    @Environment(\.dockCurrentPane) private var current

    var body: some View {
        Button {
            show(pane)
            area.collapseDock()
        } label: {
            DockEntryFace(subject: .pane(pane))
                .frame(width: Metrics.dragBubble, height: Metrics.dragBubble)
                .contentShape(Circle())
        }
        .buttonStyle(.pointingPlain)
        .accessibilityLabel(area.dockLabel(.pane(pane)))
        .modifier(DockPaneDrag(pane: pane))
        .modifier(DockHoverReport(id: DockEntry.pane(pane).id))
        .contextMenuOutline(Circle())
        .contextMenu { DockEntryMenu(entry: .pane(pane)) }
        // 选中底垫在菜单外面：长按浮起的只有头像，选中底留在底栏里
        .background { if current == pane { DockSelection() } }
    }
}

/// 收着的一格：没有视图的实例（盖一层半透明的底色，点开实例设置），或家族格展开后里面的一项（有视图的放上台面）。家族见 DockGroup。
struct DockCellButton: View {
    let instance: RemotePluginInstance
    /// 没有视图的实例盖一层半透明的底色。
    var veiled = false
    /// 带子上的一格自己报悬停（位置按停靠栏的几何找）；家族里的一项由 DockItemHover 报。
    var reportsHover = false
    /// 家族里点了子代理：同点父代理，放上台面，见 DockGroup.showPane。
    var showPane: ((Pane) -> Void)?
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area

    var body: some View {
        let size = Metrics.dragBubble
        Button(action: activate) {
            DockEntryFace(subject: .instance(instance))
                .frame(width: size, height: size)
                .overlay { if veiled { Circle().fill(Theme.background.opacity(0.5)) } }
                .contentShape(Circle())
        }
        .buttonStyle(.pointingPlain)
        .accessibilityLabel(area.dockLabel(entry))
        .modifier(DockPaneDrag(pane: draggable))
        .onHover { hovering in
            if reportsHover { area.setDockHover(entry.id, hovering: hovering) }
        }
        .contextMenuOutline(Circle())
        .contextMenu { DockEntryMenu(entry: entry) }
    }

    private var entry: DockEntry { .instance(instance) }

    /// 有视图的实例能拖出去放上台面。
    private var draggable: Pane? {
        area.currentView(of: instance) != nil ? Pane(instance.id) : nil
    }

    private func activate() {
        if let showPane, area.currentView(of: instance) != nil { showPane(Pane(instance.id)) }
        else { model.openDockInstance(instance, in: area) }
        area.collapseDockAfterShowing()
    }
}

/// 带子上的一格报悬停，标签的位置按停靠栏的几何找。
struct DockHoverReport: ViewModifier {
    let id: String
    @Environment(WorkArea.self) private var area

    func body(content: Content) -> some View {
        content.onHover { area.setDockHover(id, hovering: $0) }
    }
}

/// 宽屏台面（dockStage）的停靠栏里按住一格拖出去：同拖卡片，卡片缩成停靠形状跟着指针，放到台面上展开、放回停靠栏回到自己那一格。
/// iPad 上手指长按起拖、指针按住挪动起拖，见 DockCellTouch；紧凑布局没有台面，不拖。
struct DockPaneDrag: ViewModifier {
    let pane: Pane?
    @Environment(WorkArea.self) private var area
    @Environment(\.dockStage) private var stage

    func body(content: Content) -> some View {
        #if os(macOS)
        if let pane, let stage {
            content.highPriorityGesture(
                DragGesture(minimumDistance: Metrics.dragThreshold, coordinateSpace: .named(DockSpace.name))
                    .onChanged { value in
                        area.collapseDock()
                        area.dockHover = nil
                        area.layout.drag(pane, to: value.location, in: stage.bounds)
                    }
                    .onEnded { _ in area.layout.drop(in: stage.bounds) }
            )
        } else {
            content
        }
        #else
        content.modifier(DockCellTouch(pane: stage == nil ? nil : pane))
        #endif
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
            else if area.hasClose(pane) { Button("关闭窗口") { model.close(pane, in: area) }.disabled(!area.canClose(pane)) }
        }
    }
}

/// 家族格：收着和展开是同一个组件的两种样子，openness 从 0（收着）到 1（展开）逐帧插值，每个头像始终是同一个视图，
/// 从叠着的地方挪到排开的地方，胶囊跟着拉长；收起时原路叠回去。
/// 收着：一格宽的长胶囊，父代理在最前面（竖排在上，横排在右），子代理和它一样大，一个压一个往后错开，各露出一截，
/// 最多露三个、往后渐隐（见 foldedOpacity），再多不再变长。整格是一个按钮，点了展开。
/// 展开：各项放大到一格的大小，沿排列方向排开，里面的才接点击；里面再展开的家族嵌在描边里，同样原地展开。
/// 排不下时（viewport）照停靠栏的堆叠排，越靠后越透明。
/// 宽屏竖排，紧凑布局横排；横排和底栏一样倒着排，第一项在右端。
struct DockGroup: View, Animatable {
    let entry: DockEntry
    let depth: Int
    /// 展开的目标：收着时整格是一个按钮，展开时里面的才接点击。openness 是这一刻画到哪。
    var expanded = false
    var openness: CGFloat = 0
    /// 紧凑布局里当前窗口在这一家：垫选中底，展开时淡掉。
    var selected = false
    /// 看得见的那一段，排不下时在里面滚动，见 openSlots。
    var viewport: DockViewport?
    /// 点了家族里的代理：宽屏放上台面，紧凑布局切过去。
    var showPane: (Pane) -> Void = { _ in }

    @Environment(WorkArea.self) private var area
    @Environment(\.dockAxis) private var axis
    /// 外层收着时，自己只露最前面的头像。
    @Environment(\.dockFaceDetail) private var detail

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    static var padding: CGFloat { Metrics.dragBubble * 5 / 36 }
    static let shownChildren = 3
    static func inset(_ width: CGFloat) -> CGFloat { width * 3 / 36 }
    /// 收着的家族胶囊沿排列方向多长：每露一个子代理长三分之一格。
    static func length(_ family: DockFamily, width: CGFloat) -> CGFloat {
        width * (1 + CGFloat(min(family.children.count, shownChildren)) / 3)
    }

    /// 收着时沿排列方向多长：家族是胶囊，其余一格。
    static func foldedLength(_ entry: DockEntry) -> CGFloat {
        guard case .family(let family) = entry else { return Metrics.dragBubble }
        return length(family, width: Metrics.dragBubble)
    }

    /// 收着时第 index 项（父代理是 0）露出来的透明度：子代理往后渐隐，露不出来的看不见。
    static func foldedOpacity(_ index: Int) -> Double {
        switch index {
        case 0: 1
        case 1...shownChildren: 1 - 0.25 * Double(index)
        default: 0
        }
    }

    /// 收着时的大小：家族是胶囊。
    static func foldedSize(_ entry: DockEntry, width: CGFloat, axis: Axis) -> CGSize {
        guard case .family(let family) = entry else { return CGSize(width: width, height: width) }
        let length = length(family, width: width)
        return axis == .vertical ? CGSize(width: width, height: length) : CGSize(width: length, height: width)
    }

    /// 一项展开后沿排列方向的长和垂直方向的宽：没展开的按格子，展开了的按它自己展开后的大小。
    static func box(_ member: DockEntry, path: ArraySlice<String>) -> (along: CGFloat, across: CGFloat) {
        if member.expands, path.first == member.id { return (extent(member, path: path.dropFirst()), breadth(member, path: path.dropFirst())) }
        return (foldedLength(member), Metrics.dragBubble)
    }

    /// 展开后沿排列方向的长度，停靠栏据此摆放。
    static func extent(_ entry: DockEntry, path: ArraySlice<String>) -> CGFloat {
        let members = entry.members
        var total = 2 * padding + Metrics.gap * CGFloat(max(members.count - 1, 0))
        for member in members { total += box(member, path: path).along }
        return total
    }

    /// 展开后垂直于排列方向的宽度：每嵌一层多两份内边距。
    static func breadth(_ entry: DockEntry, path: ArraySlice<String>) -> CGFloat {
        let nested = entry.members.first { $0.expands && path.first == $0.id }
        return 2 * padding + (nested.map { breadth($0, path: path.dropFirst()) } ?? Metrics.dragBubble)
    }

    /// 排开时各项离开头多远（沿排列方向，不缩放）与透明度：沿排列方向依次排，两头留 padding；viewport 排不下时只有看得见的那一段长，
    /// 照停靠栏的堆叠排（见 DockStackCurve）：开头照原来的间距，末端还有没滚到的时候挤起来、叠进末端、越靠后越透明；
    /// 开头滚出去的渐隐，见 DockStartFade。length 是排开后沿排列方向多长。卡片落点（DockGeometry）也按它算。
    static func openPlacement(_ entry: DockEntry, path: ArraySlice<String>, viewport: DockViewport?)
        -> (length: CGFloat, members: [(along: CGFloat, opacity: Double)]) {
        let extent = Self.extent(entry, path: path)
        var along = padding
        var members = entry.members.map { member -> (along: CGFloat, opacity: Double) in
            let box = box(member, path: path)
            defer { along += box.along + Metrics.gap }
            return (along, 1)
        }
        guard let viewport, extent > viewport.length else { return (extent, members) }
        // 同停靠栏从末端量：一项靠末端的那条边离内容末端多远，按曲线摆到离看得见的末端多远
        let total = extent - 2 * padding, region = viewport.length - 2 * padding
        let curve = DockStackCurve(total: total, region: region, distance: viewport.offset, stacking: 1)
        for (index, member) in entry.members.enumerated() {
            let size = box(member, path: path).along
            let end = total - (members[index].along - padding + size)
            members[index] = (padding + region - curve(end) - size, curve.opacity(end + size / 2))
        }
        return (viewport.length, members)
    }

    var body: some View {
        let path = area.dockExpansion.dropFirst(depth + 1)
        let (size, slots) = slots(path: path)
        let isFamily = if case .family = entry { true } else { false }
        let fill = Double(min(max(openness, 0), 1))
        // 竖排贴上端、横排贴右端；垂直方向始终居中，外层变宽时里面的不跟着偏
        let alignment: Alignment = axis == .vertical ? .top : .trailing, anchor: UnitPoint = axis == .vertical ? .top : .trailing
        ZStack(alignment: alignment) {
            ForEach(Array(entry.members.enumerated()), id: \.element.id) { index, member in
                let slot = slots[index], unfolded = member.expands && path.first == member.id
                self.member(member, at: index, unfolded: unfolded, fold: 1 - fill)
                    .frame(width: slot.box.width, height: slot.box.height, alignment: alignment)
                    // 收着时同格子：家族里只有父代理发脉冲（子代理在跑也由它发），自己也带着子代理的只露头像，都不发
                    .transformEnvironment(\.dockPulseOpacity) { $0 *= isFamily && index == 0 ? 1 : fill }
                    .environment(\.dockFaceDetail, isFamily ? fill : 1)
                    .modifier(DockSlotScale(scale: slot.scale, anchor: anchor))
                    .opacity(slot.opacity * (isFamily && index > 0 ? detail : 1))
                    .offset(axis == .vertical ? CGSize(width: 0, height: slot.along) : CGSize(width: -slot.along, height: 0))
                    // 里面又展开了一层时，这一层其余的模糊淡出
                    .modifier(DockDimmed(dimmed: path.first.map { $0 != member.id } ?? false))
                    // 叠着时前面的压在后面的上面；展开着的压在别的上面
                    .zIndex(Double(-index) + (unfolded ? 0.5 : 0))
            }
        }
        .allowsHitTesting(expanded)
        .accessibilityHidden(!expanded)
        .frame(width: size.width, height: size.height, alignment: alignment)
        .modifier(DockStartFade(axis: axis, amount: viewport.map { Double(min(max($0.offset / ScrollOverflowCaret.fade, 0), 1)) }))
        // 收着时没有底色，同停靠栏的底
        .background {
            Capsule().fill(Theme.background).opacity(fill * detail)
            Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1).opacity((isFamily ? 1 : fill) * detail)
        }
        .background { if selected { DockSelection().opacity(1 - fill) } }
        .overlay { if !expanded { foldedButtons } }
        .contextMenuOutline(Capsule())
        .contextMenu { if !expanded { DockEntryMenu(entry: entry) } }
    }

    /// 收着时：点父代理的头像直接打开它（宽屏上按住拖出去放上台面），点其余的地方展开；悬停整格浮出名字。
    private var foldedButtons: some View {
        let width = Metrics.dragBubble, inset = Self.inset(width), face = width - 2 * inset
        return ZStack(alignment: axis == .vertical ? .top : .trailing) {
            Button { area.toggleDock(entry.id, depth: depth, axis: axis) } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.pointingPlain)
            .accessibilityLabel(area.dockLabel(entry))
            if case .family(let family) = entry {
                Button { openParent(family) } label: {
                    Color.clear.contentShape(Circle())
                }
                .buttonStyle(.pointingPlain)
                .frame(width: face, height: face)
                .padding(inset)
                .accessibilityLabel(area.dockLabel(.instance(family.parent)))
                .modifier(DockPaneDrag(pane: family.pane))
            }
        }
        .onHover { hovering in
            if depth == 0 { area.setDockHover(entry.id, hovering: hovering) }
        }
    }

    /// 打开父代理：放上台面（在台面上就聚焦）。
    private func openParent(_ family: DockFamily) {
        showPane(family.pane)
        area.collapseDockAfterShowing()
    }

    /// fold 是收着到哪（1 收着、0 展开），父代理替收着的子代理发脉冲，见 DockEntryFace.familyFold。
    @ViewBuilder
    private func member(_ member: DockEntry, at index: Int, unfolded: Bool, fold: Double) -> some View {
        if index == 0, case .family(let family) = entry {
            parentRow(family, fold: fold)
        } else if member.expands {
            DockGroup(entry: member, depth: depth + 1, expanded: unfolded, openness: unfolded ? 1 : 0, showPane: showPane)
                .modifier(DockItemHover(id: member.id, enabled: !unfolded))
        } else if case .instance(let instance) = member {
            DockCellButton(instance: instance, showPane: showPane)
                .modifier(DockItemHover(id: member.id))
        }
    }

    /// 一项摆在哪：box 是它不缩放时占的方框，along 是缩放后离开头（竖排上端、横排右端）多远，垂直方向居中。
    private struct Slot {
        var box: CGSize
        var along: CGFloat
        var scale: CGFloat = 1
        var opacity: Double = 1
    }

    private func measure(_ member: DockEntry, path: ArraySlice<String>) -> (along: CGFloat, across: CGFloat, size: CGSize) {
        let box = Self.box(member, path: path)
        return (box.along, box.across, axis == .vertical ? CGSize(width: box.across, height: box.along) : CGSize(width: box.along, height: box.across))
    }

    /// 这一刻的样子：在叠着和排开之间按 openness 插值。
    private func slots(path: ArraySlice<String>) -> (CGSize, [Slot]) {
        let open = openSlots(path: path)
        guard openness < 1 else { return open }
        let folded = foldedSlots(path: path)
        guard openness > 0 else { return folded }
        let t = openness
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        let size = CGSize(width: mix(folded.0.width, open.0.width), height: mix(folded.0.height, open.0.height))
        let slots = zip(folded.1, open.1).map { f, o in
            Slot(box: o.box, along: mix(f.along, o.along), scale: mix(f.scale, o.scale), opacity: f.opacity + (o.opacity - f.opacity) * Double(t))
        }
        return (size, slots)
    }

    /// 排开，见 openPlacement。
    private func openSlots(path: ArraySlice<String>) -> (CGSize, [Slot]) {
        let breadth = Self.breadth(entry, path: path)
        let placement = Self.openPlacement(entry, path: path, viewport: viewport)
        let slots = zip(entry.members, placement.members).map { member, place in
            Slot(box: measure(member, path: path).size, along: place.along, opacity: place.opacity)
        }
        let length = placement.length
        return (axis == .vertical ? CGSize(width: breadth, height: length) : CGSize(width: length, height: breadth), slots)
    }

    /// 叠着：家族的各项缩成格子里头像的大小，父代理在最前面，子代理往后每个错开三分之一格、往后渐隐，露不出来的藏在最后一个后面。
    private func foldedSlots(path: ArraySlice<String>) -> (CGSize, [Slot]) {
        let width = Metrics.dragBubble, inset = Self.inset(width), face = width - 2 * inset
        let slots = entry.members.enumerated().map { index, member in
            let box = measure(member, path: path)
            guard case .family = entry else {
                let scale = face / max(box.along, box.across)
                return Slot(box: box.size, along: (width - box.along * scale) / 2, scale: scale)
            }
            let along = inset + CGFloat(min(index, Self.shownChildren)) * width / 3
            let opacity = Self.foldedOpacity(index)
            // 自己也带着子代理的那一项只露胶囊最前面的头像（见 dockFaceDetail），按那个头像对齐
            if index > 0, case .family = member, path.first != member.id {
                let scale = face / (Metrics.dragBubble - 2 * inset)
                return Slot(box: box.size, along: along - inset * scale, scale: scale, opacity: opacity)
            }
            return Slot(box: box.size, along: along, scale: face / box.across, opacity: opacity)
        }
        return (Self.foldedSize(entry, width: width, axis: axis), slots)
    }

    private func parentRow(_ family: DockFamily, fold: Double) -> some View {
        Button { openParent(family) } label: {
            DockEntryFace(subject: .parent(family), familyFold: fold)
                .frame(width: Metrics.dragBubble, height: Metrics.dragBubble)
                .contentShape(Circle())
        }
        .buttonStyle(.pointingPlain)
        .modifier(DockPaneDrag(pane: family.pane))
        .modifier(DockItemHover(id: DockEntry.instance(family.parent).id))
        .accessibilityLabel(area.dockLabel(.instance(family.parent)))
        .contextMenuOutline(Circle())
        .contextMenu {
            Text(area.dockLabel(.instance(family.parent)))
            InstanceActions(instance: family.parent)
        }
    }
}

/// 面板里一项的缩放（锚在开头），逐帧把累计的缩放交给头像（dockFaceScale）：描边、箭头、模糊按画出来的大小算，
/// 叠着时和格子里画的一样粗细，展开途中也不跟着缩放变细。
private struct DockSlotScale: ViewModifier, Animatable {
    var scale: CGFloat
    let anchor: UnitPoint

    var animatableData: CGFloat {
        get { scale }
        set { scale = newValue }
    }

    func body(content: Content) -> some View {
        content
            .transformEnvironment(\.dockFaceScale) { $0 *= scale }
            .scaleEffect(scale, anchor: anchor)
    }
}

/// 展开的家族格看得见的那一段：沿排列方向多长，从开头滚了多远。
struct DockViewport: Equatable {
    var length: CGFloat
    var offset: CGFloat
}

/// 面板滚过开头时，开头那一头渐隐，边的正中有箭头指向它，同 hintsScrollOverflow：只遮里面的各项，胶囊的底色和描边不跟着渐隐。
/// amount 从 0（在开头）到 1（滚过一段渐隐的长）；遮罩四周多让出脉冲那一圈，没滚动时不截掉什么。
private struct DockStartFade: ViewModifier {
    let axis: Axis
    let amount: Double?

    func body(content: Content) -> some View {
        if let amount {
            let vertical = axis == .vertical, margin = Metrics.dragBubble * DockPulse.reach
            content
                .mask {
                    GeometryReader { proxy in
                        let extent = (vertical ? proxy.size.height : proxy.size.width) + 2 * margin
                        let edge = Color.black.opacity(1 - amount)
                        LinearGradient(stops: [
                            .init(color: edge, location: 0),
                            .init(color: edge, location: margin / extent),
                            .init(color: .black, location: min((margin + ScrollOverflowCaret.fade) / extent, 1)),
                            .init(color: .black, location: 1),
                        ], startPoint: vertical ? .top : .trailing, endPoint: vertical ? .bottom : .leading)
                        .padding(-margin)
                    }
                }
                .overlay(alignment: vertical ? .top : .trailing) {
                    ScrollOverflowCaret(edge: vertical ? .top : .trailing)
                        .padding(vertical ? .top : .trailing, ScrollOverflowCaret.inset)
                        .opacity(amount)
                }
        } else {
            content
        }
    }
}

/// 展开的家族格里的各项自己报位置，悬停标签按它浮在左边；里面又展开着的家族不浮，由它里面的各项浮。
/// 位置记在不被观察的盒子里：家族格滚动、展开途中每帧都在变，不因此重算这一项。
private struct DockItemHover: ViewModifier {
    let id: String
    var enabled = true
    @Environment(WorkArea.self) private var area
    @State private var frame = DockFrameBox()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DockSpace.name)) } action: { frame.value = $0 }
            .onHover { area.setDockHover(id, frame: frame.value, hovering: $0 && enabled) }
    }
}

private final class DockFrameBox {
    var value: CGRect = .zero
}

extension EnvironmentValues {
    /// 停靠格排列的方向：宽屏停靠栏竖排，紧凑布局的底栏横排；家族胶囊顺着它拉长。
    @Entry var dockAxis: Axis = .vertical
    /// 紧凑布局的底栏里正显示的窗口，它的头像换成向上的箭头。
    @Entry var dockCurrentPane: Pane?
    /// 头像画出来比排版的大小缩了多少：家族格收着时头像整个缩成格子里的大小，描边、箭头、模糊按画出来的大小算，见 DockFace。
    @Entry var dockFaceScale: CGFloat = 1
    /// 宽屏台面上停着的实例：格子画向左的箭头（看得到），见 StageGeometry.staged。
    @Entry var dockOnStage: Set<String> = []
    /// 卡片自己画着头像的实例：格子先不画，见 StageGeometry.airborne。
    @Entry var dockHidden: Set<String> = []
    /// 宽屏台面：停靠栏的格子拖出去时按它的范围交给排布，见 DockPaneDrag。紧凑布局没有。
    @Entry var dockStage: StageGeometry?
    /// 头像脉冲的透明度：家族格收着时只有父代理发，展开途中其余的跟着淡入。
    @Entry var dockPulseOpacity: Double = 1
    /// 外层家族格展开到哪：收着时里面自己也带着子代理的那一项只露最前面的头像，展开途中其余的和描边淡入。
    @Entry var dockFaceDetail: Double = 1
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

/// 停靠栏的添加入口：和实例一样大的圆，描一圈淡边，没有底色。
struct DockAddFace: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(Theme.title)
            .foregroundStyle(.secondary)
            .frame(width: Metrics.dragBubble, height: Metrics.dragBubble)
            .overlay { Circle().stroke(.secondary.opacity(0.4), lineWidth: 1).padding(0.5) }
            .contentShape(Circle())
    }
}

/// 添加实例：实例组最后一格，点开是新建实例的选择页（见 WorkArea.openChooser），新建的窗口从这里展开。
struct AddWindowButton: View {
    @Environment(WorkArea.self) private var area

    var body: some View {
        Button {
            area.openChooser()
        } label: {
            DockAddFace(symbol: "plus")
        }
        .buttonStyle(.pointingPlain)
        .fixedSize()
        .accessibilityLabel(DockBandItem.addInstanceTitle)
        // 名字同格子一样由停靠栏浮出来
        .modifier(DockHoverReport(id: DockBandItem.addInstance.id))
        .modifier(WindowErrorAlert())
    }
}

/// 紧凑布局底栏里的当前窗口：垫在格子下面的选中底，向外扩出一圈，与格子同心。
struct DockSelection: View {
    var body: some View {
        let outset = Metrics.gap / 3
        Capsule().fill(Theme.selection)
            .padding(-outset)
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

/// 紧凑布局的底栏：停靠栏横排（见 DockBand），列的是停靠栏模型里的全部实例（没有布局组），一次看一个窗口，点了切换，当前窗口垫选中底、画向上的箭头。
struct CompactDockBar: View {
    @Binding var open: WorkspaceDrawer?
    @Environment(WorkArea.self) private var area

    var body: some View {
        let layout = area.layout
        DockBand(axis: .horizontal) { pane in
            layout.focus(pane)
            open = nil
        }
        .environment(\.dockCurrentPane, layout.focused)
        // 压暗时点到底栏两头也收起
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { area.collapseDock() }
                .allowsHitTesting(!area.dockExpansion.isEmpty)
        }
        // 底栏收起来（点了窗口、拉开侧栏）时一起收起，下次拉开是收着的
        .onChange(of: open) { _, open in
            if open != .actions { area.collapseDock() }
        }
        .onChange(of: layout.focused.map(area.dockInstanceID), initial: true) { _, id in
            area.noteVisible(id.map { [$0] } ?? [])
        }
        .onDisappear { area.noteVisible([]) }
    }
}
