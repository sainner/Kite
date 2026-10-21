import SwiftUI

/// 停靠栏里的一格。添加入口不在这里，固定排第一个。
indirect enum DockEntry: Identifiable {
    /// 本机最小化的窗口；紧凑布局里是底栏上的每个窗口，含当前窗口。
    case pane(Pane)
    /// 父代理和它没有窗口的子代理合成一格。
    case family(DockFamily)
    /// 小头像排不下的，占最后一个小头像的位置。
    case more([DockEntry])
    /// 没有窗口的实例。
    case instance(RemotePluginInstance)

    var id: String {
        switch self {
        case .pane(let pane): "pane:\(pane.id)"
        case .family(let family): Self.familyID(family.parent.id)
        case .more: Self.moreID
        case .instance(let instance): "instance:\(instance.id)"
        }
    }

    static let moreID = "more"
    static func familyID(_ instance: String) -> String { "family:\(instance)" }

    /// 展开后看到的各项：「更多」是放不下的小头像，家族是父代理和子代理。
    var members: [DockEntry] {
        switch self {
        case .more(let entries): entries
        case .family(let family): [.instance(family.parent)] + family.children
        default: []
        }
    }

    /// 这一格代表的实例：实例本身，或家族的父代理。
    var leadInstance: RemotePluginInstance? {
        switch self {
        case .instance(let instance): instance
        case .family(let family): family.parent
        default: nil
        }
    }

    var expands: Bool {
        switch self {
        case .more, .family: true
        default: false
        }
    }

    /// 这一格里有没有这个实例：它自己，或装着它的「更多」、家族格。
    func contains(instance: String) -> Bool {
        switch self {
        case .instance(let value): value.id == instance
        case .family(let family): family.parent.id == instance || family.children.contains { $0.contains(instance: instance) }
        case .more(let entries): entries.contains { $0.contains(instance: instance) }
        case .pane: false
        }
    }

    /// 这一格里的实例，家族连同各层子代理。
    var instanceIDs: [String] {
        switch self {
        case .instance(let value): [value.id]
        case .family(let family): [family.parent.id] + family.children.flatMap(\.instanceIDs)
        case .more(let entries): entries.flatMap(\.instanceIDs)
        case .pane: []
        }
    }
}

/// 子代理挂在父代理下面显示，随父代理归档：开没开窗口都在父代理这一格里，不另占一格。
struct DockFamily {
    let parent: RemotePluginInstance
    /// 父代理在本机的窗口；没有窗口时整家占一个小头像。
    let pane: Pane?
    /// 父代理的窗口在台面上，格子里以箭头代替头像。
    let onStage: Bool
    /// 子代理：.instance，或自己也带着子代理的 .family。窗口在台面上的画箭头，收着的窗口藏在自己的头像后面（见 DockGeometry.tucked）。
    let children: [DockEntry]
}

/// 代理组在上，有子代理的优先；工具组在下；没有窗口的代理和工具排成小头像，在最后。
struct DockModel {
    /// 小头像最多两格，每格两行两列；再多时最后一个位置换成「更多」。
    static let miniLimit = 8

    var agents: [DockEntry] = []
    var tools: [DockEntry] = []
    /// 没有窗口的代理和工具，按创建先后排，状态变化不挪位置。紧凑布局的底栏直接排它们，不收进「更多」。
    var windowless: [DockEntry] = []
    /// 宽屏把 windowless 排成小头像，小头像就表示没有窗口。
    var minis: [DockMini] = []
    /// 窗口在台面上的实例：家族格里的子代理画向左的箭头。
    var onStage: Set<String> = []
    /// 挂在父代理下面的子代理（各层都算），开着窗口的也算。
    var grouped: Set<String> = []
    var all: [DockEntry] { agents + tools + minis.map(\.entry) }
    /// 宽屏停靠栏从上到下的各格，⌘数字按它数：代理组、工具组，再是贴着底边的小头像。小头像上面的一格在前，格里上面一行在前，
    /// 行内从左到右；家族占一列上下两个位置，算在上面一行。
    var topToBottom: [DockEntry] {
        func top(_ mini: DockMini) -> Int {
            if case .family = mini.entry { return 1 }
            return mini.row
        }
        return agents + tools + minis.sorted { ($1.cell, top($1), $0.column) < ($0.cell, top($0), $1.column) }.map(\.entry)
    }
    /// 小头像占的格数。
    var miniCells: Int { minis.map { $0.cell + 1 }.max() ?? 0 }

