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
/// 窗口正看得到时头像模糊、画上指向它的箭头，不显示状态：宽屏台面上的父代理、子代理向左，紧凑布局的当前窗口向上。
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
    @Environment(\.dockOnStage) private var onStage
    @Environment(\.dockPulseOpacity) private var pulseOpacity

    var body: some View {
        let id = instanceID, arrow = self.arrow
        DockFace(look: look, running: area.isRunning(id), tint: area.dockAttention(of: id)?.color, arrow: arrow, ring: ring)
            .overlay { if pulse, pulseOpacity > 0, arrow == nil { DockPulse(instance: id).opacity(pulseOpacity) } }
    }

    private var arrow: String? {
        switch subject {
        case .pane(let pane): pane == current ? "arrow.up" : nil
        // 家族格里开着窗口的子代理
        case .instance(let instance): onStage.contains(instance.id) ? "arrow.left" : current.map(area.dockInstanceID) == instance.id ? "arrow.up" : nil
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

/// 收起时的一格：没有窗口的实例或缩在停靠栏里的窗口（宽屏上最小化的窗口由窗口卡片自己画，不在这里）；家族与「更多」见 DockGroup。
struct DockCell: View {
    let entry: DockEntry
    var mini = false

    var body: some View {
        switch entry {
        case .family, .more: DockGroup(entry: entry, depth: 0, mini: mini)
        case .instance(let instance): DockEntryFace(subject: .instance(instance))
        case .pane(let pane): DockEntryFace(subject: .pane(pane))
        }
    }
}

/// 收着的一格：打开没有窗口的实例；家族里开着窗口的子代理换到它的窗口（showPane）。家族与「更多」交给 DockGroup，点了原地展开。
struct DockCellButton: View {
    let entry: DockEntry
    let depth: Int
    var mini = false
    /// 紧凑布局里没有窗口的实例不缩成小头像，盖一层半透明的底色。
    var veiled = false
    var hoverFrame: CGRect?
    /// 见 DockGroup.drawsParent。
    var drawsParent = true
    /// 家族里点了开着窗口的子代理：同点父代理的窗口，见 DockGroup.showPane。
    var showPane: ((Pane) -> Void)?
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    @Environment(\.dockAxis) private var axis

    var body: some View {
        if entry.expands {
            // 家族胶囊比格子短时贴着父代理那头（小头像里的家族）
            DockGroup(entry: entry, depth: depth, mini: mini, veiled: veiled, drawsParent: drawsParent, hoverFrame: hoverFrame,
                      showPane: showPane ?? { _ in })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: axis == .vertical ? .top : .trailing)
        } else {
            let size = DockGeometry.cellSize(entry, mini: mini, axis: axis), outline = self.outline(size)
            Button(action: activate) {
                DockCell(entry: entry, mini: mini)
                    .frame(width: size.width, height: size.height)
                    .overlay { if veiled { outline.fill(Theme.background.opacity(0.5)) } }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pointingPlain)
            .accessibilityLabel(area.dockLabel(entry))
            .onHover { hovering in
                if let hoverFrame { area.setDockHover(entry.id, frame: hoverFrame, hovering: hovering) }
            }
            .contextMenuOutline(outline)
            .contextMenu { DockEntryMenu(entry: entry) }
        }
    }

    private func outline(_ size: CGSize) -> DockOutline {
        let width = min(size.width, size.height)
        switch entry {
        case .instance(let instance): return .face(agent: area.isAgent(instance), width: width)
        case .pane(let pane): return .face(agent: area.isAgentPane(pane), width: width)
        case .family, .more: return DockOutline()
        }
    }

    private func activate() {
        guard case .instance(let instance) = entry else { return }
        if let showPane, let window = area.window(of: instance.id) { showPane(Pane(window.id)) }
        else { model.openDockInstance(instance, in: area) }
        area.collapseDock()
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

/// 家族格与「更多」：同一个组件的两种样子，openness 从 0（收着）到 1（展开）逐帧插值，每个头像始终是同一个视图，
/// 从叠着的地方挪到排开的地方，胶囊跟着拉长；收起时原路叠回去。
/// 收着：家族是一格宽的长胶囊，父代理在最前面（竖排在上，横排在右），子代理和它一样大，一个压一个往后错开，各露出一截，
/// 最多露三个，再多不再变长；小头像里的按比例缩小。「更多」是省略号那一格，里面的藏在它底下。整格是一个按钮，点了展开。
/// 展开：各项放大到一格的大小，沿排列方向排开，里面的才接点击；里面再展开的家族嵌在描边里，同样原地展开。
/// 宽屏竖排，紧凑布局横排；横排和底栏一样倒着排，第一项在右端。
struct DockGroup: View, Animatable {
    let entry: DockEntry
    let depth: Int
    /// 展开的目标：收着时整格是一个按钮，展开时里面的才接点击。openness 是这一刻画到哪。
    var expanded = false
    var openness: CGFloat = 0
    /// 宽屏停靠栏末尾的小头像。
    var mini = false
    /// 紧凑布局里没有窗口的那一格盖着一层底色，展开时淡掉。
    var veiled = false
    /// 紧凑布局里当前窗口在这一家：垫选中底，展开时淡掉。
    var selected = false
    /// 宽屏上最小化的父代理由窗口卡片画在它的位置（关掉的窗口正飞回来时也是），这里不画。
    var drawsParent = true
    /// 收着时浮出悬停标签的范围，内容区坐标。
    var hoverFrame: CGRect?
    /// 点了家族里开着窗口的代理：宽屏放上台面，紧凑布局切过去。
    var showPane: (Pane) -> Void = { _ in }

    @Environment(AppModel.self) private var model
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

    /// 收着时的大小：家族是胶囊，「更多」是一个圆。
    static func foldedSize(_ entry: DockEntry, width: CGFloat, axis: Axis) -> CGSize {
        guard case .family(let family) = entry else { return CGSize(width: width, height: width) }
        let length = length(family, width: width)
        return axis == .vertical ? CGSize(width: width, height: length) : CGSize(width: length, height: width)
    }

    /// 一项展开后沿排列方向的长和垂直方向的宽：没展开的按格子，展开了的按它自己展开后的大小。
    private static func box(_ member: DockEntry, path: ArraySlice<String>) -> (along: CGFloat, across: CGFloat) {
        if member.expands, path.first == member.id { return (extent(member, path: path.dropFirst()), breadth(member, path: path.dropFirst())) }
        return (DockGeometry.cellSize(member).height, Metrics.dragBubble)
    }

    /// 展开后沿排列方向的长度，宽屏、底栏据此摆放。
    static func extent(_ entry: DockEntry, path: ArraySlice<String>) -> CGFloat {
        let members = entry.members
        var total = 2 * padding + Metrics.gap * CGFloat(max(members.count - 1, 0))
        for member in members {
            if member.expands, path.first == member.id { total += extent(member, path: path.dropFirst()) }
            else { total += DockGeometry.cellSize(member).height }
        }
        return total
    }

    /// 展开后垂直于排列方向的宽度：每嵌一层多两份内边距。
    static func breadth(_ entry: DockEntry, path: ArraySlice<String>) -> CGFloat {
        let nested = entry.members.first { $0.expands && path.first == $0.id }
        return 2 * padding + (nested.map { breadth($0, path: path.dropFirst()) } ?? Metrics.dragBubble)
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
                self.member(member, at: index, unfolded: unfolded)
                    .frame(width: slot.box.width, height: slot.box.height, alignment: alignment)
                    // 收着时同格子：家族里只有父代理发脉冲，自己也带着子代理的只露头像；「更多」里的藏在省略号底下，都不发
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
        // 收着时没有底色，同停靠栏的底；「更多」收着时的描边由省略号那一格画
        .background {
            Capsule().fill(Theme.background).opacity(fill * detail)
            Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1).opacity((isFamily ? 1 : fill) * detail)
        }
        .background { if selected { DockSelection().opacity(1 - fill) } }
        .overlay {
            if case .more(let entries) = entry {
                DockMoreFace(entries: entries)
                    .frame(width: cellWidth, height: cellWidth)
                    .opacity(1 - fill)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if veiled { Capsule().fill(Theme.background.opacity(0.5)).opacity(1 - fill).allowsHitTesting(false) }
        }
        .overlay { if !expanded { foldedButtons } }
        .contextMenuOutline(Capsule())
        .contextMenu { if !expanded { DockEntryMenu(entry: entry) } }
    }

    private var cellWidth: CGFloat { mini ? DockGeometry.miniSize : Metrics.dragBubble }

    /// 收着时：点父代理的头像直接打开它，点其余的地方展开；悬停整格浮出名字。宽屏上最小化的父代理由窗口卡片画在它的位置，
    /// 点卡片同样打开它（见 CardView.click）。
    private var foldedButtons: some View {
        let inset = Self.inset(cellWidth), face = cellWidth - 2 * inset
        return ZStack(alignment: axis == .vertical ? .top : .trailing) {
            Button { area.toggleDock(entry.id, depth: depth) } label: {
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
            }
        }
        .onHover { hovering in
            if let hoverFrame { area.setDockHover(entry.id, frame: hoverFrame, hovering: hovering) }
        }
    }

    /// 打开父代理：有窗口的换到它的窗口，没有的打开它。
    private func openParent(_ family: DockFamily) {
        if let pane = family.pane { showPane(pane) }
        else { model.openDockInstance(family.parent, in: area) }
        area.collapseDock()
    }

    @ViewBuilder
    private func member(_ member: DockEntry, at index: Int, unfolded: Bool) -> some View {
        if index == 0, case .family(let family) = entry {
            parentRow(family).opacity(drawsParent ? 1 : 0)
        } else if member.expands {
            DockGroup(entry: member, depth: depth + 1, expanded: unfolded, openness: unfolded ? 1 : 0, showPane: showPane)
                .modifier(DockItemHover(id: member.id, enabled: !unfolded))
        } else {
            DockCellButton(entry: member, depth: depth + 1, showPane: showPane)
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

    /// 排开：沿排列方向依次排，两头留 padding。
    private func openSlots(path: ArraySlice<String>) -> (CGSize, [Slot]) {
        let extent = Self.extent(entry, path: path), breadth = Self.breadth(entry, path: path)
        var along = Self.padding
        let slots = entry.members.map { member in
            let box = measure(member, path: path)
            defer { along += box.along + Metrics.gap }
            return Slot(box: box.size, along: along)
        }
        return (axis == .vertical ? CGSize(width: breadth, height: extent) : CGSize(width: extent, height: breadth), slots)
    }

    /// 叠着：家族的各项缩成格子里头像的大小，父代理在最前面，子代理往后每个错开三分之一格，露不出来的藏在最后一个后面；
    /// 「更多」里的缩成格子里头像的大小，叠在省略号底下。
    private func foldedSlots(path: ArraySlice<String>) -> (CGSize, [Slot]) {
        let width = cellWidth, inset = Self.inset(width), face = width - 2 * inset
        let fullInset = Self.inset(Metrics.dragBubble)
        let slots = entry.members.enumerated().map { index, member in
            let box = measure(member, path: path)
            guard case .family = entry else {
                let scale = face / max(box.along, box.across)
                return Slot(box: box.size, along: (width - box.along * scale) / 2, scale: scale)
            }
            let along = inset + CGFloat(min(index, Self.shownChildren)) * width / 3
            let opacity: Double = index > Self.shownChildren ? 0 : 1
            // 自己也带着子代理的那一项只露胶囊最前面的头像（见 dockFaceDetail），按那个头像对齐
            if index > 0, case .family = member, path.first != member.id {
                let scale = face / (Metrics.dragBubble - 2 * fullInset)
                return Slot(box: box.size, along: along - fullInset * scale, scale: scale, opacity: opacity)
            }
            return Slot(box: box.size, along: along, scale: face / box.across, opacity: opacity)
        }
        return (Self.foldedSize(entry, width: width, axis: axis), slots)
    }

    private func parentRow(_ family: DockFamily) -> some View {
        Button { openParent(family) } label: {
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

/// 展开的家族格与「更多」里的各项自己报位置，悬停标签按它浮在左边；里面又展开着的家族不浮，由它里面的各项浮。
private struct DockItemHover: ViewModifier {
    let id: String
    var enabled = true
    @Environment(WorkArea.self) private var area
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DockSpace.name)) } action: { frame = $0 }
            .onHover { area.setDockHover(id, frame: frame, hovering: $0 && enabled) }
    }
}

extension EnvironmentValues {
    /// 宽屏上最小化的窗口由卡片画在停靠格里；紧凑布局的底栏没有卡片，自己画。
    @Entry var dockCardsDrawPanes = false
    /// 停靠格排列的方向：宽屏停靠栏竖排，紧凑布局的底栏横排；家族胶囊顺着它拉长。
    @Entry var dockAxis: Axis = .vertical
    /// 紧凑布局的底栏里正显示的窗口，它的头像换成向上的箭头。
    @Entry var dockCurrentPane: Pane?
    /// 宽屏展开的家族格在停靠栏上面那一层展开到哪，见 DockUnfold。
    @Entry var dockPanelOpenness: CGFloat = 1
    /// 头像画出来比排版的大小缩了多少：家族格收着时头像整个缩成格子里的大小，描边、箭头、模糊按画出来的大小算，见 DockFace。
    @Entry var dockFaceScale: CGFloat = 1
    /// 宽屏台面上开着窗口的实例：家族格里的子代理画向左的箭头，见 DockModel.onStage。
    @Entry var dockOnStage: Set<String> = []
    /// 头像脉冲的透明度：家族格收着时只有父代理发，展开途中其余的跟着淡入。
    @Entry var dockPulseOpacity: Double = 1
    /// 外层家族格展开到哪：收着时里面自己也带着子代理的那一项只露最前面的头像，展开途中其余的和描边淡入。
    @Entry var dockFaceDetail: Double = 1
}

/// 宽屏的家族格展开时要压在窗口卡片上面，画在停靠栏上面那一层：那一层另放一个同样的 DockGroup，先按收着的样子摆上
/// （和下面那一格一模一样），再逐帧展开；收起时叠回收着的样子再拿掉。进度逐帧交给它（dockPanelOpenness）。
/// 不用过渡：过渡的修饰里改的环境值传不到里面，一直按展开的样子排，两头之间没有过渡（2026-10-19 探针实测）。
struct DockUnfold<Panel: View>: View {
    let expanded: Bool
    @ViewBuilder let panel: Panel
    @State private var mounted = false
    @State private var openness: CGFloat = 0

    var body: some View {
        ZStack {
            if mounted { DockOpenness(openness: openness) { panel } }
        }
        .onChange(of: expanded, initial: true) { _, expanded in
            if expanded {
                // 先按收着的样子摆上，不带外面的动画
                if !mounted { withTransaction(Transaction(animation: nil)) { mounted = true } }
                withAnimation(.snappy) { openness = 1 }
            } else if mounted {
                withAnimation(.snappy, completionCriteria: .removed) { openness = 0 } completion: {
                    if openness == 0 { mounted = false }
                }
            }
        }
    }
}

/// 逐帧把展开进度交给里面。
private struct DockOpenness<Content: View>: View, Animatable {
    var openness: CGFloat
    @ViewBuilder let content: Content

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    var body: some View {
        content.environment(\.dockPanelOpenness, openness)
    }
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
    /// 圆角；nil 是代理头像的圆和「更多」的圆。
    var cornerRadius: CGFloat?

    /// 一个头像：代理是圆，工具的圆角随格子大小缩放，同 DockFace。
    @MainActor static func face(agent: Bool, width: CGFloat = Metrics.dragBubble) -> Self {
        Self(cornerRadius: agent ? nil : Metrics.dockRadius * width / Metrics.dragBubble)
    }

    func path(in rect: CGRect) -> Path {
        if let cornerRadius { return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect) }
        return Capsule().path(in: rect)
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
/// 展开时不滚动：右端不动，家族格往左长，比底栏宽时左边超出的手动滑过去看。展开途中家族格每帧都让底栏重排，iPhone 的滚动区
/// 每次重排都把位置拉回右端，和滚动的动画轮流生效，整串来回抖（2026-10-19 真机记录）。
///
/// 滚动区只借它的手势、惯性和滚动范围：里面是一条和照原来间距排开一样长的空轨道，头像钉在可视区里，由 DockStackLayout
/// 按离右端滚了多远来摆，加减格子时由排版的动画过渡，家族格展开、收起时按它这一刻的长让位（见 DockStackExtent）。头像若直接排在滚动内容里、用 visualEffect 挪成堆叠，
/// 内容变长时右端锚定会让滚动偏移跟着动画，visualEffect 拿到的却是格子的终点，两者对不上，堆叠会先散开再收回。
struct CompactDockBar: View {
    @Binding var open: WorkspaceDrawer?
    @Environment(AppModel.self) private var model
    @Environment(WorkArea.self) private var area
    /// 滚动区的宽，含四周让出的一圈。
    @State private var width: CGFloat = 0
    @State private var scroll = DockScroll()
    @State private var position = ScrollPosition()
    /// 刚加进底栏的窗口：切过去时把它滚到最右，见 reveal。
    @State private var fresh: Set<Pane> = []

    /// 头像的脉冲和选中底伸出格子，滚动区向四周多让出这一圈，免得被截掉；排版仍按格子算。
    private var margin: CGFloat { Metrics.dragBubble * DockPulse.reach }
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
        let current = items.firstIndex { if case .entry(let entry, _) = $0 { holdsCurrent(entry) } else { false } }
        // 照原来的间距排开时每一项的长、离最左一项多远，整串多长
        let extents = items.map(extent)
        let positions = extents.indices.map { extents[..<$0].reduce(0, +) + Metrics.gap * CGFloat($0) }
        let total = (positions.last ?? 0) + (extents.last ?? 0)
        // 轨道两头含让出的一圈，不用 contentMargins：有内边距时滚动区坐标的原点不在边上，钉住会偏一圈
        let track = max(total, region) + 2 * margin, height = Metrics.dragBubble + 2 * margin
        let divider = items.firstIndex { $0.id == DockStackItem.divider.id }.map { positions[$0] } ?? 0
        HStack(spacing: Metrics.gap) {
            ScrollView(.horizontal, showsIndicators: false) {
                Color.clear
                    .frame(width: track, height: height)
                    // 展开着时点底栏里别的地方收起：别的格子压暗了不接点击，点到的是这条轨道
                    .contentShape(Rectangle())
                    .onTapGesture { area.collapseDock() }
                    .allowsHitTesting(dimmed)
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
                                        DockStackDivider(scroll: scroll, position: divider, total: total, region: region, stacking: dimmed ? 0 : 1)
                                            .modifier(DockDimmed(dimmed: dimmed))
                                            .transition(.opacity)
                                    }
                                }
                                .layoutValue(key: DockStackPosition.self, value: position)
                                .layoutValue(key: DockStackExtent.self, value: flexibleExtent(item))
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
            .scrollPosition($position)
            .onScrollGeometryChange(for: DockScrollGeometry.self) { geometry in
                DockScrollGeometry(content: geometry.contentSize.width, offset: geometry.contentOffset.x, visible: geometry.visibleRect.width)
            } action: { old, new in
                guard new.content != old.content else {
                    withTransaction(Transaction(animation: nil)) { scroll.distance = new.distance }
                    return
                }
                // 轨道变长变短（展开、收起、增减格子）：不在右端时滚动区留着离左端的位置，离右端的距离跟着变，整串会跳。
                // 当场滚回离右端同样远的地方，右端不动；滚不到那么远时（收起后排得下了，展开时为露出左边滚过的那一点要退回去），
                // 排版的距离跟着收起、展开的动画挪过去，不当场跳（2026-10-19 iPhone 逐帧截图：收起第一帧整串往左跳 7.5 点）
                let target = min(max(new.content - new.visible - old.distance, 0), max(new.content - new.visible, 0))
                if abs(target - new.offset) > 0.5 { withTransaction(Transaction(animation: nil)) { position.scrollTo(x: target) } }
                let distance = new.content - target - new.visible
                if abs(distance - scroll.distance) > 0.5 { withAnimation(.snappy) { scroll.distance = distance } }
            }
            .hintsScrollOverflow(.horizontal, carets: .endOnly, caretsDimmed: dimmed)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // 新窗口加进来和切过去可能不在同一次更新里，先记下，切过去时再滚
            .onChange(of: layout.panes) { old, new in
                // 累加：新窗口加进来、切过去之前别的窗口又有增减，也还记着它
                fresh = fresh.union(Set(new).subtracting(old)).intersection(new)
                reveal()
            }
            .onChange(of: layout.focused) {
                reveal()
                fresh = []
            }
            .padding(-margin)
            AddWindowButton(concentric: false)
                .modifier(DockDimmed(dimmed: dimmed))
        }
        // 压暗的加号不接点击，点到它那里也收起
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { area.collapseDock() }
                .allowsHitTesting(dimmed)
        }
        // 底栏收起来（点了窗口、拉开侧栏）时一起收起，下次拉开是收着的
        .onChange(of: open) { _, open in
            if open != .actions { area.collapseDock() }
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
        if entry.expands, area.dockExpansion.first == entry.id { return DockGroup.extent(entry, path: area.dockExpansion.dropFirst()) }
        return DockGeometry.cellSize(entry, axis: .horizontal).width
    }

    /// 家族格展开、收起时这一刻多长由它自己逐帧排，排版要量（见 DockStackExtent）；别的格子不量。
    private func flexibleExtent(_ item: DockStackItem) -> CGFloat? {
        guard case .entry(let entry, _) = item, entry.expands else { return nil }
        return extent(item)
    }

    private func item(_ entry: DockEntry, dimmed: Bool, veiled: Bool) -> some View {
        let expanded = area.dockExpansion.first == entry.id
        // 包一层容器：进出底栏的过渡只管整格，不落到里面展开、收起的切换上
        return ZStack {
            if case .pane(let pane) = entry {
                paneButton(pane)
            } else if entry.expands {
                // 原地展开：收着和展开是同一个家族格，头像从叠着的地方排开
                DockGroup(entry: entry, depth: 0, expanded: expanded, openness: expanded ? 1 : 0, veiled: veiled,
                          selected: holdsCurrent(entry), showPane: show)
            } else {
                DockCellButton(entry: entry, depth: 0, veiled: veiled)
            }
        }
        .modifier(DockDimmed(dimmed: dimmed && !expanded))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// 新加的窗口切过去时（新建的窗口会自动切过去），把它滚到头像那一段的最右；离左端太近滚不到最右时停在左端，
    /// 全部照原来的间距排开，它也就尽量靠右了。
    private func reveal() {
        guard let focused = area.layout.focused, fresh.contains(focused) else { return }
        fresh = []
        withAnimation(.snappy) { position.scrollTo(id: Self.current, anchor: .trailing) }
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

    /// 当前窗口在这一格：它自己，或家族格里的父代理、子代理；家族格也垫选中底。
    private func holdsCurrent(_ entry: DockEntry) -> Bool {
        guard let focused = area.layout.focused else { return false }
        if window(of: entry) == focused { return true }
        return isFamily(entry) && entry.contains(instance: area.dockInstanceID(focused))
    }

    private func isFamily(_ entry: DockEntry) -> Bool {
        if case .family = entry { true } else { false }
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

/// 滚动区这一刻的几何：内容多长、滚到哪、看得见多宽。
private nonisolated struct DockScrollGeometry: Equatable {
    var content: CGFloat
    var offset: CGFloat
    var visible: CGFloat
    /// 离右端滚了多远。
    var distance: CGFloat { content - offset - visible }
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
    /// 挤到什么程度：0 照原来的间距排开（展开时），1 照上面的曲线挤；展开、收起途中按它在两种摆法之间插值。
    let stacking: CGFloat

    init(total: CGFloat, region: CGFloat, distance: CGFloat, stacking: CGFloat) {
        hidden = total - region - distance
        zone = region * Self.squeeze
        self.stacking = stacking
    }

    func callAsFunction(_ c: CGFloat) -> CGFloat {
        let spread = c - hidden
        guard stacking > 0, hidden > 0, zone > 0, spread < zone else { return spread }
        let span = hidden + zone
        return spread + (zone * pow(max(c, 0) / span, span / zone) - spread) * stacking
    }
}

/// 按离右端滚了多远摆一串格子：滚动时只有这里重算。
private struct DockStackView<Content: View>: View {
    let scroll: DockScroll
    let stacking: Bool
    let total: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        DockStackLayout(distance: scroll.distance, stacking: stacking ? 1 : 0, total: total) { content }
    }
}

/// 一格照原来的间距排开时离最左一项多远，body 按格子算好交给排版（DockStackPosition）。
private nonisolated struct DockStackPosition: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// 家族格照原来的间距排开时多长（body 按展开、收起的终点算）。它展开、收起时自己逐帧变长变短，排版量它这一刻实际多长，
/// 和终点差多少，它左边的就跟着挪多少：家族格和两边的格子一起动，不靠排版另走一段动画去对上它。
private nonisolated struct DockStackExtent: LayoutValueKey {
    static let defaultValue: CGFloat? = nil
}

/// 从左往右排一串格子，位置按 DockStackCurve，靠右的压在上面。位置是排版算出来的，变化时由排版的动画过渡。
/// 每格离最左多远、整串多长都用 body 算好的，和轨道、分隔线、替身同一套，滚动时不再逐格量：正在淡出的格子还在
/// subviews 里，但不占位置（留在原来那格淡出），别的格子当场带着动画让位，淡出完不会再跳一下。只有家族格量这一刻的长（见 DockStackExtent）。
/// 挤不挤（stacking）和离右端多远（distance）由排版自己逐帧插值：展开、收起时家族格每帧都让底栏重排一次，这些重排不带动画，
/// 交给排版的动画的话第一帧就到终点，左边的一下挤过去或散开、整串一下挪过去。滚动时 distance 不带动画，照滚到的位置摆。
private struct DockStackLayout: Layout {
    var distance: CGFloat
    var stacking: CGFloat
    var total: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(stacking, distance) }
        set { (stacking, distance) = (newValue.first, newValue.second) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = subviews.map { subview in subview[DockStackExtent.self].map { _ in subview.sizeThatFits(.unspecified).width } }
        let deltas = zip(subviews, widths).map { subview, width in width.map { $0 - subview[DockStackExtent.self]! } ?? 0 }
        let curve = DockStackCurve(total: total + deltas.reduce(0, +), region: bounds.width, distance: distance, stacking: stacking)
        var shift: CGFloat = 0
        for ((subview, delta), width) in zip(zip(subviews, deltas), widths) {
            let start = subview[DockStackPosition.self] + shift
            // 正在展开、收起的家族格按右边缘摆：它往左长进挤起来的那一段时，左边缘不跟着被挤、把整格推向右边（右边缘先往右抽一下再回来）
            let x = abs(delta) > 0.5 ? width.map { curve(start + $0) - $0 } ?? curve(start) : curve(start)
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.midY), anchor: .leading, proposal: .unspecified)
            shift += delta
        }
    }
}

/// 工具和代理之间的分隔线：跟着格子堆叠，挤到和两边的格子没有间距时淡出。左边挨着的工具一格宽。
private struct DockStackDivider: View, Animatable {
    let scroll: DockScroll
    /// 照原来的间距排开时离最左一项多远，整串多长。
    let position: CGFloat
    let total: CGFloat
    let region: CGFloat
    /// 同 DockStackLayout.stacking。
    var stacking: CGFloat

    var animatableData: CGFloat {
        get { stacking }
        set { stacking = newValue }
    }

    var body: some View {
        let gap = Metrics.gap, cell = Metrics.dragBubble
        let curve = DockStackCurve(total: total, region: region, distance: scroll.distance, stacking: stacking)
        let spacing = min(curve(position) - curve(position - gap - cell) - cell, curve(position + 1 + gap) - curve(position) - 1)
        Rectangle().fill(Theme.rule)
            .frame(width: 1, height: Metrics.dragBubble * 0.6)
            .opacity(min(max(spacing / (gap / 3), 0), 1))
    }
}
