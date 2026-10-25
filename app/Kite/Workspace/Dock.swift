import SwiftUI

/// 停靠栏里的一格。添加入口不在这里，固定排第一个。
indirect enum DockEntry: Identifiable {
    /// 一个实例（Pane 的 ID 就是实例 ID），本机台面上的和不在台面上的都一样；也用于草稿、新建页这两个只在本机的 pane。
    /// 紧凑布局里是底栏上的每一格，含当前窗口。
    case pane(Pane)
    /// 父代理和它的子代理合成一格。
    case family(DockFamily)
    /// 没有视图的实例（只在后台的插件）：只在停靠栏占格，点开是实例设置；家族格展开后里面的代理也用它表示。
    case instance(RemotePluginInstance)

    var id: String {
        switch self {
        case .pane(let pane): "pane:\(pane.id)"
        case .family(let family): Self.familyID(family.parent.id)
        case .instance(let instance): "instance:\(instance.id)"
        }
    }

    static func familyID(_ instance: String) -> String { "family:\(instance)" }

    /// 展开后看到的各项：家族是父代理和子代理。
    var members: [DockEntry] {
        switch self {
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
        if case .family = self { true } else { false }
    }

    /// 这一格里有没有这个实例：它自己，或装着它的家族格。
    func contains(instance: String) -> Bool {
        switch self {
        case .instance(let value): value.id == instance
        case .family(let family): family.parent.id == instance || family.children.contains { $0.contains(instance: instance) }
        case .pane(let pane): pane.id == instance
        }
    }

    /// 这一格里的实例，家族连同各层子代理。
    var instanceIDs: [String] {
        switch self {
        case .instance(let value): [value.id]
        case .family(let family): [family.parent.id] + family.children.flatMap(\.instanceIDs)
        case .pane(let pane): [pane.id]
        }
    }
}

/// 子代理挂在父代理下面显示，随父代理归档：在不在台面上都在父代理这一格里，不另占一格。
struct DockFamily {
    let parent: RemotePluginInstance
    /// 父代理的 pane（就是它的实例 ID）；代理都有对话视图，所以总有。
    let pane: Pane?
    /// 父代理在本机台面上，格子里以箭头代替头像。
    let onStage: Bool
    /// 子代理：.instance，或自己也带着子代理的 .family。在台面上的画箭头，不在的藏在自己的头像后面（见 DockGeometry.tucked）。
    let children: [DockEntry]
}

/// 停靠栏的两组：布局组（本项目的布局文件夹，第二期画）与实例组（代理在前、工具在后，各按创建先后，状态变化不挪位置）。
struct DockModel {
    /// 本项目的布局（配方），见 ProjectLayout；这一期停靠栏还不画它们，入口留给第二期。
    var layouts: [ProjectLayout] = []
    var agents: [DockEntry] = []
    var tools: [DockEntry] = []
    /// 本机台面上的实例：家族格里的子代理画向左的箭头。
    var onStage: Set<String> = []
    /// 挂在父代理下面的子代理（各层都算）。
    var grouped: Set<String> = []
    var all: [DockEntry] { agents + tools }
    /// 宽屏停靠栏从上到下的各格，⌘数字按它数：代理组、工具组。
    var topToBottom: [DockEntry] { agents + tools }
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
    /// pane 对应的实例（ID 相同）。新建页关掉、交给了后台实例的，按那个实例算（关闭的卡片飞进它那一格，见 handedOff）。
    func instance(of pane: Pane) -> RemotePluginInstance? {
        let id = handedOff[pane.id] ?? pane.id
        return instances.first { $0.id == id }
    }

    func isAgent(_ instance: RemotePluginInstance) -> Bool { definition(of: instance)?.agent != nil }

    func isAgentPane(_ pane: Pane) -> Bool {
        pane.id == draftPane || instance(of: pane).map(isAgent) == true
    }

    /// 停靠栏的数据：所有未归档的实例各一格（代理在前、工具在后，各按创建先后），子代理收在父代理的家族格里；
    /// 草稿排在代理末尾、打开着的新建页排在最后，同排布里的顺序（见 WorkArea.panes）。onStage 是本机台面上的实例。
    func dockModel(onStage: Set<String>) -> DockModel {
        let open = instances.filter { $0.status == .open }
        let byID = Dictionary(open.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 子代理挂在开着的父代理下面，在不在台面上都一样。
        func parent(of instance: RemotePluginInstance) -> RemotePluginInstance? {
            guard isAgent(instance) else { return nil }
            return instance.origin.flatMap { byID[$0.instanceId] }.flatMap { isAgent($0) ? $0 : nil }
        }
        let childAgents = open.filter { parent(of: $0) != nil }
        let childrenOf = Dictionary(grouping: childAgents) { parent(of: $0)!.id }
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
            ordered((childrenOf[id] ?? []).sorted { recent($0) > recent($1) }.map(member))
        }
        /// 家族里的一项：子代理自己也带着子代理的是嵌套的家族。
        func member(_ instance: RemotePluginInstance) -> DockEntry {
            let kids = children(of: instance.id)
            guard !kids.isEmpty else { return .instance(instance) }
            return .family(.init(parent: instance, pane: Pane(instance.id), onStage: onStage.contains(instance.id), children: kids))
        }
        /// 顶层的一格：带着子代理的代理是家族格，有视图的实例是它自己的 pane，没有视图的只占格。
        func entry(_ instance: RemotePluginInstance) -> DockEntry {
            let kids = children(of: instance.id)
            if !kids.isEmpty { return .family(.init(parent: instance, pane: Pane(instance.id), onStage: onStage.contains(instance.id), children: kids)) }
            return definition(of: instance)?.views.isEmpty == false ? .pane(Pane(instance.id)) : .instance(instance)
        }

        let ordered = open.filter { parent(of: $0) == nil }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        var model = DockModel()
        model.layouts = layouts
        model.agents = ordered.filter(isAgent).map(entry) + (draftPane.map { [.pane(Pane($0))] } ?? [])
        model.tools = ordered.filter { !isAgent($0) }.map(entry) + (chooserOpen ? [.pane(Pane(chooserPane))] : [])
        model.onStage = onStage
        model.grouped = Set(childAgents.map(\.id))
        return model
    }

    /// 代理开出、还开着的直接子代理；不是代理的没有。
    private func childAgents(of instance: RemotePluginInstance) -> [RemotePluginInstance] {
        guard isAgent(instance) else { return [] }
        return instances.filter { $0.status == .open && $0.origin?.instanceId == instance.id && isAgent($0) }
    }

    /// 代理开出、还开着的各层子代理，归档时一起归档，和工作机的规则一样（见 kited 的 Kite.subagents）。
    func subagents(of instance: RemotePluginInstance) -> [RemotePluginInstance] {
        childAgents(of: instance).flatMap { [$0] + subagents(of: $0) }
    }

    /// 「归档空闲的子代理」要归档的：整棵都空闲的子代理，归档时连同它的各层子代理；有一个不空闲就留下它，往下一层找。
    func idleSubagents(of instance: RemotePluginInstance) -> [RemotePluginInstance] {
        childAgents(of: instance).flatMap { child in
            ([child] + subagents(of: child)).allSatisfy { isIdle($0.id) } ? [child] : idleSubagents(of: child)
        }
    }

    /// 空闲：回合已结束（完成、停止、失败都算），没在等人回应，也没在等确认继续。
    /// 工作机还没给出活动摘要的（刚开出、或工作机重启后没载入过）不知道在做什么，不算，免得归档掉在跑或等继续的。
    func isIdle(_ id: String) -> Bool {
        guard let activity = activities[id] else { return false }
        return activity.phase == "idle" && activity.waiting == nil && !activity.waitingForResume
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

    /// 家族里最要紧的一项。
    func attention(in entries: [DockEntry]) -> DockAttention? {
        var top: DockAttention?
        func visit(_ entry: DockEntry) {
            switch entry {
            case .instance(let instance):
                if let value = attention(of: instance.id) { top = max(top ?? value, value) }
            case .family(let family):
                visit(.instance(family.parent))
                family.children.forEach(visit)
            case .pane(let pane):
                if let value = attention(of: pane.id) { top = max(top ?? value, value) }
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
        case .instance(let instance):
            guard isAgent(instance) else {
                return instance.title + ((definition(of: instance)?.views.isEmpty ?? true) ? " · 后台" : "")
            }
            return instance.title + " · " + statusText(of: instance.id)
        }
    }

    /// 停靠栏浮出的标签：悬停的那一格；numbered（按住 ⌘，见 ShortcutHint）时各格一起浮出、尾部带编号，悬停时照常浮出标签。
    /// 展开着家族格时不标。
    func dockHoverTips(in geometry: DockGeometry, numbered: Bool) -> [DockHoverTip] {
        let hover = dockHoverTip(in: geometry)
        guard numbered, dockExpansion.isEmpty else { return hover.map { [$0] } ?? [] }
        let numbers = Dictionary(uniqueKeysWithValues: geometry.numbered.enumerated().map { ($1, $0 + 1) })
        var tips: [DockHoverTip] = []
        for (entry, frame) in geometry.cells {
            guard let number = numbers[entry.id] else { continue }
            tips.append(DockHoverTip(id: entry.id, text: dockLabel(entry), frame: geometry.hoverFrame(of: entry, cell: frame), number: number))
        }
        return tips
    }

    /// 停靠栏上悬停的那一格的标签；家族格里的父代理是卡片报上来的，按 pane 找。
    /// 展开着家族格时只标面板里的：别的格子、卡片压暗了，面板也盖在它们上面，报上来的悬停不算。
    private func dockHoverTip(in geometry: DockGeometry) -> DockHoverTip? {
        guard let hover = dockHover else { return nil }
        let entry: DockEntry
        if let root = dockExpansion.first {
            let members = geometry.cells.first { $0.entry.id == root }?.entry.members ?? []
            guard let found = DockModel(agents: members).entry(hover.id) else { return nil }
            entry = found
        } else if let found = DockModel(agents: geometry.cells.map(\.entry)).entry(hover.id) {
            entry = found
        } else if hover.id.hasPrefix("pane:") {
            entry = .pane(Pane(String(hover.id.dropFirst("pane:".count))))
        } else {
            return nil
        }
        return DockHoverTip(id: hover.id, text: dockLabel(entry), frame: hover.frame)
    }
}

extension AppModel {
    /// 点一格：有视图的实例放上台面（在台面上就聚焦），没有视图的打开实例设置。
    func openDockInstance(_ instance: RemotePluginInstance, in area: WorkArea) {
        guard area.currentView(of: instance) != nil else {
            area.settingsInstance = instance
            return
        }
        showInstance(instance.id, in: area)
    }

    /// ⌘数字：点宽屏停靠栏从上到下第 index 格（从 0 数），同用指针点：放上台面或聚焦，家族格打开父代理。拖动、拖缝当中不做。
    func openDockEntry(at index: Int, in area: WorkArea) {
        let layout = area.layout
        guard area.pluginClient != nil, layout.presentation == .tiled, layout.drag == nil, layout.resizing == nil else { return }
        let entries = area.dockModel(onStage: Set((layout.shown?.panes ?? []).map(\.id))).topToBottom
        guard entries.indices.contains(index) else { return }
        switch entries[index] {
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

/// 宽屏停靠栏每一格的位置：添加入口固定在最上面，然后是代理组、分隔线、工具组。坐标与内容区相同。
struct DockGeometry {
    /// 两组之间多出的一个模块，分隔线画在两组正中。
    static var dividerExtra: CGFloat { Metrics.gap }
    /// 展开的家族格里头像缩放的下限，见 DockGroup；沿用原来小头像的尺寸。
    static var miniGap: CGFloat { Metrics.dragBubble * 4 / 36 }
    static var miniSize: CGFloat { (Metrics.dragBubble - miniGap) / 2 }

    let add: CGRect
    private(set) var cells: [(entry: DockEntry, frame: CGRect)] = []
    private(set) var divider: CGFloat?
    /// 家族格里各个代理的头像画在哪（实例 ID 到位置）：父代理在胶囊最前面，子代理各在露出来的那一截，露不出来的藏在最后一个后面，
    /// 孙辈跟着它所在的子代理。卡片缩小、关掉时落到这里。
    private(set) var faces: [String: CGRect] = [:]
    let onStage: Set<String>
    let grouped: Set<String>
    /// ⌘1～9 打开的各格，按编号排，见 DockModel.topToBottom。
    let numbered: [String]
    var allCells: [(entry: DockEntry, frame: CGRect)] { cells }

    init(model: DockModel, regions: WindowRegions) {
        onStage = model.onStage
        grouped = model.grouped
        numbered = model.topToBottom.prefix(9).map(\.id)
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
        for (entry, frame) in cells {
            guard case .family(let family) = entry else { continue }
            faces[family.parent.id] = Self.faceFrame(in: frame, at: 0)
            for (index, child) in family.children.enumerated() {
                let face = Self.faceFrame(in: frame, at: min(index + 1, DockGroup.shownChildren))
                for id in child.instanceIDs { faces[id] = face }
            }
        }
    }

    /// 一格的大小：家族沿排列方向更长。
    static func cellSize(_ entry: DockEntry, mini: Bool = false, axis: Axis = .vertical) -> CGSize {
        let width = mini ? miniSize : Metrics.dragBubble
        var length = width
        if case .family(let family) = entry { length = mini ? Metrics.dragBubble : DockGroup.length(family, width: width) }
        return axis == .vertical ? CGSize(width: width, height: length) : CGSize(width: length, height: width)
    }

    /// 从添加入口到最后一格的总长，窗口最小高度据此算。
    static func length(of model: DockModel) -> CGFloat {
        let lengths = [Metrics.dragBubble] + (model.agents + model.tools).map { cellSize($0).height }
        let divider = model.agents.isEmpty || model.tools.isEmpty ? 0 : dividerExtra
        return lengths.reduce(0, +) + CGFloat(lengths.count - 1) * Metrics.gap + divider
    }

    /// 某个实例落在哪一格：它自己，或装着它的家族格。
    func frame(containing instance: String) -> CGRect? {
        cells.first { $0.entry.contains(instance: instance) }?.frame
    }

    /// 实例的头像画在哪：家族格里的按它在胶囊里的位置（见 faces），其余的按装着它的那一格。
    func face(of instance: String) -> CGRect? {
        faces[instance] ?? frame(containing: instance)
    }

    /// 卡片缩小后画在哪：普通的占满一格，家族格里的父代理在胶囊最上面。
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

    /// 悬停标签对着的范围：家族格的对着最上面父代理的头像，不对着整格。
    func hoverFrame(of entry: DockEntry, cell: CGRect, mini: Bool = false) -> CGRect {
        var frame = cell
        if case .family = entry {
            let face = Self.parentFrame(in: cell)
            frame = CGRect(x: frame.minX, y: face.minY, width: frame.width, height: face.height)
        }
        return frame
    }

    /// 面板最高多高：照原来的间距排开八格。
    static var panelLimit: CGFloat { 2 * DockGroup.padding + 8 * Metrics.dragBubble + 7 * Metrics.gap }

    /// 展开的家族格从格子原地拉长成的面板：先往下，放不下再往上，最高 panelLimit（停靠栏没那么高时到停靠栏全高），
    /// 再多就在里面滚动，照紧凑布局的底栏堆叠（见 DockGroup.viewport）。extent 是里面排开时的长，比面板高时要滚动。
    static func panel(_ entry: DockEntry, from cell: CGRect, path: ArraySlice<String>, regions: WindowRegions) -> (frame: CGRect, extent: CGFloat) {
        let extent = DockGroup.extent(entry, path: path), breadth = DockGroup.breadth(entry, path: path)
        let height = min(extent, panelLimit, regions.dock.height)
        let top = max(min(cell.minY - DockGroup.padding, regions.dock.maxY - height), regions.dock.minY)
        return (CGRect(x: regions.dock.midX - breadth / 2, y: top, width: breadth, height: height), extent)
    }

    /// 能展开的各格收着时的格子和展开后的面板，按格子的 ID；path 是展开着的那一格里又展开到哪。
    func unfolds(path: ArraySlice<String>, regions: WindowRegions) -> [String: (cell: CGRect, panel: CGRect)] {
        var frames: [String: (cell: CGRect, panel: CGRect)] = [:]
        for (entry, frame) in cells where entry.expands {
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