    /// 按先后放进两格的八个位置，每个放进第一个空着的位置；家族要同一列上下两个位置都空着。
    /// 全放得下就都排开，放不下时最后一个位置换成「更多」，从第一个放不下的起都收进去。
    static func pack(_ entries: [DockEntry]) -> [DockMini] {
        func place(in slots: Int) -> (placed: [DockMini], rest: [DockEntry]) {
            var used = Set<Int>(), placed: [DockMini] = []
            for (index, entry) in entries.enumerated() {
                let tall = if case .family = entry { true } else { false }
                let free = { (slot: Int) in !used.contains(slot) && (!tall || slot % 4 < 2 && slot + 2 < slots && !used.contains(slot + 2)) }
                guard let slot = (0..<slots).first(where: free) else { return (placed, Array(entries[index...])) }
                used.formUnion(tall ? [slot, slot + 2] : [slot])
                placed.append(DockMini(entry: entry, slot: slot))
            }
            return (placed, [])
        }
        let all = place(in: miniLimit)
        guard !all.rest.isEmpty else { return all.placed }
        let some = place(in: miniLimit - 1)
        return some.placed + [DockMini(entry: .more(some.rest), slot: miniLimit - 1)]
    }
}

/// 一个小头像的位置。slot 是两格八个位置里的序号：每格先排挨着末端的一行，行内从左到右；
/// 家族占 slot 所在那一列的两个位置。
struct DockMini: Identifiable {
    let entry: DockEntry
    let slot: Int
    var id: String { entry.id }
    /// 在第几格。
    var cell: Int { slot / 4 }
    /// 格里的第几行，0 是挨着末端的那一行。
    var row: Int { slot % 4 / 2 }
    /// 行内从左数第几个。
    var column: Int { slot % 2 }
}

/// 需要处理的状态，换掉头像本色；同时只显示一个，按这个顺序取。
enum DockAttention: Int, Comparable {
    case unseen, waiting, failed

