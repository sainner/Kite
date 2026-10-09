import SwiftUI

/// 停靠栏里的一格。添加入口不在这里，固定排第一个。
indirect enum DockEntry: Identifiable {
    /// 本机最小化的窗口；紧凑布局里是底栏上的每个窗口，含当前窗口。
    case pane(Pane)
    /// 父代理和它没有窗口的子代理合成一格。
    case family(DockFamily)
    /// 所有没有窗口的代理。
    case folder([DockEntry])
    /// 没有窗口的实例。
    case instance(RemotePluginInstance)

    var id: String {
        switch self {
        case .pane(let pane): "pane:\(pane.id)"
        case .family(let family): Self.familyID(family.parent.id)
        case .folder: Self.folderID
        case .instance(let instance): "instance:\(instance.id)"
        }
    }

    static let folderID = "folder"
    static func familyID(_ instance: String) -> String { "family:\(instance)" }

    /// 展开后看到的各项：文件夹是里面的代理，家族是父代理和子代理。
    var members: [DockEntry] {
        switch self {
        case .folder(let entries): entries
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
        case .folder, .family: true
        default: false
        }
    }
}

/// 子代理不随父代理回收，只是挂在它下面显示；有窗口的子代理独立成格。
struct DockFamily {
    let parent: RemotePluginInstance
    /// 父代理在本机的窗口；没有窗口时整家收在文件夹里。
    let pane: Pane?
    /// 父代理的窗口在台面上，格子里以箭头代替头像。
    let onStage: Bool
    /// 没有窗口的子代理：.instance，或自己也带着子代理的 .family。
    let children: [DockEntry]
}

/// 代理组在上，有子代理的优先；工具组在下。
struct DockModel {
    var agents: [DockEntry] = []
    var tools: [DockEntry] = []
    var all: [DockEntry] { agents + tools }
}

/// 停靠格的角标，同时只显示一个，按这个顺序取。
enum DockAttention: Int, Comparable {
    case unseen, waiting, failed

    var color: Color {
        switch self {
        case .failed: Theme.danger
        case .waiting: Theme.warning
        case .unseen: .accentColor
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
        pane.id == Self.draftWindowID || instance(of: pane).map(isAgent) == true
    }

    /// docked 是停靠栏里按顺序放的窗口，onStage 是台面上的窗口（只用来找带着子代理的父代理）。
    /// closing 是正要关窗口的实例，按已经没有窗口来排，用来算关窗口时卡片要飞去哪一格。
    func dockModel(docked: [Pane], onStage: Set<Pane>, closing: String? = nil) -> DockModel {
        let open = instances.filter { $0.status == .open }
        let byID = Dictionary(open.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var windowed = Set(windows.map(\.target.instanceId))
        if let closing { windowed.remove(closing) }
        // 子代理挂在仍然存在的父代理下面；父代理归档后提升为文件夹里的顶层项。
        func parent(of instance: RemotePluginInstance) -> RemotePluginInstance? {
            instance.origin.flatMap { byID[$0.instanceId] }.flatMap { isAgent($0) ? $0 : nil }
        }
        let windowlessAgents = open.filter { isAgent($0) && !windowed.contains($0.id) }
        let childrenOf = Dictionary(grouping: windowlessAgents.filter { parent(of: $0) != nil }) { parent(of: $0)!.id }
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
        for pane in docked {
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
        let folder = ordered(windowlessAgents.filter { parent(of: $0) == nil }.sorted { recent($0) > recent($1) }.map(entry))
        if !folder.isEmpty { model.agents.append(.folder(folder)) }
        model.tools += open.filter { !isAgent($0) && !windowed.contains($0.id) }.map(DockEntry.instance)
        return model
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

    /// 文件夹与家族里最要紧的一项，以及需要处理的个数。
    func attention(in entries: [DockEntry]) -> (DockAttention, Int)? {
        var top: DockAttention?
        var count = 0
        func visit(_ entry: DockEntry) {
            switch entry {
            case .instance(let instance):
                if let value = attention(of: instance.id) { top = max(top ?? value, value); count += 1 }
            case .family(let family):
                visit(.instance(family.parent))
                family.children.forEach(visit)
            case .folder(let entries):
                entries.forEach(visit)
            case .pane:
                break
            }
        }
        entries.forEach(visit)
        return top.map { ($0, count) }
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
        case .folder(let entries):
            return "没有窗口的代理 · \(entries.count) 个"
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

/// 宽屏停靠栏每一格的位置：添加入口固定在最上面，然后是代理组、分隔线、工具组。坐标与内容区相同。
struct DockGeometry {
    /// 两组之间多出的一个模块，分隔线画在两组正中。
    static var dividerExtra: CGFloat { Metrics.gap }

    let add: CGRect
    private(set) var cells: [(entry: DockEntry, frame: CGRect)] = []
    private(set) var divider: CGFloat?

    init(model: DockModel, regions: WindowRegions) {
        let size = Metrics.dragBubble, step = size + Metrics.gap
        let x = regions.dock.midX - size / 2
        var y = regions.dock.minY
        add = CGRect(x: x, y: y, width: size, height: size)
        y += step
        for entry in model.agents {
            cells.append((entry, CGRect(x: x, y: y, width: size, height: size)))
            y += step
        }
        if !model.agents.isEmpty && !model.tools.isEmpty {
            divider = y - Metrics.gap / 2 + Self.dividerExtra / 2
            y += Self.dividerExtra
        }
        for entry in model.tools {
            cells.append((entry, CGRect(x: x, y: y, width: size, height: size)))
            y += step
        }
    }

    /// 某个没有窗口的实例落在哪一格：它自己，或装着它的文件夹、家族格。
    func frame(containing instance: String) -> CGRect? {
        func contains(_ entry: DockEntry) -> Bool {
            switch entry {
            case .instance(let value): value.id == instance
            case .family(let family): family.parent.id == instance || family.children.contains(where: contains)
            case .folder(let entries): entries.contains(where: contains)
            case .pane: false
            }
        }
        return cells.first { contains($0.entry) }?.frame
    }

    /// 窗口缩小后画在哪：普通窗口占满一格，家族格里的父代理缩在左下角，给角上的子代理留位置。
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

    static func parentFrame(in cell: CGRect) -> CGRect {
        let size = cell.width * 26 / 36, inset = cell.width * 3 / 36
        return CGRect(x: cell.minX + inset, y: cell.maxY - inset - size, width: size, height: size)
    }

    static func childFrame(in cell: CGRect) -> CGRect {
        let size = cell.width * 15 / 36, inset = cell.width * 2 / 36
        return CGRect(x: cell.maxX - inset - size, y: cell.minY + inset, width: size, height: size)
    }

    /// 家族格描边的右上角与角上的子代理同心。
    static func familyCornerRadius(_ cell: CGFloat) -> CGFloat {
        cell * 15 / 36 / 2 + cell * 2 / 36
    }
}

/// 加号与家族格共用的形状：圆，右上角圆角略小。
nonisolated struct NotchedCircle: InsettableShape {
    var corner: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        let radius = min(rect.width, rect.height) / 2
        return UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: radius,
                                      topTrailingRadius: max(min(corner - inset, radius), 0), style: .continuous).path(in: rect)
    }

    func inset(by amount: CGFloat) -> Self { var copy = self; copy.inset += amount; return copy }
}
