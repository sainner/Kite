import SwiftUI

/// 实例组里的一格。布局文件夹、添加入口见 DockBandItem。
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
    /// 子代理：.instance，或自己也带着子代理的 .family。在台面上的画箭头；收着时只露前三个，其余的藏在后面（见 DockGeometry.tucked）。
    let children: [DockEntry]

    /// 父代理的 pane（就是它的实例 ID）；代理都有对话视图。
    var pane: Pane { Pane(parent.id) }
}

/// 停靠栏的两组：布局组（本项目的布局文件夹）与实例组（代理在前、工具在后，各按创建先后，状态变化不挪位置），各项的排法见 DockBandItem。
struct DockModel {
    /// 本项目的布局（配方），见 ProjectLayout；宽屏停靠栏的布局组里一个布局一个文件夹。
    var layouts: [ProjectLayout] = []
    var agents: [DockEntry] = []
    var tools: [DockEntry] = []
    var all: [DockEntry] { agents + tools }
    /// ⌘数字按它数：实例组从上到下的各格（代理、工具），布局文件夹和两个添加入口不占编号。
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
        let id = dockInstanceID(pane)
        return instances.first { $0.id == id }
    }

    func isAgent(_ instance: RemotePluginInstance) -> Bool { definition(of: instance)?.agent != nil }

    func isAgentPane(_ pane: Pane) -> Bool {
        pane.id == draftPane || instance(of: pane).map(isAgent) == true
    }

    /// 停靠栏的数据：所有未归档的实例各一格（代理在前、工具在后，各按创建先后），子代理收在父代理的家族格里；
    /// 草稿排在代理末尾、打开着的新建页排在最后，同排布里的顺序（见 WorkArea.panes）。
    func dockModel() -> DockModel {
        let open = instances.filter { $0.status == .open }
        let byID = Dictionary(open.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 子代理挂在开着的父代理下面，在不在台面上都一样。
        func parent(of instance: RemotePluginInstance) -> RemotePluginInstance? {
            guard isAgent(instance) else { return nil }
            return instance.origin.flatMap { byID[$0.instanceId] }.flatMap { isAgent($0) ? $0 : nil }
        }
        let childAgents = open.filter { parent(of: $0) != nil }
        let childrenOf = Dictionary(grouping: childAgents) { parent(of: $0)!.id }
        func ordered(_ entries: [DockEntry]) -> [DockEntry] {
            entries.enumerated().sorted { left, right in
                let (a, b) = (left.element, right.element)
                if case .family = a, case .instance = b { return true }
                if case .instance = a, case .family = b { return false }
                return left.offset < right.offset
            }.map(\.element)
        }
        /// 子代理按创建先后（自己也带着子代理的排在前面），状态变化不挪位置：在跑的不靠挪到前面露出来，
        /// 收着时由父代理那一格替它发脉冲（见 DockEntryFace.familyFold）。
        func children(of id: String) -> [DockEntry] {
            ordered((childrenOf[id] ?? []).sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }.map(member))
        }
        /// 家族里的一项：子代理自己也带着子代理的是嵌套的家族。
        func member(_ instance: RemotePluginInstance) -> DockEntry {
            let kids = children(of: instance.id)
            guard !kids.isEmpty else { return .instance(instance) }
            return .family(.init(parent: instance, children: kids))
        }
        /// 顶层的一格：带着子代理的代理是家族格，有视图的实例是它自己的 pane，没有视图的只占格。
        func entry(_ instance: RemotePluginInstance) -> DockEntry {
            let kids = children(of: instance.id)
            if !kids.isEmpty { return .family(.init(parent: instance, children: kids)) }
            return definition(of: instance)?.views.isEmpty == false ? .pane(Pane(instance.id)) : .instance(instance)
        }

        let ordered = open.filter { parent(of: $0) == nil }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        var model = DockModel()
        model.layouts = layouts
        model.agents = ordered.filter(isAgent).map(entry) + (draftPane.map { [.pane(Pane($0))] } ?? [])
        model.tools = ordered.filter { !isAgent($0) }.map(entry) + (chooserOpen ? [.pane(Pane(chooserPane))] : [])
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
        for (entry, _) in geometry.entries {
            guard let number = numbers[entry.id], let frame = geometry.hoverFrame(of: entry.id) else { continue }
            tips.append(DockHoverTip(id: entry.id, text: dockLabel(entry), frame: frame, number: number))
        }
        return tips
    }

    /// 停靠栏上悬停的那一格的标签：带子上的格子按停靠栏的几何找位置，展开的家族格里的各项自己报位置。
    /// 展开着家族格时只标家族格里的：别的格子压暗了，报上来的悬停不算。
    private func dockHoverTip(in geometry: DockGeometry) -> DockHoverTip? {
        guard let hover = dockHover else { return nil }
        let text: String
        if let root = dockExpansion.first {
            let members = geometry.entries.first { $0.entry.id == root }?.entry.members ?? []
            guard let found = DockModel(agents: members).entry(hover.id) else { return nil }
            text = dockLabel(found)
        } else if let found = DockModel(agents: geometry.entries.map(\.entry)).entry(hover.id) {
            text = dockLabel(found)
        } else if let layout = layouts.first(where: { DockBandItem.layout($0).id == hover.id }) {
            text = layout.name
        } else if hover.id == DockBandItem.addLayout.id {
            text = DockBandItem.addLayoutTitle
        } else if hover.id == DockBandItem.addInstance.id {
            text = DockBandItem.addInstanceTitle
        } else {
            return nil
        }
        guard let frame = hover.frame ?? geometry.hoverFrame(of: hover.id) else { return nil }
        return DockHoverTip(id: hover.id, text: text, frame: frame)
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
        let entries = area.dockModel().topToBottom
        guard entries.indices.contains(index) else { return }
        switch entries[index] {
        case .pane(let pane):
            layout.activate(pane)
        case .family(let family):
            layout.activate(family.pane)
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

/// 宽屏停靠栏（竖排）每一项、每个头像画在哪，坐标与内容区相同。和停靠栏画出来的是同一套排法（DockBandRun、DockStackCurve、
/// DockGroup.openPlacement），按这一刻离前端滚了多远、展开着哪一格算：卡片缩小落到哪、从哪展开（StagePlan.dockSlot、
/// CardPresentation.place），悬停标签对着哪，都按它。
struct DockGeometry {
    /// 一项或一个头像画在哪、多透明（堆叠渐隐）。
    struct Slot: Equatable {
        var frame: CGRect
        var opacity: Double = 1
    }

    /// 从前到后各项，见 DockModel.bandItems。
    private(set) var items: [(item: DockBandItem, slot: Slot)] = []
    /// 各实例的头像画在哪：普通的就是它那一格，家族里的按它在胶囊里或展开的一排里的位置。卡片缩小、关掉时落到这里，打开时从这里起。
    private(set) var faces: [String: Slot] = [:]
    /// 收在家族胶囊里、只露一截的子代理（各层都算）：卡片落进来时外框缩到它的头像上淡没，不压在父代理的头像上面停一下。
    private(set) var tucked: Set<String> = []
    /// ⌘1～9 打开的各格，按编号排，见 DockModel.topToBottom。
    let numbered: [String]

    /// region 是停靠栏那一列（WindowRegions.dock），distance 是离前端滚了多远，familyOffset 是展开的家族格里面滚了多远。
    /// familyLimit 是展开的家族格最长多长（见 WorkArea.dockFamilyLimit），没给时按停靠栏的长。
    init(model: DockModel, region: CGRect, expansion: [String] = [], distance: CGFloat = 0, familyOffset: CGFloat = 0, familyLimit: CGFloat? = nil) {
        numbered = model.topToBottom.prefix(9).map(\.id)
        let bandItems = model.bandItems(.vertical), visible = region.height
        let limit = familyLimit ?? DockBandMetrics.familyLimit(visible: visible)
        let extents = bandItems.map { DockBandMetrics.extent($0, expansion: expansion, limit: limit) }
        let run = DockBandRun(extents: extents, gap: Metrics.gap)
        let curve = DockStackCurve(total: run.total, region: visible, distance: distance, stacking: expansion.isEmpty ? 1 : 0)
        for (index, item) in bandItems.enumerated() {
            let length = extents[index], back = run.back(index)
            let breadth = DockBandMetrics.breadth(item, expansion: expansion)
            let slot = Slot(frame: CGRect(x: region.midX - breadth / 2, y: region.minY + visible - curve(back) - length, width: breadth, height: length),
                            opacity: curve.opacity(back + length / 2))
            items.append((item, slot))
            guard case .entry(let entry) = item else { continue }
            switch entry {
            case .pane(let pane): faces[pane.id] = slot
            case .instance(let instance): faces[instance.id] = slot
            case .family:
                let open = expansion.first == entry.id
                place(entry, in: slot, path: open ? expansion.dropFirst() : nil,
                      viewport: open ? DockViewport(length: length, offset: familyOffset) : nil)
            }
        }
    }

    /// 家族格里各头像的位置。path 为 nil 是收着（同 DockGroup.foldedSlots）：父代理在胶囊最上面，子代理往下每个错开三分之一格、往后渐隐，
    /// 露不出来的藏在最后一个后面，孙辈跟着它所在的子代理。展开着的照 DockGroup.openPlacement 排开，里面再展开的往里接着算。
    private mutating func place(_ entry: DockEntry, in slot: Slot, path: ArraySlice<String>?, viewport: DockViewport?) {
        guard case .family(let family) = entry else { return }
        let cell = slot.frame
        guard let path else {
            let width = Metrics.dragBubble, inset = DockGroup.inset(width), size = width - 2 * inset
            for (index, member) in entry.members.enumerated() {
                let frame = CGRect(x: cell.minX + inset, y: cell.minY + inset + CGFloat(min(index, DockGroup.shownChildren)) * width / 3,
                                   width: size, height: size)
                let face = Slot(frame: frame, opacity: slot.opacity * DockGroup.foldedOpacity(index))
                for id in index == 0 ? [family.parent.id] : member.instanceIDs {
                    faces[id] = face
                    if index > 0 { tucked.insert(id) }
                }
            }
            return
        }
        let placement = DockGroup.openPlacement(entry, path: path, viewport: viewport)
        for (index, (member, spot)) in zip(entry.members, placement.members).enumerated() {
            let box = DockGroup.box(member, path: path)
            let face = Slot(frame: CGRect(x: cell.midX - box.across / 2, y: cell.minY + spot.along, width: box.across, height: box.along),
                            opacity: slot.opacity * spot.opacity)
            switch member {
            case .family where index > 0:
                let open = path.first == member.id
                place(member, in: face, path: open ? path.dropFirst() : nil, viewport: nil)
            default:
                faces[index == 0 ? family.parent.id : member.instanceIDs.first ?? member.id] = face
            }
        }
    }

    /// 实例的各格，带编号的悬停标签按它浮。
    var entries: [(entry: DockEntry, slot: Slot)] {
        items.compactMap { if case .entry(let entry) = $0.item { (entry, $0.slot) } else { nil } }
    }

    /// 添加实例那一格：新建的窗口从这里展开，没选插件就关掉的新建页收回这里。
    var add: CGRect? {
        items.first { if case .addInstance = $0.item { true } else { false } }?.slot.frame
    }

    /// 实例的头像画在哪：家族格里的按它在胶囊里的位置（见 faces），其余的就是它那一格。
    func face(of instance: String) -> Slot? { faces[instance] }

    /// 卡片缩小后停在哪：pane 就是实例（草稿、新建页是本机的 pane），家族格里的父代理在胶囊最上面。
    func slot(of pane: Pane) -> Slot? { faces[pane.id] }

    /// 悬停标签对着的范围：家族格的对着父代理的头像那一行，不对着整格；布局文件夹、实例按它那一格。
    func hoverFrame(of id: String) -> CGRect? {
        if let found = items.first(where: { $0.item.id == id }) {
            guard case .entry(.family(let family)) = found.item, let face = faces[family.parent.id] else { return found.slot.frame }
            let cell = found.slot.frame
            return CGRect(x: cell.minX, y: face.frame.minY, width: cell.width, height: face.frame.height)
        }
        for prefix in ["instance:", "pane:"] where id.hasPrefix(prefix) {
            return faces[String(id.dropFirst(prefix.count))]?.frame
        }
        return nil
    }
}
