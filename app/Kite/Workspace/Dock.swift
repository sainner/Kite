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
}

/// 子代理不随父代理回收，只是挂在它下面显示；有窗口的子代理独立成格。
struct DockFamily {
    let parent: RemotePluginInstance
    /// 父代理在本机的窗口；没有窗口时整家占一个小头像。
    let pane: Pane?
    /// 父代理的窗口在台面上，格子里以箭头代替头像。
    let onStage: Bool
    /// 没有窗口的子代理：.instance，或自己也带着子代理的 .family。
    let children: [DockEntry]
}

/// 代理组在上，有子代理的优先；工具组在下；没有窗口的代理和工具排成小头像，在最后。
struct DockModel {
    /// 小头像最多两格，每格两行两列；再多时最后一个位置换成「更多」。
    static let miniLimit = 8

    var agents: [DockEntry] = []
    var tools: [DockEntry] = []
    /// 没有窗口的代理和工具按创建先后排，状态变化不挪位置；小头像就表示没有窗口。
    var minis: [DockMini] = []
    var all: [DockEntry] { agents + tools + minis.map(\.entry) }
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
    func instance(of pane: Pane) -> RemotePluginInstance? {
        guard let target = windows.first(where: { $0.id == pane.id })?.target else { return nil }
        return instances.first { $0.id == target.instanceId }
    }

    func isAgent(_ instance: RemotePluginInstance) -> Bool { definition(of: instance)?.agent != nil }

    func isAgentPane(_ pane: Pane) -> Bool {
        pane.id == draftWindow || instance(of: pane).map(isAgent) == true
    }

    /// docked 是停靠栏里按顺序放的窗口，onStage 是台面上的窗口（只用来找带着子代理的父代理）。
    /// windowless 是按没有窗口来排的实例：正要关窗口的，用来算卡片飞去哪一格；或正从停靠栏打开、窗口还没放上台面的。
    func dockModel(docked: [Pane], onStage: Set<Pane>, windowless: String? = nil) -> DockModel {
        let open = instances.filter { $0.status == .open }
        let byID = Dictionary(open.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var windowed = Set(windows.map(\.target.instanceId))
        if let windowless { windowed.remove(windowless) }
        // 子代理挂在仍然存在的父代理下面；父代理归档后提升为顶层的小头像。
        func parent(of instance: RemotePluginInstance) -> RemotePluginInstance? {
            instance.origin.flatMap { byID[$0.instanceId] }.flatMap { isAgent($0) ? $0 : nil }
        }
        let windowlessAgents = open.filter { isAgent($0) && !windowed.contains($0.id) }
        let childrenOf = Dictionary(grouping: windowlessAgents.filter { parent(of: $0) != nil }) { parent(of: $0)!.id }
        // 没有窗口的都排成小头像：子代理挂在父代理下面，其余各占一个
        let loose = open.filter { !windowed.contains($0.id) && !(isAgent($0) && parent(of: $0) != nil) }
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
            return kids.isEmpty ? .instance(instance) : .family(.init(parent: instance, pane: nil, onStage: false, children: kids))
        }

        var model = DockModel()
        var families: [DockEntry] = []
        var agentPanes: [DockEntry] = []
        for pane in panes(in: onStage) {
            guard let instance = instance(of: pane), isAgent(instance) else { continue }
            let kids = children(of: instance.id)
            if !kids.isEmpty { families.append(.family(.init(parent: instance, pane: pane, onStage: true, children: kids))) }
        }
        for pane in docked where dockInstanceID(pane) != windowless {
            if isAgentPane(pane) {
                if let instance = instance(of: pane), case let kids = children(of: instance.id), !kids.isEmpty {
                    families.append(.family(.init(parent: instance, pane: pane, onStage: false, children: kids)))
                } else {
                    agentPanes.append(.pane(pane))
                }
            } else {
                model.tools.append(.pane(pane))
            }
        }
        model.agents = families + agentPanes
        model.minis = DockModel.pack(loose.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }.map(entry))
        return model
    }

    /// 正从停靠栏打开窗口的实例。工作机建好的窗口先收进停靠栏，放上台面前仍按没有窗口来排，卡片从它原来那一格展开。
    /// 实例已经有别的窗口时不算。
    var openingInstance: String? {
        guard case .open(let target) = pendingWindowRequest?.content else { return nil }
        let panes = layout.panes.filter { dockInstanceID($0) == target.instanceId }
        return panes.count <= 1 && panes.allSatisfy(layout.docked.contains) ? target.instanceId : nil
    }

    /// 按窗口集合的顺序取出台面上的窗口，结果稳定。
    private func panes(in set: Set<Pane>) -> [Pane] {
        set.isEmpty ? [] : windows.map { Pane($0.id) }.filter(set.contains)
    }

    func attention(of id: String) -> DockAttention? {
        guard let activity = activities[id] else { return nil }
        if activity.outcome == "failed" || activity.error == true { return .failed }
        if activity.waitingForResume { return .waiting }
        return unseen(id) ? .unseen : nil
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
                                     waitingForResume: activity.waitingForResume, unseen: unseen(id))
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
}

extension AppModel {
    /// 打开没有窗口的实例：有视图开默认视图，没有视图打开实例设置。
    func openDockInstance(_ instance: RemotePluginInstance, in area: WorkArea) {
        guard let definition = area.definition(of: instance) else { return }
        guard let view = definition.views.first(where: { $0.id == definition.defaultView }) ?? definition.views.first else {
            area.settingsInstance = instance
            return
        }
        guard !area.changingWindows, area.pendingWindowRequest == nil, area.pendingInstanceRequest == nil else { return }
        openWindow(.open(.init(instanceId: instance.id, viewId: view.id)), in: area)
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
    var allCells: [(entry: DockEntry, frame: CGRect)] { cells + minis }

    init(model: DockModel, regions: WindowRegions) {
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
    }

    /// 一格的大小：家族沿排列方向更长，小头像里的家族占一列两个位置。
    static func cellSize(_ entry: DockEntry, mini: Bool = false, axis: Axis = .vertical) -> CGSize {
        let width = mini ? miniSize : Metrics.dragBubble
        var length = width
        if case .family(let family) = entry { length = mini ? Metrics.dragBubble : DockFamilyFace.length(family, width: width) }
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
        func contains(_ entry: DockEntry) -> Bool {
            switch entry {
            case .instance(let value): value.id == instance
            case .family(let family): family.parent.id == instance || family.children.contains(where: contains)
            case .more(let entries): entries.contains(where: contains)
            case .pane: false
            }
        }
        return allCells.first { contains($0.entry) }?.frame
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

    /// 竖排家族格里父代理的位置，胶囊最上面。
    static func parentFrame(in cell: CGRect) -> CGRect {
        let inset = DockFamilyFace.inset(cell.width), size = cell.width - 2 * inset
        return CGRect(x: cell.minX + inset, y: cell.minY + inset, width: size, height: size)
    }
}