    var color: Color {
        switch self {
        case .failed: Theme.danger
        case .waiting: Theme.warning
        case .unseen: Theme.unseen
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

extension WorkArea {
    /// 新建窗口关掉、交给了后台实例的，按那个实例算（关闭的卡片飞进它那一格，见 handedOff）。
    func instance(of pane: Pane) -> RemotePluginInstance? {
        let id = windows.first(where: { $0.id == pane.id })?.target.instanceId ?? handedOff[pane.id]
        return id.flatMap { id in instances.first { $0.id == id } }
    }

    func isAgent(_ instance: RemotePluginInstance) -> Bool { definition(of: instance)?.agent != nil }

    func isAgentPane(_ pane: Pane) -> Bool {
        pane.id == draftWindow || instance(of: pane).map(isAgent) == true
    }

    /// docked 是停靠栏里按顺序放的窗口，onStage 是台面上的窗口（只用来找带着子代理的父代理）。
    /// windowless 是按没有窗口来排的实例：正要关窗口的那个，用来算卡片飞回哪一格。
    func dockModel(docked: [Pane], onStage: Set<Pane>, windowless: String? = nil) -> DockModel {
        let open = instances.filter { $0.status == .open }
        let byID = Dictionary(open.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var paneOf: [String: Pane] = [:]
        for window in windows where window.target.instanceId != windowless && paneOf[window.target.instanceId] == nil {
            paneOf[window.target.instanceId] = Pane(window.id)
        }
        // 子代理挂在开着的父代理下面，开没开窗口都一样。
        func parent(of instance: RemotePluginInstance) -> RemotePluginInstance? {
            guard isAgent(instance) else { return nil }
            return instance.origin.flatMap { byID[$0.instanceId] }.flatMap { isAgent($0) ? $0 : nil }
        }
        let childAgents = open.filter { parent(of: $0) != nil }
        let childrenOf = Dictionary(grouping: childAgents) { parent(of: $0)!.id }
        // 没有窗口的都排成小头像：子代理挂在父代理下面，其余各占一个
        let loose = open.filter { paneOf[$0.id] == nil && parent(of: $0) == nil }
        func recent(_ instance: RemotePluginInstance) -> Double {
            activities[instance.id]?.changedAt ?? Double(instance.createdAt)
        }
        func ordered(_ entries: [DockEntry]) -> [DockEntry] {
            entries.enumerated().sorted { left, right in
                let (a, b) = (left.element, right.element)
                if case .family = a, case .instance = b { return true }
                if case .instance = a, case .family = b { return false }
                return left.offset < right.offset
            }.map(\.element)
        }
        func children(of id: String) -> [DockEntry] {
            ordered((childrenOf[id] ?? []).sorted { recent($0) > recent($1) }.map(entry))
        }
        func entry(_ instance: RemotePluginInstance) -> DockEntry {
            let kids = children(of: instance.id)
            guard !kids.isEmpty else { return .instance(instance) }
            let pane = paneOf[instance.id]
            return .family(.init(parent: instance, pane: pane, onStage: pane.map(onStage.contains) ?? false, children: kids))
        }

        var model = DockModel()
        var families: [DockEntry] = []
        var agentPanes: [DockEntry] = []
        for pane in panes(in: onStage) {
            guard let instance = instance(of: pane), isAgent(instance), parent(of: instance) == nil else { continue }
            if case .family = entry(instance) { families.append(entry(instance)) }
        }
        for pane in docked where dockInstanceID(pane) != windowless {
            if isAgentPane(pane) {
                if let instance = instance(of: pane) {
                    // 子代理的窗口收在父代理那一格里
                    if parent(of: instance) != nil { continue }
                    if case .family = entry(instance) { families.append(entry(instance)); continue }
                }
                agentPanes.append(.pane(pane))
            } else {
                model.tools.append(.pane(pane))
            }
        }
        model.agents = families + agentPanes
        model.windowless = loose.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }.map(entry)
        model.minis = DockModel.pack(model.windowless)
        model.onStage = Set(panes(in: onStage).map(dockInstanceID))
        model.grouped = Set(childAgents.map(\.id))
        return model
    }

    /// 代理开出、还开着的各层子代理，归档时一起归档，和工作机的规则一样（见 kited 的 Kite.subagents）；不是代理的没有。
    func subagents(of instance: RemotePluginInstance) -> [RemotePluginInstance] {
        guard isAgent(instance) else { return [] }
        return instances.filter { $0.status == .open && $0.origin?.instanceId == instance.id && isAgent($0) }.flatMap { [$0] + subagents(of: $0) }
    }

    /// 父代理关窗口时一起关的：各层子代理开着、但没在眼前的窗口（宽屏收在停靠栏里，紧凑布局不是当前窗口）。
    /// 台面上的留着，其余的随父代理收进它那一格。
    func descendantPanesClosing(with pane: Pane) -> [Pane] {
        guard let instance = instance(of: pane) else { return [] }
        let visible = layout.presentation == .tiled ? Set(layout.shown?.panes ?? []) : Set([layout.focused].compactMap(\.self))
        return subagents(of: instance).compactMap { window(of: $0.id).map { Pane($0.id) } }.filter { !visible.contains($0) }
    }

    /// 按窗口集合的顺序取出台面上的窗口，结果稳定。
    private func panes(in set: Set<Pane>) -> [Pane] {
        set.isEmpty ? [] : windows.map { Pane($0.id) }.filter(set.contains)
    }

    func attention(of id: String) -> DockAttention? {
        guard let activity = activities[id] else { return nil }
        if activity.outcome == "failed" || activity.error == true { return .failed }
        if activity.waiting != nil || activity.waitingForResume { return .waiting }
        return unseen(id) ? .unseen : nil
    }

    /// 挂在开着的父代理下面的子代理。
    func isSubagent(_ id: String) -> Bool {
        guard let instance = instances.first(where: { $0.id == id }), isAgent(instance), let origin = instance.origin,
              let parent = instances.first(where: { $0.id == origin.instanceId }) else { return false }
        return parent.status == .open && isAgent(parent)
    }

    /// 「更多」与家族里最要紧的一项。
    func attention(in entries: [DockEntry]) -> DockAttention? {
        var top: DockAttention?
        func visit(_ entry: DockEntry) {
            switch entry {
            case .instance(let instance):
                if let value = attention(of: instance.id) { top = max(top ?? value, value) }
            case .family(let family):
                visit(.instance(family.parent))
                family.children.forEach(visit)
            case .more(let entries):
                entries.forEach(visit)
            case .pane:
                break
            }
        }
        entries.forEach(visit)
        return top
    }

    func isRunning(_ id: String) -> Bool {
        guard let phase = activities[id]?.phase else { return false }
        return phase != "idle"
    }

    /// 悬停标签与长按菜单里的说明。
    func statusText(of id: String) -> String {
        guard let activity = activities[id] else { return "空闲" }
        return WorkThread.turnStatus(phase: activity.phase, outcome: activity.error == true ? "failed" : activity.outcome,
                                     waitingForResume: activity.waitingForResume, unseen: unseen(id), waiting: activity.waiting)
    }

    func dockLabel(_ entry: DockEntry) -> String {
        switch entry {
        case .pane(let pane):
            let name = appearance(of: pane).name
            guard let instance = instance(of: pane), isAgent(instance) else { return name }
            return name + " · " + statusText(of: instance.id)
        case .family(let family):
            return family.parent.title + " · \(family.children.count) 个子代理"
        case .more(let entries):
            return "还有 \(entries.count) 项没有窗口"
        case .instance(let instance):
            guard isAgent(instance) else {
                return instance.title + ((definition(of: instance)?.views.isEmpty ?? true) ? " · 后台" : " · 没有窗口")
            }
            return instance.title + " · " + statusText(of: instance.id)
        }
    }

    /// 停靠栏上悬停的那一格的标签；家族格里的父代理是窗口卡片报上来的，按窗口找。
    func dockHoverTip(in geometry: DockGeometry) -> DockHoverTip? {
        guard let hover = dockHover else { return nil }
        let entry: DockEntry
        if let found = DockModel(agents: geometry.allCells.map(\.entry)).entry(hover.id) {
            entry = found
        } else if hover.id.hasPrefix("pane:") {
            entry = .pane(Pane(String(hover.id.dropFirst("pane:".count))))
        } else {
            return nil
        }
        return DockHoverTip(text: dockLabel(entry), frame: hover.frame)
    }
}

extension AppModel {
    /// 打开没有窗口的实例：有视图开它该先显示的视图（见 WorkArea.openingView），没有视图打开实例设置。
    func openDockInstance(_ instance: RemotePluginInstance, in area: WorkArea) {
        guard let view = area.openingView(of: instance) else {
            area.settingsInstance = instance
            return
        }
        openWindow(.open(.init(instanceId: instance.id, viewId: view)), in: area)
    }

    /// ⌘数字：点宽屏停靠栏从上到下第 index 格（从 0 数），同用指针点：收着的窗口放上台面，没有窗口的打开窗口，
    /// 家族格打开父代理，「更多」原地展开。拖动、拖缝当中不做。
    func openDockEntry(at index: Int, in area: WorkArea) {
        let layout = area.layout
        guard area.pluginClient != nil, layout.presentation == .tiled, layout.drag == nil, layout.resizing == nil else { return }
        let entries = area.dockModel(docked: layout.shownDock, onStage: Set(layout.shown?.panes ?? [])).topToBottom
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        switch entry {
        case .more:
            area.toggleDock(entry.id, depth: 0)
            return
        case .pane(let pane):
            layout.activate(pane)
        case .family(let family):
            if let pane = family.pane { layout.activate(pane) } else { openDockInstance(family.parent, in: area) }
        case .instance(let instance):
            openDockInstance(instance, in: area)
        }
        area.collapseDock()
    }

    /// 代理头像用实例记下的角色签名；角色列表还没读到或角色没有签名时用默认图案。
    func emblem(for instance: String, in area: WorkArea) -> EmblemDesign? {
        let role: String?
        if instance == area.draftThread.id { role = newThreadRole(for: area.draftThread, in: area)?.id }
        else { role = area.instances.first { $0.id == instance }?.config?.role?.id }
        return roles(in: area)?.roles.first { $0.id == role }?.emblem?.design
    }
}

/// 宽屏停靠栏每一格的位置：添加入口固定在最上面，然后是代理组、分隔线、工具组，没有窗口的代理排成小头像贴着底边。
/// 坐标与内容区相同。
struct DockGeometry {
    /// 两组之间多出的一个模块，分隔线画在两组正中。
    static var dividerExtra: CGFloat { Metrics.gap }
    /// 小头像两行两列正好占一格。
    static var miniGap: CGFloat { Metrics.dragBubble * 4 / 36 }
    static var miniSize: CGFloat { (Metrics.dragBubble - miniGap) / 2 }

    let add: CGRect
    private(set) var cells: [(entry: DockEntry, frame: CGRect)] = []
    private(set) var minis: [(entry: DockEntry, frame: CGRect)] = []
    private(set) var divider: CGFloat?
    /// 家族格里各个代理的头像画在哪（实例 ID 到位置）：父代理在胶囊最前面，子代理各在露出来的那一截，露不出来的藏在最后一个后面，
    /// 孙辈跟着它所在的子代理。窗口缩小、关掉时落到这里。「更多」里的不算。
    private(set) var faces: [String: CGRect] = [:]
    let onStage: Set<String>
    let grouped: Set<String>
    var allCells: [(entry: DockEntry, frame: CGRect)] { cells + minis }

    init(model: DockModel, regions: WindowRegions) {
        onStage = model.onStage
        grouped = model.grouped
        let size = Metrics.dragBubble, step = size + Metrics.gap
        let x = regions.dock.midX - size / 2
        var y = regions.dock.minY
        add = CGRect(x: x, y: y, width: size, height: size)
        y += step
        for (index, entry) in (model.agents + model.tools).enumerated() {
            // 工具组的第一格前面有代理时，先空出分隔线
            if index == model.agents.count && index > 0 {
                divider = y - Metrics.gap / 2 + Self.dividerExtra / 2
                y += Self.dividerExtra
            }
            let height = Self.cellSize(entry).height
            cells.append((entry, CGRect(x: x, y: y, width: size, height: height)))
            y += height + Metrics.gap
        }
        // 小头像从底边往上排，每格先排下面一行，行内从左到右；高度不够时紧跟在前面的格子后面，不叠上去
        let count = model.miniCells, mini = Self.miniSize, gap = Self.miniGap
        let top = max(y, regions.dock.maxY - CGFloat(count) * step + Metrics.gap)
        for item in model.minis {
            let bottom = top + CGFloat(count - item.cell) * step - Metrics.gap
            let height = Self.cellSize(item.entry, mini: true).height
            minis.append((item.entry, CGRect(x: x + CGFloat(item.column) * (mini + gap), y: bottom - height - CGFloat(item.row) * (mini + gap),
                                             width: mini, height: height)))
        }
        for (entry, frame) in allCells {
            guard case .family(let family) = entry else { continue }
            faces[family.parent.id] = Self.faceFrame(in: frame, at: 0)
            for (index, child) in family.children.enumerated() {
                let face = Self.faceFrame(in: frame, at: min(index + 1, DockGroup.shownChildren))
                for id in child.instanceIDs { faces[id] = face }
            }
        }
    }

    /// 一格的大小：家族沿排列方向更长，小头像里的家族占一列两个位置。
    static func cellSize(_ entry: DockEntry, mini: Bool = false, axis: Axis = .vertical) -> CGSize {
        let width = mini ? miniSize : Metrics.dragBubble
        var length = width
        if case .family(let family) = entry { length = mini ? Metrics.dragBubble : DockGroup.length(family, width: width) }
        return axis == .vertical ? CGSize(width: width, height: length) : CGSize(width: length, height: width)
    }

    /// 从添加入口到最后一格的总长，窗口最小高度据此算。
    static func length(of model: DockModel) -> CGFloat {
        let lengths = [Metrics.dragBubble] + (model.agents + model.tools).map { cellSize($0).height }
            + Array(repeating: Metrics.dragBubble, count: model.miniCells)
        let divider = model.agents.isEmpty || model.tools.isEmpty ? 0 : dividerExtra
        return lengths.reduce(0, +) + CGFloat(lengths.count - 1) * Metrics.gap + divider
    }

    /// 某个没有窗口的实例落在哪一格：它自己，或装着它的「更多」、家族格。
    func frame(containing instance: String) -> CGRect? {
        allCells.first { $0.entry.contains(instance: instance) }?.frame
    }

    /// 实例的头像画在哪：家族格里的按它在胶囊里的位置（见 faces），其余的按装着它的那一格。
    func face(of instance: String) -> CGRect? {
        faces[instance] ?? frame(containing: instance)
    }

    /// 窗口缩小后画在哪：普通窗口占满一格，家族格里的父代理在胶囊最上面。
    func paneFrame(_ pane: Pane) -> CGRect? {
        for (entry, frame) in cells {
            switch entry {
            case .pane(let value) where value == pane: return frame
            case .family(let family) where family.pane == pane && !family.onStage: return Self.parentFrame(in: frame)
            default: continue
            }
        }
        return nil
    }

    /// 悬停标签对着的范围：小头像的从停靠栏左边浮出，不盖住左列的小头像。
    func hoverFrame(of cell: CGRect, mini: Bool) -> CGRect {
        mini ? CGRect(x: add.minX, y: cell.minY, width: cell.maxX - add.minX, height: cell.height) : cell
    }

    /// 展开的家族格、「更多」从格子原地拉长成的面板：先往下，放不下再往上，最高到停靠栏全高，再多就在里面滚动；
    /// 小头像展开后也居中在停靠栏上。extent 是里面排开时的长，比面板高时要滚动。
    static func panel(_ entry: DockEntry, from cell: CGRect, path: ArraySlice<String>, regions: WindowRegions) -> (frame: CGRect, extent: CGFloat) {
        let extent = DockGroup.extent(entry, path: path), breadth = DockGroup.breadth(entry, path: path)
        let height = min(extent, regions.dock.height)
        let top = max(min(cell.minY - DockGroup.padding, regions.dock.maxY - height), regions.dock.minY)
        return (CGRect(x: regions.dock.midX - breadth / 2, y: top, width: breadth, height: height), extent)
    }

    /// 能展开的各格收着时的格子和展开后的面板，按格子的 ID；path 是展开着的那一格里又展开到哪。
    func unfolds(path: ArraySlice<String>, regions: WindowRegions) -> [String: (cell: CGRect, panel: CGRect)] {
        var frames: [String: (cell: CGRect, panel: CGRect)] = [:]
        for (entry, frame) in allCells where entry.expands {
            frames[entry.id] = (frame, Self.panel(entry, from: frame, path: path, regions: regions).frame)
        }
        return frames
    }

    /// 竖排家族格里父代理的位置，胶囊最上面。
    static func parentFrame(in cell: CGRect) -> CGRect { faceFrame(in: cell, at: 0) }

    /// 竖排家族格里第 index 个头像的位置，同 DockGroup 收着时：父代理是 0，往下每个错开三分之一格。
    static func faceFrame(in cell: CGRect, at index: Int) -> CGRect {
        let inset = DockGroup.inset(cell.width), size = cell.width - 2 * inset
        return CGRect(x: cell.minX + inset, y: cell.minY + inset + CGFloat(index) * cell.width / 3, width: size, height: size)
    }
}
